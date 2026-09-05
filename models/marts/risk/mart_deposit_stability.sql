-- mart_deposit_stability.sql
-- Post-SVB deposit stability monitoring mart.
-- Grain: one row per active account with portfolio-level concentration metrics.
-- Key regulatory outputs:
--   • Uninsured deposit % (balances > $250K FDIC limit)
--   • HHI deposit concentration index
--   • CD maturity ladder (30/60/90/180/365+ day buckets)
--   • Deposit stability classification (OPERATIONAL / CORE / RATE_SENSITIVE / TERM_LOCKED / RETIREMENT)
--   • Dormancy risk flags
-- Schema: MARTS_RISK

{{
    config(
        materialized = 'table',
        schema       = 'MARTS_RISK'
    )
}}

with accounts as (
    select * from {{ ref('stg_accounts') }}
    where account_status != 'CLOSED'
),

customers as (
    select
        customer_id,
        credit_tier,
        income_band,
        lifecycle_stage,
        relationship_value_tier,
        tenure_months
    from {{ ref('stg_customers') }}
),

-- Portfolio totals (denominator for concentration calculations)
portfolio_totals as (
    select
        sum(current_balance)                                                        as total_deposits,
        sum(case when account_type in ('CHECKING','SAVINGS')
                 then current_balance else 0 end)                                   as core_deposits,
        sum(case when account_type in ('CD','MONEY_MARKET')
                 then current_balance else 0 end)                                   as term_deposits,
        sum(case when account_type in ('IRA_TRADITIONAL','IRA_ROTH')
                 then current_balance else 0 end)                                   as retirement_deposits,
        count(distinct customer_id)                                                 as depositor_count,
        count(*)                                                                    as account_count
    from accounts
),

-- Per-customer totals (for HHI and uninsured amounts)
customer_totals as (
    select
        customer_id,
        sum(current_balance)                                as customer_total_deposits,
        greatest(sum(current_balance) - 250000, 0)         as uninsured_amount
    from accounts
    group by customer_id
),

-- HHI = Σ (customer_share²) × 10,000
-- >2,500 = highly concentrated; <1,500 = diversified
hhi_calc as (
    select
        sum(
            power(ct.customer_total_deposits / nullif(pt.total_deposits, 0), 2)
        ) * 10000                                           as deposit_hhi
    from customer_totals ct
    cross join portfolio_totals pt
),

-- CD maturity ladder
cd_ladder as (
    select
        sum(case when account_type = 'CD'
                  and datediff('day', current_date(), cd_maturity_date) <= 90
                 then current_balance else 0 end)           as cd_maturing_0_90d,
        sum(case when account_type = 'CD'
                  and datediff('day', current_date(), cd_maturity_date) between 91 and 180
                 then current_balance else 0 end)           as cd_maturing_91_180d,
        sum(case when account_type = 'CD'
                  and datediff('day', current_date(), cd_maturity_date) between 181 and 365
                 then current_balance else 0 end)           as cd_maturing_181_365d,
        sum(case when account_type = 'CD'
                  and datediff('day', current_date(), cd_maturity_date) > 365
                 then current_balance else 0 end)           as cd_maturing_beyond_1yr,
        count(case when account_type = 'CD' then 1 end)    as total_cd_count,
        sum(case when account_type = 'CD'
                 then current_balance else 0 end)           as total_cd_balance
    from accounts
),

-- Portfolio-level uninsured total
portfolio_uninsured as (
    select sum(uninsured_amount) as total_uninsured
    from customer_totals
)

select
    -- ── Account identifiers ────────────────────────────────────────────────
    a.account_id,
    a.customer_id,
    a.account_type,
    a.account_status,
    a.current_balance,
    a.interest_rate,
    a.cd_maturity_date,
    a.cd_maturing_soon,
    a.account_age_months,

    -- ── Customer context ───────────────────────────────────────────────────
    c.credit_tier,
    c.income_band,
    c.lifecycle_stage,
    c.relationship_value_tier,
    c.tenure_months                                         as customer_tenure_months,

    -- ── Uninsured exposure ─────────────────────────────────────────────────
    ct.customer_total_deposits,
    ct.uninsured_amount,
    ct.uninsured_amount > 0                                 as has_uninsured_deposits,

    -- ── Deposit stability classification ──────────────────────────────────
    -- OPERATIONAL = behavioral, low rate-sensitivity (sticky core deposits)
    -- CORE        = core savings, moderate rate-sensitivity
    -- RATE_SENSITIVE = moves quickly if better rates available elsewhere
    -- TERM_LOCKED = locked until maturity date
    -- RETIREMENT  = tax-advantaged, very sticky
    case a.account_type
        when 'CHECKING'        then 'OPERATIONAL'
        when 'SAVINGS'         then 'CORE'
        when 'MONEY_MARKET'    then 'RATE_SENSITIVE'
        when 'CD'              then 'TERM_LOCKED'
        when 'IRA_TRADITIONAL' then 'RETIREMENT'
        when 'IRA_ROTH'        then 'RETIREMENT'
        else 'OTHER'
    end                                                     as deposit_stability_class,

    -- ── Risk flags ─────────────────────────────────────────────────────────
    a.account_status = 'DORMANT'                            as is_dormant,
    a.current_balance < 500 and a.account_age_months > 24  as is_low_engagement,

    -- ── Portfolio totals (denormalized for BI aggregation) ────────────────
    pt.total_deposits,
    pt.core_deposits,
    pt.term_deposits,
    pt.retirement_deposits,
    pt.depositor_count,
    pt.account_count,

    -- ── Concentration metrics ──────────────────────────────────────────────
    round(ct.customer_total_deposits / nullif(pt.total_deposits, 0) * 100, 4)
                                                            as customer_deposit_share_pct,
    round(ct.uninsured_amount / nullif(pt.total_deposits, 0) * 100, 4)
                                                            as customer_uninsured_share_pct,
    round(pu.total_uninsured / nullif(pt.total_deposits, 0) * 100, 2)
                                                            as portfolio_uninsured_pct,

    -- ── HHI index (same for all rows — portfolio-level) ───────────────────
    round(h.deposit_hhi, 0)                                 as deposit_hhi,
    case
        when h.deposit_hhi > 2500 then 'HIGH_CONCENTRATION'
        when h.deposit_hhi > 1500 then 'MODERATE_CONCENTRATION'
        else                           'DIVERSIFIED'
    end                                                     as concentration_classification,

    -- ── CD maturity ladder (portfolio-level) ──────────────────────────────
    round(cl.cd_maturing_0_90d / 1e6, 2)                   as cd_maturing_0_90d_mm,
    round(cl.cd_maturing_91_180d / 1e6, 2)                 as cd_maturing_91_180d_mm,
    round(cl.cd_maturing_181_365d / 1e6, 2)                as cd_maturing_181_365d_mm,
    round(cl.cd_maturing_beyond_1yr / 1e6, 2)              as cd_maturing_beyond_1yr_mm,
    cl.total_cd_count,
    round(cl.total_cd_balance / 1e6, 2)                    as total_cd_balance_mm,

    -- ── Rollover risk score (higher = more runoff risk) ───────────────────
    round(
        (case when ct.uninsured_amount > 0 then 30 else 0 end)
        + (case when a.account_type = 'MONEY_MARKET' then 20 else 0 end)
        + (case when a.account_status = 'DORMANT'    then 25 else 0 end)
        + (case when a.cd_maturing_soon              then 15 else 0 end)
        + (case when c.tenure_months < 12            then 10 else 0 end)
    , 0)                                                    as runoff_risk_score,

    current_timestamp()                                     as dbt_updated_at

from accounts a
join customers c         using (customer_id)
join customer_totals ct  using (customer_id)
cross join portfolio_totals pt
cross join hhi_calc h
cross join cd_ladder cl
cross join portfolio_uninsured pu
