"""
pull_fdic_peers.py
==================
financial_analytics_dbt — Phase 2b
Pulls peer bank data from FDIC BankFind Suite API (free, public — no API key needed).
Filters for community/regional banks with $1B–$10B in total assets.

API docs: https://banks.data.fdic.gov/docs/
Target table: RAW_FDIC_PEERS

Run:
    python data_generation/pull_fdic_peers.py
"""

import os
import requests
import pandas as pd
from datetime import datetime
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

FDIC_BASE = "https://banks.data.fdic.gov/api/institutions"

SNOWFLAKE_CONFIG = {
    "account":   "dqmbxut-dk43290",
    "user":      "SHIVAARJULA6",
    "password":  os.environ.get("SNOWFLAKE_PASSWORD", "Shiva@123"),
    "database":  "FINANCIAL_ANALYTICS",
    "schema":    "RAW",
    "warehouse": "COMPUTE_WH",
    "role":      "ACCOUNTADMIN",
}

# FDIC fields to retrieve
FDIC_FIELDS = [
    "REPDTE",       # Report date (YYYYMMDD)
    "CERT",         # FDIC certificate number (unique bank ID)
    "NAME",         # Institution name
    "CITY",         # City
    "STNAME",       # State name
    "ASSET",        # Total assets ($thousands)
    "DEP",          # Total deposits ($thousands)
    "LNLSNET",      # Net loans and leases ($thousands)
    "NETINC",       # Net income ($thousands)
    "ROA",          # Return on assets (%)
    "ROE",          # Return on equity (%)
    "INTINC",       # Total interest income ($thousands)
    "EINTEXP",      # Total interest expense ($thousands)
    "NIITEPRE",     # Net interest margin (%)
    "DRLNLS",       # Net charge-off rate (%)
    "RBCT1J",       # Tier 1 capital ratio (%)
    "LNLSDEPR",     # Loan-to-deposit ratio (%)
    "REPNO",        # Employee count
]


def fetch_fdic_peers() -> pd.DataFrame:
    print("Pulling FDIC BankFind peer bank data...")
    print("  Filter: Active banks, $1B–$10B total assets")

    all_rows = []
    offset = 0
    limit  = 500   # FDIC max per request

    while True:
        params = {
            "filters":    "ASSET:[1000000 TO 10000000] AND ACTIVE:1",
            "fields":     ",".join(FDIC_FIELDS),
            "limit":      limit,
            "offset":     offset,
            "output":     "json",
            "sort_by":    "ASSET",
            "sort_order": "DESC",
        }
        resp = requests.get(FDIC_BASE, params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()

        rows = data.get("data", [])
        if not rows:
            break

        for row in rows:
            all_rows.append(row.get("data", {}))

        total  = data.get("meta", {}).get("total", 0)
        offset += limit
        print(f"  Fetched {min(offset, total)}/{total} banks...")

        if offset >= total:
            break

    df = pd.DataFrame(all_rows)
    print(f"\n  Retrieved {len(df)} peer banks")
    return df


def clean_fdic_data(df: pd.DataFrame) -> pd.DataFrame:
    rename_map = {
        "REPDTE":   "report_date",
        "CERT":     "fdic_cert_id",
        "NAME":     "bank_name",
        "CITY":     "city",
        "STNAME":   "state",
        "ASSET":    "total_assets_k",
        "DEP":      "total_deposits_k",
        "LNLSNET":  "net_loans_k",
        "NETINC":   "net_income_k",
        "ROA":      "return_on_assets_pct",
        "ROE":      "return_on_equity_pct",
        "INTINC":   "interest_income_k",
        "EINTEXP":  "interest_expense_k",
        "NIITEPRE": "net_interest_margin_pct",
        "DRLNLS":   "net_chargeoff_rate_pct",
        "RBCT1J":   "tier1_capital_ratio_pct",
        "LNLSDEPR": "loan_to_deposit_ratio_pct",
        "REPNO":    "employee_count",
    }
    df = df.rename(columns={k: v for k, v in rename_map.items() if k in df.columns})

    # Coerce all numeric columns
    str_cols = {"bank_name", "city", "state", "report_date"}
    for col in df.columns:
        if col not in str_cols:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    # Convert $thousands → $millions for readability
    k_cols = ["total_assets_k", "total_deposits_k", "net_loans_k",
              "net_income_k", "interest_income_k", "interest_expense_k"]
    for col in k_cols:
        if col in df.columns:
            mm_col = col.replace("_k", "_mm")
            df[mm_col] = (df[col] / 1000).round(2)
            df.drop(columns=[col], inplace=True)

    df["created_at"] = datetime.now().isoformat()
    return df


def load_to_snowflake(df: pd.DataFrame):
    print("\nConnecting to Snowflake...")
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()
    cur.execute("USE DATABASE FINANCIAL_ANALYTICS")
    cur.execute("USE SCHEMA RAW")

    cur.execute("DROP TABLE IF EXISTS RAW_FDIC_PEERS")
    cur.execute("""
        CREATE TABLE RAW_FDIC_PEERS (
            REPORT_DATE                 VARCHAR(10),
            FDIC_CERT_ID                INTEGER,
            BANK_NAME                   VARCHAR(200),
            CITY                        VARCHAR(100),
            STATE                       VARCHAR(50),
            TOTAL_ASSETS_MM             FLOAT,
            TOTAL_DEPOSITS_MM           FLOAT,
            NET_LOANS_MM                FLOAT,
            NET_INCOME_MM               FLOAT,
            RETURN_ON_ASSETS_PCT        FLOAT,
            RETURN_ON_EQUITY_PCT        FLOAT,
            INTEREST_INCOME_MM          FLOAT,
            INTEREST_EXPENSE_MM         FLOAT,
            NET_INTEREST_MARGIN_PCT     FLOAT,
            NET_CHARGEOFF_RATE_PCT      FLOAT,
            TIER1_CAPITAL_RATIO_PCT     FLOAT,
            LOAN_TO_DEPOSIT_RATIO_PCT   FLOAT,
            EMPLOYEE_COUNT              FLOAT,
            CREATED_AT                  TIMESTAMP_NTZ
        )
    """)

    df.columns = [c.upper() for c in df.columns]

    print(f"Loading {len(df)} rows → RAW_FDIC_PEERS...")
    _, _, nrows, _ = write_pandas(conn, df, "RAW_FDIC_PEERS")
    print(f"✅  Loaded {nrows} rows")

    cur.execute("""
        SELECT BANK_NAME, STATE, TOTAL_ASSETS_MM,
               NET_INTEREST_MARGIN_PCT, RETURN_ON_ASSETS_PCT, NET_CHARGEOFF_RATE_PCT
        FROM RAW_FDIC_PEERS
        ORDER BY TOTAL_ASSETS_MM DESC
        LIMIT 8
    """)
    rows = cur.fetchall()
    cols = [d[0] for d in cur.description]
    print("\nTop 8 peer banks by assets:")
    print(pd.DataFrame(rows, columns=cols).to_string(index=False))

    cur.close()
    conn.close()


if __name__ == "__main__":
    raw     = fetch_fdic_peers()
    cleaned = clean_fdic_data(raw)
    load_to_snowflake(cleaned)
    print("\n✅  pull_fdic_peers.py — COMPLETE")
    print("    Now run: dbt run --select mart_peer_benchmarking")
