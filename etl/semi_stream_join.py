"""
ReviewLens - Part 1: semi-stream join demo (index nested-loop join).

Idea: reviews keep ARRIVING (the stream).  The dimension tables are big, disk-based relations.  For every arriving
review we PROBE the dimensions through their indexes (index nested-loop join), look up the surrogate keys,
and load the finished row into Fact_Review.  A new product / customer / keyword that is not in a dimension yet is added.

Before running:   sql/02 (ETL) -> sql/04 section 2 (indexes) -> sql/08_stream_setup.sql
Run:              pip install pymysql
                  python etl/semi_stream_join.py --batch 50 --delay 1
Every batch is timed and logged to ETL_Audit.  Safe to re-run (reviews already loaded are skipped).
"""
import argparse, getpass, json, time

stats = {"probes": 0}


def probe(cur, sql, params):
    """One index lookup into a dimension table = one probe of the join."""
    stats["probes"] += 1
    cur.execute(sql, params)
    row = cur.fetchone()
    return row[0] if row else None


def next_key(cur, table, col):
    cur.execute(f"SELECT COALESCE(MAX({col}), 0) + 1 FROM {table}")
    return cur.fetchone()[0]


def keywords_of(features):
    """Features is text like ['aram', 'pocket'] -> clean lower-case keyword list."""
    try:
        arr = json.loads(str(features).replace("'", '"'))
    except ValueError:
        return []
    return sorted({str(w).strip().lower() for w in arr if str(w).strip()})


def load_one(cur, r):
    (review_key, product_id, customer_id, customer_name, review_date, rating, is_spam, sentiment, language,
     length_band, rating_conflict, is_dup, word_count, char_count, review_raw, review_clean, features,
     category_code, brand_code) = r

    if probe(cur, "SELECT review_key FROM Fact_Review WHERE review_key = %s", (review_key,)) is not None:
        return "skipped"                                              # already loaded earlier

    date_key = int(str(review_date)[:10].replace("-", ""))
    if probe(cur, "SELECT date_key FROM Dim_Date WHERE date_key = %s", (date_key,)) is None:
        return "rejected"                                             # date outside the calendar dimension

    product_key = probe(cur, "SELECT product_key FROM Dim_Product WHERE product_id = %s", (product_id,))
    if product_key is None:                                           # new product -> grow the dimension
        cat = probe(cur, "SELECT category_key FROM Dim_Category WHERE category_code = %s", (category_code,)) or 9
        product_key = next_key(cur, "Dim_Product", "product_key")
        cur.execute("INSERT INTO Dim_Product (product_key, product_id, brand_code, category_key) VALUES (%s,%s,%s,%s)",
                    (product_key, product_id, brand_code, cat))

    customer_key = probe(cur, "SELECT customer_key FROM Dim_Customer WHERE customer_id = %s", (customer_id,))
    if customer_key is None:                                          # new customer
        customer_key = next_key(cur, "Dim_Customer", "customer_key")
        cur.execute("INSERT INTO Dim_Customer (customer_key, customer_id, customer_name) VALUES (%s,%s,%s)",
                    (customer_key, customer_id, customer_name))

    sentiment_key = probe(cur, "SELECT sentiment_key FROM Dim_Sentiment WHERE sentiment_label = %s", (sentiment,)) or 4
    language_key = probe(cur, "SELECT language_key FROM Dim_Language WHERE language_name = %s", (language,)) or 4
    length_key = probe(cur, "SELECT length_key FROM Dim_ReviewLength WHERE length_band = %s", (length_band,)) or 1

    cur.execute("""INSERT INTO Fact_Review (review_key, date_key, product_key, customer_key, sentiment_key, language_key,
                   length_key, rating, is_spam, rating_conflict, is_duplicate_text, word_count, char_count)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (review_key, date_key, product_key, customer_key, sentiment_key, language_key, length_key,
                 rating, is_spam, rating_conflict, is_dup, word_count, char_count))
    cur.execute("INSERT INTO Review_Text (review_key, review_raw, review_clean) VALUES (%s,%s,%s)",
                (review_key, review_raw, review_clean))

    for kw in keywords_of(features):
        kk = probe(cur, "SELECT keyword_key FROM Dim_Keyword WHERE keyword = %s", (kw,))
        if kk is None:                                                # new keyword
            kk = next_key(cur, "Dim_Keyword", "keyword_key")
            cur.execute("INSERT INTO Dim_Keyword (keyword_key, keyword) VALUES (%s,%s)", (kk, kw))
        cur.execute("INSERT INTO Bridge_Review_Keyword (review_key, keyword_key) VALUES (%s,%s)", (review_key, kk))
    return "loaded"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", type=int, default=50, help="reviews per micro-batch")
    ap.add_argument("--delay", type=float, default=0, help="seconds to wait between batches (simulates arrival)")
    ap.add_argument("--host", default="localhost"); ap.add_argument("--user", default="root")
    ap.add_argument("--password"); ap.add_argument("--db", default="reviewlens")
    a = ap.parse_args()

    import pymysql
    conn = pymysql.connect(host=a.host, user=a.user, password=a.password or getpass.getpass("MySQL password: "),
                           database=a.db, charset="utf8mb4")
    cur = conn.cursor()
    cur.execute("""SELECT review_key, product_id, customer_id, customer_name, review_date, rating, is_spam, sentiment,
                          language, length_band, rating_conflict, is_duplicate_text, word_count, char_count,
                          review_raw, review_clean, features, category_code, brand_code
                   FROM stream_source ORDER BY review_key""")
    stream = cur.fetchall()
    print(f"{len(stream)} reviews waiting in the stream; batch size {a.batch}\n")
    print(f"{'batch':>5} {'loaded':>7} {'skipped':>8} {'rejected':>9} {'index probes':>13} {'time ms':>9}")

    total = {"loaded": 0, "skipped": 0, "rejected": 0}
    for n, start in enumerate(range(0, len(stream), a.batch), 1):
        batch = stream[start:start + a.batch]
        stats["probes"] = 0
        t0 = time.perf_counter(); res = {"loaded": 0, "skipped": 0, "rejected": 0}
        for row in batch:
            res[load_one(cur, row)] += 1
        conn.commit()
        ms = (time.perf_counter() - t0) * 1000
        for k in total: total[k] += res[k]
        cur.execute("INSERT INTO ETL_Audit (step, rows_in, rows_out, note) VALUES (%s,%s,%s,%s)",
                    (f"stream batch {n}", len(batch), res["loaded"], f"{ms:.1f} ms, {stats['probes']} index probes"))
        conn.commit()
        print(f"{n:5d} {res['loaded']:7d} {res['skipped']:8d} {res['rejected']:9d} {stats['probes']:13d} {ms:9.1f}")
        if a.delay: time.sleep(a.delay)

    cur.execute("SELECT COUNT(*) FROM Fact_Review"); print(f"\nDone: {total}. Fact_Review now has {cur.fetchone()[0]} rows.")
    print("Tip: CALL refresh_summary_sentiment();   to bring the summary table up to date.")
    conn.close()

if __name__ == "__main__":
    main()
