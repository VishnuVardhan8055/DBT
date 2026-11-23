
WITH salesinfo AS (
    SELECT
        gender,
        sales_id,
        gross_amount
    FROM {{ ref('sliver_salesinfo') }}
)

SELECT
    gender,
    COUNT(DISTINCT sales_id) AS total_transactions,
    SUM(gross_amount) AS total_sales,
    AVG(gross_amount) AS average_sales,
    MAX(gross_amount) AS highest_sale,
    MIN(gross_amount) AS lowest_sale

FROM salesinfo

GROUP BY gender

ORDER BY total_sales DESC
