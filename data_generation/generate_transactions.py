"""
generate_transactions.py  (v2 — vectorized)
============================================
financial_analytics_dbt — Phase 1, Script 3
Generates ~1.5M realistic transactions for all ACTIVE accounts using
numpy vectorized operations. Runs in 2-4 minutes instead of hours.

Run:
    python generate_transactions.py
"""

import os
import random
import numpy as np
import pandas as pd
from datetime import datetime, date, timedelta
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

np.random.seed(77)
random.seed(77)

SNOWFLAKE_CONFIG = {
    "account":   "dqmbxut-dk43290",
    "user":      "SHIVAARJULA6",
    "password":  os.environ.get("SNOWFLAKE_PASSWORD", "Shiva@123"),
    "database":  "FINANCIAL_ANALYTICS",
    "schema":    "RAW",
    "warehouse": "COMPUTE_WH",
    "role":      "ACCOUNTADMIN",
}

LOOKBACK_DAYS = 365        # 12 months of history — enough for all mart calculations
CHUNK_SIZE    = 300_000    # rows per Snowflake PUT
TODAY         = date.today()
WINDOW_START  = TODAY - timedelta(days=LOOKBACK_DAYS)

# ── Category master ────────────────────────────────────────────────────────────
# Each entry: (category, mcc, is_debit, weight_for_checking)
CHECKING_CATS = [
    ("groceries",        "5411", True,  18),
    ("dining",           "5812", True,  14),
    ("gas_station",      "5541", True,  10),
    ("utilities",        "4900", True,   8),
    ("streaming",        "7994", True,   6),
    ("amazon",           "5999", True,   9),
    ("clothing",         "5651", True,   6),
    ("pharmacy",         "5912", True,   5),
    ("home_improvement", "5251", True,   4),
    ("entertainment",    "7832", True,   4),
    ("travel",           "4722", True,   3),
    ("atm_withdrawal",   "6011", True,   5),
    ("fee",              "6012", True,   2),
    ("payroll",          "6012", False, 12),   # credit
    ("transfer_in",      "6012", False,  6),   # credit
    ("refund",           "9999", False,  3),   # credit
    ("interest",         "6012", False,  2),   # credit
]
CAT_NAMES    = [c[0] for c in CHECKING_CATS]
CAT_MCCS     = [c[1] for c in CHECKING_CATS]
CAT_IS_DEBIT = [c[2] for c in CHECKING_CATS]
CAT_WEIGHTS  = np.array([c[3] for c in CHECKING_CATS], dtype=float)
CAT_WEIGHTS /= CAT_WEIGHTS.sum()

SAVINGS_CATS = [
    ("interest",      "6012", False, 60),
    ("transfer_in",   "6012", False, 25),
    ("transfer_out",  "6012", True,  15),
]

MERCHANTS = {
    "groceries":        ["Whole Foods","Kroger","Safeway","Trader Joe's","Costco","Walmart"],
    "dining":           ["McDonald's","Chipotle","Starbucks","Olive Garden","DoorDash","Uber Eats"],
    "gas_station":      ["Shell","BP","Chevron","ExxonMobil","Speedway"],
    "utilities":        ["Xcel Energy","ComEd","Duke Energy","Dominion Energy"],
    "streaming":        ["Netflix","Spotify","Disney+","Hulu","Apple TV+"],
    "amazon":           ["Amazon","Amazon Prime","Amazon Marketplace"],
    "clothing":         ["Target","H&M","Gap","Old Navy","Zara"],
    "pharmacy":         ["CVS","Walgreens","Rite Aid"],
    "home_improvement": ["Home Depot","Lowe's","Ace Hardware"],
    "entertainment":    ["AMC Theaters","Live Nation","Ticketmaster"],
    "travel":           ["Delta Airlines","Southwest","Marriott","Airbnb"],
    "atm_withdrawal":   ["ATM Withdrawal"],
    "fee":              ["Service Fee","Overdraft Fee"],
    "payroll":          ["Payroll Direct Deposit"],
    "transfer_in":      ["Internal Transfer In"],
    "transfer_out":     ["Internal Transfer Out"],
    "refund":           ["Merchant Refund"],
    "interest":         ["Interest Credit"],
}

CHANNELS = ["mobile","online","pos","atm","branch"]
CHANNEL_W = [0.42, 0.22, 0.22, 0.08, 0.06]

# Amount ranges by category (min, max)
AMT_RANGES = {
    "groceries":        (25,   280),
    "dining":           (8,    95),
    "gas_station":      (30,   120),
    "utilities":        (60,   350),
    "streaming":        (8,    25),
    "amazon":           (12,   400),
    "clothing":         (20,   300),
    "pharmacy":         (10,   150),
    "home_improvement": (20,   800),
    "entertainment":    (12,   200),
    "travel":           (150,  2500),
    "atm_withdrawal":   (40,   500),
    "fee":              (5,    35),
    "payroll":          (1500, 8000),
    "transfer_in":      (100,  5000),
    "transfer_out":     (100,  5000),
    "refund":           (10,   300),
    "interest":         (1,    80),
}

INCOME_SCALE = {
    "<25K": 0.55, "25K-50K": 0.75, "50K-75K": 0.95,
    "75K-100K": 1.05, "100K-150K": 1.25, "150K-250K": 1.60, "250K+": 2.30,
}

# ── Monthly transaction volume by account type ─────────────────────────────────
MONTHLY_VOL = {
    "CHECKING":         (15, 40),
    "SAVINGS":          (2,  6),
    "MONEY_MARKET":     (1,  4),
    "CD":               (1,  1),
    "IRA_TRADITIONAL":  (0,  2),
    "IRA_ROTH":         (0,  2),
}


# ── Core vectorized generator ──────────────────────────────────────────────────

def generate_transactions(accounts_df: pd.DataFrame, customers_df: pd.DataFrame) -> pd.DataFrame:
    print(f"Generating transactions for {len(accounts_df):,} accounts...")
    print(f"Window: {WINDOW_START} → {TODAY}  ({LOOKBACK_DAYS} days / ~{LOOKBACK_DAYS//30} months)")

    cust_map = customers_df.set_index("CUSTOMER_ID")[["INCOME_BAND", "CHURN_RISK_SCORE"]].to_dict("index")

    all_chunks = []
    total_txns = 0
    months     = LOOKBACK_DAYS // 30

    for _, acct in accounts_df.iterrows():
        if acct["ACCOUNT_STATUS"] == "CLOSED":
            continue

        acct_id    = acct["ACCOUNT_ID"]
        cust_id    = acct["CUSTOMER_ID"]
        acct_type  = acct["ACCOUNT_TYPE"]
        open_dt    = acct["OPEN_DATE"]
        if isinstance(open_dt, str):
            open_dt = date.fromisoformat(open_dt[:10])
        elif hasattr(open_dt, 'date'):
            open_dt = open_dt.date()

        cinfo      = cust_map.get(cust_id, {})
        income_band= cinfo.get("INCOME_BAND", "50K-75K")
        scale      = INCOME_SCALE.get(income_band, 1.0)
        is_dormant = acct["ACCOUNT_STATUS"] == "DORMANT"

        vol_lo, vol_hi = MONTHLY_VOL.get(acct_type, (2, 8))
        if is_dormant:
            vol_lo, vol_hi = 0, 1

        # Total transactions for this account over the window
        n_txns = np.random.randint(vol_lo, vol_hi + 1) * months
        if n_txns == 0:
            continue

        # Random dates within window (after account open date)
        eff_start  = max(open_dt, WINDOW_START)
        date_range = (TODAY - eff_start).days
        if date_range <= 0:
            continue

        offsets    = np.random.randint(0, date_range, size=n_txns)
        txn_dates  = [eff_start + timedelta(days=int(d)) for d in offsets]

        # Category selection
        if acct_type == "CHECKING":
            cat_indices = np.random.choice(len(CHECKING_CATS), size=n_txns, p=CAT_WEIGHTS)
            categories  = [CAT_NAMES[i]    for i in cat_indices]
            mccs        = [CAT_MCCS[i]     for i in cat_indices]
            is_debits   = [CAT_IS_DEBIT[i] for i in cat_indices]
        elif acct_type == "SAVINGS":
            sw = np.array([c[3] for c in SAVINGS_CATS], dtype=float); sw /= sw.sum()
            cat_indices = np.random.choice(len(SAVINGS_CATS), size=n_txns, p=sw)
            categories  = [SAVINGS_CATS[i][0] for i in cat_indices]
            mccs        = [SAVINGS_CATS[i][1] for i in cat_indices]
            is_debits   = [SAVINGS_CATS[i][2] for i in cat_indices]
        else:
            categories  = ["interest"] * n_txns
            mccs        = ["6012"]     * n_txns
            is_debits   = [False]      * n_txns

        # Amounts via log-normal
        amounts = []
        for cat in categories:
            lo, hi = AMT_RANGES.get(cat, (10, 200))
            lo = max(lo * scale, 0.50)
            hi = hi * scale
            mu    = (np.log(lo) + np.log(hi)) / 2
            sigma = max((np.log(hi) - np.log(lo)) / 4, 0.01)
            amt   = float(np.clip(np.random.lognormal(mu, sigma), lo, hi))
            amounts.append(round(amt, 2))

        # Fraud signal (~0.3% of debits — large, off-hours amount)
        fraud_flags = [
            (is_deb and random.random() < 0.003)
            for is_deb in is_debits
        ]
        amounts = [
            round(a * random.uniform(3, 8), 2) if f else a
            for a, f in zip(amounts, fraud_flags)
        ]

        # Hours
        hours = []
        for cat, is_fraud in zip(categories, fraud_flags):
            if is_fraud:
                hours.append(3)
            elif cat in ("payroll", "interest", "transfer_in", "transfer_out"):
                hours.append(random.randint(8, 17))
            elif cat == "dining":
                hours.append(random.choices([7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22],
                                            weights=[2,3,4,5,10,15,12,6,5,5,8,15,12,8,5,3])[0])
            else:
                hours.append(random.randint(8, 20))

        # Build rows
        merchants  = [random.choice(MERCHANTS.get(c, ["Merchant"])) for c in categories]
        channels   = random.choices(CHANNELS, weights=CHANNEL_W, k=n_txns)

        chunk = pd.DataFrame({
            "TRANSACTION_ID":          [f"TXN{cust_id[4:]}{i:07d}" for i in range(total_txns + 1, total_txns + n_txns + 1)],
            "ACCOUNT_ID":              acct_id,
            "CUSTOMER_ID":             cust_id,
            "TRANSACTION_DATE":        [
                datetime(d.year, d.month, d.day, h, random.randint(0,59), random.randint(0,59))
                for d, h in zip(txn_dates, hours)
            ],
            "TRANSACTION_TYPE":        ["DEBIT" if d else "CREDIT" for d in is_debits],
            "TRANSACTION_CATEGORY":    categories,
            "MERCHANT_CATEGORY_CODE":  mccs,
            "MERCHANT_NAME":           merchants,
            "CHANNEL":                 channels,
            "AMOUNT":                  amounts,
            "BALANCE_AFTER":           acct["CURRENT_BALANCE"],   # snapshot — not running
            "IS_FRAUD_SIGNAL":         fraud_flags,
            "CREATED_AT":              datetime.now(),
        })
        all_chunks.append(chunk)
        total_txns += n_txns

        if len(all_chunks) % 5_000 == 0:
            print(f"  Accounts: {len(all_chunks):,} | Transactions so far: {total_txns:,}")

    print(f"\nCombining {len(all_chunks):,} account batches...")
    df = pd.concat(all_chunks, ignore_index=True)
    df.sort_values("TRANSACTION_DATE", inplace=True)
    df.reset_index(drop=True, inplace=True)
    # Unique transaction IDs after sort
    df["TRANSACTION_ID"] = [f"TXN{i+1:010d}" for i in range(len(df))]

    print(f"Total transactions: {len(df):,}")
    print(f"Date range: {df['TRANSACTION_DATE'].min().date()} → {df['TRANSACTION_DATE'].max().date()}")
    print(f"Fraud signals: {df['IS_FRAUD_SIGNAL'].sum():,}")
    print(df["TRANSACTION_CATEGORY"].value_counts().head(8).to_string())
    return df


# ── Snowflake load ─────────────────────────────────────────────────────────────

def load_to_snowflake(df: pd.DataFrame):
    print("\nConnecting to Snowflake...")
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()
    cur.execute("USE DATABASE FINANCIAL_ANALYTICS")
    cur.execute("USE SCHEMA RAW")

    print("Creating RAW_TRANSACTIONS...")
    cur.execute("DROP TABLE IF EXISTS RAW_TRANSACTIONS")
    cur.execute("""
        CREATE TABLE RAW_TRANSACTIONS (
            TRANSACTION_ID          VARCHAR(20)   NOT NULL,
            ACCOUNT_ID              VARCHAR(12)   NOT NULL,
            CUSTOMER_ID             VARCHAR(12)   NOT NULL,
            TRANSACTION_DATE        TIMESTAMP_NTZ NOT NULL,
            TRANSACTION_TYPE        VARCHAR(6),
            TRANSACTION_CATEGORY    VARCHAR(30),
            MERCHANT_CATEGORY_CODE  VARCHAR(6),
            MERCHANT_NAME           VARCHAR(60),
            CHANNEL                 VARCHAR(15),
            AMOUNT                  FLOAT,
            BALANCE_AFTER           FLOAT,
            IS_FRAUD_SIGNAL         BOOLEAN,
            CREATED_AT              TIMESTAMP_NTZ
        )
    """)

    total   = len(df)
    loaded  = 0
    chunk_n = 0
    print(f"Loading {total:,} rows in {CHUNK_SIZE:,}-row chunks...")
    for start in range(0, total, CHUNK_SIZE):
        chunk   = df.iloc[start:start + CHUNK_SIZE].copy()
        chunk_n += 1
        _, _, nrows, _ = write_pandas(conn, chunk, "RAW_TRANSACTIONS")
        loaded += nrows
        print(f"  Chunk {chunk_n}: {nrows:,} rows  ({loaded/total*100:.1f}%)")

    cur.execute("""
        SELECT COUNT(*), COUNT(DISTINCT ACCOUNT_ID),
               SUM(IS_FRAUD_SIGNAL::INT),
               MIN(TRANSACTION_DATE)::DATE, MAX(TRANSACTION_DATE)::DATE
        FROM RAW_TRANSACTIONS
    """)
    r = cur.fetchone()
    print(f"\n✅  Loaded {r[0]:,} rows | {r[1]:,} accounts | {r[2]:,} fraud signals")
    print(f"    Date range: {r[3]} → {r[4]}")
    cur.close()
    conn.close()


# ── Data loaders ──────────────────────────────────────────────────────────────

def fetch(query: str) -> pd.DataFrame:
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()
    cur.execute(query)
    rows = cur.fetchall()
    cols = [d[0].upper() for d in cur.description]
    cur.close(); conn.close()
    return pd.DataFrame(rows, columns=cols)


if __name__ == "__main__":
    print("Loading accounts...")
    accounts_df = fetch("""
        SELECT ACCOUNT_ID, CUSTOMER_ID, ACCOUNT_TYPE, ACCOUNT_STATUS,
               OPEN_DATE, CURRENT_BALANCE, HAS_DIRECT_DEPOSIT
        FROM RAW_ACCOUNTS ORDER BY ACCOUNT_ID
    """)
    print(f"  {len(accounts_df):,} accounts loaded")

    print("Loading customers...")
    customers_df = fetch("""
        SELECT CUSTOMER_ID, INCOME_BAND, CHURN_RISK_SCORE
        FROM RAW_CUSTOMERS ORDER BY CUSTOMER_ID
    """)
    print(f"  {len(customers_df):,} customers loaded")

    txn_df = generate_transactions(accounts_df, customers_df)
    load_to_snowflake(txn_df)
    print(f"\n✅  generate_transactions.py — COMPLETE  ({len(txn_df):,} rows)")
    print("    Next: run generate_loans.py")