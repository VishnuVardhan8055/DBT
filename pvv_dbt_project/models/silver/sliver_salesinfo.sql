
{{ config(materialized='view') }}

WITH sales AS (
    SELECT
        sales_id,
        product_sk,
        customer_sk,
        unit_price,
        quantity,
        {{ gross_calculated_amount('unit_price', 'quantity') }} AS gross_amount,
        payment_method
    FROM {{ ref('bronze_sales') }}
),

product AS (
    SELECT
        product_sk,
        category
    FROM {{ ref('bronze_product') }}
),

customer AS (
    SELECT
        customer_sk,
        gender
    FROM {{ ref('bronze_customer') }}
)

SELECT
    s.sales_id,
    s.product_sk,
    s.customer_sk,
    p.category,
    c.gender,
    s.gross_amount,
    s.payment_method

FROM sales AS s

LEFT JOIN product AS p
    ON s.product_sk = p.product_sk

LEFT JOIN customer AS c
    ON s.customer_sk = c.customer_sk
