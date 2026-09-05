-- int_loan_performance.sql
-- Loan-grain model enriching staging loans with CECL expected credit loss,
-- amortization progress, and borrower context from the customer profile.
-- Consumed by: mart_cecl_reserve, mart_executive_kpis

with loans as (
    select * from {{ ref('stg_loans') }}
),

customers as (
    select
        customer_id,
        credit_tier,
        income_band,
        lifecycle_stage,
        churn_risk_score,
        state
    from {{ ref('stg_customers') }}
)

select
    -- ── Loan identity ────────────────────────────────────────────────────────
    l.loan_id,
    l.customer_id,
    l.loan_type,
    l.loan_status,
    l.origination_date,
    l.maturity_date,
    l.term_months,

    -- ── Borrower context ─────────────────────────────────────────────────────
    c.credit_tier,
    c.income_band,
    c.lifecycle_stage,
    c.churn_risk_score,
    c.state,

    -- ── Loan economics ────────────────────────────────────────────────────────
    l.original_principal,
    l.current_balance,
    l.monthly_payment,
    l.interest_rate,
    l.annual_percentage_rate,
    l.loan_to_value_ratio,
    l.debt_to_income_ratio,

    -- ── Amortization progress ─────────────────────────────────────────────────
    datediff('month', l.origination_date, current_date())                   as months_on_book,
    datediff('month', current_date(), l.maturity_date)                      as months_to_maturity,
    round(
        l.current_balance / nullif(l.original_principal, 0),
    4)                                                                       as balance_pct_remaining,
    round(
        (l.original_principal - l.current_balance) / nullif(l.original_principal, 0),
    4)                                                                       as pct_amortized,

    -- Monthly interest income from this loan (simple interest approximation)
    round(l.current_balance * (l.interest_rate / 100.0) / 12, 2)           as monthly_interest_income,

    -- ── Delinquency ───────────────────────────────────────────────────────────
    l.days_past_due,
    l.times_30dpd_last_12m,
    l.times_60dpd_last_12m,
    l.delinquency_severity,
    l.is_active,

    -- Bucket for reporting
    case
        when l.loan_status = 'CHARGED_OFF'  then '5 - Charged Off'
        when l.loan_status = '90DPD'        then '4 - 90+ DPD'
        when l.loan_status = '60DPD'        then '3 - 60-89 DPD'
        when l.loan_status = '30DPD'        then '2 - 30-59 DPD'
        when l.loan_status = 'PAID_OFF'     then '0 - Paid Off'
        else                                     '1 - Current'
    end                                                                      as delinquency_bucket,

    -- ── CECL risk inputs ──────────────────────────────────────────────────────
    l.probability_of_default,
    l.loss_given_default,
    l.exposure_at_default,

    -- Expected Credit Loss using the project macro
    {{ calculate_ecl(
        'l.probability_of_default',
        'l.loss_given_default',
        'l.exposure_at_default',
        "'" ~ var('macro_scenario') ~ "'"
    ) }}                                                                     as expected_credit_loss,

    -- ECL as % of EAD (loss rate)
    case
        when l.exposure_at_default > 0
        then round(
            {{ calculate_ecl(
                'l.probability_of_default',
                'l.loss_given_default',
                'l.exposure_at_default',
                "'" ~ var('macro_scenario') ~ "'"
            ) }}
            / l.exposure_at_default, 4)
        else 0
    end                                                                      as ecl_rate,

    current_timestamp                                                        as dbt_updated_at

from loans l
left join customers c on l.customer_id = c.customer_id
