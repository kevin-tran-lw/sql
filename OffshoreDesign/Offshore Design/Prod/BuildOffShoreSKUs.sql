CREATE OR ALTER PROCEDURE dbo.BuildOffShoreSKUs
    @id NVARCHAR(40),
    @allocated dbo.design READONLY
AS
BEGIN
    /*
    	Author: Kevin Tran
        Purpose:
            Fills the caller's #offShoreSKUs with the Offshore designs on one customer order: the
            normalized (parent) design ID, treatment method, garment quantity, and suggested vendor.

            Shared by CheckOffShoreDesignOrder3, which turns these rows into Offshore demand, and the
            Manager's Approval Order Bonus dialog, which lists them before approval. The caller must
            create #offShoreSKUs (id, method, vendor, quantity) first.
    */

    SET NOCOUNT ON;

    IF OBJECT_ID(N'tempdb..#offShoreSKUs') IS NULL
    BEGIN
        ;THROW 50010, 'BuildOffShoreSKUs requires the caller to create #offShoreSKUs.', 1;
    END;

        -- Finds the explicit assigned offshore designs on one customer order, calculates how many garments use each design, and inserts into temp table.
        INSERT INTO #offShoreSKUs (
            id,
            quantity,
            method
        )
        SELECT
            ISNULL(d.parentId, c.designId),
            SUM(f.quantity),
            d.method
        FROM dbo.ORDER_DTL b
        JOIN dbo.ORDER_DTL_DECORATION c
            ON c.lineId = b.id
        JOIN dbo.ORDER_DESIGNS d
            ON d.id = c.designId
            AND d.variation = c.designVariation
            AND d.method NOT IN ('RRAA', 'RRAB')
        JOIN dbo.TreatmentMaster e
            ON e.TreatmentType = d.method
        JOIN dbo.ORDER_DTL_SIZE f
            ON f.lineId = b.id
        WHERE b.orderID = @id
            AND NOT EXISTS (
                SELECT 1
                FROM @allocated allocated
                WHERE allocated.id = c.designId
            )
            AND e.vend_numb IS NOT NULL
        GROUP BY
            ISNULL(d.parentId, c.designId),
            d.method

        /* 
            This adds quantities from catalog-defined decorations in CurrLicLongSkus_DECORATION to designs that already exist in #offShoreSKUs.
            It handles decorations inherited from the garment SKU and color, rather than decorations explicitly stored in ORDER_DTL_DECORATION.
        */
        UPDATE a SET quantity = a.quantity + b.qty
        FROM #offShoreSKUs a
        JOIN (
            SELECT DISTINCT 
                ISNULL(d.parentId, c.designID) id, 
                SUM(f.quantity) qty
            FROM ORDER_DTL b
            JOIN CurrLicLongSkus_DECORATION c 
                ON c.style_code_no_country = b.sku 
                AND c.colorCode = b.colorCode
            JOIN ORDER_DESIGNS d 
                ON d.id = c.designId
                AND d.variation = c.designVariation
                AND d.method NOT IN ('RRAA', 'RRAB')
            JOIN TreatmentMaster e
                ON e.TreatmentType = d.method
            JOIN ORDER_DTL_SIZE f
                ON f.lineId = b.id
            WHERE b.orderID = @id
                AND NOT EXISTS (
                    SELECT 1
                    FROM @allocated allocated
                    WHERE allocated.id = c.designId
                )
                AND e.vend_numb IS NOT NULL
            GROUP BY ISNULL(d.parentId, c.designId)
        ) b ON a.id = b.id;

        -- Insert each CurrLic-inherited design that is missing from #offShoreSKUs, using the total garment quantity associated with that design.
        INSERT INTO #offShoreSKUs(
            id, 
            quantity, 
            method
        )
        SELECT DISTINCT 
            ISNULL(d.parentId, c.designId), 
            SUM(f.quantity), 
            d.method
        FROM ORDER_DTL b
        JOIN CurrLicLongSkus_DECORATION c 
            ON c.style_code_no_country = b.sku
            AND c.colorCode = b.colorCode
        JOIN ORDER_DESIGNS d 
            ON d.id = c.designId
            AND d.variation = c.designVariation
            AND d.method NOT IN ('RRAA', 'RRAB')
        JOIN TreatmentMaster e
            ON e.TreatmentType = d.method
        JOIN ORDER_DTL_SIZE f
            ON f.lineId = b.id
        LEFT JOIN #offShoreSKUs g 
            ON g.id = ISNULL(d.parentId, c.designId)
        WHERE b.orderID = @id 
            AND g.id IS NULL 
            AND NOT EXISTS (
                SELECT 1
                FROM @allocated allocated
                WHERE allocated.id = c.designId
            )
            AND e.vend_numb IS NOT NULL
        GROUP BY 
            ISNULL(d.parentId, c.designId), 
            d.method
        
        -- Adds garment quantities from INSTOCK_DECORATION to matching designs already present in #offShoreSKUs.
        UPDATE a SET quantity = a.quantity + b.qty 
        FROM #offShoreSKUs a
        JOIN (
            SELECT DISTINCT 
                ISNULL(d.parentId, c.designId) id,
                SUM(f.quantity) qty
            FROM ORDER_DTL b
            JOIN INSTOCK_DECORATION c 
                ON c.style_code_no_country = b.sku
                AND c.colorCode = b.colorCode
            JOIN ORDER_DESIGNS d 
                ON d.id = c.designId
                AND d.variation = c.designVariation
                AND d.method NOT IN ('RRAA', 'RRAB')
            JOIN TreatmentMaster e
                ON e.TreatmentType = d.method
            JOIN ORDER_DTL_SIZE f
                ON f.lineId = b.id
            WHERE b.orderID = @id
                AND NOT EXISTS (
                    SELECT 1
                    FROM @allocated allocated
                    WHERE allocated.id = c.designId
                )
                AND e.vend_numb IS NOT NULL
            GROUP BY ISNULL(d.parentId, c.designId)
        ) b ON b.id = a.id;


        -- Adds designs from INSTOCK_DECORATION that are not already present in #offShoreSKUs, using their calculated garment quantities and treatment methods.
        INSERT INTO #offShoreSKUs(
            id, 
            quantity, 
            method
        )
        SELECT DISTINCT
            ISNULL(d.parentid, c.designId), 
            SUM(f.quantity),
            d.method
        FROM ORDER_DTL b
        JOIN INSTOCK_DECORATION c
            ON c.style_code_no_country = b.sku
            AND c.colorCode = b.colorCode
        JOIN ORDER_DESIGNS d 
            ON d.id = c.designId
            AND d.variation = c.designVariation
            AND d.method NOT IN ('RRAA', 'RRAB')
        JOIN TreatmentMaster e
            ON e.TreatmentType = d.method
        JOIN ORDER_DTL_SIZE f
            ON f.lineId = b.id
        LEFT JOIN #offShoreSKUs g
            ON g.id = ISNULL(d.parentId, c.designId)
        WHERE b.orderID = @id 
            AND g.id IS NULL 
            AND NOT EXISTS (
                SELECT 1
                FROM @allocated allocated
                WHERE allocated.id = c.designId
            )
            AND e.vend_numb IS NOT NULL
        GROUP BY 
            ISNULL(d.parentId, c.designId), 
            d.method

        -- Disabled: removing every drop-ship design here dropped designs the user left unticked in
        -- Allocate Designs, so they reached neither FG42 nor Offshore demand. Ticked designs are
        -- already excluded through @allocated above and allocated by CheckDropShipDecoOrder.
        -- DELETE a
        -- FROM #offShoreSKUs a
        -- WHERE EXISTS (
        --     SELECT 1
        --     FROM INVENTORYCHECK.dbo.dropshipstockdecos dropship
        --     WHERE LTRIM(RTRIM(dropship.designid))
        --         = LTRIM(RTRIM(a.id))
        -- );

        -- Throws error for when multiple records with the same designId
        -- exist in the #OffShore table to prevent later errors 
        -- that could arrise with inseretion into DESIGN_ORDERS, etc ...
        IF EXISTS (
            SELECT 1
            FROM #offShoreSKUs
            GROUP BY id
            HAVING COUNT(*) > 1
        )
        BEGIN
            ;THROW 50002,
                'Duplicate normalized design IDs found in #offShoreSKUs.',
                1;
        END

        
        -- Automatically selectes Vendor for a design if possible
        UPDATE sku
        SET sku.vendor = COALESCE(latestVendor.VEND_NUMB, fallbackVendor.VEND_NUMB)
        FROM #offShoreSKUs sku
        -- Prefer the vendor from the design's latest purchase order.
        OUTER APPLY (
            SELECT TOP (1)
                p11.VEND_NUMB
            FROM CRCDATA..PO11 p11
            JOIN CRCDATA..PO10 p10
                ON p10.PO_NUMB = p11.PO_NUMB
            JOIN dbo.OFFSHORE_DESIGN_VENDOR_USER vu
                ON vu.VEND_NUMB = p11.VEND_NUMB
                AND vu.activeVendor = 1
            WHERE p11.ITEM_NUMB = sku.id
            ORDER BY
                TRY_CONVERT(DATE, p10.DATE_ORDERED, 1) DESC,
                p10.PO_NUMB DESC,
                p11.VEND_NUMB ASC
        ) latestVendor
        -- Fall back to the treatment's configured vendor if no PO exists.
        OUTER APPLY (
            SELECT TOP (1)
                vu.VEND_NUMB
            FROM dbo.TreatmentMaster tm
            JOIN dbo.OFFSHORE_DESIGN_VENDOR_USER vu
                ON vu.VEND_NUMB = tm.VEND_NUMB
                AND vu.activeVendor = 1
            WHERE tm.TreatmentType = sku.method
            ORDER BY vu.VEND_NUMB ASC
        ) fallbackVendor;
END;
