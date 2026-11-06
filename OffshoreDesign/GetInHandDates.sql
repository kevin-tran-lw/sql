Result Set Batch 1 - Query 1
========================================

Text                                                                                                                        
----------------------------------------------------------------------------------------------------------------------------
-- =============================================
                                                                          
-- Author:		<Author,,Name>
                                                                                                
-- Create date: <Create Date,,>
                                                                                           
-- Description:	<Description,,>
                                                                                           
-- =============================================
                                                                          
CREATE PROCEDURE [OrderEntry].[GetInHandDateLimits]
                                                                       
	@products_and_treatments dbo.StyleColorTreatment readonly,
                                                               
	@order_type char(3),
                                                                                                     
	@state char(2),
                                                                                                          
	@country char(1),
                                                                                                        
	@rep char(3),
                                                                                                            
	@order_time date = null
                                                                                                  
AS
                                                                                                                        
BEGIN
                                                                                                                     
	-- SET NOCOUNT ON added to prevent extra result sets from
                                                                
	-- interfering with SELECT statements.
                                                                                   
	SET NOCOUNT ON;
                                                                                                          

                                                                                                                          
	if null in (@state, @country)
                                                                                            
		raiserror('@state and @country must not be null', 1, 16);
                                                               

                                                                                                                          
	set @order_time = isnull(@order_time, getdate());
                                                                        

                                                                                                                          
	declare @shipping_business_days int = (
                                                                                  
		select [days]
                                                                                                           
		from crcdata..wo_rdat_want
                                                                                              
		where country = @country and shipto = @state
                                                                            
	);
                                                                                                                       

                                                                                                                          
	declare @result dbo.GetInHandDateLimitsResult;
                                                                           

                                                                                                                          
	insert into @result
                                                                                                      
	select OrderEntry.AddBusinessDays(getdate(), a.production_lead_time + @shipping_business_days, @country) production_date,

		OrderEntry.AddBusinessDays(b.intro_date, 0, @country), c.order_type_date
                                                
	from (
                                                                                                                   
		select max(case
                                                                                                         
				when d.is_predecorated = 1 or c.lead_time != 0 -- if any decorated
                                                    
				then case
                                                                                                             
						when @order_type = '217' or c.lead_time = 0
                                                                         
						then 10
                                                                                                             
						else c.lead_time
                                                                                                    
					end
                                                                                                                  
				else case -- if all blank
                                                                                             
						when @order_time <= dateadd(hour, 9, dateadd(minute, 30, cast(cast(getdate() as date) as datetime)))
                
						then 1
                                                                                                              
						else 2
                                                                                                              
					end
                                                                                                                  
			end) production_lead_time
                                                                                              
		from @products_and_treatments a
                                                                                         
		left join currliclongskus_decoration b on a.style = b.style_code_no_country and
                                         
			a.color = b.colorcode
                                                                                                  
		outer apply (
                                                                                                           
			select isnull(max(c.leadtimeweeks) * 5, 0) lead_time
                                                                   
			from treatmentmaster c
                                                                                                 
			where isnull(a.treatment, b.method) = c.treatmenttype
                                                                  
		) c
                                                                                                                     
		outer apply (
                                                                                                           
			select top 1 1 is_predecorated
                                                                                         
			from style d
                                                                                                           
			where d.stylenum = a.style and d.brand = 'a' -- order is pre-decorated
                                                 
		) d
                                                                                                                     
	) a
                                                                                                                      
	cross apply (
                                                                                                            
		select cast(max(c.introdate) as date) intro_date
                                                                        
		from @products_and_treatments a
                                                                                         
		left join currliclongskus_style b on a.style = b.stylenum
                                                               
		join style c on isnull(b.basestyle, a.style) = c.stylenum
                                                               
	) b
                                                                                                                      
	cross apply (
                                                                                                            
		select top 1 case
                                                                                                       
				when c.earliest_date > c.lead_time_date
                                                                               
				then c.earliest_date
                                                                                                  
				else c.lead_time_date
                                                                                                 
			end order_type_date
                                                                                                    
		from order_types_view a
                                                                                                 
		left join order_types_exceptions b on a.JC17Code = b.jc17code and b.srep = @rep
                                         
		cross apply (
                                                                                                           
			select cast(coalesce(a.earliestdate, datefromparts(
                                                                    
				year(getdate()) - case
                                                                                                
						when month(getdate()) <= 6
                                                                                          
						then 1
                                                                                                              
						else 0
                                                                                                              
					end, a.earliestmonth, a.earliestday
                                                                                  
				), getdate()) as date) earliest_date,
                                                                                 
				OrderEntry.AddBusinessDays(
                                                                                           
					getdate(),
                                                                                                           
					c.lead_time - (c.lead_time / 7 * 2 + 1) /* remove approximate weekend days count */ +
                                
						@shipping_business_days,
                                                                                            
					@country
                                                                                                             
				) lead_time_date
                                                                                                      
			from (
                                                                                                                 
				select isnull(b.minleadtimedays, a.minleadtimedays) lead_time
                                                         
			) c
                                                                                                                    
		) c
                                                                                                                     
		where a.jc17code = @order_type
                                                                                          
	) c;
                                                                                                                     

                                                                                                                          
	select *
                                                                                                                 
	from @result;
                                                                                                            

                                                                                                                          
END
                                                                                                                       

