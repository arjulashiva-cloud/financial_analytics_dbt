-- mart_macro_risk_overlay.sql
-- Grain: one row per FRED monthly observation, enriched with portfolio snapshot metrics.
-- Gives ALM / Treasury teams a macro-aware view of:
--   • Rate environment vs portfolio yield (NIM compression risk)
--   • ECL scenario picks aligned to current macro_scenario
--   • Rate direction signals (rising / falling / stable)
-- Schema: MARTS_RISK

{{
    config(
        materialized = 'table',
        schema       = 'MARTS_RISK'
    )
}}

with macro as (
    select * from {{ ref('stg_fred_macro') }}
),

-- Portfolio ECL by scenario (point-in-time snapshot)
ecl_snapshot as (
    select
        sum(probability_of_default * loss_given_default * exposure_at_default * 1.00) as ecl_base,
        sum(probability_of_default * loss_given_default * exposure_at_default * 1.20) as ecl_adverse,
        sum(probability_of_default * loss_given_default * exposure_at_default * 1.50) as ecl_severely_adverse,
        sum(exposure_at_default)                                                        as total_ead,
        avg(interest_rate)                                                              as avg_loan_rate,
        sum(current_balance)                                                            as total_loan_balance,
        count(*)                                                                        as active_loan_count
    from {{ ref('stg_loans') }}
    where is_active
),

-- Total deposit base (funding cost proxy denominator)
deposit_snapshot as (
    select
        sum(current_balance)    as total_deposit_balance,
        count(distinct customer_id) as depositor_count
    from {{ ref('stg_accounts') }}
    where account_status = 'ACTIVE'
),

-- Card revolving balance (additional earning assets)
card_snapshot as (
    select
        sum(current_balance * 0.20 / 12) * 12 as est_card_annual_interest
    from {{ ref('stg_credit_cards') }}
    where card_status = 'ACTIVE'
      and payment_pattern != 'FULL'
),

final as (
    select
        -- ── Date ──────────────────────────────────────────────────────────────
        m.obs_date,
        m.obs_year,

        -- ── FRED macro conditions ─────────────────────────────────────────────
        m.fed_funds_rate,
        m.fed_funds_3m_avg,
        m.yield_curve_spread,
        m.yield_curve_3m_avg,
        m.unemployment_rate,
        m.unemployment_3m_avg,
        m.cpi_index,
        m.cpi_yoy_pct,
        m.mortgage_30yr_rate,
        m.macro_scenario,
        m.is_yield_curve_inverted,
        m.is_high_inflation,

        -- ── Rate environment label ─────────────────────────────────────────────
        case
            when m.fed_funds_rate >= 5.0 then 'HIGH'
            when m.fed_funds_rate >= 3.0 then 'ELEVATED'
            when m.fed_funds_rate >= 1.0 then 'NORMAL'
            else                              'LOW'
        end                                             as rate_environment,

        -- ── Rate direction (MoM) ──────────────────────────────────────────────
        case
            when m.fed_funds_rate > lag(m.fed_funds_rate) over (order by m.obs_date)
                then 'RISING'
            when m.fed_funds_rate < lag(m.fed_funds_rate) over (order by m.obs_date)
                then 'FALLING'
            else 'STABLE'
        end                                             as rate_direction,

        -- ── Portfolio snapshot (same for every row — denormalized for BI) ─────
        e.total_ead,
        e.total_loan_balance,
        e.active_loan_count,
        e.avg_loan_rate,
        d.total_deposit_balance,
        d.depositor_count,

        -- ── NIM spread: avg loan yield minus fed funds (proxy funding cost) ───
        round(e.avg_loan_rate - m.fed_funds_rate, 2)   as nim_spread_pct,

        -- ── NIM compression warning ───────────────────────────────────────────
        case
            when (e.avg_loan_rate - m.fed_funds_rate) < 1.5  then 'CRITICAL'
            when (e.avg_loan_rate - m.fed_funds_rate) < 2.5  then 'WARNING'
            when (e.avg_loan_rate - m.fed_funds_rate) < 4.0  then 'WATCH'
            else                                                   'HEALTHY'
        end                                             as nim_health,

        -- ── ECL scenarios ─────────────────────────────────────────────────────
        round(e.ecl_base, 2)                            as ecl_base,
        round(e.ecl_adverse, 2)                         as ecl_adverse,
        round(e.ecl_severely_adverse, 2)                as ecl_severely_adverse,

        round(e.ecl_base / nullif(e.total_ead, 0) * 100, 4)              as ecl_coverage_base_pct,
        round(e.ecl_adverse / nullif(e.total_ead, 0) * 100, 4)           as ecl_coverage_adverse_pct,
        round(e.ecl_severely_adverse / nullif(e.total_ead, 0) * 100, 4)  as ecl_coverage_severe_pct,

        -- ── Scenario pick: what reserve to hold given TODAY'S macro ───────────
        case m.macro_scenario
            when 'severely_adverse' then round(e.ecl_severely_adverse, 2)
            when 'adverse'          then round(e.ecl_adverse, 2)
            else                         round(e.ecl_base, 2)
        end                                             as ecl_scenario_pick,

        case m.macro_scenario
            when 'severely_adverse' then round(e.ecl_severely_adverse / nullif(e.total_ead, 0) * 100, 4)
            when 'adverse'          then round(e.ecl_adverse / nullif(e.total_ead, 0) * 100, 4)
            else                         round(e.ecl_base / nullif(e.total_ead, 0) * 100, 4)
        end                                             as ecl_coverage_scenario_pct,

        current_timestamp()                             as dbt_updated_at

    from macro m
    cross join ecl_snapshot e
    cross join deposit_snapshot d
    cross join card_snapshot c
)

select * from final
order by obs_date
