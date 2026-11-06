legacy SP is the legacy version.
Order2 SP is the legacy version.
Order3 is the current live version.

===============================================================================================================================================================================
AI PROMT TO SWAP TO DEVLOPMENT CREATE PO
===============================================================================================================================================================================

Create a development-only stored procedure named dbo.CreateDesignPO4 based on the existing dbo.CreateDesignPO3.
Keep the same parameters:
- @designPrices dbo.DesignPrice READONLY
- @vendor VARCHAR(5)
- @dateRequired CHAR(8)
- @poNumb CHAR(6) OUTPUT
Preserve the existing input validation, transaction handling, and error handling. Do not modify CreateDesignPO3.
For CreateDesignPO4:
- Do not read or update CRCDATA..SY12.
- Do not insert into CRCDATA.DBO.PO10.
- Do not insert into CRCDATA.DBO.PO11.
- Remove the USD exchange-rate validation because no ERP PO is created.
- Retain the VN10 vendor validation unless it prevents isolated development testing.
- Generate a fake six-digit PO using MAX(po) + 5 from dbo.OFFSHORE_DESIGN_ORDER_HDR.
- Start at 000005 when no prior numeric PO exists.
- Use WITH (UPDLOCK, HOLDLOCK) so concurrent Go transactions cannot generate the same number.
- Assign the generated value to @poNumb.
- Reject generated numbers outside 000001–999999.
- Clearly document that this procedure is development-only and creates no ERP purchasing records.
Then temporarily change the V2 Go PO-creation call from dbo.CreateDesignPO3 to dbo.CreateDesignPO4. Do not modify the surrounding Go transaction, offshore header/detail inserts, demand claiming, status records, or timeline records.
Verify that:
- The SQL procedure compiles.
- The Go API compiles.
- PO creation returns sequential fake numbers such as 000005, 000010, and 000015.
- No records are written to CRCDATA..SY12, PO10, or PO11.
- The generated fake PO is still written to the V2 offshore tables and associated demand records.
Report every changed file and clearly state that PO4 must be deployed before the Go caller is switched to it.