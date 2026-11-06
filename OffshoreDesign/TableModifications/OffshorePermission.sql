SELECT * FROM CRCDATA..DASHBOARD_USER WHERE email = 'shirley@levelwear.com'

BEGIN TRANSACTION;

UPDATE a
SET a.approve_quote =  1
FROM CRCDATA..DASHBOARD_USER a
WHERE a.email = 'shirley@levelwear.com'

ROLLBACK;
