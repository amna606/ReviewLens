-- FALLBACK ONLY: use this if sql/02_etl_in_mysql.sql fails and you ran  python etl/transform_python_alternative.py  instead.
-- (That route does NOT create stg_clean, so the semi-stream demo (step 26) needs the SQL ETL.)
-- ReviewLens - Part 1: load the CSVs produced by etl/transform.py
-- Edit the path below: it must be the folder that holds data/warehouse_csv (use forward slashes on Windows).
-- Connect with:  mysql --local-infile=1 -u root -p reviewlens
-- If you get "LOAD DATA LOCAL INFILE is disabled":  SET GLOBAL local_infile = 1;  (needs an admin user)
USE reviewlens;

-- ORDER MATTERS: dimensions first, then fact, then bridge. Same FIELDS clause everywhere.
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Dim_Date.csv'          INTO TABLE Dim_Date          CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Dim_Department.csv'    INTO TABLE Dim_Department    CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Dim_Category.csv'      INTO TABLE Dim_Category      CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Dim_Product.csv'       INTO TABLE Dim_Product       CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Dim_Customer.csv'      INTO TABLE Dim_Customer      CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Dim_Sentiment.csv'     INTO TABLE Dim_Sentiment     CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Dim_Language.csv'      INTO TABLE Dim_Language      CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Dim_ReviewLength.csv'  INTO TABLE Dim_ReviewLength  CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Dim_Keyword.csv'       INTO TABLE Dim_Keyword       CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;

-- Fact: list columns explicitly so the 4 Part-2 columns stay NULL
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Fact_Review.csv'       INTO TABLE Fact_Review       CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES
 (review_key,date_key,product_key,customer_key,sentiment_key,language_key,length_key,rating,is_spam,rating_conflict,is_duplicate_text,word_count,char_count);
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Bridge_Review_Keyword.csv' INTO TABLE Bridge_Review_Keyword CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/Review_Text.csv'       INTO TABLE Review_Text       CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE 'D:/5th Semester/Data Analysis And Visualization/reviewlens/data/warehouse_csv/ETL_Audit.csv'         INTO TABLE ETL_Audit         CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES (step,rows_in,rows_out,note);
