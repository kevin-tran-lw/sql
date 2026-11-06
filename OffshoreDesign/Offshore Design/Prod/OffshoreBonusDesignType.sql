-- Bonus quantities entered in the Manager's Approval Order Bonus dialog, passed to
-- CheckOffShoreDesignOrder3 as @bonus. id is the normalized (parent) design ID from #offShoreSKUs.
-- Run once before deploying CheckOffShoreDesignOrder3.
IF TYPE_ID(N'dbo.OffshoreBonusDesign') IS NULL
BEGIN
    CREATE TYPE dbo.OffshoreBonusDesign AS TABLE (
        id          VARCHAR(12)     NOT NULL PRIMARY KEY,
        quantity    INT             NOT NULL CHECK (quantity >= 0)
    );
END;
