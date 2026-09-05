-- int_account_monthly.sql
-- Monthly transaction aggregates per account.
-- Grain: one row per account per calendar month.
-- Consumed by: mart_nim_analysis, mart_deposit_stability, mart_executive_kpis

with txns as (
    select * from {{ ref('stg_transactions') }}
),

accounts as (
    select
        account_id,
        customer_id,
        account_type,
        interest_rate,
        current_balance,
        has_direct_deposit,
        has_autopay
    from {{ ref('stg_accounts') }}
    where account_status != 'CLOSED'
)

select
    t.account_id,
    a.customer_id,
    a.account_type,
    a.interest_rate,
    a.current_balance                                                        as ending_balance,
    a.has_direct_deposit,
    a.has_autopay,
    date_trunc('month', t.transaction_date)::date                           as month_start,

    -- ── Volume ────────────────────────────────────────────────────────────────
    count(*)                                                                 as txn_count,
    sum(case when t.is_debit  then t.amount else 0 end)                     as total_debits,
    sum(case when t.is_credit then t.amount else 0 end)                     as total_credits,
    sum(case when t.is_debit  then t.amount else 0 end)
    - sum(case when t.is_credit then t.amount else 0 end)                   as net_outflow,

    -- ── Category spend (checking focus) ───────────────────────────────────────
    sum(case when t.transaction_category = 'payroll'
             then t.amount else 0 end)                                      as payroll_credits,
    sum(case when t.transaction_category = 'groceries'
             then t.amount else 0 end)                                      as grocery_spend,
    sum(case when t.transaction_category = 'dining'
             then t.amount else 0 end)                                      as dining_spend,
    sum(case when t.transaction_category = 'gas_station'
             then t.amount else 0 end)                                      as gas_spend,
    sum(case when t.transaction_category = 'travel'
             then t.amount else 0 end)                                      as travel_spend,
    sum(case when t.transaction_category = 'amazon'
             then t.amount else 0 end)                                      as amazon_spend,

    -- ── Risk signals ──────────────────────────────────────────────────────────
    sum(t.is_fraud_signal::int)                                             as fraud_signals,
    sum(t.is_overdraft::int)                                                as overdraft_txns,
    sum(case when t.transaction_category = 'fee'
             then t.amount else 0 end)                                      as fee_charges,

    -- ── Channel mix ───────────────────────────────────────────────────────────
    sum(case when t.channel = 'mobile'  then 1 else 0 end)                 as mobile_txns,
    sum(case when t.channel = 'online'  then 1 else 0 end)                 as online_txns,
    sum(case when t.channel = 'pos'     then 1 else 0 end)                 as pos_txns,
    sum(case when t.channel = 'atm'     then 1 else 0 end)                 as atm_txns,
    sum(case when t.channel = 'branch'  then 1 else 0 end)                 as branch_txns,

    -- Digital adoption (mobile + online share of total)
    round(
        sum(case when t.channel in ('mobile','online') then 1 else 0 end) * 1.0
        / nullif(count(*), 0),
    4)                                                                       as digital_adoption_rate,

    -- ── Interest income estimate ───────────────────────────────────────────────
    -- Simple: balance × monthly rate; used in NIM mart
    round(a.current_balance * (a.interest_rate / 100.0) / 12, 2)           as est_interest_income,

    current_timestamp                                                        as dbt_updated_at

from txns t
inner join accounts a on t.account_id = a.account_id
group by
    t.account_id, a.customer_id, a.account_type, a.interest_rate,
    a.current_balance, a.has_direct_deposit, a.has_autopay,
    date_trunc('month', t.transaction_date)::date
