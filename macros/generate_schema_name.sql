{#
    generate_schema_name.sql
    ─────────────────────────
    Override dbt's default schema naming so every layer gets its own clean
    Snowflake schema regardless of whether we're in dev or prod.

    Default behavior would produce things like DBT_DEV_STAGING — we want
    just STAGING in dev and STAGING in prod (scoped to the right database).

    Pattern:
      - If a custom_schema_name is set on the model, use it verbatim
        (uppercased). This makes MARTS_RISK, MARTS_FINANCE, etc. predictable.
      - If not set, fall back to the target schema from profiles.yml.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is none -%}

        {{ default_schema | upper }}

    {%- else -%}

        {{ custom_schema_name | upper }}

    {%- endif -%}

{%- endmacro %}
