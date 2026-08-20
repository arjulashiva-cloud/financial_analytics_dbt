{{
  config(
    materialized = 'table',
    description = 'Customer 360 golden record — one row per customer with full financial profile, segmentation, lifecycle stage, and LTV estimate. Primary mart for GTM, retention, and executive reporting.'
  )
}}

with base as (
    select * from {{ ref('int_customer_financials') }}
),

transactions as (
    select
        a.customer_id,
        count(t.transaction_id)                         as total_transactions_12m,
        sum(case when t.transaction_type = 'DEBIT'
            then t.amount_abs else 0 end)               as total_spend_12m,
        sum(case when t.transaction_type = 'FEE'
            then t.amount_abs else 0 end)               as total_fees_12m,
        max(t.transaction_date)                         as last_transaction_date,
        count(distinct t.transaction_month)             as active_months_12m
    from {{ ref('stg_transactions') }} t
    inner join {{ ref('stg_accounts') }} a
        on t.account_id = a.account_id
    where t.transaction_date >= dateadd('year', -1, current_date())
        and t.is_posted = true
        and t.is_reversal = false
    group by 1
),

final as (
    select
        -- Identity
        b.customer_id,
        b.full_name,
        b.customer_segment,
        b.acquisition_channel,
        b.state,
        b.customer_since_date,
        b.customer_tenure_days,
        b.is_premium_customer,
        b.is_new_customer,

        -- Financial profile
        b.total_accounts,
        b.active_accounts,
        b.total_deposit_balance,
        b.checking_balance,
        b.savings_balance,
        b.total_loans,
        b.active_loans,
        b.total_loan_balance,
        b.total_cards,
        b.active_cards,
        b.total_credit_limit,
        b.total_card_balance,
        b.avg_utilization_rate,
        b.total_relationship_value,
        b.product_depth,
        b.has_risk_flag,

        -- Transaction activity
        coalesce(t.total_transactions_12m, 0)           as total_transactions_12m,
        coalesce(t.total_spend_12m, 0)                  as total_spend_12m,
        coalesce(t.total_fees_12m, 0)                   as total_fees_12m,
        t.last_transaction_date,
        coalesce(t.active_months_12m, 0)                as active_months_12m,

        -- Engagement score (0-100)
        least(100,
            coalesce(t.active_months_12m, 0) * 5
            + b.product_depth * 15
            + case when b.total_deposit_balance > 10000 then 20 else 0 end
            + case when b.is_premium_customer then 10 else 0 end
        )                                               as engagement_score,

        -- Lifecycle stage
        case
            when b.customer_tenure_days <= 90           then 'ONBOARDING'
            when coalesce(t.active_months_12m, 0) = 0  then 'DORMANT'
            when coalesce(t.active_months_12m, 0) <= 3 then 'AT_RISK'
            when b.product_depth >= 2
                and coalesce(t.active_months_12m, 0) >= 9
                                                        then 'LOYAL'
            else 'ACTIVE'
        end                                             as lifecycle_stage,

        -- LTV tier (simplified proxy)
        case
            when b.total_relationship_value >= 100000   then 'TIER_1_HIGH_VALUE'
            when b.total_relationship_value >= 25000    then 'TIER_2_MID_VALUE'
            when b.total_relationship_value >= 5000     then 'TIER_3_STANDARD'
            else 'TIER_4_LOW_VALUE'
        end                                             as ltv_tier,

        -- Churn risk flag
        case
            when coalesce(t.active_months_12m, 0) = 0
                and b.customer_tenure_days > 90         then 'HIGH'
            when coalesce(t.active_months_12m, 0) <= 2 then 'MEDIUM'
            else 'LOW'
        end                                             as churn_risk,

        -- Days since last transaction
        datediff('day', t.last_transaction_date, current_date())
                                                        as days_since_last_txn,

        current_timestamp()                             as dbt_loaded_at

    from base b
    left join transactions t on b.customer_id = t.customer_id
)

select * from final
