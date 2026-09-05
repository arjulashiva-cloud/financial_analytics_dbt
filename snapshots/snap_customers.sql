{% snapshot snap_customers %}

{{
    config(
        target_schema = 'SNAPSHOTS',
        unique_key    = 'customer_id',
        strategy      = 'check',
        check_cols    = ['credit_tier', 'lifecycle_stage', 'churn_risk_score']
    )
}}

select
    customer_id,
    full_name,
    email,
    state,
    credit_score,
    credit_tier,
    income_band,
    lifecycle_stage,
    churn_risk_score,
    relationship_value_tier,
    tenure_months,
    current_timestamp() as snapshotted_at

from {{ ref('stg_customers') }}

{% endsnapshot %}