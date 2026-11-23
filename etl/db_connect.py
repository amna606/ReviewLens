import mysql.connector
import pandas as pd

conn = mysql.connector.connect(
    host="localhost",
    port=3306,
    user="root",
    #password=os.environ.get("MYSQL_PWD", ""),
    database="reviewlens",
)
print("Connected:", conn.is_connected())

cur = conn.cursor()
cur.execute("SELECT VERSION()")
print("Server:", cur.fetchone()[0])

for t in ["fact_review", "dim_product", "dim_customer", "review_pos", "review_aspectopinion"]:
    cur.execute(f"SELECT COUNT(*) FROM {t}")
    print(t, cur.fetchone()[0])
cur.close()

df = pd.read_sql("""
    SELECT s.sentiment_label, COUNT(*) AS reviews
    FROM fact_review f
    JOIN dim_sentiment s ON s.sentiment_key = f.sentiment_key
    GROUP BY s.sentiment_label
""", conn)
print(df)

conn.close()