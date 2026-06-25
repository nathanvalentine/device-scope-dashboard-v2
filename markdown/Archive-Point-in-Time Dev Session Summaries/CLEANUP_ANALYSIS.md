# Code Cleanup & Deduplication Analysis

**Date:** Generated after functional verification
**Scope:** `streamlit_app.py` (540 lines) and `AllDeviceExports_Merge.ps1` (1122 lines)

---

## Executive Summary

Both files have healthy structure and are largely well-organized. However, there are **3 categories of cleanup opportunities**:

1. **Redundant Code** (repeated logic within files)
2. **Non-Portable Assumptions** (Windows-specific paths, hardcoded values)
3. **Minor Optimization** (simplification without refactoring)

**Estimated effort:** Low to Medium. These are quality-of-life improvements, not architectural changes.

---

## Category 1: Redundant Code (High Priority)

### 1.1 Boolean Column Normalization - DUPLICATE LOGIC
**File:** `streamlit_app.py`
**Lines:** 149-151, 159-161, 397-399, 427-429 (and variations)

**Issue:** The same boolean normalization pattern appears 4+ times:
```python
df[col] = df[col].astype(str).str.strip().str.lower().replace({"true": True, "false": False, "1": True, "0": False})
df[col] = df[col].astype(bool)
```

**Affected functions:** `count_all_5_contexts()`, `count_multi_instance_devices()`, context filter section, heatmap section

**Recommendation:** Extract into a helper function
```python
def normalize_bool_column(series):
    """Convert string booleans ('true'/'false'/'1'/'0') to Python bool."""
    return series.astype(str).str.strip().str.lower()\
        .replace({"true": True, "false": False, "1": True, "0": False})\
        .astype(bool)
```

**Impact:** Reduces ~20 lines of duplicated logic, improves maintainability

---

### 1.2 CSV Column List Building - DUPLICATE APPROACH
**File:** `streamlit_app.py`
**Lines:** 319-324 (data table), 551-552 (overview)

**Issue:** The same pattern of filtering available columns from a mapping dict appears twice:
```python
# Data table version (line 319)
existing_actual = [actual for display, actual in data_table_display_to_actual.items() if actual in df.columns]

# Overview version (line 551)
existing_actual = [actual for actual in overview_display_to_actual.values() if actual in df.columns]
```

**Recommendation:** Create a generic helper
```python
def get_existing_columns(mapping_dict, dataframe):
    """Return list of actual column names from mapping that exist in dataframe."""
    if isinstance(mapping_dict, dict) and any(isinstance(k, str) for k in mapping_dict.keys()):
        # It's a display->actual mapping
        return [actual for display, actual in mapping_dict.items() if actual in dataframe.columns]
    else:
        # It's a direct list of column names
        return [col for col in mapping_dict if col in dataframe.columns]
```

**Impact:** Reduces ~4 lines, clarifies intent

---

### 1.3 Instance Count Calculations - DUPLICATE FORMULA
**File:** `streamlit_app.py`
**Lines:** 135-141 (count_total_devices), 143-158 (count_all_5_contexts), 365-374 (heatmap)

**Issue:** The pattern for adding duplicate instance counts is repeated:
```python
base_count = len(df)  # or df[mask].sum() etc
extra_entra = (df["Entra_InstanceCount"] - 1).clip(lower=0).sum()
extra_sophos = (df["Sophos_InstanceCount"] - 1).clip(lower=0).sum()
adjusted_total = int(base_count + extra_entra + extra_sophos)
```

**Recommendation:** Extract into utility function
```python
def adjust_count_for_duplicates(base_count, series_entra, series_sophos):
    """Add extra instances from multi-instance devices."""
    extra_entra = (series_entra - 1).clip(lower=0).sum()
    extra_sophos = (series_sophos - 1).clip(lower=0).sum()
    return int(base_count + extra_entra + extra_sophos)
```

**Impact:** Reduces ~10 lines of duplicate arithmetic, centralizes the duplication logic

---

### 1.4 Context Filter Application - REPETITIVE STRUCTURE
**File:** `streamlit_app.py`
**Lines:** 427-455

**Issue:** 5 nearly-identical context filter blocks (Entra, Intune, AD, Sophos, KACE) with only column names changing:

```python
elif selected_context == "Devices in Entra":
    if exclusive_only:
        filtered_df = filtered_df[
            (filtered_df["In Entra"]) &
            (~filtered_df[["In Intune", "In AD", "In Sophos", "In KACE"]].any(axis=1))
        ]
    else:
        filtered_df = filtered_df[filtered_df["In Entra"]]
# ... repeat 4 more times ...
```

**Recommendation:** Use data-driven approach
```python
CONTEXT_MAPPINGS = {
    "Devices in Entra": "In Entra",
    "Devices in Intune": "In Intune",
    "Devices in AD": "In AD",
    "Devices in Sophos": "In Sophos",
    "Devices in KACE": "In KACE",
}

OTHER_CONTEXTS = {
    "In Entra": ["In Intune", "In AD", "In Sophos", "In KACE"],
    "In Intune": ["In Entra", "In AD", "In Sophos", "In KACE"],
    "In AD": ["In Entra", "In Intune", "In Sophos", "In KACE"],
    "In Sophos": ["In Entra", "In Intune", "In AD", "In KACE"],
    "In KACE": ["In Entra", "In Intune", "In AD", "In Sophos"],
}

# Then:
if selected_context in CONTEXT_MAPPINGS:
    col = CONTEXT_MAPPINGS[selected_context]
    if exclusive_only:
        others = OTHER_CONTEXTS[col]
        filtered_df = filtered_df[
            (filtered_df[col]) & (~filtered_df[others].any(axis=1))
        ]
    else:
        filtered_df = filtered_df[filtered_df[col]]
```

**Impact:** Reduces ~30 lines, makes it trivial to add a new context

---

## Category 2: Non-Portable Assumptions (High Priority)

### 2.1 Hardcoded Paths - WINDOWS-SPECIFIC
**File:** `AllDeviceExports_Merge.ps1`
**Lines:** 468-470, 554-556, 559-561, 564-566, 576-580

**Issue:** DPAPI secret paths and log folders are hardcoded to `C:\` drives:
```powershell
$MgTenantId = Get-DpapiSecret -Path "C:\Secure\MgTenantId.bin"
$KaceUsername = Get-DpapiSecret -Path "C:\Secure\KaceUser.bin"
$UploadLogDir = "C:\Logs"
$DeleteLogDir = "C:\logs"  # Typo: inconsistent casing
```

**Recommendation:** Make configurable
```powershell
# CONFIG SECTION - make it easy to customize
$SecureDataFolder = if (Test-Path "C:\Secure") { "C:\Secure" } else { "$env:USERPROFILE\AppData\Local\DeviceScope\Secure" }
$LogsFolder = if (Test-Path "C:\Logs") { "C:\Logs" } else { "$env:TEMP\DeviceScope" }

# Then use:
$MgTenantId = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "MgTenantId.bin")
```

**Impact:** Makes script portable across machines without manual edits; fixes `C:\logs` typo casing

---

### 2.2 Hardcoded SharePoint URL - CONFIGURATION VARIABLE
**File:** `AllDeviceExports_Merge.ps1`
**Line:** 551

**Issue:** SharePoint folder share link is hardcoded:
```powershell
$TargetFolderShareLink = "https://cachevalleybank.sharepoint.com/:f:/s/m365appbuilder-devicescope-1110/IgA7_c00SIQ2QKpThfWjiMT-AWleUZWOXmbutpzUKv4akMU?e=CP1wea"
```

**Recommendation:** Move to a configuration file or environment variable:
```powershell
# At the top, with other config:
$SharePointConfigFile = Join-Path (Split-Path $PSScriptRoot) "sharepoint.config"
if (Test-Path $SharePointConfigFile) {
    $spConfig = Get-Content $SharePointConfigFile | ConvertFrom-Json
    $TargetFolderShareLink = $spConfig.TargetFolderShareLink
} else {
    Write-Warning "SharePoint config not found. Upload will be skipped."
    $TargetFolderShareLink = $null
}
```

**Impact:** Enables deployment to different SharePoint sites without code changes

---

### 2.3 Inconsistent Path Separator Handling
**File:** `AllDeviceExports_Merge.ps1`
**Line:** 531

**Issue:** Dynamic path resolution uses forward slashes in Join-Path chain; PowerShell handles this but it's clearer to be explicit:
```powershell
# Current (works but non-idiomatic):
$dataFolder = Join-Path -Path $PSScriptRoot -ChildPath ".." | Join-Path -ChildPath "data"
```

**Recommendation:** Use intermediate variable for clarity
```powershell
$parentDir = Join-Path -Path $PSScriptRoot -ChildPath ".."
$dataFolder = Join-Path -Path $parentDir -ChildPath "data"
$dataFolder = (Resolve-Path $dataFolder -ErrorAction Stop).Path
```

**Impact:** Improves readability; already implemented, just documenting it

---

## Category 3: Minor Optimizations & Observations

### 3.1 Unused/Commented Code
**File:** `AllDeviceExports_Merge.ps1`
**Lines:** 1097-1122 (commented out deletion block)

**Issue:** Large commented-out deletion logic at end of script

**Recommendation:** Remove if no longer needed, or move to separate script if keeping for reference
```powershell
# REMOVE or MOVE TO: scripts/CleanupOldFiles.ps1
```

**Impact:** Cleaner code, less confusion

---

### 3.2 Redundant Session State Check
**File:** `streamlit_app.py`
**Lines:** 302-304

**Issue:** Session state is initialized before use, which is good, but the refresh button disabling logic creates a brief UX gap during the wait loop

**Observation:** This is a design choice (prevent double-clicks) rather than a bug. Currently acceptable.

---

### 3.3 Two Similar Column Mapping Dictionaries
**File:** `streamlit_app.py`
**Lines:** 49-76 (data_table_display_to_actual) vs 78-96 (overview_display_to_actual)

**Issue:** 40 keys overlap between the two dictionaries; many mappings are identical:
- Both have: Name, Device Type, OS, Sophos_Health, KACE_Machine_RAM_Total, etc.

**Observation:** The dictionaries serve different purposes (data table row filtering vs. device overview display), so complete consolidation isn't warranted. However, consider:

```python
# Shared core mappings
DEVICE_CORE_FIELDS = {
    "Device Name": "Name",
    "In Entra": "InEntra",
    "In Intune": "InIntune",
    # ... etc
}

# Extend with context-specific fields
data_table_display_to_actual = {
    **DEVICE_CORE_FIELDS,
    "Entra Device Instance Count": "Entra_InstanceCount",
    # data-table-specific
}

overview_display_to_actual = {
    **DEVICE_CORE_FIELDS,
    "AD DNS Hostname": "AD_DNSHostName",
    # overview-specific
}
```

**Impact:** Reduces maintenance burden if many fields are added; makes inheritance obvious

---

### 3.4 KACE Instance Count Commented Out
**File:** `AllDeviceExports_Merge.ps1`
**Lines:** 976-978

**Issue:** KACE duplication fields are commented:
```powershell
# KACE_InstanceCount = $KACE_InstanceCount
# KACE_DuplicateFlag = $KACE_DuplicateFlag
# KACE_IDs = $KACE_IDs
```

**Observation:** This is intentional (KACE rarely has duplicates if naming is clean). Document the rationale with a comment for future maintainers.

---

### 3.5 PowerShell Get-Readable Function - Possible Consolidation
**File:** `AllDeviceExports_Merge.ps1`
**Lines:** 82-100

**Issue:** There are multiple value-reading helper functions with similar purposes:
- `Get-Readable` (lines 82-100)
- `Get-AnyReadableFromSources` (lines 103-116)
- `Get-AnyFromSources` (lines 848-859)

**Observation:** These have slightly different contracts (single value vs. array of sources), so consolidation would be complex. Current organization is acceptable; add comments to clarify differences if not already clear.

---

## Summary Table: Quick Reference

| Issue | File | Lines | Type | Effort | Impact |
|-------|------|-------|------|--------|--------|
| Bool column normalization | Streamlit | 149-151, 159-161, 397-399, 427-429 | Duplication | Low | High |
| CSV column list building | Streamlit | 319-324, 551-552 | Duplication | Low | Low |
| Instance count calculations | Streamlit | 135-141, 143-158, 365-374 | Duplication | Low | Medium |
| Context filter application | Streamlit | 427-455 | Duplication | Medium | High |
| Hardcoded DPAPI paths | PowerShell | 468-470, 554-566 | Non-portable | Medium | High |
| Hardcoded SharePoint URL | PowerShell | 551 | Non-portable | Low | Medium |
| Path separator handling | PowerShell | 531 | Clarity | Low | Low |
| Unused code (deletion block) | PowerShell | 1097-1122 | Clutter | Low | Low |
| Two column mapping dicts | Streamlit | 49-96 | Maintenance | Low | Low |
| KACE duplication commented | PowerShell | 976-978 | Documentation | Trivial | Low |

---

## Recommended Implementation Order

**Phase 1 (Quick Wins - 30 min):**
1. Extract `normalize_bool_column()` helper
2. Create `get_existing_columns()` helper
3. Add comments to explain intentional patterns (KACE, column dicts)

**Phase 2 (Portability - 45 min):**
4. Refactor hardcoded paths → configurable (DPAPI, logs)
5. Extract SharePoint URL → config file

**Phase 3 (Architecture - 1 hour):**
6. Extract instance count adjustment logic
7. Refactor context filter with data-driven approach
8. Consider column mapping consolidation

**Phase 4 (Polish - 15 min):**
9. Remove commented deletion code
10. Final review and testing

---

## Notes

- **No architectural changes needed.** Both files have sound design.
- **No missing error handling.** DPAPI, API calls, and file I/O are all wrapped.
- **No performance issues.** Both files are well within acceptable execution time.
- **Cross-file deduplication is minimal.** PowerShell and Python serve different roles; minimal duplication between them.

