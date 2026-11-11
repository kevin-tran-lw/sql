/* 

    Useful for when we have an input value and need an associating matching pair of data

*/
SELECT *
FROM (
    VALUES
        ('PZAM20299002'),
        ('PZAA07732014'),
        ('XXXX')
) AS designs(design)
OUTER APPLY (
    SELECT 
        tm.VEND_NUMB,
        vn.NAME
    FROM TreatmentMaster tm
    JOIN CRCDATA..VN10 vn
       ON tm.VEND_NUMB = VN.VEND_NUMB
    WHERE tm.TreatmentType = SUBSTRING(LTRIM(RTRIM(designs.design)), 1, 4)
) latest;
