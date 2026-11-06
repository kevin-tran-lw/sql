CREATE OR ALTER PROCEDURE dbo.CheckDropShipDecoOrder
    @id         NVARCHAR(40),
    @allocated  dbo.design READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @dropShipDecos TABLE(
            designId        VARCHAR(12)  NOT NULL,
            lineId          CHAR(40) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL,
            quantity        INT          NOT NULL,
            country         CHAR(1)      NOT NULL,
            allocCountry    CHAR(1)      NOT NULL,
            PRIMARY KEY (lineId, designId)
       );

        /*
            Find each ticked design once per order line, using the same design
            sources as the Manager's Approval Allocate Designs dialog
            (GetRequiredDesigns): a line's explicit decorations, otherwise the
            license catalog decorations for its style and color. Ticked IDs are
            the dialog's ORDER_DESIGNS IDs; allocations are made against the
            parent design, the item that holds the finished inventory.
            FG42 design allocations intentionally do not use style, color, or size.
        */
        ;WITH designCandidates AS (
            SELECT DISTINCT
                dtl.id AS lineId,
                CONVERT(VARCHAR(12), ISNULL(od.parentId, od.id)) AS designId,
                dtl.country
            FROM dbo.ORDER_DTL dtl
            LEFT JOIN dbo.ORDER_DTL_DECORATION odd
                ON odd.lineId = dtl.id
            LEFT JOIN dbo.CurrLicLongSkus_DECORATION catalogDeco
                ON catalogDeco.style_code_no_country = dtl.sku
                AND catalogDeco.colorCode = dtl.colorCode
            JOIN dbo.ORDER_DESIGNS od
                ON od.id = ISNULL(odd.designId, catalogDeco.designId)
                AND od.variation = ISNULL(odd.designVariation, catalogDeco.designVariation)
            WHERE dtl.orderID = @id
                AND od.method NOT IN ('RRAA', 'RRAB')
                AND EXISTS (
                    SELECT 1
                    FROM @allocated allocated
                    WHERE allocated.id = od.id
                )
        )
        INSERT INTO @dropShipDecos (
            designId,
            lineId,
            quantity,
            country,
            allocCountry
        )
        SELECT
            candidate.designId,
            candidate.lineId,
            SUM(sizeDtl.quantity),
            candidate.country,
            CASE
                WHEN SUM(ISNULL(sizeDtl.C, 0)) > 0 THEN 'C'
                WHEN SUM(ISNULL(sizeDtl.U, 0)) > 0 THEN 'U'
                ELSE candidate.country
            END
        FROM designCandidates candidate
        JOIN dbo.ORDER_DTL_SIZE sizeDtl
            ON sizeDtl.lineId = candidate.lineId
        GROUP BY
            candidate.designId,
            candidate.lineId,
            candidate.country
        HAVING SUM(sizeDtl.quantity) > 0;

        BEGIN TRANSACTION;

        /*
            Replace this order's design-allocation rows as one atomic set, so
            reruns and unticked designs never leave stale rows. Design rows have
            no style or size; garment allocations are left untouched.
        */
        DELETE fg42
        FROM CRCDATA..FG42_NewPending fg42
        JOIN dbo.ORDER_HDR hdr
            ON hdr.numb = fg42.orderNumb
        WHERE hdr.id = @id
            AND ISNULL(fg42.stylenum, '') = ''
            AND ISNULL(fg42.sizeAbbr, '') = ''
            AND EXISTS (
                SELECT 1
                FROM dbo.ORDER_DESIGNS od
                WHERE LTRIM(RTRIM(ISNULL(od.parentId, od.id))) = LTRIM(RTRIM(fg42.item_numb))
            );

        INSERT INTO CRCDATA..FG42_NewPending (
            orderNumb,
            lineid,
            item_numb,
            itemNumberNoCountry,
            allocQty,
            allocDate,
            dateWanted,
            stylenum,
            colorcode,
            sizeAbbr,
            country,
            allocCountry,
            po_numb
        )
        SELECT
            hdr.numb,
            currentDeco.lineId,
            currentDeco.designId,
            currentDeco.designId,
            currentDeco.quantity,
            SYSDATETIME(),
            hdr.date_required,
            '', -- fg42_newpending_history.stylenum is NOT NULL; spOrderSubmit archives these rows there.
            '',
            '',
            currentDeco.country,
            currentDeco.allocCountry,
            NULL
        FROM @dropShipDecos currentDeco
        JOIN dbo.ORDER_DTL dtl
            ON dtl.id = currentDeco.lineId
        JOIN dbo.ORDER_HDR hdr
            ON hdr.id = dtl.orderID
        WHERE hdr.id = @id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
