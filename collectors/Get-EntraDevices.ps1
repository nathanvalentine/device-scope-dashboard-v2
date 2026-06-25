<#
Get-EntraDevices.ps1

Collector for Entra ID (Azure AD) devices via Microsoft Graph.
Writes results to entra_raw. Does NOT merge or normalize anything -
that all happens in SQL views (sql/02_views.sql).

Usage (called by orchestrator, but runnable standalone for testing):
  .\Get-EntraDevices.ps1 -DbPath C:\apps\devicescope\data\devicescope.db -RunId "20260618_043000_ab12cd34"
#>
param(
    [Parameter(Mandatory=$true)][string]$DbPath,
    [Parameter(Mandatory=$true)][string]$RunId,
    [string]$ConfigPath
)

Import-Module (Join-Path $PSScriptRoot "DeviceScope.Common.psm1") -Force

$startedAt = Get-Date
$entraFlat = @()

try {
    $configPath = if ($ConfigPath) { $ConfigPath } else { Join-Path (Split-Path $PSScriptRoot -Parent) "config.json" }
    $config = if (Test-Path $configPath) { Get-Content $configPath | ConvertFrom-Json } else { $null }

    $SecureDataFolder = if ($config.SecureDataFolder -and (Test-Path $config.SecureDataFolder)) { $config.SecureDataFolder } else { Join-Path $env:USERPROFILE "AppData\Local\DeviceScope\Secure" }

    $MgTenantId     = $config.TenantId
    $MgClientId     = $config.ClientId
    $MgClientSecret = $null

    # Prefer certificate-based auth (see FINAL_AUTHENTICATION_SUMMARY.md);
    # fall back to DPAPI client secret only if certificate auth unavailable.
    $accessToken = $null
    $headers = $null

    if ($config.CertificateThumbprint) {
        try {
            $at = Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue
            if ($at) {
                $t = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/"
                if ($t -and $t.Token) {
                    $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($t.Token)
                    try { $accessToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto($tokenPtr) }
                    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr) }
                    $headers = @{ Authorization = "Bearer $accessToken" }
                }
            }
        } catch {
            Write-Warning "Certificate-based Graph token acquisition failed: $($_.Exception.Message)"
        }
    }

    if (-not $headers) {
        $MgClientSecret = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "MgClientSecret.bin")
        if ($MgTenantId -and $MgClientId -and $MgClientSecret) {
            $tokenBody = @{ client_id = $MgClientId; client_secret = $MgClientSecret; scope = "https://graph.microsoft.com/.default"; grant_type = "client_credentials" }
            $tokenResp = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$MgTenantId/oauth2/v2.0/token" -Body $tokenBody
            $headers = @{ Authorization = "Bearer $($tokenResp.access_token)" }
        }
    }

    if (-not $headers) {
        throw "Could not acquire Graph access token via certificate or client secret."
    }

    $entraAll = @()
    $uri = "https://graph.microsoft.com/v1.0/devices?`$select=*"
    do {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
        if ($resp.value) { $entraAll += $resp.value }
        $uri = $resp.'@odata.nextLink'
    } while ($uri)

    $entraFlat = $entraAll | ForEach-Object {
        $nameKey = NormalizeDisplayName $_.displayName
        if (-not $nameKey) { return }
        [PSCustomObject]@{
            name_key                  = $nameKey
            device_id                 = $_.deviceId
            display_name              = $_.displayName
            operating_system          = $_.operatingSystem
            operating_system_version  = $_.operatingSystemVersion
            trust_type                = $_.trustType
            join_type                 = $_.joinType
            is_managed                = [string]$_.isManaged
            is_compliant               = [string]$_.isCompliant
            approx_last_signin         = [string]$_.approximateLastSignInDateTime
        }
    } | Where-Object { $_ -ne $null }

    Write-Output "Entra: fetched $($entraFlat.Count) devices from Graph"

} catch {
    Write-Warning "Entra collection failed: $($_.Exception.Message)"
    $entraFlat = @()
}

Write-SourceRawTable -DbPath $DbPath -TableName "entra_raw" -SourceName "Entra" `
    -RunId $RunId -StartedAt $startedAt -Rows $entraFlat
