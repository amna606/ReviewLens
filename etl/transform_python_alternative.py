"""
ReviewLens - Part 1: extract + transform.
Reads the Daraz xlsx and writes one CSV per warehouse table into data/warehouse_csv/.
Run:  python etl/transform.py data/Daraz_Labelled_Review_Dataset_with_Sentiments_and_Features.xlsx
Needs: pandas, openpyxl
"""
import sys, re, ast, csv
from pathlib import Path
import pandas as pd

# Path to the xlsx: pass it as an argument, or just leave it in data/ and it is found automatically
if len(sys.argv) > 1:
    SRC = Path(sys.argv[1])
else:
    found = sorted(Path("data").glob("*.xlsx"))
    if not found:
        sys.exit("No .xlsx found in data/. Put the Daraz file there, or run: python etl/transform.py <path-to-xlsx>")
    SRC = found[0]
print("Reading:", SRC)
OUT = Path("data/warehouse_csv"); OUT.mkdir(parents=True, exist_ok=True)
audit = []   # (step, rows_in, rows_out, note)

def save(df, name):
    # No NaNs are written: every loaded column is filled, so MySQL needs no NULL handling.
    df.to_csv(OUT / f"{name}.csv", index=False, quoting=csv.QUOTE_MINIMAL, encoding="utf-8")
    print(f"{name:28s} {len(df):>7,} rows")

# ---------------------------------------------------------------- EXTRACT
raw = pd.read_excel(SRC)
raw.columns = ["src_row", "product_id", "customer_name", "customer_id", "date",
               "rating", "is_spam", "review_raw", "sentiment", "features"]
audit.append(("extract", len(raw), len(raw), "rows read from xlsx"))

# ---------------------------------------------------------------- CLEAN
df = raw.copy()
df["review_key"] = df["src_row"] + 1                       # stable id shared with Part 2
df["product_id"] = df["product_id"].astype(str).str.strip()  # a few ids are numeric in the file
df["customer_name"] = df["customer_name"].astype(str).str.strip()
df["sentiment"] = df["sentiment"].astype(str).str.strip().str.title()
df["date"] = pd.to_datetime(df["date"])

def clean_text(s):
    s = str(s)
    s = re.sub(r"https?://\S+|www\.\S+", " ", s)          # URLs
    s = re.sub(r"[\r\n\t]+", " ", s)                        # newlines break CSV loading
    s = re.sub(r"\s+", " ", s).strip()
    return s
df["review_raw"] = df["review_raw"].map(clean_text)

# Roman Urdu spelling variants -> one form (extend this dict as you find more)
VARIANTS = {r"\b(achha|accha|aacha|acha|achi|achii|acchi|achhi)\b": "acha",
            r"\b(bohat|bohot|boht|bahut|bht)\b": "bohat",
            r"\b(nhi|nahi|nai|nahin)\b": "nahi",
            r"\b(hai|hy|he|h)\b": "hai"}
def normalise(s):
    s = s.lower()
    for pat, rep in VARIANTS.items(): s = re.sub(pat, rep, s)
    return s
df["review_clean"] = df["review_raw"].map(normalise)

df["word_count"] = df["review_clean"].str.split().str.len().fillna(0).astype(int)
df["char_count"] = df["review_clean"].str.len().astype(int)
df["is_spam"] = df["is_spam"].astype(int)

# Same text appearing more than once. These are NOT exact duplicate rows (product/customer/date differ),
# so we FLAG them instead of deleting real reviews.
df["is_duplicate_text"] = df.duplicated("review_clean", keep="first").astype(int)
audit.append(("flag duplicate text", len(df), len(df), f"{int(df.is_duplicate_text.sum())} rows flagged, none deleted"))

# Rating-vs-label conflict (the 'can we trust stars?' signal)
df["rating_conflict"] = (((df.rating >= 4) & (df.sentiment == "Negative")) |
                         ((df.rating <= 2) & (df.sentiment == "Positive"))).astype(int)

# ---------------------------------------------------------------- LANGUAGE (rule-based, approximate)
EN = set("the is are was were this that and with for not very good bad product quality price delivery fast slow "
         "received order item nice great worth money love excellent awesome best phone screen battery size color "
         "colour small big cheap expensive looks work works working but have has had it its my your you".split())
UR = set("hai acha bohat nahi ka ki ke ko ho hain tha thi aur lekin bhi mein main yeh ye woh kya kuch sab zabardast "
         "behtareen mujhe pasand cheez dam kharab sahi theek shukriya qeemat miyaar masla".split())
def lang(s):
    toks = re.findall(r"[a-z]+", s); e = sum(t in EN for t in toks); u = sum(t in UR for t in toks)
    if e == 0 and u == 0: return "Unknown"
    if u == 0: return "English"
    if e == 0: return "Roman Urdu"
    r = e / (e + u)
    return "English" if r > 0.7 else "Roman Urdu" if r < 0.3 else "Mixed"
df["language"] = df["review_clean"].map(lang)

def length_band(w): return "Short (1-8 words)" if w <= 8 else "Medium (9-30 words)" if w <= 30 else "Long (31+ words)"
df["length_band"] = df["word_count"].map(length_band)

# ---------------------------------------------------------------- DIMENSIONS
# Dim_Date: full calendar between first and last review (so days with no reviews still exist)
days = pd.date_range(df.date.min().replace(day=1), df.date.max() + pd.offsets.MonthEnd(0))
dim_date = pd.DataFrame({"full_date": days})
dim_date["date_key"] = dim_date.full_date.dt.strftime("%Y%m%d").astype(int)
dim_date["year"] = dim_date.full_date.dt.year
dim_date["quarter"] = dim_date.full_date.dt.quarter
dim_date["month"] = dim_date.full_date.dt.month
dim_date["month_name"] = dim_date.full_date.dt.month_name()
dim_date["day"] = dim_date.full_date.dt.day
dim_date["day_name"] = dim_date.full_date.dt.day_name()
dim_date["is_weekend"] = (dim_date.full_date.dt.dayofweek >= 5).astype(int)
dim_date["full_date"] = dim_date.full_date.dt.strftime("%Y-%m-%d")
dim_date = dim_date[["date_key","full_date","year","quarter","month","month_name","day","day_name","is_weekend"]]

# Category: INFERRED from characters 6-7 of Product_ID (e.g. MI543EL... -> EL). Verify ~50 products by hand!
CODE = {"FA":("Fashion","Fashion & Beauty"), "HB":("Health & Beauty","Fashion & Beauty"),
        "EL":("Electronics","Electronics & Media"), "ME":("Media & Gaming","Electronics & Media"),
        "HL":("Home & Living","Home & Family"), "TB":("Toys & Baby","Home & Family"),
        "SP":("Sports & Outdoor","Sports & Others"), "OT":("Other","Sports & Others"),
        "XX":("Unknown","Unknown")}
df["category_code"] = df.product_id.str.extract(r"^[A-Z]{2}\d{3}([A-Z]{2})")[0].fillna("XX")
df.loc[~df.category_code.isin(CODE), "category_code"] = "XX"
df["brand_code"] = df.product_id.str.extract(r"^([A-Z]{2})\d")[0].fillna("XX")

depts = sorted({d for _, d in CODE.values()})
dim_department = pd.DataFrame({"department_key": range(1, len(depts)+1), "department_name": depts})
dkey = dict(zip(dim_department.department_name, dim_department.department_key))
dim_category = pd.DataFrame([{"category_key": i+1, "category_code": c, "category_name": n, "department_key": dkey[d]}
                             for i, (c, (n, d)) in enumerate(CODE.items())])
ckey = dict(zip(dim_category.category_code, dim_category.category_key))

prod = df.drop_duplicates("product_id")[["product_id","brand_code","category_code"]].reset_index(drop=True)
prod["product_key"] = prod.index + 1
prod["category_key"] = prod.category_code.map(ckey)
dim_product = prod[["product_key","product_id","brand_code","category_key"]]
pkey = dict(zip(prod.product_id, prod.product_key))

# Customer: one row per customer_id; the same id appears with 2 names sometimes -> keep the most frequent
cust = (df.groupby("customer_id").customer_name.agg(lambda s: s.mode().iat[0]).reset_index())
cust["customer_key"] = cust.index + 1
dim_customer = cust[["customer_key","customer_id","customer_name"]]
ukey = dict(zip(cust.customer_id, cust.customer_key))

dim_sentiment = pd.DataFrame({"sentiment_key":[1,2,3,4], "sentiment_label":["Positive","Neutral","Negative","Unknown"]})
skey = dict(zip(dim_sentiment.sentiment_label, dim_sentiment.sentiment_key))
dim_language = pd.DataFrame({"language_key":[1,2,3,4], "language_name":["English","Roman Urdu","Mixed","Unknown"]})
lkey = dict(zip(dim_language.language_name, dim_language.language_key))
bands = ["Short (1-8 words)","Medium (9-30 words)","Long (31+ words)"]
dim_length = pd.DataFrame({"length_key":[1,2,3], "length_band":bands}); bkey = dict(zip(bands, [1,2,3]))

# Keywords come from the dataset's Features column (a Python-style list stored as text)
def parse_feats(s):
    try: return [w.strip().lower() for w in ast.literal_eval(s) if str(w).strip()]
    except Exception: return []
pairs = [(rk, w) for rk, f in zip(df.review_key, df.features) for w in set(parse_feats(f))]
kw = pd.DataFrame(pairs, columns=["review_key","keyword"])
dim_keyword = pd.DataFrame({"keyword": sorted(kw.keyword.unique())}); dim_keyword.insert(0,"keyword_key", range(1,len(dim_keyword)+1))
bridge_kw = kw.merge(dim_keyword, on="keyword")[["review_key","keyword_key"]]

# ---------------------------------------------------------------- FACT
fact = pd.DataFrame({
    "review_key": df.review_key,
    "date_key": df.date.dt.strftime("%Y%m%d").astype(int),
    "product_key": df.product_id.map(pkey),
    "customer_key": df.customer_id.map(ukey),
    "sentiment_key": df.sentiment.map(skey).fillna(skey["Unknown"]).astype(int),
    "language_key": df.language.map(lkey),
    "length_key": df.length_band.map(bkey),
    "rating": df.rating, "is_spam": df.is_spam,
    "rating_conflict": df.rating_conflict, "is_duplicate_text": df.is_duplicate_text,
    "word_count": df.word_count, "char_count": df.char_count})
review_text = df[["review_key","review_raw","review_clean"]]

# ---------------------------------------------------------------- QUALITY GATE
assert fact.review_key.is_unique, "review_key must be unique"
for col in ["date_key","product_key","customer_key","sentiment_key","language_key","length_key"]:
    assert fact[col].notna().all(), f"unmapped foreign key in {col}"
assert fact.date_key.isin(dim_date.date_key).all()
assert not fact.isna().any().any()
audit.append(("transform", len(df), len(fact), "fact rows built, all foreign keys resolved"))

# ---------------------------------------------------------------- WRITE
for name, t in [("Dim_Date",dim_date),("Dim_Department",dim_department),("Dim_Category",dim_category),
                ("Dim_Product",dim_product),("Dim_Customer",dim_customer),("Dim_Sentiment",dim_sentiment),
                ("Dim_Language",dim_language),("Dim_ReviewLength",dim_length),("Dim_Keyword",dim_keyword),
                ("Fact_Review",fact),("Bridge_Review_Keyword",bridge_kw),("Review_Text",review_text)]:
    save(t, name)
save(pd.DataFrame(audit, columns=["step","rows_in","rows_out","note"]), "ETL_Audit")
# Handoff file for Part 2 (NLP): everything they need to train and to join results back by review_key
df[["review_key","review_clean","sentiment","rating","is_spam","language"]].to_csv("data/reviews_for_nlp.csv", index=False)
print("wrote data/reviews_for_nlp.csv (give this to Part 2)")
