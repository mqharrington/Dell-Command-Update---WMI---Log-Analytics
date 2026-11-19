Dell Command Update writes its update history to the local WMI.

############################################################################

clear-host


$Namespace = 'root\Dell\PlatformUpdateEvents'

try {
    $Events = Get-CimInstance -Namespace $Namespace -ClassName 'UpdateEvents' -ErrorAction Stop

    if (-not $Events) {
        Write-Host "No update events found." -ForegroundColor Yellow
    }
    else {
        Write-Host "Found $($Events.Count) update event(s):" -ForegroundColor Green
        $Events | Format-List *
        # Or:
        # $Events | Format-Table -AutoSize
    }
}
catch {
    Write-Host "Failed to query WMI: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Make sure Dell Command | Update is installed and you're running as Administrator." -ForegroundColor Yellow
}




 ############################################################################


--  file DCUResultsUdated.ps1

Copies Dell’s temporary catalog files so it can look up friendly names later.
Gets the computer model and service tag.
Finds and loads the matching catalog XML, building a lookup table of update IDs → Display name + Vendor Version.
Queries the WMI class UpdateEvents under root\Dell\PlatformUpdateEvents.
For each event, maps the codes to readable text and enriches it with Display / VendorVersion from the catalog.
Writes every event as its own subkey under HKLM:\SOFTWARE\DELL\UpdateService\UpdateHistory.
Prints the results to the screen and deletes the temporary catalog folder.


 ############################################################################



--  file QueryDCUWMI_SendtoLAWPRODFinal.ps1

Copies Dell’s temporary catalog files and loads the matching catalog for this PC.
Builds a lookup table of update IDs → Display name + Vendor Version.
Reads and parses Activity.log into individual log entries with timestamps.
Filters the entries to the last $DaysBack days (or the most recent run if $DaysBack is null).
For each remaining entry, tries to extract a release ID and enriches it with Display / VendorVersion from the catalog.
Sends the enriched records to Azure Log Analytics.
Deletes the temporary catalog folder.

############################################################################

--  the file WMI_DCU_Information.json 
is what you can upload into Azure / Log Analytics.  then you need to get your workspace ID and sharedkey


Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName "XYZ" -Name "ABCXYZ"   enter your resource group name
and -Name from LAW.  On the OVERVIEW page


Then in your file QueryDCUWMI_SendtoLAWPRODFinal.ps1 you need to update these fields

$WorkspaceId  = ""
$SharedKey    = ""

############################################################################

 
