CREATE OR ALTER PROCEDURE dbo.CheckOffShoreDesignOrder3
    @id NVARCHAR(40),
    @allocated dbo.design READONLY,
    @orderIncludesOFT BIT = 0 OUTPUT
AS
BEGIN
    /*
    	Author: Kevin Tran
        Created: 9/17/2026
        Purpose:
            Recalculates and synchronizes Offshore Design demand for a submitted customer order.

        Process:
            - Builds #offShoreSKUs from explicit, catalog, and in-stock decoration sources.
            - Normalizes designs to parent design IDs and excludes allocated/drop-ship designs.
            - Determines the appropriate active Offshore vendor for each design.
            - Updates existing active DESIGN_ORDERS_DUMMY quantities using only the difference
            between the newly calculated order quantity and the quantity previously recorded
            for this customer order.
            - Updates existing DESIGN_ORDER_DTL_DUMMY rows so each order continues to reflect
            its current contribution to the active Design Order.
            - Removes demand and detail rows for designs that were previously on the order but
            have since been removed.
            - Deletes active Design Order records whose total remaining demand reaches zero.
            - Creates new active Design Order and detail records for newly added designs.
            - Creates required Sample Requests and Quote Requests when eligible, along with
            their associated timeline and status records.
            - Runs all persistent changes in a transaction so rerunning the procedure for the
            same customer order updates existing demand instead of double-counting it.
    */

    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @orderIncludesOFT = 0;

    BEGIN TRY

        DECLARE @orderNumb NVARCHAR(80) = (
            SELECT numb
            FROM ORDER_HDR
            WHERE id = @id
        );

        -- Drops table if it exists and creates it
        IF OBJECT_ID(N'tempdb..#offShoreSKUs') IS NOT NULL
            DROP TABLE #offShoreSKUs;
    
        CREATE TABLE #offShoreSKUs (
            id          VARCHAR(12)     NOT NULL,
            method      VARCHAR(4)      NOT NULL,
            vendor      VARCHAR(5),
            quantity    INT             NOT NULL
        );

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
        -- that could arrise with inseretion into DESIGN_ORDERS_DUMMY, etc ...
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

       
        BEGIN TRANSACTION;
        /*
            The following actions are taken in order:

            1. Update quantities of existing active DESIGN_ORDERS_DUMMY records using the difference
               between the newly calculated quantity and this order's previously recorded quantity.
            2. Update existing DESIGN_ORDER_DTL_DUMMY rows to reflect this order's current quantity.
            3. Subtract demand for designs that have since been removed from this order.
            4. Delete DESIGN_ORDER_DTL_DUMMY rows for designs removed from this order.
            5. Delete active DESIGN_ORDERS_DUMMY records with no remaining demand.
            6. Insert missing active DESIGN_ORDERS_DUMMY records for newly added designs.
            7. Insert missing DESIGN_ORDER_DTL_DUMMY rows linking this order to its Design Orders.
            8. Insert required Sample Requests and capture inserted rows.
            9. Insert Sample Request timeline/status records.
            10. Insert Art Production Requests for designs missing production or working files.
            11. Insert missing Quote Requests and capture inserted rows.
            12. Insert Quote Request timeline/status records.
        */

        -- This Update on DESIGN_ORDERS_DUMMY is important for adding the new quantity of a design to an existing 'active' Offshore Design record. 
        -- If table is set up correctly, there should only be one 'active' record that has its quantity updated.
        -- PENDING REMOVAL
        -- UPDATE do
        -- SET do.quantity = do.quantity + a.quantity
        -- FROM #offShoreSKUs a
        -- JOIN DESIGN_ORDERS_DUMMY do
        --     ON a.id = do.design
        --     AND do.[status] < 2 -- Important, this is the condition that allows more quantity to be added to an 'ACTIVE' Offshore Design Order before a PO is cut  
        -- ^ ^ ^ ^  ^

        DECLARE @adjusted Table (
            designId VARCHAR(12),
            quantityDifference INT,
            previousQuantity INT,
            newQuantity INT
        )

        UPDATE do
        SET do.quantity =
            do.quantity + (a.quantity - ISNULL(dod.quantity, 0))
        OUTPUT
            INSERTED.design,
            a.quantity - ISNULL(dod.quantity, 0),
            ISNULL(dod.quantity, 0),
            a.quantity
        INTO @adjusted (
            designId,
            quantityDifference,
            previousQuantity,
            newQuantity
        )
        FROM #offShoreSKUs a
        JOIN DESIGN_ORDERS_DUMMY do
            ON a.id = do.design
            AND do.[status] < 2 -- Important, this is the condition that allows more quantity to be added to an 'ACTIVE' Offshore Design Order before a PO is cut  
        LEFT JOIN DESIGN_ORDER_DTL_DUMMY dod
            ON dod.id = do.id
            AND dod.orderId = @id;

        -- Updates the Order Detail record with the new quantity for design *if changed
        UPDATE dod
        SET dod.quantity = dod.quantity + a.quantityDifference
        FROM DESIGN_ORDER_DTL_DUMMY dod
        JOIN DESIGN_ORDERS_DUMMY do
            ON do.id = dod.id
        JOIN @adjusted a
            ON a.designId = do.design
        WHERE dod.orderId = @id
            AND do.[status] < 2;

        INSERT INTO dbo.ORDER_TIMELINE (
            id, 
            orderId,
            [date],
            [type],
            comment,
            [user]
        ) 
        SELECT 
            NEWID(),
            @id,
            SYSDATETIME(),
            2,
            CONCAT('Order #', @orderNumb, ' adjusted Offshore demand quantity for design ', a.designId, ' from ', a.previousQuantity, ' to ', a.newQuantity, '.'),
            'no-reply@levelwear.com'
        FROM @adjusted a
        WHERE a.previousQuantity <> a.newQuantity;

        -- Updates the Design Order quantity to remove any Designs that have since been removed entirely from an order.
        UPDATE do
        SET do.quantity = do.quantity - dod.quantity
        FROM DESIGN_ORDERS_DUMMY do
        JOIN DESIGN_ORDER_DTL_DUMMY dod
            ON dod.id = do.id
        WHERE dod.orderId = @id
            AND do.[status] < 2
            AND NOT EXISTS (
                SELECT 1
                FROM #offShoreSKUs sku
                WHERE sku.id = do.design
            )

        -- Removes Design Order Detail records if that design in its entirety has been removed from the order
        DELETE dod
        FROM DESIGN_ORDER_DTL_DUMMY dod
        JOIN DESIGN_ORDERS_DUMMY do
            ON do.id = dod.id
        WHERE dod.orderId = @id
            AND do.[status] < 2
            AND NOT EXISTS (
                SELECT 1
                FROM #offShoreSKUs sku
                WHERE sku.id = do.design
            );
        
        -- Removes active Design Order records that no longer have any demand.
        DELETE FROM DESIGN_ORDERS_DUMMY
        WHERE [status] < 2
            AND quantity <= 0;

        -- Adds a Design Order record if an 'active' record doesn't exist for that design.
        DECLARE @demandInserted TABLE (
            designId VARCHAR(12) NOT NULL,
            quantity INT NOT NULL
        );

        INSERT INTO DESIGN_ORDERS_DUMMY (
            design,
            vendor,
            createdOn,
            [status],
            quantity,
            createBy
        )
        OUTPUT
            INSERTED.design,
            INSERTED.quantity
        INTO @demandInserted (
            designId,
            quantity
        )
        SELECT 
            a.id,
            a.vendor,
            GETDATE(),
            1,
            a.quantity,
            'no-reply@levelwear.com'
        FROM #offShoreSKUs a
        WHERE NOT EXISTS (
            SELECT 1
            FROM DESIGN_ORDERS_DUMMY do WITH (UPDLOCK, SERIALIZABLE)
            WHERE do.design = a.id
                AND do.[status] < 2
        )

        -- Adds new Order Detail records for a design tied to an order if it does not exist.
        INSERT INTO dbo.DESIGN_ORDER_DTL_DUMMY (
            id,
            orderId,
            quantity
        )
        SELECT
            do.id,
            @id,
            sku.quantity
        FROM #offShoreSKUs sku
        JOIN dbo.DESIGN_ORDERS_DUMMY do
            ON do.design = sku.id
            AND do.[status] < 2
        WHERE NOT EXISTS (
            SELECT 1
            FROM DESIGN_ORDER_DTL_DUMMY dod
            WHERE dod.id = do.id
                AND dod.orderId = @id
        );

        INSERT INTO dbo.ORDER_TIMELINE (
            id, 
            orderId,
            [date],
            [type],
            comment,
            [user]
        ) 
        SELECT 
            NEWID(),
            @id,
            SYSDATETIME(),
            2,
            CONCAT('Order #', @orderNumb, ' created Offshore demand of quantity ', a.quantity, ' for design ', a.designId, '.'),
            'no-reply@levelwear.com'
        FROM @demandInserted a;

        -- ===================================== Sample Requests ========================================
    
        DECLARE @sampleInserted TABLE (
            designId VARCHAR(12) NOT NULL,
            vendor VARCHAR(5) NOT NULL
        )

        INSERT INTO dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST (
            designId,
            createdBy,
            vendor,
            requiredBy,
            photo,
            physical
        ) 
        OUTPUT 
            INSERTED.designId,
            INSERTED.vendor
        INTO @sampleInserted (
            designId,
            vendor
        )
        SELECT 
            a.id,
            'no-reply@levelwear.com',
            designOrder.vendor,
            DATEADD(WEEK, 1, SYSDATETIME()),
            1,
            0
        FROM #offShoreSKUs a
        JOIN dbo.DESIGN_ORDERS_DUMMY designOrder
            ON designOrder.design = a.id
            AND designOrder.[status] < 2
        WHERE CEILING(designOrder.quantity*1.10) >= 101 -- 10% is added to account for safety amount. 
        AND NOT EXISTS (
            SELECT 1
            FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sr
                WITH (UPDLOCK, SERIALIZABLE)
            WHERE sr.designId = a.id
                AND sr.vendor = designOrder.vendor
                AND sr.cancelledAt IS NULL
        )
        AND NOT EXISTS (
            SELECT 1
            FROM CRCDATA..PO11 po11
            WHERE po11.ITEM_NUMB = a.id
        )
        AND EXISTS (
            SELECT 1
            FROM dbo.OFFSHORE_DESIGN_VENDOR_USER vu
            WHERE vu.vend_numb = designOrder.vendor
                AND vu.activeVendor = 1
        )
        AND EXISTS (
            SELECT 1
            FROM dbo.ORDER_DESIGNS_FILES productionFile
            WHERE productionFile.id = a.id
                AND productionFile.fileType = 'prod'
        )
        AND EXISTS (
            SELECT 1
            FROM dbo.ORDER_DESIGNS_FILES workingFile
            WHERE workingFile.id = a.id
                AND workingFile.fileType = 'working'
        )
        AND designOrder.vendor IS NOT NULL;

        INSERT INTO dbo.OFFSHORE_DESIGN_TIMELINE (
            po,
            designId,
            quoteRequest,
            createdBy,
            messageType,
            [message]
        ) 
        SELECT
            NULL,
            a.designId,
            0,
            'no-reply@levelwear.com',
            'SYSTEM',
            'Requested - Sample Request | System' + CHAR(13) + CHAR(10) + 'Sample requested for ' + a.designId + ' from vendor ' + a.vendor
        FROM @sampleInserted a

        INSERT INTO dbo.OFFSHORE_DESIGN_STATUS_TIMELINE (
            po,
            designId,
            quoteRequest,
            [status]
        ) 
        SELECT 
            NULL,
            a.designId,
            0,
            'REQUESTED'
        FROM @sampleInserted a

        INSERT INTO dbo.ORDER_TIMELINE (
            id, 
            orderId,
            [date],
            [type],
            comment,
            [user]
        ) 
        SELECT 
            NEWID(),
            @id,
            SYSDATETIME(),
            2,
            CONCAT('A Sample Request was created for design ', a.designId, ' for vendor ', a.vendor, ' by the System.'),
            'no-reply@levelwear.com'
        FROM @sampleInserted a;


        -- Maybe we want a more dynamic way of calculating rather then hard coding sammpleRequired when a production request is created
        -- Ie. Calculate if sampleRequired is needed when production files are created to account for potential changes in quantity of the design
        -- but this asks the question that if we are in this current stage of 5-3, should an order be allowed to be changed any more?

        DECLARE @artInserted TABLE (
            designId VARCHAR(12) NOT NULL
        );

        INSERT INTO dbo.OFFSHORE_ART_PRODUCTION_REQUEST (
            designId,
            method,
            sampleRequired
        )
        OUTPUT
            INSERTED.designId
        INTO @artInserted (
            designId
        )
        SELECT
            a.id,
            a.method,
            CASE WHEN CEILING(dod.quantity * 1.10) >= 101
                AND NOT EXISTS (SELECT 1 FROM CRCDATA..PO11 po11 WHERE po11.ITEM_NUMB = a.id)
                THEN 1 ELSE 0 END 
        FROM #offShoreSKUs a
        JOIN dbo.DESIGN_ORDERS_DUMMY dod
            ON dod.design = a.id
            AND dod.[status] < 2
        WHERE (
                NOT EXISTS (SELECT 1 FROM dbo.ORDER_DESIGNS_FILES odf WHERE odf.id = a.id AND odf.fileType = 'prod')
                OR NOT EXISTS (SELECT 1 FROM dbo.ORDER_DESIGNS_FILES odf WHERE odf.id = a.id AND odf.fileType = 'working')
            )
            AND NOT EXISTS (
                SELECT 1
                FROM dbo.OFFSHORE_ART_PRODUCTION_REQUEST oapr WITH (UPDLOCK, SERIALIZABLE)
                WHERE oapr.designId = a.id
                    AND oapr.[status] <> 99
            );

        INSERT INTO dbo.ORDER_TIMELINE (
            id, 
            orderId,
            [date],
            [type],
            comment,
            [user]
        ) 
        SELECT 
            NEWID(),
            @id,
            SYSDATETIME(),
            2,
            CONCAT('An Art Production Request was created for design ', a.designId, ' by the System.'),
            'no-reply@levelwear.com'
        FROM @artInserted a;

        -- ===================================== Quote Requests ========================================            

        DECLARE @quoteInserted TABLE (
            designId VARCHAR(12) NOT NULL,
            vendor VARCHAR(5) NOT NULL
        )

        INSERT INTO dbo.OFFSHORE_DESIGN_QUOTE_REQUEST (
            vendor,
            designId,
            createdBy
        ) 
        OUTPUT 
            INSERTED.designId,
            INSERTED.vendor
        INTO @quoteInserted (
            designId,
            vendor
        )
        SELECT 
            designOrder.vendor,
            a.id,
            'no-reply@levelwear.com'
        FROM #offShoreSKUs a
        JOIN dbo.DESIGN_ORDERS_DUMMY designOrder
            ON designOrder.design = a.id
            AND designOrder.[status] < 2
        WHERE NOT EXISTS (
            SELECT 1 
            FROM dbo.OFFSHORE_DESIGN_QUOTE_REQUEST qr 
                WITH (UPDLOCK, SERIALIZABLE)
            WHERE qr.designId = a.id
                AND qr.vendor = designOrder.vendor
        )   
        AND EXISTS (
            SELECT 1
            FROM dbo.OFFSHORE_DESIGN_VENDOR_USER vu
            WHERE vu.vend_numb = designOrder.vendor
                AND vu.activeVendor = 1
        )
        AND EXISTS (
            SELECT 1 
            FROM dbo.ORDER_DESIGNS_FILES odf 
            WHERE odf.id = a.id 
                AND odf.fileType = 'prod'
        )
        AND EXISTS (
            SELECT 1 
            FROM dbo.ORDER_DESIGNS_FILES odf 
            WHERE odf.id = a.id 
            AND odf.fileType = 'working'
        )
        AND designOrder.vendor IS NOT NULL;

        INSERT INTO dbo.OFFSHORE_DESIGN_TIMELINE (
            po,
            designId,
            quoteRequest,
            createdBy,
            messageType,
            [message]
        )        
        SELECT 
            NULL,
            a.designId,
            1,
            'no-reply@levelwear.com',
            'SYSTEM',
            'Requested - Quote Request | System' + CHAR(13) + CHAR(10) + 'Quote requested for ' + a.designId + ' from vendor ' + a.vendor
        FROM @quoteInserted A

        INSERT INTO dbo.OFFSHORE_DESIGN_STATUS_TIMELINE (
            po,
            designId,
            quoteRequest,
            [status]
        )
        SELECT 
            NULL,
            a.designId,
            1,
            'REQUESTED'
        FROM @quoteInserted a

        INSERT INTO dbo.ORDER_TIMELINE (
            id, 
            orderId,
            [date],
            [type],
            comment,
            [user]
        ) 
        SELECT 
            NEWID(),
            @id,
            SYSDATETIME(),
            2,
            CONCAT('A Quote Request was created for design ', a.designId, ' for vendor ', a.vendor, ' by the System.'),
            'no-reply@levelwear.com'
        FROM @quoteInserted a;

        -- =================================================================================================
        
        COMMIT TRANSACTION;

        -- Report OFT only when this order actually has Offshore demand rows. Checking #offShoreSKUs
        -- alone could route an order to Awaiting OFT with no demand, so it could never become ready.
        IF EXISTS (
            SELECT 1
            FROM dbo.DESIGN_ORDER_DTL_DUMMY dod
            JOIN dbo.DESIGN_ORDERS_DUMMY do
                ON do.id = dod.id
            WHERE dod.orderId = @id
                AND do.[status] < 99
        )
        BEGIN
            SET @orderIncludesOFT = 1;
        END;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
