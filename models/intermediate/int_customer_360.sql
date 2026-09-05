-- int_customer_360.sql
-- Joins the customer base with account, loan, and card aggregates into a
-- single customer-grain row consumed by core and executive marts.

with customers as (
    select * from {{ ref('stg_customers') }}
),

account_summary as (
    select
        customer_id,
        count(*)                                                            as total_accounts,
        sum(case when account_type = 'CHECKING'       then 1 else 0 end)   as checking_count,
        sum(case when account_type = 'SAVINGS'        then 1 else 0 end)   as savings_count,
        sum(case when account_type = 'MONEY_MARKET'   then 1 else 0 end)   as money_market_count,
        sum(case when account_type = 'CD'             then 1 else 0 end)   as cd_count,
        sum(case when account_type like 'IRA%'        then 1 else 0 end)   as ira_count,
        sum(case when account_status = 'ACTIVE'       then 1 else 0 end)   as active_accounts,
        sum(current_balance)                                                as total_deposit_balance,
        max(case when account_type = 'CHECKING'
                  and has_direct_deposit              then 1 else 0 end)   as has_direct_deposit,
        max(case when account_type = 'CHECKING'
                  and has_autopay                    then 1 else 0 end)   as has_autopay,
        min(open_date)                                                      as earliest_account_open
    from {{ ref('stg_accounts') }}
    group by 1
),

loan_summary as (
    select
        customer_id,
        count(*)                                                            as total_loans,
        sum(case when is_active                        then 1 else 0 end)  as active_loans,
        sum(case when loan_type = 'MORTGAGE'           then 1 else 0 end)  as mortgage_count,
        sum(case when loan_type = 'AUTO'               then 1 else 0 end)  as auto_loan_count,
        sum(original_principal)                                             as total_loan_originated,
        sum(current_balance)                                                as total_loan_balance,
        sum(exposure_at_default)                                            as total_ead,
        round(avg(probability_of_default), 4)                              as avg_pd,
        round(avg(loss_given_default),     4)                              as avg_lgd,
        max(delinquency_severity)                                           as max_delinquency_severity,
        max(case when loan_status in ('30DPD','60DPD','90DPD')
                  then 1 else 0 end)                                       as has_delinquent_loan
    from {{ ref('stg_loans') }}
    group by 1
),

card_summary as (
    select
        customer_id,
        count(*)                                                            as total_cards,
        sum(credit_limit)                                                   as total_credit_limit,
        sum(current_balance)                                                as total_card_balance,
        round(avg(utilization_rate), 4)                                    as avg_utilization,
        max(case when payment_pattern = 'MISSED'       then 1 else 0 end)  as has_missed_payment,
        max(case when has_fraud_dispute                then 1 else 0 end)  as has_fraud_dispute,
        sum(rewards_balance_points)                                         as total_rewards_points,
        max(case when card_product = 'PREMIUM'         then 1 else 0 end)  as has_premium_card,
        max(case when card_product = 'TRAVEL_REWARDS'  then 1 else 0 end)  as has_travel_card
    from {{ ref('stg_credit_cards') }}
    group by 1
)

select
    -- ── Customer identity ────────────────────────────────────────────────────
    c.customer_id,
    c.full_name,
    c.email,
    c.phone,
    c.city,
    c.state,
    c.zip_code,

    -- ── Demographics ────────────────────────────────────────────────────────
    c.age,
    c.income_band,
    c.credit_score,
    c.credit_tier,
    c.lifecycle_stage,
    c.relationship_value_tier,
    c.tenure_bucket,
    c.customer_since_date,
    c.churn_risk_score,
    c.is_active,

    -- ── Account metrics ──────────────────────────────────────────────────────
    coalesce(a.total_accounts,        0)    as total_accounts,
    coalesce(a.checking_count,        0)    as checking_count,
    coalesce(a.savings_count,         0)    as savings_count,
    coalesce(a.money_market_count,    0)    as money_market_count,
    coalesce(a.cd_count,              0)    as cd_count,
    coalesce(a.ira_count,             0)    as ira_count,
    coalesce(a.active_accounts,       0)    as active_accounts,
    coalesce(a.total_deposit_balance, 0)    as total_deposit_balance,
    coalesce(a.has_direct_deposit,    0)    as has_direct_deposit,
    coalesce(a.has_autopay,           0)    as has_autopay,

    -- ── Loan metrics ─────────────────────────────────────────────────────────
    coalesce(l.total_loans,           0)    as total_loans,
    coalesce(l.active_loans,          0)    as active_loans,
    coalesce(l.mortgage_count,        0)    as mortgage_count,
    coalesce(l.auto_loan_count,       0)    as auto_loan_count,
    coalesce(l.total_loan_originated, 0)    as total_loan_originated,
    coalesce(l.total_loan_balance,    0)    as total_loan_balance,
    coalesce(l.total_ead,             0)    as total_ead,
    l.avg_pd,
    l.avg_lgd,
    coalesce(l.max_delinquency_severity, 0) as max_delinquency_severity,
    coalesce(l.has_delinquent_loan,   0)    as has_delinquent_loan,

    -- ── Card metrics ─────────────────────────────────────────────────────────
    coalesce(cc.total_cards,          0)    as total_cards,
    coalesce(cc.total_credit_limit,   0)    as total_credit_limit,
    coalesce(cc.total_card_balance,   0)    as total_card_balance,
    coalesce(cc.avg_utilization,      0)    as avg_card_utilization,
    coalesce(cc.has_missed_payment,   0)    as has_missed_card_payment,
    coalesce(cc.has_fraud_dispute,    0)    as has_fraud_dispute,
    coalesce(cc.total_rewards_points, 0)    as total_rewards_points,
    coalesce(cc.has_premium_card,     0)    as has_premium_card,
    coalesce(cc.has_travel_card,      0)    as has_travel_card,

    -- ── Composite scores ─────────────────────────────────────────────────────
    -- Relationship depth: how many products does the customer use?
    least(10,
        coalesce(a.active_accounts,    0)
        + coalesce(l.active_loans,     0) * 2
        + coalesce(cc.total_cards,     0)
        + coalesce(a.has_direct_deposit, 0) * 2
        + coalesce(a.has_autopay,      0)
    )                                       as relationship_depth_score,

    -- Total book value (deposits + loans + card balances)
    coalesce(a.total_deposit_balance,  0)
    + coalesce(l.total_loan_balance,   0)
    + coalesce(cc.total_card_balance,  0)   as total_book_value,

    -- Risk flag: any active delinquency or missed card payment
    case when coalesce(l.has_delinquent_loan,    0) = 1
           or coalesce(cc.has_missed_payment,    0) = 1
          then true else false
    end                                     as is_delinquent,

    -- Attrition flag: high churn risk + no direct deposit + no autopay
    case when c.churn_risk_score > 70
           and coalesce(a.has_direct_deposit, 0) = 0
           and coalesce(a.has_autopay,        0) = 0
          then true else false
    end                                     as is_at_risk_of_attrition,

    current_timestamp                       as dbt_updated_at

from customers c
left join account_summary a  on c.customer_id = a.customer_id
left join loan_summary     l  on c.customer_id = l.customer_id
left join card_summary    cc  on c.customer_id = cc.customer_id
