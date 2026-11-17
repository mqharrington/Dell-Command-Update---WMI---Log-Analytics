 Clear-Host

<#
    .AUTHOR
    Matt Harrington

    .SYNOPSIS
        Collect history data from Dell Command | Update via WMI

    .DESCRIPTION
        This script will copy the Activity.log file from C:\ProgramData\Dell\UpdateService\Log and then parse through it looking for resent updates.
        There is a $DaysBack variable below that you can set for the number of days you want to look back in this file.  It then gets the Display Name 
        and Vendor Version from the Dell catalog and sends this data to Log Analytics Workspace.  
        
    .NOTES
        This script is provided solely as an illustrative example and is not an officially supported Dell production script. It has not been validated, tested, or approved
        for production use. You assume full responsibility for reviewing, testing, adapting, and validating this script in a non-production environment before deployment.
        Use in production is at your own risk. No warranty or support is provided.

        !!!!!!!!!!  THIS IS JUST ONE WAY TO DO THIS.  USE THIS SCRIPT AS A STARTING POINT AND MODIFY AS NEEDED FOR YOUR ENVIRONMENT  !!!!!!!!!!

    .Version
    4.1.1
#>


# Log Analytics workspace and shared key configuration

$WorkspaceId  = "c233fa17-e78a-4d91-9f9b-c26b60f965a4"
$SharedKey    = "YuO3J3N310Xe9tDmLn61QDznDqC8VBJsb2SiNbnsfmnyUxHlLUuDSRVOIcXb5qlfbXH1kv7cFBoulrCMT2e2PA=="
$LogType      = "DellDCUActivityLog"

#  example of how to get the workspace shared key from Azure   
#  Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName "dcu" -Name "WMIDCU"  << your resource group and -Name will be different.  
#   

#  ###################################################################################################################################################################################

#  This script will search the Activity log file that Dell Command Update logs update information too.  You can search back a set number of days in this file
# Set to a number (e.g. 7) to keep the last X days, or $null for most recent run only
$ActivityLogPath = "C:\ProgramData\Dell\UpdateService\Log\Activity.log"
$DaysBack = 1


#  catalog handling 
$Source        = 'C:\ProgramData\Dell\updateservice\temp*'
$Destination   = 'C:\ProgramData\Dell\UpdateHistory'
$DirectoryPath = 'C:\ProgramData\Dell\UpdateHistory\Temp'

# Function to copy the update service file
function Copy-UpdateServiceFiles {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )
    if (-not (Test-Path -LiteralPath 'C:\ProgramData\Dell\updateservice')) {
        throw 'Dell UpdateService source directory does not exist.'
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    }
    Copy-Item -Path $Source -Destination $Destination -Recurse -Force -ErrorAction Stop
}

# Function to get manifest path and .xml data
function Get-DellManifestPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]$Model,
        [Parameter(Mandatory)] [string]$XmlPath
    )
    if (-not (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
        throw "Catalog index was not found: $XmlPath"
    }
    $Xml = New-Object System.Xml.XmlDocument
    $Xml.Load($XmlPath)
    $NamespaceManager = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $NamespaceManager.AddNamespace('d', 'openmanage/cm/dm')
    $Manifests = $Xml.SelectNodes('//d:ManifestInformation', $NamespaceManager)
    foreach ($Manifest in $Manifests) {
        $Display = $Manifest.SelectSingleNode('d:Display', $NamespaceManager)
        if ($Display -and $Display.InnerText.Trim().IndexOf($Model, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $Manifest.GetAttribute('path')
        }
    }
    throw "No Dell catalog manifest was found for model: $Model"
}

function Import-ComponentLookup {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$XmlPath)
    if (-not (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
        throw "Catalog XML was not found: $XmlPath"
    }
    [xml]$Xml = Get-Content -LiteralPath $XmlPath -Raw -ErrorAction Stop
    $Lookup = @{}
    $Components = $Xml.SelectNodes("//*[local-name()='SoftwareComponent']")
    foreach ($Component in $Components) {
        $ReleaseId = $Component.GetAttribute('releaseID')
        if ([string]::IsNullOrWhiteSpace($ReleaseId)) { continue }
        $NameNode = $Component.SelectSingleNode("./*[local-name()='Name']")
        $Display = if ($NameNode) { $NameNode.InnerText.Trim() } else { $Component.GetAttribute('Name') }
        $Lookup[$ReleaseId] = [PSCustomObject]@{
            Display       = $Display
            VendorVersion = $Component.GetAttribute('vendorVersion')
            InstallDate   = $Component.GetAttribute('dateTime')
        }
    }
    return $Lookup
}

function Remove-Folder {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$FolderPath)
    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) { return $true }
    Remove-Item -LiteralPath $FolderPath -Recurse -Force -ErrorAction Stop
    return $true
}
# === End of Skip's catalog handling ===


#  send data to LAW
function Send-LogAnalyticsData {
    param($WorkspaceId, $SharedKey, $LogType, $JsonBody)
    $method = "POST"; $contentType = "application/json"; $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $JsonBody.Length
    $stringToHash = "$method`n$contentLength`n$contentType`nx-ms-date:$rfc1123date`n$resource"
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($SharedKey)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $encodedHash = [Convert]::ToBase64String($hmac.ComputeHash($bytesToHash))
    $authorization = "SharedKey ${WorkspaceId}:${encodedHash}"
    $uri = "https://${WorkspaceId}.ods.opinsights.azure.com${resource}?api-version=2016-04-01"
    $headers = @{
        "Authorization"        = $authorization
        "Log-Type"             = $LogType
        "x-ms-date"            = $rfc1123date
        "time-generated-field" = "RecordedAt"
    }
    (Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $JsonBody -UseBasicParsing).StatusCode
}

# --- Load catalog  ---
try {
    Copy-UpdateServiceFiles -Source $Source -Destination $Destination

    $ComputerInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $LocalPCModel = [string]$ComputerInfo.Model

    $CatalogIndexPath = Join-Path -Path $DirectoryPath -ChildPath 'CatalogIndexPC.xml'
    $ManifestPath     = Get-DellManifestPath -Model $LocalPCModel -XmlPath $CatalogIndexPath
    $CatalogFile      = [System.IO.Path]::GetFileNameWithoutExtension($ManifestPath) + '.xml'
    $CatalogPath      = Join-Path -Path $DirectoryPath -ChildPath $CatalogFile

    $ComponentLookup  = Import-ComponentLookup -XmlPath $CatalogPath
}
catch {
    Write-Warning "Catalog enrichment unavailable: $($_.Exception.Message)"
    $ComponentLookup = @{}
}

# --- Parse Activity.log (your original logic unchanged) ---
if (-not (Test-Path $ActivityLogPath)) {
    Write-Error "Activity.log not found at $ActivityLogPath"
    exit 1
}

[xml]$log = Get-Content -Path $ActivityLogPath -Raw -ErrorAction Stop
$entries = $log.SelectNodes("//LogEntry")

if (-not $entries -or $entries.Count -eq 0) {
    Write-Host "No LogEntry nodes found." -ForegroundColor Yellow
    exit 0
}

$parsed = foreach ($entry in $entries) {
    $tsText = $entry.timestamp
    if (-not $tsText) { continue }

    try {
        $dt = [DateTimeOffset]::Parse($tsText).UtcDateTime
    }
    catch { continue }

    [PSCustomObject]@{
        Timestamp = $dt
        Level     = $entry.level
        Source    = $entry.source
        Message   = $entry.message
        Data      = $entry.data
        Trace     = $entry.trace
    }
}

$parsed = $parsed | Where-Object { $_ } | Sort-Object Timestamp

if (-not $parsed) {
    Write-Host "No parseable entries found." -ForegroundColor Yellow
    exit 0
}

# --- Filter to most recent run or last X days (your original logic unchanged) ---
if ($DaysBack) {
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$DaysBack)
    $filtered = $parsed | Where-Object { $_.Timestamp -ge $cutoff }
    Write-Host "Keeping entries from the last $DaysBack days" -ForegroundColor Cyan
}
else {
    $newest = ($parsed | Select-Object -Last 1).Timestamp
    $filtered = [System.Collections.Generic.List[object]]::new()
    $current = $newest

    for ($i = $parsed.Count - 1; $i -ge 0; $i--) {
        $entry = $parsed[$i]
        $gap = ($current - $entry.Timestamp).TotalMinutes
        if ($gap -gt 30 -and $filtered.Count -gt 0) { break }
        $filtered.Insert(0, $entry)
        $current = $entry.Timestamp
    }
    Write-Host "Keeping entries from the most recent DCU run (ending $($newest.ToString('u')))" -ForegroundColor Cyan
}

if (-not $filtered -or $filtered.Count -eq 0) {
    Write-Host "No entries matched the filter." -ForegroundColor Yellow
    exit 0
}

$ServiceTag = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber

$records = foreach ($item in $filtered) {
    # Optional enrichment: try to pull a release ID out of Message or Data and look it up
    $Display = ''
    $Version = ''
    $CatalogDate = ''

    $possibleId = $null
    if ($item.Message -match '[A-Z0-9]{6,}') { $possibleId = $Matches[0] }
    elseif ($item.Data -match '[A-Z0-9]{6,}') { $possibleId = $Matches[0] }

    if ($possibleId -and $ComponentLookup.ContainsKey($possibleId)) {
        $meta = $ComponentLookup[$possibleId]
        $Display     = $meta.Display
        $Version     = $meta.VendorVersion
        $CatalogDate = $meta.InstallDate
    }

    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        ServiceTag   = $ServiceTag
        Timestamp    = $item.Timestamp.ToString("o")
        Level        = $item.Level
        Source       = $item.Source
        Message      = $item.Message
        Data         = $item.Data
        Display      = $Display          # added from catalog
        Version      = $Version          # added from catalog
        CatalogDate  = $CatalogDate      # added from catalog
        RecordedAt   = (Get-Date).ToUniversalTime().ToString("o")
    }
}

if ($records) {
    $json = $records | ConvertTo-Json -Depth 5 -Compress
    $status = Send-LogAnalyticsData -WorkspaceId $WorkspaceId -SharedKey $SharedKey -LogType $LogType -JsonBody $json
    Write-Host "Sent $($records.Count) activity record(s). HTTP status: $status" -ForegroundColor Green
    Write-Host "Table name: ${LogType}_CL" -ForegroundColor Cyan
}

# Cleanup temporary catalog files
try { Remove-Folder -FolderPath $Destination | Out-Null } catch { }