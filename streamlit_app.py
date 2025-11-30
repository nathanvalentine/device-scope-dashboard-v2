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
    "Physical Device Location": "Location",
    "Operating System": "KACE_Os_name",
    "Entra OS Version": "Entra_OperatingSystemVersion",
    "IPv4 Address": "KACE_Machine_Ip",
    "Installed RAM Total": "KACE_Machine_RAM_Total",
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
    "Sophos Device Health Status": "Sophos_Health",
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

# ==================================
# ---------- Data loading ----------
# ==================================

# ---------- HELPER: Normalize string booleans to Python bool ----------
def normalize_bool_column(series):
    """
    Convert string booleans ('true'/'false'/'1'/'0') and mixed types to Python bool.
    Handles case-insensitivity and whitespace.
    """
    return series.astype(str).str.strip().str.lower()\
        .replace({"true": True, "false": False, "1": True, "0": False})\
        .astype(bool)

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

# ---------- Load cached data ----------
@st.cache_data(ttl=24 * 3600) # refresh every 24 hours
def load_devices(device_data: Path) -> pd.DataFrame:
    df = pd.read_csv(device_data)
    return df

# --- LOAD DATA ---
latest_file = get_latest_csv()
if latest_file:
    df = load_devices(latest_file)
    mtime = datetime.fromtimestamp(os.path.getmtime(latest_file))
else:
    st.warning("No device export file found.")

def count_total_devices(df: pd.DataFrame) -> int:
    # Ensure instance count columns are numeric
    df["Entra_InstanceCount"] = pd.to_numeric(df["Entra_InstanceCount"], errors="coerce").fillna(0)
    df["Sophos_InstanceCount"] = pd.to_numeric(df["Sophos_InstanceCount"], errors="coerce").fillna(0)
    base_count = len(df)
    return adjust_count_for_duplicates(base_count, df["Entra_InstanceCount"], df["Sophos_InstanceCount"])

def count_all_5_contexts(df: pd.DataFrame) -> int:
    context_cols = PRESENCE_BOOL_COLS
    # Ensure boolean columns
    for col in context_cols:
        df[col] = normalize_bool_column(df[col])
    # Ensure instance counts are numeric
    df["Entra_InstanceCount"] = pd.to_numeric(df["Entra_InstanceCount"], errors="coerce").fillna(0)
    df["Sophos_InstanceCount"] = pd.to_numeric(df["Sophos_InstanceCount"], errors="coerce").fillna(0)
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

# Duplicate filter
# Normalize the column if needed
df_view["Duplicate Devices"] = normalize_bool_column(df_view["Duplicate Devices"])

# Apply the filter
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
Created with ❤️ by Nathan Valentine''')

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
# Ensure boolean and numeric columns
for col in context_cols_renamed:
    df_view[col] = normalize_bool_column(df_view[col])
df_view["Entra Device Instance Count"] = pd.to_numeric(df_view["Entra Device Instance Count"], errors="coerce").fillna(0)
df_view["Sophos Device Instance Count"] = pd.to_numeric(df_view["Sophos Device Instance Count"], errors="coerce").fillna(0)

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
for col in context_cols:
    df[col] = normalize_bool_column(df[col])

df["Entra_InstanceCount"] = pd.to_numeric(df["Entra_InstanceCount"], errors="coerce").fillna(0)
df["Sophos_InstanceCount"] = pd.to_numeric(df["Sophos_InstanceCount"], errors="coerce").fillna(0)

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
    st.altair_chart(heatmap_chart, use_container_width=True)
with c2:
    st.markdown('### Device context chart')
    # if context_theta == "Context Association":
    #     plost.donut_chart(
    #         data=association_data,
    #         theta="DeviceCount",
    #         color="ContextsPresent",  # 1, 2, 3, 4, 5
    #         legend='bottom',
    #         use_container_width=True
    #     )
    # elif context_theta == "Per context (count)":
    #     plost.donut_chart(
    #         data=context_count_data,
    #         theta="DeviceCount",
    #         color="Context",  # InEntra, InIntune, etc.
    #         legend='bottom',
    #         use_container_width=True
    #     )
    plost.donut_chart(
        data=association_data,
        theta="DeviceCount",
        color="ContextsPresent",  # 1, 2, 3, 4, 5
        legend='bottom',
        use_container_width=True
    )

# ---------- Row C ----------
st.markdown('### Data table')
st.dataframe(filtered_df, use_container_width=True, hide_index=True)

# ---------- Row D ----------
# Only keep columns that exist in the DataFrame
existing_actual = get_existing_columns(overview_display_to_actual, df)

# Filter for the selected device
device_row = df[df['Name'] == selected_device][existing_actual]

# Build overview DataFrame with display names
display_names = [display for display, actual in overview_display_to_actual.items() if actual in existing_actual]
values = [device_row.iloc[0][actual] if not device_row.empty else "" for actual in existing_actual]

overview_df = pd.DataFrame({
    "Property": display_names,
    "Value": values
})

# Display device overview
st.markdown(f"### Device Overview: {selected_device}")
if not overview_df.empty:
    st.table(overview_df)
else:
    st.warning("No data found for the selected device.")



