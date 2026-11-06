CREATE OR ALTER PROCEDURE [dbo].CreateDesignPO3
    @designPrices dbo.DesignPrice READONLY,
    @vendor VARCHAR(5),
    @dateRequired CHAR(8),
    @poNumb CHAR(6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @parsedDateRequired DATE = TRY_CONVERT(DATE, @dateRequired, 1);
    
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

    IF @parsedDateRequired IS NULL
        THROW 50007, 'Required date must be a valid MM/DD/YY date.', 1;

    IF (
        SELECT COUNT(*)
        FROM CRCDATA..Exchange_Rates
        WHERE CUR_CODE = 'USD'
    ) <> 1
        THROW 50008, 'A unique USD exchange rate is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

    IF (
        SELECT COUNT(*)
        FROM CRCDATA..sy12 WITH(UPDLOCK, HOLDLOCK)
        WHERE PFILE_NAME = 'NXTPO'
    ) <> 1
        THROW 50009, 'A unique NXTPO pointer could not be found.', 1;

    DECLARE @nextPo INT;

    -- Get PO Numb
    SELECT @nextPo = CONVERT(INT, POINTER_VALUE) + 1
    FROM CRCDATA..sy12 WITH(UPDLOCK, HOLDLOCK)
    WHERE PFILE_NAME = 'NXTPO';

    IF @nextPo IS NULL OR @nextPo NOT BETWEEN 1 AND 999999
        THROW 50010, 'The next PO number is invalid or exceeds six digits.', 1;

    SET @poNumb = RIGHT('000000' + CONVERT(VARCHAR(6), @nextPo), 6);

    -- Moves Pointer
    UPDATE CRCDATA..SY12 
    SET POINTER_VALUE = RIGHT('00000000000000000000' + @poNumb, 20) 
    WHERE pfile_name = 'NXTPO'

    DECLARE @charges TABLE (
        designId    VARCHAR(12),
        chargeType  VARCHAR(6),
        cost        DECIMAL(10,3)
    )

    INSERT INTO @charges (
        designId,
        chargeType,
        cost
    )
    SELECT 
        dp.designId,
        CASE 
            WHEN tc.mold = 1 THEN 'Mold'
            ELSE 'Sample'
        END,
        tc.cost
    FROM @designPrices dp
    JOIN dbo.ORDER_DESIGNS od
        ON od.id = dp.designId 
    -- Inner join on purpose: a method with no row for this vendor has no sample or mold charge
    -- (business rule), so the design gets no charge line.
    JOIN dbo.OFFSHORE_DESIGN_TREATMENT_CHARGES tc
        ON tc.method = od.method
        AND tc.vendor = @vendor
    WHERE NOT EXISTS ( -- No Repeat Order Rule
        SELECT 1 
        FROM CRCDATA.DBO.PO11 p11
        WHERE p11.ITEM_NUMB = dp.designId
    )
    AND ( -- Handles rules for Mold and Sample
            (tc.mold = 1 AND dp.quantity < tc.moqRefundable)
        OR  (tc.mold = 0 AND EXISTS (
                SELECT 1 
                FROM dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST sr
                WHERE sr.designId = dp.designId 
                    AND sr.vendor = @vendor
                    AND sr.cancelledAt IS NULL
                    AND sr.byPassed = 0            -- Rush bypass: no sample was made
            ))
    );

    IF (SELECT COUNT(*) FROM @designPrices) + (SELECT COUNT(*) FROM @charges) > 999
        THROW 50011, 'A purchase order cannot contain more than 999 lines including sample and mold charges.', 1;

    INSERT INTO CRCDATA.DBO.PO10 (
        [PO_NUMB],
        [PO_NUMB_SPARE1],
        [VEND_NUMB],
        [VEND_NAME],
        [VEND_ADDR1],
        [VEND_ADDR2],
        [VEND_CITY],
        [VEND_STATE],
        [VEND_ZIP],
        [VEND_ATTN],
        [SHIPTO_NUMB],
        [SHIPTO_NAME],
        [SHIPTO_ADDR1],
        [SHIPTO_ADDR2],
        [SHIPTO_CITY],
        [SHIPTO_STATE],
        [SHIPTO_ZIP],
        [SHIPTO_ATTN],
        [BUYER1_NUMB],
        [INLUDE_ON_1099_FLAG],
        [BLANKET_PO_FLAG],
        [FOB_DESC],
        [RDAT_REVISED],
        [DATE_ORDERED],
        [DATE_REQUIRED],
        [CONFIRMING_FLAG],
        [CCNTR_NUMB],
        [TERMS_DESC],
        [AP_POST_CODE],
        [AP_OPERATOR_ID],
        [GROSS_PO_DLR],
        [STATUS_FLAG],
        [SHIP_VIA_CODE],
        [SHIP_VIA_DESC],
        [TERMS_CODE],
        [FOB_CODE],
        [CRED_MEMO_FLAG],
        [CURRENCY_CODE],
        [CEF],
        [RDATE_ORDERED],
        [RDATE_REQUIRED],
        [DEST_TYPE],
        [MESSAGE_NUMB]
    )
    SELECT
        @poNumb,                                            -- [PO_NUMB]
        '000',                                              -- [PO_NUMB_SPARE1]
        @vendor,                                            -- [VEND_NUMB]
        vn10.NAME,                                          -- [VEND_NAME]
        vn10.addr1,                                         -- [VEND_ADDR1]
        vn10.addr2,                                         -- [VEND_ADDR2]
        vn10.city,                                          -- [VEND_CITY]
        vn10.state,                                         -- [VEND_STATE]
        vn10.zip,                                           -- [VEND_ZIP]
        vn10.attn,                                          -- [VEND_ATTN]
        '',                                                 -- [SHIPTO_NUMB]
        'Accolade / Levelwear / Ke',                        -- [SHIPTO_NAME]
        '66 West Beaver Creek Rd. ',                        -- [SHIPTO_ADDR1]
        '',                                                 -- [SHIPTO_ADDR2]
        'Richmond Hill',                                    -- [SHIPTO_CITY]
        'ON',                                               -- [SHIPTO_STATE]
        'L4B1G5',                                           -- [SHIPTO_ZIP]
        '',                                                 -- [SHIPTO_ATTN]
        '22',                                               -- [BUYER1_NUMB]
        'Y',                                                -- [INLUDE_ON_1099_FLAG]
        'N',                                                -- [BLANKET_PO_FLAG]
        '',                                                 -- [FOB_DESC]
        CRCDATA.DBO.Return_RDAT(GETDATE()),                 -- [RDAT_REVISED]
        CONVERT(VARCHAR, GETDATE(), 1),                     -- [DATE_ORDERED]
        @dateRequired,                                      -- [DATE_REQUIRED]
        'N',                                                -- [CONFIRMING_FLAG]
        '940.10',                                           -- [CCNTR_NUMB]
        'TT COD',                                           -- [TERMS_DESC]
        '11',                                               -- [AP_POST_CODE]
        '11',                                               -- [AP_OPERATOR_ID]
        (
            SELECT CAST(
                (SELECT SUM(price * quantity) FROM @designPrices)
            + ISNULL((SELECT SUM(cost) FROM @charges), 0)
            AS VARCHAR(30))
        ),                                                  -- [GROSS_PO_DLR]
        '1',                                                -- [STATUS_FLAG]
        '05',                                               -- [SHIP_VIA_CODE]
        'Air',                                              -- [SHIP_VIA_DESC]
        '08',                                               -- [TERMS_CODE]
        '',                                                 -- [FOB_CODE]
        'N',                                                -- [CRED_MEMO_FLAG]
        'USD',                                              -- [CURRENCY_CODE]
        (
            SELECT EXCHANGE_RATE_1
            FROM CRCDATA..Exchange_Rates
            WHERE CUR_CODE = 'USD'
        ),                                                  -- [CEF]
        CRCDATA.DBO.return_rdat(GETDATE()),                 -- [RDATE_ORDERED]
        CRCDATA.DBO.return_rdat(@dateRequired),             -- [RDATE_REQUIRED]
        '0',                                                -- [DEST_TYPE]
        ''                                                  -- [MESSAGE_NUMB]
    FROM CRCDATA.DBO.VN10 vn10
    WHERE @vendor = vn10.VEND_NUMB


    -- Inserts the PO11 records for the offshore treatments
    INSERT INTO CRCDATA.DBO.PO11 (
        [PO_NUMB],
        [PO_NUMB_SPARE1],
        [PO_LINE_NUMB],
        [PO_PROC_FLAG],
        [NON_STOCK_FLAG],
        [ITEM_NUMB],
        [PO_DESC],
        [ORIG_ORDER_QTY],
        [ORIG_UNIT_COST],
        [ORDER_QTY],
        [UNIT_PRICE],
        [STATUS_FLAG],
        [GROSS_LINE_DLR],
        [JC16_SEQ_NUMB],
        [AP_POST_CODE],
        [JOB_NUMB],
        [VEND_NUMB],
        [RDAT_ORDERED],
        [TAX_PCT],
        [DATE_DUE],
        [TAXABLE_FLAG],
        [COA_NUMB],
        [ORDER_UM],
        [CCNTR_NUMB],
        [CHARGE_CODE],
        [ORIG_PO_DLR],
        [PRICE_UM]
    )
    SELECT
        @poNumb,                                            -- [PO_NUMB]
        '000',                                              -- [PO_NUMB_SPARE1]
        RIGHT(
            '000' + CAST(
                ROW_NUMBER() OVER (ORDER BY dp.designId) AS VARCHAR(3)
            ),
            3
        ),                                                  -- [PO_LINE_NUMB]
        '0',                                                -- [PO_PROC_FLAG]
        '',                                                 -- [NON_STOCK_FLAG]
        dp.designId,                                        -- [ITEM_NUMB]
        dp.designId,                                        -- [PO_DESC]
        dp.quantity,                                        -- [ORIG_ORDER_QTY]
        dp.price,                                           -- [ORIG_UNIT_COST]
        dp.quantity,                                        -- [ORDER_QTY]
        dp.price,                                           -- [UNIT_PRICE]
        '',                                                 -- [STATUS_FLAG]
        CAST(dp.price * dp.quantity AS VARCHAR(30)),        -- [GROSS_LINE_DLR]
        '133',                                              -- [JC16_SEQ_NUMB]
        '11',                                               -- [AP_POST_CODE]
        '',                                                 -- [JOB_NUMB]
        @vendor,                                            -- [VEND_NUMB]
        CRCDATA.DBO.return_rdat(GETDATE()),                 -- [RDAT_ORDERED]
        '',                                                 -- [TAX_PCT]
        CONVERT(
            CHAR(8),
            DATEADD(DAY, 7, @parsedDateRequired),
            1
        ),                                                  -- [DATE_DUE]
        '',                                                 -- [TAXABLE_FLAG]
        '120120022350',                                     -- [COA_NUMB]
        'EA',                                               -- [ORDER_UM]
        '940.10',                                           -- [CCNTR_NUMB]
        '0',                                                -- [CHARGE_CODE]
        CAST(dp.price * dp.quantity AS VARCHAR(30)),        -- [ORIG_PO_DLR]
        'EA'                                                -- [PRICE_UM]
    FROM @designPrices dp;

    -- Gets the latest PO_LINE_NUMB seq. value
    DECLARE @lastPoLineNumb INT; 

    SELECT @lastPoLineNumb = 
        MAX(TRY_CAST(p11.PO_LINE_NUMB AS INT))
    FROM CRCDATA.DBO.PO11 p11
    WHERE p11.PO_NUMB = @poNumb;
    
    -- Inserts the PO11 records for the offshore treatment sample requests
    INSERT INTO CRCDATA.DBO.PO11 (
        [PO_NUMB],
        [PO_NUMB_SPARE1],
        [PO_LINE_NUMB],
        [PO_PROC_FLAG],
        [NON_STOCK_FLAG],
        [ITEM_NUMB],
        [PO_DESC],
        [ORIG_ORDER_QTY],
        [ORIG_UNIT_COST],
        [ORDER_QTY],
        [UNIT_PRICE],
        [STATUS_FLAG],
        [GROSS_LINE_DLR],
        [JC16_SEQ_NUMB],
        [AP_POST_CODE],
        [JOB_NUMB],
        [VEND_NUMB],
        [RDAT_ORDERED],
        [TAX_PCT],
        [DATE_DUE],
        [TAXABLE_FLAG],
        [COA_NUMB],
        [ORDER_UM],
        [CCNTR_NUMB],
        [CHARGE_CODE],
        [ORIG_PO_DLR],
        [PRICE_UM]
    )
    SELECT
        @poNumb,                                            -- [PO_NUMB]
        '000',                                              -- [PO_NUMB_SPARE1]
        RIGHT(
            '000' + CAST(
                @lastPoLineNumb + ROW_NUMBER() OVER (ORDER BY c.designId) AS VARCHAR(3)
            ),
            3
        ),                                                  -- [PO_LINE_NUMB]
        '0',                                                -- [PO_PROC_FLAG]
        '*',                                                -- [NON_STOCK_FLAG]
        'NS',                                               -- [ITEM_NUMB]
        CONCAT(c.chargeType, ' cost for ', c.designId),     -- [PO_DESC]         
        1,                                                  -- [ORIG_ORDER_QTY]
        c.cost,                                             -- [ORIG_UNIT_COST]
        1,                                                  -- [ORDER_QTY]
        c.cost,                                             -- [UNIT_PRICE]
        '',                                                 -- [STATUS_FLAG]
        c.cost,                                             -- [GROSS_LINE_DLR]
        '100',                                              -- [JC16_SEQ_NUMB]
        '11',                                               -- [AP_POST_CODE]
        '',                                                 -- [JOB_NUMB]
        @vendor,                                            -- [VEND_NUMB]
        CRCDATA.DBO.return_rdat(GETDATE()),                 -- [RDAT_ORDERED]
        '',                                                 -- [TAX_PCT]
        CONVERT(
            CHAR(8),
            DATEADD(DAY, 7, @parsedDateRequired),
            1
        ),                                                  -- [DATE_DUE]
        '',                                                 -- [TAXABLE_FLAG]
        '120120022350',                                     -- [COA_NUMB]
        'EA',                                               -- [ORDER_UM]
        '940.10',                                           -- [CCNTR_NUMB]
        '0',                                                -- [CHARGE_CODE]
        c.cost,                                            -- [ORIG_PO_DLR]
        'EA'                                                -- [PRICE_UM]
    FROM @charges c;

    COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
