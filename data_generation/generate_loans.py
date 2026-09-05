"""
generate_loans.py
=================
financial_analytics_dbt — Phase 1, Script 4
Generates ~35,000 loan records (AUTO, MORTGAGE, PERSONAL, HELOC)
correlated to customer credit scores and income bands.
Includes all CECL inputs: PD, LGD, EAD, delinquency history.

Run:
    python generate_loans.py
"""

import os
import random
import numpy as np
import pandas as pd
from datetime import datetime, date, timedelta
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

random.seed(55)
np.random.seed(55)

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

# ── Loan product configs ───────────────────────────────────────────────────────
# prob_has = probability a customer has this loan type
LOAN_PRODUCTS = {
    "AUTO": {
        "prob_has":       0.28,
        "term_months":    [24, 36, 48, 60, 72, 84],
        "term_weights":   [0.05, 0.10, 0.20, 0.35, 0.20, 0.10],
        "principal_mean": 28_000,
        "principal_std":  15_000,
        "principal_min":  5_000,
        "principal_max":  95_000,
        "rate_base":      6.5,     # APR base %
        "ltv_mean":       0.82,
        "ltv_std":        0.12,
    },
    "MORTGAGE": {
        "prob_has":       0.22,
        "term_months":    [180, 360],          # 15yr or 30yr
        "term_weights":   [0.25, 0.75],
        "principal_mean": 320_000,
        "principal_std":  180_000,
        "principal_min":  80_000,
        "principal_max":  1_500_000,
        "rate_base":      6.8,
        "ltv_mean":       0.78,
        "ltv_std":        0.10,
    },
    "PERSONAL": {
        "prob_has":       0.20,
        "term_months":    [12, 24, 36, 48, 60],
        "term_weights":   [0.10, 0.20, 0.35, 0.20, 0.15],
        "principal_mean": 12_000,
        "principal_std":  10_000,
        "principal_min":  1_000,
        "principal_max":  100_000,
        "rate_base":      11.5,
        "ltv_mean":       None,    # unsecured
        "ltv_std":        None,
    },
    "HELOC": {
        "prob_has":       0.10,
        "term_months":    [120],               # 10yr draw period
        "term_weights":   [1.0],
        "principal_mean": 75_000,
        "principal_std":  50_000,
        "principal_min":  10_000,
        "principal_max":  500_000,
        "rate_base":      8.5,
        "ltv_mean":       0.70,
        "ltv_std":        0.10,
    },
}

# ── Credit-score adjustments ───────────────────────────────────────────────────
def credit_score_rate_adj(credit_score: int) -> float:
    """Better credit = lower rate. Returns percentage points adjustment."""
    if credit_score >= 800: return -2.0
    if credit_score >= 750: return -1.2
    if credit_score >= 700: return -0.5
    if credit_score >= 650: return  0.5
    if credit_score >= 600: return  1.8
    return  3.5

def income_principal_scale(income_band: str) -> float:
    return {
        "<25K": 0.40, "25K-50K": 0.65, "50K-75K": 0.85,
        "75K-100K": 1.00, "100K-150K": 1.25, "150K-250K": 1.70, "250K+": 2.50,
    }.get(income_band, 1.0)

# ── CECL probability of default ───────────────────────────────────────────────
def estimate_pd(credit_score: int, loan_type: str, days_past_due: int) -> float:
    """
    Probability of Default — simplified but defensible for a portfolio project.
    Based on credit score tier, product risk, and current delinquency.
    """
    base_pd = {
        "AUTO":     0.025,
        "MORTGAGE": 0.015,
        "PERSONAL": 0.055,
        "HELOC":    0.030,
    }.get(loan_type, 0.04)

    # Credit score adjustment
    score_adj = {
        (800, 850): -0.010,
        (750, 800): -0.007,
        (700, 750): -0.003,
        (650, 700):  0.005,
        (600, 650):  0.015,
        (300, 600):  0.035,
    }
    for (lo, hi), adj in score_adj.items():
        if lo <= credit_score < hi:
            base_pd += adj
            break

    # Delinquency multiplier
    if days_past_due >= 90:   base_pd *= 4.0
    elif days_past_due >= 60: base_pd *= 2.5
    elif days_past_due >= 30: base_pd *= 1.8

    return round(float(np.clip(base_pd + np.random.normal(0, 0.005), 0.001, 0.95)), 4)

def estimate_lgd(loan_type: str, ltv: float | None) -> float:
    """Loss Given Default — lower for secured loans with good LTV."""
    base = {"AUTO": 0.40, "MORTGAGE": 0.25, "PERSONAL": 0.75, "HELOC": 0.35}.get(loan_type, 0.50)
    if ltv is not None:
        # High LTV = less collateral coverage = higher loss
        base += (ltv - 0.70) * 0.3
    return round(float(np.clip(base + np.random.normal(0, 0.03), 0.05, 0.95)), 4)

# ── Monthly payment calculator ─────────────────────────────────────────────────
def monthly_payment(principal: float, annual_rate_pct: float, term_months: int) -> float:
    r = (annual_rate_pct / 100) / 12
    if r == 0:
        return round(principal / term_months, 2)
    pmt = principal * r * (1 + r) ** term_months / ((1 + r) ** term_months - 1)
    return round(pmt, 2)

# ── Delinquency generator ─────────────────────────────────────────────────────
def generate_delinquency(credit_score: int, churn_risk: float):
    """Returns (days_past_due, times_30dpd, times_60dpd)."""
    # Higher churn risk and lower credit → more delinquency
    dpd_prob = np.clip((100 - credit_score) / 1000 + churn_risk / 500, 0.01, 0.40)

    if random.random() < dpd_prob:
        dpd = random.choices(
            [30, 60, 90, 120],
            weights=[0.55, 0.25, 0.13, 0.07]
        )[0]
    else:
        dpd = 0

    times_30 = random.choices([0,1,2,3], weights=[0.70,0.18,0.08,0.04])[0]
    times_60 = min(times_30, random.choices([0,1,2], weights=[0.80,0.15,0.05])[0])
    return dpd, times_30, times_60

# ── Loan status from delinquency ──────────────────────────────────────────────
def loan_status(dpd: int, is_paid_off: bool, is_charged_off: bool) -> str:
    if is_charged_off: return "CHARGED_OFF"
    if is_paid_off:    return "PAID_OFF"
    if dpd >= 90:      return "90DPD"
    if dpd >= 60:      return "60DPD"
    if dpd >= 30:      return "30DPD"
    return "CURRENT"

# ── Main generator ────────────────────────────────────────────────────────────
def generate_loans(customers_df: pd.DataFrame) -> pd.DataFrame:
    print(f"Generating loans for {len(customers_df):,} customers...")
    records = []
    loan_counter = 0

    for _, cust in customers_df.iterrows():
        cust_id      = cust["CUSTOMER_ID"]
        credit_score = int(cust["CREDIT_SCORE"])
        income_band  = cust["INCOME_BAND"]
        churn_risk   = float(cust["CHURN_RISK_SCORE"])
        since_date   = cust["CUSTOMER_SINCE_DATE"]
        if isinstance(since_date, str):
            since_date = date.fromisoformat(since_date[:10])
        elif hasattr(since_date, 'date'):
            since_date = since_date.date()

        scale = income_principal_scale(income_band)

        for loan_type, cfg in LOAN_PRODUCTS.items():
            # Mortgage and HELOC less likely for low income / poor credit
            prob = cfg["prob_has"]
            if loan_type in ("MORTGAGE", "HELOC"):
                if credit_score < 620 or income_band in ("<25K", "25K-50K"):
                    prob *= 0.25
            if credit_score < 580 and loan_type == "AUTO":
                prob *= 0.60

            if random.random() > prob:
                continue

            loan_counter += 1
            loan_id = f"LOAN{loan_counter:07d}"

            # Principal
            raw_principal = np.random.lognormal(
                mean=np.log(cfg["principal_mean"] * scale),
                sigma=0.45
            )
            principal = round(float(np.clip(raw_principal, cfg["principal_min"], cfg["principal_max"])), 2)

            # Term
            term = random.choices(cfg["term_months"], weights=cfg["term_weights"])[0]

            # Rate
            rate_adj = credit_score_rate_adj(credit_score)
            apr = round(float(np.clip(cfg["rate_base"] + rate_adj + np.random.normal(0, 0.3), 2.5, 29.9)), 2)

            # Origination date (sometime during customer tenure)
            days_since = (TODAY - since_date).days
            if days_since <= 0:
                orig_offset = 0
            else:
                orig_offset = random.randint(0, min(days_since, 365 * 5))
            orig_date = since_date + timedelta(days=orig_offset)
            maturity_date = orig_date + timedelta(days=term * 30)

            # How far along is the loan?
            months_elapsed = max(1, (TODAY - orig_date).days // 30)
            pct_paid = min(months_elapsed / term, 1.0)
            is_paid_off   = (pct_paid >= 1.0) and random.random() < 0.85
            is_charged_off = (not is_paid_off) and credit_score < 580 and random.random() < 0.05

            current_balance = 0.0 if (is_paid_off or is_charged_off) else round(principal * (1 - pct_paid * 0.9), 2)

            # LTV (secured loans)
            ltv = None
            if cfg["ltv_mean"] is not None:
                ltv = round(float(np.clip(np.random.normal(cfg["ltv_mean"], cfg["ltv_std"]), 0.10, 1.20)), 3)

            # DTI
            monthly_income_est = {
                "<25K": 1800, "25K-50K": 3200, "50K-75K": 4800,
                "75K-100K": 6800, "100K-150K": 9500, "150K-250K": 15000, "250K+": 28000,
            }.get(income_band, 5000)
            pmt = monthly_payment(principal, apr, term)
            dti = round(float(np.clip(pmt / monthly_income_est + np.random.normal(0, 0.03), 0.02, 0.65)), 3)

            # Delinquency
            dpd, times_30, times_60 = generate_delinquency(credit_score, churn_risk)
            status = loan_status(dpd, is_paid_off, is_charged_off)

            # CECL inputs
            pd_est  = estimate_pd(credit_score, loan_type, dpd)
            lgd_est = estimate_lgd(loan_type, ltv)
            ead     = current_balance

            records.append({
                "LOAN_ID":                  loan_id,
                "CUSTOMER_ID":              cust_id,
                "LOAN_TYPE":                loan_type,
                "LOAN_STATUS":              status,
                "ORIGINATION_DATE":         orig_date.isoformat(),
                "MATURITY_DATE":            maturity_date.isoformat(),
                "TERM_MONTHS":              term,
                "ORIGINAL_PRINCIPAL":       principal,
                "CURRENT_BALANCE":          current_balance,
                "MONTHLY_PAYMENT":          pmt,
                "INTEREST_RATE":            apr,
                "ANNUAL_PERCENTAGE_RATE":   apr,
                "DAYS_PAST_DUE":            dpd,
                "TIMES_30DPD_LAST_12M":     times_30,
                "TIMES_60DPD_LAST_12M":     times_60,
                "LOAN_TO_VALUE_RATIO":      ltv,
                "DEBT_TO_INCOME_RATIO":     dti,
                "PROBABILITY_OF_DEFAULT":   pd_est,
                "LOSS_GIVEN_DEFAULT":       lgd_est,
                "EXPOSURE_AT_DEFAULT":      ead,
                "CREATED_AT":              datetime.now().isoformat(),
            })

    df = pd.DataFrame(records)
    print(f"\nGenerated {len(df):,} loans")
    print(df["LOAN_TYPE"].value_counts().to_string())
    print(f"Active loans: {(df['LOAN_STATUS'] == 'CURRENT').sum():,}")
    print(f"Delinquent:   {df['LOAN_STATUS'].isin(['30DPD','60DPD','90DPD']).sum():,}")
    return df


# ── Snowflake load ─────────────────────────────────────────────────────────────
def load_to_snowflake(df: pd.DataFrame):
    print("\nConnecting to Snowflake...")
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()
    cur.execute("USE DATABASE FINANCIAL_ANALYTICS")
    cur.execute("USE SCHEMA RAW")

    cur.execute("DROP TABLE IF EXISTS RAW_LOANS")
    cur.execute("""
        CREATE TABLE RAW_LOANS (
            LOAN_ID                 VARCHAR(12)  NOT NULL,
            CUSTOMER_ID             VARCHAR(12)  NOT NULL,
            LOAN_TYPE               VARCHAR(15),
            LOAN_STATUS             VARCHAR(15),
            ORIGINATION_DATE        DATE,
            MATURITY_DATE           DATE,
            TERM_MONTHS             INTEGER,
            ORIGINAL_PRINCIPAL      FLOAT,
            CURRENT_BALANCE         FLOAT,
            MONTHLY_PAYMENT         FLOAT,
            INTEREST_RATE           FLOAT,
            ANNUAL_PERCENTAGE_RATE  FLOAT,
            DAYS_PAST_DUE           INTEGER,
            TIMES_30DPD_LAST_12M    INTEGER,
            TIMES_60DPD_LAST_12M    INTEGER,
            LOAN_TO_VALUE_RATIO     FLOAT,
            DEBT_TO_INCOME_RATIO    FLOAT,
            PROBABILITY_OF_DEFAULT  FLOAT,
            LOSS_GIVEN_DEFAULT      FLOAT,
            EXPOSURE_AT_DEFAULT     FLOAT,
            CREATED_AT              TIMESTAMP_NTZ
        )
    """)

    print(f"Loading {len(df):,} rows → RAW_LOANS...")
    _, _, nrows, _ = write_pandas(conn, df, "RAW_LOANS")
    print(f"✅  Loaded {nrows:,} rows")

    cur.execute("SELECT COUNT(*), ROUND(SUM(ORIGINAL_PRINCIPAL)/1e6,1), ROUND(SUM(CURRENT_BALANCE)/1e6,1) FROM RAW_LOANS")
    r = cur.fetchone()
    print(f"    Loans: {r[0]:,} | Originated: ${r[1]:.1f}M | Outstanding: ${r[2]:.1f}M")
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
    loans_df = generate_loans(customers_df)
    load_to_snowflake(loans_df)
    print("\n✅  generate_loans.py — COMPLETE")
    print("    Next: run generate_credit_cards.py")