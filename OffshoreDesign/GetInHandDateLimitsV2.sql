                                                                                                                    
----------------------------------------------------------------------------------------------------------------------------
-- =============================================
                                                                          
-- Author:		<Author,,Name>
                                                                                                
-- Create DATE: <Create DATE,,>
                                                                                           
-- Description:	<Description,,>
                                                                                           
-- =============================================
                                                                          
CREATE PROCEDURE [OrderEntry].[GetInHANDDATELimitsV2]
	@products_AND_treatments dbo.StyleColorTreatmentDesign READONLY,
	@order_type CHAR(3),                                                                                              
	@state CHAR(2),                                                                                        
	@country CHAR(1),                                                                                               
	@rep CHAR(3),                                                                                                      
	@order_time DATE = NULL
AS
                                                                                                                        
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets FROM
	-- INTerfering with SELECT statements.
	SET NOCOUNT ON;
                                                                                                          
	IF NULL IN (@state, @country)
		RAISERROR('@state AND @country must not be NULL', 1, 16);
                                                                                                                          
    SET @order_time = ISNULL(@order_time, GETDATE());
                                                                                                                          
	DECLARE @shipping_business_days INT = (
		SELECT [days]
		FROM crcdata..wo_rdat_want
		WHERE country = @country 
            AND shipto = @state
	);
                                                                                                                                                                                                                            
	DECLARE @result dbo.GetInHANDDATELimitsResult;
                                                                           
	INSERT INTo @result                                                                                                      
	SELECT 
        OrderEntry.AddBusinessDays(getDATE(), a.production_lead_time + @shipping_business_days, @country) production_DATE,
		OrderEntry.AddBusinessDays(b.INTRO_DATE, 0, @country), 
        c.order_type_DATE                                                
	FROM (
		SELECT 
            MAX(CASE
				WHEN d.is_predecorated = 1 OR c.lead_time != 0 -- if any decorated                                                    
				    THEN CASE
                        WHEN @order_type = '217' 
                            OR c.lead_time = 0
                        THEN 10
                        ELSE c.lead_time                                                                        
					END                                                                                                  
				ELSE CASE -- if all blank
					WHEN @order_time <= DATEadd(hour, 9, DATEadd(minute, 30, cast(cast(getDATE() as DATE) as DATEtime)))
					THEN 1
                    ELSE 2
                END
			END) production_lead_time                                                                              
		FROM @products_AND_treatments a
		LEFT JOIN currliclongskus_decoration b 
            ON a.style = b.style_code_no_country 
            AND a.color = b.colorcode
		OUTER APPLY (                                                                                                           
            SELECT
                ISNULL(
                    MAX(c.LeadTimeWeeks) * 5, 0
                ) -
                CASE
                    WHEN EXISTS (
                        SELECT 1
                        FROM CRCDATA.dbo.PO11 p11
                        WHERE p11.ITEM_NUMB = a.designId
                    )
                    THEN 10
                    ELSE 0
                END AS lead_time
            FROM TreatmentMaster c
            WHERE ISNULL(a.treatment, b.method) = c.TreatmentType                                                          
		) c
		OUTER APPLY (
			SELECT TOP 1 1 is_predecorated
			FROM style d
			WHERE d.stylenum = a.style 
            AND d.brAND = 'a' -- order is pre-decorated
		) d
	) a
	CROSS APPLY (
		SELECT cast(MAX(c.INTRO_DATE) as DATE) INTRO_DATE
		FROM @products_AND_treatments a
		LEFT JOIN currliclongskus_style b ON a.style = b.stylenum
		JOIN style c ON isNULL(b.basestyle, a.style) = c.stylenum
                                                               
	) b
	CROSS APPLY (
		SELECT TOP 1 
            CASE
				WHEN c.earliest_DATE > c.lead_time_DATE
				THEN c.earliest_DATE
				ELSE c.lead_time_DATE
			END order_type_DATE
		FROM order_types_view a
		LEFT JOIN order_types_exceptions b 
            ON a.JC17Code = b.jc17code 
            AND b.srep = @rep
		CROSS APPLY (
			SELECT 
                cast(coalesce(a.earliestDATE, DATEFROMparts(
				    year(getDATE()) - 
                    CASE
                        WHEN month(getDATE()) <= 6
                        THEN 1
                        ELSE 0
                    END, a.earliestmonth, a.earliestday
	    		), getDATE()) as DATE) earliest_DATE,
                                                                             
				OrderEntry.AddBusinessDays(
                                                                                           
					getDATE(),
                                                                                                           
					c.lead_time - (c.lead_time / 7 * 2 + 1) /* remove approximate weekEND days count */ +
                                
						@shipping_business_days,
                                                                                            
					@country
                                                                                                             
				) lead_time_DATE
                                                                                                      
			FROM (
                                                                                                                 
				SELECT isNULL(b.minleadtimedays, a.minleadtimedays) lead_time
                                                         
			) c
                                                                                                                    
		) c
                                                                                                                     
		WHERE a.jc17code = @order_type
                                                                                          
	) c;
                                                                                                                     

                                                                                                                          
	SELECT *
                                                                                                                 
	FROM @result;
                                                                                                            

                                                                                                           
END
                                                                                                                       

