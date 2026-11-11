CREATE OR ALTER PROCEDURE dbo.RequestSampleQuote
    @id        VARCHAR(12),
    @variation VARCHAR(3),
    @user      VARCHAR(200),
    @physicalRequested BIT = 0,
    @testData BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @designId VARCHAR(12) = (
        SELECT ISNULL(parentId, id)
        FROM dbo.ORDER_DESIGNS
        WHERE id = @id AND variation = @variation
    );

    IF @designId IS NULL
        RETURN;

    -- The production file must exist (any variation, same as CheckOffShoreDesignOrder3)
    IF NOT EXISTS (SELECT 1 FROM dbo.ORDER_DESIGNS_FILES WHERE id = @designId AND fileType = 'prod')
        RETURN;

    IF NOT EXISTS (SELECT 1 FROM dbo.ORDER_DESIGNS WHERE id = @designId AND prodFilesApproved = 1)
        RETURN;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Claim the open art production request; only one caller wins
        DECLARE @claimed TABLE (id INT);

        UPDATE apr
        SET completedOn = SYSDATETIME(),
            completedBy = @user,
            [status]    = 1          -- completed
        OUTPUT INSERTED.id INTO @claimed
        FROM dbo.OFFSHORE_ART_PRODUCTION_REQUEST apr WITH (UPDLOCK, ROWLOCK)
        WHERE apr.designId = @designId
            AND apr.completedOn IS NULL
            AND apr.[status] <> 99;

        IF NOT EXISTS (SELECT 1 FROM @claimed)
        BEGIN
            COMMIT TRANSACTION;
            RETURN;
        END;

        -- Active demand row supplies vendor + aggregated quantity
        DECLARE @demandId INT, @vendor VARCHAR(5), @quantity INT, @orderType INT;

        SELECT TOP (1)
            @demandId = do.id,
            @vendor   = do.vendor,
            @quantity = do.quantity,
            @orderType = do.orderType
        FROM dbo.DESIGN_ORDERS do WITH (UPDLOCK)
        WHERE do.design = @designId
            AND do.[status] < 2
            AND do.po IS NULL
            AND (
                (@testData = 1 AND do.orderType = 4)
                OR (@testData = 0 AND do.orderType IN (1, 2, 3))
            )
        ORDER BY CASE do.orderType WHEN 1 THEN 0 WHEN 4 THEN 0 ELSE 1 END, do.id DESC;

        -- Customer orders behind the demand, for the same ORDER_TIMELINE posts CheckOffShoreDesignOrder3 makes
        DECLARE @customerOrders TABLE (orderId NVARCHAR(40) NOT NULL);

        INSERT INTO @customerOrders (orderId)
        SELECT DISTINCT dod.orderId
        FROM dbo.DESIGN_ORDER_DTL dod
        WHERE dod.id = @demandId;

        -- Requests created after Art Production completes still belong to the latest linked
        -- customer-order approval. Older pending rows without this JSON value fall back to System.
        DECLARE @approvalActor NVARCHAR(200) = (
            SELECT TOP (1)
                NULLIF(LTRIM(RTRIM(JSON_VALUE(pending.bodyJson, '$.approvedBy'))), '')
            FROM @customerOrders customerOrder
            JOIN dbo.OFFSHORE_ORDER_PENDING_SUBMISSION pending
                ON pending.orderId = customerOrder.orderId
            ORDER BY pending.createdAt DESC
        );

        SET @approvalActor = COALESCE(@approvalActor, 'System');

        INSERT INTO dbo.ORDER_TIMELINE (id, orderId, [date], [type], comment, [user])
        SELECT NEWID(), o.orderId, SYSDATETIME(), 2,
            CONCAT('The Art Production Request for design ', @designId, ' was completed by ', @user, '.'),
            @user
        FROM @customerOrders o;

        IF @demandId IS NOT NULL
            AND @vendor IS NOT NULL
            AND (
                @testData = 1
                OR EXISTS (
                SELECT 1 FROM dbo.OFFSHORE_DESIGN_VENDOR_USER vu
                WHERE vu.VEND_NUMB = @vendor AND vu.activeVendor = 1
                )
            )
        BEGIN
            -- ---------- Sample Request (conditional) ----------
            -- Upgrade a shared pending request instead of silently discarding an explicit physical
            -- selection. Approved requests remain historical and are not reopened. As with the
            -- Sample Request page's Request Physical Sample action, a request already ACCEPTED, SENT
            -- or RECEIVED returns to ACCEPTED so the vendor ships the physical sample; REQUESTED and
            -- REJECTED keep their status.
            DECLARE @physicalUpgraded TABLE (
                designId VARCHAR(12) NOT NULL,
                previousStatus VARCHAR(20) NULL,
                nextStatus VARCHAR(20) NULL
            );

            IF @physicalRequested = 1
            BEGIN
                UPDATE sampleRequest
                SET physical = 1
                OUTPUT
                    INSERTED.designId,
                    latestStatus.[status],
                    CASE
                        WHEN latestStatus.[status] IN ('ACCEPTED', 'SENT', 'RECEIVED') THEN 'ACCEPTED'
                        ELSE latestStatus.[status]
                    END
                INTO @physicalUpgraded (designId, previousStatus, nextStatus)
                FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sampleRequest
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
                WHERE sampleRequest.designId = @designId
                    AND sampleRequest.vendor = @vendor
                    AND sampleRequest.cancelledAt IS NULL
                    AND sampleRequest.approvedAt IS NULL
                    AND ISNULL(sampleRequest.physical, 0) = 0
                    AND ISNULL(latestStatus.[status], '') <> 'CANCELLED';

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
                        ' from vendor ', @vendor, ' by ', @approvalActor,
                        CASE
                            WHEN upgraded.previousStatus IN ('SENT', 'RECEIVED') THEN CONCAT(
                                CHAR(13), CHAR(10),
                                'Status moved back from ', upgraded.previousStatus,
                                ' to ACCEPTED because a physical sample was requested during Manager Approval.'
                            )
                            ELSE ''
                        END
                    )
                FROM @physicalUpgraded upgraded;

                INSERT INTO dbo.OFFSHORE_DESIGN_STATUS_TIMELINE (po, designId, quoteRequest, [status])
                SELECT NULL, upgraded.designId, 0, upgraded.nextStatus
                FROM @physicalUpgraded upgraded
                WHERE upgraded.nextStatus IS NOT NULL;
            END;

            -- The design's combined ORDER, IN_HOUSE and ORDER_BONUS demand for the vendor decides the
            -- threshold, with 10% added to ORDER and ORDER_BONUS. An explicit physical selection
            -- overrides the automatic quantity and purchase-history recommendation.
            IF (
                    @physicalRequested = 1
                    OR (
                        (
                            SELECT SUM(CASE
                                WHEN combinedDemand.orderType IN (2, 4) THEN combinedDemand.quantity
                                ELSE CEILING(combinedDemand.quantity * 1.10)
                            END)
                            FROM dbo.DESIGN_ORDERS combinedDemand
                            WHERE combinedDemand.design = @designId
                                AND COALESCE(combinedDemand.vendor, '') = COALESCE(@vendor, '')
                                AND combinedDemand.po IS NULL
                                AND combinedDemand.[status] < 2
                                AND (
                                    (@testData = 1 AND combinedDemand.orderType = 4)
                                    OR (@testData = 0 AND combinedDemand.orderType IN (1, 2, 3))
                                )
                        ) >= 101
                        AND NOT EXISTS (SELECT 1 FROM CRCDATA..PO11 WHERE ITEM_NUMB = @designId)
                    )
                )
                AND NOT EXISTS (
                    SELECT 1 FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sr WITH (UPDLOCK, SERIALIZABLE)
                    WHERE sr.designId = @designId AND sr.vendor = @vendor AND sr.cancelledAt IS NULL
                )
                AND EXISTS (
                    SELECT 1
                    FROM dbo.ORDER_DESIGNS 
                    WHERE id = @id 
                        AND variation = @variation
                        AND prodFilesApproved = 1
                )
            BEGIN
                INSERT INTO dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST (designId, createdBy, vendor, requiredBy, photo, physical, designOrdersId)
                VALUES (@designId, 'no-reply@levelwear.com', @vendor, DATEADD(WEEK, 2, SYSDATETIME()), 1, @physicalRequested, @demandId);

                INSERT INTO dbo.OFFSHORE_DESIGN_TIMELINE (po, designId, quoteRequest, createdBy, messageType, [message])
                VALUES (NULL, @designId, 0, @approvalActor, 'LW_USER',
                    CONCAT(
                        'Requested - Sample Request | ', @approvalActor,
                        CHAR(13), CHAR(10),
                        CASE WHEN @physicalRequested = 1 THEN 'Photo & Physical ' ELSE 'Photo ' END,
                        'sample requested for ', @designId, ' from vendor ', @vendor, ' by ', @approvalActor
                    ));

                INSERT INTO dbo.OFFSHORE_DESIGN_STATUS_TIMELINE (po, designId, quoteRequest, [status])
                VALUES (NULL, @designId, 0, 'REQUESTED');

                INSERT INTO dbo.ORDER_TIMELINE (id, orderId, [date], [type], comment, [user])
                SELECT NEWID(), o.orderId, SYSDATETIME(), 2,
                    CONCAT('A Sample Request was created for design ', @designId, ' for vendor ', @vendor, ' by ', @approvalActor, '.'),
                    'no-reply@levelwear.com'
                FROM @customerOrders o;
            END;

            -- ---------- Quote Request (always) ----------
            IF NOT EXISTS (
                SELECT 1 FROM dbo.OFFSHORE_DESIGN_QUOTE_REQUEST qr WITH (UPDLOCK, SERIALIZABLE)
                WHERE qr.designId = @designId AND qr.vendor = @vendor
                    AND ISNULL(qr.[status], 0) <> 99 -- a cancelled quote does not block a new one
            )
            BEGIN
                INSERT INTO dbo.OFFSHORE_DESIGN_QUOTE_REQUEST (vendor, designId, createdBy, designOrdersId)
                VALUES (@vendor, @designId, 'no-reply@levelwear.com', @demandId);

                INSERT INTO dbo.OFFSHORE_DESIGN_TIMELINE (po, designId, quoteRequest, createdBy, messageType, [message])
                VALUES (NULL, @designId, 1, @approvalActor, 'LW_USER',
                    CONCAT(
                        'Requested - Quote Request | ', @approvalActor,
                        CHAR(13), CHAR(10),
                        'Quote requested for ', @designId, ' from vendor ', @vendor, ' by ', @approvalActor
                    ));

                INSERT INTO dbo.OFFSHORE_DESIGN_STATUS_TIMELINE (po, designId, quoteRequest, [status])
                VALUES (NULL, @designId, 1, 'REQUESTED');

                INSERT INTO dbo.ORDER_TIMELINE (id, orderId, [date], [type], comment, [user])
                SELECT NEWID(), o.orderId, SYSDATETIME(), 2,
                    CONCAT('A Quote Request was created for design ', @designId, ' for vendor ', @vendor, ' by ', @approvalActor, '.'),
                    'no-reply@levelwear.com'
                FROM @customerOrders o;
            END;
        END;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
