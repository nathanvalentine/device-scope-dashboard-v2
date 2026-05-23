# DeviceScope Dashboard - Windows Service Deployment Guide

**Version:** 1.0  
**Date:** December 1, 2025  
**Target Environment:** Windows Server 2016+ with group managed service account  
**Authentication:** Azure Entra service principal with certificate + Azure Key Vault for secret storage

---

## Overview

This guide walks through deploying the DeviceScope Dashboard as a Windows Service using:
- **Group Managed Service Account (gMSA)** for service identity
- **Certificate-based authentication** to Azure Entra ID (no client secret)
- **Azure Key Vault** for runtime secret retrieval (Sophos credentials, KACE password)
- **NSSM** (Non-Sucking Service Manager) for service lifecycle management

The app fetches secrets from Key Vault at startup, avoiding local secret storage and enabling credential rotation without service restarts.

---

## Prerequisites

Before you begin, verify the following on your workstation or admin host:

### 1. Certificate Setup
- ✅ Client authentication certificate installed in Windows Domain CA
- ✅ Certificate enrolled and available in `LocalMachine\My` store (verify thumbprint: `d933e750a76acaa9da82ceb06a230a89c9898fac`)
- ✅ Certificate private key permissions: gMSA account must have **Read** access to the private key

### 2. Azure Setup
- ✅ Entra App Registration created with certificate uploaded
- ✅ App has **Application** permissions for Microsoft Graph (not Delegated):
  - `Device.Read.All` (read device data)
  - `DeviceManagementManagedDevices.Read.All` (read Intune devices)
  - `Files.ReadWrite.All` (upload to SharePoint, if enabled)
- ✅ Admin consent granted for all Application permissions
- ✅ Key Vault access policy or RBAC role assigned to app (`Key Vault Secret User` or equivalent)

### 3. Key Vault Secrets
Verify all 3 secrets exist in `kv-cvb-prod-westus2-core`:
- `DeviceScopeApp-SophosClientID` (36-char GUID)
- `DeviceScopeApp-SophosClientSecret` (100-char string)
- `DeviceScopeApp-KACEPassword-nV` (22-char password)

### 4. Group Managed Service Account
- ✅ gMSA account created in AD (e.g., `svc-devicescope$`)
- ✅ gMSA password managed by AD (no manual password management)
- ✅ Host server is authorized to retrieve gMSA password

---

## Step-by-Step Deployment

### Phase 1: Prepare the Host

1. **Create deployment folder** (run as Administrator on target host):
```powershell
$AppRoot = 'C:\apps\device-scope-dashboard-v2'
New-Item -Path $AppRoot -ItemType Directory -Force

# Also create logs and secure folders
New-Item -Path 'C:\apps\device-scope-dashboard-v2\logs' -ItemType Directory -Force
New-Item -Path 'C:\Secure' -ItemType Directory -Force
```

2. **Copy project files** from your workstation or repo (using robocopy):
```powershell
# From workstation or build server
robocopy \\buildserver\path\to\device-scope-dashboard-v2 C:\apps\device-scope-dashboard-v2 /MIR /Z /R:3 /W:5
```

3. **Verify key files are present**:
```powershell
Get-ChildItem C:\apps\device-scope-dashboard-v2\config.json
Get-ChildItem C:\apps\device-scope-dashboard-v2\scripts\AllDeviceExports_Merge.ps1
Get-ChildItem C:\apps\device-scope-dashboard-v2\streamlit_app.py
```

4. **Verify config.json content** (should include Key Vault bootstrap):
```powershell
$cfg = Get-Content C:\apps\device-scope-dashboard-v2\config.json | ConvertFrom-Json
$cfg | Select-Object TenantId, ClientId, KeyVaultName, @{N='HasSecrets'; E={$_.KeyVaultSecrets -ne $null}}
```

---

### Phase 2: Prepare Python and PowerShell Environment

5. **Install Python virtual environment** (on target host, as Administrator):
```powershell
cd C:\apps\device-scope-dashboard-v2
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
```

6. **Ensure Az PowerShell modules are installed** (run as Administrator):
```powershell
# Install Az.Accounts and Az.KeyVault for the machine scope
Install-Module -Name Az.Accounts -Scope AllUsers -Force -AllowClobber
Install-Module -Name Az.KeyVault -Scope AllUsers -Force -AllowClobber
```

If the server is offline or locked down, pre-stage these modules in `C:\Program Files\PowerShell\Modules` or use a package repository.

---

### Phase 3: Install and Configure Certificate Private Key Permissions

7. **Ensure certificate is in the correct store** on the target host:
```powershell
# Verify the certificate thumbprint exists
Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -Match 'd933e750a76acaa9da82ceb06a230a89c9898fac' | Format-List Subject, Thumbprint, NotAfter
```

8. **Grant the gMSA account access to the certificate private key**:

**Option A: GUI (Recommended for validation)**
- Run `mmc.exe` on the host
- Add snap-in: File → Add/Remove Snap-in → Certificates → Computer account → Local computer → OK
- Navigate to: Certificates (Local Computer) → Personal → Certificates
- Find the certificate with thumbprint `d933e750...`
- Right-click → All Tasks → **Manage Private Keys...**
- Click Add, enter the gMSA account (e.g., `DOMAIN\svc-devicescope$`), grant **Read** permission
- Click OK to save

**Option B: PowerShell Script (automated)**
I've provided `scripts/grant-cert-access.ps1` (optional, use after Phase 3 validation) to automate this via the private key file ACLs.

---

### Phase 4: Validate Certificate Auth and Key Vault Access (on target host)

9. **Run the Key Vault test script** to confirm authentication flow works:

```powershell
# Must run in the context where gMSA will run
# (or as a user with access to the certificate private key)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
cd C:\apps\device-scope-dashboard-v2
.\scripts\test-keyvault-auth.ps1
```

**Expected output:**
```
Using KeyVault: kv-cvb-prod-westus2-core
Loaded configuration from: C:\apps\device-scope-dashboard-v2\config.json
Key Vault configuration detected. Preparing Az modules and authenticating...
Connecting with certificate thumbprint: d933e750a76acaa9da82ceb06a230a89c9898fac
Connect-AzAccount succeeded
Fetching secret 'DeviceScopeApp-SophosClientID' from vault 'kv-cvb-prod-westus2-core'...
Retrieved secret 'DeviceScopeApp-SophosClientID' (length: 36)
Fetching secret 'DeviceScopeApp-SophosClientSecret' from vault 'kv-cvb-prod-westus2-core'...
Retrieved secret 'DeviceScopeApp-SophosClientSecret' (length: 100)
Fetching secret 'DeviceScopeApp-KACEPassword-nV' from vault 'kv-cvb-prod-westus2-core'...
Retrieved secret 'DeviceScopeApp-KACEPassword-nV' (length: 22)
Key Vault test completed.
```

If the test succeeds, the certificate and Key Vault permissions are correct. Proceed to Phase 5.

**Troubleshooting test failures:**
- **401 Unauthorized (certificate)**: Ensure the gMSA account has Read permission on the certificate private key (see Phase 3, step 8).
- **Forbidden (Key Vault)**: Ensure the Entra app principal has Key Vault Secret User role or access policy on `kv-cvb-prod-westus2-core`.

---

### Phase 5: Create the Windows Service with NSSM

10. **Download and install NSSM**:

```powershell
# Option 1: Download from nssm.cc
# Save to C:\tools\nssm\nssm.exe (or similar)
# https://nssm.cc/download

# Option 2: If you have wget or Invoke-WebRequest
$nssm_url = "https://nssm.cc/ci/nssm-2.24-104-gef43fac.zip"
Invoke-WebRequest -Uri $nssm_url -OutFile C:\temp\nssm.zip
Expand-Archive C:\temp\nssm.zip -DestinationPath C:\tools\
# Extract the win64/nssm.exe binary
Copy-Item C:\tools\nssm-*\win64\nssm.exe C:\Windows\System32\ -Force
```

11. **Create the Windows Service**:

```powershell
$nssm = "C:\Windows\System32\nssm.exe"
$serviceName = "DeviceScopeDashboard"
$appExe = "C:\apps\device-scope-dashboard-v2\.venv\Scripts\python.exe"
$appArgs = "-m streamlit run C:\apps\device-scope-dashboard-v2\streamlit_app.py --server.port 8501 --server.address 0.0.0.0"
$appDir = "C:\apps\device-scope-dashboard-v2"

# Install the service
& $nssm install $serviceName $appExe $appArgs
Write-Host "Service installed: $serviceName"

# Configure service properties
& $nssm set $serviceName AppDirectory $appDir
& $nssm set $serviceName AppStdout "$appDir\logs\streamlit_stdout.log"
& $nssm set $serviceName AppStderr "$appDir\logs\streamlit_stderr.log"
& $nssm set $serviceName AppRotateFiles 1
& $nssm set $serviceName AppRotateOnline 1
& $nssm set $serviceName AppRotateSeconds 86400  # rotate daily
& $nssm set $serviceName AppRotateBytes 10485760  # rotate at 10 MB

# Set service to run under gMSA account
# (Replace DOMAIN and account name as appropriate)
& $nssm set $serviceName ObjectName "DOMAIN\svc-devicescope$" ""
# NSSM will use gMSA password managed by AD (no password needed)

# Configure restart behavior
& $nssm set $serviceName AppExit Default Restart
& $nssm set $serviceName AppRestartDelay 5000  # 5 seconds between restarts

# Start the service
& $nssm start $serviceName
```

12. **Verify service is running**:

```powershell
Get-Service DeviceScopeDashboard | Select-Object Name, Status, StartType

# Check recent log entries
Get-Content 'C:\apps\device-scope-dashboard-v2\logs\streamlit_stdout.log' -Tail 20

# Try accessing the app (should be available on port 8501)
Invoke-WebRequest -Uri "http://localhost:8501" -UseBasicParsing
```

---

### Phase 6: Configure Firewall and Access

13. **Open firewall port for Streamlit**:

```powershell
New-NetFirewallRule -DisplayName "DeviceScope Streamlit (8501)" `
    -Direction Inbound -LocalPort 8501 -Protocol TCP -Action Allow `
    -Profile Domain,Private
```

14. **Test remote access** (from another machine on the network):

```powershell
# From a workstation
Invoke-WebRequest -Uri "http://<server-ip>:8501" -UseBasicParsing
# Should return 200 OK and Streamlit HTML
```

---

### Phase 7: Schedule the PowerShell Export Script (Optional)

If you want to run the `AllDeviceExports_Merge.ps1` export on a schedule (e.g., daily), create a scheduled task:

```powershell
$scriptPath = "C:\apps\device-scope-dashboard-v2\scripts\AllDeviceExports_Merge.ps1"
$taskName = "DeviceScope-Export-Daily"
$time = "02:00 AM"  # 2 AM daily

# Create task action
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

# Create trigger (daily at 2 AM)
$trigger = New-ScheduledTaskTrigger -Daily -At $time

# Create task settings (run under gMSA)
$principal = New-ScheduledTaskPrincipal -UserID "DOMAIN\svc-devicescope$" -LogonType Password
$settings = New-ScheduledTaskSettingSet -MultipleInstances IgnoreNew -RunOnlyIfNetworkAvailable

# Register the task
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force
```

---

## Operation and Maintenance

### Service Management

```powershell
# Start service
Start-Service DeviceScopeDashboard

# Stop service
Stop-Service DeviceScopeDashboard

# Restart service
Restart-Service DeviceScopeDashboard

# View service status
Get-Service DeviceScopeDashboard

# View recent logs
Get-Content 'C:\apps\device-scope-dashboard-v2\logs\streamlit_stdout.log' -Tail 50
```

### Updating the Application

1. Stop the service:
```powershell
Stop-Service DeviceScopeDashboard
```

2. Copy new files (using robocopy):
```powershell
robocopy \\buildserver\path\to\updated\repo C:\apps\device-scope-dashboard-v2 /MIR /XD .git .venv
```

3. If dependencies changed, update pip:
```powershell
cd C:\apps\device-scope-dashboard-v2
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

4. Restart the service:
```powershell
Start-Service DeviceScopeDashboard
```

### Certificate Renewal

When the certificate is renewed and re-enrolled:

1. Update the certificate in `LocalMachine\My` store.
2. Update the thumbprint in `config.json` (property `CertificateThumbprint`).
3. Upload the new certificate to the Entra App Registration.
4. Restart the service:
```powershell
Restart-Service DeviceScopeDashboard
```

### Credential Rotation (Key Vault Secrets)

To rotate credentials (Sophos, KACE passwords):

1. Update the secret values in Azure Key Vault (no code or config changes needed).
2. At next service start, the script fetches the updated secret.
3. No service restart required (secrets are fetched at startup).

---

## Troubleshooting

### Service fails to start or exits immediately

**Check logs:**
```powershell
Get-Content 'C:\apps\device-scope-dashboard-v2\logs\streamlit_stderr.log' -Tail 100
Get-Content 'C:\apps\device-scope-dashboard-v2\logs\streamlit_stdout.log' -Tail 100
```

**Common issues:**
- Python virtual environment path incorrect → verify `.venv` folder exists and has `Scripts\python.exe`
- Port 8501 already in use → change `--server.port` in NSSM config
- gMSA account doesn't have certificate private key permissions → re-run Phase 3, step 8
- Certificate not found in store → verify thumbprint in `config.json` matches installed cert

### Certificate authentication fails (401 Unauthorized)

**Check:**
1. Certificate thumbprint is correct: `d933e750a76acaa9da82ceb06a230a89c9898fac`
2. Certificate is in `LocalMachine\My` store on the host
3. gMSA account has Read permission on the certificate private key
4. Certificate is uploaded to the Entra App Registration
5. Certificate is not expired

### Key Vault secret retrieval fails (Forbidden / 403)

**Check:**
1. The Entra app principal has role assignment in Key Vault (Azure Portal → Key Vault → Access Control (IAM) → Role assignments → "Key Vault Secret User" should list your app)
2. The secret names in `config.json` match exactly (case-sensitive)
3. Network connectivity: host can reach `https://vault.azure.net` and `https://login.microsoftonline.com`

### Streamlit app loads but shows errors

1. Check the Streamlit logs in `C:\apps\device-scope-dashboard-v2\logs\streamlit_stdout.log`
2. Check if Entra/Intune/AD/Sophos/KACE data sources are accessible
3. For development, run the app manually from the venv to see live output:
```powershell
cd C:\apps\device-scope-dashboard-v2
.\.venv\Scripts\Activate.ps1
streamlit run streamlit_app.py --logger.level=debug
```

---

## Rollback / Uninstall

To remove the service:

```powershell
$nssm = "C:\Windows\System32\nssm.exe"
$serviceName = "DeviceScopeDashboard"

# Stop and remove service
& $nssm stop $serviceName
& $nssm remove $serviceName confirm
```

To preserve app files while uninstalling, do **not** delete `C:\apps\device-scope-dashboard-v2`.

---

## Security Notes

- **Certificate private key**: Restricted to gMSA account and administrators. Regularly audit key permissions.
- **Config file**: Contains non-secret bootstrap IDs (TenantId, ClientId, thumbprint). These are safe in version control but be mindful of accidental credential leaks.
- **Key Vault secrets**: Never stored locally. Retrieved at runtime only. Rotation happens transparently.
- **Logs**: May contain operation messages but not raw credentials. Review log retention policies if sensitive data is logged.
- **gMSA**: Password automatically managed by AD. No manual password reset needed.

---

## Support & Next Steps

- For questions on Entra app configuration, see: [Microsoft Entra app roles](https://learn.microsoft.com/en-us/entra/identity-platform/howto-add-app-roles-in-apps)
- For Key Vault access policies, see: [Azure Key Vault access policies](https://learn.microsoft.com/en-us/azure/key-vault/general/assign-access-policy?tabs=azure-portal)
- For gMSA management, see: [Group Managed Service Accounts](https://learn.microsoft.com/en-us/windows-server/security/group-managed-service-accounts/group-managed-service-accounts-overview)

---

**End of Deployment Guide**
