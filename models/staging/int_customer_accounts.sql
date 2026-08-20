{{
  config(
    materialized = 'view',
    description = 'Customer-account grain — one row per customer-account combination with relationship context and financial summary.'
  )
}}

with customers as (
    select * from {{ ref('stg_customers') }}
),

accounts as (
    select * from {{ ref('stg_accounts') }}
),

joined as (
    select
        -- Customer keys & identity
        c.customer_id,
        c.full_name,
        c.customer_segment,
        c.acquisition_channel,
        c.state,
        c.customer_since_date,
        c.customer_tenure_days,
        c.is_premium_customer,
        c.is_new_customer,

        -- Account keys & attributes
        a.account_id,
        a.account_type,
        a.account_category,
        a.account_status,
        a.is_active                                     as account_is_active,
        a.opened_date                                   as account_opened_date,
        a.account_age_days,
        a.currency_code,

        -- Financial
        a.balance,
        a.available_balance,
        a.interest_rate,

        -- Relationship metadata
        datediff('day', c.customer_since_date, a.opened_date)
                                                        as days_to_account_open,

        case
            when a.opened_date = c.customer_since_date then true
            else false
        end                                             as is_first_account,

        current_timestamp()                             as dbt_loaded_at

    from customers c
    inner join accounts a
        on c.customer_id = a.customer_id
)

select * from joined
