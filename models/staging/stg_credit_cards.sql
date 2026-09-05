-- stg_credit_cards.sql
-- Staging layer for RAW_CREDIT_CARDS.
-- Adds utilization_bucket, available_credit, days_since_open.

with source as (
    select * from {{ source('raw', 'RAW_CREDIT_CARDS') }}
),

renamed as (
    select
        -- ── Keys ─────────────────────────────────────────────────────────────
        card_id,
        customer_id,

        -- ── Product & status ──────────────────────────────────────────────────
        card_product,                   -- SECURED / CASH_BACK / TRAVEL_REWARDS / PREMIUM / STORE_BRANDED
        card_status,                    -- ACTIVE / SUSPENDED / CLOSED

        -- ── Dates ─────────────────────────────────────────────────────────────
        open_date,
        datediff('day',   open_date, current_date())    as days_since_open,
        datediff('month', open_date, current_date())    as months_since_open,

        -- ── Financials ────────────────────────────────────────────────────────
        credit_limit,
        current_balance,
        statement_balance,
        minimum_payment_due,
        annual_percentage_rate,
        annual_fee,
        credit_limit - current_balance                  as available_credit,

        -- ── Utilization ───────────────────────────────────────────────────────
        utilization_rate,
        case
            when utilization_rate >= 0.90  then 'maxed'
            when utilization_rate >= 0.60  then 'high'
            when utilization_rate >= 0.30  then 'moderate'
            else                                'low'
        end                                             as utilization_bucket,

        -- ── Payment behaviour ─────────────────────────────────────────────────
        payment_pattern,                -- FULL / MINIMUM / PARTIAL / MISSED
        payment_status,                 -- CURRENT / MINIMUM_PAY / 30DPD / 60DPD / 90DPD
        months_since_missed_pmt,
        times_overlimit_last_12m,
        autopay_enrolled,

        -- ── Rewards ───────────────────────────────────────────────────────────
        rewards_type,
        rewards_balance_points,

        -- ── Risk flags ────────────────────────────────────────────────────────
        has_fraud_dispute,
        fraud_dispute_amount,

        -- ── Metadata ─────────────────────────────────────────────────────────
        created_at

    from source
)

select * from renamed
