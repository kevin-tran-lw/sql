CREATE OR ALTER PROCEDURE dbo.CheckOffShoreDesignOrder3
    @id NVARCHAR(40),
    @allocated dbo.design READONLY,
    @physicalSamples dbo.design READONLY,
    @orderIncludesOFT BIT = 0 OUTPUT,
    -- Order Bonus quantities from Manager's Approval. Applied only when @applyBonus = 1; other
    -- callers leave the order's existing bonus as it is.
    @bonus dbo.OffshoreBonusDesign READONLY,
    @applyBonus BIT = 0,
    -- New designs selected during Manager Approval to skip the vendor Sample Request for rush work.
    @bypassSample dbo.design READONLY,
    -- CSR who approved the order. Non-approval callers may omit this and are recorded as System.
    @approvedBy NVARCHAR(200) = NULL,
    -- Kevin-only application option for exercising the Offshore workflow without merging the
    -- generated demand into production ORDER, IN_HOUSE, or ORDER_BONUS demand. 
    -- THIS IS A TEST ONLY BIT FOR CREATING TEST DATA, DEFAULT 0 WILL RUN THE SP AS NORMAL
    @testData BIT = 0
AS
BEGIN
    /*
    	Author: Kevin Tran
        Created: 9/17/2026
        Purpose:
            Recalculates and synchronizes Offshore Design demand for a submitted customer order.

        Process:
            - Builds #offShoreSKUs through dbo.BuildOffShoreSKUs from explicit, catalog, and
            in-stock decoration sources, normalized to parent design IDs, excluding allocated
            drop-ship designs, with the appropriate active Offshore vendor for each design.
            - Updates existing active DESIGN_ORDERS quantities using only the difference
            between the newly calculated order quantity and the quantity previously recorded
            for this customer order.
            - Updates existing DESIGN_ORDER_DTL rows so each order continues to reflect
            its current contribution to the active Design Order.
            - Removes demand and detail rows for designs that were previously on the order but
            have since been removed.
            - Deletes active Design Order records whose total remaining demand reaches zero.
            - Creates new active Design Order and detail records for newly added designs.
            - Keeps this order's ORDER_BONUS (orderType 3) demand in line with the Order Bonus
            quantities when @applyBonus = 1, and always removes bonus for designs no longer on
            the order.
            - Creates required Sample Requests and Quote Requests when eligible, along with
            their associated timeline and status records.
            - Runs all persistent changes in a transaction so rerunning the procedure for the
            same customer order updates existing demand instead of double-counting it.
    */

    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @orderIncludesOFT = 0;

    DECLARE @approvalActor NVARCHAR(200) = COALESCE(NULLIF(LTRIM(RTRIM(@approvedBy)), ''), 'System');
    DECLARE @demandOrderType INT = CASE WHEN @testData = 1 THEN 4 ELSE 1 END;

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

        -- Builds the order's Offshore designs and suggested vendors (shared with the Order Bonus dialog).
        EXEC dbo.BuildOffShoreSKUs @id = @id, @allocated = @allocated;

        IF @testData = 1
            UPDATE #offShoreSKUs SET vendor = '00000';

       
        BEGIN TRANSACTION;
        /*
            The following actions are taken in order:

            1. Update quantities of existing active DESIGN_ORDERS records using the difference
               between the newly calculated quantity and this order's previously recorded quantity.
            2. Update existing DESIGN_ORDER_DTL rows to reflect this order's current quantity.
            3. Subtract demand for designs that have since been removed from this order.
            4. Delete DESIGN_ORDER_DTL rows for designs removed from this order.
            5. Delete active DESIGN_ORDERS records with no remaining demand.
            6. Insert missing active DESIGN_ORDERS records for newly added designs.
            7. Insert missing DESIGN_ORDER_DTL rows linking this order to its Design Orders.
            7a. Sync this order's ORDER_BONUS (orderType 3) demand and detail rows.
            8. Insert required Sample Requests and capture inserted rows.
            9. Insert Sample Request timeline/status records.
            10. Insert Art Production Requests for designs missing production files.
            11. Insert missing Quote Requests and capture inserted rows.
            12. Insert Quote Request timeline/status records.
        */

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
        JOIN DESIGN_ORDERS do
            ON a.id = do.design
        LEFT JOIN DESIGN_ORDER_DTL dod
            ON dod.id = do.id
            AND dod.orderId = @id
        WHERE do.orderType = @demandOrderType
            AND do.[status] < 2 -- Important, this is the condition that allows more quantity to be added to an 'ACTIVE' Offshore Design Order before a PO is cut  

        -- Updates the Order Detail record with the new quantity for design *if changed
        UPDATE dod
        SET dod.quantity = dod.quantity + a.quantityDifference
        FROM DESIGN_ORDER_DTL dod
        JOIN DESIGN_ORDERS do
            ON do.id = dod.id
        JOIN @adjusted a
            ON a.designId = do.design
        WHERE dod.orderId = @id
            AND do.[status] < 2
            AND do.orderType = @demandOrderType;

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
        FROM DESIGN_ORDERS do
        JOIN DESIGN_ORDER_DTL dod
            ON dod.id = do.id
        WHERE dod.orderId = @id
            AND do.[status] < 2
            AND do.orderType = @demandOrderType
            AND NOT EXISTS (
                SELECT 1
                FROM #offShoreSKUs sku
                WHERE sku.id = do.design
            )

        -- Removes Design Order Detail records if that design in its entirety has been removed from the order
        DELETE dod
        FROM DESIGN_ORDER_DTL dod
        JOIN DESIGN_ORDERS do
            ON do.id = dod.id
        WHERE dod.orderId = @id
            AND do.[status] < 2
            AND do.orderType = @demandOrderType
            AND NOT EXISTS (
                SELECT 1
                FROM #offShoreSKUs sku
                WHERE sku.id = do.design
            );
        
        -- Removes active Design Order records that no longer have any demand.
        DELETE FROM DESIGN_ORDERS
        WHERE [status] < 2
            AND orderType = @demandOrderType
            AND quantity <= 0;

        -- Adds a Design Order record if an 'active' record doesn't exist for that design.
        DECLARE @demandInserted TABLE (
            designId VARCHAR(12) NOT NULL,
            quantity INT NOT NULL
        );

        INSERT INTO DESIGN_ORDERS (
            design,
            vendor,
            createdOn,
            [status],
            quantity,
            createBy,
            orderType
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
            'no-reply@levelwear.com',
            @demandOrderType
        FROM #offShoreSKUs a
        WHERE NOT EXISTS (
            SELECT 1
            FROM DESIGN_ORDERS do WITH (UPDLOCK, SERIALIZABLE)
            WHERE do.design = a.id
                AND do.[status] < 2
                AND do.orderType = @demandOrderType
        )

        -- Adds new Order Detail records for a design tied to an order if it does not exist.
        INSERT INTO dbo.DESIGN_ORDER_DTL (
            id,
            orderId,
            quantity
        )
        SELECT
            do.id,
            @id,
            sku.quantity
        FROM #offShoreSKUs sku
        JOIN dbo.DESIGN_ORDERS do
            ON do.design = sku.id
            AND do.[status] < 2
            AND do.orderType = @demandOrderType
        WHERE NOT EXISTS (
            SELECT 1
            FROM DESIGN_ORDER_DTL dod
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

        -- ===================================== Order Bonus ========================================
        -- ORDER_BONUS (orderType 3) is extra stock a manager adds on top of this order's demand at
        -- Manager's Approval. Like ORDER demand, there is one active record per design, with one
        -- detail row per customer order holding that order's bonus share.

        DECLARE @bonusAdjusted TABLE (
            designId VARCHAR(12) NOT NULL,
            previousQuantity INT NOT NULL,
            newQuantity INT NOT NULL
        );

        -- Removes bonus for designs that are no longer on this order, whether or not a bonus was submitted.
        UPDATE do
        SET do.quantity = do.quantity - dod.quantity
        OUTPUT
            INSERTED.design,
            dod.quantity,
            0
        INTO @bonusAdjusted (
            designId,
            previousQuantity,
            newQuantity
        )
        FROM DESIGN_ORDERS do
        JOIN DESIGN_ORDER_DTL dod
            ON dod.id = do.id
        WHERE dod.orderId = @id
            AND do.[status] < 2
            AND do.orderType = 3
            AND @testData = 0
            AND NOT EXISTS (
                SELECT 1
                FROM #offShoreSKUs sku
                WHERE sku.id = do.design
            );

        DELETE dod
        FROM DESIGN_ORDER_DTL dod
        JOIN DESIGN_ORDERS do
            ON do.id = dod.id
        WHERE dod.orderId = @id
            AND do.[status] < 2
            AND do.orderType = 3
            AND @testData = 0
            AND NOT EXISTS (
                SELECT 1
                FROM #offShoreSKUs sku
                WHERE sku.id = do.design
            );

        IF @applyBonus = 1 AND @testData = 0
        BEGIN
            -- Every Offshore design on the order gets a target; designs left out of @bonus target 0.
            DECLARE @targetBonus TABLE (
                designId VARCHAR(12) NOT NULL PRIMARY KEY,
                vendor VARCHAR(5) NULL,
                quantity INT NOT NULL
            );

            INSERT INTO @targetBonus (
                designId,
                vendor,
                quantity
            )
            SELECT
                sku.id,
                sku.vendor,
                ISNULL(bonus.quantity, 0)
            FROM #offShoreSKUs sku
            LEFT JOIN @bonus bonus
                ON bonus.id = sku.id;

            -- Moves existing active bonus records by the change in this order's share.
            UPDATE do
            SET do.quantity = do.quantity + (target.quantity - ISNULL(dod.quantity, 0))
            OUTPUT
                INSERTED.design,
                ISNULL(dod.quantity, 0),
                target.quantity
            INTO @bonusAdjusted (
                designId,
                previousQuantity,
                newQuantity
            )
            FROM @targetBonus target
            JOIN DESIGN_ORDERS do
                ON do.design = target.designId
                AND do.[status] < 2
                AND do.orderType = 3
            LEFT JOIN DESIGN_ORDER_DTL dod
                ON dod.id = do.id
                AND dod.orderId = @id
            WHERE target.quantity <> ISNULL(dod.quantity, 0);

            UPDATE dod
            SET dod.quantity = target.quantity
            FROM DESIGN_ORDER_DTL dod
            JOIN DESIGN_ORDERS do
                ON do.id = dod.id
            JOIN @targetBonus target
                ON target.designId = do.design
            WHERE dod.orderId = @id
                AND do.[status] < 2
                AND do.orderType = 3
                AND target.quantity > 0;

            DELETE dod
            FROM DESIGN_ORDER_DTL dod
            JOIN DESIGN_ORDERS do
                ON do.id = dod.id
            JOIN @targetBonus target
                ON target.designId = do.design
            WHERE dod.orderId = @id
                AND do.[status] < 2
                AND do.orderType = 3
                AND target.quantity = 0;

            -- Adds an active bonus record for designs that have none yet.
            INSERT INTO DESIGN_ORDERS (
                design,
                vendor,
                createdOn,
                [status],
                quantity,
                createBy,
                orderType
            )
            OUTPUT
                INSERTED.design,
                0,
                INSERTED.quantity
            INTO @bonusAdjusted (
                designId,
                previousQuantity,
                newQuantity
            )
            SELECT
                target.designId,
                target.vendor,
                GETDATE(),
                1,
                target.quantity,
                'no-reply@levelwear.com',
                3
            FROM @targetBonus target
            WHERE target.quantity > 0
                AND NOT EXISTS (
                    SELECT 1
                    FROM DESIGN_ORDERS do WITH (UPDLOCK, SERIALIZABLE)
                    WHERE do.design = target.designId
                        AND do.[status] < 2
                        AND do.orderType = 3
                );

            INSERT INTO dbo.DESIGN_ORDER_DTL (
                id,
                orderId,
                quantity
            )
            SELECT
                do.id,
                @id,
                target.quantity
            FROM @targetBonus target
            JOIN dbo.DESIGN_ORDERS do
                ON do.design = target.designId
                AND do.[status] < 2
                AND do.orderType = 3
            WHERE target.quantity > 0
                AND NOT EXISTS (
                    SELECT 1
                    FROM DESIGN_ORDER_DTL dod
                    WHERE dod.id = do.id
                        AND dod.orderId = @id
                );
        END;

        -- Removes active bonus records with no remaining bonus, along with any zero detail rows left on them.
        DELETE dod
        FROM DESIGN_ORDER_DTL dod
        JOIN DESIGN_ORDERS do
            ON do.id = dod.id
        WHERE do.[status] < 2
            AND do.orderType = 3
            AND do.quantity <= 0
            AND @testData = 0;

        DELETE FROM DESIGN_ORDERS
        WHERE [status] < 2
            AND orderType = 3
            AND quantity <= 0
            AND @testData = 0;

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
            CASE
                WHEN a.previousQuantity = 0
                    THEN CONCAT('Order #', @orderNumb, ' added Offshore Order Bonus of quantity ', a.newQuantity, ' for design ', a.designId, '.')
                WHEN a.newQuantity = 0
                    THEN CONCAT('Order #', @orderNumb, ' removed Offshore Order Bonus of quantity ', a.previousQuantity, ' for design ', a.designId, '.')
                ELSE CONCAT('Order #', @orderNumb, ' adjusted Offshore Order Bonus for design ', a.designId, ' from ', a.previousQuantity, ' to ', a.newQuantity, '.')
            END,
            'no-reply@levelwear.com'
        FROM @bonusAdjusted a
        WHERE a.previousQuantity <> a.newQuantity;

        -- ===================================== Sample Requests ========================================

        -- A physical-sample selection upgrades a shared pending photo-only request for the same
        -- design/vendor. Approved requests remain historical and are not reopened. As with the
        -- Sample Request page's Request Physical Sample action, a request already ACCEPTED, SENT or
        -- RECEIVED returns to ACCEPTED so the vendor ships the physical sample; REQUESTED and
        -- REJECTED keep their status.
        DECLARE @samplePhysicalUpgraded TABLE (
            designId VARCHAR(12) NOT NULL,
            vendor VARCHAR(5) NOT NULL,
            previousStatus VARCHAR(20) NULL,
            nextStatus VARCHAR(20) NULL
        );

        UPDATE sampleRequest
        SET physical = 1
        OUTPUT
            INSERTED.designId,
            INSERTED.vendor,
            latestStatus.[status],
            CASE
                WHEN latestStatus.[status] IN ('ACCEPTED', 'SENT', 'RECEIVED') THEN 'ACCEPTED'
                ELSE latestStatus.[status]
            END
        INTO @samplePhysicalUpgraded (designId, vendor, previousStatus, nextStatus)
        FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sampleRequest
        JOIN @physicalSamples selected
            ON selected.id = sampleRequest.designId
        OUTER APPLY (
            SELECT TOP (1) newerRequest.createdAt
            FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST newerRequest
            WHERE newerRequest.designId = sampleRequest.designId
                AND (
                    newerRequest.createdAt > sampleRequest.createdAt
                    OR (
                        newerRequest.createdAt = sampleRequest.createdAt
                        AND newerRequest.id > sampleRequest.id
                    )
                )
            ORDER BY newerRequest.createdAt, newerRequest.id
        ) nextRequest
        OUTER APPLY (
            SELECT TOP (1) LTRIM(RTRIM(statusTimeline.[status])) AS [status]
            FROM dbo.OFFSHORE_DESIGN_STATUS_TIMELINE statusTimeline
            WHERE statusTimeline.designId = sampleRequest.designId
                AND statusTimeline.po IS NULL
                AND statusTimeline.quoteRequest = 0
                AND statusTimeline.createdAt >= sampleRequest.createdAt
                AND (
                    nextRequest.createdAt IS NULL
                    OR statusTimeline.createdAt < nextRequest.createdAt
                )
            ORDER BY statusTimeline.id DESC, statusTimeline.createdAt DESC
        ) latestStatus
        WHERE sampleRequest.cancelledAt IS NULL
            AND sampleRequest.approvedAt IS NULL
            AND ISNULL(sampleRequest.physical, 0) = 0
            AND ISNULL(latestStatus.[status], '') <> 'CANCELLED'
            AND EXISTS (
                SELECT 1
                FROM #offShoreSKUs sku
                JOIN dbo.DESIGN_ORDERS demand
                    ON demand.design = sku.id
                    AND demand.vendor = sampleRequest.vendor
                    AND demand.po IS NULL
                    AND demand.[status] < 2
                    AND demand.orderType = @demandOrderType
                WHERE sku.id = sampleRequest.designId
            );

        INSERT INTO dbo.OFFSHORE_DESIGN_TIMELINE (
            po, designId, quoteRequest, createdBy, messageType, [message]
        )
        SELECT
            NULL,
            upgraded.designId,
            0,
            @approvalActor,
            'LW_USER',
            CONCAT(
                CASE upgraded.nextStatus
                    WHEN 'REQUESTED' THEN 'Requested'
                    WHEN 'REJECTED' THEN 'Rejected'
                    WHEN 'ACCEPTED' THEN 'Accepted'
                    ELSE 'Updated'
                END,
                ' - Physical Sample | ', @approvalActor,
                CHAR(13), CHAR(10),
                'Physical sample added for ', upgraded.designId,
                ' from vendor ', upgraded.vendor, ' by ', @approvalActor,
                CASE
                    WHEN upgraded.previousStatus IN ('SENT', 'RECEIVED') THEN CONCAT(
                        CHAR(13), CHAR(10),
                        'Status moved back from ', upgraded.previousStatus,
                        ' to ACCEPTED because a physical sample was requested during Manager Approval.'
                    )
                    ELSE ''
                END
            )
        FROM @samplePhysicalUpgraded upgraded;

        INSERT INTO dbo.OFFSHORE_DESIGN_STATUS_TIMELINE (
            po, designId, quoteRequest, [status]
        )
        SELECT NULL, upgraded.designId, 0, upgraded.nextStatus
        FROM @samplePhysicalUpgraded upgraded
        WHERE upgraded.nextStatus IS NOT NULL;

        IF EXISTS (
            SELECT 1
            FROM @bypassSample selected
            WHERE NOT EXISTS (
                    SELECT 1 FROM #offShoreSKUs sku WHERE sku.id = selected.id
                )
                OR EXISTS (
                    SELECT 1
                    FROM CRCDATA.dbo.PO11 purchaseHistory
                    WHERE LTRIM(RTRIM(purchaseHistory.ITEM_NUMB)) = LTRIM(RTRIM(selected.id))
                )
        )
        BEGIN
            ;THROW 50004, 'A selected Sample Request bypass is no longer eligible.', 1;
        END;

        DECLARE @sampleBypassed TABLE (
            designId VARCHAR(12) NOT NULL,
            vendor VARCHAR(5) NOT NULL
        );

        -- If another order already opened the same design/vendor request, approve that request.
        -- The request is marked bypassed (no sample fee at PO creation) only when the vendor never
        -- started on it. If the request EVER reached ACCEPTED, SENT or RECEIVED in its lifecycle, sample
        -- work may already exist, so it stays chargeable even if a later issue moved it to REJECTED.
        -- This matches the backfill in TableModifications/AddSampleRequestBypassed.sql.
        UPDATE sampleRequest
        SET approvedAt = SYSDATETIME(),
            byPassed = CASE
                WHEN EXISTS (
                    SELECT 1
                    FROM dbo.OFFSHORE_DESIGN_STATUS_TIMELINE started
                    WHERE started.designId = sampleRequest.designId
                        AND started.po IS NULL
                        AND started.quoteRequest = 0
                        AND started.createdAt >= sampleRequest.createdAt
                        AND (
                            nextRequest.createdAt IS NULL
                            OR started.createdAt < nextRequest.createdAt
                        )
                        AND LTRIM(RTRIM(started.[status])) IN ('ACCEPTED', 'SENT', 'RECEIVED')
                ) THEN 0
                ELSE 1
            END
        OUTPUT INSERTED.designId, INSERTED.vendor
        INTO @sampleBypassed (designId, vendor)
        FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sampleRequest
        JOIN (SELECT DISTINCT id FROM @bypassSample) selected
            ON selected.id = sampleRequest.designId
        OUTER APPLY (
            SELECT TOP (1) newerRequest.createdAt
            FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST newerRequest
            WHERE newerRequest.designId = sampleRequest.designId
                AND (
                    newerRequest.createdAt > sampleRequest.createdAt
                    OR (
                        newerRequest.createdAt = sampleRequest.createdAt
                        AND newerRequest.id > sampleRequest.id
                    )
                )
            ORDER BY newerRequest.createdAt, newerRequest.id
        ) nextRequest
        WHERE sampleRequest.approvedAt IS NULL
            AND sampleRequest.cancelledAt IS NULL
            AND NOT EXISTS (
                SELECT 1
                FROM CRCDATA.dbo.PO11 purchaseHistory
                WHERE LTRIM(RTRIM(purchaseHistory.ITEM_NUMB)) = LTRIM(RTRIM(sampleRequest.designId))
            )
            AND EXISTS (
                SELECT 1
                FROM dbo.DESIGN_ORDERS demand
                WHERE demand.design = sampleRequest.designId
                    AND demand.vendor = sampleRequest.vendor
                    AND demand.po IS NULL
                    AND demand.[status] < 2
                    AND demand.orderType = @demandOrderType
            );

        -- Otherwise create the audit record already approved and marked bypassed. No request is
        -- exposed to the vendor and CreateDesignPO3 does not charge a sample fee for it.
        INSERT INTO dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST (
            designId,
            createdBy,
            vendor,
            requiredBy,
            photo,
            physical,
            approvedAt,
            byPassed,
            designOrdersId
        )
        OUTPUT INSERTED.designId, INSERTED.vendor
        INTO @sampleBypassed (designId, vendor)
        SELECT
            sku.id,
            'no-reply@levelwear.com',
            demand.vendor,
            SYSDATETIME(),
            1,
            0,
            SYSDATETIME(),
            1,
            demand.id
        FROM #offShoreSKUs sku
        JOIN (SELECT DISTINCT id FROM @bypassSample) selected
            ON selected.id = sku.id
        CROSS APPLY (
            SELECT TOP (1) activeDemand.id, activeDemand.vendor
            FROM dbo.DESIGN_ORDERS activeDemand
            WHERE activeDemand.design = sku.id
                AND activeDemand.po IS NULL
                AND activeDemand.[status] < 2
                AND activeDemand.orderType = @demandOrderType
                AND activeDemand.vendor IS NOT NULL
            ORDER BY activeDemand.id DESC
        ) demand
        WHERE (
                @testData = 1
                OR EXISTS (
                SELECT 1
                FROM dbo.OFFSHORE_DESIGN_VENDOR_USER vendorUser
                WHERE vendorUser.VEND_NUMB = demand.vendor
                    AND vendorUser.activeVendor = 1
                )
            )
            AND NOT EXISTS (
                SELECT 1
                FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST existingRequest
                    WITH (UPDLOCK, SERIALIZABLE)
                WHERE existingRequest.designId = sku.id
                    AND existingRequest.vendor = demand.vendor
                    AND existingRequest.cancelledAt IS NULL
            );

        IF EXISTS (
            SELECT 1
            FROM @bypassSample selected
            WHERE NOT EXISTS (
                SELECT 1 FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sampleRequest
                WHERE sampleRequest.designId = selected.id
                    AND sampleRequest.cancelledAt IS NULL
                    AND sampleRequest.approvedAt IS NOT NULL
            )
        )
        BEGIN
            ;THROW 50005, 'A selected Sample Request bypass could not be approved.', 1;
        END;

        INSERT INTO dbo.OFFSHORE_DESIGN_TIMELINE (
            po, designId, quoteRequest, createdBy, messageType, [message]
        )
        SELECT
            NULL,
            bypassed.designId,
            0,
            @approvalActor,
            'LW_USER',
            CONCAT(
                'Received - Sample Request | ', @approvalActor,
                CHAR(13), CHAR(10),
                @approvalActor, ' approved the Sample Request for ', bypassed.designId,
                ' without a physical sample because the design requires rush processing.'
            )
        FROM @sampleBypassed bypassed;

        INSERT INTO dbo.OFFSHORE_DESIGN_STATUS_TIMELINE (
            po, designId, quoteRequest, [status]
        )
        SELECT NULL, bypassed.designId, 0, 'RECEIVED'
        FROM @sampleBypassed bypassed;

        INSERT INTO dbo.ORDER_TIMELINE (id, orderId, [date], [type], comment, [user])
        SELECT
            NEWID(),
            @id,
            SYSDATETIME(),
            2,
            CONCAT(
                'The Sample Request for design ', bypassed.designId,
                ' was automatically approved without a physical sample for rush processing.'
            ),
            'no-reply@levelwear.com'
        FROM @sampleBypassed bypassed;
    
        DECLARE @sampleInserted TABLE (
            designId VARCHAR(12) NOT NULL,
            vendor VARCHAR(5) NOT NULL,
            physical BIT NOT NULL
        )

        INSERT INTO dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST (
            designId,
            createdBy,
            vendor,
            requiredBy,
            photo,
            physical,
            eta,
            etd,
            designOrdersId
        ) 
        OUTPUT 
            INSERTED.designId,
            INSERTED.vendor,
            INSERTED.physical
        INTO @sampleInserted (
            designId,
            vendor,
            physical
        )
        SELECT 
            a.id,
            'no-reply@levelwear.com',
            designOrder.vendor,
            DATEADD(WEEK, 2, SYSDATETIME()),
            1,
            CASE 
                WHEN EXISTS (
                    SELECT 1
                    FROM @physicalSamples ps
                    WHERE ps.id = a.id
                ) THEN 1 
                ELSE 0
            END,
            DATEADD(WEEK, 2, SYSDATETIME()),
            DATEADD(WEEk, 1, SYSDATETIME()),
            designOrder.id
        FROM #offShoreSKUs a
        JOIN dbo.DESIGN_ORDERS designOrder
            ON designOrder.design = a.id
            AND designOrder.[status] < 2
            AND designOrder.orderType = @demandOrderType
        -- Production mode combines ORDER, IN_HOUSE and ORDER_BONUS for the vendor. Test mode uses
        -- only isolated TEST demand. The 10% safety amount does not apply to IN_HOUSE or TEST.
        WHERE (
            EXISTS (
                SELECT 1
                FROM @physicalSamples selectedPhysical
                WHERE selectedPhysical.id = a.id
            )
            OR (
                (
                    SELECT SUM(CASE
                        WHEN combinedDemand.orderType IN (2, 4) THEN combinedDemand.quantity
                        ELSE CEILING(combinedDemand.quantity * 1.10)
                    END)
                    FROM dbo.DESIGN_ORDERS combinedDemand
                    WHERE combinedDemand.design = a.id
                        AND COALESCE(combinedDemand.vendor, '') = COALESCE(designOrder.vendor, '')
                        AND combinedDemand.po IS NULL
                        AND combinedDemand.[status] < 2
                        AND (
                            (@testData = 1 AND combinedDemand.orderType = 4)
                            OR (@testData = 0 AND combinedDemand.orderType IN (1, 2, 3))
                        )
                ) >= 101
                AND NOT EXISTS (
                    SELECT 1
                    FROM CRCDATA..PO11 po11
                    WHERE po11.ITEM_NUMB = a.id
                )
            )
        )
        AND NOT EXISTS (
            SELECT 1
            FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sr
                WITH (UPDLOCK, SERIALIZABLE)
            WHERE sr.designId = a.id
                AND sr.vendor = designOrder.vendor
                AND sr.cancelledAt IS NULL
        )
        AND (
            @testData = 1
            OR EXISTS (
            SELECT 1
            FROM dbo.OFFSHORE_DESIGN_VENDOR_USER vu
            WHERE vu.vend_numb = designOrder.vendor
                AND vu.activeVendor = 1
            )
        )
        AND EXISTS (
            SELECT 1
            FROM dbo.ORDER_DESIGNS_FILES productionFile
            WHERE productionFile.id = a.id
                AND productionFile.fileType = 'prod'
        )
        AND EXISTS (
            SELECT 1 
            FROM dbo.ORDER_DESIGNS od
            WHERE od.prodFilesApproved = 1
                AND od.id = a.id
        )
        AND designOrder.vendor IS NOT NULL
        AND designOrder.po IS NULL
        AND designOrder.[status] < 2;

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
            @approvalActor,
            'LW_USER',
            CONCAT(
                'Requested - Sample Request | ', @approvalActor,
                CHAR(13), CHAR(10),
                CASE
                    WHEN a.physical = 1 THEN 'Photo & Physical '
                    ELSE 'Photo '
                END,
                'sample requested for ', a.designId, ' from vendor ', a.vendor, ' by ', @approvalActor
            )
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
            CONCAT('A Sample Request was created for design ', a.designId, ' for vendor ', a.vendor, ' by ', @approvalActor, '.'),
            'no-reply@levelwear.com'
        FROM @sampleInserted a;

        -- ====== Art Production Request ======

        DECLARE @artInserted TABLE (
            designId VARCHAR(12) NOT NULL,
            id INT NOT NULL
        );

        INSERT INTO dbo.OFFSHORE_ART_PRODUCTION_REQUEST (
            designId,
            method
        )
        OUTPUT
            INSERTED.designId,
            INSERTED.id
        INTO @artInserted (
            designId,
            id
        )
        SELECT
            a.id,
            a.method
        FROM #offShoreSKUs a
        JOIN dbo.DESIGN_ORDERS do
            ON do.design = a.id
            AND do.[status] < 2
            AND do.orderType = @demandOrderType
        WHERE (
            NOT EXISTS (
                SELECT 1 
                FROM ORDER_DESIGNS_FILES odf
                WHERE odf.id = a.id 
                    AND odf.fileType = 'prod'
            )
            OR NOT EXISTS (
                SELECT 1
                FROM dbo.ORDER_DESIGNS od
                WHERE od.id = a.id
                    AND od.prodFilesApproved = 1
            )
        )
        AND NOT EXISTS (
            SELECT 1 
            FROM OFFSHORE_ART_PRODUCTION_REQUEST oapr WITH (UPDLOCK, SERIALIZABLE)
            WHERE oapr.designId = a.id
                AND oapr.completedOn IS NULL
                AND oapr.[status] <> 99
        )

        INSERT INTO dbo.OFFSHORE_ART_PRODUCTION_TIMELINE (
            requestId,
            messageType,
            [message]
        )
        SELECT
            a.id,
            'SYSTEM',
            CONCAT('An Art Production Request was created for design ', a.designId, ' by the System.')
        FROM @artInserted a;

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

        -- Keep every open Art Production Request in the correct work queue, including requests
        -- that existed before this execution and therefore are not present in @artInserted.
        -- Without a Production file, an unapproved request remains active work for an artist.
        UPDATE od
        SET od.prodFilesApproved = NULL
        FROM dbo.ORDER_DESIGNS od
        JOIN #offShoreSKUs a
            ON a.id = od.id
        WHERE od.prodFilesApproved IS NOT NULL
            AND NOT EXISTS (
                SELECT 1
                FROM dbo.ORDER_DESIGNS_FILES productionFile
                WHERE productionFile.id = od.id
                    AND productionFile.fileType = 'prod'
            );

        -- Once a Production file exists, an unapproved design moves to the manager's approval
        -- queue. Preserve prodFilesApproved = 1 so an already approved file is not reopened.
        UPDATE od
        SET od.prodFilesApproved = 0
        FROM dbo.ORDER_DESIGNS od
        JOIN #offShoreSKUs a
            ON a.id = od.id
        WHERE od.prodFilesApproved IS NULL
            AND EXISTS (
                SELECT 1
                FROM dbo.ORDER_DESIGNS_FILES productionFile
                WHERE productionFile.id = od.id
                    AND productionFile.fileType = 'prod'
            )
            AND EXISTS (
                SELECT 1
                FROM dbo.OFFSHORE_ART_PRODUCTION_REQUEST request
                WHERE request.designId = od.id
                    AND request.completedOn IS NULL
                    AND request.[status] <> 99
            );

        -- Heal an existing open request whose Production file was already approved. The approval bit
        -- is authoritative, so preserve it and complete the request even if its file record is missing.
        -- Restricting this to @artInserted would leave older open requests out of every manager view.
        UPDATE request
        SET request.[status] = 1,
            request.completedOn = SYSDATETIME(),
            request.completedBy = 'no-reply@levelwear.com'
        FROM dbo.OFFSHORE_ART_PRODUCTION_REQUEST request
        JOIN #offShoreSKUs sku
            ON sku.id = request.designId
        WHERE request.[status] = 0
            AND request.completedBy IS NULL
            AND request.completedOn IS NULL
            AND EXISTS (
                SELECT 1
                FROM dbo.ORDER_DESIGNS approvedDesign
                WHERE approvedDesign.id = request.designId
                    AND approvedDesign.prodFilesApproved = 1
            );
 
        -- ===================================== Quote Requests ========================================            

        DECLARE @quoteInserted TABLE (
            designId VARCHAR(12) NOT NULL,
            vendor VARCHAR(5) NOT NULL
        )

        INSERT INTO dbo.OFFSHORE_DESIGN_QUOTE_REQUEST (
            vendor,
            designId,
            createdBy,
            designOrdersId
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
            'no-reply@levelwear.com',
            designOrder.id
        FROM #offShoreSKUs a
        JOIN dbo.DESIGN_ORDERS designOrder
            ON designOrder.design = a.id
            AND designOrder.orderType = @demandOrderType
        WHERE NOT EXISTS (
            SELECT 1 
            FROM dbo.OFFSHORE_DESIGN_QUOTE_REQUEST qr 
                WITH (UPDLOCK, SERIALIZABLE)
            WHERE qr.designId = a.id
                AND qr.vendor = designOrder.vendor
        )   
        AND (
            @testData = 1
            OR EXISTS (
            SELECT 1
            FROM dbo.OFFSHORE_DESIGN_VENDOR_USER vu
            WHERE vu.vend_numb = designOrder.vendor
                AND vu.activeVendor = 1
            )
        )
        AND EXISTS (
            SELECT 1 
            FROM dbo.ORDER_DESIGNS_FILES odf 
            WHERE odf.id = a.id 
                AND odf.fileType = 'prod'
        )
        AND EXISTS (
            SELECT 1
            FROM dbo.ORDER_DESIGNS od
            WHERE od.id = a.id 
                AND od.prodFilesApproved = 1
        )
        AND designOrder.vendor IS NOT NULL
        AND designOrder.po IS NULL
        AND designOrder.[status] < 2;


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
            @approvalActor,
            'LW_USER',
            CONCAT(
                'Requested - Quote Request | ', @approvalActor,
                CHAR(13), CHAR(10),
                'Quote requested for ', a.designId, ' from vendor ', a.vendor, ' by ', @approvalActor
            )
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
            CONCAT('A Quote Request was created for design ', a.designId, ' for vendor ', a.vendor, ' by ', @approvalActor, '.'),
            'no-reply@levelwear.com'
        FROM @quoteInserted a;

        -- =================================================================================================
        
        COMMIT TRANSACTION;

        -- Report OFT only when this order actually has Offshore demand rows. Checking #offShoreSKUs
        -- alone could route an order to Awaiting OFT with no demand, so it could never become ready.
        IF EXISTS (
            SELECT 1
            FROM dbo.DESIGN_ORDER_DTL dod
            JOIN dbo.DESIGN_ORDERS do
                ON do.id = dod.id
            WHERE dod.orderId = @id
                AND do.[status] < 99
                AND do.orderType = @demandOrderType
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
