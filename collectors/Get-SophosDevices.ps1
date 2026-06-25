<#
Get-SophosDevices.ps1

Collector for Sophos Central endpoints via OAuth2 client credentials.
Writes results to sophos_raw.
#>
param(
    [Parameter(Mandatory=$true)][string]$DbPath,
    [Parameter(Mandatory=$true)][string]$RunId,
    [string]$ConfigPath
)

Import-Module (Join-Path $PSScriptRoot "DeviceScope.Common.psm1") -Force

$startedAt = Get-Date
$sophosFlat = @()

try {
    $configPath = if ($ConfigPath) { $ConfigPath } else { Join-Path (Split-Path $PSScriptRoot -Parent) "config.json" }
    $config = if (Test-Path $configPath) { Get-Content $configPath | ConvertFrom-Json } else { $null }
    $SecureDataFolder = if ($config.SecureDataFolder -and (Test-Path $config.SecureDataFolder)) { $config.SecureDataFolder } else { Join-Path $env:USERPROFILE "AppData\Local\DeviceScope\Secure" }

    # Prefer Key Vault if configured, else DPAPI fallback (consistent
    # with existing FINAL_AUTHENTICATION_SUMMARY.md pattern)
    $SophosClientId     = $null
    $SophosClientSecret = $null

    if ($config.KeyVaultName -and (Get-Command Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        try {
            $kv = $config.KeyVaultName
            $names = $config.KeyVaultSecrets
            if ($names.SophosClientId) {
                $s = Get-AzKeyVaultSecret -VaultName $kv -Name $names.SophosClientId -ErrorAction Stop
                $SophosClientId = Convert-SecureStringToPlainText -Secure $s.SecretValue
            }
            if ($names.SophosClientSecret) {
                $s = Get-AzKeyVaultSecret -VaultName $kv -Name $names.SophosClientSecret -ErrorAction Stop
                $SophosClientSecret = Convert-SecureStringToPlainText -Secure $s.SecretValue
            }
        } catch {
            Write-Warning "Key Vault Sophos secret retrieval failed: $($_.Exception.Message)"
        }
    }

    if (-not $SophosClientId)     { $SophosClientId     = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "SophosClientId.bin") }
    if (-not $SophosClientSecret) { $SophosClientSecret = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "SophosClientSecret.bin") }

    if (-not $SophosClientId -or -not $SophosClientSecret) {
        throw "Sophos credentials not available (Key Vault and DPAPI both failed)."
    }

    $body = @{ grant_type = 'client_credentials'; client_id = $SophosClientId; client_secret = $SophosClientSecret; scope = 'token' }
    $tokenResp = Invoke-RestMethod -Uri "https://id.sophos.com/api/v2/oauth2/token" -Method Post -Body $body
    $accessToken = $tokenResp.access_token

    $whoHeaders = @{ Authorization = "Bearer $accessToken" }
    $whoamiResp = Invoke-RestMethod -Uri "https://api.central.sophos.com/whoami/v1" -Headers $whoHeaders
    $tenantId   = $whoamiResp.id
    $regionHost = $whoamiResp.apiHosts.dataRegion

    $headersSophos = @{ Authorization = "Bearer $accessToken"; 'X-Tenant-ID' = $tenantId }
    $allEndpoints = @(); $nextKey = $null
    do {
        $uri = "$regionHost/endpoint/v1/endpoints?view=full&pageSize=500"
        if ($nextKey) { $uri += "&pageFromKey=$nextKey" }
        $resp = Invoke-RestMethod -Uri $uri -Headers $headersSophos
        if ($resp.items) { $allEndpoints += $resp.items }
        $nextKey = $resp.pages.nextKey
    } while ($nextKey)

    $sophosFlat = $allEndpoints | ForEach-Object {
        $nameKey = NormalizeComputerName $_.hostname
        if (-not $nameKey) { return }
        [PSCustomObject]@{
            name_key               = $nameKey
            sophos_id                = $_.id
            hostname                = $_.hostname
            os_name                 = $_.os.name
            last_seen_at             = [string]$_.lastSeenAt
            health_overall           = $_.health.overall
            ipv4_addresses           = ($_.ipv4Addresses -join '; ')
            device_type              = $_.type
            associated_person_name    = $_.associatedPerson.name
        }
    } | Where-Object { $_ -ne $null }

    Write-Output "Sophos: fetched $($sophosFlat.Count) endpoints"

    $SophosClientId = $null; $SophosClientSecret = $null

} catch {
    Write-Warning "Sophos collection failed: $($_.Exception.Message)"
    $sophosFlat = @()
}

Write-SourceRawTable -DbPath $DbPath -TableName "sophos_raw" -SourceName "Sophos" `
    -RunId $RunId -StartedAt $startedAt -Rows $sophosFlat
