"""
pull_fred_data.py
=================
financial_analytics_dbt — Phase 1, Script 6
Pulls 5 macroeconomic series from the FRED API (Federal Reserve Bank of St. Louis)
and loads them into RAW_FRED_MACRO in Snowflake.

FRED Series pulled:
    FEDFUNDS     — Federal Funds Effective Rate (monthly, %)
    T10Y2Y       — 10-Year minus 2-Year Treasury spread (daily → monthly avg)
    UNRATE       — Unemployment Rate (monthly, %)
    CPIAUCSL     — Consumer Price Index, All Urban (monthly, index)
    MORTGAGE30US — 30-Year Fixed Mortgage Rate (weekly → monthly avg)

Free API key: https://fred.stlouisfed.org/docs/api/api_key.html
              Register → My Account → API Keys → Request API Key (instant)

Set env var:
    $env:FRED_API_KEY = "your_key_here"

Run:
    python pull_fred_data.py
"""

import os
import time
import requests
import pandas as pd
from datetime import datetime, date
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

FRED_API_KEY = os.environ.get("FRED_API_KEY", "")
FRED_BASE    = "https://api.stlouisfed.org/fred/series/observations"

# Pull 5 years of history — enough for trend analysis and scenario context
OBSERVATION_START = "2019-01-01"
OBSERVATION_END   = date.today().isoformat()

SNOWFLAKE_CONFIG = {
    "account":   "dqmbxut-dk43290",
    "user":      "SHIVAARJULA6",
    "password":  os.environ.get("SNOWFLAKE_PASSWORD", "Shiva@123"),
    "database":  "FINANCIAL_ANALYTICS",
    "schema":    "RAW",
    "warehouse": "COMPUTE_WH",
    "role":      "ACCOUNTADMIN",
}

# ── Series definitions ────────────────────────────────────────────────────────
SERIES = {
    "FEDFUNDS":     {"label": "fed_funds_rate",    "freq": "m"},   # monthly
    "T10Y2Y":       {"label": "yield_curve_spread", "freq": "m"},   # daily, we avg to monthly
    "UNRATE":       {"label": "unemployment_rate",  "freq": "m"},   # monthly
    "CPIAUCSL":     {"label": "cpi_index",          "freq": "m"},   # monthly
    "MORTGAGE30US": {"label": "mortgage_30yr_rate", "freq": "m"},   # weekly, avg to monthly
}


# ── FRED fetcher ──────────────────────────────────────────────────────────────
def fetch_series(series_id: str) -> pd.DataFrame:
    """Pull observations from FRED API and return a tidy DataFrame."""
    if not FRED_API_KEY:
        raise ValueError(
            "FRED_API_KEY not set.\n"
            "  1. Get a free key at https://fred.stlouisfed.org/docs/api/api_key.html\n"
            "  2. Run: $env:FRED_API_KEY = 'your_key_here'"
        )

    params = {
        "series_id":         series_id,
        "observation_start": OBSERVATION_START,
        "observation_end":   OBSERVATION_END,
        "api_key":           FRED_API_KEY,
        "file_type":         "json",
        "frequency":         "m",     # request monthly aggregation from FRED
        "aggregation_method":"avg",   # weekly/daily → monthly average
    }
    resp = requests.get(FRED_BASE, params=params, timeout=30)
    resp.raise_for_status()
    data = resp.json()

    observations = data.get("observations", [])
    if not observations:
        print(f"  ⚠  No observations returned for {series_id}")
        return pd.DataFrame()

    df = pd.DataFrame(observations)[["date", "value"]]
    df = df[df["value"] != "."]          # FRED uses "." for missing values
    df["date"]  = pd.to_datetime(df["date"]).dt.date
    df["value"] = df["value"].astype(float)
    df.rename(columns={"date": "obs_date", "value": series_id}, inplace=True)
    print(f"  {series_id}: {len(df)} monthly observations")
    return df


# ── Main pull and reshape ─────────────────────────────────────────────────────
def pull_fred_data() -> pd.DataFrame:
    print("Pulling FRED macroeconomic data...")
    print(f"  Series: {list(SERIES.keys())}")
    print(f"  Window: {OBSERVATION_START} → {OBSERVATION_END}")

    frames = []
    for series_id in SERIES:
        df = fetch_series(series_id)
        if not df.empty:
            frames.append(df)
        time.sleep(0.5)   # be polite to the FRED API

    if not frames:
        raise RuntimeError("No FRED data retrieved — check API key and network.")

    # Merge all series on obs_date (outer join so no month is dropped if one series lags)
    merged = frames[0]
    for df in frames[1:]:
        merged = pd.merge(merged, df, on="obs_date", how="outer")

    merged.sort_values("obs_date", inplace=True)
    merged.reset_index(drop=True, inplace=True)

    # Rename columns to descriptive names
    col_map = {sid: info["label"] for sid, info in SERIES.items()}
    merged.rename(columns=col_map, inplace=True)

    # ── Derived fields ────────────────────────────────────────────────────────
    # CPI year-over-year % change (inflation)
    merged["cpi_yoy_pct"] = merged["cpi_index"].pct_change(12).mul(100).round(2)

    # Macro scenario classification for CECL
    #   base             : unemployment ≤ 5.5% AND yield_curve ≥ 0
    #   adverse          : unemployment 5.5–8% OR yield_curve < 0
    #   severely_adverse : unemployment > 8%
    merged["macro_scenario"] = merged.apply(
        lambda r: (
            "severely_adverse" if (
                pd.notna(r.get("unemployment_rate")) and r["unemployment_rate"] > 8.0
            ) else (
                "adverse" if (
                    pd.notna(r.get("unemployment_rate")) and r["unemployment_rate"] > 5.5
                    or pd.notna(r.get("yield_curve_spread")) and r["yield_curve_spread"] < 0
                ) else "base"
            )
        ),
        axis=1
    )

    merged["created_at"] = datetime.now().isoformat()

    print(f"\nFinal dataset: {len(merged)} rows × {len(merged.columns)} columns")
    print(merged[["obs_date","fed_funds_rate","unemployment_rate","cpi_yoy_pct","macro_scenario"]].tail(6).to_string(index=False))
    return merged


# ── Snowflake load ─────────────────────────────────────────────────────────────
def load_to_snowflake(df: pd.DataFrame):
    print("\nConnecting to Snowflake...")
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()
    cur.execute("USE DATABASE FINANCIAL_ANALYTICS")
    cur.execute("USE SCHEMA RAW")

    cur.execute("DROP TABLE IF EXISTS RAW_FRED_MACRO")
    cur.execute("""
        CREATE TABLE RAW_FRED_MACRO (
            OBS_DATE            DATE          NOT NULL,
            FED_FUNDS_RATE      FLOAT,
            YIELD_CURVE_SPREAD  FLOAT,
            UNEMPLOYMENT_RATE   FLOAT,
            CPI_INDEX           FLOAT,
            MORTGAGE_30YR_RATE  FLOAT,
            CPI_YOY_PCT         FLOAT,
            MACRO_SCENARIO      VARCHAR(20),
            CREATED_AT          TIMESTAMP_NTZ
        )
    """)

    # Uppercase columns to match Snowflake convention
    df.columns = [c.upper() for c in df.columns]

    print(f"Loading {len(df)} rows → RAW_FRED_MACRO...")
    _, _, nrows, _ = write_pandas(conn, df, "RAW_FRED_MACRO")
    print(f"✅  Loaded {nrows} rows")

    cur.execute("""
        SELECT OBS_DATE, FED_FUNDS_RATE, UNEMPLOYMENT_RATE,
               CPI_YOY_PCT, MACRO_SCENARIO
        FROM RAW_FRED_MACRO
        ORDER BY OBS_DATE DESC
        LIMIT 6
    """)
    rows = cur.fetchall()
    cols = [d[0] for d in cur.description]
    print("\nMost recent 6 months:")
    print(pd.DataFrame(rows, columns=cols).to_string(index=False))

    cur.close()
    conn.close()


if __name__ == "__main__":
    fred_df = pull_fred_data()
    load_to_snowflake(fred_df)
    print("\n✅  pull_fred_data.py — COMPLETE")
    print("    Now run: dbt run --select stg_fred_macro")
    print("    Then:    dbt run --select marts.risk marts.finance marts.executive")