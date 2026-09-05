-- mart_peer_benchmarking.sql
-- Compares our synthetic bank's key ratios against real FDIC peer data.
-- Grain: one row per institution (our bank + all FDIC peers).
-- Powers the peer benchmarking dashboard — NIM, charge-off, loan-to-deposit,
-- with quartile positioning vs. real peers.
-- Schema: MARTS_FINANCE

{{
    config(
        materialized = 'table',
        schema       = 'MARTS_FINANCE'
    )
}}

with fdic_peers as (
    select * from {{ source('raw', 'RAW_FDIC_PEERS') }}
),

-- ── Our Bank metrics (derived from staging models) ────────────────────────
our_loans as (
    select
        sum(current_balance)                                        as loan_balance,
        sum(probability_of_default * loss_given_default
            * exposure_at_default)                                  as ecl,
        sum(exposure_at_default)                                    as ead,
        avg(interest_rate)                                          as avg_loan_rate,
        sum(case when is_charged_off then original_principal
                 else 0 end)                                        as charged_off_principal,
        sum(original_principal)                                     as total_originated
    from {{ ref('stg_loans') }}
),

our_deposits as (
    select
        sum(current_balance)    as deposit_balance
    from {{ ref('stg_accounts') }}
    where account_status = 'ACTIVE'
      and account_type in ('CHECKING','SAVINGS','MONEY_MARKET','CD')
),

our_cards as (
    select
        sum(current_balance * annual_percentage_rate / 100 / 12) as monthly_card_interest
    from {{ ref('stg_credit_cards') }}
    where card_status = 'ACTIVE'
      and payment_pattern != 'FULL'
),

our_bank as (
    select
        'OUR_BANK (Synthetic)'                                      as bank_name,
        'CO'                                                        as state,
        -- Proxy total assets as loans + deposits (simplified)
        round((l.loan_balance + d.deposit_balance) / 1e6, 2)       as total_assets_mm,
        round(d.deposit_balance / 1e6, 2)                          as total_deposits_mm,
        round(l.loan_balance / 1e6, 2)                             as net_loans_mm,
        -- NIM = (loan interest income + card interest income) / avg earning assets
        round(
            (l.loan_balance * l.avg_loan_rate / 100 + c.monthly_card_interest * 12)
            / nullif(l.loan_balance + d.deposit_balance, 0) * 100
        , 2)                                                        as net_interest_margin_pct,
        -- Net charge-off rate
        round(l.charged_off_principal / nullif(l.total_originated, 0) * 100, 2)
                                                                    as net_chargeoff_rate_pct,
        -- Loan-to-deposit ratio
        round(l.loan_balance / nullif(d.deposit_balance, 0) * 100, 2)
                                                                    as loan_to_deposit_ratio_pct,
        -- ECL coverage (our bank only)
        round(l.ecl / nullif(l.ead, 0) * 100, 2)                   as ecl_coverage_pct,
        true                                                        as is_our_bank
    from our_loans l
    cross join our_deposits d
    cross join our_cards c
),

-- ── FDIC peer rows ────────────────────────────────────────────────────────
peers as (
    select
        bank_name,
        state,
        total_assets_mm,
        total_deposits_mm,
        net_loans_mm,
        net_interest_margin_pct,
        net_chargeoff_rate_pct,
        loan_to_deposit_ratio_pct,
        null::float     as ecl_coverage_pct,
        false           as is_our_bank
    from fdic_peers
    where total_assets_mm is not null
      and net_interest_margin_pct is not null
),

-- ── Peer percentile benchmarks ────────────────────────────────────────────
peer_stats as (
    select
        percentile_cont(0.25) within group (order by net_interest_margin_pct)   as nim_p25,
        percentile_cont(0.50) within group (order by net_interest_margin_pct)   as nim_median,
        percentile_cont(0.75) within group (order by net_interest_margin_pct)   as nim_p75,
        percentile_cont(0.25) within group (order by net_chargeoff_rate_pct)    as chargeoff_p25,
        percentile_cont(0.50) within group (order by net_chargeoff_rate_pct)    as chargeoff_median,
        percentile_cont(0.75) within group (order by net_chargeoff_rate_pct)    as chargeoff_p75,
        percentile_cont(0.25) within group (order by loan_to_deposit_ratio_pct) as ldr_p25,
        percentile_cont(0.50) within group (order by loan_to_deposit_ratio_pct) as ldr_median,
        percentile_cont(0.75) within group (order by loan_to_deposit_ratio_pct) as ldr_p75,
        count(*)                                                                 as peer_count
    from peers
),

combined as (
    select * from our_bank
    union all
    select * from peers
)

select
    c.*,
    -- ── Peer benchmark bands (same for every row) ─────────────────────────
    round(ps.nim_p25, 2)           as peer_nim_p25,
    round(ps.nim_median, 2)        as peer_nim_median,
    round(ps.nim_p75, 2)           as peer_nim_p75,
    round(ps.chargeoff_p25, 3)     as peer_chargeoff_p25,
    round(ps.chargeoff_median, 3)  as peer_chargeoff_median,
    round(ps.chargeoff_p75, 3)     as peer_chargeoff_p75,
    round(ps.ldr_p25, 1)           as peer_ldr_p25,
    round(ps.ldr_median, 1)        as peer_ldr_median,
    round(ps.ldr_p75, 1)           as peer_ldr_p75,
    ps.peer_count,

    -- ── Quartile positioning ──────────────────────────────────────────────
    case
        when c.net_interest_margin_pct > ps.nim_p75    then 'TOP_QUARTILE'
        when c.net_interest_margin_pct > ps.nim_median  then 'ABOVE_MEDIAN'
        when c.net_interest_margin_pct > ps.nim_p25    then 'BELOW_MEDIAN'
        else                                                 'BOTTOM_QUARTILE'
    end                             as nim_vs_peers,

    case
        when c.net_chargeoff_rate_pct < ps.chargeoff_p25    then 'BEST_QUARTILE'
        when c.net_chargeoff_rate_pct < ps.chargeoff_median  then 'ABOVE_MEDIAN'
        when c.net_chargeoff_rate_pct < ps.chargeoff_p75    then 'BELOW_MEDIAN'
        else                                                      'WORST_QUARTILE'
    end                             as chargeoff_vs_peers,

    case
        when c.loan_to_deposit_ratio_pct between ps.ldr_p25 and ps.ldr_p75
            then 'IN_RANGE'
        when c.loan_to_deposit_ratio_pct > ps.ldr_p75
            then 'ABOVE_PEER_RANGE'
        else 'BELOW_PEER_RANGE'
    end                             as ldr_vs_peers,

    current_timestamp()             as dbt_updated_at

from combined c
cross join peer_stats ps
