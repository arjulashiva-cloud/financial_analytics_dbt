-- mart_sox_controls.sql
-- SOX (Sarbanes-Oxley) controls automation mart.
-- Synthesizes automated control test results from transactional and customer data.
-- Covers: Application Controls, Financial Reporting Controls, ITGC (Segregation of Duties).
--
-- Controls implemented:
--   1. CREDIT_LIMIT_AUTHORIZATION     — credit limits within approved product policy bands
--   2. LOAN_ORIGINATION_POLICY        — loans meet minimum credit score thresholds
--   3. DORMANT_ACCOUNT_REVIEW         — dormant accounts with large balances flagged for escheatment
--   4. HIGH_RISK_LOAN_APPROVAL        — large high-PD loans require documented senior approval
--   5. OVERLIMIT_REVIEW               — repeated overlimit events trigger credit line review
--
-- Schema: MARTS_RISK

{{
    config(
        materialized = 'table',
        schema       = 'MARTS_RISK'
    )
}}

with loans as (
    select * from {{ ref('stg_loans') }}
),

accounts as (
    select * from {{ ref('stg_accounts') }}
),

customers as (
    select * from {{ ref('stg_customers') }}
),

credit_cards as (
    select * from {{ ref('stg_credit_cards') }}
),

-- ── Control 1: Credit Limit Authorization ────────────────────────────────
-- SECURED cards must not exceed $2,000 (subprime product policy)
-- PREMIUM cards must be at least $10,000 (premium product minimum)
-- All cards must be at least $500 (minimum viable limit)
ctl_1 as (
    select
        card_id                                 as control_subject_id,
        customer_id,
        'CREDIT_LIMIT_AUTHORIZATION'            as control_id,
        'Application Control'                   as control_category,
        'Verify credit limits fall within approved product policy bands' as control_description,
        'Quarterly'                             as control_frequency,
        case
            when card_product = 'SECURED'  and credit_limit > 2000   then 'EXCEPTION'
            when card_product = 'PREMIUM'  and credit_limit < 10000  then 'EXCEPTION'
            when credit_limit < 500                                   then 'EXCEPTION'
            else 'PASS'
        end                                     as test_result,
        case
            when card_product = 'SECURED'  and credit_limit > 2000
                then 'SECURED card limit $' || credit_limit::varchar || ' exceeds $2,000 policy cap'
            when card_product = 'PREMIUM'  and credit_limit < 10000
                then 'PREMIUM card limit $' || credit_limit::varchar || ' below $10,000 minimum'
            when credit_limit < 500
                then 'Credit limit $' || credit_limit::varchar || ' below $500 minimum'
            else null
        end                                     as exception_detail
    from credit_cards
),

-- ── Control 2: Loan Origination Policy ───────────────────────────────────
-- Minimum credit scores by loan type:
--   AUTO: 550 | MORTGAGE: 620 | PERSONAL: 580 | HELOC: 640
ctl_2 as (
    select
        l.loan_id                               as control_subject_id,
        l.customer_id,
        'LOAN_ORIGINATION_POLICY'               as control_id,
        'Application Control'                   as control_category,
        'Verify loan originations meet minimum credit score policy thresholds' as control_description,
        'Quarterly'                             as control_frequency,
        case
            when l.loan_type = 'AUTO'     and c.credit_score < 550  then 'EXCEPTION'
            when l.loan_type = 'MORTGAGE' and c.credit_score < 620  then 'EXCEPTION'
            when l.loan_type = 'PERSONAL' and c.credit_score < 580  then 'EXCEPTION'
            when l.loan_type = 'HELOC'    and c.credit_score < 640  then 'EXCEPTION'
            else 'PASS'
        end                                     as test_result,
        case
            when l.loan_type = 'AUTO'     and c.credit_score < 550
                then 'AUTO loan, customer credit score ' || c.credit_score::varchar || ' (min 550)'
            when l.loan_type = 'MORTGAGE' and c.credit_score < 620
                then 'MORTGAGE, customer credit score ' || c.credit_score::varchar || ' (min 620)'
            when l.loan_type = 'PERSONAL' and c.credit_score < 580
                then 'PERSONAL loan, customer credit score ' || c.credit_score::varchar || ' (min 580)'
            when l.loan_type = 'HELOC'    and c.credit_score < 640
                then 'HELOC, customer credit score ' || c.credit_score::varchar || ' (min 640)'
            else null
        end                                     as exception_detail
    from loans l
    join customers c using (customer_id)
),

-- ── Control 3: Dormant Account Review ────────────────────────────────────
-- Dormant accounts with balances > $10,000 must be reviewed for escheatment
-- (State unclaimed property laws; typically triggers after 3-5 years of inactivity)
ctl_3 as (
    select
        account_id                              as control_subject_id,
        customer_id,
        'DORMANT_ACCOUNT_REVIEW'                as control_id,
        'Financial Reporting Control'           as control_category,
        'Identify dormant accounts with significant balances for escheatment review' as control_description,
        'Monthly'                               as control_frequency,
        case
            when account_status = 'DORMANT' and current_balance > 10000 then 'EXCEPTION'
            else 'PASS'
        end                                     as test_result,
        case
            when account_status = 'DORMANT' and current_balance > 10000
                then 'Dormant account balance $' || round(current_balance, 2)::varchar || ' — escheatment risk'
            else null
        end                                     as exception_detail
    from accounts
),

-- ── Control 4: High-Risk Loan Approval ───────────────────────────────────
-- Loans with PD > 15% AND principal > $100K require documented senior credit officer approval
-- (SOX ITGC — Segregation of Duties: front-line vs senior approval)
ctl_4 as (
    select
        loan_id                                 as control_subject_id,
        customer_id,
        'HIGH_RISK_LOAN_APPROVAL'               as control_id,
        'ITGC - Segregation of Duties'          as control_category,
        'Large loans with elevated PD require documented senior credit officer approval' as control_description,
        'Monthly'                               as control_frequency,
        case
            when probability_of_default > 0.15 and original_principal > 100000 then 'EXCEPTION'
            else 'PASS'
        end                                     as test_result,
        case
            when probability_of_default > 0.15 and original_principal > 100000
                then 'Loan $' || round(original_principal)::varchar
                     || ', PD=' || round(probability_of_default * 100, 1)::varchar
                     || '% — senior approval documentation required'
            else null
        end                                     as exception_detail
    from loans
),

-- ── Control 5: Overlimit Review ───────────────────────────────────────────
-- Cards overlimit > 3 times in 12 months must have credit line review initiated
ctl_5 as (
    select
        card_id                                 as control_subject_id,
        customer_id,
        'OVERLIMIT_REVIEW'                      as control_id,
        'Application Control'                   as control_category,
        'Cards with repeated overlimit events require credit line review within 30 days' as control_description,
        'Monthly'                               as control_frequency,
        case
            when times_overlimit_last_12m > 3 then 'EXCEPTION'
            else 'PASS'
        end                                     as test_result,
        case
            when times_overlimit_last_12m > 3
                then 'Card overlimit ' || times_overlimit_last_12m::varchar
                     || ' times in 12 months — credit line review required'
            else null
        end                                     as exception_detail
    from credit_cards
),

all_controls as (
    select * from ctl_1
    union all select * from ctl_2
    union all select * from ctl_3
    union all select * from ctl_4
    union all select * from ctl_5
),

-- Per-control pass rates (for executive summary)
control_summary as (
    select
        control_id,
        count(*)                                                        as total_tested,
        sum(case when test_result = 'PASS'      then 1 else 0 end)     as pass_count,
        sum(case when test_result = 'EXCEPTION' then 1 else 0 end)     as exception_count,
        round(
            sum(case when test_result = 'PASS' then 1.0 else 0 end)
            / nullif(count(*), 0) * 100
        , 2)                                                            as pass_rate_pct
    from all_controls
    group by control_id
)

select
    ac.control_id,
    ac.control_category,
    ac.control_description,
    ac.control_frequency,
    ac.control_subject_id,
    ac.customer_id,
    ac.test_result,
    ac.exception_detail,
    current_date()                  as test_date,

    -- ── Control-level summary (denormalized for BI) ───────────────────────
    cs.total_tested,
    cs.pass_count,
    cs.exception_count,
    cs.pass_rate_pct,

    -- ── Risk rating based on exception rate ───────────────────────────────
    case
        when cs.pass_rate_pct >= 99 then 'LOW_RISK'
        when cs.pass_rate_pct >= 95 then 'MODERATE_RISK'
        when cs.pass_rate_pct >= 90 then 'HIGH_RISK'
        else                             'CRITICAL'
    end                             as control_risk_rating,

    -- ── Audit readiness ────────────────────────────────────────────────────
    case
        when cs.pass_rate_pct >= 95 then 'EVIDENCE_COMPLETE'
        else                             'REMEDIATION_REQUIRED'
    end                             as audit_status,

    current_timestamp()             as dbt_updated_at

from all_controls ac
join control_summary cs using (control_id)
order by
    case ac.test_result when 'EXCEPTION' then 0 else 1 end,
    ac.control_id,
    ac.control_subject_id
