{{
  config(
    materialized = 'view',
    description = 'Staged credit card records — cleaned, typed, utilization rate derived, and risk flags added.'
  )
}}

with source as (
    select * from {{ source('raw_banking', 'credit_cards') }}
),

cleaned as (
    select
        -- Keys
        card_id,
        customer_id,

        -- Card attributes
        upper(trim(card_status))                        as card_status,
        upper(trim(card_product))                       as card_product,
        upper(trim(rewards_program))                    as rewards_program,

        -- Financials
        round(cast(credit_limit as numeric(18,2)), 2)   as credit_limit,
        round(cast(current_balance as numeric(18,2)), 2)
                                                        as current_balance,
        round(cast(minimum_payment_due as numeric(18,2)), 2)
                                                        as minimum_payment_due,
        round(cast(last_payment_amount as numeric(18,2)), 2)
                                                        as last_payment_amount,
        round(cast(annual_fee as numeric(18,2)), 2)     as annual_fee,
        round(cast(interest_rate as numeric(8,4)), 4)   as interest_rate,

        -- Derived: utilization rate
        round(
            cast(current_balance as numeric(18,2))
            / nullif(cast(credit_limit as numeric(18,2)), 0) * 100,
        2)                                              as utilization_rate_pct,

        -- Derived: available credit
        round(
            cast(credit_limit as numeric(18,2))
            - cast(current_balance as numeric(18,2)),
        2)                                              as available_credit,

        -- Dates
        cast(opened_date as date)                       as opened_date,
        cast(closed_date as date)                       as closed_date,
        cast(last_payment_date as date)                 as last_payment_date,
        cast(statement_close_date as date)              as statement_close_date,
        cast(updated_at as timestamp_ntz)               as updated_at,

        -- Status flags
        case
            when upper(trim(card_status)) = 'ACTIVE' then true
            else false
        end                                             as is_active,

        -- Utilization risk flag
        case
            when cast(current_balance as numeric(18,2))
                / nullif(cast(credit_limit as numeric(18,2)), 0) >= 0.90
                then 'HIGH'
            when cast(current_balance as numeric(18,2))
                / nullif(cast(credit_limit as numeric(18,2)), 0) >= 0.70
                then 'MEDIUM'
            else 'LOW'
        end                                             as utilization_risk,

        -- Card age in months
        datediff('month', cast(opened_date as date), current_date())
                                                        as card_age_months,

        -- Metadata
        current_timestamp()                             as dbt_loaded_at

    from source
    where card_id is not null
)

select * from cleaned
