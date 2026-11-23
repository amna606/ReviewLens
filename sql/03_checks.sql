-- ReviewLens - Part 1: post-load validation. Every query below should return what the comment says.
USE reviewlens;

-- 1. Row counts (expect: Fact 3923, Product 1066, Customer 2787, Date 1461, Keyword 2462, Bridge 20099)
SELECT 'Fact_Review' t, COUNT(*) n FROM Fact_Review UNION ALL SELECT 'Dim_Product', COUNT(*) FROM Dim_Product
UNION ALL SELECT 'Dim_Customer', COUNT(*) FROM Dim_Customer UNION ALL SELECT 'Dim_Date', COUNT(*) FROM Dim_Date
UNION ALL SELECT 'Dim_Keyword', COUNT(*) FROM Dim_Keyword UNION ALL SELECT 'Bridge_Review_Keyword', COUNT(*) FROM Bridge_Review_Keyword;

-- 2. Orphan checks = referential integrity (every query must return 0)
SELECT COUNT(*) orphan_date      FROM Fact_Review f LEFT JOIN Dim_Date d      ON f.date_key=d.date_key           WHERE d.date_key IS NULL;
SELECT COUNT(*) orphan_product   FROM Fact_Review f LEFT JOIN Dim_Product p   ON f.product_key=p.product_key     WHERE p.product_key IS NULL;
SELECT COUNT(*) orphan_customer  FROM Fact_Review f LEFT JOIN Dim_Customer c  ON f.customer_key=c.customer_key   WHERE c.customer_key IS NULL;
SELECT COUNT(*) orphan_sentiment FROM Fact_Review f LEFT JOIN Dim_Sentiment s ON f.sentiment_key=s.sentiment_key WHERE s.sentiment_key IS NULL;
SELECT COUNT(*) orphan_language  FROM Fact_Review f LEFT JOIN Dim_Language l  ON f.language_key=l.language_key   WHERE l.language_key IS NULL;
SELECT COUNT(*) orphan_category  FROM Dim_Product p LEFT JOIN Dim_Category c  ON p.category_key=c.category_key   WHERE c.category_key IS NULL;
SELECT COUNT(*) orphan_dept      FROM Dim_Category c LEFT JOIN Dim_Department d ON c.department_key=d.department_key WHERE d.department_key IS NULL;
SELECT COUNT(*) orphan_bridge    FROM Bridge_Review_Keyword b LEFT JOIN Fact_Review f ON b.review_key=f.review_key WHERE f.review_key IS NULL;

-- 3. Hierarchy works end to end (snowflake joins): reviews per department > category
SELECT dp.department_name, c.category_name, COUNT(*) reviews
FROM Fact_Review f JOIN Dim_Product p ON f.product_key=p.product_key
JOIN Dim_Category c ON p.category_key=c.category_key JOIN Dim_Department dp ON c.department_key=dp.department_key
GROUP BY dp.department_name, c.category_name ORDER BY reviews DESC;

-- 4. Text survived the load (Roman Urdu / emojis): eyeball 5 rows
SELECT review_key, LEFT(review_raw,60) FROM Review_Text ORDER BY review_key LIMIT 5;
