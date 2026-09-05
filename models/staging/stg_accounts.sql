-- stg_accounts.sql
-- Staging layer for RAW_ACCOUNTS.
-- Adds account_age_days, product_category, has_positive_balance, cd_maturing_soon.

with source as (
    select * from {{ source('raw', 'RAW_ACCOUNTS') }}
),

renamed as (
    select
        -- ── Keys ─────────────────────────────────────────────────────────────
        account_id,
        customer_id,

        -- ── Product & status ──────────────────────────────────────────────────
        account_type,
        account_status,

        -- Product category grouping for NIM / deposit stability analysis
        case
            when account_type in ('IRA_TRADITIONAL', 'IRA_ROTH') then 'RETIREMENT'
            when account_type = 'CD'                              then 'TERM'
            when account_type = 'MONEY_MARKET'                    then 'MONEY_MARKET'
            else                                                       'DEPOSIT'
        end                                                         as product_category,

        -- ── Dates ─────────────────────────────────────────────────────────────
        open_date,
        close_date,
        datediff('day',   open_date, current_date())               as account_age_days,
        datediff('month', open_date, current_date())               as account_age_months,

        -- ── Balances & rates ──────────────────────────────────────────────────
        current_balance,
        interest_rate,
        overdraft_limit,
        monthly_fee,
        fee_waiver_reason,

        current_balance > 0                                         as has_positive_balance,

        -- ── CD-specific ───────────────────────────────────────────────────────
        cd_term_months,
        cd_maturity_date,
        -- Flag CDs maturing within 90 days (ALM / retention signal)
        case
            when account_type = 'CD'
             and cd_maturity_date is not null
             and datediff('day', current_date(), cd_maturity_date) between 0 and 90
            then true
            else false
        end                                                         as cd_maturing_soon,

        -- ── Engagement flags ──────────────────────────────────────────────────
        has_direct_deposit,
        has_autopay,

        -- ── Metadata ─────────────────────────────────────────────────────────
        created_at

    from source
)

select * from renamed
