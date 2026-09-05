"""
generate_accounts.py
====================
financial_analytics_dbt — Phase 1, Script 2
Generates ~120,000 bank accounts for the 50,000 customers already in RAW_CUSTOMERS,
then loads to Snowflake RAW_ACCOUNTS.

Prerequisites:
    RAW_CUSTOMERS must already exist (run generate_customers.py first).
    pip install faker snowflake-connector-python pandas numpy

Run:
    python generate_accounts.py
"""

import os
import random
import numpy as np
import pandas as pd
from datetime import datetime, date, timedelta
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

random.seed(99)
np.random.seed(99)

# ─── SNOWFLAKE CONNECTION ─────────────────────────────────────────────────────
SNOWFLAKE_CONFIG = {
    "account":   "dqmbxut-dk43290",
    "user":      "SHIVAARJULA6",
    "password":  os.environ.get("SNOWFLAKE_PASSWORD", "Shiva@123"),
    "database":  "FINANCIAL_ANALYTICS",
    "schema":    "RAW",
    "warehouse": "COMPUTE_WH",
    "role":      "ACCOUNTADMIN",
}

# ─── PRODUCT REFERENCE DATA ───────────────────────────────────────────────────
ACCOUNT_TYPES = ["CHECKING", "SAVINGS", "MONEY_MARKET", "CD", "IRA_TRADITIONAL", "IRA_ROTH"]

# How many accounts each product type tends to generate (per-customer distribution)
# Weights used to pick # of accounts per customer per product
PRODUCT_CONFIGS = {
    "CHECKING": {
        "prob_has":        0.97,   # 97% of customers have at least one
        "multi_prob":      0.15,   # 15% chance they have 2
        "balance_mean":    3_500,
        "balance_std":     4_000,
        "balance_min":     0,
        "balance_max":     150_000,
        "overdraft_limit": lambda: random.choices([0, 500, 1000, 2500], weights=[0.20, 0.35, 0.30, 0.15])[0],
        "interest_rate":   lambda: round(random.uniform(0.01, 0.05), 4),   # checking APY near 0
    },
    "SAVINGS": {
        "prob_has":        0.75,
        "multi_prob":      0.08,
        "balance_mean":    12_000,
        "balance_std":     18_000,
        "balance_min":     0,
        "balance_max":     500_000,
        "overdraft_limit": lambda: 0,
        "interest_rate":   lambda: round(random.uniform(0.35, 5.10), 4),   # HYSA range
    },
    "MONEY_MARKET": {
        "prob_has":        0.28,
        "multi_prob":      0.04,
        "balance_mean":    35_000,
        "balance_std":     45_000,
        "balance_min":     2_500,
        "balance_max":     1_000_000,
        "overdraft_limit": lambda: 0,
        "interest_rate":   lambda: round(random.uniform(3.50, 5.25), 4),
    },
    "CD": {
        "prob_has":        0.22,
        "multi_prob":      0.12,   # CD laddering — customers often have multiple
        "balance_mean":    25_000,
        "balance_std":     30_000,
        "balance_min":     1_000,
        "balance_max":     500_000,
        "overdraft_limit": lambda: 0,
        "interest_rate":   lambda: round(random.uniform(4.50, 5.50), 4),
    },
    "IRA_TRADITIONAL": {
        "prob_has":        0.18,
        "multi_prob":      0.02,
        "balance_mean":    85_000,
        "balance_std":     120_000,
        "balance_min":     0,
        "balance_max":     2_000_000,
        "overdraft_limit": lambda: 0,
        "interest_rate":   lambda: round(random.uniform(0.01, 0.05), 4),
    },
    "IRA_ROTH": {
        "prob_has":        0.15,
        "multi_prob":      0.02,
        "balance_mean":    55_000,
        "balance_std":     80_000,
        "balance_min":     0,
        "balance_max":     1_500_000,
        "overdraft_limit": lambda: 0,
        "interest_rate":   lambda: round(random.uniform(0.01, 0.05), 4),
    },
}

# CD term buckets (months)
CD_TERMS = [3, 6, 9, 12, 18, 24, 36, 48, 60]
CD_TERM_WEIGHTS = [0.08, 0.15, 0.07, 0.30, 0.15, 0.12, 0.07, 0.03, 0.03]

ACCOUNT_STATUS = ["ACTIVE", "ACTIVE", "ACTIVE", "ACTIVE", "DORMANT", "CLOSED"]
ACCOUNT_STATUS_WEIGHTS = [0.88, 0.88, 0.88, 0.88, 0.06, 0.06]   # normalized below

# ─── HELPERS ─────────────────────────────────────────────────────────────────

def skewed_balance(mean: float, std: float, low: float, high: float) -> float:
    """Log-normal distribution produces realistic right-skewed bank balances."""
    sigma = np.log1p(std / max(mean, 1))
    mu = np.log(max(mean, 1)) - 0.5 * sigma ** 2
    raw = np.random.lognormal(mean=mu, sigma=sigma)
    return round(float(np.clip(raw, low, high)), 2)


def income_balance_multiplier(income_band: str) -> float:
    return {
        "<25K": 0.35, "25K-50K": 0.65, "50K-75K": 0.90,
        "75K-100K": 1.10, "100K-150K": 1.45, "150K-250K": 2.10, "250K+": 3.80,
    }.get(income_band, 1.0)


def pick_open_date(customer_since: date, product: str) -> date:
    """Account open date: on or after customer_since, up to today."""
    days_available = (date.today() - customer_since).days
    if days_available <= 0:
        return customer_since
    # Most accounts opened soon after customer joined; long-tail for later additions
    offset = int(np.random.exponential(scale=max(days_available * 0.2, 1)))
    offset = min(offset, days_available)
    return customer_since + timedelta(days=offset)


def pick_status(open_date: date, churn_risk: float) -> str:
    """Accounts opened long ago with high churn are more likely closed/dormant."""
    age_days = (date.today() - open_date).days
    if age_days < 30:
        return "ACTIVE"
    closed_prob = 0.01 + (churn_risk / 100) * 0.12
    dormant_prob = 0.005 + (churn_risk / 100) * 0.05
    r = random.random()
    if r < closed_prob:
        return "CLOSED"
    elif r < closed_prob + dormant_prob:
        return "DORMANT"
    return "ACTIVE"


def pick_close_date(open_date: date, status: str) -> str | None:
    if status != "CLOSED":
        return None
    days_open = random.randint(30, max(31, (date.today() - open_date).days - 1))
    return (open_date + timedelta(days=days_open)).isoformat()


# ─── MAIN GENERATOR ──────────────────────────────────────────────────────────

def generate_accounts(customers_df: pd.DataFrame) -> pd.DataFrame:
    print(f"Generating accounts for {len(customers_df):,} customers...")
    records = []
    account_counter = 0

    for idx, cust in customers_df.iterrows():
        if (idx + 1) % 10_000 == 0:
            print(f"  Customer {idx + 1:,} / {len(customers_df):,}  |  Accounts so far: {len(records):,}")

        cust_id       = cust["CUSTOMER_ID"]
        since_date    = cust["CUSTOMER_SINCE_DATE"] if isinstance(cust["CUSTOMER_SINCE_DATE"], date) else date.fromisoformat(str(cust["CUSTOMER_SINCE_DATE"])[:10])
        income_band   = cust["INCOME_BAND"]
        churn_risk    = cust["CHURN_RISK_SCORE"]
        rel_tier      = cust["RELATIONSHIP_VALUE_TIER"]
        is_active_cust = cust["IS_ACTIVE"]
        bal_multiplier = income_balance_multiplier(income_band)

        for product, cfg in PRODUCT_CONFIGS.items():
            # Inactive customers have reduced product penetration
            prob = cfg["prob_has"] * (1.0 if is_active_cust else 0.55)
            if random.random() > prob:
                continue

            # How many accounts of this type
            n_accounts = 1
            if random.random() < cfg["multi_prob"]:
                n_accounts = 2

            for _ in range(n_accounts):
                account_counter += 1
                acct_id = f"ACCT{account_counter:08d}"

                open_date  = pick_open_date(since_date, product)
                status     = pick_status(open_date, churn_risk)
                close_date = pick_close_date(open_date, status)

                # Balance — zero if closed, reduced if dormant
                if status == "CLOSED":
                    balance = 0.0
                else:
                    raw_bal = skewed_balance(
                        cfg["balance_mean"] * bal_multiplier,
                        cfg["balance_std"]  * bal_multiplier,
                        cfg["balance_min"],
                        cfg["balance_max"],
                    )
                    if status == "DORMANT":
                        raw_bal *= random.uniform(0.01, 0.15)
                    balance = round(raw_bal, 2)

                interest_rate  = cfg["interest_rate"]()
                overdraft_limit = cfg["overdraft_limit"]()

                # CD-specific fields
                cd_term_months  = None
                cd_maturity_date = None
                if product == "CD":
                    cd_term_months = random.choices(CD_TERMS, weights=CD_TERM_WEIGHTS)[0]
                    cd_maturity_date = (open_date + timedelta(days=cd_term_months * 30)).isoformat()

                # Monthly fee waiver logic
                waiver_reason = None
                monthly_fee   = 0.0
                if product == "CHECKING":
                    if balance >= 1_500 or rel_tier in ("gold", "platinum"):
                        waiver_reason = "min_balance"
                        monthly_fee   = 0.0
                    else:
                        monthly_fee = round(random.choices([0, 5, 12, 15], weights=[0.3, 0.25, 0.30, 0.15])[0], 2)

                # Autopay / direct deposit flags (checking only)
                has_direct_deposit = False
                has_autopay        = False
                if product == "CHECKING" and status == "ACTIVE":
                    has_direct_deposit = random.random() < 0.62
                    has_autopay        = random.random() < 0.45

                records.append({
                    "ACCOUNT_ID":          acct_id,
                    "CUSTOMER_ID":         cust_id,
                    "ACCOUNT_TYPE":        product,
                    "ACCOUNT_STATUS":      status,
                    "OPEN_DATE":           open_date.isoformat(),
                    "CLOSE_DATE":          close_date,
                    "CURRENT_BALANCE":     balance,
                    "INTEREST_RATE":       interest_rate,
                    "OVERDRAFT_LIMIT":     overdraft_limit,
                    "CD_TERM_MONTHS":      cd_term_months,
                    "CD_MATURITY_DATE":    cd_maturity_date,
                    "MONTHLY_FEE":         monthly_fee,
                    "FEE_WAIVER_REASON":   waiver_reason,
                    "HAS_DIRECT_DEPOSIT":  has_direct_deposit,
                    "HAS_AUTOPAY":         has_autopay,
                    "CREATED_AT":          datetime.now().isoformat(),
                })

    df = pd.DataFrame(records)
    print(f"\nGenerated {len(df):,} accounts")
    print(df.groupby("ACCOUNT_TYPE")[["CURRENT_BALANCE"]].agg(["count", "mean"]).round(0))
    return df


# ─── SNOWFLAKE LOAD ───────────────────────────────────────────────────────────

def load_to_snowflake(df: pd.DataFrame):
    print("\nConnecting to Snowflake...")
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()

    cur.execute("USE DATABASE FINANCIAL_ANALYTICS")
    cur.execute("USE SCHEMA RAW")

    print("Creating RAW_ACCOUNTS table...")
    cur.execute("DROP TABLE IF EXISTS RAW_ACCOUNTS")
    cur.execute("""
        CREATE TABLE RAW_ACCOUNTS (
            ACCOUNT_ID          VARCHAR(12)    NOT NULL,
            CUSTOMER_ID         VARCHAR(12)    NOT NULL,
            ACCOUNT_TYPE        VARCHAR(20),
            ACCOUNT_STATUS      VARCHAR(10),
            OPEN_DATE           DATE,
            CLOSE_DATE          DATE,
            CURRENT_BALANCE     FLOAT,
            INTEREST_RATE       FLOAT,
            OVERDRAFT_LIMIT     FLOAT,
            CD_TERM_MONTHS      INTEGER,
            CD_MATURITY_DATE    DATE,
            MONTHLY_FEE         FLOAT,
            FEE_WAIVER_REASON   VARCHAR(30),
            HAS_DIRECT_DEPOSIT  BOOLEAN,
            HAS_AUTOPAY         BOOLEAN,
            CREATED_AT          TIMESTAMP_NTZ
        )
    """)

    print(f"Loading {len(df):,} rows → RAW_ACCOUNTS ...")
    success, nchunks, nrows, _ = write_pandas(conn, df, "RAW_ACCOUNTS")
    print(f"✅  Loaded {nrows:,} rows across {nchunks} chunk(s)")

    cur.execute("""
        SELECT
            COUNT(*)                               AS total_accounts,
            COUNT(DISTINCT CUSTOMER_ID)            AS unique_customers,
            ROUND(AVG(CURRENT_BALANCE), 0)         AS avg_balance,
            ROUND(SUM(CURRENT_BALANCE) / 1e6, 1)  AS total_deposits_mm
        FROM RAW_ACCOUNTS
        WHERE ACCOUNT_STATUS != 'CLOSED'
    """)
    row = cur.fetchone()
    print(f"    Active/Dormant: {row[0]:,} accounts | {row[1]:,} customers")
    print(f"    Avg Balance: ${row[2]:,.0f} | Total Deposits: ${row[3]:.1f}M")

    cur.close()
    conn.close()


# ─── ENTRY POINT ─────────────────────────────────────────────────────────────

def load_customers_from_snowflake() -> pd.DataFrame:
    """Pull the customer data we need to drive account generation."""
    print("Loading customers from Snowflake RAW_CUSTOMERS...")
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()
    cur.execute("""
        SELECT
            CUSTOMER_ID, CUSTOMER_SINCE_DATE, INCOME_BAND,
            CHURN_RISK_SCORE, RELATIONSHIP_VALUE_TIER, IS_ACTIVE
        FROM RAW_CUSTOMERS
        ORDER BY CUSTOMER_ID
    """)
    rows = cur.fetchall()
    cols = [desc[0].upper() for desc in cur.description]
    cur.close()
    conn.close()
    df = pd.DataFrame(rows, columns=cols)
    print(f"  Loaded {len(df):,} customers")
    return df


if __name__ == "__main__":
    customers_df = load_customers_from_snowflake()
    accounts_df  = generate_accounts(customers_df)
    load_to_snowflake(accounts_df)
    print("\n✅  generate_accounts.py — COMPLETE")
    print(f"    Total accounts generated: {len(accounts_df):,}")
    print("    Next: run generate_transactions.py")