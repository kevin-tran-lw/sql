-- Current Order Numbers 181837 & 181128

-- ======================= VIEWING THE ORDER =======================

SELECT TOP 1 * FROM ORDER_DTL_SIZE;
SELECT TOP 1 * FROM ORDER_DTL_DECORATION;

SELECT 
    oh.numb,
    oh.[status],
    oh.subStatus,
    oh.id,
    odd.designId,
    od.id,
    ods.quantity
FROM ORDER_HDR oh
JOIN ORDER_DTL od
    ON od.orderID = oh.id
JOIN ORDER_DTL_DECORATION odd
    ON odd.lineId = od.id
JOIN ORDER_DTL_SIZE ods
    ON ods.lineId = od.id
WHERE oh.numb IN ('181837', '181128')
    AND oh.id IN ('9XKaNmAtbakNqHzqTwAL9nnpQlSklQgV44AXC6OW', '3yRPIGrZEEKtvdQhRDSPkrSYhQ80tt0EH75tvfBo');

-- ======================= ALTER STATUS =======================
UPDATE oh
SET
    oh.[status] = 5,
    oh.subStatus = 0
FROM ORDER_HDR oh
WHERE oh.numb IN ('181837', '181128')
    AND oh.id IN ('9XKaNmAtbakNqHzqTwAL9nnpQlSklQgV44AXC6OW', '3yRPIGrZEEKtvdQhRDSPkrSYhQ80tt0EH75tvfBo');

-- ======================= ALTER QUANTITY =======================
UPDATE ods
SET 
    ods.quantity = 1
FROM ORDER_DTL_SIZE ods
WHERE ods.lineId = '8E9617F4-9CC6-4B68-99E4-E3B46C991E76'

-- =========================================================================

 