SELECT * FROM OFFSHORE_DESIGN_ORDER_HDR ORDER BY PO DESC;
SELECT * FROM OFFSHORE_DESIGN_ORDER_DTL ORDER BY PO DESC;
SELECT * FROM OFFSHORE_DESIGN_SAMPLE_REQUEST ORDER BY createdAt DESC;
SELECT * from DESIGN_ORDERS ORDER BY ID DESC;

SELECT do.id, sr.id, sr.designId, * FROM OFFSHORE_DESIGN_SAMPLE_REQUEST sr
JOIN DESIGN_ORDERS do
    ON sr.designId = do.design
    AND sr.vendor = do.vendor
WHERE do.design = 'SDTAN1700001'

UPDATE a 
SET a.designOrdersId = 1938
from OFFSHORE_DESIGN_SAMPLE_REQUEST a 
WHERE a.designId = 'SDTAN1700001'
    and a.id = 2201
    


SELECT * FROM OFFSHORE_ISSUE_REASON;
SELECT * FROM OFFSHORE_DESIGN_TIMELINE ORDER BY createdAt DESC;
SELECT * FROM OFFSHORE_DESIGN_MESSAGE_TYPES;
SELECT * FROM OFFSHORE_DESIGN_STATUS;
SELECT * FROM OFFSHORE_DESIGN_STATUS_TIMELINE ORDER BY ID DESC, createdAt DESC;
SELECT * FROM OFFSHORE_DESIGN_VENDOR_USER;
SELECT * FROM OFFSHORE_DESIGN_QUOTE_REQUEST ORDER BY quoteRequestId DESC;
SELECT * FROM OFFSHORE_DESIGN_PRICE ORDER BY priceBucketID DESC, qty DESC;
SELECT * FROM OFFSHORE_DESIGN_PRICE_MAP ORDER BY priceBucketID DESC
SELECT * FROM OFFSHORE_DESIGN_PRICE_RESTRICTIONS;
SELECT * FROM OFFSHORE_ORDER_PENDING_SUBMISSION ORDER BY createdAt DESC;
SELECT * FROM OFFSHORE_DESIGN_VENDOR_SHIPMENTS;
SELECT * FROM OFFSHORE_DESIGN_VENDOR_FILES ORDER BY uploadedAt desc;
SELECT * FROM OFFSHORE_DESIGN_VENDOR_FILE_TYPE;
SELECT * from OFFSHORE_APPROVED_METHOD_PRICING
SELECT * FROM OFFSHORE_ART_PRODUCTION_REQUEST WHERE designid = 'TPTSUTA00001'
SELECT * FROM OFFSHORE_ART_PRODUCTION_TIMELINE;
SELECT * FROM OFFSHORE_ART_PRODUCTION_TIMELINE_TYPES;
SELECT * FROM OFFSHORE_ART_PRODUCTION_TIMELINE_FILES;
SELECT * FROM OFFSHORE_DESIGN_TREATMENT_CHARGES;
SELECT * from DESIGN_ORDERS ORDER BY ID DESC;
SELECT * FROM DESIGN_ORDER_DTL ORDER BY ID DESC;
SELECT * FROM DESIGN_ORDERS_TYPE;
SELECT * FROM ORDER_DESIGNS;
SELECT * FROM ORDER_HDR;
SELECT FabricComposition,* from stylemaster..style WHERE StyleNum = ''
SELECT * FROM FabricMaster;
SELECT * FROM STYLE;
SELECT * FROM CRCDATA.DBO.PO10;
SELECT * FROM CRCDATA.DBO.PO11;

SELECT 
    p11.ITEM_NUMB,
    COUNT(*) AS occurrenceCount
FROM CRCDATA.DBO.PO11 p11
WHERE p11.ITEM_NUMB LIKE 'CH%'
GROUP BY p11.ITEM_NUMB
HAVING COUNT(*) > 1
ORDER BY occurrenceCount DESC;

SELECT p10.DATE_ORDERED, p11.* FROM CRCDATA.DBO.PO11 p11 
JOIN CRCDATA.DBO.PO10 p10
    ON p11.PO_NUMB = p10.PO_NUMB
WHERE p11.ITEM_NUMB = 'CHEMX3900001'
ORDER BY CAST(p10.DATE_ORDERED AS date) DESC;

SELECT * FROM CRCDATA.DBO.PO11 where PO_NUMB = '044306';
SELECT * FROM CRCDATA.DBO.PO11 where PO_NUMB = '044299'

SELECT * FROM CRCDATA.DBO.PO11 where PO_NUMB = '033660';
SELECT * FROM CRCDATA.DBO.PO11 where PO_NUMB = '043575';

SELECT * FROM CRCDATA.DBO.PO11 WHERE AP_POST_CODE = '11';

SELECT * FROM CRCDATA.DBO.PO11 where PO_NUMB = '036227';
SELECT * FROM CRCDATA.DBO.PO11 where PO_NUMB = '044127'
SELECT * FROM OFFSHORE_DESIGN_TREATMENT_CHARGES;

SELECT * FROM CRCDATA.DBO.JC16;

select * from crcdata.dbo.po11 where JC16_SEQ_NUMB = 100;


select * from crcdata.dbo.po11 p11 WHERE p11.PO_DESC LIKE '%samp%' ORDER BY CAST(DATE_DUE AS date) desc;
select * from crcdata.dbo.po11 p11 WHERE p11.PO_DESC LIKE '%mold%' ORDER BY CAST(DATE_DUE AS date) desc;

INSERT INTO OFFSHORE_ART_PRODUCTION_TIMELINE_TYPES (
    messageType
) VALUEs ('REVISION_PROD_FILE_REPLACED'), ('REVISION_MANAGERS_APPROVED'), ('MANAGERS_APPROVED')

SELECT lic.baseStyle, dtl.sku, hdr.numb, dtl.sku, dtl.colorCode, RTRIM(k.COLOR_DESC) AS color,
       s.StyleNum, s.StyleName, s.Category, s.Gender, fm.FabricComposition AS fabric
FROM dbo.ORDER_HDR hdr
JOIN dbo.ORDER_DTL dtl ON dtl.orderID = hdr.id
LEFT JOIN CRCDATA..KZ01 k ON k.ORDER_SEQ = dtl.colorCode
LEFT JOIN dbo.CurrLicLongSkus_Style lic ON lic.styleNum = dtl.sku AND lic.colorCode = dtl.colorCode
LEFT JOIN dbo.style s ON s.StyleNum = ISNULL(lic.baseStyle, dtl.sku)
LEFT JOIN dbo.FabricMaster fm ON fm.Code = s.FabricComposition
WHERE hdr.numb = 184194

SELECT
    LEFT(LTRIM(RTRIM(s.styleNum)), 2) AS prefix,
    COALESCE(
        NULLIF(LTRIM(RTRIM(s.fabricComposition)), ''),
        '(missing)'
    ) AS fabricCode,
    COALESCE(
        NULLIF(LTRIM(RTRIM(f.FabricComposition)), ''),
        '(no matching description)'
    ) AS description,
    COUNT(*) AS styleCount
FROM dbo.style s
LEFT JOIN dbo.FabricMaster f
    ON LTRIM(RTRIM(f.Code)) = LTRIM(RTRIM(s.fabricComposition))
WHERE LEFT(LTRIM(RTRIM(s.styleNum)), 2) IN ('RC', 'CM', 'US', 'HF', 'JI')
GROUP BY
    LEFT(LTRIM(RTRIM(s.styleNum)), 2),
    COALESCE(NULLIF(LTRIM(RTRIM(s.fabricComposition)), ''), '(missing)'),
    COALESCE(NULLIF(LTRIM(RTRIM(f.FabricComposition)), ''), '(no matching description)')
ORDER BY prefix, styleCount DESC, fabricCode;




SELECT * FROM STYLE WHERE StyleNum Like 'RC%'

SELECT * FROM Style Where StyleNum LIKE 'rc%'

SELECT TOP 5 baseStyle, * FROM CurrLicLongSkus;

SELECT FabricComposition, * FROM Style;
select Code, * from FabricMaster;


SELECT * FROM CRCDATA..WO_RDAT_WANT;
SELECT * FROM CRCDATA..HOLIDAY_WEEKENDS;

SELECT LeadTimeWeeks, TreatmentType, vend_numb, * FROM TreatmentMaster WHERE vend_numb IS NOT NULL;

EXEC sp_helptext 'OrderEntry.GetEarliestInHandDateByOrder';
EXEC sp_helptext 'OrderEntry.AddBusinessDays';
EXEC sp_helptext 'OrderEntry.earliestinhandsample'
EXEC sp_helptext 'OrderEntry.getinhanddatelimits';

-- ==========================================================================================

SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.FG_ALLOC'));

DECLARE @orderId VARCHAR(40) = '5x8ftcUdYavmJ33IEgAso9TRdnjvekaGM7LfL84v'
DECLARE @order_type CHAR(3);                                                    
DECLARE @state CHAR(2);                                                         
DECLARE @country CHAR(1);                                                            
DECLARE @rep CHAR(3);                                                            
DECLARE @order_time DATETIME;                                                
DECLARE @pre_prod_date DATE;                                                          
DECLARE @is_sample BIT;                                                             
DECLARE @is_game_day BIT;
DECLARE @rush BIT;

-- ========== GET HDR INFO ==========                            
                                 
SELECT 
    @order_type = od.[type],
    @state= od.[state],
    @country = od.currency,
    @rep = od.rep,
    @order_time = od.updated_at,
    @pre_prod_date = od.date_required,
    @rush = od.rush
FROM ORDER_HDR od 
WHERE id = @orderId;

SELECT
    @order_type AS order_type,
    @state AS state,
    @country AS country,
    @rep AS rep,
    @order_time AS order_time,
    @pre_prod_date AS pre_prod_date,
    @is_sample AS is_sample,
    @is_game_day AS is_game_day,
    @rush AS rush;


-- ========================================

DECLARE @products_and_treatments dbo.StyleColorTreatmentDesign;

INSERT INTO @products_and_treatments
SELECT 
    dtl.sku,
    dtl.colorcode,
    dtld.method,
    dtld.designId
FROM ORDER_DTL dtl
LEFT JOIN ORDER_DTL_DECORATION dtld
    ON dtld.lineId = dtl.id
WHERE dtl.orderID = @orderId;

SELECT * FROM @products_and_treatments;

-- ========================================

DECLARE @limits dbo.getinhanddatelimitsresult

INSERT INTO @limits
EXEC orderentry.getinhanddatelimits
    @products_and_treatments = @products_and_treatments,
    @order_type = @order_type,
    @state = @state,
    @country = @country,
    @rep = @rep,
    @order_time = @order_time

SELECT * FROM @limits;

-- ========================================

SELECT 
    MAX([date])
FROM (
    SELECT production_date [date]
    FROM @limits
    UNION
    SELECT intro_date   
    FROM @limits
    UNION
    SELECT order_type_date
    FROM @limits
    UNION
    SELECT @pre_prod_date
) a;


