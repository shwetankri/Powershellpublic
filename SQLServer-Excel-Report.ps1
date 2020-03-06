#Change the location of path to a csv containing your server list
$servers = Import-Csv -Path 'C:\Servers\serversnp.csv'
 
Foreach ($server in $servers)
{
 
#Database status for all the servers

#The below query will run on all the servers
$statusquery = "Select name,state_desc from sys.databases where state_desc != 'ONLINE'"

$It will create the dailytest excel sheet. Report directory should already exist
Invoke-Sqlcmd  -ServerInstance $server.servers -Query $statusquery | Select-Object name,state_desc| Export-Excel -Path 'C:\Report\dailytest.xlsx' -WorksheetName Sheet3 -Append -TableName Database_status3 -AutoSize
 
}

#This is just a template, no exception handling or Test-connection is used. Modify and append as per your usage.
