$Computername = {"Server1","Server2"}
$UsertoAdd = "DatabaseAdmins-Prod-PA"
#If you need to add any specific group then provide the name for the group in $UsertoAdd and at line 11 change from user to group

$GrouptoAddIn = "Administrators"
$DomainName = $env:USERDOMAIN

foreach($computer in $Computername)
  {
  $Group = [ADSI]"WinNT://$computer/$GrouptoAddIn,group"
  $User = [ADSI]"WinNT://$DomainName/$UsertoAdd,user"
  $Group.Add($User.Path)
  }
