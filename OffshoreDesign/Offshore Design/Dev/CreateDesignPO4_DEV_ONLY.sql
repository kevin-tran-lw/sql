CREATE OR ALTER PROCEDURE [dbo].CreateDesignPO4
    @designPrices dbo.DesignPrice READONLY,
    @vendor VARCHAR(5),
    @dateRequired CHAR(8),
    @poNumb CHAR(6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ==========================================
    -- INPUT VALIDATIONS
    -- ==========================================

    IF NOT EXISTS (SELECT 1 FROM @designPrices)
        THROW 50001, 'At least one design price is required.', 1;

    IF (SELECT COUNT(*) FROM @designPrices) > 999
        THROW 50002, 'A purchase order cannot contain more than 999 design lines.', 1;

    IF EXISTS (
        SELECT 1
        FROM @designPrices
        WHERE NULLIF(LTRIM(RTRIM(designId)), '') IS NULL
            OR price <= 0
            OR quantity IS NULL
            OR quantity <= 0
    )
        THROW 50003, 'Every design requires a design ID, positive price, and positive quantity.', 1;

    IF EXISTS (
        SELECT designId
        FROM @designPrices
        GROUP BY designId
        HAVING COUNT(*) > 1
    )
        THROW 50004, 'A design cannot appear more than once on the same purchase order.', 1;

    IF @vendor IS NULL OR LEN(LTRIM(RTRIM(@vendor))) <> 5
        THROW 50005, 'Vendor must be exactly five characters.', 1;

    IF (
        SELECT COUNT(*)
        FROM CRCDATA.DBO.VN10
        WHERE VEND_NUMB = @vendor
    ) <> 1
        THROW 50006, 'Vendor was not found or is not unique.', 1;

    IF @dateRequired IS NULL OR ISDATE(@dateRequired) <> 1
        THROW 50007, 'Required date must be a valid MM/DD/YY date.', 1;

    /*
    -- PROD ONLY: Validate exchange rate

    IF (
        SELECT COUNT(*)
        FROM CRCDATA..Exchange_Rates
        WHERE CUR_CODE = 'USD'
    ) <> 1
        THROW 50008, 'A unique USD exchange rate is required.', 1;
    */

    BEGIN TRY

        -- ==========================================
        -- DEV: GENERATE PO NUMBER
        -- ==========================================

        DECLARE @nextPo INT;

        SELECT @nextPo =
            ISNULL(
                MAX(TRY_CONVERT(INT, po)),
                0
            ) + 5
        FROM dbo.OFFSHORE_DESIGN_ORDER_HDR;

        IF @nextPo NOT BETWEEN 1 AND 999999
            THROW 50010, 'The next PO number is invalid or exceeds six digits.', 1;

        SET @poNumb = RIGHT(
            '000000' + CONVERT(VARCHAR(6), @nextPo),
            6
        );

        /*
        -- ==========================================
        -- PROD ONLY: BEGIN TRANSACTION
        -- ==========================================

        BEGIN TRANSACTION;


        -- ==========================================
        -- PROD ONLY: VALIDATE PO POINTER
        -- ==========================================

        IF (
            SELECT COUNT(*)
            FROM CRCDATA..sy12 WITH (UPDLOCK, HOLDLOCK)
            WHERE PFILE_NAME = 'NXTPO'
        ) <> 1
            THROW 50009, 'A unique NXTPO pointer could not be found.', 1;


        -- ==========================================
        -- PROD ONLY: GENERATE PO NUMBER
        -- ==========================================

        DECLARE @nextPo INT;

        SELECT @nextPo =
            TRY_CONVERT(INT, POINTER_VALUE) + 1
        FROM CRCDATA..sy12 WITH (UPDLOCK, HOLDLOCK)
        WHERE PFILE_NAME = 'NXTPO';

        IF @nextPo IS NULL
            OR @nextPo NOT BETWEEN 1 AND 999999
            THROW 50010, 'The next PO number is invalid or exceeds six digits.', 1;

        SET @poNumb = RIGHT(
            '000000' + CONVERT(VARCHAR(6), @nextPo),
            6
        );


        -- ==========================================
        -- PROD ONLY: ADVANCE PO POINTER
        -- ==========================================

        UPDATE CRCDATA..SY12
        SET POINTER_VALUE = RIGHT(
            '00000000000000000000' + @poNumb,
            20
        )
        WHERE PFILE_NAME = 'NXTPO';


        -- ==========================================
        -- PROD ONLY: INSERT PO HEADER
        -- ==========================================

        INSERT INTO CRCDATA.DBO.PO10 (
            -- Original PO10 column list
        )
        SELECT
            -- Original PO10 values
        FROM CRCDATA.DBO.VN10 vn10
        WHERE @vendor = vn10.VEND_NUMB;


        -- ==========================================
        -- PROD ONLY: INSERT PO DETAILS
        -- ==========================================

        INSERT INTO CRCDATA.DBO.PO11 (
            -- Original PO11 column list
        )
        SELECT
            -- Original PO11 values
        FROM @designPrices dp;


        -- ==========================================
        -- PROD ONLY: COMMIT TRANSACTION
        -- ==========================================

        COMMIT TRANSACTION;

        */

        -- ==========================================
        -- DEV: RETURN GENERATED PO NUMBER
        -- ==========================================

        SELECT @poNumb AS poNumb;

    END TRY
    BEGIN CATCH

        -- PROD ONLY: Transaction rollback
        /*
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        */

        THROW;

    END CATCH;
END;