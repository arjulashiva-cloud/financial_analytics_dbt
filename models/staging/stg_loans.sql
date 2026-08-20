{{
  config(
    materialized = 'view',
    description = 'Staged loan records — cleaned, typed, delinquency flags standardized, and risk tiers derived.'
  )
}}

with source as (
    select * from {{ source('raw_banking', 'loans') }}
),

cleaned as (
    select
        -- Keys
        loan_id,
        customer_id,

        -- Loan attributes
        upper(trim(loan_type))                          as loan_type,
        upper(trim(loan_status))                        as loan_status,

        -- Financials
        round(cast(principal_amount as numeric(18,2)), 2)
                                                        as principal_amount,
        round(cast(outstanding_balance as numeric(18,2)), 2)
                                                        as outstanding_balance,
        round(cast(interest_rate as numeric(8,4)), 4)   as interest_rate,
        round(cast(monthly_payment as numeric(18,2)), 2)
                                                        as monthly_payment,

        -- Derived: paid-down amount
        round(
            cast(principal_amount as numeric(18,2))
            - cast(outstanding_balance as numeric(18,2)),
        2)                                              as amount_paid_down,

        -- Derived: paydown percentage
        round(
            (cast(principal_amount as numeric(18,2))
             - cast(outstanding_balance as numeric(18,2)))
            / nullif(cast(principal_amount as numeric(18,2)), 0) * 100,
        2)                                              as pct_paid_down,

        -- Dates
        cast(origination_date as date)                  as origination_date,
        cast(maturity_date as date)                     as maturity_date,
        cast(last_payment_date as date)                 as last_payment_date,
        cast(updated_at as timestamp_ntz)               as updated_at,

        -- Delinquency flags
        case
            when upper(trim(loan_status)) like 'DELINQUENT%' then true
            else false
        end                                             as is_delinquent,

        case
            when upper(trim(loan_status)) = 'CHARGED_OFF' then true
            else false
        end                                             as is_charged_off,

        case
            when upper(trim(loan_status)) = 'PAID_OFF' then true
            else false
        end                                             as is_paid_off,

        -- Risk tier based on status
        case
            when upper(trim(loan_status)) = 'CURRENT'       then '1_CURRENT'
            when upper(trim(loan_status)) = 'DELINQUENT_30' then '2_DPD_30'
            when upper(trim(loan_status)) = 'DELINQUENT_60' then '3_DPD_60'
            when upper(trim(loan_status)) = 'DELINQUENT_90' then '4_DPD_90'
            when upper(trim(loan_status)) = 'CHARGED_OFF'   then '5_CHARGED_OFF'
            when upper(trim(loan_status)) = 'PAID_OFF'      then '0_PAID_OFF'
            else '9_UNKNOWN'
        end                                             as risk_tier,

        -- Loan age in months
        datediff('month', cast(origination_date as date), current_date())
                                                        as loan_age_months,

        -- Metadata
        current_timestamp()                             as dbt_loaded_at

    from source
    where loan_id is not null
)

select * from cleaned
