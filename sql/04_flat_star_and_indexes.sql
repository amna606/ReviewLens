-- ReviewLens - Part 1: build the FLAT star copy and the indexes for the 4-way experiment.
-- Experiment grid:   A = flat star, no indexes   B = flat star + indexes
--                    C = snowflake, no indexes   D = snowflake + indexes
-- Run section 1 once. Run the timed queries (Part 3) BEFORE section 2 (A, C), then run section 2 and repeat (B, D).
USE reviewlens;

-- ===== SECTION 1: flat dimension (department folded into product). The fact table is shared. =====
DROP TABLE IF EXISTS Dim_Product_Flat;
CREATE TABLE Dim_Product_Flat AS
SELECT p.product_key, p.product_id, p.brand_code, c.category_key, c.category_name, d.department_key, d.department_name
FROM Dim_Product p JOIN Dim_Category c ON p.category_key=c.category_key JOIN Dim_Department d ON c.department_key=d.department_key;
ALTER TABLE Dim_Product_Flat ADD PRIMARY KEY (product_key);   -- PK only: still no secondary indexes

-- ===== SECTION 1b: a scaled-up fact table (100 copies = about 392,000 rows) =====
-- With only 3,923 real rows every query takes a millisecond or two and indexes barely matter. A bigger copy makes the
-- difference visible. Run this BEFORE section 2 (CREATE TABLE ... LIKE would otherwise copy the indexes too).
DROP TABLE IF EXISTS Fact_Review_Big;
CREATE TABLE Fact_Review_Big LIKE Fact_Review;
INSERT INTO Fact_Review_Big (review_key, date_key, product_key, customer_key, sentiment_key, language_key, length_key,
                             rating, is_spam, rating_conflict, is_duplicate_text, word_count, char_count)
SELECT f.review_key + n.k * 100000, f.date_key, f.product_key, f.customer_key, f.sentiment_key, f.language_key, f.length_key,
       f.rating, f.is_spam, f.rating_conflict, f.is_duplicate_text, f.word_count, f.char_count
FROM Fact_Review f
JOIN (SELECT a.d + 10 * b.d AS k
      FROM (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
      CROSS JOIN
           (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b) n;
SELECT COUNT(*) AS big_rows FROM Fact_Review_Big;      -- expect 392300

-- ===== SECTION 2: secondary indexes (apply AFTER measuring A and C) =====
CREATE INDEX ix_fact_date      ON Fact_Review (date_key);
CREATE INDEX ix_fact_product   ON Fact_Review (product_key);
CREATE INDEX ix_fact_customer  ON Fact_Review (customer_key);
CREATE INDEX ix_fact_sentiment ON Fact_Review (sentiment_key);
CREATE INDEX ix_fact_language  ON Fact_Review (language_key);
CREATE INDEX ix_fact_lang_sent ON Fact_Review (language_key, sentiment_key);   -- composite for the common slice
CREATE INDEX ix_prod_category  ON Dim_Product (category_key);
CREATE INDEX ix_cat_dept       ON Dim_Category (department_key);
CREATE INDEX ix_bridge_review  ON Bridge_Review_Keyword (review_key, keyword_key);
CREATE INDEX ix_bridge_keyword ON Bridge_Review_Keyword (keyword_key, review_key);
CREATE UNIQUE INDEX ux_keyword ON Dim_Keyword (keyword);
CREATE UNIQUE INDEX ux_product_id ON Dim_Product (product_id);
CREATE UNIQUE INDEX ux_customer_id ON Dim_Customer (customer_id);   -- needed by the semi-stream join (probe by customer_id)
CREATE INDEX ix_pflat_cat      ON Dim_Product_Flat (category_key);
-- the same indexes on the scaled-up fact table
CREATE INDEX ix_big_date      ON Fact_Review_Big (date_key);
CREATE INDEX ix_big_product   ON Fact_Review_Big (product_key);
CREATE INDEX ix_big_customer  ON Fact_Review_Big (customer_key);
CREATE INDEX ix_big_sentiment ON Fact_Review_Big (sentiment_key);
CREATE INDEX ix_big_language  ON Fact_Review_Big (language_key);
CREATE INDEX ix_big_lang_sent ON Fact_Review_Big (language_key, sentiment_key);

-- ===== Storage report (run after each section; paste into your results table) =====
SELECT table_name, ROUND(data_length/1024,1) data_kb, ROUND(index_length/1024,1) index_kb
FROM information_schema.tables WHERE table_schema='reviewlens' ORDER BY data_length DESC;
