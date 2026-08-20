{{
  config(
    materialized = 'view',
    description = 'Customer-level financial rollup — deposits, loans, credit cards aggregated to one row per customer.'
  )
}}

with customers as (
    select * from {{ ref('stg_customers') }}
),

accounts as (
    select * from {{ ref('stg_accounts') }}
),

loans as (
    select * from {{ ref('stg_loans') }}
),

credit_cards as (
    select * from {{ ref('stg_credit_cards') }}
),

-- Aggregate accounts per customer
account_summary as (
    select
        customer_id,
        count(*)                                        as total_accounts,
        count(case when is_active then 1 end)           as active_accounts,
        sum(balance)                                    as total_deposit_balance,
        sum(case when account_type = 'CHECKING'
            then balance else 0 end)                    as checking_balance,
        sum(case when account_type = 'SAVINGS'
            then balance else 0 end)                    as savings_balance,
        min(opened_date)                                as first_account_date,
        max(opened_date)                                as latest_account_date
    from accounts
    group by 1
),

-- Aggregate loans per customer
loan_summary as (
    select
        customer_id,
        count(*)                                        as total_loans,
        count(case when not is_paid_off
            and not is_charged_off then 1 end)          as active_loans,
        sum(outstanding_balance)                        as total_loan_balance,
        sum(principal_amount)                           as total_loan_originated,
        count(case when is_delinquent then 1 end)       as delinquent_loans,
        count(case when is_charged_off then 1 end)      as charged_off_loans,
        max(origination_date)                           as latest_loan_date
    from loans
    group by 1
),

-- Aggregate credit cards per customer
card_summary as (
    select
        customer_id,
        count(*)                                        as total_cards,
        count(case when is_active then 1 end)           as active_cards,
        sum(credit_limit)                               as total_credit_limit,
        sum(current_balance)                            as total_card_balance,
        avg(utilization_rate_pct)                       as avg_utilization_rate,
        max(case when utilization_risk = 'HIGH'
            then 1 else 0 end)                          as has_high_utilization
    from credit_cards
    group by 1
),

final as (
    select
        c.customer_id,
        c.full_name,
        c.customer_segment,
        c.acquisition_channel,
        c.state,
        c.customer_since_date,
        c.customer_tenure_days,
        c.is_premium_customer,
        c.is_new_customer,

        -- Deposit summary
        coalesce(a.total_accounts, 0)                   as total_accounts,
        coalesce(a.active_accounts, 0)                  as active_accounts,
        coalesce(a.total_deposit_balance, 0)            as total_deposit_balance,
        coalesce(a.checking_balance, 0)                 as checking_balance,
        coalesce(a.savings_balance, 0)                  as savings_balance,
        a.first_account_date,

        -- Loan summary
        coalesce(l.total_loans, 0)                      as total_loans,
        coalesce(l.active_loans, 0)                     as active_loans,
        coalesce(l.total_loan_balance, 0)               as total_loan_balance,
        coalesce(l.total_loan_originated, 0)            as total_loan_originated,
        coalesce(l.delinquent_loans, 0)                 as delinquent_loans,
        coalesce(l.charged_off_loans, 0)                as charged_off_loans,

        -- Credit card summary
        coalesce(k.total_cards, 0)                      as total_cards,
        coalesce(k.active_cards, 0)                     as active_cards,
        coalesce(k.total_credit_limit, 0)               as total_credit_limit,
        coalesce(k.total_card_balance, 0)               as total_card_balance,
        coalesce(k.avg_utilization_rate, 0)             as avg_utilization_rate,
        coalesce(k.has_high_utilization, 0)             as has_high_utilization,

        -- Total relationship value (AUM proxy)
        coalesce(a.total_deposit_balance, 0)
            + coalesce(l.total_loan_balance, 0)
            + coalesce(k.total_card_balance, 0)         as total_relationship_value,

        -- Product depth (number of product types held)
        (case when coalesce(a.active_accounts, 0) > 0
            then 1 else 0 end)
        + (case when coalesce(l.active_loans, 0) > 0
            then 1 else 0 end)
        + (case when coalesce(k.active_cards, 0) > 0
            then 1 else 0 end)                          as product_depth,

        -- Risk flag
        case
            when coalesce(l.delinquent_loans, 0) > 0
                or coalesce(l.charged_off_loans, 0) > 0
                or coalesce(k.has_high_utilization, 0) = 1
            then true else false
        end                                             as has_risk_flag,

        current_timestamp()                             as dbt_loaded_at

    from customers c
    left join account_summary a on c.customer_id = a.customer_id
    left join loan_summary l on c.customer_id = l.customer_id
    left join card_summary k on c.customer_id = k.customer_id
)

select * from final
