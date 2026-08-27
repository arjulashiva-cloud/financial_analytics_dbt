# financial_analytics_dbt

**A production-grade dbt project demonstrating enterprise financial services analytics — source-to-target mapping, data governance, KPI frameworks, and GTM analytics built on Snowflake.**

---

## Overview

This project models a retail banking / fintech data platform using dbt Core + Snowflake. It covers the full analytics engineering lifecycle: raw source ingestion, staging, intermediate business logic, and purpose-built data marts for Finance, GTM, and Governance teams.

Built to reflect real-world financial services analytics patterns — STTM documentation, golden-record design, portfolio performance, customer 360, churn risk, and certified KPI definitions.

---

## Project Structure

```
financial_analytics_dbt/
├── models/
│   ├── staging/           # Raw source cleaning & typing (views)
│   │   ├── sources.yml    # Source definitions + freshness checks
│   │   ├── stg_customers.sql
│   │   ├── stg_accounts.sql
│   │   ├── stg_transactions.sql
│   │   ├── stg_loans.sql
│   │   └── stg_credit_cards.sql
│   │
│   ├── intermediate/      # Business logic joins & rollups (views)
│   │   ├── int_customer_accounts.sql
│   │   └── int_customer_financials.sql
│   │
│   └── marts/
│       ├── finance/       # CFO/executive financial reporting (tables)
│       │   └── mart_portfolio_performance.sql
│       │
│       ├── gtm/           # Sales, marketing, customer analytics (tables)
│       │   ├── mart_customer_360.sql
│       │   ├── mart_acquisition_funnel.sql
│       │   └── schema.yml
│       │
│       └── governance/    # Data quality, KPI catalog, STTM recon (tables)
│           └── mart_kpi_governance.sql
│
├── macros/
│   └── financial_utils.sql   # Reusable SQL utilities
├── seeds/
│   └── raw_customers.csv     # Sample data for local development
├── dbt_project.yml
└── profiles.yml
```

---

## Data Model

### Sources (RAW schema)
| Source Table | Description |
|---|---|
| `raw_banking.customers` | Master customer records from core banking CRM |
| `raw_banking.accounts` | Deposit accounts (checking, savings, CD, investment) |
| `raw_banking.transactions` | Daily transaction ledger across all accounts |
| `raw_banking.loans` | Loan origination and servicing records |
| `raw_banking.credit_cards` | Credit card accounts, balances, and utilization |

### Staging Layer
Standardizes data types, normalizes text fields, derives basic flags, and filters invalid records. All staging models materialize as **views**.

### Intermediate Layer
Joins and aggregates staging models into reusable business logic building blocks — customer-account relationships and customer-level financial rollups.

### Marts

#### `marts/gtm/`
| Mart | Description |
|---|---|
| `mart_customer_360` | Golden record — one row per customer with lifecycle stage, LTV tier, churn risk, engagement score |
| `mart_acquisition_funnel` | Monthly cohort acquisition, activation rates, channel performance, retention |

#### `marts/finance/`
| Mart | Description |
|---|---|
| `mart_portfolio_performance` | Loan portfolio health, delinquency roll-forward, credit card utilization, deposit trends |

#### `marts/governance/`
| Mart | Description |
|---|---|
| `mart_kpi_governance` | Certified KPI definitions, data quality scorecards, STTM reconciliation tie-outs |

---

## Key Features

### Source-to-Target Mapping (STTM)
Every model documents its source fields, transformation rules, and lineage. The governance mart produces automated STTM reconciliation tie-outs between source counts and mart counts.

### Data Quality Testing
- **Schema tests**: `unique`, `not_null`, `accepted_values`, `relationships` across all source and mart models
- **Source freshness checks**: warn after 24 hours, error after 48 hours
- **Completeness scoring**: per-entity data quality scorecards in the governance mart

### KPI Governance
The `mart_kpi_governance` model maintains a **certified KPI catalog** — each metric has a name, definition, source mart, calculation logic, domain, and certification status. No ambiguity about how numbers are calculated.

### Reusable Macros
| Macro | Purpose |
|---|---|
| `safe_divide(numerator, denominator)` | Division with null/zero guard |
| `delinquency_bucket(status_field)` | Standard delinquency risk tier mapping |
| `utilization_risk(balance, limit)` | Credit utilization risk classification |
| `months_since(date_field)` | Months elapsed from a date to today |
| `generate_surrogate_key(fields)` | MD5-based surrogate key generation |

---

## Setup

### Prerequisites
- dbt Core (`pip install dbt-snowflake`)
- Snowflake account with a `TRANSFORMER` role and `COMPUTE_WH` warehouse

### Environment Variables
```bash
export SNOWFLAKE_ACCOUNT=your_account
export SNOWFLAKE_USER=your_user
export SNOWFLAKE_PASSWORD=your_password
```

### Run
```bash
# Install dependencies
dbt deps

# Load seed data
dbt seed

# Run all models
dbt run

# Run tests
dbt test

# Generate and serve docs
dbt docs generate
dbt docs serve
```

### Run a specific layer
```bash
dbt run --select staging
dbt run --select marts.gtm
dbt run --select marts.finance
dbt run --select tag:governance
```

---

## Design Decisions

**Why views for staging and intermediate?**
Staging models are lightweight cleaning layers — no need to materialize. Intermediate models are building blocks consumed by multiple marts; keeping them as views avoids storage duplication and ensures marts always read fresh data.

**Why tables for marts?**
Marts are queried directly by BI tools (Tableau, Power BI, Looker). Materializing as tables ensures fast query performance and predictable refresh timing.

**Why a governance mart?**
Certified KPI definitions, data quality scorecards, and STTM reconciliation checks are first-class analytics products — not afterthoughts. The governance mart makes data trust a measurable, reportable outcome.

---

## Author

**Shiva Krishna Arjula** — Senior Data Analyst / Analytics Engineer  
Financial services analytics specialist: STTM, data governance, KPI frameworks, Snowflake, dbt, SQL  
[linkedin.com/in/shivakrishnaarjula](https://www.linkedin.com/in/shivakrishnaarjula)
