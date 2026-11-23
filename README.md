# ReviewLens: A Sentiment Analytics Data Warehouse for Daraz Product Reviews

A university project for **Data Analysis & Visualization (DAV)** and **Data Warehousing & Business Intelligence (DWBI)**, FAST-NUCES Karachi.

ReviewLens turns 3,923 Daraz product reviews into a star-schema data warehouse in MySQL, adds a sentiment model and part-of-speech (POS) analysis for Roman Urdu text, measures how indexing and summary tables change query speed, and feeds a Power BI dashboard.

**Authors:** Amna Syed, Amna Baig, Usman Wasti

---

## Dataset

"Daraz Labelled Review Dataset with Sentiments and Features": 3,923 reviews, 1 Feb 2016 to 31 Jan 2020.

| Column | Meaning |
| --- | --- |
| product_id, customer_id, customer_name | Who reviewed what |
| date, rating | When, and the 1 to 5 stars |
| is_spam | Spam flag from the dataset |
| review | Review text, about 89% Roman Urdu (looks machine-translated) |
| sentiment | Dataset label: Positive, Neutral, Negative |
| features | Keyword list for the review |

The dataset has no category column. A department and category are inferred from characters 6 and 7 of the Product_ID and were checked by hand on 50 products (see `data/category_check_sample.csv`).

---

## What was built

1. **Data warehouse (MySQL 8).** One row per review in `Fact_Review`. Dimensions for date, product (product, category, department snowflake), customer, sentiment, language and review length. A bridge table links reviews to keywords. Duplicate texts are flagged, not deleted. Each ETL step is logged in `ETL_Audit`.
2. **ETL in SQL.** CSV to staging tables to cleaned data to dimensions and facts, using window functions, a recursive CTE, `JSON_TABLE` and `LOAD DATA`. A Python version gives the same counts and is included as an alternative.
3. **Sentiment model.** TF-IDF (word and character n-grams) with Logistic Regression: about 78.5% accuracy and a macro F1 of about 0.72. Linear SVM scored about the same; Naive Bayes was clearly lower. Each review is predicted by a model that never saw it, and reviews where the prediction disagrees with the dataset label get `mismatch_flag = 1` (867 reviews, 22.1%).
4. **POS tagging and aspects.** NLTK only handles English, so a Roman Urdu word lexicon was built and NLTK is used as a fallback. Noun, adjective, verb and pronoun counts are stored per review, and adjective and noun pairs (with negation) show which product aspects customers complain about.
5. **Performance experiments.** Flat star versus snowflake, with and without indexes, on the real table (3,923 rows) and on a scaled copy (392,300 rows), plus a summary table that stands in for a materialised view.
6. **Semi-stream join.** Held-back reviews arrive in micro-batches and are joined to the indexed dimension tables (an index nested-loop join).
7. **Power BI dashboard.** Built on the warehouse tables (see the `dashboard/` folder).

---

## Warehouse tables

| Table | Rows |
| --- | --- |
| Fact_Review | 3,923 |
| Dim_Product | 1,066 |
| Dim_Customer | 2,787 |
| Dim_Date | 1,461 |
| Dim_Keyword | 2,462 |
| Bridge_Review_Keyword | 20,099 |
| Review_POS | 3,923 |
| Review_AspectOpinion | 4,379 |

Other tables: Dim_Category, Dim_Department, Dim_Sentiment, Dim_Language, Dim_ReviewLength, Review_Text, Summary_Sentiment, ETL_Audit.

No foreign-key constraints are declared on purpose. MySQL silently indexes every foreign key, which would spoil the no-index baseline in the performance test. Integrity is checked with orphan-row queries in `sql/03_checks.sql`.

---

## Key results

**Sentiment model** (held-out reviews): accuracy about 78.5%, macro F1 about 0.72. Neutral is the hardest class. Mismatch rate by dataset label: Negative 27.3%, Neutral 41.0%, Positive 15.4%. 119 reviews are high-confidence disagreements, and many look like label errors.

**Query performance** (one laptop, default memory settings):

| Setting | Result |
| --- | --- |
| 3,923 rows, with indexes | Selective query Q4: 4.1 ms to 2.1 ms. Large roll-up Q1: 29 ms to 50 ms (slower). |
| 392,300 rows, no indexes | Q1 about 8.6 s, Q4 about 1.2 s |
| 392,300 rows, with indexes | Slower than without (Q1 about 90 s, single run). Likely cause: a small InnoDB buffer pool, so index lookups go to disk. |
| Summary table | Same question as Q1 in about 2 to 3 ms in every run |

Takeaway: indexes help selective queries, they do not help queries that read most of the table, and a pre-aggregated summary table was fastest in every test. The result files are in `docs/`.

---

## Repository structure

```
reviewlens/
  data/        Source CSVs, predictions, POS outputs, warehouse CSVs, Roman Urdu lexicon
  docs/        Charts and benchmark results
  etl/         xlsx_to_csv.py, transform_python_alternative.py, benchmark.py, semi_stream_join.py, db_connect.py
  notebooks/   eda.ipynb, 02_sentiment_model.ipynb, 03_pos_tagging.ipynb
  sql/         01 to 09 SQL scripts (schema, ETL, checks, indexes, summary tables, queries, stream, POS)
  dashboard/   Power BI file
```

---

## How to run it

Requirements: Python 3.10+, MySQL 8, `pip install -r requirements.txt`.

1. Put the Daraz xlsx in `data/` and run `python etl/xlsx_to_csv.py`.
2. In MySQL: `SET GLOBAL local_infile = 1;`
3. Run `sql/01_schema.sql`, then `sql/02_etl_in_mysql.sql` (edit the CSV path first), then `sql/03_checks.sql`.
4. Run `notebooks/02_sentiment_model.ipynb`, then `sql/05_load_predictions.sql`.
5. Run `notebooks/03_pos_tagging.ipynb` (needs `pip install nltk`), then `sql/09_load_pos.sql`.
6. Performance: `sql/04_flat_star_and_indexes.sql` (Section 1 and 1b), `sql/06_summary_table.sql`, `sql/06b_summary_table_big.sql`, then `python etl/benchmark.py --label no_index`, apply the indexes (Section 2), and run it again with `--label with_index`.
7. Semi-stream join: `sql/08_stream_setup.sql`, then `python etl/semi_stream_join.py --batch 50 --delay 1`.
8. Test the Python connection: set `MYSQL_PWD` to your MySQL password, then `python etl/db_connect.py`.

The scripts expect MySQL on `localhost:3306` and take `--password`. The password is never stored in the repo.

---

## Limitations

- Sentiment labels are noisy: the label disagrees with the star rating in roughly one review in seven.
- Category is inferred from the Product_ID and language is a word-list guess, so both are approximate.
- Reviews are Roman Urdu and look machine-translated, which limits any language model.
- The Roman Urdu POS lexicon is hand-checked but small (the 450 most frequent words).
- Dependency parsing is not possible for Roman Urdu. Adjective and noun pairs plus a network graph are used instead.
- The `trust_score` column exists in `Fact_Review` but is not populated.
- Performance numbers come from one laptop with default MySQL memory settings, and the last big-table run was a single measurement.

## Tech

MySQL 8, Python (pandas, scikit-learn, NLTK, matplotlib, seaborn, networkx), Jupyter, Power BI.