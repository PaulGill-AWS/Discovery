param([String]$Server)

import-module sqlps
Get-Variable * -Exclude $Server | Remove-Variable -EA 0
$Flag = 0

# Determine discovery server and database repository
$DBAServer = "$env:computername\" + (Get-ItemProperty 'HKLM:\SOFTWARE\MICROSOFT\MICROSOFT SQL SERVER').INSTALLEDINSTANCES[0]

# If no server has been specified ask for input and ensure uppercase
if([string]::IsNullOrWhiteSpace($Server)){
    Write-Host "Please enter the target server name, do not include any instance names"
    [string]$Server = Read-Host -Prompt "Target Server Name"
}
$Server = $Server.ToUpper()
$Server = $Server -Replace '\s',''
If($Server.IndexOf("\") -gt 0) {
    $Server = $Server.Substring(0,$Server.IndexOf("\"))
}

# Start SQL Browser
sc.exe \\$Server config SQLBrowser start=auto
sc.exe \\$Server start SQLBrowser

# Get list of installed services
$Services = Get-Service -ComputerName $Server

# Extrapolate Installed Instances via remote registry read
$Registry = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine',"$Server")
$RegistryKey = $Registry.OpenSubKey("Software\Microsoft\Microsoft SQL Server")
[string[]]$Instances = $RegistryKey.GetValue("InstalledInstances")
Write-Host "$($Instances.Count) Instance(s) Found"

# Check if the server is clustered
$OSCluster = "Standalone"
if(($Services | Where-Object {$_.Name -like '*ClusSvc*' -and $_.Status -eq 'Running'} | Measure-Object).Count -gt 0){
    $OSCluster = "Clustered"
}

# Iterate through all instance names Outer Loop
ForEach($Instance in $Instances){
    Write-Host "Starting Discovery of $Instance"

    # Build discovery output script
    If($Flag -eq 1){
        $CMDSUFFIX = "$CMDSUFFIX or "
    }

    # Determine target instance name with default instance logic and service status
    If($Instance -eq 'MSSQLSERVER') {
        $TargetSQL="$Server"
        $ServiceName = "MSSQLSERVER"
    } Else {
        $TargetSQL= "$Server\$Instance" 
        $ServiceName = 'MSSQL$'+"$Instance"
    }
    $SQLStatus = $Services | Where-Object {$_.Name -eq $ServiceName} | Select StartType

    # If the OS is clustered check for SQL Virtual Names
    if($OSCluster -eq "Clustered") {
        $ResGroup = Get-ClusterResource -Cluster $Server | Where-Object {$_.Name -like "*$Instance*" -and $_.ResourceType -eq 'SQL Server'}
        $ResOwner = Get-ClusterResource -Cluster $Server | Where-Object {$_.Name -like "*$Instance*" -and $_.ResourceType -eq 'SQL Server'} | Get-ClusterOwnerNode
        $VName = Get-ClusterResource -Cluster $Server | Where-Object {$_.Ownergroup -eq $ResGroup.OwnerGroup -and $_.ResourceType -eq 'Network Name'}
        $Nodes = Get-ClusterNode -Cluster $Server | select name
        $VName.Name = $VName.Name.Replace("SQL Network Name (","")
        $VName.Name = $VName.Name.Replace(")","")
        if($Server -in $ResOwner.OwnerNodes) {
            Write-Host "Virtual Name $($VName.Name)"
            $TargetSQL = "$($VName.Name)\$Instance"
        }
    }

     # Clear existing data for the specific instance from the Discovery Database
     Invoke-Sqlcmd -ServerInstance $DBAServer -Query "delete from Discovery..Instance where InstanceName='$TargetSQL'"
     Invoke-Sqlcmd -ServerInstance $DBAServer -Query "delete from Discovery..Databases where InstanceName='$TargetSQL'"
     Invoke-Sqlcmd -ServerInstance $DBAServer -Query "delete from Discovery..DatabaseFiles where InstanceName='$TargetSQL'"
     Invoke-Sqlcmd -ServerInstance $DBAServer -Query "delete from Discovery..Jobs where InstanceName='$TargetSQL'"
     Invoke-Sqlcmd -ServerInstance $DBAServer -Query "delete from Discovery..Security where InstanceName='$TargetSQL'"
     Invoke-Sqlcmd -ServerInstance $DBAServer -Query "delete from Discovery..Remediation where InstanceName='$TargetSQL'"
     Invoke-Sqlcmd -ServerInstance $DBAServer -Query "delete from Discovery..SSIS where InstanceName='$TargetSQL'" 

    # If the service is disabled perform no further discovery and write out an entry to Instances with default data
    If($SQLStatus.StartType -eq "Disabled" -or $SQLStatus.StartType -eq "Stopped"){
        $TargetServerCollation = "N/A"
        $SQLEdition = "N/A"
        $SQLVersion = "Disabled"
        $SQLTextVersion = "Unknown"
        $FTInstalled   = "N/A" 
        $SSISInstalled = "N/A"
        $SSASInstalled = "N/A"
        $SSRSInstalled = "N/A"
        $SSASCollation = "N/A"    
        Write-Host "$Server SQL is Disabled"
    } Else {
        # Check for Vname, determine if this is a cluster
        $Cluster = "Standalone"
        $RegistryKey = $Registry.OpenSubKey("Software\Microsoft\Microsoft SQL Server\Instance Names\SQL\")
        $InstanceReg = $RegistryKey.GetValue($Instance)
        Write-Host "Instance Path $InstanceReg"

        # If windows is clustered check for SQL Failover Cluster
        if($OSCluster -eq "Clustered"){
            $Nodes = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "select * from sys.dm_os_cluster_nodes"
            if(($Nodes | Measure-Object).Count -gt 0){
                $Cluster = "FCI - " + $($Nodes.NodeName -join ",")
            } else {
                $HADR = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "Select ServerProperty('IsHADREnabled')"
                If($HADR.Column1 -ne 0) {
                    $Cluster = "AAG"
                }
            }
        }
    
        # Get XP_CMDSHELL Status and enable if not enabled
        $XPCMDStatus = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "sp_configure 'xp_cmdshell'"
        if($XPCMDStatus.run_value -ne 1) {
            Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "sp_configure 'xp_cmdshell',1"
            Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "reconfigure with override"
        }

        # Gather Instance Level Information
        $TargetServerCollation = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "Select ServerProperty('Collation')"
        $SQLEdition = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "Select ServerProperty('Edition')"
        $SQLVersion = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "Select ServerProperty('ProductVersion')"
        $SQLVersion = $SQLVersion.Column1.Substring(0,4)
        $SQLTextVersion = "Unknown"
        $FTInstalled   = "No"
        $SSISInstalled = "No"
        $SSASInstalled = "No"
        $SSRSInstalled = "No"
        $SSASCollation = "N/A"

        # Extrapolate SQL Version
        Switch ($SQLVersion) {
            "8.0." {$SQLTextVersion = "2000";break}
            "9.0." {$SQLTextVersion = "2005";break}
            "10.0" {$SQLTextVersion = "2008";break}
            "10.5" {$SQLTextVersion = "2008r2";break}
            "11.0" {$SQLTextVersion = "2012";break}
            "12.0" {$SQLTextVersion = "2014";break}
            "13.0" {$SQLTextVersion = "2016";break}
            "14.0" {$SQLTextVersion = "2017";break}
            "15.0" {$SQLTextVersion = "2019";break}
        }

        # Check Services
        $SSISStatus = $Services | Where-Object {$_.Name -like 'MSDTSServer*' -and $_.Status -eq 'Running'} | Measure-Object
        $FTStatus   = $Services | Where-Object {$_.Name -eq "MSSQLFDLauncher`$$Instance" -and $_.Status -eq 'Running'} | Measure-Object
        $SSASStatus = $Services | Where-Object {$_.Name -like 'MSOLAP*'} | Measure-Object
        $SSRSStatus = $Services | Where-Object {$_.Name -like 'ReportServer*'} | Measure-Object
        If($FTStatus.Count -eq 1)   {$FTInstalled = "Yes"}
        If($SSISStatus.Count -eq 1) {$SSISInstalled = "Yes"}
        If($SSASStatus.Count -eq 1) {$SSASInstalled = "Yes";$SSASCollation="Unknown"}
        If($SSRSStatus.Count -eq 1) {$SSRSInstalled = "Yes"}

        # Obtain Database, Database File List and Jobs
        if($SQLVersion -eq "12.0" -or $SQLVersion -eq "13.0" -or $SQLVersion -eq "14.0" -or $SQLVersion -eq "15.0"){
            $Databases = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "
                select DISTINCT sd.name, compatibility_level, collation_name,
                    (case when en.encryption_state is null then 'Unencrypted' else 'Encrypted' end) as Encryption,
                       (case when hdrs.is_primary_replica IS NULL then '' when exists
                              (select * from sys.dm_hadr_database_replica_states as irs where sd.database_id = irs.database_id and is_primary_replica = 1 ) then
                              'PRIMARY - ' else 'SECONDARY - ' end) + COALESCE(grp.ag_name,'No') as AAG,
                              'Rep' as Rep
                from sys.databases sd
                       left join sys.dm_database_encryption_keys en on db_id(sd.name) = en.database_id
                       left join sys.dm_hadr_database_replica_states as hdrs on hdrs.database_id = sd.database_id
                       left join sys.dm_hadr_name_id_map as grp on grp.ag_id = hdrs.group_id"
        } else {
            $Databases = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "
                select DISTINCT sd.name, compatibility_level, collation_name,
                    (case when en.encryption_state is null then 'Unencrypted' else 'Encrypted' end) as Encryption,
                       'No' as AAG,
                       'Rep' as Rep
                from sys.databases sd
                       left join sys.dm_database_encryption_keys en on db_id(sd.name) = en.database_id"
        }
        $DatabaseFiles = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "select DB_NAME(database_id) As DBName,name,type_desc,physical_name,size from sys.master_files"
        $Jobs = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "select name,enabled from msdb..sysjobs where name not like 'DBA_Admin%' and name not like 'Raise Tivoli%' and name <> 'syspolicy_purge_history' and name not like 'IBM DBA%' and name not like 'SQL Sentry%'"
        $SSISJobs = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "select j.name,js.* from msdb..sysjobsteps js inner join msdb..sysjobs j on js.job_id = j.job_id where subsystem = 'SSIS'"
        $SSISMSDB = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "select name from msdb..sysssispackages where description <> 'System Data Collector Package'"

        # Insert any SSIS Jobs into the Discovery Database
        Write-Host "Extrapolating SSIS Packages"
        ForEach ($Package in $SSISJobs){
            Invoke-Sqlcmd -ServerInstance $DBAServer -Query "insert into Discovery..SSIS (InstanceName,JobName,StepName,Command)
                Values ('$TargetSQL','$($Package.Name -replace '\$','#')','$($Package.Step_Name -replace '\$','#')','$($Package.Command -replace '\$','#')')"
        }

        ForEach ($Package in $SSISMSDB){
            Invoke-Sqlcmd -ServerInstance $DBAServer -Query "insert into Discovery..SSIS (InstanceName,JobName,StepName,Command)
                Values ('$TargetSQL','MSDB','$($Package.Name)','')"
        }

        # Insert the job details into the Discovery Database
        ForEach ($Job in $Jobs){
            Invoke-Sqlcmd -ServerInstance $DBAServer -Query "insert into Discovery..Jobs (InstanceName,JobName,Status)
                Values ('$TargetSQL','$($Job.Name -replace '\$','#')','$($Job.Enabled)')"
        }

        # Is distribution DB present for replication
        # $Replication = "No"
        # If($Databases.Name -contains "distribution"){$Replication = "Yes"}
        # Iterate through the database files and add them to the Discovery Database
        Write-Host "Updating DatabaseFiles"

        ForEach ($DBFile in $DatabaseFiles) {
            $TSQL = "declare @output as table (line nvarchar(512));declare @filesize as numeric(22,2);Insert Into @output execute master..xp_cmdshell 'for %I in (""$($DBFile.physical_name)"") do @echo %~zI';select @filesize = (select top 1 convert(decimal(22,2), line)from @output)/1024/1024/1024;select @filesize"
            $FileSize = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query $TSQL
            Invoke-Sqlcmd -ServerInstance $DBAServer -Query "insert into Discovery..DatabaseFiles (InstanceName,DatabaseName,FileName,FileType,Path,Size,FileSize)
                Values ('$TargetSQL','$($DBFile.DBName)','$($DBFile.Name)','$($DBFile.type_desc)','$($DBFile.physical_name)','$($DBFile.Size)','$($FileSize.Column1)')"
        }
        Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Update Discovery..DatabaseFiles Set FileSize = 0.01 where FileSize = 0.00"

        # Iterate through the database details and add them to the Discovery Database
        Write-Host "Updating Databases"
            ForEach ($Database in $Databases) {
            $DataSize = Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Select Sum(FileSize) from Discovery..DatabaseFiles where (InstanceName='$TargetSQL' and DatabaseName='$($Database.Name)' and FileType='ROWS')"
            $LogSize = Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Select Sum(FileSize) from Discovery..DatabaseFiles where (InstanceName='$TargetSQL' and DatabaseName='$($Database.Name)' and FileType='LOG')"
            # Check if database is a subscriber to replication package
                $Replication = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "select name from sys.databases where OBJECT_ID(name+'.dbo.msreplication_objects') is not null and name = '$($Database.Name)'"
                if ([String]::IsNullOrEmpty($Replication)) {
                        $Database.Rep = "No"
                    } else {
                        $Database.Rep = "Subscriber"
                }
            Invoke-Sqlcmd -ServerInstance $DBAServer -Query "insert into Discovery..Databases
                (InstanceName,DatabaseName,DatabaseCollation,DataFileSize,LogFileSize,DBCompatibilityLevel,TDEConfigured,HAStatus,ReplicationStatus)
                Values ('$TargetSQL','$($Database.Name)','$($Database.Collation_Name)',$($DataSize.Column1),$($LogSize.Column1),'$($Database.Compatibility_level)','$($Database.Encryption)','$($Database.AAG)','$($Database.Rep)')"
        }

        # Use collected data to summarise instance sizing
        Write-Host "Updating Instance Sizing"
        $DataSize = Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Select Sum(DataFileSize) From Discovery..Databases where (InstanceName='$TargetSQL' and DatabaseName<>'tempdb')"
        $LogSize = Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Select Sum(LogFileSize) From Discovery..Databases where (InstanceName='$TargetSQL' and DatabaseName<>'tempdb')"
        $DataSize = ($DataSize.Column1)
        $LogSize = ($LogSize.Column1)
        $TempDataSize = Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Select Sum(FileSize) from Discovery..DatabaseFiles where (InstanceName='$TargetSQL' and DatabaseName='tempdb' and FileType='ROWS')"
        $TempLogSize = Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Select Sum(FileSize) from Discovery..DatabaseFiles where (InstanceName='$TargetSQL' and DatabaseName='tempdb' and FileType='LOG')"
        $CombinedTempSize = ($TempDataSize.Column1+$TempLogSize.Column1)

        If($CombinedTempSize -lt 1) {$CombinedTempSize=1}

        Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Update Discovery..Instance Set DataFileSize=$DataSize,LogFileSize=$LogSize,TempFileSize=$CombinedTempSize where InstanceName='$TargetSQL'"

        # Extract Users and Server Roles
        Write-Host "Extracting User Information"
        $Users = Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "Select name,sysadmin,securityadmin,serveradmin,setupadmin,processadmin,diskadmin,dbcreator,bulkadmin from master..syslogins where (name <> 'sa' and name not like '##%' and name not like '%DLG_SQL_%' and name not like 'NT %')"
        ForEach ($User in $Users) {
            Invoke-Sqlcmd -ServerInstance $DBAServer -Query "
                Insert into Discovery..Security (InstanceName,SecurityName,Sysadmin,securityadmin,serveradmin,setupadmin,processadmin,diskadmin,dbcreator,bulkadmin)
                Values ('$TargetSQL','$($User.Name)','$($User.sysadmin)','$($User.securityadmin)','$($User.Serveradmin)','$($User.SetupAdmin)','$($User.ProcessAdmin)','$($User.DiskAdmin)','$($User.DBCreator)','$($User.BulkAdmin)')"
        }

        # Check instance for known remediation items
        # Check authentication mode
        $RegistryKey = $Registry.OpenSubKey("Software\Microsoft\Microsoft SQL Server\$InstanceReg\MSSQLServer")
        $AuthMode = $RegistryKey.GetValue("LoginMode")
        If($AuthMode -ne 1) {Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Insert into Discovery..Remediation (InstanceName, Item) Values ('$TargetSQL','Mixed authentication mode used')"}

        # Check for non-DBA Sysadmin
        $Sysadmin = Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Select Count(*) from Discovery..Security where (InstanceName='$TargetSQL' and SysAdmin=1)"
        If($Sysadmin.Column1 -ne 0) {Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Insert into Discovery..Remediation (InstanceName, Item) Values ('$TargetSQL','Non-DBAs in Sysadmin')"}

        # Disable XPCMDShell if it was enabled, flag if it was already enabled
        if($XPCMDStatus.run_value -eq 0) {
            Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "sp_configure 'xp_cmdshell',0"
            Invoke-Sqlcmd -ServerInstance $TargetSQL -Query "reconfigure with override"
        } else {
            Invoke-Sqlcmd -ServerInstance $DBAServer -Query "Insert into Discovery..Remediation (InstanceName, Item) Values ('$TargetSQL','XP_CMDShell enabled')"
        }
    }

    # Insert the new instance details into the Discovery Database
        Invoke-Sqlcmd -ServerInstance $DBAServer -Query "insert into Discovery..Instance (InstanceName,ServerCollation,Edition,SSASInstalled,SSASCollation,SSRSInstalled,SSISInstalled,LastScanDate,Version,IsClustered,FTInstalled,Domain)
            Values ('$TargetSQL','$($TargetServerCollation.Column1)','$($SQLEdition.Column1)','$SSASInstalled','$SSASCollation','$SSRSInstalled','$SSISInstalled',getdate(),'$SQLTextVersion','$Cluster','$FTInstalled','$Domain')"

    Write-Host "$TargetSQL Discovery Completed"

    $CMDSUFFIX = $CMDSUFFIX + "InstanceName = '" + $TargetSQL + "'"
    $Flag = 1
}

$Output = "Select InstanceName,'',Domain,IsClustered,[Version],Edition,ServerCollation,SSASInstalled,SSASCollation,`nSSRSInstalled,FTInstalled,SSISInstalled,DataFileSize,LogFileSize,TempFileSize from Discovery..Instance where `n$CMDSUFFIX"
$Output = $Output + "`nSelect InstanceName,DatabaseName,'',DatabaseCollation as 'Database Collation',HAStatus,ReplicationStatus,`nTDEConfigured as 'Encryption',"
$Output = $Output + "`nLogFileSize as 'Combined Log File Size (Gb)',DataFileSize as 'Combined Data File Size (Gb)',DBCompatibilityLevel from Discovery..databases where `n$CMDSUFFIX"
$Output = $Output + "`nSelect InstanceName,SecurityName,'',Sysadmin,SecurityAdmin,ServerAdmin,SetupAdmin,ProcessAdmin,DiskAdmin,DBCreator,BulkAdmin From Discovery..Security where `n$CMDSUFFIX"
$Output = $Output + "`nSelect InstanceName,'',JobName,Status from Discovery..Jobs where $CMDSuffix"
$Output = $Output + "`nSelect InstanceName,'',JobName,StepName,Command From Discovery..SSIS where $CMDSuffix"
$Output = $Output + "`nSelect * from Discovery..Remediation where $CMDSuffix"
Set-Clipboard -Value $Output

Write-Host "Select InstanceName,'',Domain,IsClustered,[Version],Edition,ServerCollation,SSASInstalled,SSASCollation,`nSSRSInstalled,FTInstalled,SSISInstalled,DataFileSize,LogFileSize,TempFileSize from Discovery..Instance where `n$CMDSUFFIX" -ForegroundColor Cyan
Write-Host "Select InstanceName,DatabaseName,'',DatabaseCollation as 'Database Collation',HAStatus,ReplicationStatus,`nTDEConfigured as 'Encryption'," -ForegroundColor Cyan
Write-Host "LogFileSize as 'Combined Log File Size (Gb)',DataFileSize as 'Combined Data File Size (Gb)',DBCompatibilityLevel from Discovery..databases where `n$CMDSUFFIX" -ForegroundColor Cyan
Write-Host "Select InstanceName,SecurityName,'',Sysadmin,SecurityAdmin,ServerAdmin,SetupAdmin,ProcessAdmin,DiskAdmin,DBCreator,BulkAdmin From Discovery..Security where `n$CMDSUFFIX" -ForegroundColor Cyan
Write-Host "Select InstanceName,'',JobName,Status from Discovery..Jobs where $CMDSuffix" -ForegroundColor Cyan
Write-Host "Select InstanceName,'',JobName,StepName,Command From Discovery..SSIS where $CMDSuffix" -ForegroundColor Cyan
Write-Host "Select * from Discovery..Remediation where $CMDSuffix" -ForegroundColor Cyan 


$ProductName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName).ProductName
