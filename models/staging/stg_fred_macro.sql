-- stg_fred_macro.sql
-- Staging layer for RAW_FRED_MACRO (FRED API pull).
-- Computes rolling 3-month averages and confirms macro scenario classification.

with source as (
    select * from {{ source('raw', 'RAW_FRED_MACRO') }}
),

renamed as (
    select
        -- ── Date ─────────────────────────────────────────────────────────────
        obs_date,
        date_trunc('year', obs_date)::date      as obs_year,

        -- ── Raw series ────────────────────────────────────────────────────────
        fed_funds_rate,
        yield_curve_spread,
        unemployment_rate,
        cpi_index,
        mortgage_30yr_rate,
        cpi_yoy_pct,

        -- ── Rolling 3-month averages (smoothed for scenario logic) ────────────
        avg(unemployment_rate) over (
            order by obs_date
            rows between 2 preceding and current row
        )                                       as unemployment_3m_avg,

        avg(fed_funds_rate) over (
            order by obs_date
            rows between 2 preceding and current row
        )                                       as fed_funds_3m_avg,

        avg(yield_curve_spread) over (
            order by obs_date
            rows between 2 preceding and current row
        )                                       as yield_curve_3m_avg,

        -- ── Macro scenario (from FRED script) ─────────────────────────────────
        macro_scenario,

        -- Is yield curve inverted? (classic recession signal)
        yield_curve_spread < 0                  as is_yield_curve_inverted,

        -- Is inflation elevated? (>4% YoY)
        cpi_yoy_pct > 4.0                       as is_high_inflation,

        -- ── Metadata ─────────────────────────────────────────────────────────
        created_at

    from source
)

select * from renamed
