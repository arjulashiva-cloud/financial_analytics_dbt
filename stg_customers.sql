{{
  config(
    materialized = 'view',
    description = 'Staged customer records — cleaned, typed, and standardized from raw banking source.'
  )
}}

with source as (
    select * from {{ source('raw_banking', 'customers') }}
),

cleaned as (
    select
        -- Primary key
        customer_id,

        -- Name fields — standardized to proper case
        initcap(trim(first_name))                       as first_name,
        initcap(trim(last_name))                        as last_name,
        initcap(trim(first_name)) || ' '
            || initcap(trim(last_name))                 as full_name,

        -- Contact
        lower(trim(email))                              as email,
        trim(phone)                                     as phone,

        -- Segmentation
        upper(trim(customer_segment))                   as customer_segment,
        upper(trim(acquisition_channel))                as acquisition_channel,
        upper(trim(state))                              as state,
        upper(trim(zip_code))                           as zip_code,

        -- Dates — cast to DATE for consistency
        cast(created_at as date)                        as customer_since_date,
        cast(updated_at as timestamp_ntz)               as updated_at,

        -- Derived flags
        case
            when upper(trim(customer_segment)) = 'PREMIUM' then true
            else false
        end                                             as is_premium_customer,

        case
            when cast(created_at as date)
                >= dateadd('year', -1, current_date()) then true
            else false
        end                                             as is_new_customer,

        -- Age of customer relationship in days
        datediff('day', cast(created_at as date), current_date())
                                                        as customer_tenure_days,

        -- Metadata
        current_timestamp()                             as dbt_loaded_at

    from source
    where customer_id is not null
)

select * from cleaned
