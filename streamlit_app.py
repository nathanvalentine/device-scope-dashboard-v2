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
    "InEntra", "InIntune", "InAD", "InSophos", "InKACE"
]
PRESENCE_BOOL_COLS_RENAMED = [
    "In Entra", "In Intune", "In AD", "In Sophos", "In KACE"
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
    "Devices in Sophos", "Devices in KACE", "Devices in all systems"
]

# Data-driven context mappings for simplified filter logic
CONTEXT_COLUMN_MAP = {
    "Devices in Entra": "In Entra",
    "Devices in Intune": "In Intune",
    "Devices in AD": "In AD",
    "Devices in Sophos": "In Sophos",
    "Devices in KACE": "In KACE",
}

CONTEXT_EXCLUSIONS = {
    "In Entra": ["In Intune", "In AD", "In Sophos", "In KACE"],
    "In Intune": ["In Entra", "In AD", "In Sophos", "In KACE"],
    "In AD": ["In Entra", "In Intune", "In Sophos", "In KACE"],
    "In Sophos": ["In Entra", "In Intune", "In AD", "In KACE"],
    "In KACE": ["In Entra", "In Intune", "In AD", "In Sophos"],
}
# ---------- Shared core device fields (used in both data table and overview) ----------
DEVICE_CORE_FIELDS = {
    "Device Name": "Name",
    "In Entra": "InEntra",
    "In Intune": "InIntune",
    "In AD": "InAD",
    "In Sophos": "InSophos",
    "In KACE": "InKACE",
    "Physical Device Location": "DerivedLocation",
    "Device Type": "DeviceType",
    "OS": "OS",
    "Sophos Health": "Sophos_Health",
    "Total Memory (GB)": "KACE_Machine_RAM_Total",
    "Duplicate Devices": "MultiInstanceFlag",
    "Last Seen": "LastSeen",
    "Primary User": "PrimaryUser",
    "AD Object GUID": "AD_ObjectGUID",
    "Entra Device ID(s)": "Entra_DeviceIds",
    "Intune Entra Device ID": "Intune_AzureADDeviceIds",
}

# ---------- Data table-specific fields (extends core) ----------
DATA_TABLE_SPECIFIC_FIELDS = {
    "IP Address": "Sophos_ipv4Addresses",
    "Entra Device Instance Count": "Entra_InstanceCount",
    "Entra Hybrid Joined": "Entra_HybridCount",
    "Entra Device ID Matches AD Object GUID": "Entra_HybridIdMatchesAD",
    "Entra Device ID Mismatches AD Object GUID": "Entra_HybridIdMismatchExists",
    "Entra Registered": "Entra_RegisteredCount",
    "Sophos Device Instance Count": "Sophos_InstanceCount",
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
    "Entra Managed": "Entra_IsManaged"
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
# This ensures that all boolean columns are properly normalized to True/False and all numeric columns are coerced to numbers (with non-convertible values treated as 0), which is crucial for accurate filtering, counting, and display in the dashboard.
# By centralizing this logic in helper functions, we avoid code duplication and ensure that any changes to the normalization logic are applied consistently throughout the app.
# For example, before applying filters based on context presence or calculating metrics that depend on instance counts, we can call these helper functions to ensure the data is in the correct format. This is especially important given that the source CSV may have inconsistent formatting for boolean and numeric fields.
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
    mtime = datetime.fromtimestamp(os.path.getmtime(latest_file))
else:
    st.warning("No device export file found.")

def count_total_devices(df: pd.DataFrame) -> int:
    # Ensure instance count columns are numeric
    base_count = len(df)
    return adjust_count_for_duplicates(base_count, df["Entra_InstanceCount"], df["Sophos_InstanceCount"])

def count_all_5_contexts(df: pd.DataFrame) -> int:
    context_cols = PRESENCE_BOOL_COLS
    
    # Devices in all 5 contexts
    all_five_mask = df[context_cols].all(axis=1)
    all_five_devices = df[all_five_mask]
    base_count = len(all_five_devices)
    # Add duplicates
    return adjust_count_for_duplicates(
        base_count,
        all_five_devices["Entra_InstanceCount"],
        all_five_devices["Sophos_InstanceCount"]
    )

def count_multi_instance_devices(df: pd.DataFrame) -> int:
    if MULTI_INSTANCE_COL not in df.columns:
        return 0
    col = df[MULTI_INSTANCE_COL]
    # Handle boolean True/False and numeric flags (>0 means multi-instance)
    if col.dtype == bool:
        return int(col.sum())
    nums = pd.to_numeric(col, errors="coerce").fillna(0)
    return int(nums.gt(0).sum())

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

# ---------- Convert Total from MB to GB (numeric) ----------
if RAM_TOTAL_COL in df.columns:
    df[RAM_TOTAL_COL] = df[RAM_TOTAL_COL].apply(parse_mb).apply(mb_to_gb)

# =============================
# ---------- Sidebar ----------
# =============================
context_cols_renamed = PRESENCE_BOOL_COLS_RENAMED
st.sidebar.header('Filters')

# # ---------- Sidebar: device context parameter selection ----------
# st.sidebar.subheader('Device context parameter')
# context_theta = st.sidebar.selectbox('Select data',('Context Association', 'Per context (count)'))

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
total_devices = count_total_devices(df)
devices_all_5   = count_all_5_contexts(df)
multi_instance  = count_multi_instance_devices(df)

# ---------- Row A ----------
st.markdown("### Metrics")
col1, col2, col3 = st.columns(3)
col1.metric("Total devices", f"{total_devices:,}")
col2.metric("Devices in all 5 contexts", f"{devices_all_5:,}")
col3.metric("Multi-instance devices", f"{multi_instance:,}")

# ---------- Row B ----------
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

# # Devices per context (count)
# context_counts = {col: df[col].sum() for col in context_cols}
# context_count_data = pd.DataFrame({
#     "Context": list(context_counts.keys()),
#     "DeviceCount": list(context_counts.values())
# })

c1, c2 = st.columns((7,3))
with c1:
    st.markdown('### Heatmap')
    st.altair_chart(heatmap_chart, width='stretch')
with c2:
    st.markdown('### Device context chart')
    # if context_theta == "Context Association":
    #     plost.donut_chart(
    #         data=association_data,
    #         theta="DeviceCount",
    #         color="ContextsPresent",  # 1, 2, 3, 4, 5
    #         legend='bottom',
    #         width='stretch'
    #     )
    # elif context_theta == "Per context (count)":
    #     plost.donut_chart(
    #         data=context_count_data,
    #         theta="DeviceCount",
    #         color="Context",  # InEntra, InIntune, etc.
    #         legend='bottom',
    #         width='stretch'
    #     )
    plost.donut_chart(
        data=association_data,
        theta="DeviceCount",
        color="ContextsPresent",  # 1, 2, 3, 4, 5
        legend='bottom',
        width='stretch'
    )

# ---------- Row C ----------
st.markdown('### Data table')
st.dataframe(filtered_df, width='stretch', hide_index=True)

# ---------- Row D ----------
st.markdown(f"### Device Overview: {selected_device}")

# Build ordered list of (display_name, actual_col) pairs that exist in df
overview_pairs = [
    (display, actual)
    for display, actual in overview_display_to_actual.items()
    if actual in df.columns
]

# Get all rows for that selected device (sometimes there can be multiple)
device_rows = df.loc[df["Name"] == selected_device]

def scalar_from_rows(rows: pd.DataFrame, col_name: str):
    """
    Return a single scalar value for a given column from rows.
    - Handles duplicate columns (col_name appearing multiple times)
    - Returns first non-null value if multiple rows exist
    - Returns "" if nothing usable exists
    """
    if rows.empty or col_name not in rows.columns:
        return ""

    # Use .loc[:, col_name] so pandas returns:
    # - Series if column is unique
    # - DataFrame if duplicate columns exist
    block = rows.loc[:, col_name]

    # If duplicate columns exist, take the first duplicate column
    if isinstance(block, pd.DataFrame):
        series = block.iloc[:, 0]
    else:
        series = block

    # Pick first non-null value across potentially multiple rows
    series_nonnull = series.dropna()
    if series_nonnull.empty:
        return ""

    return series_nonnull.iloc[0]

display_names = [d for d, _ in overview_pairs]
values = [scalar_from_rows(device_rows, actual) for _, actual in overview_pairs]

overview_df = pd.DataFrame({"Property": display_names, "Value": values})

# Force Arrow-safe + hide NaN
#overview_df["Value"] = overview_df["Value"].fillna("").astype(str)
overview_df["Value"] = overview_df["Value"].apply(format_display_value)

if not overview_df.empty:
    st.table(overview_df)
else:
    st.warning("No data found for the selected device.")
