-- ReviewLens - Part 1: warehouse schema (MySQL 8)
-- Run:  mysql --local-infile=1 -u root -p < sql/01_schema.sql
-- Design notes (say these in the viva):
--  * Grain of Fact_Review = ONE REVIEW.
--  * Snowflake: Dim_Product -> Dim_Category -> Dim_Department.
--  * Bridge_Review_Keyword = many-to-many (a review has many keywords, a keyword many reviews).
--  * FOREIGN KEY constraints are deliberately NOT declared. InnoDB silently creates an index for every FK,
--    which would ruin the "before indexing" baseline in the indexing experiment. Integrity is verified with
--    the orphan checks in sql/05_checks.sql instead (common DW practice: validate in ETL, not per insert).

DROP DATABASE IF EXISTS reviewlens;
CREATE DATABASE reviewlens CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE reviewlens;

-- ---------- staging (raw landing area for the ETL story: CSV -> staging -> warehouse) ----------
CREATE TABLE stg_reviews (
  review_key INT, review_clean TEXT, sentiment VARCHAR(20), rating INT, is_spam INT, language VARCHAR(20)
);  -- loaded from data/reviews_for_nlp.csv

-- ---------- dimensions ----------
CREATE TABLE Dim_Date (
  date_key INT PRIMARY KEY, full_date DATE NOT NULL, year SMALLINT, quarter TINYINT, month TINYINT,
  month_name VARCHAR(12), day TINYINT, day_name VARCHAR(12), is_weekend TINYINT
);
CREATE TABLE Dim_Department (department_key INT PRIMARY KEY, department_name VARCHAR(40) NOT NULL);
CREATE TABLE Dim_Category (
  category_key INT PRIMARY KEY, category_code CHAR(2) NOT NULL, category_name VARCHAR(40) NOT NULL,
  department_key INT NOT NULL            -- snowflake link -> Dim_Department
);
CREATE TABLE Dim_Product (
  product_key INT PRIMARY KEY, product_id VARCHAR(30) NOT NULL, brand_code CHAR(2),
  category_key INT NOT NULL              -- snowflake link -> Dim_Category
);
CREATE TABLE Dim_Customer (customer_key INT PRIMARY KEY, customer_id INT NOT NULL, customer_name VARCHAR(255));
CREATE TABLE Dim_Sentiment (sentiment_key INT PRIMARY KEY, sentiment_label VARCHAR(20) NOT NULL);
CREATE TABLE Dim_Language (language_key INT PRIMARY KEY, language_name VARCHAR(20) NOT NULL);
CREATE TABLE Dim_ReviewLength (length_key INT PRIMARY KEY, length_band VARCHAR(30) NOT NULL);
CREATE TABLE Dim_Keyword (keyword_key INT PRIMARY KEY, keyword VARCHAR(100) NOT NULL);

-- ---------- fact + bridge + text ----------
CREATE TABLE Fact_Review (
  review_key INT PRIMARY KEY,
  date_key INT NOT NULL, product_key INT NOT NULL, customer_key INT NOT NULL,
  sentiment_key INT NOT NULL, language_key INT NOT NULL, length_key INT NOT NULL,
  rating TINYINT NOT NULL, is_spam TINYINT NOT NULL, rating_conflict TINYINT NOT NULL,
  is_duplicate_text TINYINT NOT NULL, word_count INT NOT NULL, char_count INT NOT NULL,
  -- filled later from Part 2 (NLP + fuzzy logic); NULL until then
  predicted_label VARCHAR(20) NULL, confidence DECIMAL(5,4) NULL,
  mismatch_flag TINYINT NULL, trust_score DECIMAL(5,4) NULL
);
CREATE TABLE Bridge_Review_Keyword (review_key INT NOT NULL, keyword_key INT NOT NULL);
CREATE TABLE Review_Text (review_key INT PRIMARY KEY, review_raw TEXT, review_clean TEXT);  -- kept out of the fact on purpose (keeps the fact narrow)
CREATE TABLE ETL_Audit (step VARCHAR(40), rows_in INT, rows_out INT, note VARCHAR(200), run_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);

-- ---------- hand-off table from Part 2 ----------
CREATE TABLE stg_predictions (
  review_key INT PRIMARY KEY, predicted_label VARCHAR(20), confidence DECIMAL(5,4),
  mismatch_flag TINYINT, trust_score DECIMAL(5,4)
);

SELECT VERSION();