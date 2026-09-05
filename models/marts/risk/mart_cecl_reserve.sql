-- mart_cecl_reserve.sql
-- CECL (Current Expected Credit Loss) reserve calculation.
-- Grain: one row per loan, with portfolio roll-up columns for BI.
-- Materialized as TABLE for dashboard performance.
-- Powers: Power BI Credit Risk page, QuickSight CECL dashboard

{{ config(materialized='table', schema='MARTS_RISK') }}

with loan_perf as (
    select * from {{ ref('int_loan_performance') }}
),

-- Portfolio totals for coverage ratio calculation
portfolio_totals as (
    select
        sum(exposure_at_default)    as total_ead,
        sum(expected_credit_loss)   as total_ecl
    from loan_perf
    where is_active
)

select
    -- ── Loan keys ────────────────────────────────────────────────────────────
    lp.loan_id,
    lp.customer_id,
    lp.loan_type,
    lp.loan_status,
    lp.delinquency_bucket,
    lp.origination_date,
    lp.maturity_date,
    lp.months_on_book,
    lp.months_to_maturity,

    -- ── Borrower segment ──────────────────────────────────────────────────────
    lp.credit_tier,
    lp.income_band,
    lp.state,

    -- ── Loan financials ───────────────────────────────────────────────────────
    lp.original_principal,
    lp.current_balance,
    lp.monthly_payment,
    lp.interest_rate,
    lp.loan_to_value_ratio,
    lp.debt_to_income_ratio,
    lp.monthly_interest_income,
    lp.is_active,

    -- ── CECL inputs ───────────────────────────────────────────────────────────
    lp.probability_of_default,
    lp.loss_given_default,
    lp.exposure_at_default,
    lp.delinquency_severity,
    lp.times_30dpd_last_12m,
    lp.times_60dpd_last_12m,

    -- ── ECL outputs ───────────────────────────────────────────────────────────
    lp.expected_credit_loss,
    lp.ecl_rate,

    -- ECL under three macro scenarios — interoperability with var()
    lp.probability_of_default * lp.loss_given_default * lp.exposure_at_default * 1.00  as ecl_base,
    lp.probability_of_default * lp.loss_given_default * lp.exposure_at_default * 1.20  as ecl_adverse,
    lp.probability_of_default * lp.loss_given_default * lp.exposure_at_default * 1.50  as ecl_severely_adverse,

    -- ── Portfolio coverage ratios ─────────────────────────────────────────────
    -- Reserve coverage = ECL / EAD across the whole portfolio
    round(pt.total_ecl / nullif(pt.total_ead, 0), 4)                       as portfolio_coverage_ratio,

    -- This loan's share of total ECL
    round(lp.expected_credit_loss / nullif(pt.total_ecl, 0), 6)            as ecl_share_of_portfolio,

    -- ── Risk tiering ─────────────────────────────────────────────────────────
    case
        when lp.probability_of_default >= 0.10  then 'HIGH'
        when lp.probability_of_default >= 0.04  then 'MEDIUM'
        else                                          'LOW'
    end                                                                      as pd_risk_tier,

    case
        when lp.ecl_rate >= 0.10  then 'WATCH'
        when lp.ecl_rate >= 0.04  then 'MONITOR'
        else                           'PASS'
    end                                                                      as ecl_classification,

    -- ── Metadata ──────────────────────────────────────────────────────────────
    '{{ var("macro_scenario") }}'                                            as macro_scenario,
    current_timestamp                                                        as dbt_updated_at

from loan_perf lp
cross join portfolio_totals pt
