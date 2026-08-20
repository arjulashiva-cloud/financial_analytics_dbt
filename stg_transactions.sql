{{
  config(
    materialized = 'view',
    description = 'Staged transaction records — cleaned, typed, signed amounts normalized, and enriched with date dimensions.'
  )
}}

with source as (
    select * from {{ source('raw_banking', 'transactions') }}
),

cleaned as (
    select
        -- Keys
        transaction_id,
        account_id,

        -- Transaction attributes
        upper(trim(transaction_type))                   as transaction_type,
        upper(trim(status))                             as transaction_status,
        upper(trim(channel))                            as channel,
        trim(merchant_category_code)                    as merchant_category_code,
        trim(description)                               as description,

        -- Amount — normalized so credits are positive, debits negative
        case
            when upper(trim(transaction_type)) in ('CREDIT', 'INTEREST')
                then abs(cast(amount as numeric(18,2)))
            when upper(trim(transaction_type)) in ('DEBIT', 'FEE')
                then -abs(cast(amount as numeric(18,2)))
            else round(cast(amount as numeric(18,2)), 2)
        end                                             as amount,

        abs(cast(amount as numeric(18,2)))              as amount_abs,

        -- Dates
        cast(transaction_date as date)                  as transaction_date,
        date_trunc('month', cast(transaction_date as date))
                                                        as transaction_month,
        date_trunc('year', cast(transaction_date as date))
                                                        as transaction_year,
        dayofweek(cast(transaction_date as date))       as day_of_week,
        cast(posted_date as date)                       as posted_date,
        cast(created_at as timestamp_ntz)               as created_at,

        -- Derived flags
        case
            when upper(trim(status)) = 'POSTED' then true
            else false
        end                                             as is_posted,

        case
            when upper(trim(transaction_type)) = 'REVERSAL' then true
            else false
        end                                             as is_reversal,

        case
            when upper(trim(transaction_type)) = 'FEE' then true
            else false
        end                                             as is_fee,

        -- Metadata
        current_timestamp()                             as dbt_loaded_at

    from source
    where transaction_id is not null
        and transaction_date >= '{{ var("start_date") }}'
)

select * from cleaned
