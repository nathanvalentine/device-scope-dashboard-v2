<#
Get-IntuneDevices.ps1

Collector for Intune managed devices via Microsoft Graph.
Writes results to intune_raw.
#>
param(
    [Parameter(Mandatory=$true)][string]$DbPath,
    [Parameter(Mandatory=$true)][string]$RunId,
    [string]$ConfigPath
)

Import-Module (Join-Path $PSScriptRoot "DeviceScope.Common.psm1") -Force

$startedAt = Get-Date
$intuneFlat = @()

try {
    $configPath = if ($ConfigPath) { $ConfigPath } else { Join-Path (Split-Path $PSScriptRoot -Parent) "config.json" }
    $config = if (Test-Path $configPath) { Get-Content $configPath | ConvertFrom-Json } else { $null }
    $SecureDataFolder = if ($config.SecureDataFolder -and (Test-Path $config.SecureDataFolder)) { $config.SecureDataFolder } else { Join-Path $env:USERPROFILE "AppData\Local\DeviceScope\Secure" }

    $MgTenantId = $config.TenantId
    $MgClientId = $config.ClientId

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

    if (-not $headers) { throw "Could not acquire Graph access token via certificate or client secret." }

    $intuneAll = @()
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=*"
    do {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
        if ($resp.value) { $intuneAll += $resp.value }
        $uri = $resp.'@odata.nextLink'
    } while ($uri)

    $intuneFlat = $intuneAll | ForEach-Object {
        $nameKey = NormalizeComputerName $_.deviceName
        if (-not $nameKey) { return }
        [PSCustomObject]@{
            name_key            = $nameKey
            device_id           = $_.id
            device_name          = $_.deviceName
            operating_system     = $_.operatingSystem
            compliance_state      = $_.complianceState
            management_agent      = $_.managementAgent
            azure_ad_device_id    = $_.azureADDeviceId
            serial_number         = $_.serialNumber
            user_principal_name    = $_.userPrincipalName
            last_sync_datetime     = [string]$_.lastSyncDateTime
        }
    } | Where-Object { $_ -ne $null }

    Write-Output "Intune: fetched $($intuneFlat.Count) devices from Graph"

} catch {
    Write-Warning "Intune collection failed: $($_.Exception.Message)"
    $intuneFlat = @()
}

Write-SourceRawTable -DbPath $DbPath -TableName "intune_raw" -SourceName "Intune" `
    -RunId $RunId -StartedAt $startedAt -Rows $intuneFlat
