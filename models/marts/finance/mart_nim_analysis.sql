-- mart_nim_analysis.sql
-- Net Interest Margin (NIM) analysis by account type and customer segment.
-- NIM = (Interest Income - Interest Expense) / Average Earning Assets
-- Grain: one row per account_type × income_band × month_start
-- Powers: Power BI Finance page — NIM trend, deposit mix, margin waterfall

{{ config(materialized='table', schema='MARTS_FINANCE') }}

with account_monthly as (
    select * from {{ ref('int_account_monthly') }}
),

-- Loan interest income by customer (monthly estimate)
loan_income as (
    select
        lp.customer_id,
        date_trunc('month', current_date())::date   as month_start,   -- snapshot month
        sum(lp.monthly_interest_income)              as loan_interest_income,
        sum(lp.exposure_at_default)                  as total_ead
    from {{ ref('int_loan_performance') }} lp
    where lp.is_active
    group by 1, 2
),

-- Card interest income estimate (revolvers only — not full payers)
card_income as (
    select
        c.customer_id,
        date_trunc('month', current_date())::date    as month_start,
        sum(
            case when c.payment_pattern != 'FULL'
                 then c.current_balance * (c.annual_percentage_rate / 100.0) / 12
                 else 0
            end
        )                                             as card_interest_income
    from {{ ref('stg_credit_cards') }} c
    where c.card_status = 'ACTIVE'
    group by 1, 2
),

-- Deposit interest expense
deposit_expense as (
    select
        am.account_id,
        am.customer_id,
        am.account_type,
        am.month_start,
        am.ending_balance,
        am.interest_rate,
        -- Interest expense = balance × rate / 12
        round(am.ending_balance * (am.interest_rate / 100.0) / 12, 2)  as monthly_interest_expense,
        am.est_interest_income,    -- from loans routed through checking (payroll etc.)
        am.txn_count,
        am.total_debits,
        am.total_credits,
        am.digital_adoption_rate,
        am.fraud_signals,
        am.overdraft_txns
    from account_monthly am
),

customers as (
    select customer_id, income_band, credit_tier, relationship_value_tier, state
    from {{ ref('stg_customers') }}
),

-- Join everything to account grain with customer context
base as (
    select
        de.account_id,
        de.customer_id,
        de.account_type,
        de.month_start,
        c.income_band,
        c.credit_tier,
        c.relationship_value_tier,
        c.state,

        de.ending_balance,
        de.interest_rate,
        de.monthly_interest_expense,
        de.txn_count,
        de.total_debits,
        de.total_credits,
        de.digital_adoption_rate,
        de.fraud_signals,
        de.overdraft_txns,

        coalesce(li.loan_interest_income, 0)  as loan_interest_income,
        coalesce(ci.card_interest_income, 0)  as card_interest_income,
        coalesce(li.total_ead, 0)             as total_ead
    from deposit_expense de
    left join customers   c  on de.customer_id = c.customer_id
    left join loan_income  li on de.customer_id = li.customer_id
                              and de.month_start = li.month_start
    left join card_income  ci on de.customer_id = ci.customer_id
                              and de.month_start = ci.month_start
)

select
    -- ── Keys ─────────────────────────────────────────────────────────────────
    account_id,
    customer_id,
    account_type,
    month_start,
    income_band,
    credit_tier,
    relationship_value_tier,
    state,

    -- ── Balance sheet ─────────────────────────────────────────────────────────
    ending_balance                                                           as deposit_balance,
    interest_rate                                                            as deposit_rate_pct,
    total_ead                                                                as loan_ead,

    -- ── Income & expense ──────────────────────────────────────────────────────
    loan_interest_income,
    card_interest_income,
    loan_interest_income + card_interest_income                              as total_interest_income,
    monthly_interest_expense                                                 as interest_expense,

    -- ── NIM calculation ───────────────────────────────────────────────────────
    -- Net interest income
    (loan_interest_income + card_interest_income) - monthly_interest_expense as net_interest_income,

    -- NIM % = NII / earning assets (deposits as proxy for funded assets)
    case
        when ending_balance > 0
        then round(
            ((loan_interest_income + card_interest_income) - monthly_interest_expense)
            / nullif(ending_balance, 0),
        6)
        else 0
    end                                                                      as nim_rate,

    -- Annualized NIM basis points (standard banking KPI)
    case
        when ending_balance > 0
        then round(
            ((loan_interest_income + card_interest_income) - monthly_interest_expense)
            / nullif(ending_balance, 0) * 12 * 10000,
        1)
        else 0
    end                                                                      as nim_bps_annualized,

    -- ── Operational metrics ───────────────────────────────────────────────────
    txn_count,
    total_debits,
    total_credits,
    digital_adoption_rate,
    fraud_signals,
    overdraft_txns,

    -- ── Deposit stability proxy ───────────────────────────────────────────────
    -- Core deposits: checking + savings with low outflow
    case
        when account_type in ('CHECKING','SAVINGS','MONEY_MARKET')
        then 'CORE'
        when account_type = 'CD'
        then 'TERM'
        else 'INVESTMENT'
    end                                                                      as deposit_category,

    current_timestamp                                                        as dbt_updated_at

from base
