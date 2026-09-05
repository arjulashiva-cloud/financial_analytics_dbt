{#
    calculate_ecl.sql
    ─────────────────
    CECL (Current Expected Credit Loss) macro.

    ECL = PD × LGD × EAD × macro_adjustment

    Args:
        pd_estimate       : probability of default (0–1)
        lgd_estimate      : loss given default (0–1); defaults to var cecl_lgd_default
        ead               : exposure at default (dollar amount)
        macro_scenario    : 'base' | 'adverse' | 'severely_adverse'

    Returns a SQL expression (inline, no CTE needed).

    Usage in a model:
        {{ calculate_ecl('probability_of_default', 'loss_given_default',
                         'exposure_at_default', 'macro_scenario_col') }}
#}

{% macro calculate_ecl(pd_col, lgd_col, ead_col, macro_col) %}

    (
        {{ pd_col }}
        * coalesce({{ lgd_col }}, {{ var('cecl_lgd_default') }})
        * {{ ead_col }}
        * case {{ macro_col }}
              when 'severely_adverse' then 1.50
              when 'adverse'          then 1.20
              else                         1.00
          end
    )

{% endmacro %}
