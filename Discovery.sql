/*
	Author : Paul Gill
	E-Mail : Pugi@amazon.co.uk
	Version : 1.0
	Description :
	T-SQL Script that will gather the configuration details of the instance where it is run
	The script captures details on both the instance configuration, database information,
	sql agent jobs as well as logins.

	Be aware the script will enable xp_cmdshell, you should turn this off after completion
	if it was off prior to running.
*/

--- Enable XP_CMDSHELL
sp_configure 'show advanced options',1
go
reconfigure with override
go
sp_configure 'xp_cmdshell',1
go
reconfigure with override
go

--- Declare variables
declare @cluster as nvarchar(15)
declare @ssas as nvarchar(3)
declare @name as nvarchar(128)
declare @ssrs as nvarchar(3)
declare @ssis as nvarchar(3)
declare @ft as nvarchar(3)
declare @count as int
declare @totalt as numeric(10,2)
declare @totald as numeric(10,2)
declare @totalts as numeric(10,2)
declare @result table (line nvarchar(512))
declare @cmd nvarchar(512)
declare @ver as int
declare @version sql_variant
declare @edition sql_variant
declare @collation sql_variant

IF OBJECT_ID('tempdb..#dbinfo') IS NOT NULL  
   DROP TABLE #dbinfo;  

create table #dbinfo(
		DBName nvarchar(128),
		Coll nvarchar(128),
		HA nvarchar(128),
		Rep nvarchar(50),
		TDE nvarchar(50),
		TSize numeric(10,2),
		DSize numeric(10,2),
		Comp int
	)

--- Gather cluster settings
select @count = count(*) from sys.dm_os_cluster_nodes
if @count = 0 (Select @cluster = 'Standalone') else (select @cluster = 'Clustered')

--- Check to see which SQL services are running on the server
set @cmd = 'net start'
insert into @result execute master.dbo.xp_cmdshell @cmd
select @count = count(*) from @result where line like 'Service_Name: MSOLAP%'
if @count = 0 (Select @SSAS = 'No') else (select @SSAS = 'Yes')
select @count = count(*) from @result where line like '   SQL Server Reporting Services%'
if @count = 0 (Select @SSRS = 'No') else (select @SSRS = 'Yes')
select @count = count(*) from @result where line like '   SQL Full-text%'
if @count = 0 (Select @FT = 'No') else (select @FT = 'Yes')
select @count = count(*) from @result where line like '   SQL Server Integration Services%'
if @count = 0 (Select @SSIS = 'No') else (select @SSIS = 'Yes')

--- Get the SQL Version and convert to number
select @version = ServerProperty('ProductVersion')
set @ver = left(convert(varchar,@version),2)

-- Get the instance Collation and Output
select @collation = ServerProperty('Collation')

-- Output SQL Version and Edition Details and Collation Details
select @@VERSION as 'Instance Version', @collation as 'Instance Collation'

--- Gather Database Information based upon core version
Set @cmd =
	(case
		When @ver <= 8 then 'Insert Into #DBInfo (DBName, Comp, Coll, TDE, HA) Select DISTINCT name, compatibility_level, collation_name, ''No'',''No'' from sys.databases'
		When @ver > 8  then 'Insert Into #DBInfo (DBName, Comp, Coll, TDE, HA) Select DISTINCT sd.name, compatibility_level, collation_name, 
			(case when en.encryption_state is null then ''Unencrypted'' else ''Encrypted'' end) ,
			''No'' from sys.databases sd 
	            left join sys.dm_database_encryption_keys en on db_id(sd.name) = en.database_id'
	end)
execute sp_executesql @cmd
select @count = count(*) from #DBInfo where DBName = 'distribution'
if @count = 0 
		Update #DBInfo Set Rep = 'No';
	else 
		Update #DBInfo Set Rep = 'Yes';

declare db_cursor cursor for
	select DBName from #DbInfo
open db_cursor
fetch next from db_cursor into @name
while @@fetch_status = 0
begin
	Select @totalt = (Sum(cast(Size as float)*8)/1024/1024) from sys.master_files where DB_Name(database_id) = @name and type_desc = 'LOG'
	Select @totald = (Sum(Cast(Size as float)*8)/1024/1024) from sys.master_files where DB_Name(database_id) = @name and type_desc = 'ROWS'
	Update #DBInfo Set TSize = @TotalT, DSize = @TotalD where DBname = @Name
	fetch next from db_cursor into @name
end
Close db_cursor
Deallocate db_cursor
Update #DBInfo Set TSize = 0.01 where TSize = 0
Update #DBInfo Set DSize = 0.01 where DSize = 0

-- Output Database Information
Select @@ServerName[Server Name],DBName,'',Coll,HA,Rep,TDE,TSize,DSize,Comp from #DBInfo

-- Gather Base Server Information and Output Clean up temporary tables
Select @TotalT = Sum(TSize) from #DBInfo where DBName <> 'TempDB'
Select @TotalD = Sum(DSize) from #DBINfo where DBName <> 'TempDB'
Select @TotalTS = TSize+DSize from #DBINfo where DBName = 'TempDB'

select @@ServerName[Server Name],'',default_domain()[Domain Name],@Cluster[HA],@ver[Version],serverproperty('Edition')[Edition],serverproperty('Collation')[Collation],@SSAS[SSAS],'N/A'[SSAS Collation],@SSRS[SSRS],@FT[Full Text],@SSIS[SSIS],@TotalD[Data],@TotalT[Log],@TotalTS[Temp]
drop table #DbInfo

-- Output Login Information
Select @@ServerName[Server Name],name,'',sysadmin,securityadmin,serveradmin,setupadmin,processadmin,diskadmin,dbcreator,bulkadmin from master..syslogins

-- Output Job Information
select @@ServerName[Server Name],'',name,enabled from msdb..sysjobs

-- Output Any SSIS Packages
select @@ServerName[Server Name],'',j.name,js.step_name,js.command from msdb..sysjobsteps js inner join msdb..sysjobs j on js.job_id = j.job_id where subsystem = 'SSIS'
