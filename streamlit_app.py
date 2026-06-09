import streamlit as st
import re
import pandas as pd
import os
import glob
import subprocess
import time
from datetime import datetime, timedelta
import plost
from pathlib import Path
import altair as alt

# ===============================
# ---------- Constants ----------
# ===============================
CVB_SQ_ICON = "images/CVB-Acorn-Monogram-Detailed-sq-16.ico"
CVB_RECTANGULAR_LOGO = "images/CVB_Logo_Teams.png"
CVB_SQ_LOGO = "images/CVB-Acorn-Monogram-Detailed-sq-48.png"
RAM_TOTAL_COL = "KACE_Machine_RAM_Total"

# ---------- Path constants ----------
APP_DIR = Path(__file__).resolve().parent
CSS_PATH = APP_DIR / "style.css"

# ---------- Column name constants ----------
PRESENCE_BOOL_COLS = [
    "InEntra", "InIntune", "InAD", "InSophos", "InKACE", "InEventSentry"
]
PRESENCE_BOOL_COLS_RENAMED = [
    "In Entra", "In Intune", "In AD", "In Sophos", "In KACE", "In EventSentry"
]
MULTI_INSTANCE_COL = "MultiInstanceFlag"  # boolean or int > 0 means multi-instance

SUBNET_TO_BRANCH = {
    "10.157.0.": "Logan Production",
    "10.157.1.": "Logan Production",
    "10.157.15.": "Logan Administration",
    "10.157.16.": "Mortgage",
    "10.157.18.": "South Logan",
    "10.157.20.": "Hyrum",
    "10.157.21.": "Ogden",
    "10.157.22.": "Smithfield",
    "10.157.23.": "Logan Mall",
    "10.157.24.": "SLC",
    "10.157.26.": "Preston",
    "10.157.27.": "Cedar City",
    "10.157.29.": "Lehi",
    "10.157.41.": "Washington",
    "10.157.42.": "Sunset",
    "10.157.43.": "River Road",
    "10.157.44.": "Layton",
    "10.157.46.": "DR",
    "10.157.47.": "North Logan",
    "10.157.48.": "Logan Main",
    "10.157.49.": "Logan Main",
    "10.157.50.": "Logan Printers",
    "10.157.51.": "Fairview",
    "10.157.52.": "Mount Pleasant",
    "10.157.53.": "Loa",
    "10.157.54.": "Bountiful",
    "10.157.55.": "Price",
    "10.157.56.": "Nephi",
    "10.157.57.": "Ephraim",
    "10.157.58.": "Tabernacle",
    "10.157.59.": "Tabernacle"
}

# ==================================================
# ---------- Variables/Lists/Dictionaries ----------
# ==================================================
# ---------- Configurable paths ----------
csv_dir = APP_DIR / "data"
csv_pattern = "DeviceScope_Merged*.csv"
powershell_script = APP_DIR / "scripts" / "AllDeviceExports_Merge.ps1"

# ---------- Context filter (sidebar) ----------
context_options = [
    "Show all devices", "Devices in Entra", "Devices in Intune", "Devices in AD",
    "Devices in Sophos", "Devices in KACE", "Devices in EventSentry", "Devices in all systems"
]

# Data-driven context mappings for simplified filter logic
CONTEXT_COLUMN_MAP = {
    "Devices in Entra": "In Entra",
    "Devices in Intune": "In Intune",
    "Devices in AD": "In AD",
    "Devices in Sophos": "In Sophos",
    "Devices in KACE": "In KACE",
    "Devices in EventSentry": "In EventSentry"
}

CONTEXT_EXCLUSIONS = {
    "In Entra": ["In Intune", "In AD", "In Sophos", "In KACE", "In EventSentry"],
    "In Intune": ["In Entra", "In AD", "In Sophos", "In KACE", "In EventSentry"],
    "In AD": ["In Entra", "In Intune", "In Sophos", "In KACE", "In EventSentry"],
    "In Sophos": ["In Entra", "In Intune", "In AD", "In KACE", "In EventSentry"],
    "In KACE": ["In Entra", "In Intune", "In AD", "In Sophos", "In EventSentry"],
    "In EventSentry": ["In Entra", "In Intune", "In AD", "In Sophos", "In KACE"]
}

# ---------- Shared core device fields (used in both data table and overview) ----------
DEVICE_CORE_FIELDS = {
    "Device Name": "Name",
    "In Entra": "InEntra",
    "In Intune": "InIntune",
    "In AD": "InAD",
    "In Sophos": "InSophos",
    "In KACE": "InKACE",
    "In EventSentry": "InEventSentry",
    "Physical Device Location": "DerivedLocation",
    "Health": "DeviceHealth",
    "Health Reason": "HealthReason",
    "Device Type": "DeviceType",
    "OS": "OS",
    "Sophos Health": "Sophos_Health",
    "Total Memory (GB)": "MemoryDisplay",
    "Duplicate Devices": "MultiInstanceFlag",
    "Last Seen": "LastSeen",
    "Primary User": "PrimaryUser",
    "AD Object GUID": "AD_ObjectGUID",
    "Entra Device ID(s)": "Entra_DeviceIds",
    "Intune Entra Device ID": "Intune_AzureADDeviceIds",
    "EventSentry Stale": "EventSentry_Stale",
    "EventSentry Age (Days)": "EventSentry_AgeDays"
}

# ---------- Data table-specific fields (extends core) ----------
DATA_TABLE_SPECIFIC_FIELDS = {
    "IP Address": "Sophos_ipv4Addresses",
    "Entra Device Instance Count": "Entra_InstanceCount",
    "Entra Hybrid Joined": "Entra_HybridCount",
    "Entra Device ID Matches AD Object GUID": "Entra_HybridIdMatchesAD",
    "Entra Device ID Mismatches AD Object GUID": "Entra_HybridIdMismatchExists",
    "Entra Registered": "Entra_RegisteredCount",
    "Sophos Device Instance Count": "Sophos_InstanceCount"
}

# ---------- Overview table-specific fields (extends core) ----------
OVERVIEW_SPECIFIC_FIELDS = {
    "AD DNS Hostname": "AD_DNSHostName",
    "Serial Number": "SerialNumber",
    "Device Management Lists": "Contexts",
    "Operating System": "KACE_Os_name",
    "Entra OS Version": "Entra_OperatingSystemVersion",
    "IPv4 Address": "KACE_Machine_Ip",
    "AD Device Object Enabled": "AD_Enabled",
    "AD Last Logon Date": "AD_LastLogonDate",
    "Entra Join Type": "Entra_JoinType",
    "Has a duplicate in Entra": "Entra_DuplicateFlag",
    "Has a duplicate in Intune": "Intune_DuplicateFlag",
    "Has a duplicate in Sophos": "Sophos_DuplicateFlag",
    "Intune Device ID": "Intune_DeviceId",
    "Sophos ID(s)": "Sophos_Ids",
    "KACE ID": "KACE_ID",
    "Intune Endpoint Management Agent": "Intune_ManagementAgent",
    "Intune Compliance State": "Intune_ComplianceState",
    "Entra Compliant": "Entra_IsCompliant",
    "Entra Managed": "Entra_IsManaged",
    "EventSentry Agent Present": "EventSentry_AgentPresent",
    "EventSentry Agent Version": "EventSentry_AgentVersion",
    "EventSentry Inventory Timestamp": "EventSentry_InventoryTimestamp",
    "EventSentry Age (Days)": "EventSentry_AgeDays",
    "EventSentry Stale": "EventSentry_Stale",
    "ES Stale While Active": "Anomaly_ES_StaleWhileActive",
    "ES Missing While Active": "Anomaly_ES_MissingWhileActive"
}

# ---------- Column display name mapping: display header -> actual CSV column in Data table (Row C) ----------
data_table_display_to_actual = {**DEVICE_CORE_FIELDS, **DATA_TABLE_SPECIFIC_FIELDS}

# ---------- Column display name mapping: display header -> actual CSV column in Device overview table (Row D) ----------
overview_display_to_actual = {**DEVICE_CORE_FIELDS, **OVERVIEW_SPECIFIC_FIELDS}

# ======================================= 
# ---------- Helpers/Functions ----------
# =======================================

# The following HELPER function was generated by Copilot on 5/24/2026 while other parts of the solution were cleaned up, tested, and improved for robustness and maintainability.
# ---------- HELPER: Normalize string booleans to pandas nullable boolean and then True/False only ----------
def normalize_bool_column(series):
    
    """
    Convert string booleans ('true'/'false'/'1'/'0') and mixed types
    to strict Python bool dtype (True/False only).
    Handles case-insensitivity and whitespace.
    Unmapped/blank/null values become False.
    
    NOTE:
    Any non-recognized or null value is treated as False.
    This ensures deterministic filtering and avoids nullable boolean behavior.
    """

    cleaned = series.astype(str).str.strip().str.lower()

    # ✅ Use map instead of replace to avoid pandas downcasting warning entirely
    # Map common truthy/falsy string representations to boolean values
    mapped = cleaned.map({
        "true": True,
        "false": False,
        "1": True,
        "0": False
    })

    # ✅ Fix warning by controlling dtype BEFORE fillna
    mapped = mapped.astype("boolean")  # nullable boolean

    # Enforce True/False only (no <NA>)
    return mapped.fillna(False).astype(bool) # now safe + no warning

# ---------- HELPER: Get existing columns from mapping dict ----------
def get_existing_columns(mapping_dict, dataframe):
    """
    Extract column names from a display->actual mapping dict that exist in dataframe.
    
    Args:
        mapping_dict: Either {display_name: actual_col_name} or list of column names
        dataframe: DataFrame to check columns against
    
    Returns:
        List of actual column names that exist in dataframe
    """
    return [actual for display, actual in mapping_dict.items() if actual in dataframe.columns]

# ---------- HELPER: Adjust count for multi-instance duplicates ----------
def adjust_count_for_duplicates(base_count, series_entra, series_sophos):
    """
    Account for devices with multiple instances across sources.
    
    Args:
        base_count: Number of base devices (or filtered device count)
        series_entra: Entra_InstanceCount series (or filtered series)
        series_sophos: Sophos_InstanceCount series (or filtered series)
    
    Returns:
        Adjusted total including all duplicate instances
    """
    extra_entra = (series_entra - 1).clip(lower=0).sum()
    extra_sophos = (series_sophos - 1).clip(lower=0).sum()
    return int(base_count + extra_entra + extra_sophos)

# ---------- HELPER: Find the latest CSV file ----------
def get_latest_csv():
    files = glob.glob(os.path.join(csv_dir, csv_pattern))
    if not files:
        return None
    latest = max(files, key=os.path.getmtime)
    return latest

# The following helper functions are used in multiple places to ensure consistent preprocessing of boolean and numeric columns across the app, especially before filtering and counting operations.
# This ensures that all boolean columns are properly normalized to True/False and all numeric columns are coerced to numbers (with non-convertible values treated as 0), 
# which is crucial for accurate filtering, counting, and display in the dashboard.
# By centralizing this logic in helper functions, we avoid code duplication and ensure that any changes to the normalization logic are applied consistently throughout the app.
# For example, before applying filters based on context presence or calculating metrics that depend on instance counts, we can call these helper functions to ensure the data is in the correct format. 
# This is especially important given that the source CSV may have inconsistent formatting for boolean and numeric fields.
# Additionally, this approach allows us to handle any edge cases (like unexpected string values in boolean columns or non-numeric values in instance count columns) in a single place, improving the robustness of the app.
# Note: These normalization steps are idempotent, so they can be safely called multiple times without altering already normalized data.
# Example usage:
# df = normalize_boolean_columns(df, PRESENCE_BOOL_COLS + PRESENCE_BOOL_COLS_RENAMED + [MULTI_INSTANCE_COL])
# df = normalize_numeric_columns(df, ["Entra_InstanceCount", "Sophos_InstanceCount", "Intune_InstanceCount"])
# The following HELPER functions were generated by Copilot on 5/24/2026 while other parts of the solution were cleaned up, tested, and improved for robustness and maintainability.
# ---------- HELPER: Normalize multiple boolean columns ----------
def normalize_boolean_columns(df: pd.DataFrame, columns: list[str]) -> pd.DataFrame:
    for col in columns:
        if col in df.columns:
            df[col] = normalize_bool_column(df[col])
    return df


# ---------- HELPER: Normalize numeric columns ----------
def normalize_numeric_columns(df: pd.DataFrame, columns: list[str]) -> pd.DataFrame:
    for col in columns:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0)
    return df

# ---------- HELPER: Derive branch from IP ----------
def get_branch_from_ip(ip: str) -> str:
    """
    Determine branch/location from IP address based on subnet mapping.
    Returns empty string if no match is found.
    """
    if not ip or pd.isna(ip):
        return ""

    ip = str(ip)

    for subnet, branch in SUBNET_TO_BRANCH.items():
        if ip.startswith(subnet):
            return branch

    return "Unknown"

# ---------- HELPER: Derive device health status ----------
# This function derives an overall health status for each device based on the presence of anomalies or staleness in EventSentry data, as well as the health status reported by Sophos. The logic is as follows:
# - If the device has an EventSentry anomaly while active, it is considered "Critical" (🚨).
# - If the device has EventSentry staleness while active, or if Sophos reports a health status that is not "Healthy" or "Good", it is considered "Warning" (⚠).
# - If none of the above conditions are met, the device is considered "Healthy" (✅).
# This was added by Copilot on 6/6/2026 to extend the device dashboard's health insights by incorporating new data points from EventSentry, 
# which was added as a new data source in the PowerShell export script. By deriving a composite health status, 
# we can provide users with a quick visual indicator of potential issues with each device based on multiple sources of information.
def derive_device_health(row):
    has_sophos = bool(row.get("InSophos"))
    sophos_health = str(row.get("Sophos_Health", "")).lower()
    # if row.get("Anomaly_ES_MissingWhileActive"):
    #     return "🚨 Critical"
    if row.get("IsEventSentryRelevant") and row.get("Anomaly_ES_MissingWhileActive"):
        return "🚨 Critical"
    # elif row.get("Anomaly_ES_StaleWhileActive"):
    #     return "⚠ Warning"
    elif row.get("IsEventSentryRelevant") and row.get("Anomaly_ES_StaleWhileActive"):
        return "⚠ Warning"
    elif row.get("MultiInstanceFlag"):
            return "⚠ Warning"
    elif has_sophos and sophos_health not in ["healthy", "good", ""]:
        return "⚠ Warning"
    else:
        return "✅ Healthy"

# ---------- HELPER: Derive health reason details ----------
# This function provides detailed reasons for the health status derived in the previous function. 
# It checks for specific conditions such as EventSentry anomalies, staleness, and Sophos health issues, 
# and compiles a list of reasons that explain why a device might be flagged as "Critical" or "Warning". 
# This allows users to understand the underlying issues contributing to a device's health status at a glance.
def derive_health_reason(row):
    reasons = []

    # EventSentry logic (only if relevant)
    if row.get("IsEventSentryRelevant") and row.get("Anomaly_ES_MissingWhileActive"):
        reasons.append("Missing EventSentry agent while device is active")

    elif row.get("IsEventSentryRelevant") and row.get("Anomaly_ES_StaleWhileActive"):
        reasons.append("EventSentry data is stale while device is active")

    # Duplicate logic
    if row.get("MultiInstanceFlag"):
        reasons.append("Duplicate device detected across systems")

    # Sophos logic (only if present)
    sophos_health = str(row.get("Sophos_Health", "")).lower()
    if row.get("InSophos") and sophos_health not in ["healthy", "good", ""]:
        reasons.append(f"Sophos health is '{row.get('Sophos_Health')}'")

    if not reasons:
        return "No issues detected"

    return "; ".join(reasons)

# ---------- HELPER: Full preprocessing pipeline ----------
def preprocess_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    # ---------- Boolean columns ----------
    bool_columns = (
        PRESENCE_BOOL_COLS +
        PRESENCE_BOOL_COLS_RENAMED +
        [MULTI_INSTANCE_COL]
    )
    df = normalize_boolean_columns(df, bool_columns)

    # ---------- Numeric columns ----------
    numeric_columns = [
        "Entra_InstanceCount",
        "Sophos_InstanceCount",
        "Intune_InstanceCount"
    ]
    df = normalize_numeric_columns(df, numeric_columns)

    # ---------- Derive branch location from IP ----------
    if "KACE_Machine_Ip" in df.columns:
        df["DerivedLocation"] = df["KACE_Machine_Ip"].apply(get_branch_from_ip)
    else:
        df["DerivedLocation"] = ""

    return df

# ---------- HELPER: Format display values ----------
def format_display_value(val):
    """
    Format values for display:
    - Remove .0 from whole-number floats
    - Preserve real floats
    - Convert NaN to empty string
    """
    if pd.isna(val):
        return ""

    # If float but whole number → convert to int
    if isinstance(val, float) and val.is_integer():
        return str(int(val))

    return str(val)

# ---------- HELPER: Highlight health status in Data table ----------
def highlight_health(val):
    if isinstance(val, str):
        if "🚨" in val:
            return "color: red; font-weight: bold;"
        elif "⚠" in val:
            return "color: orange; font-weight: bold;"
        elif "✅" in val:
            return "color: green; font-weight: bold;"
    return ""

# ---------- HELPER: Clean values for display (handle NaN and "nan" strings) ----------
def clean(val):
    if pd.isna(val) or val in ["nan", "NaN", None]:
        return ""
    return val

def parse_mb(val):
    """Parse values like '16384', '16384 MB', 16384.0 into numeric MB."""
    if pd.isna(val):
        return float("nan")

    s = str(val).strip().lower()
    if s in {"", "nan", "none"}:
        return float("nan")

    m = re.search(r'([0-9]+(?:\.[0-9]+)?)', s)
    return float(m.group(1)) if m else float("nan")

# ---------- HELPER: Convert MB to GB and format for display ----------
def mb_to_gb_display(val):
    mb = parse_mb(val)

    if pd.isna(mb):
        return ""

    # Convert MB → GB and round to nearest whole number
    gb = round(mb / 1024)

    return int(gb)

# ---------- HELPER: Render a section of the device overview ----------
def render_section_grid(title, items):
    # ✅ Map section titles to icons
    icon_map = {
        "Identity": "🔐",
        "Compliance": "🛡️",
        "Network": "🌐",
        "EventSentry": "🖥️",
        "Duplicates": "🔁"
    }

    icon = icon_map.get(title, "")

    st.markdown(
        "<hr style='border: none; border-top: 1px solid #e0e0e0; margin: 6px 0 14px 0;'>",
        unsafe_allow_html=True
    )

    st.markdown(
        f"<h4 style='margin-bottom:6px'>{icon} {title}</h4>",
        unsafe_allow_html=True
    )

    for left, right in items:
        label1, val1 = left
        label2, val2 = right

        val1 = clean(val1)
        val2 = clean(val2)

        if not val1 and not val2:
            continue

        if not val2:
            col = st.columns([1])[0]

            col.markdown(
                f"<span style='color:#666; font-size:12px'>{label1}</span>",
                unsafe_allow_html=True
            )
            col.markdown(
                f"<b>{val1}</b>",
                unsafe_allow_html=True
            )

        else:
            col1, col2 = st.columns(2)

            col1.markdown(
                f"<span style='color:#666; font-size:12px'>{label1}</span>",
                unsafe_allow_html=True
            )
            col1.markdown(
                f"<b>{val1}</b>",
                unsafe_allow_html=True
            )

            col2.markdown(
                f"<span style='color:#666; font-size:12px'>{label2}</span>",
                unsafe_allow_html=True
            )
            col2.markdown(
                f"<b>{val2}</b>",
                unsafe_allow_html=True
            )

        # spacing between rows
        st.markdown("<div style='margin-bottom:10px'></div>", unsafe_allow_html=True)

# ---------- HELPER: Clean integer values for display (handle NaN and remove .0) ----------
def clean_int(val):
    if pd.isna(val):
        return ""

    try:
        val = float(val)

        # Remove .0 if it's a whole number
        if val.is_integer():
            return str(int(val))

        return str(val)

    except:
        return str(val)

# ---------- HELPER: Format duplicate status with count for display ----------
def format_dup(flag, count):
    status = "🔁" if flag else "✅"
    count_val = clean_int(count)
    return f"{status} ({count_val})" if count_val else status

# ---------- HELPER: Safely get boolean series for a column, treating missing columns as all False ----------
def safe_bool_series(df: pd.DataFrame, col: str) -> pd.Series:
    """Return a boolean series for a column or all-False if missing."""
    if col in df.columns:
        return df[col].fillna(False).astype(bool)
    return pd.Series(False, index=df.index)

# ---------- HELPER: Build problem summary DataFrame and counts dictionary ----------
def build_problem_summary(df_scope: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    relevant = safe_bool_series(df_scope, "IsEventSentryRelevant")
    dup = safe_bool_series(df_scope, "MultiInstanceFlag")
    stale = relevant & safe_bool_series(df_scope, "EventSentry_Stale")
    missing_agent = relevant & safe_bool_series(df_scope, "Anomaly_ES_MissingWhileActive")

    any_problem = dup | stale | missing_agent

    counts = {
        "Duplicate Devices": int(dup.sum()),
        "EventSentry Stale": int(stale.sum()),
        "Missing ES Agent While Active": int(missing_agent.sum()),
        "Total Problem Devices": int(any_problem.sum()),
    }

    problem_df = pd.DataFrame({
        "Problem": [
            "Duplicate Devices",
            "EventSentry Stale",
            "Missing ES Agent While Active"
        ],
        "Count": [
            counts["Duplicate Devices"],
            counts["EventSentry Stale"],
            counts["Missing ES Agent While Active"]
        ]
    })

    return problem_df, counts

# ==================================
# ---------- Data loading ----------
# ==================================

# ---------- Load cached data ----------
@st.cache_data(ttl=24 * 3600) # refresh every 24 hours
def load_devices(device_data: Path) -> pd.DataFrame:
    df = pd.read_csv(device_data)
    return df

# --- LOAD DATA ---
latest_file = get_latest_csv()
if latest_file:
    df = load_devices(latest_file)
    # The following assignment was generated by Copilot on 5/24/2026 while other parts of the solution were cleaned up, tested, and improved for robustness and maintainability.
    df = preprocess_dataframe(df)

    if "EventSentry_AgeDays" in df.columns:
        df["EventSentry_AgeDays"] = (
            pd.to_numeric(df["EventSentry_AgeDays"], errors="coerce")
            .round(0).fillna(0).astype(int)
        )

    # Devices that should be evaluated for EventSentry (exclude Entra only devcies that are likely to be cloud-only and not have EventSentry agent)
    df["IsCorporateDevice"] = (
        df["InAD"].fillna(False) |
        df["InIntune"].fillna(False) |
        df["InSophos"].fillna(False) |
        df["InKACE"].fillna(False)
    )
    df["IsEventSentryRelevant"] = df["IsCorporateDevice"]

    # The following assignment was generated by Copilot on 6/6/2026 to extend the device dashboard to include data from EventSentry, 
    # which was added as a new data source in the PowerShell export script. This includes deriving new health status based on EventSentry anomalies and staleness, 
    # as well as incorporating EventSentry presence into the existing context and health calculations.
    df["DeviceHealth"] = df.apply(derive_device_health, axis=1)
    
    df["HealthReason"] = df.apply(derive_health_reason, axis=1)
    
    df["IsProblem"] = (
        (df["MultiInstanceFlag"].fillna(False)) |
        (
            df["IsEventSentryRelevant"] &
            df["EventSentry_Stale"].fillna(False)
        ) |
        (
            df["IsEventSentryRelevant"] &
            df["Anomaly_ES_MissingWhileActive"].fillna(False)
        )
    )

    # The following logic was added by Copilot on 6/6/2026 to ensure that the "Memory" column is populated in the DataFrame, 
    # as it is a key metric displayed in the dashboard. The PowerShell export script was updated to include a "Memory" field that pulls from either EventSentry's 
    # total memory or KACE's RAM total. This code checks if the "Memory" column exists and has valid data; if not, it fills it with values from the new fields added to the export. 
    # This ensures that the dashboard can display memory information even if the source CSV does not have a dedicated "Memory" column, 
    # improving the robustness of the app against variations in the exported data.
    # Build unified raw memory column if missing / empty
    if "Memory" not in df.columns or df["Memory"].isna().all():
        es_mem = df["EventSentry_TotalMemory"] if "EventSentry_TotalMemory" in df.columns else pd.Series(index=df.index, dtype="object")
        kace_mem = df["KACE_Machine_RAM_Total"] if "KACE_Machine_RAM_Total" in df.columns else pd.Series(index=df.index, dtype="object")
        df["Memory"] = es_mem.fillna(kace_mem)

    # Build display-ready memory ONCE
    df["MemoryDisplay"] = df["Memory"].apply(mb_to_gb_display)

    mtime = datetime.fromtimestamp(os.path.getmtime(latest_file))
else:
    st.warning("No device export file found.")

# The following function was generated by Copilot on 6/8/2026 to provide a simplified count of devices that are present in all contexts without adjusting for duplicates. 
# This is useful for giving users a quick overview of how many unique devices are represented across all systems, regardless of whether they have multiple instances. 
# By counting only the unique devices that appear in all contexts, we can provide a clearer metric for understanding the breadth of device coverage across the different systems 
# without the complexity of adjusting for duplicates, which may be more relevant in specific contexts rather than as an overall count.
# ---------- HELPER: Count devices present in all contexts (without duplicate adjustment) ----------
def count_all_contexts(df: pd.DataFrame) -> int:
    context_cols = PRESENCE_BOOL_COLS

    # Devices present in all contexts
    all_contexts_mask = df[context_cols].all(axis=1)

    return int(all_contexts_mask.sum())

# ---------- Robust parser: "16384 MB", "16384", 16384.0 → numeric MB ----------
def parse_mb(val):
    if pd.isna(val):
        return float('nan')
    s = str(val).strip().lower()
    m = re.search(r'([0-9]+(?:\.[0-9]+)?)', s)
    return float(m.group(1)) if m else float('nan')

def mb_to_gb(mb):
    # RAM convention (binary): 1 GB = 1024 MB
    return mb / 1024 if pd.notna(mb) else float('nan')

# =============================================
# ---------- Prepare app/layout/data ----------
# =============================================
# ---------- Load CSS ----------
with open(CSS_PATH) as f:
    st.markdown(f"<style>{f.read()}</style>", unsafe_allow_html=True)

st.set_page_config(layout='wide', initial_sidebar_state='expanded', page_title='CVB Device Dashboard', page_icon=CVB_SQ_ICON)

st.logo(CVB_RECTANGULAR_LOGO, size='large', icon_image=CVB_SQ_LOGO)

st.title('CVB Device Dashboard')

# --- SESSION STATE FOR BUTTON LOCK ---
if "refresh_running" not in st.session_state:
    st.session_state.refresh_running = False

# --- HELPER: Find all recent CSV files (last 10 minutes) ---
def get_recent_csvs(minutes=10):
    files = glob.glob(os.path.join(csv_dir, csv_pattern))
    now = datetime.now()
    recent_files = [
        f for f in files
        if now - datetime.fromtimestamp(os.path.getmtime(f)) < timedelta(minutes=minutes)
    ]
    # Sort by most recent first
    recent_files.sort(key=os.path.getmtime, reverse=True)
    return recent_files

# --- REFRESH BUTTON LOGIC ---
def refresh_and_wait():
    st.session_state.refresh_running = True
    with st.spinner("Running PowerShell script and waiting for new device export..."):
        try:
            # 1. Run the PowerShell script
            result = subprocess.run(
                ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(powershell_script)],
                check=True, capture_output=True, text=True
            )
            # Log both stdout and stderr for debugging (ONLY UNCOMMENT FOR DEBUGGING PURPOSES IN THE UI)
            # if result.stdout:
            #     st.write("**PowerShell Output:**")
            #     st.write(result.stdout)
            # if result.stderr:
            #     st.write("**PowerShell Errors/Warnings:**")
            #     st.write(result.stderr)
        except subprocess.CalledProcessError as e:
            st.session_state.refresh_running = False
            st.error(f"PowerShell script failed:\n{e.stderr or e.stdout}")
            return

        # 2. Wait for a new file (modified in last 5 minutes)
        timeout = 60  # seconds to wait before giving up
        poll_interval = 2  # seconds
        start_time = time.time()
        found = False
        while time.time() - start_time < timeout:
            recent_files = get_recent_csvs(minutes=5)
            if recent_files:
                found = True
                break
            time.sleep(poll_interval)
        if found:
            load_devices.clear()  # Clear cache so next load is fresh
            # Prefer to show the filename + mtime when available
            latest_file = get_latest_csv()
            if latest_file:
                mtime = datetime.fromtimestamp(os.path.getmtime(latest_file))
                st.success(f"Loaded: {os.path.basename(latest_file)} (last updated {mtime.strftime('%Y-%m-%d %H:%M:%S')})")
            else:
                st.success("New device export file(s) found and ready to load.")
        else:
            st.error("No recent device export file found after running the script.")
    st.session_state.refresh_running = False

# --- REFRESH BUTTON (single centralized handler) ---
st.button("🔄 Refresh Device Data", on_click=refresh_and_wait, disabled=st.session_state.refresh_running)

# File version verification caption below refresh device data button
st.caption(f"Using file: {os.path.basename(latest_file)} (last updated {mtime.strftime('%Y-%m-%d %H:%M:%S')})")

# =============================
# ---------- Sidebar ----------
# =============================
context_cols_renamed = PRESENCE_BOOL_COLS_RENAMED
st.sidebar.header('Filters')

# ---------- Sidebar: Data table filters ----------
st.sidebar.subheader('Data table filters')
# Build the list of actual columns that exist in the Data table (in the same order as display headers)
existing_actual = [actual for display, actual in data_table_display_to_actual.items() if actual in df.columns]
# Slice to those Data table columns
df_view = df.loc[:, existing_actual].copy()
# Rename the Data table columns to friendly display headers
actual_to_display = {v: k for k, v in data_table_display_to_actual.items()}
df_view.rename(columns=actual_to_display, inplace=True)

# --- Sidebar: Context filter ---
selected_context = st.sidebar.selectbox("Filter by Context", context_options)

# Sidebar: Checkbox for exclusive context
if selected_context != "Show all devices" and selected_context != "Devices in all systems":
    exclusive_only = st.sidebar.checkbox(
        f"Show only devices exclusively in: {selected_context.replace('Devices in ', '')}"
    )
else:
    exclusive_only = False

# --- Sidebar: Device Type filter ---
device_types = df_view['Device Type'].dropna().unique()
selected_type = st.sidebar.multiselect('Filter by Device Type', device_types)

# --- Sidebar: OS filter ---
# Avoid shadowing the imported `os` module; use `os_choices` instead
os_choices = df_view['OS'].dropna().unique()
selected_os = st.sidebar.multiselect('Filter by OS', os_choices)

# --- Sidebar: Branch (Location) filter ---
branches = df_view["Physical Device Location"].dropna().unique()
branches.sort()

selected_branches = st.sidebar.multiselect(
    'Filter by Branch',
    branches
)

# --- Sidebar: Duplicate filter ---
dup_filter = st.sidebar.radio(
    "Duplicate Devices filter",
    ("Show all devices", "Show duplicates only", "Show non-duplicates only")
)

# Apply filters
filtered_df = df_view.copy()
if selected_type:
    filtered_df = filtered_df[filtered_df['Device Type'].isin(selected_type)]
if selected_os:
    filtered_df = filtered_df[filtered_df['OS'].isin(selected_os)]
if selected_branches:
    filtered_df = filtered_df[
        filtered_df["Physical Device Location"].isin(selected_branches)
    ]

# Apply context filter
if selected_context == "Show all devices":
    pass  # no filtering applied, show all devices
elif selected_context == "Devices in all systems":
    filtered_df = filtered_df[filtered_df[context_cols_renamed].all(axis=1)]
elif selected_context in CONTEXT_COLUMN_MAP:
    # Data-driven context filter: Entra, Intune, AD, Sophos, or KACE
    col = CONTEXT_COLUMN_MAP[selected_context]
    if exclusive_only:
        other_cols = CONTEXT_EXCLUSIONS[col]
        filtered_df = filtered_df[
            (filtered_df[col]) &
            (~filtered_df[other_cols].any(axis=1))
        ]
    else:
        filtered_df = filtered_df[filtered_df[col]]

# Apply duplicate filter
if dup_filter == "Show duplicates only":
    filtered_df = filtered_df[filtered_df["Duplicate Devices"]]
elif dup_filter == "Show non-duplicates only":
    filtered_df = filtered_df[~filtered_df["Duplicate Devices"]]
# else: show all devices (no filter)

# --------- Sidebar: Problem Device Filters ----------
st.sidebar.subheader("Problem Devices")
show_problems_only = st.sidebar.checkbox("Only show problem devices")

if show_problems_only:
    st.markdown("### ⚠ Showing Problem Devices Only")
    # Added 6/8/2026: Use the unified "IsProblem" column to filter the already filtered_df to show only devices that have any of the defined problems, 
    # ensuring that the problem device filters work correctly even after applying other filters. 
    # This approach simplifies the logic and ensures consistency in identifying problem devices across multiple dimensions.
    filtered_df = filtered_df[
        filtered_df["Device Name"].isin(df[df["IsProblem"]]["Name"])
    ]

# ---------- Sidebar: Problem summary for current scope ----------
# ---------- Build scoped dataframe ----------
# Build a scoped version of the original dataframe that matches current table filters
# Robust method to ensure we get the full original data for the devices that are currently in the filtered view, 
# which is necessary for accurate problem summary calculations. This is especially important if the filtering has reduced the number of devices or changed the index, 
# as we want to make sure we are analyzing the correct subset of devices from the original DataFrame.
scoped_df = df[df["Name"].isin(filtered_df["Device Name"])].copy()

# Build problem summary for current scope
# ---------- Problem summary ----------
problem_df, problem_counts = build_problem_summary(scoped_df)

# ---------- Sidebar: Device selection ----------
st.sidebar.subheader('Device overview selection')
device_names = df['Name'].dropna().unique()
selected_device = st.sidebar.selectbox('Choose device by Name:', device_names)

# ---------- Sidebar: Attribution ----------
st.sidebar.markdown('''
---
📧 Contact Nathan with any questions or feedback''')

# ==============================
# ---------- Main app ----------
# ==============================

# ---------- Metrics ----------
#total_devices = count_total_devices(scoped_df)
total_devices = len(scoped_df)
corporate_devices = int(scoped_df["IsCorporateDevice"].sum())
personal_devices = len(scoped_df) - corporate_devices
devices_all_contexts = count_all_contexts(scoped_df)
not_fully_managed = total_devices - devices_all_contexts

# ---------- Row A ----------
st.markdown("### Metrics")
col1, col2, col3, col4, col5 = st.columns(5)
col1.metric("Total devices", f"{total_devices:,}")
col2.metric("Corporate Devices", f"{corporate_devices:,}")
col3.metric("Personal Devices", f"{personal_devices:,}")
col4.metric("Devices Fully Managed", f"{devices_all_contexts:,}")
col5.metric("Not Fully Managed", f"{not_fully_managed:,}")

# ---------- Row B ----------
st.markdown("### Problem Summary")

m1, m2, m3, m4 = st.columns(4)
m1.metric("Duplicate Devices", f"{problem_counts['Duplicate Devices']:,}")
m2.metric("EventSentry Stale", f"{problem_counts['EventSentry Stale']:,}")
m3.metric("Missing ES Agent While Active", f"{problem_counts['Missing ES Agent While Active']:,}")
m4.metric("Total Problem Devices (Unique)", f"{problem_counts['Total Problem Devices']:,}")
st.caption("Note: Individual problem counts may overlap. Total represents unique affected devices.")

#st.markdown("### Problem Breakdown")
with st.expander("Problem Breakdown", expanded=False):
    problem_chart = alt.Chart(problem_df).mark_bar(cornerRadiusTopLeft=4, cornerRadiusTopRight=4).encode(
        x=alt.X("Problem:N", sort=None, title=""),
        y=alt.Y("Count:Q", title="Device Count"),
        color=alt.Color(
            "Problem:N",
            legend=None,
            scale=alt.Scale(
                domain=[
                    "Duplicate Devices",
                    "EventSentry Stale",
                    "Missing ES Agent While Active"
                ],
                range=["#36b9cc", "#f6c23e", "#e74a3b"]
            )
        ),
        tooltip=["Problem", "Count"]
    ).properties(
        height=280
    )

    st.altair_chart(problem_chart, width='stretch')

with st.expander("Advanced Context Analysis (legacy charts)"):
    # Pull context columns for Heatmap and Donut Chart
    context_cols_renamed = PRESENCE_BOOL_COLS_RENAMED

    # Build adjusted heatmap
    heatmap_matrix = pd.DataFrame(0, index=context_cols_renamed, columns=context_cols_renamed)
    for i in context_cols_renamed:
        for j in context_cols_renamed:
            overlap_mask = df_view[i] & df_view[j]
            base_count = overlap_mask.sum()
            extra_entra = 0
            extra_sophos = 0
            if i == "In Entra" or j == "In Entra":
                extra_entra = (df.loc[overlap_mask, "Entra_InstanceCount"] - 1).clip(lower=0).sum()
            if i == "In Sophos" or j == "In Sophos":
                extra_sophos = (df.loc[overlap_mask, "Sophos_InstanceCount"] - 1).clip(lower=0).sum()
            adjusted_count = int(base_count + extra_entra + extra_sophos)
            heatmap_matrix.loc[i, j] = adjusted_count

    # Melt for Altair
    heatmap_data = heatmap_matrix.reset_index().melt(id_vars="index")
    heatmap_data.columns = ["Context1", "Context2", "DeviceCount"]

    # Altair chart (unchanged)
    heatmap_chart = alt.Chart(heatmap_data).mark_rect().encode(
        x=alt.X('Context1:N', title='', axis=alt.Axis(labelAngle=0)), # Tilt x-axis labels for readability
        y=alt.Y('Context2:N', title=''),
        color=alt.Color('DeviceCount:Q', scale=alt.Scale(scheme='blues')),
        tooltip=['Context1', 'Context2', 'DeviceCount']
    ).properties(
        width='container',
        height=345,
        title='Context Overlap Heatmap'
    )

    # Calculate how many contexts each device is in for Donut Chart
    context_cols = PRESENCE_BOOL_COLS

    # Calculate number of contexts present per device
    df["ContextsPresent"] = df[context_cols].sum(axis=1)

    # Adjusted counts for each context association group
    adjusted_counts = {}
    for num_contexts in sorted(df["ContextsPresent"].unique()):
        mask = df["ContextsPresent"] == num_contexts
        base_count = mask.sum()
        adjusted_counts[num_contexts] = adjust_count_for_duplicates(
            base_count,
            df.loc[mask, "Entra_InstanceCount"],
            df.loc[mask, "Sophos_InstanceCount"]
        )

    association_data = pd.DataFrame({
        "ContextsPresent": list(adjusted_counts.keys()),
        "DeviceCount": list(adjusted_counts.values())
    })

    c1, c2 = st.columns((7,3))
    with c1:
        st.markdown('### Heatmap')
        st.altair_chart(heatmap_chart, width='stretch')
    with c2:
        st.markdown('### Device context chart')
        
        plost.donut_chart(
            data=association_data,
            theta="DeviceCount",
            color="ContextsPresent",  # 1, 2, 3, 4, 5
            legend='bottom',
            width='stretch'
        )

# ---------- Row C ----------
st.markdown('### Data table')
# Replaced by Copilot on 6/6/2026 to add conditional formatting for the Health column based on the derived health status that incorporates EventSentry anomalies and staleness, as well as Sophos health status. 
# The `highlight_health` function applies color coding to the Health column in the Data table, making it easier for users to visually identify devices that are in critical or warning states at a glance. 
# This enhancement extends the device dashboard's ability to surface important health insights directly within the main data table, improving usability and situational awareness for IT staff monitoring device health across multiple systems.
# st.dataframe(filtered_df, width='stretch', hide_index=True)
st.dataframe(
    filtered_df.style.map(highlight_health, subset=["Health"]),
    width='stretch',
    hide_index=True
)

# ---------- Row D ----------
st.markdown(f"### Device Overview: {selected_device}")

# Get all rows for that selected device (sometimes there can be multiple)
device_rows = df.loc[df["Name"] == selected_device]

# Pull row once and handle empty case upfront to avoid multiple .iloc[0] calls and potential IndexErrors later
if device_rows.empty:
    st.warning("No data found for the selected device.")
    st.stop()

# Assuming we want to display the first row for the selected device (if multiple exist), 
# we can safely pull it now that we've confirmed it's not empty. 
# This avoids potential IndexErrors from trying to access .iloc[0] on an empty DataFrame later in the code.
device_row = device_rows.head(1).iloc[0] if not device_rows.empty else None

# Check if device exists only in EventSentry (new data source added on 6/6/2026) and show a warning if so, since data will be limited for these devices. 
# This is determined by the presence of the device in EventSentry and absence from all other contexts/sources.
only_eventsentry = (
    device_row.get("InEventSentry") and
    not device_row.get("InEntra") and
    not device_row.get("InIntune") and
    not device_row.get("InAD") and
    not device_row.get("InSophos") and
    not device_row.get("InKACE")
)

if only_eventsentry:
    st.warning("⚠ This device exists only in EventSentry. Limited data is available.")

if device_row is None:
    st.warning("No data found for the selected device.")
    st.stop()
else:

    # -------------------------
    # 🔷 Overview
    # -------------------------
    if only_eventsentry:
        st.info("This device was detected via EventSentry telemetry only. Additional context (Intune, AD, etc.) not found.")

    st.markdown("#### Overview")
    col1, col2, col3 = st.columns(3)
    
    mem = device_row.get("Memory")

    col1.metric("Device Type", clean(device_row.get("DeviceType", "")))
    col2.metric("OS", clean(device_row.get("OS", "")))
    col3.metric("Memory (GB)", clean(device_row.get("MemoryDisplay")))

    col4, col5, col6 = st.columns(3)
    col4.metric("Last Seen", clean(device_row.get("LastSeen", "")))
    col5.metric("Primary User", clean(device_row.get("PrimaryUser", "")))
    col6.metric("Location", clean(device_row.get("DerivedLocation", "")))

    # -------------------------
    # 🔶 Health & Issues
    # -------------------------
    st.markdown("#### Health & Issues")

    health = device_row.get("DeviceHealth", "")
    st.metric("Device Health", health)

    issues = []
    if device_row.get("Anomaly_ES_MissingWhileActive"):
        issues.append("🚨 Missing EventSentry Agent")
    if device_row.get("Anomaly_ES_StaleWhileActive"):
        issues.append("⚠ EventSentry Stale While Active")
    if str(device_row.get("Sophos_Health", "")).lower() not in ["healthy", "good"]:
        issues.append("⚠ Sophos Not Healthy")

    if issues:
        st.markdown("**Active Issues:**")
        for issue in issues:
            st.warning(issue)
    else:
        st.success("No active issues")

    # -------------------------
    # 🔹 Presence
    # -------------------------
    st.markdown("#### Presence")

    presence_cols = [
        "InEntra", "InIntune", "InAD",
        "InSophos", "InKACE", "InEventSentry"
    ]

    presence_display = [
        "Entra", "Intune", "AD",
        "Sophos", "KACE", "EventSentry"
    ]

    cols = st.columns(len(presence_cols))

    for i, col in enumerate(presence_cols):
        val = device_row.get(col, False)
        cols[i].metric(presence_display[i], "✅" if val else "❌")

    # -------------------------
    # 🔸 Identity
    # -------------------------
    render_section_grid("Identity", [
        (("AD Object GUID", clean(device_row.get("AD_ObjectGUID"))),
        ("Entra Device ID", clean(device_row.get("Entra_DeviceIds")))),

        (("Intune Device ID", clean(device_row.get("Intune_DeviceId"))),
        ("Intune Entra Device ID", clean(device_row.get("Intune_AzureADDeviceIds")))),

        (("KACE ID", clean_int(device_row.get("KACE_ID"))),
        ("Entra Join Type", clean(device_row.get("Entra_JoinType")))),

        (("DNS Hostname", clean(device_row.get("AD_DNSHostName"))),
        ("Serial Number", clean(device_row.get("SerialNumber")))),
    ])

    # -------------------------
    # 🔸 Compliance
    # -------------------------
    render_section_grid("Compliance", [
        (("Intune Compliance", clean(device_row.get("Intune_ComplianceState"))),
        ("Intune Agent", clean(device_row.get("Intune_ManagementAgent")))),

        (("Entra Managed", clean(device_row.get("Entra_IsManaged"))),
        ("Entra Compliant", clean(device_row.get("Entra_IsCompliant")))),
    ])

    # -------------------------
    # 🔸 Network
    # -------------------------
    kace_ip = clean(device_row.get("KACE_Machine_Ip"))
    sophos_ip = clean(device_row.get("Sophos_ipv4Addresses"))

    if kace_ip and sophos_ip and kace_ip != sophos_ip:
        render_section_grid("Network", [
            (("IP Address (KACE)", kace_ip),
            ("IP Address (Sophos)", sophos_ip)),
        ])
    else:
        render_section_grid("Network", [
            (("IP Address", kace_ip or sophos_ip),
            ("", "")),
        ])


    # -------------------------
    # 🔸 EventSentry (NEW 🔥)
    # -------------------------
    render_section_grid("EventSentry", [
        (("Agent Present", "✅" if clean(device_row.get("EventSentry_AgentPresent")) else "❌"),
        ("Agent Version", clean(device_row.get("EventSentry_AgentVersion")))),

        (("Inventory Timestamp", clean(device_row.get("EventSentry_InventoryTimestamp"))),
        ("Age (Days)", clean(device_row.get("EventSentry_AgeDays")))),

        (("Stale", "⚠" if clean(device_row.get("EventSentry_Stale")) else "✅"),
        ("Model", clean(device_row.get("EventSentry_Model")))),

        (("Manufacturer", clean(device_row.get("EventSentry_Manufacturer"))),
        ("", "")),
    ])

    # -------------------------
    # 🔸 Duplicates
    # -------------------------
    render_section_grid("Duplicates", [
        (("Entra Duplicate",
        format_dup(device_row.get("Entra_DuplicateFlag"),
                    device_row.get("Entra_InstanceCount"))),
        
        ("Intune Duplicate",
        format_dup(device_row.get("Intune_DuplicateFlag"),
                    device_row.get("Intune_InstanceCount")))),

        (("Sophos Duplicate",
        format_dup(device_row.get("Sophos_DuplicateFlag"),
                    device_row.get("Sophos_InstanceCount"))),
        
        ("Overall Duplicate",
        "🔁" if device_row.get("MultiInstanceFlag") else "✅")),
    ])

    # -------------------------
    # 🔸 Source Details (collapsible)
    # -------------------------
    with st.expander("Raw Source Data"):
        raw_data = {
            k: clean(v)
            for k, v in device_row.to_dict().items()
        }
        st.write(raw_data)

