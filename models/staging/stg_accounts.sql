{{
  config(
    materialized = 'view',
    description = 'Staged account records — cleaned, typed, and enriched with derived status flags.'
  )
}}

with source as (
    select * from {{ source('raw_banking', 'accounts') }}
),

cleaned as (
    select
        -- Keys
        account_id,
        customer_id,

        -- Account attributes — standardized
        upper(trim(account_type))                       as account_type,
        upper(trim(account_status))                     as account_status,
        upper(trim(currency_code))                      as currency_code,

        -- Financials — rounded to 2 decimal places
        round(cast(balance as numeric(18,2)), 2)        as balance,
        round(cast(available_balance as numeric(18,2)), 2)
                                                        as available_balance,
        round(cast(interest_rate as numeric(8,4)), 4)   as interest_rate,

        -- Dates
        cast(opened_date as date)                       as opened_date,
        cast(closed_date as date)                       as closed_date,
        cast(updated_at as timestamp_ntz)               as updated_at,

        -- Derived flags
        case
            when upper(trim(account_status)) = 'ACTIVE' then true
            else false
        end                                             as is_active,

        case
            when upper(trim(account_status)) = 'CLOSED'
                and closed_date is not null then true
            else false
        end                                             as is_closed,

        case
            when upper(trim(account_type))
                in ('CHECKING', 'SAVINGS', 'MONEY_MARKET') then 'DEPOSIT'
            when upper(trim(account_type))
                in ('CD') then 'TERM_DEPOSIT'
            when upper(trim(account_type))
                in ('INVESTMENT') then 'INVESTMENT'
            else 'OTHER'
        end                                             as account_category,

        -- Account age in days
        datediff('day', cast(opened_date as date), current_date())
                                                        as account_age_days,

        -- Metadata
        current_timestamp()                             as dbt_loaded_at

    from source
    where account_id is not null
)

select * from cleaned
