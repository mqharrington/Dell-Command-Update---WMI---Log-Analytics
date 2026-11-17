<#

        .AUTHOR
        SKip Braun

        .SYNOPSIS
            Collect history Data from Dell Command | Update.

        .DESCRIPTION
            Queries the WMI provider for DCU to retrieve historical data and writes it to the assigned 
            registry location, currently set to `HKLM:\SOFTWARE\DELL\UpdateService\UpdateHistory`.

        .SWITCHES
            none.

        .OUTPUT
        Written to screen and to a the registry

        .NOTES
        This script is provided solely as an illustrative example and is not an officially
        supported Dell production script. It has not been validated, tested, or approved
        for production use. You assume full responsibility for reviewing, testing, adapting,
        and validating this script in a non-production environment before deployment.
        Use in production is at your own risk and may result in unexpected behavior,
        data loss, system impact, or service disruption. No warranty or support is provided.

        .Version
        2611.2
    #>


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Configuration
$Source        = 'C:\ProgramData\Dell\updateservice\temp*'
$Destination   = 'C:\ProgramData\Dell\UpdateHistory'
$DirectoryPath = 'C:\ProgramData\Dell\UpdateHistory\Temp'
$Namespace     = 'root\Dell\PlatformUpdateEvents'
$RegistryPath  = 'HKLM:\SOFTWARE\DELL\UpdateService\UpdateHistory'

$ComponentTypes = @{
    1 = 'BIOS'
    2 = 'Driver'
    3 = 'Firmware'
    4 = 'Applications'
    5 = 'Utilities'
}

$EventTypes = @{
    0 = 'Update Completed'
    1 = 'Update Failed'
    2 = 'BIOS Updated'
}

$ReturnCodes = @{
     0 = 'SUCCESS'
     1 = 'ERROR'
     2 = 'REBOOT_REQUIRED'
     3 = 'DEP_SOFT_ERROR'
     4 = 'DEP_HARD_ERROR'
     5 = 'PLATFORM_UNSUPPORTED'
     6 = 'REBOOTING_SYSTEM'
     7 = 'PASSWORD_REQUIRED'
     8 = 'NO_DOWNGRADE'
     9 = 'REBOOT_UPDATE_PENDING'
    10 = 'INVALID_CMDLINE_SPEC'
    11 = 'UNKNOWN_OPTION'
    12 = 'AUTHORIZATION_LEVEL'
}

<# 

    This function sets up all of the temporary files needed to associate each update ID with additional information about its corresponding update.
#>

function Copy-UpdateServiceFiles {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath 'C:\ProgramData\Dell\updateservice')) {
        throw 'Dell UpdateService source directory does not exist.'
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -Path $Destination -ItemType Directory -Force |
            Out-Null
    }

    Copy-Item `
        -Path $Source `
        -Destination $Destination `
        -Recurse `
        -Force `
        -ErrorAction Stop
}

<# 

    Each system uses a discrete catalog file to identify the available updates. This function 
    locates the correct catalog file for the system on which it is being executed.
#>

function Get-DellManifestPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$XmlPath
    )

    if (-not (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
        throw "Catalog index was not found: $XmlPath"
    }

    $Xml = New-Object System.Xml.XmlDocument
    $Xml.Load($XmlPath)

    $NamespaceManager = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $NamespaceManager.AddNamespace('d', 'openmanage/cm/dm')

    $Manifests = $Xml.SelectNodes(
        '//d:ManifestInformation',
        $NamespaceManager
    )

    foreach ($Manifest in $Manifests) {
        $Display = $Manifest.SelectSingleNode(
            'd:Display',
            $NamespaceManager
        )

        if ($Display -and
            $Display.InnerText.Trim().IndexOf(
                $Model,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0) {
            return $Manifest.GetAttribute('path')
        }
    }

    throw "No Dell catalog manifest was found for model: $Model"
}

<# 

    This function  compares the specified `UpdateID` against the entries in the catalog to verify whether a 
    matching record exists and to identify any additional details or metadata associated with that update.
#>


function Import-ComponentLookup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$XmlPath
    )

    if (-not (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
        throw "Catalog XML was not found: $XmlPath"
    }

    [xml]$Xml = Get-Content `
        -LiteralPath $XmlPath `
        -Raw `
        -ErrorAction Stop

    $Lookup = @{}

    $Components = $Xml.SelectNodes(
        "//*[local-name()='SoftwareComponent']"
    )

    foreach ($Component in $Components) {
        $ReleaseId = $Component.GetAttribute('releaseID')

        if ([string]::IsNullOrWhiteSpace($ReleaseId)) {
            continue
        }

        $NameNode = $Component.SelectSingleNode(
            "./*[local-name()='Name']"
        )

        $Display = if ($NameNode) {
            $NameNode.InnerText.Trim()
        }
        else {
            $Component.GetAttribute('Name')
        }

        $Lookup[$ReleaseId] = [PSCustomObject]@{
            Display       = $Display
            VendorVersion = $Component.GetAttribute('vendorVersion')
            InstallDate   = $Component.GetAttribute('dateTime')
        }
    }

    return $Lookup
}

<# 

    This function cleans up temporary files created or used during script execution.
#>

function Remove-Folder {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderPath
    )

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        return $true
    }

    Remove-Item `
        -LiteralPath $FolderPath `
        -Recurse `
        -Force `
        -ErrorAction Stop

    return $true
}

function ConvertTo-SafeRegistryName {
    param (
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'UnknownUpdate'
    }

    return ($Value -replace '[\/:*?"<>|]', '_')
}

function Write-RegistryProperties {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Properties
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force |
            Out-Null
    }

    foreach ($Property in $Properties.GetEnumerator()) {
        $PropertyType = if (
            $Property.Name -in @('Successful', 'RebootRequired')
        ) {
            'DWord'
        }
        else {
            'String'
        }

        New-ItemProperty `
            -Path $Path `
            -Name $Property.Name `
            -Value $Property.Value `
            -PropertyType $PropertyType `
            -Force |
            Out-Null
    }
}

try {
    # Copy the local Dell UpdateService catalog files.
    Copy-UpdateServiceFiles `
        -Source $Source `
        -Destination $Destination

    # Query system information once per class.
    $ComputerInfo = Get-CimInstance `
        -ClassName Win32_ComputerSystem `
        -ErrorAction Stop

    $BiosInfo = Get-CimInstance `
        -ClassName Win32_BIOS `
        -ErrorAction Stop

    $LocalPCModel = [string]$ComputerInfo.Model
    $ServiceTag = [string]$BiosInfo.SerialNumber

    # Locate the catalog index.
    $CatalogIndexPath = Join-Path `
        -Path $DirectoryPath `
        -ChildPath 'CatalogIndexPC.xml'

    $ManifestPath = Get-DellManifestPath `
        -Model $LocalPCModel `
        -XmlPath $CatalogIndexPath

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        throw "Manifest path is empty for model: $LocalPCModel"
    }

    $CatalogFile = [System.IO.Path]::GetFileNameWithoutExtension(
        $ManifestPath
    ) + '.xml'

    $CatalogPath = Join-Path `
        -Path $DirectoryPath `
        -ChildPath $CatalogFile

    # Load and index the catalog once.
    $ComponentLookup = Import-ComponentLookup `
        -XmlPath $CatalogPath

    # Ensure the registry destination exists.
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Container)) {
        New-Item -Path $RegistryPath -ItemType Directory -Force |
            Out-Null
    }

    # Read all update events once.
    $Events = @(Get-CimInstance `
        -Namespace $Namespace `
        -ClassName 'UpdateEvents' `
        -ErrorAction Stop)

    if ($Events.Count -eq 0) {
        Write-Host 'No update events found.' -ForegroundColor Yellow
        return
    }

    $Results = foreach ($Event in $Events) {
        $ReleaseId = [string]$Event.SWBReleaseID
        $ReturnCodeValue = [int]$Event.ExecutionReturnCode
        $ComponentTypeValue = [int]$Event.ComponentType
        $EventTypeValue = [int]$Event.EventType

        $Metadata = $null

        if (-not [string]::IsNullOrWhiteSpace($ReleaseId)) {
            $Metadata = $ComponentLookup[$ReleaseId]
        }

        $Display = if ($Metadata) {
            [string]$Metadata.Display
        }
        else {
            ''
        }

        $VendorVersion = if ($Metadata) {
            [string]$Metadata.VendorVersion
        }
        else {
            ''
        }

        $InstallDate = if ($Metadata) {
            [string]$Metadata.InstallDate
        }
        else {
            ''
        }

        $Successful = $ReturnCodeValue -eq 0
        $RebootRequired = $ReturnCodeValue -in @(2, 6, 9)

        $SafeUpdateID = ConvertTo-SafeRegistryName `
            -Value $ReleaseId

        $EventRegistryPath = Join-Path `
            -Path $RegistryPath `
            -ChildPath $SafeUpdateID

        $RegistryProperties = @{
            ComputerName   = $env:COMPUTERNAME
            'Service Tag'  = $ServiceTag
            UpdateID       = $ReleaseId
            Component      = [string]$ComponentTypes[$ComponentTypeValue]
            EventStatus    = [string]$EventTypes[$EventTypeValue]
            ReturnCode     = [string]$ReturnCodes[$ReturnCodeValue]
            Successful     = [int]$Successful
            RebootRequired = [int]$RebootRequired
            RecordedAt     = (Get-Date).ToString('o')
            Display        = $Display
            VendorVersion  = $VendorVersion
            CatalogDate    = $InstallDate
        }

        Write-RegistryProperties `
            -Path $EventRegistryPath `
            -Properties $RegistryProperties

        [PSCustomObject]@{
            ComputerName   = $env:COMPUTERNAME
            UpdateID       = $ReleaseId
            Component      = [string]$ComponentTypes[$ComponentTypeValue]
            EventStatus    = [string]$EventTypes[$EventTypeValue]
            ReturnCode     = [string]$ReturnCodes[$ReturnCodeValue]
            Successful     = $Successful
            RebootRequired = $RebootRequired
            Display        = $Display
            Version        = $VendorVersion
            CatalogDate    = $InstallDate
        }
    }

    $Results
}
catch {
    Write-Error `
        -Message "Unable to process Dell update history: $($_.Exception.Message)"
}
finally {
    try {
        Remove-Folder -FolderPath $Destination |
            Out-Null
    }
    catch {
        Write-Warning `
            "Cleanup failed for '$Destination': $($_.Exception.Message)"
    }
}
