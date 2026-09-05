-- stg_transactions.sql
-- Staging layer for RAW_TRANSACTIONS.
-- Adds debit/credit flags, time dimensions, and overdraft proxy.

with source as (
    select * from {{ source('raw', 'RAW_TRANSACTIONS') }}
),

renamed as (
    select
        -- ── Keys ─────────────────────────────────────────────────────────────
        transaction_id,
        account_id,
        customer_id,

        -- ── Transaction core ──────────────────────────────────────────────────
        transaction_date,
        transaction_type,
        transaction_category,
        merchant_category_code,
        merchant_name,
        channel,
        amount,
        balance_after,

        -- ── Debit / credit flags ──────────────────────────────────────────────
        transaction_type = 'DEBIT'              as is_debit,
        transaction_type = 'CREDIT'             as is_credit,

        -- Overdraft proxy: debit that pushed balance negative
        (transaction_type = 'DEBIT'
         and balance_after < 0)                 as is_overdraft,

        -- ── Risk ──────────────────────────────────────────────────────────────
        is_fraud_signal,

        -- ── Time dimensions ───────────────────────────────────────────────────
        date_trunc('month', transaction_date)::date  as transaction_month,
        date_trunc('week',  transaction_date)::date  as transaction_week,
        dayofweek(transaction_date)                  as day_of_week,    -- 0=Sun, 6=Sat
        hour(transaction_date)                       as hour_of_day,
        dayofweek(transaction_date) in (0, 6)        as is_weekend,
        hour(transaction_date) between 22 and 23
            or hour(transaction_date) between 0 and 5 as is_off_hours,

        -- ── Metadata ─────────────────────────────────────────────────────────
        created_at

    from source
)

select * from renamed
