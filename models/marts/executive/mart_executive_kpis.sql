-- mart_executive_kpis.sql
-- Single-row (or small set of rows) executive dashboard KPIs.
-- Grain: one row per snapshot date.
-- Powers: Power BI Executive Summary, QuickSight C-suite dashboard

{{ config(materialized='table', schema='MARTS_EXECUTIVE') }}

with customers as (
    select * from {{ ref('stg_customers') }}
),

accounts as (
    select * from {{ ref('stg_accounts') }}
),

loans as (
    select * from {{ ref('int_loan_performance') }}
),

cards as (
    select * from {{ ref('stg_credit_cards') }}
),

-- Customer KPIs
cust_kpis as (
    select
        count(*)                                                             as total_customers,
        sum(case when is_active then 1 else 0 end)                         as active_customers,
        round(avg(churn_risk_score), 2)                                     as avg_churn_risk,
        round(avg(credit_score), 0)                                         as avg_credit_score,
        sum(case when churn_risk_score >= 70 then 1 else 0 end)            as high_risk_customers,
        -- NPS proxy: customers with credit_score > 750 and churn < 30
        sum(case when credit_score > 750 and churn_risk_score < 30
                 then 1 else 0 end)                                         as promoter_proxy_count
    from customers
),

-- Deposit KPIs
deposit_kpis as (
    select
        count(*)                                                             as total_accounts,
        sum(case when account_status = 'ACTIVE'  then 1 else 0 end)        as active_accounts,
        sum(case when account_status = 'DORMANT' then 1 else 0 end)        as dormant_accounts,
        round(sum(current_balance) / 1e6, 2)                               as total_deposits_mm,
        round(avg(current_balance), 0)                                      as avg_account_balance,
        sum(case when account_type = 'CHECKING' and has_direct_deposit
                 then 1 else 0 end)                                         as direct_deposit_accounts,
        sum(case when account_type = 'CHECKING' and has_autopay
                 then 1 else 0 end)                                         as autopay_accounts
    from accounts
),

-- Loan KPIs
loan_kpis as (
    select
        count(*)                                                             as total_loans,
        sum(case when is_active then 1 else 0 end)                         as active_loans,
        round(sum(original_principal)  / 1e6, 2)                           as total_originated_mm,
        round(sum(current_balance)     / 1e6, 2)                           as total_outstanding_mm,
        round(sum(exposure_at_default) / 1e6, 2)                           as total_ead_mm,
        round(sum(expected_credit_loss)/ 1e6, 2)                           as total_ecl_mm,
        round(sum(expected_credit_loss) / nullif(sum(exposure_at_default),0), 4) as ecl_coverage_ratio,
        round(avg(probability_of_default), 4)                              as avg_pd,
        round(avg(interest_rate), 2)                                       as avg_loan_rate,
        -- Delinquency rates
        sum(case when loan_status in ('30DPD','60DPD','90DPD') and is_active
                 then 1 else 0 end)                                         as delinquent_loans,
        round(
            sum(case when loan_status in ('30DPD','60DPD','90DPD') and is_active then 1 else 0 end)
            * 1.0 / nullif(sum(case when is_active then 1 else 0 end), 0),
        4)                                                                   as delinquency_rate,
        sum(case when loan_status = 'CHARGED_OFF' then 1 else 0 end)       as charged_off_loans,
        round(sum(case when loan_status = 'CHARGED_OFF'
                       then original_principal else 0 end) / 1e6, 2)       as charged_off_mm
    from loans
),

-- Card KPIs
card_kpis as (
    select
        count(*)                                                             as total_cards,
        sum(case when card_status = 'ACTIVE' then 1 else 0 end)            as active_cards,
        round(sum(credit_limit)      / 1e6, 2)                             as total_limit_mm,
        round(sum(current_balance)   / 1e6, 2)                             as total_card_balance_mm,
        round(avg(utilization_rate)  * 100, 1)                             as avg_utilization_pct,
        sum(case when has_fraud_dispute then 1 else 0 end)                 as fraud_disputes,
        round(sum(fraud_dispute_amount) / 1e3, 1)                          as fraud_dispute_amt_k,
        sum(case when payment_pattern = 'MISSED' then 1 else 0 end)        as missed_payment_cards,
        sum(case when payment_pattern = 'FULL'   then 1 else 0 end)        as full_payment_cards
    from cards
)

select
    current_date()                                                           as snapshot_date,
    '{{ var("macro_scenario") }}'                                            as macro_scenario,

    -- ── Customer health ───────────────────────────────────────────────────────
    ck.total_customers,
    ck.active_customers,
    round(ck.active_customers * 100.0 / nullif(ck.total_customers, 0), 1)  as active_customer_pct,
    ck.avg_churn_risk,
    ck.avg_credit_score,
    ck.high_risk_customers,
    round(ck.high_risk_customers * 100.0 / nullif(ck.active_customers, 0), 1) as high_risk_pct,
    ck.promoter_proxy_count,

    -- ── Deposit book ──────────────────────────────────────────────────────────
    dk.total_accounts,
    dk.active_accounts,
    dk.dormant_accounts,
    dk.total_deposits_mm,
    dk.avg_account_balance,
    dk.direct_deposit_accounts,
    round(dk.direct_deposit_accounts * 100.0 / nullif(dk.active_accounts, 0), 1) as direct_deposit_pct,
    dk.autopay_accounts,

    -- ── Loan book ─────────────────────────────────────────────────────────────
    lk.total_loans,
    lk.active_loans,
    lk.total_originated_mm,
    lk.total_outstanding_mm,
    lk.total_ead_mm,
    lk.total_ecl_mm,
    lk.ecl_coverage_ratio,
    round(lk.ecl_coverage_ratio * 100, 2)                                   as ecl_coverage_pct,
    lk.avg_pd,
    lk.avg_loan_rate,
    lk.delinquent_loans,
    round(lk.delinquency_rate * 100, 2)                                     as delinquency_rate_pct,
    lk.charged_off_loans,
    lk.charged_off_mm,

    -- ── Card book ────────────────────────────────────────────────────────────
    ck2.total_cards,
    ck2.active_cards,
    ck2.total_limit_mm,
    ck2.total_card_balance_mm,
    ck2.avg_utilization_pct,
    ck2.fraud_disputes,
    ck2.fraud_dispute_amt_k,
    ck2.missed_payment_cards,
    round(ck2.missed_payment_cards * 100.0 / nullif(ck2.active_cards, 0), 1) as missed_pmt_rate_pct,
    ck2.full_payment_cards,
    round(ck2.full_payment_cards * 100.0 / nullif(ck2.active_cards, 0), 1)   as full_pay_rate_pct,

    -- ── Total AUM ─────────────────────────────────────────────────────────────
    round(dk.total_deposits_mm + lk.total_outstanding_mm + ck2.total_card_balance_mm, 2)
                                                                             as total_aum_mm,

    current_timestamp                                                        as dbt_updated_at

from cust_kpis    ck
cross join deposit_kpis dk
cross join loan_kpis    lk
cross join card_kpis    ck2
