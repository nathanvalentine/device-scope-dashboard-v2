<#
Initialize-DpapiSecrets.ps1

Purpose:
  Securely encrypt and store secrets using Windows Data Protection API (DPAPI).
  Stores encrypted secrets as binary files that can only be decrypted by the same
  machine/user account that encrypted them.

Usage:
  .\Initialize-DpapiSecrets.ps1 -TargetFolder C:\Secure

  Prompts for each secret interactively:
  - MgTenantId (Azure AD tenant ID)
  - MgClientId (OAuth2 client ID)
  - MgClientSecret (OAuth2 client secret)
  - SophosClientId (Sophos API client ID)
  - SophosClientSecret (Sophos API client secret)
  - KaceUsername (KACE SMA username)
  - KacePassword (KACE SMA password)

Requirements:
  - Windows OS (DPAPI is Windows-specific)
  - Admin rights may be needed to create target folder
  - Must be run on the same machine where secrets will be decrypted

Security Notes:
  - Secrets are encrypted with LocalMachine scope (key tied to machine)
  - If you run under a service account, run this script under that same account
  - Don't move encrypted files to other machines; they won't decrypt
  - For on-prem servers, consider encrypting with CurrentUser (personal) or
    use a central vault (Azure Key Vault, Vault, 1Password) instead
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetFolder
)

# ========================================
# Helper function to encrypt and save
# ========================================
function Save-DpapiSecret {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SecretName,
        
        [Parameter(Mandatory=$true)]
        [string]$SecretValue,
        
        [Parameter(Mandatory=$true)]
        [string]$TargetPath
    )
    
    try {
        [System.Reflection.Assembly]::LoadWithPartialName("System.Security") | Out-Null
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($SecretValue)
        $encryptedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes, $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        [System.IO.File]::WriteAllBytes($TargetPath, $encryptedBytes)
        Write-Host "✓ Saved $SecretName to $TargetPath" -ForegroundColor Green
        return $true
    } catch {
        Write-Error "Failed to encrypt and save $SecretName : $($_.Exception.Message)"
        return $false
    }
}

# ========================================
# Helper to prompt for secret securely
# ========================================
function Read-SecretValue {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PromptText
    )
    
    Write-Host $PromptText -ForegroundColor Cyan
    $secret = Read-Host -AsSecureString
    return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret))
}

# ========================================
# Ensure target folder exists
# ========================================
if (-not (Test-Path $TargetFolder)) {
    try {
        New-Item -ItemType Directory -Path $TargetFolder -Force -ErrorAction Stop | Out-Null
        Write-Host "Created target folder: $TargetFolder" -ForegroundColor Green
    } catch {
        Write-Error "Failed to create target folder: $($_.Exception.Message)"
        exit 1
    }
}

# Verify write permissions
$testFile = Join-Path $TargetFolder ".write-test"
try {
    "test" | Out-File -LiteralPath $testFile -Force
    Remove-Item $testFile -Force
} catch {
    Write-Error "Cannot write to target folder. Check permissions: $($_.Exception.Message)"
    exit 1
}

# ========================================
# Define secrets to collect
# ========================================
$secrets = @(
    @{
        Name = "MgTenantId"
        File = "MgTenantId.bin"
        Prompt = "Enter Microsoft Graph Tenant ID (Azure AD Directory ID):"
        Optional = $false
    },
    @{
        Name = "MgClientId"
        File = "MgClientId.bin"
        Prompt = "Enter Microsoft Graph Client ID (OAuth2 Application ID):"
        Optional = $false
    },
    @{
        Name = "MgClientSecret"
        File = "MgClientSecret.bin"
        Prompt = "Enter Microsoft Graph Client Secret:"
        Optional = $false
    },
    @{
        Name = "SophosClientId"
        File = "SophosClientId.bin"
        Prompt = "Enter Sophos Central Client ID (leave blank to skip):"
        Optional = $true
    },
    @{
        Name = "SophosClientSecret"
        File = "SophosClientSecret.bin"
        Prompt = "Enter Sophos Central Client Secret (leave blank to skip):"
        Optional = $true
    },
    @{
        Name = "KaceUsername"
        File = "KaceUser.bin"
        Prompt = "Enter KACE SMA Username (leave blank to skip):"
        Optional = $true
    },
    @{
        Name = "KacePassword"
        File = "KacePw.bin"
        Prompt = "Enter KACE SMA Password (leave blank to skip):"
        Optional = $true
    }
)

# ========================================
# Collect and encrypt secrets
# ========================================
Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host "DPAPI Secret Initialization" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Target folder: $TargetFolder" -ForegroundColor Yellow
Write-Host ""
Write-Host "Enter secrets interactively. Secrets will be encrypted with DPAPI and stored as binary files." -ForegroundColor Yellow
Write-Host ""

$successCount = 0
$skipped = @()

foreach ($secret in $secrets) {
    Write-Host ""
    
    $value = Read-SecretValue -PromptText $secret.Prompt
    
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($secret.Optional) {
            Write-Host "⊘ Skipped $($secret.Name)" -ForegroundColor DarkYellow
            $skipped += $secret.Name
            continue
        } else {
            Write-Error "$($secret.Name) is required and cannot be empty."
            exit 1
        }
    }
    
    $targetPath = Join-Path $TargetFolder $secret.File
    if (Save-DpapiSecret -SecretName $secret.Name -SecretValue $value -TargetPath $targetPath) {
        $successCount++
    }
}

# ========================================
# Summary
# ========================================
Write-Host ""
Write-Host "================================" -ForegroundColor Green
Write-Host "Initialization Complete" -ForegroundColor Green
Write-Host "================================" -ForegroundColor Green
Write-Host ""
Write-Host "✓ Successfully encrypted and saved: $successCount secrets" -ForegroundColor Green
if ($skipped.Count -gt 0) {
    Write-Host "⊘ Skipped (optional): $($skipped -join ', ')" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Location: $TargetFolder" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Verify that files were created in $TargetFolder :"
Write-Host "   Get-ChildItem -Path $TargetFolder -Filter *.bin"
Write-Host ""
Write-Host "2. Update config.json if needed (SecureDataFolder path)"
Write-Host ""
Write-Host "3. Test decryption by running AllDeviceExports_Merge.ps1 :"
Write-Host "   & '.\scripts\AllDeviceExports_Merge.ps1'"
Write-Host ""
Write-Host "IMPORTANT SECURITY NOTES:" -ForegroundColor Yellow
Write-Host "- These encrypted files can ONLY be decrypted on THIS machine"
Write-Host "- If running as a service account, also run this script under that account"
Write-Host "- Keep encrypted files secure; restrict access to $TargetFolder"
Write-Host "- If you need to move files, consider using a secrets vault instead"
Write-Host ""
