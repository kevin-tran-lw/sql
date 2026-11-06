SELECT id FROM ORDER_HDR WHERE numb = '178538'
DECLARE @orderId NVARCHAR(40) = (
    SELECT id
    FROM Stylemaster.dbo.ORDER_HDR
    WHERE numb = '178538'
);

-- ========================================================================

WITH LineQuantities AS (
    SELECT
        ods.lineId,
        SUM(ods.quantity) AS quantity
    FROM dbo.ORDER_DTL_SIZE ods
    GROUP BY ods.lineId
),
DesignSources AS (
    -- Explicitly assigned decorations
    SELECT
        COALESCE(d.parentId, decoration.designId) AS designId,
        d.method,
        SUM(q.quantity) AS quantity
    FROM dbo.ORDER_DTL od
    JOIN dbo.ORDER_DTL_DECORATION decoration
        ON decoration.lineId = od.id
    JOIN dbo.ORDER_DESIGNS d
        ON d.id = decoration.designId
        AND d.variation = decoration.designVariation
        AND d.method NOT IN ('RRAA', 'RRAB')
    JOIN dbo.TreatmentMaster treatment
        ON treatment.TreatmentType = d.method
        AND treatment.vend_numb IS NOT NULL
    JOIN LineQuantities q
        ON q.lineId = od.id
    WHERE od.orderID = @orderId
    GROUP BY
        COALESCE(d.parentId, decoration.designId),
        d.method

    UNION ALL

    -- Decorations inherited from CurrLic catalog data
    SELECT
        COALESCE(d.parentId, decoration.designId),
        d.method,
        SUM(q.quantity)
    FROM dbo.ORDER_DTL od
    JOIN dbo.CurrLicLongSkus_DECORATION decoration
        ON decoration.style_code_no_country = od.sku
        AND decoration.colorCode = od.colorCode
    JOIN dbo.ORDER_DESIGNS d
        ON d.id = decoration.designId
        AND d.variation = decoration.designVariation
        AND d.method NOT IN ('RRAA', 'RRAB')
    JOIN dbo.TreatmentMaster treatment
        ON treatment.TreatmentType = d.method
        AND treatment.vend_numb IS NOT NULL
    JOIN LineQuantities q
        ON q.lineId = od.id
    WHERE od.orderID = @orderId
    GROUP BY
        COALESCE(d.parentId, decoration.designId),
        d.method

    UNION ALL

    -- Decorations inherited from in-stock catalog data
    SELECT
        COALESCE(d.parentId, decoration.designId),
        d.method,
        SUM(q.quantity)
    FROM dbo.ORDER_DTL od
    JOIN dbo.INSTOCK_DECORATION decoration
        ON decoration.style_code_no_country = od.sku
        AND decoration.colorCode = od.colorCode
    JOIN dbo.ORDER_DESIGNS d
        ON d.id = decoration.designId
        AND d.variation = decoration.designVariation
        AND d.method NOT IN ('RRAA', 'RRAB')
    JOIN dbo.TreatmentMaster treatment
        ON treatment.TreatmentType = d.method
        AND treatment.vend_numb IS NOT NULL
    JOIN LineQuantities q
        ON q.lineId = od.id
    WHERE od.orderID = @orderId
    GROUP BY
        COALESCE(d.parentId, decoration.designId),
        d.method
)
SELECT
    designId,
    method,
    SUM(quantity) AS quantityNeeded
FROM DesignSources
GROUP BY
    designId,
    method
ORDER BY
    designId;