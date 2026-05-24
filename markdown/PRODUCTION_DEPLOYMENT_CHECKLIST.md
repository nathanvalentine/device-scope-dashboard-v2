# Device Scope Dashboard v2 - Production Deployment Checklist

## ✅ Completion Status: READY FOR DEPLOYMENT

---

## Phase 0: Code & Documentation ✅ COMPLETE

### Implementation
- [x] Azure Key Vault integration (runtime secret retrieval)
- [x] Certificate-based service principal authentication
- [x] Dual-mode Graph API token acquisition
- [x] SharePoint authentication via certificate
- [x] Secure SecureString token conversion
- [x] Config.json externalization with Key Vault support
- [x] DPAPI fallback for backward compatibility

### Testing & Validation
- [x] All authentication flows tested on production host
- [x] Entra/Intune data export validated (751 + 472 devices)
- [x] Sophos integration working
- [x] KACE integration working
- [x] AD integration working
- [x] SharePoint upload successful
- [x] Unit tests passing (25/25)

### Documentation
- [x] DEPLOYMENT_GUIDE.md - 7 phases, 14 steps
- [x] ENHANCEMENTS_COMPLETE.md - All 5 enhancements documented
- [x] FINAL_AUTHENTICATION_SUMMARY.md - Complete reference
- [x] README.md - Project overview
- [x] Code comments - Implementation details

### Git & Version Control
- [x] All changes committed to main branch
- [x] Commits pushed to origin (GitHub)
- [x] Clean git history with descriptive messages

---

## Phase 1: Pre-Deployment Preparation

### ✅ Prerequisites Already Met
- [x] Azure service principal created (ID: 05fbf991-9ba3-43e5-9e5b-2e708215bf66)
- [x] Client authentication certificate issued and installed
- [x] Azure Key Vault provisioned (kv-cvb-prod-westus2-core)
- [x] 3 secrets stored in Key Vault:
  - [x] SophosClientId
  - [x] SophosClientSecret
  - [x] KacePassword

### ✅ Code Ready for Deployment
- [x] scripts/AllDeviceExports_Merge.ps1 - Production-ready
- [x] scripts/test-keyvault-auth.ps1 - Validation ready
- [x] config.json - Production configuration
- [x] streamlit_app.py - Dashboard UI ready
- [x] All dependencies documented

---

## Phase 2: Production Server Setup

### When Ready to Deploy (Follow DEPLOYMENT_GUIDE.md):

**2.1 Host Preparation**
- [ ] Create target folder: C:\apps\device-scope-dashboard-v2
- [ ] Copy application files from repo
- [ ] Create logs and data folders

**2.2 Python Environment**
- [ ] Install Python 3.13+
- [ ] Create virtual environment
- [ ] Install dependencies: `pip install -r requirements.txt`

**2.3 PowerShell Environment**
- [ ] Ensure PowerShell 5.1+ installed
- [ ] Certificate installed in LocalMachine\My
- [ ] Copy config.json to application folder
- [ ] Verify certificate thumbprint: d933e750a76acaa9da82ceb06a230a89c9898fac

**2.4 Certificate Permissions**
- [ ] Grant gMSA account read access to certificate private key
- [ ] Use provided PowerShell commands or DEPLOYMENT_GUIDE.md Phase 3 steps

**2.5 Validation**
- [ ] Run test-keyvault-auth.ps1
- [ ] Confirm all 3 Key Vault secrets retrieved
- [ ] Confirm Graph API connectivity
- [ ] Verify certificate authentication works

---

## Phase 3: Windows Service Setup

### Service Creation (NSSM - Non-Sucking Service Manager)
- [ ] Download NSSM from https://nssm.cc/download
- [ ] Extract to C:\apps\nssm\
- [ ] Create service with gMSA account:
  ```
  nssm install DeviceScopeDashboard `
    "C:\apps\device-scope-dashboard-v2\scripts\AllDeviceExports_Merge.ps1" `
    -ObjectName "CVB\gmsa$" -Password ""
  ```
- [ ] Set service to start automatically: `nssm set DeviceScopeDashboard Start SERVICE_AUTO_START`
- [ ] Configure output redirection to logs folder

### Verification
- [ ] Service created and visible in Services.msc
- [ ] Service runs under gMSA account
- [ ] Service can be started/stopped successfully

---

## Phase 4: Firewall & Network Access

- [ ] Outbound HTTPS to login.microsoftonline.com (port 443)
- [ ] Outbound HTTPS to graph.microsoft.com (port 443)
- [ ] Outbound HTTPS to vault.azure.net (port 443)
- [ ] Outbound HTTPS to api-us01.central.sophos.com (port 443)
- [ ] Outbound HTTP/HTTPS to KACE server
- [ ] LDAP access to Active Directory (port 389)

---

## Phase 5: Operational Configuration

### Data Export Scheduling
- [ ] Schedule AllDeviceExports_Merge.ps1 via Task Scheduler (optional)
- [ ] Configure run frequency (recommend: daily at off-peak time)
- [ ] Set output log directory

### SharePoint Integration
- [ ] Configure TargetFolderShareLink in config.json (if uploading to SharePoint)
- [ ] Test upload completes successfully

### Monitoring
- [ ] Monitor logs/DeviceScope_Export.log for errors
- [ ] Check Key Vault access logs in Azure portal
- [ ] Verify CSV files generated in data/ folder
- [ ] Confirm device counts by source

---

## Phase 6: Dashboard Deployment (Optional)

If deploying Streamlit dashboard to separate host:
- [ ] Install Python + dependencies on dashboard host
- [ ] Copy streamlit_app.py to dashboard folder
- [ ] Configure data folder path
- [ ] Run: `streamlit run streamlit_app.py --server.port 8501`
- [ ] Verify dashboard accessibility

---

## Key Files Reference

| File | Purpose | Location |
|------|---------|----------|
| AllDeviceExports_Merge.ps1 | Main export script | scripts/ |
| test-keyvault-auth.ps1 | Validation script | scripts/ |
| config.json | Configuration | root |
| streamlit_app.py | Dashboard UI | root |
| DEPLOYMENT_GUIDE.md | Step-by-step deployment | root |
| ENHANCEMENTS_COMPLETE.md | Enhancement details | root |
| FINAL_AUTHENTICATION_SUMMARY.md | Auth reference | root |

---

## Troubleshooting Reference

**Symptom**: "No certificate was found in certificate store"
- **Cause**: Certificate not installed on target host
- **Solution**: Install certificate to LocalMachine\My with matching thumbprint

**Symptom**: "Could not find tenant id"
- **Cause**: Service principal not found in tenant
- **Solution**: Verify TenantId and ClientId in config.json

**Symptom**: "Graph REST calls failed: 401 Unauthorized"
- **Cause**: Token acquisition failed (certificate or DPAPI issue)
- **Solution**: Run test-keyvault-auth.ps1 to diagnose

**Symptom**: "Key Vault configuration detected" but secrets not retrieved
- **Cause**: Service account doesn't have Key Vault permissions
- **Solution**: Grant service account Secrets List + Get permissions in Key Vault access policies

---

## Security Checklist

- [x] No plaintext secrets in repositories
- [x] Secrets stored in Azure Key Vault
- [x] Certificate-based auth (no client secret)
- [x] Service account uses gMSA (automatic password management)
- [x] HTTPS for all API communications
- [x] SecureString tokens handled safely
- [x] Audit logging enabled (Key Vault access)
- [x] Config.json not in .gitignore (safe: no secrets)

---

## Support & Reference Documents

**For Azure Key Vault Issues**:
- Docs: https://learn.microsoft.com/en-us/azure/key-vault/

**For Certificate-Based Auth**:
- Docs: https://learn.microsoft.com/en-us/azure/active-directory/develop/certificate-credentials

**For NSSM Service Manager**:
- Site: https://nssm.cc/
- Docs: https://nssm.cc/commands

**For gMSA Setup**:
- Docs: https://learn.microsoft.com/en-us/windows-server/security/group-managed-service-accounts/group-managed-service-accounts-overview

---

## Ready for Production: ✅ YES

**Last Updated**: December 1, 2025  
**Version**: 2.0 with Certificate-Based Authentication  
**Git Commit**: 0f50a84 - Production deployment ready

All authentication flows tested and validated. Application ready to deploy as Windows Service with certificate-based Azure authentication and Key Vault integration.
