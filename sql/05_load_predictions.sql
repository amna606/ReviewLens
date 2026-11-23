-- ReviewLens - Part 1: take Part 2's output and write it into the warehouse (run when they hand over predictions.csv)
-- Run this BEFORE sql/08_stream_setup.sql, and run it AGAIN after the stream demo so the streamed reviews are scored too.
-- predictions.csv columns (agreed): review_key,predicted_label,confidence,mismatch_flag,trust_score
USE reviewlens;
TRUNCATE TABLE stg_predictions;
USE reviewlens;

CREATE TABLE IF NOT EXISTS stg_predictions (
    review_key INT PRIMARY KEY,
    predicted_label VARCHAR(20),
    confidence DECIMAL(5,4),
    mismatch_flag TINYINT,
    trust_score DECIMAL(5,4)
);
SHOW TABLES LIKE 'stg_predictions';
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/predictions.csv' INTO TABLE stg_predictions CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES
 (review_key, predicted_label, confidence, mismatch_flag, @trust)
 SET trust_score = NULLIF(NULLIF(@trust, ''), 'NULL');      -- trust_score is NULL until the fuzzy trust score is built

UPDATE Fact_Review f JOIN stg_predictions s ON f.review_key = s.review_key
SET f.predicted_label=s.predicted_label, f.confidence=s.confidence, f.mismatch_flag=s.mismatch_flag, f.trust_score=s.trust_score;

SELECT COUNT(*) AS scored, (SELECT COUNT(*) FROM Fact_Review) AS total FROM Fact_Review WHERE predicted_label IS NOT NULL;  -- expect scored = total
INSERT INTO ETL_Audit (step,rows_in,rows_out,note) SELECT 'load predictions', COUNT(*), SUM(predicted_label IS NOT NULL), 'Part 2 output merged' FROM Fact_Review;
