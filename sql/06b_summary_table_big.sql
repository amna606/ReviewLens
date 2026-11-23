-- ReviewLens - summary table built from the scaled-up fact (only for the benchmark on Fact_Review_Big).
-- (original header:) summary (aggregate) table. MySQL has no materialized views, so we build one by hand.
-- Idea: pre-compute the heavy GROUP BY once; dashboards and reports then read a few hundred rows instead of re-joining the fact.
USE reviewlens;

DROP TABLE IF EXISTS Summary_Sentiment_Big;
CREATE TABLE Summary_Sentiment_Big AS
SELECT dp.department_name, c.category_name, d.year, l.language_name, s.sentiment_label,
       COUNT(*)                   AS reviews,
       SUM(f.is_spam)             AS spam_reviews,
       SUM(f.rating_conflict)     AS rating_conflicts,
       ROUND(AVG(f.rating), 2)    AS avg_rating
FROM Fact_Review_Big f
JOIN Dim_Product p      ON f.product_key   = p.product_key
JOIN Dim_Category c     ON p.category_key  = c.category_key
JOIN Dim_Department dp  ON c.department_key = dp.department_key
JOIN Dim_Date d         ON f.date_key      = d.date_key
JOIN Dim_Language l     ON f.language_key  = l.language_key
JOIN Dim_Sentiment s    ON f.sentiment_key = s.sentiment_key
GROUP BY dp.department_name, c.category_name, d.year, l.language_name, s.sentiment_label;

CREATE INDEX ix_sumbig_dept_cat ON Summary_Sentiment_Big (department_name, category_name);

