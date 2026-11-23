-- ReviewLens - load the POS-tagging results (from notebooks/03_pos_tagging.ipynb) into the warehouse.
-- Edit the two paths (forward slashes). Needs: data/pos_features.csv and data/aspect_opinion_pairs.csv
USE reviewlens;

DROP TABLE IF EXISTS Review_POS;
CREATE TABLE Review_POS (                       -- one row per review: how many nouns / adjectives / verbs / pronouns
  review_key INT PRIMARY KEY, token_count INT, noun_count INT, adj_count INT, verb_count INT, pron_count INT
);
DROP TABLE IF EXISTS Review_AspectOpinion;
CREATE TABLE Review_AspectOpinion (             -- many rows per review: which noun (aspect) an adjective (opinion) describes
  review_key INT NOT NULL, aspect VARCHAR(60) NOT NULL, opinion VARCHAR(60) NOT NULL, negated TINYINT NOT NULL
);

LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/pos_features.csv' INTO TABLE Review_POS CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/aspect_opinion_pairs.csv' INTO TABLE Review_AspectOpinion CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;

CREATE INDEX ix_ao_review ON Review_AspectOpinion (review_key);
CREATE INDEX ix_ao_aspect ON Review_AspectOpinion (aspect);

SELECT (SELECT COUNT(*) FROM Review_POS) AS review_rows, (SELECT COUNT(*) FROM Review_AspectOpinion) AS pair_rows;   -- expect 3923 and about 2,700

-- OLAP query 6: which aspects do customers complain about most? (aspect x sentiment, from the warehouse)
SELECT ao.aspect, COUNT(*) AS mentions,
       SUM(s.sentiment_label = 'Negative') AS in_negative_reviews,
       ROUND(100 * SUM(s.sentiment_label = 'Negative') / COUNT(*), 1) AS negative_pct
FROM Review_AspectOpinion ao
JOIN Fact_Review f   ON f.review_key = ao.review_key
JOIN Dim_Sentiment s ON s.sentiment_key = f.sentiment_key
GROUP BY ao.aspect HAVING COUNT(*) >= 40 ORDER BY negative_pct DESC;

-- OLAP query 7: the same, rolled up by department > category (drill-down on the snowflake)
SELECT dp.department_name, c.category_name, ao.aspect, COUNT(*) AS mentions,
       ROUND(100 * SUM(s.sentiment_label = 'Negative') / COUNT(*), 1) AS negative_pct
FROM Review_AspectOpinion ao
JOIN Fact_Review f      ON f.review_key = ao.review_key
JOIN Dim_Sentiment s    ON s.sentiment_key = f.sentiment_key
JOIN Dim_Product p      ON p.product_key = f.product_key
JOIN Dim_Category c     ON c.category_key = p.category_key
JOIN Dim_Department dp  ON dp.department_key = c.department_key
WHERE ao.aspect IN ('quality', 'size', 'price', 'packing', 'delivery')
GROUP BY dp.department_name, c.category_name, ao.aspect WITH ROLLUP;

SELECT 'Fact_Review', COUNT(*) FROM Fact_Review
UNION ALL SELECT 'Dim_Product', COUNT(*) FROM Dim_Product
UNION ALL SELECT 'Dim_Customer', COUNT(*) FROM Dim_Customer
UNION ALL SELECT 'Dim_Keyword', COUNT(*) FROM Dim_Keyword
UNION ALL SELECT 'Bridge', COUNT(*) FROM Bridge_Review_Keyword
UNION ALL SELECT 'Review_POS', COUNT(*) FROM Review_POS
UNION ALL SELECT 'AspectOpinion', COUNT(*) FROM Review_AspectOpinion
UNION ALL SELECT 'scored (predictions)', COUNT(*) FROM Fact_Review WHERE predicted_label IS NOT NULL
UNION ALL SELECT 'summary rows', COUNT(*) FROM Summary_Sentiment
UNION ALL SELECT 'Fact_Review_Big', COUNT(*) FROM Fact_Review_Big;