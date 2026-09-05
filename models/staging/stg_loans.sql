-- stg_loans.sql
-- Staging layer for RAW_LOANS.
-- Adds delinquency_severity scale (1-5), is_active flag, exposure_at_default alias.

with source as (
    select * from {{ source('raw', 'RAW_LOANS') }}
),

renamed as (
    select
        -- ── Keys ─────────────────────────────────────────────────────────────
        loan_id,
        customer_id,

        -- ── Product & status ──────────────────────────────────────────────────
        loan_type,
        loan_status,

        -- ── Dates ─────────────────────────────────────────────────────────────
        origination_date,
        maturity_date,
        term_months,

        -- ── Financials ────────────────────────────────────────────────────────
        original_principal,
        current_balance,
        monthly_payment,
        interest_rate,
        annual_percentage_rate,

        -- ── Collateral / leverage ─────────────────────────────────────────────
        loan_to_value_ratio,
        debt_to_income_ratio,

        -- ── Delinquency ───────────────────────────────────────────────────────
        days_past_due,
        times_30dpd_last_12m,
        times_60dpd_last_12m,

        -- Ordinal severity scale for sorting / scoring
        case loan_status
            when 'CHARGED_OFF' then 5
            when '90DPD'       then 4
            when '60DPD'       then 3
            when '30DPD'       then 2
            when 'CURRENT'     then 1
            else                    0    -- PAID_OFF
        end                                             as delinquency_severity,

        -- ── CECL risk inputs ──────────────────────────────────────────────────
        probability_of_default,
        loss_given_default,
        exposure_at_default,                            -- = current_balance for active loans

        -- ── Flags ─────────────────────────────────────────────────────────────
        loan_status not in ('PAID_OFF', 'CHARGED_OFF')  as is_active,
        loan_status = 'CHARGED_OFF'                     as is_charged_off,
        loan_status = 'PAID_OFF'                        as is_paid_off,

        -- ── Metadata ─────────────────────────────────────────────────────────
        created_at

    from source
)

select * from renamed
