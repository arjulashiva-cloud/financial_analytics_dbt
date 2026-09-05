"""
pull_cfpb_complaints.py
=======================
financial_analytics_dbt — Phase 2c
Pulls consumer complaint data from the CFPB Complaint Database API (free, public — no key needed).
Filters for banking products: checking, savings, mortgage, credit card, personal loans.

API docs: https://cfpb.github.io/api/ccdb/
Target table: RAW_CFPB_COMPLAINTS (~10K rows, last 2 years)

Run:
    python data_generation/pull_cfpb_complaints.py
"""

import os
import requests
import pandas as pd
from datetime import datetime, date, timedelta
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

CFPB_BASE = "https://api.consumerfinance.gov/data/complaints"

SNOWFLAKE_CONFIG = {
    "account":   "dqmbxut-dk43290",
    "user":      "SHIVAARJULA6",
    "password":  os.environ.get("SNOWFLAKE_PASSWORD", "Shiva@123"),
    "database":  "FINANCIAL_ANALYTICS",
    "schema":    "RAW",
    "warehouse": "COMPUTE_WH",
    "role":      "ACCOUNTADMIN",
}

DATE_FROM   = (date.today() - timedelta(days=730)).isoformat()   # 2 years back
DATE_TO     = date.today().isoformat()
SAMPLE_SIZE = 10000
PER_PAGE    = 100   # CFPB API page limit


def fetch_cfpb_complaints() -> pd.DataFrame:
    print("Pulling CFPB consumer complaint data...")
    print(f"  Window: {DATE_FROM} → {DATE_TO}")
    print(f"  Target: {SAMPLE_SIZE} complaints")

    all_rows  = []
    max_pages = SAMPLE_SIZE // PER_PAGE

    params_base = {
        "date_received_min": DATE_FROM,
        "date_received_max": DATE_TO,
        "size":   PER_PAGE,
        "sort":   "created_date_desc",
        "_source": ",".join([
            "complaint_id", "date_received", "product", "sub_product",
            "issue", "sub_issue", "company", "state",
            "company_response", "timely", "consumer_disputed", "tags",
        ]),
    }

    frm = 0
    for page in range(max_pages):
        params = {**params_base, "from": frm}
        try:
            resp = requests.get(CFPB_BASE, params=params, timeout=30)
            resp.raise_for_status()
            data = resp.json()
            hits = data.get("hits", {}).get("hits", [])
            if not hits:
                print(f"  No more results at page {page}.")
                break
            for h in hits:
                all_rows.append(h.get("_source", {}))
            frm += PER_PAGE
            if frm % 1000 == 0:
                print(f"  Fetched {frm} complaints...")
        except requests.exceptions.RequestException as e:
            print(f"  ⚠  Page {page} error: {e} — stopping here")
            break

    df = pd.DataFrame(all_rows)
    print(f"\n  Retrieved {len(df)} complaints")
    return df


def clean_cfpb_data(df: pd.DataFrame) -> pd.DataFrame:
    rename_map = {
        "complaint_id":      "complaint_id",
        "date_received":     "date_received",
        "product":           "product",
        "sub_product":       "sub_product",
        "issue":             "issue",
        "sub_issue":         "sub_issue",
        "company":           "company_name",
        "state":             "state",
        "company_response":  "company_response",
        "timely":            "timely_response",
        "consumer_disputed": "consumer_disputed",
        "tags":              "tags",
    }
    df = df.rename(columns={k: v for k, v in rename_map.items() if k in df.columns})
    keep = list(rename_map.values())
    df   = df[[c for c in keep if c in df.columns]]

    # Parse date
    if "date_received" in df.columns:
        df["date_received"] = pd.to_datetime(df["date_received"], errors="coerce").dt.date

    # Standardize booleans
    for col in ["timely_response", "consumer_disputed"]:
        if col in df.columns:
            df[col] = df[col].map({"Yes": True, "No": False, True: True, False: False})

    # Resolution category
    def categorize_response(resp):
        if pd.isna(resp):
            return "UNKNOWN"
        r = str(resp).upper()
        if "CLOSED WITH MONETARY"     in r: return "MONETARY_RELIEF"
        if "CLOSED WITH NON-MONETARY" in r: return "NON_MONETARY_RELIEF"
        if "CLOSED WITH EXPLANATION"  in r: return "EXPLANATION_ONLY"
        if "CLOSED WITHOUT"           in r: return "CLOSED_NO_RELIEF"
        if "IN PROGRESS"              in r: return "IN_PROGRESS"
        return "OTHER"

    if "company_response" in df.columns:
        df["resolution_category"] = df["company_response"].apply(categorize_response)

    # Truncate long free-text fields to avoid Snowflake VARCHAR overflow
    for col in ["issue", "sub_issue", "company_name"]:
        if col in df.columns:
            df[col] = df[col].astype(str).str[:500]

    df["created_at"] = datetime.now().isoformat()
    return df


def load_to_snowflake(df: pd.DataFrame):
    print("\nConnecting to Snowflake...")
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()
    cur.execute("USE DATABASE FINANCIAL_ANALYTICS")
    cur.execute("USE SCHEMA RAW")

    cur.execute("DROP TABLE IF EXISTS RAW_CFPB_COMPLAINTS")
    cur.execute("""
        CREATE TABLE RAW_CFPB_COMPLAINTS (
            COMPLAINT_ID        VARCHAR(20),
            DATE_RECEIVED       DATE,
            PRODUCT             VARCHAR(200),
            SUB_PRODUCT         VARCHAR(200),
            ISSUE               VARCHAR(500),
            SUB_ISSUE           VARCHAR(500),
            COMPANY_NAME        VARCHAR(300),
            STATE               VARCHAR(5),
            COMPANY_RESPONSE    VARCHAR(300),
            TIMELY_RESPONSE     BOOLEAN,
            CONSUMER_DISPUTED   BOOLEAN,
            TAGS                VARCHAR(100),
            RESOLUTION_CATEGORY VARCHAR(30),
            CREATED_AT          TIMESTAMP_NTZ
        )
    """)

    df.columns = [c.upper() for c in df.columns]
    print(f"Loading {len(df)} rows → RAW_CFPB_COMPLAINTS...")
    _, _, nrows, _ = write_pandas(conn, df, "RAW_CFPB_COMPLAINTS")
    print(f"✅  Loaded {nrows} rows")

    cur.execute("""
        SELECT PRODUCT, COUNT(*) AS CNT,
               SUM(CASE WHEN TIMELY_RESPONSE THEN 1 ELSE 0 END) AS TIMELY,
               SUM(CASE WHEN RESOLUTION_CATEGORY = 'MONETARY_RELIEF' THEN 1 ELSE 0 END) AS MONETARY
        FROM RAW_CFPB_COMPLAINTS
        GROUP BY PRODUCT
        ORDER BY CNT DESC
        LIMIT 8
    """)
    rows = cur.fetchall()
    cols = [d[0] for d in cur.description]
    print("\nComplaints by product:")
    print(pd.DataFrame(rows, columns=cols).to_string(index=False))

    cur.close()
    conn.close()


if __name__ == "__main__":
    raw     = fetch_cfpb_complaints()
    cleaned = clean_cfpb_data(raw)
    load_to_snowflake(cleaned)
    print("\n✅  pull_cfpb_complaints.py — COMPLETE")
    print("    Now run: dbt run --select mart_compliance_conduct")
