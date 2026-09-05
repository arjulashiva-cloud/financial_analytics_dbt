-- stg_customers.sql
-- Staging layer for RAW_CUSTOMERS.
-- Adds credit_tier label and tenure_bucket derived columns.

with source as (
    select * from {{ source('raw', 'RAW_CUSTOMERS') }}
),

renamed as (
    select
        -- ── Keys ─────────────────────────────────────────────────────────────
        customer_id,

        -- ── Identity ─────────────────────────────────────────────────────────
        first_name,
        last_name,
        first_name || ' ' || last_name          as full_name,
        email,
        phone,

        -- ── Demographics ─────────────────────────────────────────────────────
        date_of_birth,
        age,
        gender,
        city,
        state,
        zip_code,
        income_band,

        -- ── Credit & risk ────────────────────────────────────────────────────
        credit_score,
        case
            when credit_score >= 800 then 'exceptional'
            when credit_score >= 740 then 'very_good'
            when credit_score >= 670 then 'good'
            when credit_score >= 580 then 'fair'
            else                          'poor'
        end                                     as credit_tier,

        churn_risk_score,

        -- ── Relationship ─────────────────────────────────────────────────────
        customer_since_date,
        tenure_months,
        acquisition_channel,
        lifecycle_stage,
        relationship_value_tier,
        is_active,

        -- Tenure bucket for segmentation
        case
            when tenure_months <  12  then '0-1yr'
            when tenure_months <  36  then '1-3yr'
            when tenure_months <  60  then '3-5yr'
            when tenure_months < 120  then '5-10yr'
            else                           '10yr+'
        end                                     as tenure_bucket,

        -- ── Metadata ─────────────────────────────────────────────────────────
        created_at

    from source
)

select * from renamed