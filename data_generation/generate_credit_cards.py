"""
generate_credit_cards.py
========================
financial_analytics_dbt — Phase 1, Script 5
Generates ~28,000 credit card accounts correlated to customer credit scores,
income bands, and churn risk. Includes payment behaviour, utilization,
rewards points, and fraud signals.

Run:
    python generate_credit_cards.py
"""

import os
import random
import numpy as np
import pandas as pd
from datetime import datetime, date, timedelta
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

random.seed(66)
np.random.seed(66)

SNOWFLAKE_CONFIG = {
    "account":   "dqmbxut-dk43290",
    "user":      "SHIVAARJULA6",
    "password":  os.environ.get("SNOWFLAKE_PASSWORD", "Shiva@123"),
    "database":  "FINANCIAL_ANALYTICS",
    "schema":    "RAW",
    "warehouse": "COMPUTE_WH",
    "role":      "ACCOUNTADMIN",
}

TODAY = date.today()

# ── Card product configs ───────────────────────────────────────────────────────
# Products ordered from mass-market to premium
CARD_PRODUCTS = {
    "SECURED": {
        "prob_has":        0.08,       # subprime customers only
        "min_credit_score": 300,
        "max_credit_score": 640,
        "credit_limit_mean": 500,
        "credit_limit_std":  200,
        "credit_limit_min":  200,
        "credit_limit_max":  2_000,
        "apr_base":          26.99,    # high APR for secured
        "annual_fee":        lambda: random.choice([0, 29, 39, 49]),
        "rewards_pct":       0.0,      # no rewards
        "rewards_type":      None,
    },
    "CASH_BACK": {
        "prob_has":        0.30,
        "min_credit_score": 580,
        "max_credit_score": 850,
        "credit_limit_mean": 8_000,
        "credit_limit_std":  6_000,
        "credit_limit_min":  500,
        "credit_limit_max":  35_000,
        "apr_base":          21.99,
        "annual_fee":        lambda: random.choices([0, 95], weights=[0.70, 0.30])[0],
        "rewards_pct":       0.015,    # 1.5% cash back baseline
        "rewards_type":      "CASH_BACK",
    },
    "TRAVEL_REWARDS": {
        "prob_has":        0.15,
        "min_credit_score": 680,
        "max_credit_score": 850,
        "credit_limit_mean": 18_000,
        "credit_limit_std":  12_000,
        "credit_limit_min":  5_000,
        "credit_limit_max":  75_000,
        "apr_base":          20.24,
        "annual_fee":        lambda: random.choices([95, 250, 550], weights=[0.50, 0.35, 0.15])[0],
        "rewards_pct":       0.02,     # 2x points on most categories
        "rewards_type":      "POINTS",
    },
    "PREMIUM": {
        "prob_has":        0.05,
        "min_credit_score": 740,
        "max_credit_score": 850,
        "credit_limit_mean": 45_000,
        "credit_limit_std":  30_000,
        "credit_limit_min":  15_000,
        "credit_limit_max":  200_000,
        "apr_base":          19.24,
        "annual_fee":        lambda: random.choices([495, 695], weights=[0.60, 0.40])[0],
        "rewards_pct":       0.03,
        "rewards_type":      "POINTS",
    },
    "STORE_BRANDED": {
        "prob_has":        0.12,
        "min_credit_score": 580,
        "max_credit_score": 850,
        "credit_limit_mean": 3_500,
        "credit_limit_std":  2_500,
        "credit_limit_min":  300,
        "credit_limit_max":  15_000,
        "apr_base":          29.49,    # store cards have high APR
        "annual_fee":        lambda: 0,
        "rewards_pct":       0.05,     # 5% at that store
        "rewards_type":      "STORE_CREDIT",
    },
}

# ── APR adjustment by credit score ────────────────────────────────────────────
def credit_score_apr_adj(credit_score: int) -> float:
    if credit_score >= 800: return -4.0
    if credit_score >= 750: return -2.5
    if credit_score >= 700: return -1.0
    if credit_score >= 650: return  1.5
    if credit_score >= 600: return  3.5
    return  6.0

# ── Income credit limit scaler ─────────────────────────────────────────────────
def income_limit_scale(income_band: str) -> float:
    return {
        "<25K": 0.35, "25K-50K": 0.60, "50K-75K": 0.85,
        "75K-100K": 1.00, "100K-150K": 1.40, "150K-250K": 2.00, "250K+": 3.20,
    }.get(income_band, 1.0)

# ── Payment behaviour generator ────────────────────────────────────────────────
def generate_payment_behaviour(credit_score: int, churn_risk: float):
    """
    Returns:
        payment_pattern      : FULL / MINIMUM / PARTIAL / MISSED
        months_since_missed  : None or int
        times_overlimit_12m  : int
        autopay_enrolled     : bool
    """
    # Probability of paying in full — higher credit score = more likely
    full_pay_prob   = np.clip((credit_score - 580) / 270 * 0.75 + 0.10, 0.05, 0.85)
    min_pay_prob    = np.clip(0.60 - full_pay_prob, 0.05, 0.55)
    missed_pay_prob = np.clip((100 - credit_score) / 600 + churn_risk / 500, 0.01, 0.25)

    r = random.random()
    if r < full_pay_prob:
        payment_pattern = "FULL"
    elif r < full_pay_prob + missed_pay_prob:
        payment_pattern = "MISSED"
    elif r < full_pay_prob + missed_pay_prob + min_pay_prob:
        payment_pattern = "MINIMUM"
    else:
        payment_pattern = "PARTIAL"

    months_since_missed = None
    if payment_pattern == "MISSED":
        months_since_missed = random.randint(1, 12)

    times_overlimit = random.choices(
        [0, 1, 2, 3],
        weights=[0.82, 0.10, 0.05, 0.03]
    )[0]

    autopay = (payment_pattern == "FULL") and (random.random() < 0.70)

    return payment_pattern, months_since_missed, times_overlimit, autopay

# ── Utilization generator ──────────────────────────────────────────────────────
def generate_utilization(credit_score: int, payment_pattern: str, credit_limit: float) -> tuple:
    """
    Returns (current_balance, utilization_rate, minimum_payment_due, statement_balance)
    """
    # Low credit score → higher utilization
    util_mean = np.clip(1.0 - (credit_score - 300) / 550 * 0.75, 0.05, 0.92)
    if payment_pattern == "FULL":
        util_mean = min(util_mean, 0.35)     # full payers tend to pay it down

    util = float(np.clip(np.random.beta(2, max(2, 2 / util_mean - 2)), 0.0, 0.99))

    current_balance   = round(credit_limit * util, 2)
    statement_balance = round(current_balance * random.uniform(0.90, 1.10), 2)
    minimum_payment   = round(max(25.0, statement_balance * 0.02), 2)   # 2% or $25

    return current_balance, round(util, 4), minimum_payment, statement_balance

# ── Rewards points ─────────────────────────────────────────────────────────────
def generate_rewards(rewards_pct: float, statement_balance: float, open_months: int) -> int:
    """Cumulative rewards points / cash-back cents since card opening."""
    if rewards_pct == 0:
        return 0
    monthly_spend = statement_balance * random.uniform(0.8, 1.2)
    total_earned  = monthly_spend * open_months * rewards_pct * 100   # cents / points
    redeemed      = total_earned * random.uniform(0.10, 0.70)
    return max(0, int(total_earned - redeemed))

# ── Fraud flag ─────────────────────────────────────────────────────────────────
def has_fraud_dispute(churn_risk: float) -> tuple:
    """Returns (has_dispute, dispute_amount)."""
    dispute_prob = np.clip(churn_risk / 1000 + 0.02, 0.02, 0.12)
    if random.random() < dispute_prob:
        return True, round(random.uniform(20, 3_500), 2)
    return False, 0.0

# ── Card status ────────────────────────────────────────────────────────────────
def card_status(payment_pattern: str, churn_risk: float) -> str:
    if payment_pattern == "MISSED" and churn_risk > 70:
        return random.choices(
            ["SUSPENDED", "CLOSED"],
            weights=[0.60, 0.40]
        )[0]
    if churn_risk > 85:
        return random.choices(
            ["ACTIVE", "SUSPENDED", "CLOSED"],
            weights=[0.50, 0.30, 0.20]
        )[0]
    return "ACTIVE"

# ── Main generator ─────────────────────────────────────────────────────────────
def generate_credit_cards(customers_df: pd.DataFrame) -> pd.DataFrame:
    print(f"Generating credit cards for {len(customers_df):,} customers...")
    records      = []
    card_counter = 0

    for _, cust in customers_df.iterrows():
        cust_id      = cust["CUSTOMER_ID"]
        credit_score = int(cust["CREDIT_SCORE"])
        income_band  = cust["INCOME_BAND"]
        churn_risk   = float(cust["CHURN_RISK_SCORE"])
        since_date   = cust["CUSTOMER_SINCE_DATE"]
        if isinstance(since_date, str):
            since_date = date.fromisoformat(since_date[:10])
        elif hasattr(since_date, "date"):
            since_date = since_date.date()

        limit_scale = income_limit_scale(income_band)

        for product, cfg in CARD_PRODUCTS.items():
            # Filter by credit score eligibility
            if not (cfg["min_credit_score"] <= credit_score <= cfg["max_credit_score"]):
                continue

            # Adjust probability for poor credit / high churn
            prob = cfg["prob_has"]
            if credit_score < 620 and product in ("TRAVEL_REWARDS", "PREMIUM"):
                prob *= 0.10
            if credit_score < 580 and product == "CASH_BACK":
                prob *= 0.40
            if credit_score >= 750 and product == "SECURED":
                prob *= 0.02   # almost nobody with good credit keeps a secured card

            if random.random() > prob:
                continue

            card_counter += 1
            card_id = f"CC{card_counter:08d}"

            # Credit limit
            raw_limit = np.random.lognormal(
                mean=np.log(cfg["credit_limit_mean"] * limit_scale),
                sigma=0.55
            )
            credit_limit = round(float(np.clip(raw_limit, cfg["credit_limit_min"], cfg["credit_limit_max"])), 2)

            # APR
            apr_adj = credit_score_apr_adj(credit_score)
            apr     = round(float(np.clip(cfg["apr_base"] + apr_adj + np.random.normal(0, 0.4), 9.99, 36.0)), 2)

            # Annual fee
            annual_fee = cfg["annual_fee"]()

            # Open date (sometime after customer since)
            days_tenure = max(1, (TODAY - since_date).days)
            open_offset = random.randint(0, min(days_tenure, 365 * 4))
            open_date   = since_date + timedelta(days=open_offset)
            open_months = max(1, (TODAY - open_date).days // 30)

            # Payment behaviour
            payment_pattern, months_since_missed, times_overlimit, autopay = \
                generate_payment_behaviour(credit_score, churn_risk)

            # Utilization & balances
            current_balance, util_rate, min_payment_due, statement_balance = \
                generate_utilization(credit_score, payment_pattern, credit_limit)

            # Status
            status = card_status(payment_pattern, churn_risk)
            if status in ("SUSPENDED", "CLOSED"):
                current_balance   = 0.0
                util_rate         = 0.0
                min_payment_due   = 0.0
                statement_balance = 0.0

            # Rewards
            rewards_balance = generate_rewards(cfg["rewards_pct"], statement_balance, open_months)

            # Fraud dispute
            fraud_dispute, dispute_amount = has_fraud_dispute(churn_risk)

            # Minimum payment status
            payment_status = "CURRENT"
            if payment_pattern == "MISSED":
                dpd = (months_since_missed or 1) * 30
                if dpd >= 90:   payment_status = "90DPD"
                elif dpd >= 60: payment_status = "60DPD"
                elif dpd >= 30: payment_status = "30DPD"
            elif payment_pattern == "MINIMUM":
                payment_status = "MINIMUM_PAY"

            records.append({
                "CARD_ID":                    card_id,
                "CUSTOMER_ID":               cust_id,
                "CARD_PRODUCT":              product,
                "CARD_STATUS":               status,
                "OPEN_DATE":                 open_date.isoformat(),
                "CREDIT_LIMIT":              credit_limit,
                "CURRENT_BALANCE":           current_balance,
                "STATEMENT_BALANCE":         statement_balance,
                "MINIMUM_PAYMENT_DUE":       min_payment_due,
                "ANNUAL_PERCENTAGE_RATE":    apr,
                "ANNUAL_FEE":                annual_fee,
                "UTILIZATION_RATE":          util_rate,
                "PAYMENT_PATTERN":           payment_pattern,
                "PAYMENT_STATUS":            payment_status,
                "MONTHS_SINCE_MISSED_PMT":   months_since_missed,
                "TIMES_OVERLIMIT_LAST_12M":  times_overlimit,
                "AUTOPAY_ENROLLED":          autopay,
                "REWARDS_TYPE":              cfg["rewards_type"],
                "REWARDS_BALANCE_POINTS":    rewards_balance,
                "HAS_FRAUD_DISPUTE":         fraud_dispute,
                "FRAUD_DISPUTE_AMOUNT":      dispute_amount,
                "CREATED_AT":               datetime.now().isoformat(),
            })

    df = pd.DataFrame(records)
    print(f"\nGenerated {len(df):,} credit card accounts")
    print(df["CARD_PRODUCT"].value_counts().to_string())
    print(f"\nAvg utilization : {df['UTILIZATION_RATE'].mean():.1%}")
    print(f"Active cards     : {(df['CARD_STATUS'] == 'ACTIVE').sum():,}")
    print(f"Fraud disputes   : {df['HAS_FRAUD_DISPUTE'].sum():,}")
    print(f"Total credit exp.: ${df['CREDIT_LIMIT'].sum()/1e6:.1f}M")
    print(f"Total outstanding: ${df['CURRENT_BALANCE'].sum()/1e6:.1f}M")
    return df


# ── Snowflake load ─────────────────────────────────────────────────────────────
def load_to_snowflake(df: pd.DataFrame):
    print("\nConnecting to Snowflake...")
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()
    cur.execute("USE DATABASE FINANCIAL_ANALYTICS")
    cur.execute("USE SCHEMA RAW")

    cur.execute("DROP TABLE IF EXISTS RAW_CREDIT_CARDS")
    cur.execute("""
        CREATE TABLE RAW_CREDIT_CARDS (
            CARD_ID                   VARCHAR(12)   NOT NULL,
            CUSTOMER_ID               VARCHAR(12)   NOT NULL,
            CARD_PRODUCT              VARCHAR(20),
            CARD_STATUS               VARCHAR(12),
            OPEN_DATE                 DATE,
            CREDIT_LIMIT              FLOAT,
            CURRENT_BALANCE           FLOAT,
            STATEMENT_BALANCE         FLOAT,
            MINIMUM_PAYMENT_DUE       FLOAT,
            ANNUAL_PERCENTAGE_RATE    FLOAT,
            ANNUAL_FEE                FLOAT,
            UTILIZATION_RATE          FLOAT,
            PAYMENT_PATTERN           VARCHAR(10),
            PAYMENT_STATUS            VARCHAR(15),
            MONTHS_SINCE_MISSED_PMT   INTEGER,
            TIMES_OVERLIMIT_LAST_12M  INTEGER,
            AUTOPAY_ENROLLED          BOOLEAN,
            REWARDS_TYPE              VARCHAR(20),
            REWARDS_BALANCE_POINTS    INTEGER,
            HAS_FRAUD_DISPUTE         BOOLEAN,
            FRAUD_DISPUTE_AMOUNT      FLOAT,
            CREATED_AT                TIMESTAMP_NTZ
        )
    """)

    print(f"Loading {len(df):,} rows → RAW_CREDIT_CARDS...")
    _, _, nrows, _ = write_pandas(conn, df, "RAW_CREDIT_CARDS")
    print(f"✅  Loaded {nrows:,} rows")

    cur.execute("""
        SELECT
            COUNT(*)                                   AS total_cards,
            COUNT(DISTINCT CUSTOMER_ID)                AS unique_customers,
            ROUND(SUM(CREDIT_LIMIT)/1e6, 1)           AS total_limit_mm,
            ROUND(SUM(CURRENT_BALANCE)/1e6, 1)        AS total_balance_mm,
            ROUND(AVG(UTILIZATION_RATE)*100, 1)       AS avg_util_pct,
            SUM(CASE WHEN HAS_FRAUD_DISPUTE THEN 1 ELSE 0 END) AS disputes
        FROM RAW_CREDIT_CARDS
    """)
    r = cur.fetchone()
    print(f"    Cards: {r[0]:,} | Customers: {r[1]:,}")
    print(f"    Total Limit: ${r[2]:.1f}M | Outstanding: ${r[3]:.1f}M")
    print(f"    Avg Utilization: {r[4]}% | Fraud Disputes: {r[5]:,}")
    cur.close()
    conn.close()


def fetch(query: str) -> pd.DataFrame:
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()
    cur.execute(query)
    rows = cur.fetchall()
    cols = [d[0].upper() for d in cur.description]
    cur.close(); conn.close()
    return pd.DataFrame(rows, columns=cols)


if __name__ == "__main__":
    customers_df = fetch("""
        SELECT CUSTOMER_ID, CREDIT_SCORE, INCOME_BAND,
               CHURN_RISK_SCORE, CUSTOMER_SINCE_DATE
        FROM RAW_CUSTOMERS ORDER BY CUSTOMER_ID
    """)
    print(f"Loaded {len(customers_df):,} customers")
    cards_df = generate_credit_cards(customers_df)
    load_to_snowflake(cards_df)
    print("\n✅  generate_credit_cards.py — COMPLETE")
    print("    Next: run pull_fred_data.py")