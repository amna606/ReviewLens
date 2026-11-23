-- =====================================================================================
-- ReviewLens - ETL written entirely in MySQL 8 SQL
-- Pipeline:  data/daraz_raw.csv -> stg_raw -> (clean/transform) -> stg_clean -> dimensions -> fact + bridge
--
-- BEFORE RUNNING
--   1. python etl/xlsx_to_csv.py                (creates data/daraz_raw.csv)
--   2. Run sql/01_schema.sql                    (creates the empty warehouse tables)
--   3. Edit the file path in STEP 1 below (use forward slashes)
--   4. Connect with local infile on:  mysql --local-infile=1 -u root -p reviewlens
--      then:  SOURCE sql/02_etl_in_mysql.sql;      (or paste it into Workbench and run all)
-- Safe to re-run: it empties the tables first.
-- Needs MySQL 8.0+ (uses REGEXP_REPLACE, window functions, recursive CTE, JSON_TABLE).
-- =====================================================================================
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
USE reviewlens;

SET SESSION collation_connection = 'utf8mb4_unicode_ci';
SET SESSION max_recursive_iterations = 5000;      -- calendar needs ~1,461 recursion steps (default is 1000)

-- a few customer names are longer than 100 chars, so widen the column
ALTER TABLE Dim_Customer MODIFY customer_name VARCHAR(255);

-- start clean
TRUNCATE TABLE Bridge_Review_Keyword; TRUNCATE TABLE Review_Text; TRUNCATE TABLE Fact_Review;
TRUNCATE TABLE Dim_Keyword; TRUNCATE TABLE Dim_Customer; TRUNCATE TABLE Dim_Product; TRUNCATE TABLE Dim_Category;
TRUNCATE TABLE Dim_Department; TRUNCATE TABLE Dim_Date; TRUNCATE TABLE Dim_Sentiment; TRUNCATE TABLE Dim_Language;
TRUNCATE TABLE Dim_ReviewLength; TRUNCATE TABLE ETL_Audit;

-- =====================================================================================
-- STEP 1  EXTRACT: land the raw CSV in a staging table, untouched
-- =====================================================================================
DROP TABLE IF EXISTS stg_raw;
CREATE TABLE stg_raw (
  src_row INT, product_id VARCHAR(40), customer_name VARCHAR(255), customer_id INT, date_str VARCHAR(30),
  rating INT, is_spam INT, review TEXT, sentiment VARCHAR(20), features TEXT
);
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/daraz_raw.csv'      -- <<< CHANGE THIS PATH
INTO TABLE stg_raw CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES
(src_row, product_id, customer_name, customer_id, date_str, rating, is_spam, review, sentiment, features);

INSERT INTO ETL_Audit (step, rows_in, rows_out, note)
SELECT 'extract', COUNT(*), COUNT(*), 'rows landed in stg_raw (expect 3923)' FROM stg_raw;

-- =====================================================================================
-- STEP 2  TRANSFORM (clean the text, derive attributes) - done in 4 small stages so each is easy to read
-- =====================================================================================

-- 2a. basic cleaning: trim, proper date, strip URLs, collapse whitespace/newlines
DROP TABLE IF EXISTS stg_t1;
CREATE TABLE stg_t1 AS
SELECT src_row + 1                                       AS review_key,       -- stable id (1..3923)
       TRIM(product_id)                                  AS product_id,
       TRIM(customer_name)                               AS customer_name,
       customer_id,
       DATE(LEFT(date_str, 10))                          AS review_date,
       rating, is_spam,
       CONCAT(UPPER(LEFT(TRIM(sentiment), 1)), LOWER(SUBSTRING(TRIM(sentiment), 2))) AS sentiment,
       features,
       TRIM(REGEXP_REPLACE(REGEXP_REPLACE(review, '(https?://|www\\.)\\S+', ' '), '\\s+', ' ')) AS review_raw
FROM stg_raw;

-- 2b. normalised text + product-code attributes
--     Roman Urdu spelling variants are mapped to one form (acha/achha/accha -> acha ...)
--     Category = characters 6-7 of Product_ID (INFERRED - validate 50 products by hand)
DROP TABLE IF EXISTS stg_t2;

CREATE TABLE stg_t2 AS
SELECT
    t.*,
    REGEXP_REPLACE(
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    LOWER(t.review_raw),
                    '\\b(achha|accha|aacha|achi|achii|acchi|achhi)\\b', 'acha'
                ),
                '\\b(bohot|boht|bahut|bht)\\b', 'bohat'
            ),
            '\\b(nhi|nai|nahin)\\b', 'nahi'
        ),
        '\\b(hy|he|h)\\b', 'hai'
    ) AS review_clean,
    IF(
        BINARY t.product_id REGEXP '^[A-Z]{2}[0-9]{3}[A-Z]{2}',
        SUBSTRING(t.product_id, 6, 2),
        'XX'
    ) AS category_code,
    IF(
        BINARY t.product_id REGEXP '^[A-Z]{2}[0-9]',
        LEFT(t.product_id, 2),
        'XX'
    ) AS brand_code
FROM stg_t1 t;

-- 2c. measures: word/char counts, duplicate flag, rating-vs-label conflict, language word-match counts
--     en_n / ur_n = how many common English / Roman Urdu words appear (each match is replaced by one marker character)
DROP TABLE IF EXISTS stg_t3;
CREATE TABLE stg_t3 AS
SELECT t.*,
       IF(t.review_clean = '', 0, CHAR_LENGTH(t.review_clean) - CHAR_LENGTH(REPLACE(t.review_clean, ' ', '')) + 1) AS word_count,
       CHAR_LENGTH(t.review_clean)                                                                                  AS char_count,
       -- the same text appearing again is FLAGGED, never deleted (different product / customer / date)
       IF(ROW_NUMBER() OVER (PARTITION BY MD5(t.review_clean) ORDER BY t.review_key) > 1, 1, 0)                     AS is_duplicate_text,
       IF((t.rating >= 4 AND t.sentiment = 'Negative') OR (t.rating <= 2 AND t.sentiment = 'Positive'), 1, 0)       AS rating_conflict,
       CHAR_LENGTH(REGEXP_REPLACE(t.review_clean,
         '\\b(the|is|are|was|were|this|that|and|with|for|not|very|good|bad|product|quality|price|delivery|fast|slow|received|order|item|nice|great|worth|money|love|excellent|awesome|best|phone|screen|battery|size|color|colour|small|big|cheap|expensive|looks|work|works|working|but|have|has|had|it|its|my|your|you)\\b', '§'))
       - CHAR_LENGTH(REPLACE(REGEXP_REPLACE(t.review_clean,
         '\\b(the|is|are|was|were|this|that|and|with|for|not|very|good|bad|product|quality|price|delivery|fast|slow|received|order|item|nice|great|worth|money|love|excellent|awesome|best|phone|screen|battery|size|color|colour|small|big|cheap|expensive|looks|work|works|working|but|have|has|had|it|its|my|your|you)\\b', '§'), '§', '')) AS en_n,
       CHAR_LENGTH(REGEXP_REPLACE(t.review_clean,
         '\\b(hai|acha|bohat|nahi|ka|ki|ke|ko|ho|hain|tha|thi|aur|lekin|bhi|mein|main|yeh|ye|woh|kya|kuch|sab|zabardast|behtareen|mujhe|pasand|cheez|dam|kharab|sahi|theek|shukriya|qeemat|miyaar|masla)\\b', '§'))
       - CHAR_LENGTH(REPLACE(REGEXP_REPLACE(t.review_clean,
         '\\b(hai|acha|bohat|nahi|ka|ki|ke|ko|ho|hain|tha|thi|aur|lekin|bhi|mein|main|yeh|ye|woh|kya|kuch|sab|zabardast|behtareen|mujhe|pasand|cheez|dam|kharab|sahi|theek|shukriya|qeemat|miyaar|masla)\\b', '§'), '§', '')) AS ur_n
FROM stg_t2 t;

-- 2d. final clean staging table: language + length band
DROP TABLE IF EXISTS stg_clean;
CREATE TABLE stg_clean AS
SELECT t.*,
       CASE WHEN t.en_n = 0 AND t.ur_n = 0 THEN 'Unknown'
            WHEN t.ur_n = 0 THEN 'English'
            WHEN t.en_n = 0 THEN 'Roman Urdu'
            WHEN t.en_n / (t.en_n + t.ur_n) > 0.7 THEN 'English'
            WHEN t.en_n / (t.en_n + t.ur_n) < 0.3 THEN 'Roman Urdu'
            ELSE 'Mixed' END                                              AS language,
       CASE WHEN t.word_count <= 8  THEN 'Short (1-8 words)'
            WHEN t.word_count <= 30 THEN 'Medium (9-30 words)'
            ELSE 'Long (31+ words)' END                                   AS length_band
FROM stg_t3 t;
DROP TABLE stg_t1; DROP TABLE stg_t2; DROP TABLE stg_t3;

INSERT INTO ETL_Audit (step, rows_in, rows_out, note)
SELECT 'transform', (SELECT COUNT(*) FROM stg_raw), COUNT(*),
       CONCAT(SUM(is_duplicate_text), ' duplicate texts flagged (none deleted); ', SUM(rating_conflict), ' rating conflicts')
FROM stg_clean;

-- =====================================================================================
-- STEP 3  LOAD DIMENSIONS (reference data first, then data-driven dimensions)
-- =====================================================================================
INSERT INTO Dim_Sentiment  VALUES (1,'Positive'),(2,'Neutral'),(3,'Negative'),(4,'Unknown');
INSERT INTO Dim_Language   VALUES (1,'English'),(2,'Roman Urdu'),(3,'Mixed'),(4,'Unknown');
INSERT INTO Dim_ReviewLength VALUES (1,'Short (1-8 words)'),(2,'Medium (9-30 words)'),(3,'Long (31+ words)');

-- snowflake hierarchy: Dim_Product -> Dim_Category -> Dim_Department  (category/department mapping is INFERRED)
INSERT INTO Dim_Department VALUES (1,'Electronics & Media'),(2,'Fashion & Beauty'),(3,'Home & Family'),(4,'Sports & Others'),(5,'Unknown');
INSERT INTO Dim_Category (category_key, category_code, category_name, department_key) VALUES
  (1,'FA','Fashion',2),(2,'HB','Health & Beauty',2),(3,'EL','Electronics',1),(4,'ME','Media & Gaming',1),
  (5,'HL','Home & Living',3),(6,'TB','Toys & Baby',3),(7,'SP','Sports & Outdoor',4),(8,'OT','Other',4),(9,'XX','Unknown',5);

-- calendar: every day from the 1st of the first review month to the end of the last review month
SET @d0 = (SELECT DATE_SUB(MIN(review_date), INTERVAL DAYOFMONTH(MIN(review_date)) - 1 DAY) FROM stg_clean);
SET @d1 = (SELECT LAST_DAY(MAX(review_date)) FROM stg_clean);
INSERT INTO Dim_Date (date_key, full_date, year, quarter, month, month_name, day, day_name, is_weekend)
WITH RECURSIVE cal (dt) AS (
  SELECT @d0 UNION ALL SELECT dt + INTERVAL 1 DAY FROM cal WHERE dt < @d1
)
SELECT DATE_FORMAT(dt, '%Y%m%d') + 0, dt, YEAR(dt), QUARTER(dt), MONTH(dt), MONTHNAME(dt), DAY(dt), DAYNAME(dt),
       IF(DAYOFWEEK(dt) IN (1, 7), 1, 0)
FROM cal;

-- products: one row per product_id; unknown category codes fall back to XX (key 9)
INSERT INTO Dim_Product (product_key, product_id, brand_code, category_key)
SELECT ROW_NUMBER() OVER (ORDER BY p.product_id), p.product_id, p.brand_code, COALESCE(c.category_key, 9)
FROM (SELECT DISTINCT product_id, brand_code, category_code FROM stg_clean) p
LEFT JOIN Dim_Category c ON c.category_code = p.category_code;

-- customers: one row per customer_id; if one id has several names keep the most frequent
INSERT INTO Dim_Customer (customer_key, customer_id, customer_name)
SELECT ROW_NUMBER() OVER (ORDER BY customer_id), customer_id, customer_name
FROM (SELECT customer_id, customer_name,
             ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY COUNT(*) DESC, customer_name) AS rn
      FROM stg_clean GROUP BY customer_id, customer_name) x
WHERE rn = 1;

-- keywords: the Features column is text like ['aram', 'pocket'].  Swap ' for " to make JSON, then split with JSON_TABLE
DROP TABLE IF EXISTS stg_kw;

CREATE TABLE stg_kw AS
SELECT DISTINCT
       review_key,
       LOWER(keyword) AS keyword
FROM(
    WITH RECURSIVE keyword_split AS (
        -- First keyword
        SELECT
            review_key,
            TRIM(
                BOTH '"' FROM
                TRIM(
                    BOTH '''' FROM
                    TRIM(SUBSTRING_INDEX(
                        TRIM(BOTH ']' FROM TRIM(BOTH '[' FROM features)),
                        ',', 1
                    ))
                )
            ) AS keyword,
            CASE
                WHEN LOCATE(',', features) > 0
                THEN SUBSTRING(
                    TRIM(BOTH ']' FROM TRIM(BOTH '[' FROM features)),
                    LOCATE(',', TRIM(BOTH ']' FROM TRIM(BOTH '[' FROM features))) + 1
                )
                ELSE ''
            END AS remaining
        FROM stg_clean
        WHERE features IS NOT NULL
          AND TRIM(features) NOT IN ('', '[]')
      UNION ALL
        -- Extract remaining keywords
        SELECT
            review_key,
            TRIM(
                BOTH '"' FROM
                TRIM(
                    BOTH '''' FROM
                    TRIM(SUBSTRING_INDEX(remaining, ',', 1))
                )
            ),
            CASE
                WHEN LOCATE(',', remaining) > 0
                THEN SUBSTRING(remaining, LOCATE(',', remaining) + 1)
                ELSE ''
            END
        FROM keyword_split
        WHERE remaining <> ''
    )
    SELECT review_key, keyword
    FROM keyword_split
) AS extracted
WHERE keyword <> '';

INSERT INTO Dim_Keyword (keyword_key, keyword)
SELECT ROW_NUMBER() OVER (ORDER BY keyword), keyword FROM (SELECT DISTINCT keyword FROM stg_kw) k;

-- =====================================================================================
-- STEP 4  LOAD FACT, BRIDGE AND TEXT (dimensions must exist first)
-- =====================================================================================
INSERT INTO Fact_Review (review_key, date_key, product_key, customer_key, sentiment_key, language_key, length_key,rating, is_spam,
      rating_conflict, is_duplicate_text, word_count, char_count)
SELECT s.review_key, DATE_FORMAT(s.review_date, '%Y%m%d') + 0, p.product_key, c.customer_key,
      COALESCE(se.sentiment_key, 4), l.language_key, ln.length_key,
      s.rating, s.is_spam, s.rating_conflict, s.is_duplicate_text, s.word_count, s.char_count
FROM stg_clean s
JOIN Dim_Product      p  ON p.product_id = s.product_id
JOIN Dim_Customer     c  ON c.customer_id = s.customer_id
LEFT JOIN Dim_Sentiment se ON se.sentiment_label = s.sentiment
JOIN Dim_Language     l  ON l.language_name = s.language
JOIN Dim_ReviewLength ln ON ln.length_band = s.length_band;

INSERT INTO Bridge_Review_Keyword (review_key, keyword_key)
SELECT w.review_key, d.keyword_key FROM stg_kw w JOIN Dim_Keyword d ON d.keyword = w.keyword;

INSERT INTO Review_Text (review_key, review_raw, review_clean)
SELECT review_key, review_raw, review_clean FROM stg_clean;

INSERT INTO ETL_Audit (step, rows_in, rows_out, note)
SELECT 'load fact', (SELECT COUNT(*) FROM stg_clean), COUNT(*), 'rows in Fact_Review - must equal rows in (no row lost in joins)' FROM Fact_Review;

-- =====================================================================================
-- STEP 5  QUICK SELF-CHECK (full checks are in 03_checks.sql)
-- Expected: Fact 3923 | Product 1066 | Customer 2787 | Date 1461 | Keyword 2462 | Bridge 20099
-- If Fact_Review has FEWER rows than stg_clean, a join failed - the audit table will show it.
-- =====================================================================================
SELECT 'Fact_Review' AS tbl, COUNT(*) AS n FROM Fact_Review
UNION ALL SELECT 'Dim_Product', COUNT(*) FROM Dim_Product
UNION ALL SELECT 'Dim_Customer', COUNT(*) FROM Dim_Customer
UNION ALL SELECT 'Dim_Date', COUNT(*) FROM Dim_Date
UNION ALL SELECT 'Dim_Keyword', COUNT(*) FROM Dim_Keyword
UNION ALL SELECT 'Bridge_Review_Keyword', COUNT(*) FROM Bridge_Review_Keyword;
SELECT * FROM ETL_Audit;
