{{
  config(
    materialized = 'table',
    description = 'Customer acquisition funnel and retention cohort mart — monthly new customer acquisition by channel and segment, activation rates, retention cohorts, and churn analysis.'
  )
}}

with customer_360 as (
    select * from {{ ref('mart_customer_360') }}
),

-- Monthly acquisition cohorts
acquisition_cohorts as (
    select
        date_trunc('month', customer_since_date)        as cohort_month,
        acquisition_channel,
        customer_segment,
        count(customer_id)                              as new_customers,
        count(case when product_depth >= 2
            then 1 end)                                 as multi_product_customers,
        count(case when lifecycle_stage = 'ONBOARDING'
            then 1 end)                                 as in_onboarding,
        count(case when lifecycle_stage = 'DORMANT'
            then 1 end)                                 as dormant,
        count(case when lifecycle_stage = 'AT_RISK'
            then 1 end)                                 as at_risk,
        count(case when lifecycle_stage = 'ACTIVE'
            then 1 end)                                 as active,
        count(case when lifecycle_stage = 'LOYAL'
            then 1 end)                                 as loyal,
        avg(total_relationship_value)                   as avg_relationship_value,
        avg(engagement_score)                           as avg_engagement_score,
        sum(total_spend_12m)                            as cohort_total_spend,
        -- Activation rate: customers who moved beyond onboarding
        round(
            count(case when lifecycle_stage != 'ONBOARDING'
                and customer_tenure_days > 90 then 1 end)
            * 100.0
            / nullif(
                count(case when customer_tenure_days > 90
                    then 1 end), 0),
        2)                                              as activation_rate_pct,
        -- Churn rate within cohort
        round(
            count(case when churn_risk = 'HIGH' then 1 end)
            * 100.0 / nullif(count(customer_id), 0),
        2)                                              as churn_risk_rate_pct

    from customer_360
    group by 1, 2, 3
),

-- Channel performance summary
channel_summary as (
    select
        acquisition_channel,
        count(customer_id)                              as total_customers,
        avg(total_relationship_value)                   as avg_ltv,
        avg(customer_tenure_days)                       as avg_tenure_days,
        avg(product_depth)                              as avg_product_depth,
        avg(engagement_score)                           as avg_engagement_score,
        count(case when lifecycle_stage = 'LOYAL'
            then 1 end) * 100.0
            / nullif(count(customer_id), 0)             as loyal_rate_pct,
        count(case when churn_risk = 'HIGH'
            then 1 end) * 100.0
            / nullif(count(customer_id), 0)             as high_churn_rate_pct
    from customer_360
    group by 1
),

-- LTV tier distribution
ltv_distribution as (
    select
        ltv_tier,
        customer_segment,
        acquisition_channel,
        count(customer_id)                              as customer_count,
        sum(total_relationship_value)                   as total_value,
        avg(total_relationship_value)                   as avg_value,
        avg(customer_tenure_days)                       as avg_tenure_days,
        avg(product_depth)                              as avg_product_depth
    from customer_360
    group by 1, 2, 3
)

select
    'ACQUISITION_COHORT'                                as record_type,
    cast(cohort_month as varchar)                       as cohort_month,
    acquisition_channel,
    customer_segment,
    new_customers,
    multi_product_customers,
    active,
    loyal,
    dormant,
    at_risk,
    activation_rate_pct,
    churn_risk_rate_pct,
    avg_relationship_value,
    avg_engagement_score,
    cohort_total_spend,
    current_timestamp()                                 as dbt_loaded_at
from acquisition_cohorts

union all

select
    'CHANNEL_SUMMARY',
    null,
    acquisition_channel,
    null,
    total_customers,
    null,
    null,
    null,
    null,
    null,
    null,
    high_churn_rate_pct,
    avg_ltv,
    avg_engagement_score,
    null,
    current_timestamp()
from channel_summary
