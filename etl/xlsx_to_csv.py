"""
Step 0 (the only Python step): MySQL cannot read .xlsx, so convert it to a plain CSV first.
Run from the reviewlens folder:   python etl/xlsx_to_csv.py
Reads the first .xlsx in data/ and writes data/daraz_raw.csv  (needs: pandas, openpyxl)
"""
import csv, sys
from pathlib import Path
import pandas as pd

files = sorted(Path("data").glob("*.xlsx"))
if not files:
    sys.exit("No .xlsx found in data/. Put the Daraz file there first.")
df = pd.read_excel(files[0])
df.columns = ["src_row", "product_id", "customer_name", "customer_id", "date",
              "rating", "is_spam", "review", "sentiment", "features"]
df["date"] = pd.to_datetime(df["date"]).dt.strftime("%Y-%m-%d")     # always yyyy-mm-dd, whatever Excel shows

with open("data/daraz_raw.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
    w.writerow(df.columns)
    w.writerows(df.astype(str).values.tolist())
print(f"Wrote data/daraz_raw.csv with {len(df):,} rows from {files[0].name}")
