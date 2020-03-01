#This script is created to make your environment ready for SQL Server + DSC + dbatools ready


#Check if the current session is admin or not, as we require admin account

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(!($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))
    {
        Write-Host "You are not currently running under admin right click PowerShell icon and run it as administrator"
        return
        }

#We will install SQL Server module if not already installed
if(Get-Module -ListAvailable -Name SQLSERVER)
    {
        Write-Host "SQL Server module already installed, way to go!"
        }
else
    {
        Write-Host "Installing SQL Server module"
        Install-Module Sqlserver -Force -AllowClobber
        Write-Host "SQLServer module installed"
        }


#We will install dbatools if not already installed
if(Get-Module -ListAvailable -Name dbatools)
    {
        Write-Host "Dbatools module is already installed moving to next.."
        }
else
    {
        Write-Host "Installing dbatools"
        Install-Module dbatools -Force -AllowClobber
        Write-Host "dbatools modules installed"
        }

#We will install SQL Server DSC if not already installed
if(Get-Module -ListAvailable -Name SqlServerDsc)
    {
        Write-Host "SqlServerDsc module is already installed.."
        }
else
    {
        Write-Host "Installing SqlServerDsc"
        Install-Module SqlServerDsc -Force -AllowClobber
        Write-Host "SQLServerDsc modules installed"
        }

#We will require to set execution policy changed to either Remotesigned if running self developed scripts or Unrestricted to allow anything to run

$currentexecpol = Get-ExecutionPolicy
if($currentexecpol -eq 'Unrestricted' -or $currentexecpol -eq "RemoteSigned")
    {
        Write-Host "Policy is already set to $currentexecpol"
        }
else
    {
        Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Force
        }
