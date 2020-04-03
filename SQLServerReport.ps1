
$npserverlist = 'C:\\serversnpa.csv'    #Location of non production servers csv
$pserverlist ='C:\\serversp.csv'        #Location of production server csv
$sharedlocation = "\\Location\Reports"  #Remote location of report excel files
$todays = get-date -Format "MM-dd-yyyy" #Date today
$reportpath = "C:\Users\c-singhsh\Desktop\Daily Report\DailyReport-$todays.xlsx"  #Local location for Excell report

#Import-Module dbatools
#Import-Module ImportExcel

Move-Item -Path "$sharedlocation\.\*.xlsx" -Destination "$sharedlocation\archive"

#Production servers

$serversp = Import-Csv -Path $pserverlist

Foreach ($serverp in $serversp)
{

#Check for connection error and put it into the Unavailable servers worksheet of our sheet
$serverpname = ($serverp).servers
If(!(Test-Connection -ComputerName ($serverpname.Split('\')[0]) -Quiet -Count 1)) 
        {        
        $var= "Could not connect to Server $($serverpname.Split('\')[0])" | Export-Excel -Path $reportpath -WorksheetName ConnectionError -Append -TableName Unavailable_servers -AutoSize 
        }

Else {

    Write-Host "Working on Server $serverpname"

    #Database status for all the servers

    $statusquery = "SELECT @@servername as Server_Name,name as Database_Name,state_desc as Status
                    FROM sys.databases 
                    WHERE state_desc != 'ONLINE'"

    Invoke-Sqlcmd  -ServerInstance $serverp.servers -Query $statusquery | 
                    Select-Object Server_Name, Database_Name,Status | 
                    Export-Excel -Path $reportpath -WorksheetName DatabaseStatus_All -Append -TableName Database_status -AutoSize

    #memory details

    $memoryquery = "SELECT @@servername as Server_Name, physical_memory_in_use_kb/1024 AS [SQL_Server_Memory_Usage],memory_utilization_percentage, process_physical_memory_low, process_virtual_memory_low 
                    FROM sys.dm_os_process_memory 
                    WITH (NOLOCK) OPTION (RECOMPILE)"

    Invoke-Sqlcmd  -ServerInstance $serverp.servers -Query $memoryquery | 
                    Select-Object Server_Name, SQL_Server_Memory_Usage,memory_utilization_percentage, process_physical_memory_low, process_virtual_memory_low | 
                    Export-Excel -Path $reportpath -WorksheetName MemoryStatus_P -Append -TableName Memory_status_P -AutoSize

    #log space usage

    $logspacequery = "IF OBJECT_ID('Tempdb..#logsize','U') IS NOT NULL DROP TABLE tempdb..#logsizereport
                        CREATE TABLE #logsizereport (Database_name varchar(200), Log_size_MB int, Log_Space_used_pct int, Status int)
                        INSERT INTO #logsizereport
                        EXECUTE('Dbcc sqlperf(logspace)')

                        SELECT @@servername as Server_Name, Database_name, Log_size_MB, Log_Space_used_pct FROM  #logsizereport
                        DROP TABLE #logsizereport"

    Invoke-Sqlcmd  -ServerInstance $serverp.servers -Query $logspacequery | 
                    Select-Object Server_Name,Database_name, Log_size_MB, Log_Space_used_pct| 
                    Export-Excel -Path $reportpath -WorksheetName LogSpace_P -Append -TableName Log_Space_P -AutoSize
 
    #Blocking Details

    $blockingquery = "SELECT @@Servername as Server_Name, DB_NAME(resource_database_id) AS [Database_Name], t1.request_session_id AS [Waiter_Sid], (t2.wait_duration_ms/1000) AS [Wait_Time],  
                        (SELECT [text] FROM sys.dm_exec_requests AS r WITH (NOLOCK)  
                            CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) 
                            WHERE r.session_id = t1.request_session_id) AS [Waiter_Batch],
                        (SELECT SUBSTRING(qt.[text],r.statement_start_offset/2, 
                            (CASE WHEN r.statement_end_offset = -1 
                            THEN LEN(CONVERT(nvarchar(max), qt.[text])) * 2 
                            ELSE r.statement_end_offset END - r.statement_start_offset)/2) 
                            FROM sys.dm_exec_requests AS r WITH (NOLOCK)
                            CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) AS qt
                            WHERE r.session_id = t1.request_session_id) AS [Waiter_Stmt],	
                        t2.blocking_session_id AS [Blocker_Sid],								
                        (SELECT [text] FROM sys.sysprocesses AS p									
                            CROSS APPLY sys.dm_exec_sql_text(p.[sql_handle]) 
                            WHERE p.spid = t2.blocking_session_id) AS [Blocker_Batch]
                    FROM sys.dm_tran_locks AS t1 WITH (NOLOCK)
                    INNER JOIN sys.dm_os_waiting_tasks AS t2 WITH (NOLOCK)
                    ON t1.lock_owner_address = t2.resource_address OPTION (RECOMPILE);"
       
    Invoke-Sqlcmd  -ServerInstance $serverp.servers -Query $blockingquery | 
                    Select-Object Server_Name,Database_name, Waiter_Sid, Wait_Time, Waiter_Batch, Waiter_Stmt, Blocker_Sid, Blocker_Batch | 
                    Export-Excel -Path $reportpath -WorksheetName BlockingDetails_P -Append  -AutoSize
    
    #I/O Latency

    $iolatencyquery = "CREATE TABLE #IOWarningResults(LogDate datetime, ProcessInfo sysname, LogText nvarchar(1000));

	                    INSERT INTO #IOWarningResults 
	                    EXEC xp_readerrorlog 0, 1, N'taking longer than 15 seconds';

	                    INSERT INTO #IOWarningResults 
	                    EXEC xp_readerrorlog 1, 1, N'taking longer than 15 seconds';

                        SELECT @@Servername as Server_Name, LogDate, ProcessInfo, LogText
                        FROM #IOWarningResults
                        ORDER BY LogDate DESC;

                        DROP TABLE #IOWarningResults;"
       
    Invoke-Sqlcmd  -ServerInstance $serverp.servers -Query $iolatencyquery | 
                    Select-Object Server_Name,LogDate,ProcessInfo, LogText | 
                    Export-Excel -Path $reportpath -WorksheetName IOLatencyDetails_P -Append -TableName IOLatency_detailp -AutoSize 
    
    #Failed Logins

    $failedloginquery = "SET NOCOUNT ON

                           DECLARE @ErrorLogCount INT 
                           DECLARE @LastLogDate DATETIME

                           DECLARE @ErrorLogInfo TABLE (
                               LogDate DATETIME
                              ,ProcessInfo NVARCHAR (50)
                              ,[Text] NVARCHAR (MAX)
                              )
   
                           DECLARE @EnumErrorLogs TABLE (
                               [Archive#] INT
                              ,[Date] DATETIME
                              ,LogFileSizeMB INT
                              )

                           INSERT INTO @EnumErrorLogs
                            EXEC sp_enumerrorlogs

                           SELECT @ErrorLogCount = MIN([Archive#]), @LastLogDate = MAX([Date])
                            FROM @EnumErrorLogs

                           WHILE @ErrorLogCount IS NOT NULL
                            BEGIN

                              INSERT INTO @ErrorLogInfo
                              EXEC sp_readerrorlog @ErrorLogCount

                              SELECT @ErrorLogCount = MIN([Archive#]), @LastLogDate = MAX([Date])
                              FROM @EnumErrorLogs
                              WHERE [Archive#] > @ErrorLogCount
                              AND @LastLogDate > getdate() - 1
  
                            END

                           -- List failed logins count of attempts and the Login failure message
                           SELECT @@servername as Server_Name, COUNT (Text) AS NumberOfAttempts, Text AS Details, MIN(LogDate) as MinLogDate, MAX(LogDate) as MaxLogDate
                            FROM @ErrorLogInfo
                            WHERE ProcessInfo = 'Logon'
                              AND Text LIKE '%fail%'
                              AND LogDate > getdate() - 1
                            GROUP BY Text
                            ORDER BY NumberOfAttempts DESC

                         SET NOCOUNT OFF"

     Invoke-Sqlcmd  -ServerInstance $serverp.servers -Query $failedloginquery | 
                    Select-Object Server_Name,NumberOfAttempts,Details,MinLogDate,MaxLogDate | 
                    Export-Excel -Path $reportpath -WorksheetName LoginFailures_P -Append -TableName Login_Failuresp -AutoSize

    #Disk utlization details

    $diskutilquery = "SELECT DISTINCT @@Servername as Server_Name, 
                          vs.volume_mount_point AS [Drive],
                          vs.logical_volume_name AS [Drive_Name],
                          vs.total_bytes/1024/1024/1024 AS [Drive_Size_GB],
                          vs.available_bytes/1024/1024/1024 AS [Drive_Free_Space_GB]
                        FROM sys.master_files AS f
                        CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id) AS vs
                        ORDER BY vs.volume_mount_point;"

    Invoke-Sqlcmd  -ServerInstance $serverp.servers -Query $diskutilquery | 
                    Select-Object Server_Name,Drive, Drive_Name, Drive_Size_GB, Drive_Free_Space_GB | 
                    Export-Excel -Path $reportpath -WorksheetName DiskUtilization_P -Append -TableName Disk_Utilizationp -AutoSize
    }

}

$servers = Import-Csv -Path $npserverlist

#$servers = ('vmindbu01','ppppp')

Foreach ($server in $servers)
{

#Check for connection error and put it into the Unavailable servers worksheet of our sheet
$servername = ($server).servers
If(!(Test-Connection -ComputerName ($servername.Split('\')[0]) -Quiet -Count 1)) 
        {        
        $var= "Could not connect to Server $($servername.Split('\')[0])" | Export-Excel -Path $reportpath -WorksheetName ConnectionError -Append -TableName Unavailable_servers -AutoSize 
        }

Else {

    Write-Host "Working on Server $servername"

    #Database status for all the servers

    $statusquery = "SELECT @@servername as Server_Name,name as Database_Name,state_desc as Status
                    FROM sys.databases 
                    WHERE state_desc != 'ONLINE'"

    Invoke-Sqlcmd  -ServerInstance $server.servers -Query $statusquery | 
                    Select-Object Server_Name, Database_Name,Status | 
                    Export-Excel -Path $reportpath -WorksheetName DatabaseStatus_All -Append -TableName Database_status -AutoSize

    #memory details

    $memoryquery = "SELECT @@servername as Server_Name, physical_memory_in_use_kb/1024 AS [SQL_Server_Memory_Usage],memory_utilization_percentage, process_physical_memory_low, process_virtual_memory_low 
                    FROM sys.dm_os_process_memory 
                    WITH (NOLOCK) OPTION (RECOMPILE)"

    Invoke-Sqlcmd  -ServerInstance $server.servers -Query $memoryquery | 
                    Select-Object Server_Name, SQL_Server_Memory_Usage,memory_utilization_percentage, process_physical_memory_low, process_virtual_memory_low | 
                    Export-Excel -Path $reportpath -WorksheetName MemoryStatus_NP -Append -TableName Memory_status_NP -AutoSize

    #log space usage

    $logspacequery = "IF OBJECT_ID('Tempdb..#logsize','U') IS NOT NULL DROP TABLE tempdb..#logsizereport
                        CREATE TABLE #logsizereport (Database_name varchar(200), Log_size_MB int, Log_Space_used_pct int, Status int)
                        INSERT INTO #logsizereport
                        EXECUTE('Dbcc sqlperf(logspace)')

                        SELECT @@servername as Server_Name, Database_name, Log_size_MB, Log_Space_used_pct FROM  #logsizereport
                        DROP TABLE #logsizereport"

    Invoke-Sqlcmd  -ServerInstance $server.servers -Query $logspacequery | 
                    Select-Object Server_Name,Database_name, Log_size_MB, Log_Space_used_pct| 
                    Export-Excel -Path $reportpath -WorksheetName LogSpace_NP -Append -TableName Log_Space_NP -AutoSize
 
    #Blocking Details

    $blockingquery = "SELECT @@Servername as Server_Name, DB_NAME(resource_database_id) AS [Database_Name], t1.request_session_id AS [Waiter_Sid], (t2.wait_duration_ms/1000) AS [Wait_Time],  
                        (SELECT [text] FROM sys.dm_exec_requests AS r WITH (NOLOCK)  
                            CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) 
                            WHERE r.session_id = t1.request_session_id) AS [Waiter_Batch],
                        (SELECT SUBSTRING(qt.[text],r.statement_start_offset/2, 
                            (CASE WHEN r.statement_end_offset = -1 
                            THEN LEN(CONVERT(nvarchar(max), qt.[text])) * 2 
                            ELSE r.statement_end_offset END - r.statement_start_offset)/2) 
                            FROM sys.dm_exec_requests AS r WITH (NOLOCK)
                            CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) AS qt
                            WHERE r.session_id = t1.request_session_id) AS [Waiter_Stmt],	
                        t2.blocking_session_id AS [Blocker_Sid],								
                        (SELECT [text] FROM sys.sysprocesses AS p									
                            CROSS APPLY sys.dm_exec_sql_text(p.[sql_handle]) 
                            WHERE p.spid = t2.blocking_session_id) AS [Blocker_Batch]
                    FROM sys.dm_tran_locks AS t1 WITH (NOLOCK)
                    INNER JOIN sys.dm_os_waiting_tasks AS t2 WITH (NOLOCK)
                    ON t1.lock_owner_address = t2.resource_address OPTION (RECOMPILE);"
       
    Invoke-Sqlcmd  -ServerInstance $server.servers -Query $blockingquery | 
                    Select-Object Server_Name,Database_name, Waiter_Sid, Wait_Time, Waiter_Batch, Waiter_Stmt, Blocker_Sid, Blocker_Batch | 
                    Export-Excel -Path $reportpath -WorksheetName BlockingDetails_NP -Append  -AutoSize
    
    #I/O Latency

    $iolatencyquery = "CREATE TABLE #IOWarningResults(LogDate datetime, ProcessInfo sysname, LogText nvarchar(1000));

	                    INSERT INTO #IOWarningResults 
	                    EXEC xp_readerrorlog 0, 1, N'taking longer than 15 seconds';

	                    INSERT INTO #IOWarningResults 
	                    EXEC xp_readerrorlog 1, 1, N'taking longer than 15 seconds';

                        SELECT @@Servername as Server_Name, LogDate, ProcessInfo, LogText
                        FROM #IOWarningResults
                        ORDER BY LogDate DESC;

                        DROP TABLE #IOWarningResults;"
       
    Invoke-Sqlcmd  -ServerInstance $server.servers -Query $iolatencyquery | 
                    Select-Object Server_Name,LogDate,ProcessInfo, LogText | 
                    Export-Excel -Path $reportpath -WorksheetName IOLatencyDetails_NP -Append -AutoSize 
    
    #Failed Logins

    $failedloginquery = "SET NOCOUNT ON

                           DECLARE @ErrorLogCount INT 
                           DECLARE @LastLogDate DATETIME

                           DECLARE @ErrorLogInfo TABLE (
                               LogDate DATETIME
                              ,ProcessInfo NVARCHAR (50)
                              ,[Text] NVARCHAR (MAX)
                              )
   
                           DECLARE @EnumErrorLogs TABLE (
                               [Archive#] INT
                              ,[Date] DATETIME
                              ,LogFileSizeMB INT
                              )

                           INSERT INTO @EnumErrorLogs
                            EXEC sp_enumerrorlogs

                           SELECT @ErrorLogCount = MIN([Archive#]), @LastLogDate = MAX([Date])
                            FROM @EnumErrorLogs

                           WHILE @ErrorLogCount IS NOT NULL
                            BEGIN

                              INSERT INTO @ErrorLogInfo
                              EXEC sp_readerrorlog @ErrorLogCount

                              SELECT @ErrorLogCount = MIN([Archive#]), @LastLogDate = MAX([Date])
                              FROM @EnumErrorLogs
                              WHERE [Archive#] > @ErrorLogCount
                              AND @LastLogDate > getdate() - 1
  
                            END

                           -- List failed logins count of attempts and the Login failure message
                           SELECT @@servername as Server_Name, COUNT (Text) AS NumberOfAttempts, Text AS Details, MIN(LogDate) as MinLogDate, MAX(LogDate) as MaxLogDate
                            FROM @ErrorLogInfo
                            WHERE ProcessInfo = 'Logon'
                              AND Text LIKE '%fail%'
                              AND LogDate > getdate() - 1
                            GROUP BY Text
                            ORDER BY NumberOfAttempts DESC

                         SET NOCOUNT OFF"

     Invoke-Sqlcmd  -ServerInstance $server.servers -Query $failedloginquery | 
                    Select-Object Server_Name,NumberOfAttempts,Details,MinLogDate,MaxLogDate | 
                    Export-Excel -Path $reportpath -WorksheetName LoginFailures_NP -Append -AutoSize

    #Disk utlization details

    $diskutilquery = "SELECT DISTINCT @@Servername as Server_Name, 
                          vs.volume_mount_point AS [Drive],
                          vs.logical_volume_name AS [Drive_Name],
                          vs.total_bytes/1024/1024/1024 AS [Drive_Size_GB],
                          vs.available_bytes/1024/1024/1024 AS [Drive_Free_Space_GB]
                        FROM sys.master_files AS f
                        CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id) AS vs
                        ORDER BY vs.volume_mount_point;"

    Invoke-Sqlcmd  -ServerInstance $server.servers -Query $diskutilquery | 
                    Select-Object Server_Name,Drive, Drive_Name, Drive_Size_GB, Drive_Free_Space_GB | 
                    Export-Excel -Path $reportpath -WorksheetName DiskUtilization_NP -Append -TableName Disk_Utilization -AutoSize
    }

}

Copy-Item $reportpath -Destination $sharedlocation
