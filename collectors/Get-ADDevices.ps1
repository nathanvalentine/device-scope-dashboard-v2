<#
Get-ADDevices.ps1

Collector for on-prem Active Directory computer objects.
Writes results to ad_raw.
#>
param(
    [Parameter(Mandatory=$true)][string]$DbPath,
    [Parameter(Mandatory=$true)][string]$RunId
)

Import-Module (Join-Path $PSScriptRoot "DeviceScope.Common.psm1") -Force

# OU parsing helpers (kept local since only AD collector needs them)
function Get-FirstOUNameFromDN {
    param([string]$distinguishedName)
    if (-not $distinguishedName) { return $null }
    $m = [regex]::Match($distinguishedName, 'OU=([^,]+)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

function Get-OUPathFromDN {
    param([string]$distinguishedName, [switch]$RootToLeaf)
    if (-not $distinguishedName) { return $null }
    $ous = [regex]::Matches($distinguishedName, 'OU=([^,]+)', 'IgnoreCase') | ForEach-Object { $_.Groups[1].Value }
    if ($ous.Count -eq 0) { return $null }
    if ($RootToLeaf.IsPresent) {
        $arr = @($ous)
        [array]::Reverse($arr)
        return ($arr -join '/')
    }
    return ($ous -join '/')
}

function DeriveLocationFromOU {
    param([string]$ouName, [string]$ouPath)
    if ($ouPath) {
        $segments = $ouPath.Split('/')
        if ($segments.Count -gt 0) { return $segments[0] }
    }
    if ($ouName) { return $ouName }
    return $null
}

$startedAt = Get-Date
$adFlat = @()

try {
    $adRaw = Get-ADComputer -Filter * -Properties *

    $adFlat = $adRaw | ForEach-Object {
        $nameKey = NormalizeComputerName $_.Name
        if (-not $nameKey) { return }

        $dn = $_.DistinguishedName
        $ouName = Get-FirstOUNameFromDN $dn
        $ouPath = Get-OUPathFromDN $dn -RootToLeaf
        $locFromOu = DeriveLocationFromOU $ouName $ouPath

        [PSCustomObject]@{
            name_key                 = $nameKey
            ad_name                   = $_.Name
            dns_hostname               = $_.DNSHostName
            operating_system           = $_.OperatingSystem
            last_logon_date             = [string]$_.LastLogonDate
            enabled                    = [string]$_.Enabled
            object_guid                = [string]$_.ObjectGUID
            distinguished_name          = $dn
            ou_name                    = $ouName
            ou_path                    = $ouPath
            location_from_ou            = $locFromOu
            physical_delivery_office     = $_.physicalDeliveryOfficeName
        }
    } | Where-Object { $_ -ne $null }

    Write-Output "AD: fetched $($adFlat.Count) computer objects"

} catch {
    Write-Warning "AD collection failed: $($_.Exception.Message)"
    $adFlat = @()
}

Write-SourceRawTable -DbPath $DbPath -TableName "ad_raw" -SourceName "AD" `
    -RunId $RunId -StartedAt $startedAt -Rows $adFlat
