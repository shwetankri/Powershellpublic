############################################################
############################################################
############################################################

#DECLARING VARIABLES

$ResourceGroupSource = ""
$ResourceGroupDestination = ""
$AKVName = "" #Required to store the secrets for creating credentials
$AutomationAccountNameSource = ""
$AutomationAccountNameDest = ""
$LocalLocation = ""
$SubscriptionName = ""
$AutomationAccountDestADName = $AutomationAccountNameDest + "_AD"
$AutomationAccountPassword = (New-Guid).Guid

$ResourceGroup = $ResourceGroupDestination
$AutomationAccountName = $AutomationAccountNameDest
$ApplicationDisplayName =$AutomationAccountDestADName
$SelfSignedCertPlainPassword = $AutomationAccountPassword
$SelfSignedCertNoOfMonthsUntilExpired = 12

############################################################
############################################################
############################################################

#Getting the Subscription details


$SubscriptionObject = Get-AzSubscription | Where-Object name -EQ $SubscriptionName
$SubscriptionId = $SubscriptionObject.Id

############################################################
############################################################
############################################################

<# FROM SOURCE #>

############################################################

# 1. Exporting the Auotmation Runbooks


$AutomationAccountTemp=Get-AzAutomationRunbook -AutomationAccountName $AutomationAccountNameSource -ResourceGroupName $ResourceGroupSource

Write-Host "STEP 1: Exporting Runbooks to $LocalLocation" -ForegroundColor Blue -BackGroundColor White

FOREACH ($Runbook in $Automationaccounttemp)
    {
    Export-AzAutomationRunbook -ResourceGroupName $ResourceGroupSource -AutomationAccountName $AutomationAccountNameSource -Name $runbook.Name -OutputFolder $LocalLocation
    }


############################################################

# 2. Getting the PowerShell modules from source
# We require these for the PowerShell runbooks to run successfully

Write-Host "STEP 2: Exporting the Module details from Automation Account" -ForegroundColor Blue -BackGroundColor White
$SourceModules = Get-AzAutomationModule -ResourceGroupName $ResourceGroupSource -AutomationAccountName $AutomationAccountNameSource


############################################################
############################################################
############################################################

<# To DESTINATION #>

############################################################

# 3. Creating the new Automation Account

Write-Host "STEP 3: Creating Automation Account" -ForegroundColor Blue -BackGroundColor White

$AutomationDestinationCreated = New-AzAutomationAccount -Name $AutomationAccountNameDest -Location 'East US' -ResourceGroupName $ResourceGroupDestination


############################################################

# 4. Importing Runbooks exported in step 1

Write-Host "STEP 4: Importing Runbooks exported in the previous step" -ForegroundColor Blue -BackGroundColor White
$RunbookExport = Get-ChildItem -Path $LocalLocation | Where-Object Name -NotLike *.graphrunbook


FOREACH ($file in $RunbookExport) #Looping through all the Runbooks exported in step 1 and creating them in Destination
    {
    #$file.FullName
    $ImportedRunbook = Import-AzAutomationRunbook -AutomationAccountName $AutomationAccountNameDest -Path $file.FullName -Published -ResourceGroupName $ResourceGroupDestination -Type PowerShell
    }

############################################################

# 5. Creating Run As Account

#Function to Create Certificate
Write-Host "STEP 5: Creating Run As Account" -ForegroundColor Blue -BackGroundColor White
function CreateSelfSignedCertificate([string] $certificateName, [string] $selfSignedCertPlainPassword,
    [string] $certPath, [string] $certPathCer, [string] $selfSignedCertNoOfMonthsUntilExpired ) {
    
    #Creating Self signed certificate on the local system

    $Cert = New-SelfSignedCertificate -DnsName $certificateName -CertStoreLocation cert:\LocalMachine\My -KeyExportPolicy Exportable -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider" -NotAfter (Get-Date).AddMonths($selfSignedCertNoOfMonthsUntilExpired) -HashAlgorithm SHA256
    $CertPassword = ConvertTo-SecureString $selfSignedCertPlainPassword -AsPlainText -Force

    #Exporting the Certificate to the local Temp folder. It will be imported in the later steps
    Export-PfxCertificate -Cert ("Cert:\localmachine\my\" + $Cert.Thumbprint) -FilePath $certPath -Password $CertPassword -Force | Write-Verbose
    Export-Certificate -Cert ("Cert:\localmachine\my\" + $Cert.Thumbprint) -FilePath $certPathCer -Type CERT | Write-Verbose
}	

#Function to create Azure AD Application, Credential and the AD Service Principal
function CreateServicePrincipal([System.Security.Cryptography.X509Certificates.X509Certificate2] $PfxCert, [string] $applicationDisplayName) {
    $keyValue = [System.Convert]::ToBase64String($PfxCert.GetRawCertData())
    
    $keyId = (New-Guid).Guid #Creating Random GUID for Key ID

    #Creating New Application
    $Application = New-AzADApplication -DisplayName $ApplicationDisplayName -HomePage ("http://" + $applicationDisplayName) -IdentifierUris ("http://" + $keyId)

    #Creating Credential for the Application
    $ApplicationCredential = New-AzADAppCredential -ApplicationId $Application.ApplicationId -CertValue $keyValue -StartDate $PfxCert.NotBefore -EndDate $PfxCert.NotAfter
    
    #Creating Service Principal for the Application created above
    $ServicePrincipal = New-AzADServicePrincipal -ApplicationId $Application.ApplicationId
    $GetServicePrincipal = Get-AzADServicePrincipal -ObjectId $ServicePrincipal.Id

    # Sleep here for a few seconds to allow the service principal application to become active (ordinarily takes a few seconds)
    Sleep -s 15

    #Assigning the Contributor Permission to the Service Principal
    #To limit the permissions assigned to the Automation Account change the -RoleDefinitionName

    $NewRole = New-AzRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName $Application.ApplicationId -ErrorAction SilentlyContinue
    $Retries = 0;
    While ($NewRole -eq $null -and $Retries -le 6) {
        Sleep -s 10
        try {
        New-AzRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName $Application.ApplicationId | Write-Verbose -ErrorAction SilentlyContinue
        $NewRole = Get-AzRoleAssignment -ServicePrincipalName $Application.ApplicationId -ErrorAction SilentlyContinue
        }
        Catch {Write-Host "Provided the Contributor Role to Service Principal" -ForegroundColor Blue -BackGroundColor White}
        $Retries++;
    }
    return $Application.ApplicationId.ToString();
}

#Function to create Automation Account Certificate
function CreateAutomationCertificateAsset ([string] $resourceGroup, [string] $AutomationAccountName, [string] $certifcateAssetName, [string] $certPath, [string] $certPlainPassword, [Boolean] $Exportable) {
    $CertPassword = ConvertTo-SecureString $certPlainPassword -AsPlainText -Force

    #Creating Certificate for Run As Account
    New-AzAutomationCertificate -ResourceGroupName $resourceGroup -AutomationAccountName $AutomationAccountName -Path $certPath -Name $certifcateAssetName -Password $CertPassword -Exportable:$Exportable | write-verbose
}	

#Function to create connection between Automation Account and AD Application
function CreateAutomationConnectionAsset ([string] $resourceGroup, [string] $AutomationAccountName, [string] $connectionAssetName, [string] $connectionTypeName, [System.Collections.Hashtable] $connectionFieldValues ) {
    
    New-AzAutomationConnection -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccountName -Name $connectionAssetName -ConnectionTypeName $connectionTypeName -ConnectionFieldValues $connectionFieldValues
}	

#Selecting the Subscription where Automation Account Exists

$SelectingAzSubscription = Select-AzSubscription -Subscription $SubscriptionName

#Importing Az.Automation account 
Import-Module Az.Automation

Enable-AzureRmAlias

#Setting Context for Script
$Subscription = Get-AzSubscription -SubscriptionId $SubscriptionId | Set-AzContext 

#Declaring Varibales that will be used to create Certificate, Service Principal and Application
$CertifcateAssetName = "AzureRunAsCertificate"
$ConnectionAssetName = "AzureRunAsConnection"
$ConnectionTypeName = "AzureServicePrincipal"

$CertificateName = $AutomationAccountName + $CertifcateAssetName
$PfxCertPathForRunAsAccount = Join-Path $env:TEMP ($CertificateName + ".pfx")

$PfxCertPlainPasswordForRunAsAccount = $SelfSignedCertPlainPassword
$CerCertPathForRunAsAccount = Join-Path $env:TEMP ($CertificateName + ".cer")

#Creating Self Signed Certificate

CreateSelfSignedCertificate $CertificateName $PfxCertPlainPasswordForRunAsAccount $PfxCertPathForRunAsAccount $CerCertPathForRunAsAccount  $SelfSignedCertNoOfMonthsUntilExpired

# Create a new service principal
$PfxCert = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @($PfxCertPathForRunAsAccount,  $PfxCertPlainPasswordForRunAsAccount)
$ApplicationId = CreateServicePrincipal $PfxCert $ApplicationDisplayName


# Create the Automation certificate asset
CreateAutomationCertificateAsset $ResourceGroup $AutomationAccountName $CertifcateAssetName $PfxCertPathForRunAsAccount  $PfxCertPlainPasswordForRunAsAccount $true

# Populate the ConnectionFieldValues
$SubscriptionInfo = Get-AzSubscription -SubscriptionId $SubscriptionId
$TenantID = $SubscriptionInfo | Select TenantId -First 1
$Thumbprint = $PfxCert.Thumbprint
$ConnectionFieldValues = @{"ApplicationId" = $ApplicationId; "TenantId" = $TenantID.TenantId; "CertificateThumbprint" = $Thumbprint; "SubscriptionId" = $SubscriptionId}

# Create an Automation connection asset named AzureRunAsConnection in the Automation account. This connection uses the service principal.
CreateAutomationConnectionAsset $ResourceGroup $AutomationAccountName $ConnectionAssetName $ConnectionTypeName $ConnectionFieldValues	

############################################################

# 6. Creating Credential in Automation Account from AKV Secret

#We cannot export password from Azure Automation
#Need to include AKV

Write-Host "STEP 6: Creating Credential in Automation Account from Key Vault" -ForegroundColor Blue -BackGroundColor White

$secrets = Get-AzKeyVaultSecret -VaultName $AKVName 

FOREACH($secret in $secrets)
{
    $secrettemp = Get-AzKeyVaultSecret -VaultName $AKVName -Name $secret.Name

    $ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secrettemp.SecretValue)
    try {
       $secretValueText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)
    } finally {
       [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
    }
    $Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $secret.Name, $secrettemp.SecretValue

    New-AzAutomationCredential -AutomationAccountName $AutomationAccountNameDest -Name $secret.Name -Value $Credential -ResourceGroupName $ResourceGroupDestination
}
