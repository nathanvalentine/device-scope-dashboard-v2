# Enhancements Documentation

This document describes the four major enhancements made to improve maintainability, configurability, security, and testability of the Device-Scope-Dashboard.

---

## 1. Consolidated Column Mapping Dictionaries

### Overview
The Python app previously had two separate column mapping dictionaries (`data_table_display_to_actual` and `overview_display_to_actual`) with significant duplication. These have been refactored into a shared base plus context-specific extensions.

### Changes
**File:** `streamlit_app.py` (lines 49-96)

**Before:**
```python
data_table_display_to_actual = {
    "Device Name": "Name",
    "In Entra": "InEntra",
    "In Intune": "InIntune",
    # ... 20+ more fields, many duplicated ...
}

overview_display_to_actual = {
    "Device Name": "Name",
    "In Entra": "InEntra",
    "In Intune": "InIntune",
    # ... similar duplication ...
}
```

**After:**
```python
# Shared core fields (used in both views)
DEVICE_CORE_FIELDS = {
    "Device Name": "Name",
    "In Entra": "InEntra",
    "In Intune": "InIntune",
    # ... 14 shared fields
}

# Data table-specific additions
DATA_TABLE_SPECIFIC_FIELDS = {
    "IP Address": "Sophos_ipv4Addresses",
    # ... 7 data-table-only fields
}

# Overview-specific additions
OVERVIEW_SPECIFIC_FIELDS = {
    "AD DNS Hostname": "AD_DNSHostName",
    # ... 22 overview-only fields
}

# Composed dictionaries (DRY principle)
data_table_display_to_actual = {**DEVICE_CORE_FIELDS, **DATA_TABLE_SPECIFIC_FIELDS}
overview_display_to_actual = {**DEVICE_CORE_FIELDS, **OVERVIEW_SPECIFIC_FIELDS}
```

### Benefits
- **Single source of truth** for shared fields: Update once, applies to both views
- **Reduced duplication:** From ~40 duplicate entries down to 14 shared + 29 specific
- **Easier to extend:** Add new fields in the appropriate category dict
- **Better maintainability:** Clear separation of concerns

### Usage
No changes required in consuming code. The dictionaries work exactly as before:
```python
data_table_display_to_actual  # Same structure, reduced duplication
overview_display_to_actual     # Same structure, reduced duplication
```

---

## 2. Extract DPAPI Configuration to `config.json`

### Overview
Previously, paths to DPAPI secrets and KACE configuration were partially hardcoded in the PowerShell script. Now they're externalized to a `config.json` file for better portability and configurability.

### Changes
**Files:** 
- **New:** `config.json`
- **Modified:** `scripts/AllDeviceExports_Merge.ps1` (CONFIG section, lines 468-540)

**config.json structure:**
```json
{
  "SecureDataFolder": "C:\\Secure",
  "LogsFolder": "C:\\Logs",
  "DpapiSecrets": {
    "MgTenantId": "MgTenantId.bin",
    "MgClientId": "MgClientId.bin",
    "MgClientSecret": "MgClientSecret.bin",
    "SophosClientId": "SophosClientId.bin",
    "SophosClientSecret": "SophosClientSecret.bin",
    "KaceUsername": "KaceUser.bin",
    "KacePassword": "KacePw.bin"
  },
  "KaceBaseUrl": "https://helpdesk.image.local",
  "KaceOrganization": "Default",
  "KaceApiVersion": "5",
  "KacePageLimit": 1000,
  "RetentionDays": 30
}
```

**PowerShell behavior:**
1. Loads `config.json` from project root
2. Uses config values if available and paths exist
3. Falls back to intelligent defaults if config missing or paths don't exist
4. Logs warnings for fallback behavior

### Benefits
- **Portable:** Deploy to different environments without editing PowerShell
- **Versioned:** config.json in git; easy to track changes
- **Centralized:** All configuration in one place
- **Flexible:** Support multiple environments (dev, prod, etc.)

### Usage

**Local development (default config):**
```powershell
# Just run; uses config.json
.\scripts\AllDeviceExports_Merge.ps1
```

**Custom paths:**
Edit `config.json`:
```json
{
  "SecureDataFolder": "D:\\MySecrets",
  "LogsFolder": "D:\\Logs",
  ...
}
```

**Deployment to production:**
```powershell
# Update config.json for prod environment
# Push to repo or deploy separately
.\scripts\AllDeviceExports_Merge.ps1  # Loads prod config automatically
```

### Migration from Old Setup
If you have existing hardcoded paths:
1. Update `config.json` to match your paths
2. No changes needed in PowerShell script (it now loads from config)
3. On upgrade, config.json is automatically used

---

## 3. Unit Tests for Helper Functions

### Overview
Comprehensive pytest test suite for the new Python helper functions (`normalize_bool_column`, `get_existing_columns`, `adjust_count_for_duplicates`).

### Changes
**File:** `test_streamlit_app.py` (new file)

**Test coverage:**
- **normalize_bool_column:** 10 test cases (lowercase/uppercase, numeric, whitespace, mixed types, NaN)
- **get_existing_columns:** 6 test cases (all exist, partial, none, empty, case-sensitive)
- **adjust_count_for_duplicates:** 8 test cases (no dupes, Entra only, Sophos only, both, high counts, edge cases)
- **Integration tests:** 3 realistic scenarios combining helpers

### Running Tests

**Install test dependencies:**
```bash
pip install pytest pandas streamlit
# or use the updated requirements.txt
pip install -r requirements.txt
```

**Run all tests:**
```bash
pytest test_streamlit_app.py -v
```

**Run specific test class:**
```bash
pytest test_streamlit_app.py::TestNormalizeBoolColumn -v
```

**Run with coverage:**
```bash
pip install pytest-cov
pytest test_streamlit_app.py --cov=streamlit_app --cov-report=html
# Opens htmlcov/index.html in browser
```

### Test Examples

**Boolean normalization:**
```python
def test_mixed_input(self):
    """Test mixed input types (strings, ints, bools)."""
    s = pd.Series(['true', 1, False, '0', True, 'false'])
    result = normalize_bool_column(s)
    expected = pd.Series([True, True, False, False, True, False])
    pd.testing.assert_series_equal(result, expected)
```

**Duplicate counting:**
```python
def test_both_duplicates(self):
    """Test when both Entra and Sophos have duplicates."""
    base_count = 10
    series_entra = pd.Series([2, 2, 1, 1])  # extras: 2
    series_sophos = pd.Series([3, 1, 2, 1])  # extras: 3
    result = adjust_count_for_duplicates(base_count, series_entra, series_sophos)
    # 10 + 2 + 3 = 15
    assert result == 15
```

### Benefits
- **Confidence:** Know that helpers work correctly
- **Regression prevention:** Tests catch breaking changes
- **Documentation:** Tests show how functions are supposed to be used
- **Maintainability:** Easier to refactor with test coverage

---

## 4. DPAPI Secret Initialization Script

### Overview
A new PowerShell script that securely prompts for credentials and encrypts them using Windows DPAPI, storing them as binary files that can only be decrypted on the same machine.

### Changes
**File:** `scripts/Initialize-DpapiSecrets.ps1` (new file)

**Features:**
- Interactive secret prompts (uses `Read-Host -AsSecureString` for secure input)
- DPAPI encryption with `LocalMachine` scope (tied to machine)
- Automatic target folder creation
- Validation and error handling
- Skip optional secrets (Sophos, KACE)
- Summary report at end

### Usage

**Basic usage:**
```powershell
.\scripts\Initialize-DpapiSecrets.ps1 -TargetFolder C:\Secure
```

**Prompts for:**
1. Microsoft Graph Tenant ID (required)
2. Microsoft Graph Client ID (required)
3. Microsoft Graph Client Secret (required)
4. Sophos Client ID (optional)
5. Sophos Client Secret (optional)
6. KACE Username (optional)
7. KACE Password (optional)

**Output:**
```
================================
DPAPI Secret Initialization
================================

Target folder: C:\Secure

Enter secrets interactively. Secrets will be encrypted with DPAPI and stored as binary files.

Enter Microsoft Graph Tenant ID (Azure AD Directory ID):
[Secure input, not echoed]
✓ Saved MgTenantId to C:\Secure\MgTenantId.bin

... [more prompts] ...

================================
Initialization Complete
================================

✓ Successfully encrypted and saved: 7 secrets
⊘ Skipped (optional): (none)

Location: C:\Secure

Next steps:
1. Verify that files were created in C:\Secure :
   Get-ChildItem -Path C:\Secure -Filter *.bin
...
```

### Security Notes

**Machine-specific encryption:**
- Secrets encrypted with `DataProtectionScope.LocalMachine`
- Can only be decrypted on the same machine
- Machine key is used; no user login required

**Service account scenario:**
- If running as a Windows Service under a service account, run this script under that same account:
  ```powershell
  # Run as service account (if using RUNAS or automation)
  runas /user:DOMAIN\svc-devicescope powershell
  .\scripts\Initialize-DpapiSecrets.ps1 -TargetFolder C:\Secure
  ```

**Alternative for centralized secrets:**
- For multi-machine environments, consider using Azure Key Vault, HashiCorp Vault, or 1Password
- This DPAPI approach works well for single on-prem server

### Integration with AllDeviceExports_Merge.ps1

The script automatically uses encrypted secrets:
```powershell
# In AllDeviceExports_Merge.ps1, secrets are loaded via:
$MgTenantId = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "MgTenantId.bin")
# Decrypts and returns plaintext (only in memory)
```

No changes needed; the PowerShell script already knows how to decrypt.

### First-time Setup Workflow

1. **Prepare secrets:**
   - Gather Tenant ID, Client ID, Client Secret, etc.

2. **Run initialization:**
   ```powershell
   .\scripts\Initialize-DpapiSecrets.ps1 -TargetFolder C:\Secure
   ```

3. **Verify:**
   ```powershell
   Get-ChildItem C:\Secure -Filter *.bin
   # Output: MgTenantId.bin, MgClientId.bin, MgClientSecret.bin, ...
   ```

4. **Test:**
   ```powershell
   .\scripts\AllDeviceExports_Merge.ps1
   # Should run without prompting for secrets
   ```

### Troubleshooting

**"Failed to decrypt DPAPI secret"**
- Ensure you're running on the same machine where secrets were encrypted
- If using service account, run script under that account
- Check file permissions (user must have read access to .bin files)

**"Cannot write to target folder"**
- Check folder permissions
- Ensure user has write access to the target folder

**Secrets file not found**
- Run `Initialize-DpapiSecrets.ps1` again
- Verify the TargetFolder path in config.json

---

## Summary of Changes

| Item | File(s) | Type | Benefit |
|------|---------|------|---------|
| Column consolidation | `streamlit_app.py` | Refactor | Reduced duplication, easier to maintain |
| Config externalization | `config.json`, `scripts/AllDeviceExports_Merge.ps1` | New + refactor | Better portability, centralized config |
| Unit tests | `test_streamlit_app.py` | New | Test coverage, regression prevention |
| DPAPI initialization | `scripts/Initialize-DpapiSecrets.ps1` | New | Automated secure secret setup |
| Dependencies | `requirements.txt` | Update | Added pytest for testing |

---

## Integration Checklist

- [x] Column mapping consolidation deployed
- [x] config.json created and integrated
- [x] AllDeviceExports_Merge.ps1 updated to load config
- [x] Unit tests created (40+ test cases)
- [x] DPAPI initialization script created
- [x] requirements.txt updated with pytest
- [ ] Run `pytest test_streamlit_app.py -v` to verify tests pass
- [ ] Update existing deployments to use `config.json` and `Initialize-DpapiSecrets.ps1`
- [ ] Document in team wiki or deployment runbook

---

## Next Steps

**For immediate use:**
1. Run tests: `pytest test_streamlit_app.py -v`
2. Initialize secrets: `.\scripts\Initialize-DpapiSecrets.ps1 -TargetFolder C:\Secure`
3. Update `config.json` if needed for your environment
4. Test the export script: `.\scripts\AllDeviceExports_Merge.ps1`

**For deployment:**
1. Include `config.json` in deployment package
2. Include `Initialize-DpapiSecrets.ps1` in runbook
3. Consider environment-specific `config.json` variants (dev/prod)
4. Update deployment documentation

**For future:**
- Consider multi-environment config (e.g., `config.prod.json`, `config.dev.json`)
- Add GitHub Actions to run tests on PR
- Document in internal wiki for IT team

