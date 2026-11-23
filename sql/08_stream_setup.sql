-- ReviewLens - Part 1: prepare the semi-stream join demo.
-- Takes every 10th review (about 10%) OUT of the warehouse and parks it in stream_source, to be fed back in by
-- etl/semi_stream_join.py as if it were arriving live.  Run AFTER 02_etl_in_mysql.sql and AFTER the indexes (04, section 2).
USE reviewlens;

DROP TABLE IF EXISTS stream_source;
CREATE TABLE stream_source AS SELECT * FROM stg_clean WHERE MOD(review_key, 10) = 0;

DELETE b FROM Bridge_Review_Keyword b JOIN stream_source s ON b.review_key = s.review_key;
DELETE t FROM Review_Text           t JOIN stream_source s ON t.review_key = s.review_key;
DELETE f FROM Fact_Review           f JOIN stream_source s ON f.review_key = s.review_key;

SELECT (SELECT COUNT(*) FROM stream_source) AS waiting_in_stream, (SELECT COUNT(*) FROM Fact_Review) AS in_warehouse;
-- expect roughly 392 waiting and 3,531 in the warehouse (they add up to 3,923)
