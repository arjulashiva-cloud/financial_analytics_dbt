"""
generate_customers.py
=====================
financial_analytics_dbt — Phase 1, Script 1
Generates 50,000 realistic retail banking customers and loads to Snowflake RAW schema.

Install dependencies first:
    pip install faker snowflake-connector-python pandas numpy

Run:
    python generate_customers.py
"""

import os
import random
import numpy as np
import pandas as pd
from datetime import datetime, date, timedelta
from faker import Faker
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

fake = Faker("en_US")
random.seed(42)
np.random.seed(42)
Faker.seed(42)

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

# ─── REFERENCE DATA ───────────────────────────────────────────────────────────
US_METRO_AREAS = [
    ("New York",       "NY", "10001"), ("Los Angeles",  "CA", "90001"),
    ("Chicago",        "IL", "60601"), ("Houston",      "TX", "77001"),
    ("Phoenix",        "AZ", "85001"), ("Philadelphia", "PA", "19101"),
    ("San Antonio",    "TX", "78201"), ("San Diego",    "CA", "92101"),
    ("Dallas",         "TX", "75201"), ("San Jose",     "CA", "95101"),
    ("Austin",         "TX", "78701"), ("Jacksonville", "FL", "32099"),
    ("Fort Worth",     "TX", "76101"), ("Columbus",     "OH", "43085"),
    ("Charlotte",      "NC", "28201"), ("Indianapolis", "IN", "46201"),
    ("San Francisco",  "CA", "94101"), ("Seattle",      "WA", "98101"),
    ("Denver",         "CO", "80201"), ("Nashville",    "TN", "37201"),
    ("Oklahoma City",  "OK", "73101"), ("Richmond",     "VA", "23201"),
    ("Atlanta",        "GA", "30301"), ("Miami",        "FL", "33101"),
    ("Minneapolis",    "MN", "55401"), ("Portland",     "OR", "97201"),
    ("Las Vegas",      "NV", "89101"), ("Boston",       "MA", "02101"),
    ("Detroit",        "MI", "48201"), ("Memphis",      "TN", "38101"),
]

METRO_WEIGHTS = [
    0.12, 0.10, 0.08, 0.06, 0.05, 0.04, 0.04, 0.04,
    0.04, 0.03, 0.03, 0.03, 0.03, 0.03, 0.03, 0.02,
    0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02,
    0.02, 0.01, 0.01, 0.01, 0.01, 0.01,
]

ACQUISITION_CHANNELS = [
    "digital_mobile", "branch", "referral",
    "direct_mail", "employer_partnership", "online_ad",
]
CHANNEL_WEIGHTS = [0.38, 0.25, 0.18, 0.08, 0.07, 0.04]

INCOME_BANDS = ["<25K", "25K-50K", "50K-75K", "75K-100K", "100K-150K", "150K-250K", "250K+"]

# ─── CORRELATED GENERATORS ────────────────────────────────────────────────────

def generate_age():
    """US banking customer age — bell curve centered on 44, range 18-82."""
    return int(np.clip(np.random.normal(loc=44, scale=14), 18, 82))


def generate_income_band(age: int) -> str:
    """Income peaks in 40s-50s, lower at extremes."""
    if age < 25:
        weights = [0.35, 0.40, 0.15, 0.05, 0.03, 0.01, 0.01]
    elif age < 35:
        weights = [0.10, 0.25, 0.30, 0.20, 0.10, 0.04, 0.01]
    elif age < 50:
        weights = [0.05, 0.12, 0.22, 0.25, 0.22, 0.10, 0.04]
    elif age < 65:
        weights = [0.05, 0.10, 0.18, 0.22, 0.25, 0.14, 0.06]
    else:
        weights = [0.08, 0.18, 0.25, 0.22, 0.16, 0.08, 0.03]
    return random.choices(INCOME_BANDS, weights=weights)[0]


def generate_credit_score(age: int, income_band: str) -> int:
    """Credit score correlated with age (experience) and income (stability)."""
    income_boost = {
        "<25K": -40, "25K-50K": -15, "50K-75K": 0,
        "75K-100K": 20, "100K-150K": 40, "150K-250K": 60, "250K+": 75,
    }.get(income_band, 0)
    age_boost = min((age - 25) * 1.5, 80) if age > 25 else 0
    raw = 650 + age_boost + income_boost + np.random.normal(0, 35)
    return int(np.clip(raw, 300, 850))


def generate_tenure_months(age: int) -> int:
    """Exponential distribution — most customers are relatively new."""
    max_possible = min((age - 18) * 12, 360)
    raw = int(np.random.exponential(scale=48))
    return max(1, min(raw, max_possible))


def generate_churn_risk(tenure_months: int, credit_score: int, income_band: str) -> float:
    """
    Churn risk 0-100.
    Lower tenure, lower income, lower credit = higher churn risk.
    """
    base = 50
    tenure_factor  = -min(tenure_months / 6, 30)
    credit_factor  = -(credit_score - 650) / 15
    income_factor  = {
        "<25K": 12, "25K-50K": 6, "50K-75K": 0,
        "75K-100K": -6, "100K-150K": -12, "150K-250K": -18, "250K+": -22,
    }.get(income_band, 0)
    noise = np.random.normal(0, 8)
    return round(float(np.clip(base + tenure_factor + credit_factor + income_factor + noise, 0, 100)), 2)


def get_lifecycle_stage(tenure_months: int, churn_risk: float) -> str:
    if tenure_months <= 3:
        return "onboarding"
    elif tenure_months <= 12:
        return "early_engagement"
    elif churn_risk > 65:
        return "at_risk"
    elif tenure_months >= 60 and churn_risk < 30:
        return "loyal"
    else:
        return "established"


def get_relationship_value_tier(income_band: str, credit_score: int, tenure_months: int) -> str:
    score = (
        {"<25K": 1, "25K-50K": 2, "50K-75K": 3, "75K-100K": 4,
         "100K-150K": 5, "150K-250K": 6, "250K+": 7}.get(income_band, 3)
        + (credit_score - 580) // 60
        + min(tenure_months // 24, 5)
    )
    if score >= 14: return "platinum"
    elif score >= 10: return "gold"
    elif score >= 6:  return "silver"
    else:             return "bronze"


# ─── MAIN GENERATOR ──────────────────────────────────────────────────────────

def generate_customers(n: int = 50_000) -> pd.DataFrame:
    print(f"Generating {n:,} customers...")
    records = []

    for i in range(1, n + 1):
        if i % 10_000 == 0:
            print(f"  {i:,} / {n:,}")

        age           = generate_age()
        gender        = random.choices(["M", "F", "NB"], weights=[0.48, 0.48, 0.04])[0]
        dob           = date.today() - timedelta(days=age * 365 + random.randint(0, 364))
        income_band   = generate_income_band(age)
        credit_score  = generate_credit_score(age, income_band)
        tenure_months = generate_tenure_months(age)
        since_date    = date.today() - timedelta(days=tenure_months * 30)
        churn_risk    = generate_churn_risk(tenure_months, credit_score, income_band)
        lifecycle     = get_lifecycle_stage(tenure_months, churn_risk)
        rel_tier      = get_relationship_value_tier(income_band, credit_score, tenure_months)
        city, state, zip_code = random.choices(US_METRO_AREAS, weights=METRO_WEIGHTS)[0]
        channel       = random.choices(ACQUISITION_CHANNELS, weights=CHANNEL_WEIGHTS)[0]

        # Customers with very high churn risk have a 40% chance of being marked inactive
        is_active = True if churn_risk < 75 else random.choices([True, False], weights=[0.6, 0.4])[0]

        records.append({
            "CUSTOMER_ID":              f"CUST{i:07d}",
            "FIRST_NAME":               fake.first_name_male() if gender == "M" else fake.first_name_female(),
            "LAST_NAME":                fake.last_name(),
            "EMAIL":                    fake.email(),
            "PHONE":                    fake.phone_number(),
            "DATE_OF_BIRTH":            dob.isoformat(),
            "AGE":                      age,
            "GENDER":                   gender,
            "INCOME_BAND":              income_band,
            "CREDIT_SCORE":             credit_score,
            "CITY":                     city,
            "STATE":                    state,
            "ZIP_CODE":                 zip_code,
            "CUSTOMER_SINCE_DATE":      since_date.isoformat(),
            "TENURE_MONTHS":            tenure_months,
            "ACQUISITION_CHANNEL":      channel,
            "CHURN_RISK_SCORE":         churn_risk,
            "LIFECYCLE_STAGE":          lifecycle,
            "RELATIONSHIP_VALUE_TIER":  rel_tier,
            "IS_ACTIVE":                is_active,
            "CREATED_AT":               datetime.now().isoformat(),
        })

    df = pd.DataFrame(records)
    print(f"\nGenerated {len(df):,} rows")
    print(df[["INCOME_BAND", "LIFECYCLE_STAGE", "RELATIONSHIP_VALUE_TIER"]].value_counts().head(15))
    return df


# ─── SNOWFLAKE LOAD ───────────────────────────────────────────────────────────

def load_to_snowflake(df: pd.DataFrame):
    print("\nConnecting to Snowflake...")
    conn = snowflake.connector.connect(**SNOWFLAKE_CONFIG)
    cur  = conn.cursor()

    cur.execute("USE DATABASE FINANCIAL_ANALYTICS")
    cur.execute("USE SCHEMA RAW")

    print("Creating RAW_CUSTOMERS table...")
    cur.execute("DROP TABLE IF EXISTS RAW_CUSTOMERS")
    cur.execute("""
        CREATE TABLE RAW_CUSTOMERS (
            CUSTOMER_ID             VARCHAR(12)   NOT NULL,
            FIRST_NAME              VARCHAR(50),
            LAST_NAME               VARCHAR(50),
            EMAIL                   VARCHAR(100),
            PHONE                   VARCHAR(30),
            DATE_OF_BIRTH           DATE,
            AGE                     INTEGER,
            GENDER                  VARCHAR(5),
            INCOME_BAND             VARCHAR(15),
            CREDIT_SCORE            INTEGER,
            CITY                    VARCHAR(50),
            STATE                   VARCHAR(5),
            ZIP_CODE                VARCHAR(10),
            CUSTOMER_SINCE_DATE     DATE,
            TENURE_MONTHS           INTEGER,
            ACQUISITION_CHANNEL     VARCHAR(30),
            CHURN_RISK_SCORE        FLOAT,
            LIFECYCLE_STAGE         VARCHAR(25),
            RELATIONSHIP_VALUE_TIER VARCHAR(10),
            IS_ACTIVE               BOOLEAN,
            CREATED_AT              TIMESTAMP_NTZ
        )
    """)

    print(f"Loading {len(df):,} rows → RAW_CUSTOMERS ...")
    success, nchunks, nrows, _ = write_pandas(conn, df, "RAW_CUSTOMERS")
    print(f"✅  Loaded {nrows:,} rows across {nchunks} chunk(s)")

    # Quick sanity check
    cur.execute("SELECT COUNT(*), AVG(CREDIT_SCORE), AVG(CHURN_RISK_SCORE) FROM RAW_CUSTOMERS")
    row = cur.fetchone()
    print(f"    Rows: {row[0]:,} | Avg Credit Score: {row[1]:.0f} | Avg Churn Risk: {row[2]:.1f}")

    cur.close()
    conn.close()


# ─── ENTRY POINT ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    df = generate_customers(50_000)
    load_to_snowflake(df)
    print("\n✅  generate_customers.py — COMPLETE")
    print("    Next: run generate_accounts.py")