{{
  config(
    materialized = 'table',
    description = 'Monthly portfolio performance mart — loan portfolio health, delinquency roll-forward, credit card utilization, and deposit trends. Primary mart for CFO/executive financial reporting.'
  )
}}

with loans as (
    select * from {{ ref('stg_loans') }}
),

credit_cards as (
    select * from {{ ref('stg_credit_cards') }}
),

accounts as (
    select * from {{ ref('stg_accounts') }}
),

customers as (
    select * from {{ ref('stg_customers') }}
),

-- Loan portfolio by type and risk tier
loan_portfolio as (
    select
        l.loan_type,
        l.risk_tier,
        l.loan_status,
        c.customer_segment,
        count(l.loan_id)                                as loan_count,
        sum(l.principal_amount)                         as total_originated,
        sum(l.outstanding_balance)                      as total_outstanding,
        sum(l.amount_paid_down)                         as total_paid_down,
        avg(l.interest_rate)                            as avg_interest_rate,
        avg(l.loan_age_months)                          as avg_loan_age_months,
        sum(case when l.is_delinquent
            then l.outstanding_balance else 0 end)      as delinquent_balance,
        sum(case when l.is_charged_off
            then l.outstanding_balance else 0 end)      as charged_off_balance,
        count(case when l.is_delinquent then 1 end)     as delinquent_count,
        count(case when l.is_charged_off then 1 end)    as charged_off_count

    from loans l
    inner join customers c on l.customer_id = c.customer_id
    group by 1, 2, 3, 4
),

-- Credit card portfolio summary
card_portfolio as (
    select
        c.customer_segment,
        k.card_product,
        k.utilization_risk,
        count(k.card_id)                                as card_count,
        sum(k.credit_limit)                             as total_credit_limit,
        sum(k.current_balance)                          as total_outstanding_balance,
        sum(k.available_credit)                         as total_available_credit,
        avg(k.utilization_rate_pct)                     as avg_utilization_rate,
        sum(k.annual_fee)                               as total_annual_fees,
        count(case when k.is_active then 1 end)         as active_cards,
        count(case when k.utilization_risk = 'HIGH'
            then 1 end)                                 as high_utilization_cards

    from credit_cards k
    inner join customers c on k.customer_id = c.customer_id
    group by 1, 2, 3
),

-- Deposit portfolio by account type
deposit_portfolio as (
    select
        c.customer_segment,
        a.account_type,
        a.account_category,
        count(a.account_id)                             as account_count,
        count(case when a.is_active then 1 end)         as active_accounts,
        sum(a.balance)                                  as total_balance,
        avg(a.balance)                                  as avg_balance,
        sum(a.available_balance)                        as total_available,
        avg(a.interest_rate)                            as avg_interest_rate

    from accounts a
    inner join customers c on a.customer_id = c.customer_id
    group by 1, 2, 3
),

-- Delinquency roll-forward summary
delinquency_summary as (
    select
        loan_type,
        customer_segment,
        sum(case when risk_tier = '1_CURRENT'
            then loan_count else 0 end)                 as current_count,
        sum(case when risk_tier = '2_DPD_30'
            then loan_count else 0 end)                 as dpd_30_count,
        sum(case when risk_tier = '3_DPD_60'
            then loan_count else 0 end)                 as dpd_60_count,
        sum(case when risk_tier = '4_DPD_90'
            then loan_count else 0 end)                 as dpd_90_count,
        sum(case when risk_tier = '5_CHARGED_OFF'
            then loan_count else 0 end)                 as charged_off_count,
        sum(total_outstanding)                          as total_outstanding,
        sum(delinquent_balance)                         as total_delinquent_balance,
        round(
            sum(delinquent_balance)
            / nullif(sum(total_outstanding), 0) * 100,
        2)                                              as delinquency_rate_pct

    from loan_portfolio
    group by 1, 2
)

-- Final combined portfolio view
select
    'LOAN' as portfolio_type,
    loan_type as product,
    customer_segment,
    risk_tier as sub_category,
    loan_count as record_count,
    total_outstanding as outstanding_balance,
    avg_interest_rate,
    delinquent_balance,
    delinquent_count,
    null as utilization_rate,
    current_timestamp() as dbt_loaded_at
from loan_portfolio

union all

select
    'CREDIT_CARD' as portfolio_type,
    card_product as product,
    customer_segment,
    utilization_risk as sub_category,
    card_count as record_count,
    total_outstanding_balance as outstanding_balance,
    null as avg_interest_rate,
    null as delinquent_balance,
    null as delinquent_count,
    avg_utilization_rate as utilization_rate,
    current_timestamp() as dbt_loaded_at
from card_portfolio

union all

select
    'DEPOSIT' as portfolio_type,
    account_type as product,
    customer_segment,
    account_category as sub_category,
    account_count as record_count,
    total_balance as outstanding_balance,
    avg_interest_rate,
    null as delinquent_balance,
    null as delinquent_count,
    null as utilization_rate,
    current_timestamp() as dbt_loaded_at
from deposit_portfolio
