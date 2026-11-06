/*
    Adds OFFSHORE_DESIGN_SAMPLE_REQUEST.byPassed.

    byPassed = 1 means Manager Approval skipped the Sample Request for rush work, so the vendor never
    produced a sample. CreateDesignPO3 does not add a sample fee line for these requests.

    Run order:
        1. This script (column + backfill).
        2. CheckOffShoreDesignOrder3.sql (sets byPassed on new rush bypasses).
        3. CreateDesignPO3.sql (filters byPassed = 1 out of sample charges).

    Step 2 below is a preview only. Review its output before running step 3.
*/

SET XACT_ABORT ON;

-- 1. Column ------------------------------------------------------------------------------------
IF COL_LENGTH('dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST', 'byPassed') IS NULL
BEGIN
    ALTER TABLE dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST
        ADD byPassed BIT NOT NULL
            CONSTRAINT DF_OFFSHORE_DESIGN_SAMPLE_REQUEST_bypassed DEFAULT (0);
END;
GO

-- 2. Preview existing rush bypasses ------------------------------------------------------------
-- A rush bypass writes this timeline message for the design. vendorStarted shows whether the
-- vendor had already ACCEPTED, SENT or RECEIVED the request before the bypass approved it; those
-- stay chargeable (byPassed = 0), matching CheckOffShoreDesignOrder3.
;WITH bypassMessage AS (
    SELECT
        t.designId,
        MIN(t.createdAt) AS bypassedAt
    FROM dbo.OFFSHORE_DESIGN_TIMELINE t
    WHERE t.quoteRequest = 0
        AND t.[message] LIKE '%without a physical sample because the design requires rush processing%'
    GROUP BY t.designId
)
SELECT
    sr.id,
    sr.designId,
    sr.vendor,
    sr.createdAt,
    sr.approvedAt,
    sr.physical,
    bm.bypassedAt,
    CASE WHEN EXISTS (
        SELECT 1
        FROM dbo.OFFSHORE_DESIGN_STATUS_TIMELINE st
        WHERE st.designId = sr.designId
            AND st.po IS NULL
            AND st.quoteRequest = 0
            AND st.createdAt >= sr.createdAt
            AND st.createdAt < bm.bypassedAt
            AND LTRIM(RTRIM(st.[status])) IN ('ACCEPTED', 'SENT', 'RECEIVED')
    ) THEN 1 ELSE 0 END AS vendorStarted,
    -- 1 = the design has no PO yet, so without the backfill its first PO would add a sample fee
    -- (when vendorStarted = 0). 0 = already on a PO; the repeat-order rule skips the charge anyway.
    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM CRCDATA.dbo.PO11 p11
        WHERE p11.ITEM_NUMB = sr.designId
    ) THEN 1 ELSE 0 END AS chargeAtRisk
FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sr
JOIN bypassMessage bm
    ON bm.designId = sr.designId
WHERE sr.cancelledAt IS NULL
    AND sr.approvedAt IS NOT NULL
    AND ISNULL(sr.physical, 0) = 0
    AND sr.createdAt <= bm.bypassedAt
    AND sr.byPassed = 0
ORDER BY chargeAtRisk DESC, sr.designId, sr.createdAt;
GO

-- 3. Backfill ----------------------------------------------------------------------------------
BEGIN TRY
    BEGIN TRANSACTION;

    ;WITH bypassMessage AS (
        SELECT
            t.designId,
            MIN(t.createdAt) AS bypassedAt
        FROM dbo.OFFSHORE_DESIGN_TIMELINE t
        WHERE t.quoteRequest = 0
            AND t.[message] LIKE '%without a physical sample because the design requires rush processing%'
        GROUP BY t.designId
    )
    UPDATE sr
    SET byPassed = 1
    FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sr
    JOIN bypassMessage bm
        ON bm.designId = sr.designId
    WHERE sr.cancelledAt IS NULL
        AND sr.approvedAt IS NOT NULL
        AND ISNULL(sr.physical, 0) = 0
        AND sr.createdAt <= bm.bypassedAt
        AND sr.byPassed = 0
        AND NOT EXISTS (
            SELECT 1
            FROM dbo.OFFSHORE_DESIGN_STATUS_TIMELINE st
            WHERE st.designId = sr.designId
                AND st.po IS NULL
                AND st.quoteRequest = 0
                AND st.createdAt >= sr.createdAt
                AND st.createdAt < bm.bypassedAt
                AND LTRIM(RTRIM(st.[status])) IN ('ACCEPTED', 'SENT', 'RECEIVED')
        );

    PRINT CONCAT(@@ROWCOUNT, ' sample request(s) marked bypassed.');

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO
