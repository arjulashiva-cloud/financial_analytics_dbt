# 🏦 financial_analytics_dbt

> A production-grade banking analytics platform built on **dbt Core + Snowflake + Power BI** — covering CECL reserves, peer benchmarking, macro risk overlay, compliance conduct, and deposit stability.

![dbt](https://img.shields.io/badge/dbt-Core-FF694B?logo=dbt&logoColor=white)
![Snowflake](https://img.shields.io/badge/Snowflake-Data_Warehouse-29B5E8?logo=snowflake&logoColor=white)
![Power BI](https://img.shields.io/badge/Power_BI-Dashboard-F2C811?logo=powerbi&logoColor=black)
![Python](https://img.shields.io/badge/Python-3.11-3776AB?logo=python&logoColor=white)
![CI](https://github.com/arjulashiva-cloud/financial_analytics_dbt/actions/workflows/dbt_ci.yml/badge.svg)

---

## What This Solves

Most bank data teams still run CECL in spreadsheets, pull SOX evidence manually, and produce peer benchmarking reports that take two weeks. This project builds the modern version of all of it:

| Problem | This Project |
|---|---|
| CECL calculated in Excel | dbt mart with PD × LGD × EAD × macro multiplier across 3 scenarios |
| Peer benchmarking takes weeks | Automated FDIC peer pipeline — quartile positioning in seconds |
| No macro linkage to credit risk | FRED API data driving ECL scenario selection |
| SOX audit evidence pulled manually | Automated controls tracking with exception flags |
| Deposit concentration blind spots | Post-SVB stability monitoring — concentration index, uninsured % |

---

## Architecture

```
Data Sources                  dbt Layers                    Consumption
─────────────                 ──────────                    ───────────
Synthetic Customers  ──►  Staging (6 models)  ──►  Marts (9 models)  ──►  Power BI (7 pages)
Synthetic Accounts   ──►  Intermediate        ──►  MARTS_CORE
Synthetic Loans            (3 models)              MARTS_FINANCE        GitHub Actions CI/CD
Synthetic Transactions                             MARTS_RISK
FRED API (macro)     ──►  Seeds                    MARTS_EXECUTIVE
FDIC Peers           ──►  raw_fdic_peers
CFPB Complaints                                     Snowflake
                                                    FINANCIAL_ANALYTICS DB
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Data Warehouse | Snowflake |
| Transformation | dbt Core 1.8 |
| Orchestration | GitHub Actions CI/CD |
| Visualization | Power BI Desktop |
| Data Ingestion | Python (pandas, snowflake-connector-python) |
| External APIs | FRED (Federal Reserve), FDIC BankFind Suite |
| Source Control | Git + GitHub |

---

## dbt Models — 18 Total

### Staging (6 models)
| Model | Source | Description |
|---|---|---|
| stg_customers | RAW_CUSTOMERS | 50,000 synthetic bank customers |
| stg_accounts | RAW_ACCOUNTS | ~120,000 checking, savings, CD accounts |
| stg_transactions | RAW_TRANSACTIONS | ~19.5M transactions |
| stg_loans | RAW_LOANS | ~35,000 loan records |
| stg_credit_cards | RAW_CREDIT_CARDS | ~28,000 credit card accounts |
| stg_fred_macro | RAW_FRED_MACRO | Fed Funds, CPI, yield curve (2019–2026) |

### Intermediate (3 models)
| Model | Description |
|---|---|
| int_customer_360 | Unified customer profile with risk scoring |
| int_loan_performance | Delinquency tracking, days past due, charge-off flags |
| int_account_monthly | Monthly balance snapshots for trend analysis |

### Marts (9 models)
| Model | Schema | Description |
|---|---|---|
| mart_executive_kpis | MARTS_EXECUTIVE | Board-level KPIs — NIM, ROA, deposit growth |
| mart_customer_360 | MARTS_CORE | Full customer profile with segment and churn risk |
| mart_nim_analysis | MARTS_FINANCE | Net interest margin sensitivity analysis |
| mart_peer_benchmarking | MARTS_FINANCE | Our bank vs 20 FDIC peers — NIM, LDR, charge-off quartile |
| mart_cecl_reserve | MARTS_RISK | CECL reserve calculation by segment and product |
| mart_macro_risk_overlay | MARTS_RISK | FRED macro data + ECL scenario selection |
| mart_deposit_stability | MARTS_RISK | Post-SVB deposit concentration and maturity laddering |
| mart_sox_controls | MARTS_RISK | SOX control exceptions and audit evidence tracking |
| mart_compliance_conduct | MARTS_RISK | CFPB complaint volume, severity, timely response rate |

---

## Power BI Dashboard — 7 Pages

### 1. Executive Summary
High-level board view — NIM, total deposits, active loans, portfolio health score, and YoY trends.

![Executive Summary](Visualization/Executive%20Summary.jpg)

---

### 2. Customer Overview
Customer segmentation by tier, lifecycle stage, churn risk, and credit score distribution across 50,000 customers.

![Customer Overview](Visualization/Customer%20Overview.jpg)

---

### 3. Portfolio Performance
Loan portfolio breakdown by product, delinquency rates, charge-off trends, and LTV distribution.

![Portfolio Performance](Visualization/Portfolio%20Performance.jpg)

---

### 4. CECL Reserve Analysis
CECL reserve estimates by segment — Base, Adverse, Severely Adverse scenarios. Coverage ratios against total loan exposure.

![CECL Reserve Analysis](Visualization/CECL%20Reserve%20Analysis.jpg)

---

### 5. Compliance & Conduct
CFPB complaint tracking — volume trends, product category breakdown, timely response rate, and severity distribution.

![Compliance & Conduct](Visualization/Compliance%20%26%20Conduct.jpg)

---

### 6. Peer Benchmarking
Our bank vs 20 FDIC peer banks — NIM quartile positioning (TOP_QUARTILE at 6.08% vs 3.4% peer median), charge-off rate (BEST_QUARTILE at 0.01% vs 0.315% peer median), and loan-to-deposit ratio.

![Peer Benchmarking](Visualization/Peer%20Benchmarking.jpg)

---

### 7. Macro Risk Overlay
Fed Funds rate cycle, yield curve spread (inversion visible 2022–2023), CPI YoY %, and ECL stress scenario comparison.

![Macro Risk Overlay](Visualization/Macro%20Risk%20Overlay.jpg)

---

## Key Metrics (Current)

| Metric | Value |
|---|---|
| Total Loan Exposure | ~$2.4B |
| Active Customers | 50,000 |
| Transactions | ~19.5M |
| Our NIM | 6.08% (TOP_QUARTILE vs peers) |
| Peer Median NIM | 3.40% |
| Net Charge-off Rate | 0.01% (BEST_QUARTILE vs peers) |
| ECL Base Scenario | ~$22M |
| ECL Severely Adverse | ~$35M |
| dbt Models | 18 |
| dbt Tests | 90+ |

---

## Project Structure

```
financial_analytics_dbt/
├── models/
│   ├── staging/          # 6 staging models
│   ├── intermediate/     # 3 intermediate models
│   └── marts/
│       ├── core/         # mart_customer_360
│       ├── finance/      # mart_nim_analysis, mart_peer_benchmarking
│       ├── risk/         # CECL, macro, deposit, SOX, compliance
│       └── executive/    # mart_executive_kpis
├── seeds/
│   └── raw_fdic_peers.csv   # 20 peer bank reference data
├── data_generation/
│   ├── generate_customers.py
│   ├── generate_accounts.py
│   ├── generate_transactions.py
│   ├── generate_loans.py
│   ├── generate_credit_cards.py
│   ├── pull_fred_data.py    # FRED API — macro time series
│   └── pull_fdic_peers.py   # FDIC BankFind Suite API
├── macros/
│   ├── generate_schema_name.sql
│   └── calculate_ecl.sql    # PD × LGD × EAD × macro_multiplier
├── .github/
│   └── workflows/
│       └── dbt_ci.yml       # CI — dbt build on every push
├── Visualization/           # Power BI screenshots (7 pages)
└── dbt_project.yml
```

---

## Getting Started

### Prerequisites
- Snowflake account
- Python 3.11+
- dbt Core 1.8+
- Power BI Desktop (free)

### 1. Clone the repo
```bash
git clone https://github.com/arjulashiva-cloud/financial_analytics_dbt.git
cd financial_analytics_dbt
```

### 2. Set environment variables
```bash
# Windows PowerShell
$env:SNOWFLAKE_PASSWORD = "your_password"

# Mac/Linux
export SNOWFLAKE_PASSWORD=your_password
```

### 3. Install Python dependencies
```bash
pip install pandas snowflake-connector-python snowflake-sqlalchemy fredapi requests
```

### 4. Generate synthetic data
```bash
cd data_generation
python generate_customers.py
python generate_accounts.py
python generate_transactions.py
python generate_loans.py
python generate_credit_cards.py
python pull_fred_data.py
```

### 5. Run dbt
```bash
dbt deps
dbt seed          # loads FDIC peer reference data
dbt build         # runs all 18 models + 90+ tests
```

### 6. Connect Power BI
Open `Visualization/Financial_Analytics.pbix` → update Snowflake connection to your account.

---

## CI/CD

GitHub Actions runs `dbt build` on every push to `main`:

```yaml
# .github/workflows/dbt_ci.yml
- dbt deps
- dbt seed
- dbt build
```

---

## ECL Methodology

CECL reserve = **PD × LGD × EAD × Macro Multiplier**

| Scenario | Macro Multiplier |
|---|---|
| Base | 1.00× |
| Adverse | 1.20× |
| Severely Adverse | 1.50× |

Scenario selection driven by FRED macro data — Fed Funds rate, yield curve spread, CPI YoY %.

---

## Author

**Shiva Krishna Arjula**  
Senior Data Analyst — Financial Services Analytics  
10 years in banking data — Capital One, Genpact, Collabera  
[linkedin.com/in/shivakrishnaarjula](https://linkedin.com/in/shivakrishnaarjula)


