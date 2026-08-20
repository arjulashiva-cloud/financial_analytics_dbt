{% macro safe_divide(numerator, denominator, default=0) %}
    case
        when {{ denominator }} = 0 or {{ denominator }} is null
        then {{ default }}
        else {{ numerator }} / {{ denominator }}
    end
{% endmacro %}


{% macro delinquency_bucket(status_field) %}
    case
        when {{ status_field }} = 'CURRENT'       then '1_CURRENT'
        when {{ status_field }} = 'DELINQUENT_30' then '2_DPD_30'
        when {{ status_field }} = 'DELINQUENT_60' then '3_DPD_60'
        when {{ status_field }} = 'DELINQUENT_90' then '4_DPD_90'
        when {{ status_field }} = 'CHARGED_OFF'   then '5_CHARGED_OFF'
        when {{ status_field }} = 'PAID_OFF'       then '0_PAID_OFF'
        else '9_UNKNOWN'
    end
{% endmacro %}


{% macro utilization_risk(balance_field, limit_field) %}
    case
        when {{ safe_divide(balance_field, limit_field) }} >= 0.90 then 'HIGH'
        when {{ safe_divide(balance_field, limit_field) }} >= 0.70 then 'MEDIUM'
        else 'LOW'
    end
{% endmacro %}


{% macro months_since(date_field) %}
    datediff('month', cast({{ date_field }} as date), current_date())
{% endmacro %}


{% macro days_since(date_field) %}
    datediff('day', cast({{ date_field }} as date), current_date())
{% endmacro %}


{#
  generate_surrogate_key: creates a deterministic surrogate key from a list of fields.
  Usage: {{ generate_surrogate_key(['customer_id', 'account_id']) }}
#}
{% macro generate_surrogate_key(field_list) %}
    md5(
        concat_ws('|',
            {% for field in field_list %}
                coalesce(cast({{ field }} as varchar), 'NULL')
                {%- if not loop.last %}, {% endif %}
            {% endfor %}
        )
    )
{% endmacro %}
