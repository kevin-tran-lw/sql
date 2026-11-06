SET IDENTITY_INSERT dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST ON;

INSERT INTO dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST (
    id,
    designId,
    createdAt,
    createdBy,
    vendor,
    requiredBy,
    approvedAt,
    photo,
    physical,
    photoFilePath,
    trackingNo,
    cancelledAt,
    etd
)
VALUES (
    1745,
    'PZAAY1000009',
    '2026-10-16 14:23:02.6541324',
    'no-reply@levelwear.com',
    '12189',
    '2026-04-02',
    '2026-04-02 00:00:00',
    1,
    0,
    NULL,
    NULL,
    NULL,
    NULL
);

SET IDENTITY_INSERT dbo.OFFSHORE_DESIGN_SAMPLE_REQUEST OFF;