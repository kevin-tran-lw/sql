/*
    Manually add a Sample or Mold charge line to an existing Offshore PO, matching CreateDesignPO3.
    Run with @commit = 0 first to preview, then @commit = 1 to save.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @poNumb     CHAR(6)       = '044369';        -- existing PO number
DECLARE @designId   VARCHAR(12)   = 'CHEL10973001';  -- design the charge is for
DECLARE @chargeType VARCHAR(6)    = 'Sample';        -- 'Sample' or 'Mold'
DECLARE @cost       DECIMAL(10,3) = NULL;            -- NULL = use OFFSHORE_DESIGN_TREATMENT_CHARGES
DECLARE @commit     BIT           = 1;               -- 0 = preview and roll back, 1 = save

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @vendor VARCHAR(5), @dateRequired CHAR(8), @dateDue CHAR(8), @nextLine INT;

    SELECT @vendor = po10.VEND_NUMB, @dateRequired = po10.DATE_REQUIRED
    FROM CRCDATA.DBO.PO10 po10 WITH (UPDLOCK, HOLDLOCK)
    WHERE po10.PO_NUMB = @poNumb;

    IF @vendor IS NULL
        THROW 50001, 'PO was not found.', 1;

    IF @chargeType NOT IN ('Sample', 'Mold')
        THROW 50002, 'Charge type must be Sample or Mold.', 1;

    -- Default cost: the vendor's treatment charge for the design's method.
    IF @cost IS NULL
        SELECT TOP (1) @cost = tc.cost
        FROM dbo.ORDER_DESIGNS od
        JOIN dbo.OFFSHORE_DESIGN_TREATMENT_CHARGES tc
            ON tc.method = od.method
            AND tc.vendor = @vendor
            AND tc.mold = CASE WHEN @chargeType = 'Mold' THEN 1 ELSE 0 END
        WHERE od.id = @designId;

    IF @cost IS NULL OR @cost <= 0
        THROW 50003, 'No positive cost was given or found for this design, method and vendor.', 1;

    IF EXISTS (
        SELECT 1
        FROM CRCDATA.DBO.PO11
        WHERE PO_NUMB = @poNumb
            AND ITEM_NUMB = 'NS'
            AND PO_DESC = CONCAT(@chargeType, ' cost for ', @designId)
    )
        THROW 50004, 'This PO already has this charge line for the design.', 1;

    SELECT @nextLine = ISNULL(MAX(TRY_CAST(PO_LINE_NUMB AS INT)), 0) + 1
    FROM CRCDATA.DBO.PO11 WITH (UPDLOCK, HOLDLOCK)
    WHERE PO_NUMB = @poNumb;

    IF @nextLine > 999
        THROW 50005, 'A purchase order cannot contain more than 999 lines.', 1;

    -- Same due date as the design lines (required date + 7 days).
    SELECT TOP (1) @dateDue = DATE_DUE
    FROM CRCDATA.DBO.PO11
    WHERE PO_NUMB = @poNumb
        AND ITEM_NUMB <> 'NS'
    ORDER BY PO_LINE_NUMB;

    SET @dateDue = ISNULL(@dateDue,
        CONVERT(CHAR(8), DATEADD(DAY, 7, TRY_CONVERT(DATE, @dateRequired, 1)), 1));

    INSERT INTO CRCDATA.DBO.PO11 (
        [PO_NUMB], [PO_NUMB_SPARE1], [PO_LINE_NUMB], [PO_PROC_FLAG], [NON_STOCK_FLAG],
        [ITEM_NUMB], [PO_DESC], [ORIG_ORDER_QTY], [ORIG_UNIT_COST], [ORDER_QTY],
        [UNIT_PRICE], [STATUS_FLAG], [GROSS_LINE_DLR], [JC16_SEQ_NUMB], [AP_POST_CODE],
        [JOB_NUMB], [VEND_NUMB], [RDAT_ORDERED], [TAX_PCT], [DATE_DUE],
        [TAXABLE_FLAG], [COA_NUMB], [ORDER_UM], [CCNTR_NUMB], [CHARGE_CODE],
        [ORIG_PO_DLR], [PRICE_UM]
    )
    VALUES (
        @poNumb, '000', RIGHT('000' + CAST(@nextLine AS VARCHAR(3)), 3), '0', '*',
        'NS', CONCAT(@chargeType, ' cost for ', @designId), 1, @cost, 1,
        @cost, '', @cost, '100', '11',
        '', @vendor, CRCDATA.DBO.return_rdat(GETDATE()), '', @dateDue,
        '', '120120022350', 'EA', '940.10', '0',
        @cost, 'EA'
    );

    -- Keep the PO header total equal to its lines.
    UPDATE CRCDATA.DBO.PO10
    SET GROSS_PO_DLR = CAST(CAST(GROSS_PO_DLR AS DECIMAL(18,3)) + @cost AS VARCHAR(30))
    WHERE PO_NUMB = @poNumb;

    -- Preview
    SELECT PO_LINE_NUMB, ITEM_NUMB, PO_DESC, ORDER_QTY, UNIT_PRICE, GROSS_LINE_DLR, DATE_DUE
    FROM CRCDATA.DBO.PO11
    WHERE PO_NUMB = @poNumb
    ORDER BY PO_LINE_NUMB;

    SELECT PO_NUMB, VEND_NUMB, GROSS_PO_DLR
    FROM CRCDATA.DBO.PO10
    WHERE PO_NUMB = @poNumb;

    IF @commit = 1
        COMMIT TRANSACTION;
    ELSE
        ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
