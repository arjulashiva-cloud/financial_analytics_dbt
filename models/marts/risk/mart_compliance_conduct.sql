-- mart_compliance_conduct.sql
-- CFPB complaint monitoring and conduct risk mart.
-- Grain: one row per CFPB complaint (real public data, banking products, last 2 years).
-- Used for compliance reporting, conduct risk dashboards, product risk monitoring.
-- Schema: MARTS_RISK

{{
    config(
        materialized = 'table',
        schema       = 'MARTS_RISK'
    )
}}

with complaints as (
    select * from {{ source('raw', 'RAW_CFPB_COMPLAINTS') }}
),

enriched as (
    select
        complaint_id,
        date_received,
        product,
        sub_product,
        issue,
        sub_issue,
        company_name,
        state,
        company_response,
        timely_response,
        consumer_disputed,
        tags,
        resolution_category,

        -- ── Standardize to our product taxonomy ──────────────────────────
        case
            when product ilike '%checking%'
              or product ilike '%savings%'   then 'DEPOSIT'
            when product ilike '%mortgage%'  then 'MORTGAGE'
            when product ilike '%credit card%'
              or product ilike '%prepaid%'   then 'CREDIT_CARD'
            when product ilike '%personal loan%'
              or product ilike '%payday%'
              or product ilike '%title loan%' then 'PERSONAL_LOAN'
            else 'OTHER'
        end                                     as product_category,

        -- ── Complaint severity ────────────────────────────────────────────
        -- HIGH: consumer disputed AND bank was late
        -- MEDIUM: either disputed OR late
        -- LOW: timely response, not disputed
        case
            when (consumer_disputed = true) and (timely_response = false)  then 'HIGH'
            when (consumer_disputed = true) or  (timely_response = false)  then 'MEDIUM'
            else                                                                 'LOW'
        end                                     as complaint_severity,

        -- ── Time dimensions ───────────────────────────────────────────────
        date_trunc('month', date_received)::date as complaint_month,
        year(date_received)                      as complaint_year,
        quarter(date_received)                   as complaint_quarter,

        -- ── Outcome flags ─────────────────────────────────────────────────
        resolution_category = 'MONETARY_RELIEF'     as resulted_in_monetary_relief,
        resolution_category = 'IN_PROGRESS'         as is_open,
        consumer_disputed = true                    as was_disputed,
        timely_response   = false                   as was_late

    from complaints
),

-- Portfolio-level SLA metrics (denormalized for BI)
sla_summary as (
    select
        count(*)                                                            as total_complaints,
        sum(case when timely_response = true  then 1 else 0 end)           as timely_count,
        sum(case when consumer_disputed = true then 1 else 0 end)          as disputed_count,
        sum(case when resolution_category = 'MONETARY_RELIEF' then 1 else 0 end) as monetary_relief_count,
        sum(case when resolution_category = 'IN_PROGRESS'     then 1 else 0 end) as open_complaint_count,
        round(avg(case when timely_response = true then 1.0 else 0.0 end) * 100, 2) as timely_rate_pct
    from enriched
)

select
    e.*,

    -- ── Portfolio SLA context ─────────────────────────────────────────────
    s.total_complaints,
    s.timely_count,
    s.disputed_count,
    s.monetary_relief_count,
    s.open_complaint_count,
    s.timely_rate_pct,

    -- ── Conduct risk score (0–100) ────────────────────────────────────────
    -- Higher = more regulatory exposure on this complaint
    (
          case when e.was_late               then 30 else 0 end
        + case when e.was_disputed           then 40 else 0 end
        + case when e.resulted_in_monetary_relief then 30 else 0 end
    )                                               as conduct_risk_score,

    -- ── Regulatory watch flag ─────────────────────────────────────────────
    -- Complaints that are HIGH severity AND resulted in monetary relief
    -- represent the highest regulatory examination risk
    (e.complaint_severity = 'HIGH' and e.resulted_in_monetary_relief) as is_regulatory_watch,

    current_timestamp()                             as dbt_updated_at

from enriched e
cross join sla_summary s
