-- ReviewLens - Part 1: summary (aggregate) table. MySQL has no materialized views, so we build one by hand.
-- Idea: pre-compute the heavy GROUP BY once; dashboards and reports then read a few hundred rows instead of re-joining the fact.
USE reviewlens;

DROP TABLE IF EXISTS Summary_Sentiment;
CREATE TABLE Summary_Sentiment AS
SELECT dp.department_name, c.category_name, d.year, l.language_name, s.sentiment_label,
       COUNT(*)                   AS reviews,
       SUM(f.is_spam)             AS spam_reviews,
       SUM(f.rating_conflict)     AS rating_conflicts,
       ROUND(AVG(f.rating), 2)    AS avg_rating
FROM Fact_Review f
JOIN Dim_Product p      ON f.product_key   = p.product_key
JOIN Dim_Category c     ON p.category_key  = c.category_key
JOIN Dim_Department dp  ON c.department_key = dp.department_key
JOIN Dim_Date d         ON f.date_key      = d.date_key
JOIN Dim_Language l     ON f.language_key  = l.language_key
JOIN Dim_Sentiment s    ON f.sentiment_key = s.sentiment_key
GROUP BY dp.department_name, c.category_name, d.year, l.language_name, s.sentiment_label;

CREATE INDEX ix_sum_dept_cat ON Summary_Sentiment (department_name, category_name);

-- Refresh = rebuild. Call this after new reviews are loaded (e.g. after the stream demo).
DROP PROCEDURE IF EXISTS refresh_summary_sentiment;
DELIMITER //
CREATE PROCEDURE refresh_summary_sentiment()
BEGIN
  TRUNCATE TABLE Summary_Sentiment;
  INSERT INTO Summary_Sentiment
  SELECT dp.department_name, c.category_name, d.year, l.language_name, s.sentiment_label,
         COUNT(*), SUM(f.is_spam), SUM(f.rating_conflict), ROUND(AVG(f.rating), 2)
  FROM Fact_Review f
  JOIN Dim_Product p      ON f.product_key   = p.product_key
  JOIN Dim_Category c     ON p.category_key  = c.category_key
  JOIN Dim_Department dp  ON c.department_key = dp.department_key
  JOIN Dim_Date d         ON f.date_key      = d.date_key
  JOIN Dim_Language l     ON f.language_key  = l.language_key
  JOIN Dim_Sentiment s    ON f.sentiment_key = s.sentiment_key
  GROUP BY dp.department_name, c.category_name, d.year, l.language_name, s.sentiment_label;
END//
DELIMITER ;

SELECT COUNT(*) AS summary_rows, SUM(reviews) AS reviews_covered FROM Summary_Sentiment;   -- reviews_covered must equal Fact_Review rows

ANALYZE TABLE Fact_Review_Big, Fact_Review, Dim_Product, Dim_Category, Dim_Department, Dim_Product_Flat, Dim_Date, Dim_Language, Dim_Sentiment;
SHOW INDEX FROM Fact_Review_Big;

SHOW FULL PROCESSLIST;

SELECT COUNT(*) FROM reviewlens.Fact_Review_Big;