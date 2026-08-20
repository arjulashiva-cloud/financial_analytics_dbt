{{
  config(
    materialized = 'table',
    description = 'KPI governance mart — certified metric definitions, data quality scorecards, and source-to-target reconciliation. Primary mart for data governance reporting and executive data trust dashboards.'
  )
}}

with customers as (
    select * from {{ ref('stg_customers') }}
),

accounts as (
    select * from {{ ref('stg_accounts') }}
),

loans as (
    select * from {{ ref('stg_loans') }}
),

credit_cards as (
    select * from {{ ref('stg_credit_cards') }}
),

transactions as (
    select * from {{ ref('stg_transactions') }}
),

customer_360 as (
    select * from {{ ref('mart_customer_360') }}
),

-- Data quality scorecard per entity
dq_customers as (
    select
        'CUSTOMERS'                                     as entity,
        count(*)                                        as total_records,
        count(case when customer_id is null
            then 1 end)                                 as null_pk_count,
        count(case when email is null
            then 1 end)                                 as null_email_count,
        count(case when customer_segment is null
            then 1 end)                                 as null_segment_count,
        count(case when acquisition_channel is null
            then 1 end)                                 as null_channel_count,
        count(case when customer_since_date is null
            then 1 end)                                 as null_date_count,
        round(
            count(case when customer_id is not null
                and email is not null
                and customer_segment is not null
                then 1 end) * 100.0 / nullif(count(*), 0),
        2)                                              as completeness_score_pct
    from customers
),

dq_accounts as (
    select
        'ACCOUNTS'                                      as entity,
        count(*)                                        as total_records,
        count(case when account_id is null
            then 1 end)                                 as null_pk_count,
        count(case when customer_id is null
            then 1 end)                                 as null_fk_count,
        count(case when balance is null
            then 1 end)                                 as null_balance_count,
        count(case when account_type is null
            then 1 end)                                 as null_type_count,
        count(case when account_status is null
            then 1 end)                                 as null_status_count,
        round(
            count(case when account_id is not null
                and customer_id is not null
                and balance is not null
                then 1 end) * 100.0 / nullif(count(*), 0),
        2)                                              as completeness_score_pct
    from accounts
),

dq_loans as (
    select
        'LOANS'                                         as entity,
        count(*)                                        as total_records,
        count(case when loan_id is null
            then 1 end)                                 as null_pk_count,
        count(case when customer_id is null
            then 1 end)                                 as null_fk_count,
        count(case when outstanding_balance is null
            then 1 end)                                 as null_balance_count,
        count(case when interest_rate is null
            then 1 end)                                 as null_rate_count,
        count(case when risk_tier is null
            then 1 end)                                 as null_risk_tier_count,
        round(
            count(case when loan_id is not null
                and customer_id is not null
                and outstanding_balance is not null
                then 1 end) * 100.0 / nullif(count(*), 0),
        2)                                              as completeness_score_pct
    from loans
),

-- KPI definitions — certified metric catalog
kpi_definitions as (
    select * from (values
        ('TOTAL_ACTIVE_CUSTOMERS',
         'Count of customers with at least one active account and a transaction in the last 12 months.',
         'mart_customer_360', 'lifecycle_stage != DORMANT', 'GTM', 'CERTIFIED'),

        ('CUSTOMER_CHURN_RATE',
         'Percentage of customers classified as DORMANT or AT_RISK out of total active customer base.',
         'mart_customer_360', 'churn_risk IN (HIGH, MEDIUM)', 'GTM', 'CERTIFIED'),

        ('AVG_RELATIONSHIP_VALUE',
         'Average total relationship value (deposits + loans + card balances) per active customer.',
         'mart_customer_360', 'total_relationship_value', 'FINANCE', 'CERTIFIED'),

        ('PORTFOLIO_DELINQUENCY_RATE',
         'Percentage of total outstanding loan balance that is 30+ days past due.',
         'mart_portfolio_performance', 'delinquent_balance / outstanding_balance', 'FINANCE', 'CERTIFIED'),

        ('PRODUCT_DEPTH',
         'Average number of distinct product types (deposits, loans, cards) held per active customer.',
         'mart_customer_360', 'product_depth', 'GTM', 'CERTIFIED'),

        ('CUSTOMER_ACQUISITION_CHANNEL_MIX',
         'Distribution of new customer acquisitions by channel (DIGITAL, BRANCH, REFERRAL, etc.).',
         'mart_customer_360', 'acquisition_channel', 'GTM', 'CERTIFIED'),

        ('CREDIT_UTILIZATION_RATE',
         'Average credit card utilization rate (current balance / credit limit) across active cards.',
         'mart_portfolio_performance', 'avg_utilization_rate', 'FINANCE', 'CERTIFIED'),

        ('DATA_COMPLETENESS_SCORE',
         'Percentage of records across all source entities meeting minimum completeness requirements.',
         'mart_kpi_governance', 'completeness_score_pct', 'GOVERNANCE', 'CERTIFIED')

    ) as t(kpi_name, kpi_definition, source_mart, calculation_logic, domain, status)
),

-- STTM reconciliation check — count tie-out between staging and marts
sttm_reconciliation as (
    select
        'CUSTOMER_COUNT_TIE_OUT'                        as check_name,
        (select count(*) from customers)                as source_count,
        (select count(*) from customer_360)             as mart_count,
        (select count(*) from customers)
            - (select count(*) from customer_360)       as variance,
        case
            when (select count(*) from customers)
                = (select count(*) from customer_360)
            then 'PASS' else 'FAIL'
        end                                             as status
)

-- Output: combined governance mart
select
    'DQ_SCORECARD'                                      as record_type,
    entity                                              as dimension,
    cast(total_records as varchar)                      as value_1,
    cast(completeness_score_pct as varchar)             as value_2,
    cast(null_pk_count as varchar)                      as value_3,
    current_timestamp()                                 as dbt_loaded_at
from dq_customers

union all

select 'DQ_SCORECARD', entity,
    cast(total_records as varchar),
    cast(completeness_score_pct as varchar),
    cast(null_pk_count as varchar),
    current_timestamp()
from dq_accounts

union all

select 'DQ_SCORECARD', entity,
    cast(total_records as varchar),
    cast(completeness_score_pct as varchar),
    cast(null_pk_count as varchar),
    current_timestamp()
from dq_loans

union all

select
    'KPI_DEFINITION'                                    as record_type,
    kpi_name                                            as dimension,
    kpi_definition                                      as value_1,
    source_mart                                         as value_2,
    status                                              as value_3,
    current_timestamp()                                 as dbt_loaded_at
from kpi_definitions

union all

select
    'STTM_RECON'                                        as record_type,
    check_name                                          as dimension,
    cast(source_count as varchar)                       as value_1,
    cast(mart_count as varchar)                         as value_2,
    status                                              as value_3,
    current_timestamp()                                 as dbt_loaded_at
from sttm_reconciliation
