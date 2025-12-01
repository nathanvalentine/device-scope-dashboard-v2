<#
Test script to validate certificate-based authentication and Key Vault secret retrieval.
Run this on the target host where the certificate is installed in the configured store,
and where the group-managed service account has access to the private key.
#>

param(
    [string]$ConfigPath
)

# Resolve config.json robustly:
function Find-ConfigJson {
    param([string]$explicitPath)
    $attempts = @()
    if ($explicitPath) {
        $attempts += $explicitPath
        if (Test-Path $explicitPath) { return (Resolve-Path $explicitPath).Path }
    }

    # Common locations relative to this script
    if ($PSScriptRoot) {
        $try1 = Join-Path $PSScriptRoot "..\config.json"
        $try2 = Join-Path $PSScriptRoot "config.json"
        $attempts += $try1; $attempts += $try2
        if (Test-Path $try1) { return (Resolve-Path $try1).Path }
        if (Test-Path $try2) { return (Resolve-Path $try2).Path }
    }

    # Walk up from current directory
    $cwd = (Get-Location).Path
    $cur = $cwd
    while ($cur -ne [System.IO.Path]::GetPathRoot($cur)) {
        $candidate = Join-Path $cur "config.json"
        $attempts += $candidate
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        $cur = Split-Path $cur -Parent
    }

    # Last resort: try repo root relative to script if available
    return @{ Found = $false; Attempts = $attempts }
}

$result = Find-ConfigJson -explicitPath $ConfigPath
if ($result -is [string]) {
    $configPathResolved = $result
} else {
    Write-Error "Config not found. Attempted paths:`n$($result.Attempts -join "`n")"
    exit 2
}

$config = Get-Content $configPathResolved | ConvertFrom-Json
if (-not $config.KeyVaultName) { Write-Error "KeyVaultName not set in config.json"; exit 2 }

Write-Host "Using KeyVault: $($config.KeyVaultName)"

# Import helper from main script if present
. (Join-Path $PSScriptRoot "AllDeviceExports_Merge.ps1") | Out-Null

# Ensure Az modules
EnsureModule -ModuleName 'Az.Accounts'
EnsureModule -ModuleName 'Az.KeyVault'

$tenant = $config.TenantId
$app = $config.ClientId
$thumb = $config.CertificateThumbprint
$vault = $config.KeyVaultName

Write-Host "Attempting Connect-AzAccount using certificate thumbprint: $thumb"
try {
    Connect-AzAccount -ServicePrincipal -Tenant $tenant -ApplicationId $app -CertificateThumbprint $thumb -ErrorAction Stop
    Write-Host "Connect-AzAccount succeeded"
} catch {
    Write-Error "Connect-AzAccount failed: $($_.Exception.Message)"; exit 3
}

# Try fetching each secret listed in config
if ($config.KeyVaultSecrets) {
    foreach ($kv in $config.KeyVaultSecrets.PSObject.Properties) {
        $name = $kv.Value
        Write-Host "Fetching secret '$name' from vault '$vault'..."
        try {
            $s = Get-AzKeyVaultSecret -VaultName $vault -Name $name -ErrorAction Stop
            $plain = Convert-SecureStringToPlainText -Secure $s.SecretValue
            if ($plain) { Write-Host "Retrieved secret '$name' (length: $($plain.Length))" } else { Write-Warning "Secret '$name' retrieved but empty" }
        } catch {
            Write-Warning "Failed to retrieve secret '$name': $($_.Exception.Message)"
        }
    }
}

Write-Host "Key Vault test completed."
