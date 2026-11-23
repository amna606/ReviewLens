"""
ReviewLens - Part 1: indexing experiment runner.
Times the same OLAP queries on the SNOWFLAKE schema and on the FLAT star copy, and records table sizes.
Run it TWICE and compare:
    python etl/benchmark.py --label no_index      (before running section 2 of 04_flat_star_and_indexes.sql)
    python etl/benchmark.py --label with_index    (after)
Add  --fact Fact_Review_Big  to run the same test on the 392,000-row copy (differences are much clearer there).
Results are saved in docs/benchmark_<label>.csv and docs/storage_<label>.csv  (paste them into your report).
Needs: pip install pymysql
    python etl/benchmark.py --dump-sql      writes sql/07_benchmark_queries.sql (same queries, for Workbench / EXPLAIN)
"""
import argparse, csv, getpass, statistics, time
from pathlib import Path

# Each entry: name -> (snowflake_sql, flat_sql).  Where flat_sql is None the query does not touch the hierarchy (control).
Q = {}
Q["Q1 roll-up: sentiment by department > category"] = (
"""SELECT dp.department_name, c.category_name, s.sentiment_label, COUNT(*) AS reviews
FROM Fact_Review f
JOIN Dim_Product p ON f.product_key = p.product_key
JOIN Dim_Category c ON p.category_key = c.category_key
JOIN Dim_Department dp ON c.department_key = dp.department_key
JOIN Dim_Sentiment s ON f.sentiment_key = s.sentiment_key
GROUP BY dp.department_name, c.category_name, s.sentiment_label WITH ROLLUP""",
"""SELECT p.department_name, p.category_name, s.sentiment_label, COUNT(*) AS reviews
FROM Fact_Review f
JOIN Dim_Product_Flat p ON f.product_key = p.product_key
JOIN Dim_Sentiment s ON f.sentiment_key = s.sentiment_key
GROUP BY p.department_name, p.category_name, s.sentiment_label WITH ROLLUP""")

Q["Q2 drill-down: negative share by category and year"] = (
"""SELECT c.category_name, d.year, COUNT(*) AS reviews,
       SUM(s.sentiment_label = 'Negative') AS negatives,
       ROUND(100 * SUM(s.sentiment_label = 'Negative') / COUNT(*), 1) AS negative_pct
FROM Fact_Review f
JOIN Dim_Date d ON f.date_key = d.date_key
JOIN Dim_Product p ON f.product_key = p.product_key
JOIN Dim_Category c ON p.category_key = c.category_key
JOIN Dim_Sentiment s ON f.sentiment_key = s.sentiment_key
GROUP BY c.category_name, d.year ORDER BY c.category_name, d.year""",
"""SELECT p.category_name, d.year, COUNT(*) AS reviews,
       SUM(s.sentiment_label = 'Negative') AS negatives,
       ROUND(100 * SUM(s.sentiment_label = 'Negative') / COUNT(*), 1) AS negative_pct
FROM Fact_Review f
JOIN Dim_Date d ON f.date_key = d.date_key
JOIN Dim_Product_Flat p ON f.product_key = p.product_key
JOIN Dim_Sentiment s ON f.sentiment_key = s.sentiment_key
GROUP BY p.category_name, d.year ORDER BY p.category_name, d.year""")

Q["Q3 window function: top 10 products by negative reviews"] = (
"""SELECT * FROM (
  SELECT p.product_id, c.category_name, COUNT(*) AS negatives, RANK() OVER (ORDER BY COUNT(*) DESC) AS rnk
  FROM Fact_Review f
  JOIN Dim_Product p ON f.product_key = p.product_key
  JOIN Dim_Category c ON p.category_key = c.category_key
  JOIN Dim_Sentiment s ON f.sentiment_key = s.sentiment_key
  WHERE s.sentiment_label = 'Negative'
  GROUP BY p.product_id, c.category_name) t
WHERE rnk <= 10""",
"""SELECT * FROM (
  SELECT p.product_id, p.category_name, COUNT(*) AS negatives, RANK() OVER (ORDER BY COUNT(*) DESC) AS rnk
  FROM Fact_Review f
  JOIN Dim_Product_Flat p ON f.product_key = p.product_key
  JOIN Dim_Sentiment s ON f.sentiment_key = s.sentiment_key
  WHERE s.sentiment_label = 'Negative'
  GROUP BY p.product_id, p.category_name) t
WHERE rnk <= 10""")

Q["Q4 slice and dice: Roman Urdu x Electronics x 2018-2019"] = (
"""SELECT s.sentiment_label, COUNT(*) AS reviews
FROM Fact_Review f
JOIN Dim_Language l ON f.language_key = l.language_key
JOIN Dim_Product p ON f.product_key = p.product_key
JOIN Dim_Category c ON p.category_key = c.category_key
JOIN Dim_Date d ON f.date_key = d.date_key
JOIN Dim_Sentiment s ON f.sentiment_key = s.sentiment_key
WHERE l.language_name = 'Roman Urdu' AND c.category_name = 'Electronics' AND d.year BETWEEN 2018 AND 2019
GROUP BY s.sentiment_label""",
"""SELECT s.sentiment_label, COUNT(*) AS reviews
FROM Fact_Review f
JOIN Dim_Language l ON f.language_key = l.language_key
JOIN Dim_Product_Flat p ON f.product_key = p.product_key
JOIN Dim_Date d ON f.date_key = d.date_key
JOIN Dim_Sentiment s ON f.sentiment_key = s.sentiment_key
WHERE l.language_name = 'Roman Urdu' AND p.category_name = 'Electronics' AND d.year BETWEEN 2018 AND 2019
GROUP BY s.sentiment_label""")

Q["Q5 control (no hierarchy): top 15 keywords in negative reviews"] = (
"""SELECT k.keyword, COUNT(*) AS n
FROM Bridge_Review_Keyword b
JOIN Fact_Review f ON b.review_key = f.review_key
JOIN Dim_Sentiment s ON f.sentiment_key = s.sentiment_key
JOIN Dim_Keyword k ON b.keyword_key = k.keyword_key
WHERE s.sentiment_label = 'Negative'
GROUP BY k.keyword ORDER BY n DESC LIMIT 15""", None)

Q["Q6 summary table: same question as Q1, answered from Summary_Sentiment"] = (
"""SELECT department_name, category_name, sentiment_label, SUM(reviews) AS reviews
FROM Summary_Sentiment
GROUP BY department_name, category_name, sentiment_label WITH ROLLUP""", None)


def dump_sql():
    out = ["-- ReviewLens - benchmark queries (generated by etl/benchmark.py --dump-sql).",
           "-- In Workbench, put EXPLAIN ANALYZE in front of a query to see its real execution time.", "USE reviewlens;", ""]
    for name, (snow, flat) in Q.items():
        out.append(f"-- {name}  [snowflake]\n{snow};\n")
        if flat: out.append(f"-- {name}  [flat star]\n{flat};\n")
    Path("sql/07_benchmark_queries.sql").write_text("\n".join(out), encoding="utf-8")
    print("wrote sql/07_benchmark_queries.sql")


def timed(cur, sql, repeat):
    cur.execute(sql); cur.fetchall()                      # warm-up run (not counted)
    ms = []
    for _ in range(repeat):
        t0 = time.perf_counter(); cur.execute(sql); cur.fetchall(); ms.append((time.perf_counter() - t0) * 1000)
    return statistics.median(ms), statistics.mean(ms), min(ms)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", help="no_index or with_index (names the output files)")
    ap.add_argument("--repeat", type=int, default=30, help="runs per query (more = steadier numbers)")
    ap.add_argument("--host", default="localhost"); ap.add_argument("--user", default="root")
    ap.add_argument("--password"); ap.add_argument("--db", default="reviewlens")
    ap.add_argument("--dump-sql", action="store_true")
    ap.add_argument("--fact", default="Fact_Review", help="fact table to query; use Fact_Review_Big for the 392,000-row copy")
    a = ap.parse_args()
    if a.dump_sql: return dump_sql()
    if not a.label: ap.error("--label is required (e.g. --label no_index)")
    import pymysql
    conn = pymysql.connect(host=a.host, user=a.user, password=a.password or getpass.getpass("MySQL password: "),
                           database=a.db, charset="utf8mb4")
    cur = conn.cursor(); rows = []
    print(f"{'query':70s} {'schema':10s} {'median ms':>10s} {'mean ms':>9s} {'min ms':>8s}")
    for name, (snow, flat) in Q.items():
        for schema, sql in (("snowflake", snow), ("flat", flat)):
            if sql is None: continue
            sql = sql.replace("Fact_Review f", f"{a.fact} f")
            if a.fact.endswith("_Big"): sql = sql.replace("Summary_Sentiment", "Summary_Sentiment_Big")
            try:
                med, mean, mn = timed(cur, sql, a.repeat)
            except pymysql.err.ProgrammingError as e:
                print(f"{name[:68]:70s} {schema:10s} skipped ({e.args[1][:60]})"); continue
            label_schema = schema if flat else "n/a (control)" if name.startswith("Q5") else "summary table"
            rows.append([name, label_schema, round(med, 3), round(mean, 3), round(mn, 3)])
            print(f"{name[:68]:70s} {label_schema:10s} {med:10.3f} {mean:9.3f} {mn:8.3f}")
    Path("docs").mkdir(exist_ok=True)
    if a.fact != "Fact_Review": a.label = f"{a.label}_{a.fact.replace('Fact_Review_', '').lower()}"     # e.g. no_index_big
    with open(f"docs/benchmark_{a.label}.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["query", "schema", "median_ms", "mean_ms", "min_ms"]); w.writerows(rows)
    cur.execute("""SELECT table_name, ROUND(data_length/1024,1), ROUND(index_length/1024,1)
                   FROM information_schema.tables WHERE table_schema=%s ORDER BY data_length DESC""", (a.db,))
    with open(f"docs/storage_{a.label}.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["table", "data_kb", "index_kb"]); w.writerows(cur.fetchall())
    print(f"\nSaved docs/benchmark_{a.label}.csv and docs/storage_{a.label}.csv")

if __name__ == "__main__":
    main()
