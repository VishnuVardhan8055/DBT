{% macro gross_calculated_amount(unit_price, quantity) %}

    {{ unit_price }} * {{ quantity }}

{% endmacro %}