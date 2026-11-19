


# this will get your workspace $WorkspaceId and $SharedKey  
# Open up Log Analytics and navigate to your workspace.  click on Overview then get your Resource Group and Workspace name 


Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName "XYZ" -Name "ABCXYZ"



<#

then you add those keys to your script

$WorkspaceId  = ""
$SharedKey    = ""
 


#>

 