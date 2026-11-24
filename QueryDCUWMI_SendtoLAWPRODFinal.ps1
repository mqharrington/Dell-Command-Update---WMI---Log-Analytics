Clear-Host

<#
    Collect Dell Command Update history via WMI and send to Log Analytics.
    Creates table: DellDCUWMI_CL
    DIY / not officially supported.
#>

# ======================== CONFIGURE THESE ========================
$WorkspaceId = "c233fa17-e78a-4d91-9f9b-c26b60f965a4"   # your Workspace ID
$SharedKey   = "YuO3J3N310Xe9tDmLn61QDznDqC8VBJsb2SiNbnsfmnyUxHlLUuDSRVOIcXb5qlfbXH1kv7cFBoulrCMT2e2PA=="  # your Primary Key
$LogType     = "DellDCUWMI"                             # table will be DellDCUWMI_CL
# =================================================================

function Send-LogAnalyticsData {
    param($WorkspaceId, $SharedKey, $LogType, $JsonBody)

    $method      = "POST"
    $contentType = "application/json"
    $resource    = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $JsonBody.Length

    $stringToHash = "$method`n$contentLength`n$contentType`nx-ms-date:$rfc1123date`n$resource"
    $bytesToHash  = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes     = [Convert]::FromBase64String($SharedKey)

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

    try {
        $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $JsonBody -UseBasicParsing
        return $response.StatusCode
    }
    catch {
        Write-Error "Send failed: $($_.Exception.Message)"
        return $null
    }
}

# --- Query WMI ---
$Namespace = 'root\Dell\PlatformUpdateEvents'
try {
    $Events = Get-CimInstance -Namespace $Namespace -ClassName 'UpdateEvents' -ErrorAction Stop
}
catch {
    Write-Error "Failed to query WMI. Is Dell Command Update installed and are you running as Administrator?"
    exit 1
}

if (-not $Events) {
    Write-Host "No update events found in WMI." -ForegroundColor Yellow
    exit 0
}

$ServiceTag = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
$ComputerName = $env:COMPUTERNAME

$records = foreach ($event in $Events) {
    [PSCustomObject]@{
        ComputerName     = $ComputerName
        ServiceTag       = $ServiceTag
        UpdateID         = $event.UpdateID
        Component        = $event.Component
        EventStatus      = $event.EventStatus
        ReturnCode       = $event.ReturnCode
        RebootRequired   = if ($event.RebootRequired) { 1 } else { 0 }
        Display          = $event.DisplayName          # adjust if property name differs
        VendorVersion    = $event.VendorVersion
        RecordedAt       = (Get-Date).ToUniversalTime().ToString("o")
    }
}

if ($records) {
    $json = $records | ConvertTo-Json -Depth 4 -Compress
    $status = Send-LogAnalyticsData -WorkspaceId $WorkspaceId -SharedKey $SharedKey -LogType $LogType -JsonBody $json
    Write-Host "Sent $($records.Count) record(s). HTTP status: $status" -ForegroundColor Green
    Write-Host "Table name: ${LogType}_CL" -ForegroundColor Cyan
}


