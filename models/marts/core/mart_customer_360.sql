-- mart_customer_360.sql
-- Final customer-grain mart. The single source of truth for customer analytics.
-- Grain: one row per customer.
-- Powers: Power BI Customer 360 page, churn model feature store, executive KPI roll-ups

{{ config(materialized='table', schema='MARTS_CORE') }}

with c360 as (
    select * from {{ ref('int_customer_360') }}
)

select
    -- ── Identity ─────────────────────────────────────────────────────────────
    customer_id,
    full_name,
    email,
    city,
    state,
    customer_since_date,

    -- ── Demographics ─────────────────────────────────────────────────────────
    age,
    income_band,
    credit_score,
    credit_tier,
    lifecycle_stage,
    relationship_value_tier,
    tenure_bucket,
    churn_risk_score,
    is_active,

    -- ── Deposit relationship ──────────────────────────────────────────────────
    total_accounts,
    active_accounts,
    checking_count,
    savings_count,
    money_market_count,
    cd_count,
    ira_count,
    total_deposit_balance,
    has_direct_deposit,
    has_autopay,

    -- ── Loan relationship ─────────────────────────────────────────────────────
    total_loans,
    active_loans,
    mortgage_count,
    auto_loan_count,
    total_loan_originated,
    total_loan_balance,

    -- ── Credit card relationship ───────────────────────────────────────────────
    total_cards,
    total_credit_limit,
    total_card_balance,
    avg_card_utilization,
    has_missed_card_payment,
    has_fraud_dispute,
    total_rewards_points,
    has_premium_card,
    has_travel_card,

    -- ── Risk indicators ───────────────────────────────────────────────────────
    avg_pd,
    avg_lgd,
    total_ead,
    max_delinquency_severity,
    has_delinquent_loan,
    is_delinquent,
    is_at_risk_of_attrition,

    -- ── Composite metrics ─────────────────────────────────────────────────────
    relationship_depth_score,
    total_book_value,

    -- Revenue proxy: interest income on loans + credit spread on cards
    -- (simplified, no cost of funds subtracted here — that's NIM mart's job)
    round(
        total_loan_balance   * 0.065 / 12   -- blended loan yield approx
        + total_card_balance * 0.200 / 12,  -- blended card yield approx
    2)                                                                       as est_monthly_revenue,

    -- Product depth bucket for segmentation
    case
        when relationship_depth_score >= 8  then 'DEEP'
        when relationship_depth_score >= 5  then 'ENGAGED'
        when relationship_depth_score >= 2  then 'DEVELOPING'
        else                                     'SHALLOW'
    end                                                                      as engagement_segment,

    -- Churn risk band for targeted retention campaigns
    case
        when churn_risk_score >= 80  then 'CRITICAL'
        when churn_risk_score >= 60  then 'HIGH'
        when churn_risk_score >= 40  then 'MEDIUM'
        else                              'LOW'
    end                                                                      as churn_risk_band,

    current_timestamp                                                        as dbt_updated_at

from c360
