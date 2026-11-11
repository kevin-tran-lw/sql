USE CRCDATA;
GO

CREATE TRIGGER dbo.trg_PO10_UpdateOffshoreTimeline
ON dbo.PO10
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(DATE_RCVD)
    BEGIN
        INSERT INTO StyleMaster.dbo.OFFSHORE_DESIGN_STATUS_TIMELINE (
            po,
            designId,
            quoteRequest,
            [status]
        )
        SELECT
            p10.PO_NUMB,
            p11.ITEM_NUMB,
            NULL,
            'RECEIVED'
        FROM inserted p10
        JOIN CRCDATA.DBO.PO11 p11
            ON p10.PO_NUMB = p11.PO_NUMB
        WHERE (
            SELECT TOP 1
                tl.[status]
            FROM StyleMaster.dbo.OFFSHORE_DESIGN_STATUS_TIMELINE tl
            WHERE tl.po = p10.PO_NUMB
                AND tl.designId = p11.ITEM_NUMB
                AND quoteRequest IS NULL
            ORDER BY tl.id DESC, tl.createdAt DESC
        ) <> 'CANCELLED'

        INSERT INTO Stylemaster.dbo.OFFSHORE_DESIGN_STATUS_TIMELINE (
            po,
            designId,
            quoteRequest,
            [status]
        ) 
        SELECT
            p10.PO_NUMB,
            NULL,
            NULL,
            'RECEIVED'
        FROM inserted p10
        WHERE (
            SELECT
                tl.[status]
            FROM StyleMaster.dbo.OFFSHORE_DESIGN_STATUS_TIMELINE tl
            JOIN CRCDATA.DBO.PO11 p11
                ON p11.ITEM_NUMB = tl.designId
            WHERE tl.po = p10.PO_NUMB
                AND quoteRequest IS NULL
            ORDER BY tl.id DESC, tl.createdAt DESC
        ) IN ('CANCELLED', 'RECEIVED')
    END
END;
GO