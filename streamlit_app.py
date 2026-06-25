import streamlit as st
import sqlite3
import pandas as pd
import os
import json
from datetime import datetime
from pathlib import Path
import altair as alt
import plost

# ===============================
# ---------- Constants ----------
# ===============================
CVB_SQ_ICON = "images/CVB-Acorn-Monogram-Detailed-sq-16.ico"
CVB_RECTANGULAR_LOGO = "images/CVB_Logo_Teams.png"
CVB_SQ_LOGO = "images/CVB-Acorn-Monogram-Detailed-sq-48.png"

APP_DIR = Path(__file__).resolve().parent
CSS_PATH = APP_DIR / "style.css"
CONFIG_PATH = APP_DIR / "config.json"


def resolve_db_path() -> Path:
    """
    Mirrors Get-DeviceScopeDbPath in collectors/DeviceScope.Common.psm1:
    config.json's "SqliteDbPath" wins if present, otherwise fall back to
    <repo root>/data/devicescope.db relative to this file's own location.

    This MUST stay in sync with the PowerShell resolution logic - if the
    two ever diverge (e.g. one honors config.json and the other doesn't),
    the pipeline can write to one location while Streamlit silently reads
    from another, with no error indicating why the dashboard looks empty
    or stale. Same config.json, same path-resolution order, both languages.
    """
    if CONFIG_PATH.exists():
        try:
            cfg = json.loads(CONFIG_PATH.read_text())
            configured = cfg.get("SqliteDbPath")
            if configured:
                return Path(configured)
        except Exception as e:
            st.warning(f"Could not read SqliteDbPath from config.json: {e}")

    return APP_DIR / "data" / "devicescope.db"


def get_it_staff_names() -> list:
    """
    Reads a pre-populated list of IT staff names from config.json's
    "ITStaffNames" key (a plain list of strings), so the roster can be
    updated by editing config - a per-environment file - rather than
    requiring a code change/redeploy every time someone joins or leaves
    the team. Falls back to a small placeholder list if the key is
    missing or unreadable, clearly marked as such so it's obvious in
    the UI that real names haven't been configured yet.
    """
    if CONFIG_PATH.exists():
        try:
            cfg = json.loads(CONFIG_PATH.read_text())
            names = cfg.get("ITStaffNames")
            if isinstance(names, list) and names:
                return sorted(str(n) for n in names)
        except Exception as e:
            st.warning(f"Could not read ITStaffNames from config.json: {e}")
    return ["(Add real names to config.json's ITStaffNames list)"]


DB_PATH = resolve_db_path()

# Sources tracked, in display priority order. NOTE: all normalization
# (booleans, health, duplicate flags, patch status) now happens in
# sql/02_views.sql - this file does ZERO data transformation. It only
# queries v_devices_final and renders it.
PRESENCE_COLS = ["InEntra", "InIntune", "InAD", "InSophos", "InKACE", "InEventSentry"]
PRESENCE_DISPLAY = ["Entra", "Intune", "AD", "Sophos", "KACE", "EventSentry"]

# Default column set for the main Data table. Source-presence columns
# come first (this dashboard's original purpose per the Excel-sheet
# predecessor), then Health/Notes, then everything else.
DEFAULT_TABLE_COLUMNS = [
    "Name",
    "InEntra", "InIntune", "InAD", "InSophos", "InKACE", "InEventSentry",
    "DeviceHealth",
    "HealthReason",
    "note",
    "NoteStatus",
    # Snapped directly to the right of Status by design - regardless of
    # how "who made this edit" ends up being populated (manual name
    # field today, possibly automatic AD-based attribution later), it
    # should always read left-to-right as "what changed -> who changed
    # it -> when". Both moved here from the optional extras list so
    # they're visible by default, not buried behind the column picker.
    "updated_by",
    "NoteUpdatedAt",
    "DeviceType",
    "PatchStatus",
    "MultiInstanceFlag",
]

ALL_DISPLAYABLE_COLUMNS = DEFAULT_TABLE_COLUMNS + [
    "OS", "PrimaryUser", "BranchLocation", "LastSeen", "SerialNumber", "Memory",
    "Sophos_ipv4Addresses", "KACE_Machine_Ip",
    "Entra_InstanceCount", "Entra_HybridCount", "Entra_RegisteredCount", "Sophos_InstanceCount",
    "Entra_DuplicateFlag", "Sophos_DuplicateFlag", "Intune_DuplicateFlag",
    # Grouped together deliberately - the whole point is being able to
    # eyeball these 3 side by side for a given device (especially an
    # Entra duplicate) to see which Entra Device ID actually matches
    # the device's AD Object GUID-linked identity vs. Intune's record
    # of it. table_cols below is ordered from ALL_DISPLAYABLE_COLUMNS,
    # not from sidebar selection order, specifically so this trio stays
    # adjacent in the Data table no matter what order they're clicked
    # in the picker.
    "AD_ObjectGUID", "Entra_DeviceIds", "Intune_AzureADDeviceIds",
    # Automates the comparison the trio above supports manually -
    # placed right after it for the same reason.
    "Entra_HybridIdMatchesAD", "Entra_HybridIdMismatchExists",
    "DaysSinceLastPatch", "EventSentry_AgeDays", "EventSentry_Stale",
    "IsPersonalDevice", "IsCorporateDevice", "IsEventSentryOnly", "EventSentry_StubRecordOnly",
]

# Friendly display labels for every column the Data table can show -
# previously only a handful of special-cased columns (note, NoteStatus,
# DeviceHealth, etc.) and the presence columns got real labels; anything
# else fell through to its raw SQL column name (e.g. "LastSeen" instead
# of "Last Seen"). This is the single source of truth for column display
# names; column_config below builds off of it so nothing has to be
# hand-labeled twice in two different places.
FRIENDLY_COLUMN_LABELS = {
    "Name": "Name",
    "DeviceHealth": "Health",
    "HealthReason": "Health Reason",
    "note": "Notes",
    "NoteStatus": "Status",
    "OS": "OS",
    "DeviceType": "Device Type",
    "PatchStatus": "Patch Status",
    "MultiInstanceFlag": "Duplicate Devices",
    "PrimaryUser": "Primary User",
    "BranchLocation": "Physical Device Location",
    "LastSeen": "Last Seen",
    "SerialNumber": "Serial Number",
    "Memory": "Memory (GB)",
    "Sophos_ipv4Addresses": "Sophos IP Address",
    "KACE_Machine_Ip": "KACE IP Address",
    "Entra_InstanceCount": "Entra Device Instance Count",
    "Entra_HybridCount": "Entra Hybrid Joined",
    "Entra_RegisteredCount": "Entra Registered",
    "Sophos_InstanceCount": "Sophos Device Instance Count",
    "Entra_DuplicateFlag": "Entra Duplicate",
    "Sophos_DuplicateFlag": "Sophos Duplicate",
    "Intune_DuplicateFlag": "Intune Duplicate",
    "AD_ObjectGUID": "AD Object GUID",
    "Entra_DeviceIds": "Entra Device ID(s)",
    "Intune_AzureADDeviceIds": "Intune Entra Device ID(s)",
    "Entra_HybridIdMatchesAD": "Entra Device ID Matches AD Object GUID",
    "Entra_HybridIdMismatchExists": "Entra Device ID Mismatches AD Object GUID",
    "DaysSinceLastPatch": "Days Since Last Patch",
    "EventSentry_AgeDays": "EventSentry Age (Days)",
    "EventSentry_Stale": "EventSentry Stale",
    "IsPersonalDevice": "Personal Device",
    "IsCorporateDevice": "Corporate Device",
    "IsEventSentryOnly": "Removal Needed (EventSentry-Only)",
    "EventSentry_StubRecordOnly": "ES Record, No Agent",
    "NoteUpdatedAt": "Note Updated",
    "updated_by": "Updated By",
}

CONTEXT_OPTIONS = [
    "Show all devices", "Devices in Entra", "Devices in Intune", "Devices in AD",
    "Devices in Sophos", "Devices in KACE", "Devices in EventSentry", "Devices in all systems"
]
CONTEXT_COLUMN_MAP = {
    "Devices in Entra": "InEntra", "Devices in Intune": "InIntune", "Devices in AD": "InAD",
    "Devices in Sophos": "InSophos", "Devices in KACE": "InKACE", "Devices in EventSentry": "InEventSentry",
}
CONTEXT_EXCLUSIONS = {
    "InEntra": ["InIntune", "InAD", "InSophos", "InKACE", "InEventSentry"],
    "InIntune": ["InEntra", "InAD", "InSophos", "InKACE", "InEventSentry"],
    "InAD": ["InEntra", "InIntune", "InSophos", "InKACE", "InEventSentry"],
    "InSophos": ["InEntra", "InIntune", "InAD", "InKACE", "InEventSentry"],
    "InKACE": ["InEntra", "InIntune", "InAD", "InSophos", "InEventSentry"],
    "InEventSentry": ["InEntra", "InIntune", "InAD", "InSophos", "InKACE"],
}

# ==================================
# ---------- Data loading ----------
# ==================================

def get_connection():
    return sqlite3.connect(str(DB_PATH))


@st.cache_data(ttl=300)  # short TTL since SQLite reads are cheap; refresh button still works as before
def load_devices() -> pd.DataFrame:
    """
    Loads the fully-normalized device view. NO transformation happens
    here - normalize_bool_column, derive_device_health, etc. have all
    been removed from this app because that logic now lives in
    sql/02_views.sql (v_devices_final). This function is intentionally
    a thin pass-through.
    """
    with get_connection() as conn:
        df = pd.read_sql_query("SELECT * FROM v_devices_final", conn)
    # SQLite has no native bool type; columns come back as 0/1 ints.
    # This is a display convenience cast only, NOT business logic.
    bool_like_cols = PRESENCE_COLS + [
        "IsPersonalDevice", "IsCorporateDevice", "MultiInstanceFlag",
        "Entra_DuplicateFlag", "Intune_DuplicateFlag", "Sophos_DuplicateFlag",
        "EventSentry_AgentPresent", "EventSentry_Stale", "IsEventSentryRelevant",
        "IsActiveElsewhere", "Anomaly_ES_MissingWhileActive", "Anomaly_ES_StaleWhileActive",
        "IsEventSentryOnly", "EventSentry_StubRecordOnly",
    ]
    for col in bool_like_cols:
        if col in df.columns:
            df[col] = df[col].astype(bool)
    return df


def get_source_freshness() -> pd.DataFrame:
    """Roadmap item #9: per-source freshness, from source_run_log."""
    with get_connection() as conn:
        try:
            df = pd.read_sql_query(
                """
                SELECT source_name, MAX(completed_at) AS last_success
                FROM source_run_log
                WHERE status = 'Success'
                GROUP BY source_name
                """,
                conn,
            )
        except Exception:
            return pd.DataFrame(columns=["source_name", "last_success"])
    return df


def ensure_metrics_table():
    """
    Creates the metric_snapshots table if it doesn't exist yet. This is
    NOT part of sql/01_schema.sql or 02_views.sql on purpose - it's
    dashboard-presentation state (daily counts for trend deltas), not
    raw device data or a normalization view, so it doesn't belong in
    either of those files' DROP+CREATE lifecycle. CREATE TABLE IF NOT
    EXISTS makes this safe to call on every page load.
    """
    with get_connection() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS metric_snapshots (
                snapshot_date          TEXT PRIMARY KEY,
                captured_at             TEXT,
                total_devices           INTEGER,
                corporate_devices        INTEGER,
                personal_devices         INTEGER,
                devices_fully_managed      INTEGER,
                not_fully_managed         INTEGER,
                dup_count               INTEGER,
                stale_count              INTEGER,
                missing_count            INTEGER,
                removal_needed_count       INTEGER,
                stub_record_count         INTEGER,
                total_problem            INTEGER,
                patch_current            INTEGER,
                patch_behind             INTEGER,
                patch_critical            INTEGER,
                patch_unknown            INTEGER
            )
            """
        )
        conn.commit()


def save_metric_snapshot(metrics: dict):
    """
    Upserts today's row, keyed on the calendar date (not a timestamp),
    so re-running the pipeline/refresh multiple times in one day just
    updates today's snapshot rather than creating duplicates. Tomorrow,
    today's values become "yesterday" for the delta comparison.
    """
    today = datetime.now().strftime("%Y-%m-%d")
    cols = list(metrics.keys())
    update_clause = ", ".join(f"{c} = excluded.{c}" for c in cols)
    col_list = ", ".join(cols)
    placeholders = ", ".join(["?"] * len(cols))
    with get_connection() as conn:
        conn.execute(
            f"""
            INSERT INTO metric_snapshots (snapshot_date, captured_at, {col_list})
            VALUES (?, ?, {placeholders})
            ON CONFLICT(snapshot_date) DO UPDATE SET
                captured_at = excluded.captured_at,
                {update_clause}
            """,
            (today, datetime.now().isoformat(), *metrics.values()),
        )
        conn.commit()


def get_previous_snapshot():
    """Most recent snapshot strictly before today, or None if there isn't one yet
    (first run, or this is the very first day metrics have been tracked)."""
    today = datetime.now().strftime("%Y-%m-%d")
    with get_connection() as conn:
        try:
            cur = conn.execute(
                "SELECT * FROM metric_snapshots WHERE snapshot_date < ? ORDER BY snapshot_date DESC LIMIT 1",
                (today,),
            )
            row = cur.fetchone()
            if not row:
                return None
            col_names = [d[0] for d in cur.description]
            return dict(zip(col_names, row))
        except Exception:
            return None


def delta_vs_previous(current, previous_snapshot, key):
    """Returns current - previous for the given metric key, or None if no
    previous snapshot exists yet - st.metric simply omits the delta arrow
    when passed None, which is the right behavior for day one."""
    if previous_snapshot is None or previous_snapshot.get(key) is None:
        return None
    return current - previous_snapshot[key]


def save_note(device_key: str, device_name_hint: str, note: str, status: str, updated_by: str = "Dashboard User"):
    """Upserts a single device's note. Never touches device data tables."""
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO device_notes (device_key, device_name_hint, note, status, updated_by, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(device_key) DO UPDATE SET
                note = excluded.note,
                status = excluded.status,
                updated_by = excluded.updated_by,
                updated_at = excluded.updated_at,
                device_name_hint = excluded.device_name_hint
            """,
            (device_key, device_name_hint, note, status, updated_by, datetime.now().isoformat()),
        )
        conn.commit()


def format_datetime_display(val) -> str:
    """
    Parses a timestamp that may have arrived in any of several raw
    source formats (same situation as LastSeen in the Data table - see
    DATETIME_LIKE_COLUMNS below) and renders it as 12-hour AM/PM text
    for single-value display contexts like st.metric, which (unlike
    DatetimeColumn) has no built-in datetime formatting of its own.
    Falls back to the original raw text if it can't be parsed, rather
    than silently showing blank - useful for spotting a genuinely
    unusual source format if one ever shows up.
    """
    if val is None or (isinstance(val, float) and pd.isna(val)):
        return ""
    parsed = pd.to_datetime(val, errors="coerce")
    if pd.isna(parsed):
        return str(val)
    return parsed.strftime("%m/%d/%Y %I:%M %p")


def device_key_for_row(row) -> str:
    """Mirrors the join logic in v_devices_final's device_notes join."""
    guid = row.get("AD_ObjectGUID")
    # pd.notna(), not a bare truthiness check - see the matching note
    # in handle_data_table_note_edits. A missing GUID comes back as
    # NaN (a float) from a pandas row, and "nan and str(nan).strip()"
    # evaluates to the truthy string "nan", silently producing
    # "GUID:nan" instead of falling back to "NAME:...". That key would
    # never match v_devices_final's SQL-side join (which correctly
    # falls back to NAME: for a NULL GUID), so any note saved this way
    # would vanish into an orphaned device_notes row - never displayed
    # back, looking exactly like the save silently failed.
    if pd.notna(guid) and str(guid).strip():
        return f"GUID:{guid}"
    return f"NAME:{row.get('Name')}"


def adjust_count_for_duplicates(base_count, series_entra, series_sophos):
    """
    Ported from the original CSV-based app. Accounts for devices with
    multiple instances across Entra/Sophos when summarizing counts -
    e.g. a device hybrid-AND-registered in Entra, or duplicated in
    Sophos, should contribute its extra instances to the total rather
    than being silently collapsed to one. Used only by the Advanced
    Context Analysis charts below; the main Problem Summary metrics
    already get duplicate-aware counts directly from the SQL views.
    """
    extra_entra = (series_entra - 1).clip(lower=0).sum()
    extra_sophos = (series_sophos - 1).clip(lower=0).sum()
    return int(base_count + extra_entra + extra_sophos)


# =============================================
# ---------- Page setup ----------
# =============================================
with open(CSS_PATH) as f:
    st.markdown(f"<style>{f.read()}</style>", unsafe_allow_html=True)

st.set_page_config(layout='wide', initial_sidebar_state='expanded', page_title='CVB Device Dashboard', page_icon=CVB_SQ_ICON)
st.logo(CVB_RECTANGULAR_LOGO, size='large', icon_image=CVB_SQ_LOGO)
st.title('CVB Device Dashboard')

# ---------- Mandatory "Your Name" gate ----------
# IMPORTANT, and worth being direct about: this is NOT authentication.
# Nothing here verifies that the person selecting/typing a name is
# actually that person - anyone can pick any name from the list, or
# type any name into "Other." This only makes the existing honor-system
# attribution unavoidable up front instead of an easily-skipped sidebar
# field; it does not restrict WHO can access this dashboard or verify
# identity in any way. Real access control would require actual
# authentication (IIS + Windows Integrated Auth, or similar - see
# PROJECT_REFERENCE.md's Known Limitations for why that wasn't pursued
# here). st.stop() below halts this entire script run before anything
# else (Refresh button, freshness banner, sidebar, Data table, etc.)
# gets a chance to render, for as long as no name has been chosen yet
# in this browser session.
if "your_name" not in st.session_state:
    st.session_state["your_name"] = ""

if not st.session_state["your_name"].strip():
    st.markdown("#### Welcome — please select your name to continue")
    st.caption("Used to attribute any Notes/Status edits you make. Not a login - just identifies your edits.")
    staff_names = get_it_staff_names()
    gate_options = ["— Select your name —"] + staff_names + ["Other (type your name)"]
    gate_choice = st.selectbox("Your name", gate_options, key="gate_name_choice")
    typed_name = ""
    if gate_choice == "Other (type your name)":
        typed_name = st.text_input("Type your name", key="gate_name_typed")
    if st.button("Continue", type="primary"):
        if gate_choice == "Other (type your name)":
            resolved = typed_name.strip()
        elif gate_choice == "— Select your name —":
            resolved = ""
        else:
            resolved = gate_choice
        if resolved:
            st.session_state["your_name"] = resolved
            st.rerun()
        else:
            st.warning("Please select or type a name before continuing.")
    st.stop()

if "refresh_running" not in st.session_state:
    st.session_state.refresh_running = False


def refresh_and_wait():
    st.session_state.refresh_running = True
    with st.spinner("Running device data pipeline..."):
        try:
            pipeline_script = APP_DIR / "Invoke-DeviceScopePipeline.ps1"
            result = subprocess_run = __import__("subprocess").run(
                ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(pipeline_script)],
                check=True, capture_output=True, text=True
            )
        except Exception as e:
            st.session_state.refresh_running = False
            # str(e) alone is nearly useless for CalledProcessError - it's
            # just "Command [...] returned non-zero exit status 1", with
            # no hint of WHY. The actual reason is in e.stdout/e.stderr
            # (captured because of capture_output=True above), which were
            # never being shown before this fix - getattr() guards against
            # other exception types (e.g. FileNotFoundError if powershell
            # itself isn't on PATH) that don't have these attributes at all.
            st.error(f"Pipeline failed:\n{e}")
            stdout_text = getattr(e, "stdout", None)
            stderr_text = getattr(e, "stderr", None)
            if stdout_text:
                st.caption("Pipeline stdout:")
                st.code(stdout_text, language="text")
            if stderr_text:
                st.caption("Pipeline stderr:")
                st.code(stderr_text, language="text")
            if not stdout_text and not stderr_text:
                st.caption("No stdout/stderr was captured - this may be a different kind of failure "
                           "(e.g. PowerShell itself not found, or the script path doesn't exist).")
            return
        load_devices.clear()
        st.success("Pipeline run complete. Data refreshed.")
    st.session_state.refresh_running = False


st.button("🔄 Refresh Device Data", on_click=refresh_and_wait, disabled=st.session_state.refresh_running)

if not DB_PATH.exists():
    st.warning(f"No database found yet at: {DB_PATH}\n\nRun the pipeline once to initialize, or check config.json's SqliteDbPath if this looks like the wrong location.")
    st.stop()

df = load_devices()
freshness = get_source_freshness()
ensure_metrics_table()

# ---------- Freshness banner (roadmap #9) ----------
# Only shown if something is stale - no clutter when everything's fresh.
if not freshness.empty:
    now = datetime.now()
    stale_sources = []
    for _, r in freshness.iterrows():
        try:
            last = datetime.fromisoformat(r["last_success"])
            age_hours = (now - last).total_seconds() / 3600
            if age_hours > 20:  # rough "older than one daily cycle" threshold
                stale_sources.append(f"{r['source_name']} ({age_hours:.0f}h old)")
        except Exception:
            pass
    if stale_sources:
        st.warning("⚠ Some sources are using cached data from a previous run: " + ", ".join(stale_sources))
    overall_last = pd.to_datetime(freshness["last_success"]).max()
    if pd.notna(overall_last):
        st.caption(f"Most recent successful pull: {overall_last.strftime('%m/%d/%Y %I:%M %p')}")
    else:
        st.caption("Most recent successful pull: unknown")
else:
    st.caption("No pipeline runs recorded yet.")

# =============================
# ---------- Sidebar ----------
# =============================

# No authentication on this app (single shared server, no SSO layer in
# front of it - see project notes), so there's no way to automatically
# know who's editing a Notes/Status field. This is an honor-system
# identity field - by this point in the script, "your_name" is already
# guaranteed non-empty (the gate above blocked execution otherwise);
# this control just lets someone correct a mis-selection or hand off
# to a different person mid-session without restarting the whole app.
st.sidebar.subheader("Your Name")
staff_names = get_it_staff_names()
sidebar_options = staff_names + ["Other (type your name)"]
current_name = st.session_state["your_name"]
default_idx = sidebar_options.index(current_name) if current_name in staff_names else len(sidebar_options) - 1
sidebar_choice = st.sidebar.selectbox(
    "Used to attribute Notes/Status edits", sidebar_options, index=default_idx, key="sidebar_name_choice",
)
if sidebar_choice == "Other (type your name)":
    typed_sidebar_name = st.sidebar.text_input(
        "Type your name", value=current_name if current_name not in staff_names else "", key="sidebar_name_typed",
    )
    st.session_state["your_name"] = typed_sidebar_name.strip() or current_name
else:
    st.session_state["your_name"] = sidebar_choice

st.sidebar.header('Filters')

# All filters bundled into one expander, defaulted OPEN - this changes
# nothing about what's visible without clicking compared to before;
# it just replaces two separate header lines with the expander's own
# label, and groups things that conceptually belong together. The
# Duplicate Devices radio is now horizontal (3 stacked rows -> 1 row)
# for a quick space win with zero functional change. The standalone
# "Problem Devices" subheader is folded in here too rather than
# getting its own header line.
with st.sidebar.expander("🔍 Data Table Filters", expanded=True):
    selected_context = st.selectbox("Filter by Context", CONTEXT_OPTIONS)
    if selected_context not in ("Show all devices", "Devices in all systems"):
        exclusive_only = st.checkbox(f"Show only devices exclusively in: {selected_context.replace('Devices in ', '')}")
    else:
        exclusive_only = False

    device_types = df['OS'].dropna().unique() if 'OS' in df.columns else []
    selected_os = st.multiselect('Filter by OS', sorted(device_types))

    device_type_choices = sorted(df["DeviceType"].dropna().unique()) if "DeviceType" in df.columns else []
    selected_device_types = st.multiselect('Filter by Device Type', device_type_choices)

    branches = sorted(df["BranchLocation"].dropna().unique()) if "BranchLocation" in df.columns else []
    selected_branches = st.multiselect('Filter by Branch', branches)

    # selectbox, not radio - horizontal=True only helps when the
    # container is wide enough to fit all labels side by side, which a
    # narrow sidebar column usually isn't (confirmed: it was still
    # wrapping to one-per-line despite horizontal=True). A dropdown is
    # always exactly one line regardless of label length or container
    # width, same as "Filter by Context" right above it.
    dup_filter = st.selectbox("Duplicate Devices filter",
                               ("Show all devices", "Show duplicates only", "Show non-duplicates only"))

    patch_filter = st.multiselect(
        "Filter by Patch Status",
        options=["Current", "Behind", "Critical", "Unknown", "Not Applicable"],
        default=[],
    )

    show_problems_only = st.checkbox("Only show problem devices")
    st.caption("Includes duplicates, stale/missing EventSentry agents, EventSentry-only devices needing "
               "removal, and EventSentry computer records with no agent installed.")

# Tucked away and collapsed by default - this is realistically a
# "set once, rarely touched" control for most people, and with 17
# default columns wrapping into chips, it was almost certainly the
# single biggest height contributor in the old always-visible layout.
with st.sidebar.expander("📋 Columns", expanded=False):
    # format_func only changes what's DISPLAYED in the widget - the values
    # returned in visible_columns are still the real column names, so
    # nothing downstream (table_cols, table_view, etc.) needs to change.
    # Falls back to PRESENCE_DISPLAY for the 6 presence columns (handled
    # separately from FRIENDLY_COLUMN_LABELS, same as in column_config
    # below), then to the raw name as a last resort.
    _presence_label_lookup = dict(zip(PRESENCE_COLS, PRESENCE_DISPLAY))
    visible_columns = st.multiselect(
        "Choose columns to display",
        options=ALL_DISPLAYABLE_COLUMNS,
        default=DEFAULT_TABLE_COLUMNS,
        format_func=lambda c: _presence_label_lookup.get(c, FRIENDLY_COLUMN_LABELS.get(c, c)),
    )

# ---------- Apply filters ----------
filtered_df = df.copy()

if selected_os:
    filtered_df = filtered_df[filtered_df['OS'].isin(selected_os)]
if selected_device_types:
    filtered_df = filtered_df[filtered_df['DeviceType'].isin(selected_device_types)]
if selected_branches:
    filtered_df = filtered_df[filtered_df["BranchLocation"].isin(selected_branches)]

if selected_context == "Show all devices":
    pass
elif selected_context == "Devices in all systems":
    filtered_df = filtered_df[filtered_df[PRESENCE_COLS].all(axis=1)]
elif selected_context in CONTEXT_COLUMN_MAP:
    col = CONTEXT_COLUMN_MAP[selected_context]
    if exclusive_only:
        other_cols = CONTEXT_EXCLUSIONS[col]
        filtered_df = filtered_df[(filtered_df[col]) & (~filtered_df[other_cols].any(axis=1))]
    else:
        filtered_df = filtered_df[filtered_df[col]]

if dup_filter == "Show duplicates only":
    filtered_df = filtered_df[filtered_df["MultiInstanceFlag"]]
elif dup_filter == "Show non-duplicates only":
    filtered_df = filtered_df[~filtered_df["MultiInstanceFlag"]]

if patch_filter:
    filtered_df = filtered_df[filtered_df["PatchStatus"].isin(patch_filter)]

if show_problems_only:
    filtered_df = filtered_df[
        filtered_df["MultiInstanceFlag"]
        | filtered_df["Anomaly_ES_StaleWhileActive"]
        | filtered_df["Anomaly_ES_MissingWhileActive"]
        | filtered_df["IsEventSentryOnly"]
        | filtered_df["EventSentry_StubRecordOnly"]
    ]

# True whenever any sidebar filter actually narrows the device set.
# Used to suppress trend-delta arrows on the summary cards below -
# "today's filtered subset vs. yesterday's whole-fleet snapshot"
# would be a misleading comparison, so deltas only show when looking
# at the full, unfiltered fleet (matching what was actually snapshotted).
filters_active = (
    selected_context != "Show all devices"
    or exclusive_only
    or bool(selected_os)
    or bool(selected_device_types)
    or bool(selected_branches)
    or dup_filter != "Show all devices"
    or bool(patch_filter)
    or show_problems_only
)

st.sidebar.subheader('Device overview selection')
device_names = sorted(df['Name'].dropna().unique())
selected_device = st.sidebar.selectbox('Choose device by Name:', device_names)

st.sidebar.markdown('''---
📧 Contact Nathan with any questions or feedback''')

# ==============================
# ---------- Main app ----------
# ==============================

def _filtered_delta(value, key):
    """Delta vs. yesterday's snapshot, but suppressed (returns None,
    which hides the arrow entirely) whenever a filter is active - a
    filtered subset compared against yesterday's whole-fleet snapshot
    isn't a meaningful comparison, so showing it would be misleading
    rather than just unhelpful."""
    if filters_active:
        return None
    return delta_vs_previous(value, prev_snapshot, key)


# ---------- Unfiltered counts: ALWAYS the full fleet, regardless of ----------
# ---------- sidebar filters - this is what gets snapshotted daily   ----------
# for trend deltas. If this were computed from filtered_df instead,
# whatever filter happened to be active on someone's screen at
# whatever moment the snapshot saves would corrupt tomorrow's "vs
# yesterday" baseline for everyone, not just that one session.
_unf_total_devices = len(df)
_unf_corporate_devices = int(df["IsCorporateDevice"].sum())
_unf_personal_devices = int(df["IsPersonalDevice"].sum())
_unf_devices_all_contexts = int(df[PRESENCE_COLS].all(axis=1).sum())
_unf_not_fully_managed = _unf_total_devices - _unf_devices_all_contexts
_unf_dup_count = int(df["MultiInstanceFlag"].sum())
_unf_stale_count = int(df["Anomaly_ES_StaleWhileActive"].sum())
_unf_missing_count = int(df["Anomaly_ES_MissingWhileActive"].sum())
_unf_removal_needed_count = int(df["IsEventSentryOnly"].sum())
_unf_stub_record_count = int(df["EventSentry_StubRecordOnly"].sum())
_unf_total_problem = int((
    df["MultiInstanceFlag"]
    | df["Anomaly_ES_StaleWhileActive"]
    | df["Anomaly_ES_MissingWhileActive"]
    | df["IsEventSentryOnly"]
    | df["EventSentry_StubRecordOnly"]
).sum())
_unf_patch_counts = df["PatchStatus"].value_counts().to_dict()

# ---------- Persist today's snapshot, then pull yesterday's for deltas (roadmap #10) ----------
# Snapshot is saved BEFORE reading "previous" so a same-day refresh never
# compares today against itself - get_previous_snapshot() only ever looks
# at rows strictly before today's date, regardless of save order, but
# saving first means the very first page load of a new day still has
# yesterday's true row intact to read (nothing here overwrites yesterday).
save_metric_snapshot({
    "total_devices": _unf_total_devices,
    "corporate_devices": _unf_corporate_devices,
    "personal_devices": _unf_personal_devices,
    "devices_fully_managed": _unf_devices_all_contexts,
    "not_fully_managed": _unf_not_fully_managed,
    "dup_count": _unf_dup_count,
    "stale_count": _unf_stale_count,
    "missing_count": _unf_missing_count,
    "removal_needed_count": _unf_removal_needed_count,
    "stub_record_count": _unf_stub_record_count,
    "total_problem": _unf_total_problem,
    "patch_current": _unf_patch_counts.get("Current", 0),
    "patch_behind": _unf_patch_counts.get("Behind", 0),
    "patch_critical": _unf_patch_counts.get("Critical", 0),
    "patch_unknown": _unf_patch_counts.get("Unknown", 0),
})
prev_snapshot = get_previous_snapshot()

# ---------- Filtered counts: what's actually DISPLAYED on the cards ----------
# Driven by filtered_df, not df - these respond live to every sidebar
# filter (Context, OS, Device Type, Branch, Duplicate filter, Patch
# Status filter, "Only show problem devices"), matching the same
# subset the Data table already reflects. The column picker is
# deliberately excluded from this - it only changes which columns
# display, never which rows, so it has no bearing on these counts.
total_devices = len(filtered_df)
corporate_devices = int(filtered_df["IsCorporateDevice"].sum())
personal_devices = int(filtered_df["IsPersonalDevice"].sum())
devices_all_contexts = int(filtered_df[PRESENCE_COLS].all(axis=1).sum())
not_fully_managed = total_devices - devices_all_contexts

dup_count = int(filtered_df["MultiInstanceFlag"].sum())
entra_dup = int(filtered_df["Entra_DuplicateFlag"].sum())
sophos_dup = int(filtered_df["Sophos_DuplicateFlag"].sum())
intune_dup = int(filtered_df["Intune_DuplicateFlag"].sum())
both_dup = int((filtered_df["Entra_DuplicateFlag"] & filtered_df["Sophos_DuplicateFlag"]).sum())

stale_count = int(filtered_df["Anomaly_ES_StaleWhileActive"].sum())
missing_count = int(filtered_df["Anomaly_ES_MissingWhileActive"].sum())
removal_needed_count = int(filtered_df["IsEventSentryOnly"].sum())
stub_record_count = int(filtered_df["EventSentry_StubRecordOnly"].sum())
total_problem = int((
    filtered_df["MultiInstanceFlag"]
    | filtered_df["Anomaly_ES_StaleWhileActive"]
    | filtered_df["Anomaly_ES_MissingWhileActive"]
    | filtered_df["IsEventSentryOnly"]
    | filtered_df["EventSentry_StubRecordOnly"]
).sum())

patch_counts = filtered_df["PatchStatus"].value_counts().to_dict()
patch_current = patch_counts.get("Current", 0)
patch_behind = patch_counts.get("Behind", 0)
patch_critical = patch_counts.get("Critical", 0)
patch_unknown = patch_counts.get("Unknown", 0)

# st.expander does NOT report its open/closed state back to the script
# at all - it's a purely client-side container with no server round
# trip when clicked, so st.session_state can never reflect it (the
# keyed-expander approach tried here previously didn't actually work
# for that reason). st.toggle, by contrast, is a real input widget -
# clicking it does trigger a rerun and updates session_state
# immediately, which is what lets the teaser line below correctly
# disappear the instant the section is opened.
analytics_open = st.toggle(
    "📊 Show Analytics (Metrics, Problem Summary, Patch Management, Charts)",
    value=False, key="analytics_open",
)
if not analytics_open:
    st.caption(f"🚨 {total_problem:,} problem devices · 🩹 {patch_critical:,} patch-critical · "
               f"⚠ {stale_count:,} EventSentry stale — toggle Analytics on above for the full breakdown.")

# This is an orientation/health-check view, not the primary workflow.
# The Data table (and Device Overview below it) is what people
# actually come to this dashboard to use day to day; this section
# shouldn't be the first thing standing between them and it on every
# page load - hence tucked behind a toggle, default off.
if analytics_open:
    st.markdown("### Metrics")
    if filters_active:
        st.caption("Reflecting the currently active sidebar filters. Trend deltas are hidden while a filter is "
                   "applied, since they're only meaningful compared to the full, unfiltered fleet. Clear all "
                   "filters to see deltas again.")
    elif prev_snapshot is None:
        st.caption("Trend deltas will appear starting tomorrow, once a prior day's snapshot exists.")
    col1, col2, col3, col4, col5 = st.columns(5)
    col1.metric("Total devices", f"{total_devices:,}",
                delta=_filtered_delta(total_devices, "total_devices"), delta_color="off")
    col2.metric("Corporate Devices", f"{corporate_devices:,}",
                delta=_filtered_delta(corporate_devices, "corporate_devices"), delta_color="off")
    col3.metric("Personal Devices", f"{personal_devices:,}",
                delta=_filtered_delta(personal_devices, "personal_devices"), delta_color="off")
    col4.metric("Devices Fully Managed", f"{devices_all_contexts:,}",
                delta=_filtered_delta(devices_all_contexts, "devices_fully_managed"))
    col5.metric("Not Fully Managed", f"{not_fully_managed:,}",
                delta=_filtered_delta(not_fully_managed, "not_fully_managed"), delta_color="inverse")

    tab_problems, tab_patch, tab_charts = st.tabs(["🚨 Problem Summary", "🩹 Patch Management", "📊 Charts"])

    # ===========================================
    # ---------- Tab: Problem Summary ----------
    # ===========================================
    with tab_problems:
        st.markdown("#### Problem Summary")

        m1, m2, m3, m4, m5, m6 = st.columns(6)
        m1.metric("Duplicate Devices", f"{dup_count:,}",
                  delta=_filtered_delta(dup_count, "dup_count"), delta_color="inverse")
        m1.caption(f"Entra: {entra_dup} · Sophos: {sophos_dup} · Intune: {intune_dup} · Both Entra+Sophos: {both_dup}")
        m2.metric("EventSentry Stale", f"{stale_count:,}",
                  delta=_filtered_delta(stale_count, "stale_count"), delta_color="inverse")
        m3.metric("Missing ES Agent While Active", f"{missing_count:,}",
                  delta=_filtered_delta(missing_count, "missing_count"), delta_color="inverse")
        m4.metric("Removal Needed", f"{removal_needed_count:,}",
                  delta=_filtered_delta(removal_needed_count, "removal_needed_count"), delta_color="inverse")
        m4.caption("EventSentry-only - removed from every other system")
        m5.metric("ES Record, No Agent", f"{stub_record_count:,}",
                  delta=_filtered_delta(stub_record_count, "stub_record_count"), delta_color="inverse")
        m5.caption("In EventSentry's computer list, agent never installed")
        m6.metric("Total Problem Devices (Unique)", f"{total_problem:,}",
                  delta=_filtered_delta(total_problem, "total_problem"), delta_color="inverse")
        st.caption("Note: Individual problem counts may overlap. Total represents unique affected devices. "
                   "Personal/MAM-managed mobile devices are excluded from EventSentry-related checks. "
                   "Deltas compare against the most recent prior day's snapshot; a red ▲ means the count went up.")

        st.markdown("#### Problem Breakdown")
        problem_df = pd.DataFrame({
            "Problem": ["Duplicate Devices", "EventSentry Stale", "Missing ES Agent While Active",
                        "Removal Needed", "ES Record, No Agent"],
            "Count": [dup_count, stale_count, missing_count, removal_needed_count, stub_record_count],
        })
        chart = alt.Chart(problem_df).mark_bar(cornerRadiusTopLeft=4, cornerRadiusTopRight=4).encode(
            x=alt.X("Problem:N", sort=None, title=""),
            y=alt.Y("Count:Q", title="Device Count"),
            color=alt.Color("Problem:N", legend=None,
                             scale=alt.Scale(domain=["Duplicate Devices", "EventSentry Stale", "Missing ES Agent While Active",
                                                      "Removal Needed", "ES Record, No Agent"],
                                             range=["#36b9cc", "#f6c23e", "#e74a3b", "#858796", "#5a5c69"])),
            tooltip=["Problem", "Count"],
        ).properties(height=280)
        st.altair_chart(chart, width='stretch')

    # ===========================================
    # ---------- Tab: Patch Management ----------
    # ===========================================
    with tab_patch:
        st.markdown("#### Patch Management")
        p1, p2, p3, p4 = st.columns(4)
        p1.metric("Current (≤30 days)", f"{patch_current:,}",
                  delta=_filtered_delta(patch_current, "patch_current"))
        p2.metric("Behind (31-60 days)", f"{patch_behind:,}",
                  delta=_filtered_delta(patch_behind, "patch_behind"), delta_color="inverse")
        p3.metric("Critical (60+ days)", f"{patch_critical:,}",
                  delta=_filtered_delta(patch_critical, "patch_critical"), delta_color="inverse")
        p4.metric("Unknown (no EventSentry data)", f"{patch_unknown:,}",
                  delta=_filtered_delta(patch_unknown, "patch_unknown"), delta_color="inverse")
        st.caption("Patch status is sourced from EventSentry security/cumulative update install dates. "
                   "'Unknown' reflects devices without EventSentry agent coverage, not unpatched devices. "
                   "Deltas compare against the most recent prior day's snapshot.")

        # 100%-stacked bar: at-a-glance share of devices in each patch bucket,
        # independent of how the total device count is trending day to day.
        #
        # Switched from Vega-Lite's automatic stacking to manually-computed
        # Start/End/Mid fractions in pandas. Two real bugs with the
        # automatic-stack approach: (1) an unsorted "order" encoding on a
        # nominal field stacks alphabetically (Behind, Critical, Current,
        # Unknown), not in the Current/Behind/Critical/Unknown order the
        # color scale/legend implies; (2) text marks in a stacked context
        # position at the START of their segment, not the center, so labels
        # sat on segment boundaries and bled into the neighboring color.
        # Computing exact Start/End/Mid ourselves and feeding bars an
        # explicit x/x2 (rather than a single stacked x) sidesteps both -
        # the bar and the label are now guaranteed to agree on where each
        # segment actually is, in the order we choose.
        patch_total = patch_current + patch_behind + patch_critical + patch_unknown
        status_order = ["Current", "Behind", "Critical", "Unknown"]
        patch_share_df = pd.DataFrame({
            "Category": ["All Devices"] * 4,
            "PatchStatus": status_order,
            "Count": [patch_current, patch_behind, patch_critical, patch_unknown],
        })
        patch_share_df["Frac"] = (patch_share_df["Count"] / patch_total) if patch_total else 0.0
        patch_share_df["End"] = patch_share_df["Frac"].cumsum()
        patch_share_df["Start"] = patch_share_df["End"] - patch_share_df["Frac"]
        patch_share_df["Mid"] = (patch_share_df["Start"] + patch_share_df["End"]) / 2
        patch_share_df["Pct"] = patch_share_df["Frac"] * 100
        patch_share_df["Label"] = patch_share_df.apply(
            lambda r: f"{r['PatchStatus']}: {r['Pct']:.0f}%" if r["Pct"] >= 4 else "", axis=1
        )

        color_scale = alt.Scale(domain=status_order, range=["#1cc88a", "#f6c23e", "#e74a3b", "#858796"])

        bars = alt.Chart(patch_share_df).mark_bar(size=60).encode(
            x=alt.X("Start:Q", title="Share of Devices", scale=alt.Scale(domain=[0, 1]),
                    axis=alt.Axis(format='%', tickCount=10)),
            x2="End:Q",
            y=alt.Y("Category:N", title=""),
            color=alt.Color("PatchStatus:N", scale=color_scale,
                             legend=alt.Legend(title="Patch Status", orient="bottom")),
            tooltip=["PatchStatus", "Count", alt.Tooltip("Pct:Q", format=".1f", title="Percent")],
        )
        # White fill keeps every label readable regardless of
        # which segment color it's sitting on.
        labels = alt.Chart(patch_share_df).mark_text(
            fontWeight="bold", baseline="middle", align="center",
            fill="white",
        ).encode(
            x=alt.X("Mid:Q", scale=alt.Scale(domain=[0, 1])),
            y=alt.Y("Category:N"),
            text="Label:N",
        )
        patch_share_chart = (bars + labels).properties(height=190)
        st.altair_chart(patch_share_chart, width='stretch')

    # ===========================================
    # ---------- Tab: Charts ----------
    # ===========================================
    with tab_charts:
        st.markdown("#### Advanced Context Analysis (legacy charts)")
        st.caption("Restored from the original CSV-based app. Same two visualizations as before - a "
                   "context-overlap heatmap and a device-association donut chart - rebuilt against the "
                   "current v_devices_final columns instead of recomputed Python booleans.")
        if filters_active:
            st.caption("Reflecting the currently active sidebar filters.")

        # ---- Context overlap heatmap ----
        # Adjusted the same way the original did: a raw boolean overlap mask
        # undercounts devices that have multiple instances in Entra or Sophos
        # (e.g. hybrid + registered in Entra), so extra instances beyond the
        # first are added back in for any cell touching that source.
        heatmap_matrix = pd.DataFrame(0, index=PRESENCE_DISPLAY, columns=PRESENCE_DISPLAY)
        for i, ci in zip(PRESENCE_DISPLAY, PRESENCE_COLS):
            for j, cj in zip(PRESENCE_DISPLAY, PRESENCE_COLS):
                overlap_mask = filtered_df[ci] & filtered_df[cj]
                base_count = int(overlap_mask.sum())
                extra_entra = 0
                extra_sophos = 0
                if i == "Entra" or j == "Entra":
                    extra_entra = (filtered_df.loc[overlap_mask, "Entra_InstanceCount"] - 1).clip(lower=0).sum()
                if i == "Sophos" or j == "Sophos":
                    extra_sophos = (filtered_df.loc[overlap_mask, "Sophos_InstanceCount"] - 1).clip(lower=0).sum()
                heatmap_matrix.loc[i, j] = int(base_count + extra_entra + extra_sophos)

        heatmap_data = heatmap_matrix.reset_index().melt(id_vars="index")
        heatmap_data.columns = ["Context1", "Context2", "DeviceCount"]

        heatmap_chart = alt.Chart(heatmap_data).mark_rect().encode(
            x=alt.X('Context1:N', title='', axis=alt.Axis(labelAngle=0)),
            y=alt.Y('Context2:N', title=''),
            color=alt.Color('DeviceCount:Q', scale=alt.Scale(scheme='blues')),
            tooltip=['Context1', 'Context2', 'DeviceCount'],
        ).properties(width='container', height=345, title='Context Overlap Heatmap')

        # ---- Device-association donut chart ----
        # How many systems each device shows up in (1 through 6), duplicate-adjusted.
        # Assigned on filtered_df (already its own copy from df.copy() up at
        # "Apply filters") rather than df, so this never mutates the cached,
        # unfiltered dataset that other parts of the page still rely on.
        filtered_df["ContextsPresent"] = filtered_df[PRESENCE_COLS].sum(axis=1)
        adjusted_counts = {}
        for num_contexts in sorted(filtered_df["ContextsPresent"].unique()):
            mask = filtered_df["ContextsPresent"] == num_contexts
            adjusted_counts[num_contexts] = adjust_count_for_duplicates(
                int(mask.sum()),
                filtered_df.loc[mask, "Entra_InstanceCount"],
                filtered_df.loc[mask, "Sophos_InstanceCount"],
            )
        association_data = pd.DataFrame({
            "ContextsPresent": list(adjusted_counts.keys()),
            "DeviceCount": list(adjusted_counts.values()),
        })

        c1, c2 = st.columns((7, 3))
        with c1:
            st.markdown('##### Heatmap')
            st.altair_chart(heatmap_chart, width='stretch')
        with c2:
            st.markdown('##### Device context chart')
            plost.donut_chart(
                data=association_data,
                theta="DeviceCount",
                color="ContextsPresent",
                legend='bottom',
                width='stretch',
            )

        st.divider()
        st.markdown("#### Device Health Distribution")
        st.caption("Room for more here as the dashboard grows - e.g. patch-vs-health treemaps, "
                   "source-overlap Sankey diagrams, etc.")
        health_counts = filtered_df["DeviceHealth"].value_counts().reset_index()
        health_counts.columns = ["DeviceHealth", "Count"]
        health_chart = alt.Chart(health_counts).mark_arc(innerRadius=70).encode(
            theta=alt.Theta("Count:Q"),
            color=alt.Color("DeviceHealth:N", legend=alt.Legend(title="Device Health", orient="bottom")),
            tooltip=["DeviceHealth", "Count"],
        ).properties(height=320)
        st.altair_chart(health_chart, width='stretch')


# ---------- Data table ----------
st.markdown('### Data table')
st.caption("Source presence columns are shown first by design - this view's original purpose was always "
           "'which systems is this device in.' Use the sidebar's column picker to choose which columns "
           "load into this table. The table's own toolbar (top-right) only lets you search, reorder, or "
           "hide/show among columns already loaded here - it can't pull in new ones; that's the sidebar's job.")

table_cols = [c for c in ALL_DISPLAYABLE_COLUMNS if c in visible_columns and c in filtered_df.columns]
if not table_cols:
    st.info("No columns selected in the sidebar's column picker - showing Name only. "
             "Choose at least one column to see more detail.")
    table_cols = ["Name"]
table_view = filtered_df[table_cols].copy()

# Keep the join key around (hidden) so we can map edits back to device_key
table_view["_AD_ObjectGUID"] = filtered_df["AD_ObjectGUID"]
table_view["_Name"] = filtered_df["Name"]

# Clean 0..N-1 positional index - required because the on_change
# callback below identifies edited rows by POSITION (edited_rows keys
# are row positions, not pandas index labels), and table_view's index
# otherwise carries over filtered_df's original, non-contiguous index
# after row filtering.
table_view = table_view.reset_index(drop=True)

BOOLEAN_LIKE_COLUMNS = {
    "MultiInstanceFlag", "Entra_DuplicateFlag", "Sophos_DuplicateFlag", "Intune_DuplicateFlag",
    "EventSentry_Stale", "IsPersonalDevice", "IsCorporateDevice", "IsEventSentryOnly",
    "EventSentry_StubRecordOnly", "Entra_HybridIdMatchesAD", "Entra_HybridIdMismatchExists",
}

# Timestamp-like text columns get parsed into real datetimes here so
# DatetimeColumn below can render them in a consistent 12-hour AM/PM
# format. LastSeen in particular is a COALESCE across 4 different
# source systems (Intune/Sophos/Entra/KACE) with different raw text
# formats - pd.to_datetime's flexible per-element parsing handles that
# mix without needing source-specific format strings; anything it
# can't parse becomes NaT, which DatetimeColumn just renders blank
# rather than erroring.
DATETIME_LIKE_COLUMNS = {"LastSeen", "NoteUpdatedAt"}
for dt_col in DATETIME_LIKE_COLUMNS:
    if dt_col in table_view.columns:
        # format='mixed' is required here, not just errors='coerce' -
        # plain pd.to_datetime infers ONE format from the first valid
        # value and applies it to the whole column, silently turning
        # every differently-formatted row into NaT (caught this in
        # testing: a column mixing KACE's "5/20/2026 17:26" with
        # Entra's ISO "2026-06-15T09:23:11Z" only parsed the first
        # one). utc=True + tz_localize(None) reconciles the ISO
        # rows' explicit "Z" UTC marker against the other sources'
        # timezone-naive text, which format='mixed' otherwise rejects
        # outright as a mixed-timezone error.
        table_view[dt_col] = pd.to_datetime(
            table_view[dt_col], errors="coerce", format="mixed", utc=True
        ).dt.tz_localize(None)

column_config = {
    "note": st.column_config.TextColumn(FRIENDLY_COLUMN_LABELS["note"], width="medium"),
    "NoteStatus": st.column_config.SelectboxColumn(
        FRIENDLY_COLUMN_LABELS["NoteStatus"], options=["New", "Acknowledged", "Resolved"], width="small"
    ),
    "DeviceHealth": st.column_config.TextColumn(FRIENDLY_COLUMN_LABELS["DeviceHealth"], width="small"),
    "HealthReason": st.column_config.TextColumn(FRIENDLY_COLUMN_LABELS["HealthReason"], width="medium"),
    "PatchStatus": st.column_config.TextColumn(FRIENDLY_COLUMN_LABELS["PatchStatus"], width="small"),
    "LastSeen": st.column_config.DatetimeColumn(FRIENDLY_COLUMN_LABELS["LastSeen"], format="MM/DD/YYYY hh:mm A"),
    "NoteUpdatedAt": st.column_config.DatetimeColumn(FRIENDLY_COLUMN_LABELS["NoteUpdatedAt"], format="MM/DD/YYYY hh:mm A"),
    "_AD_ObjectGUID": None,  # hide
    "_Name": None,  # hide
}
for pc, pd_label in zip(PRESENCE_COLS, PRESENCE_DISPLAY):
    if pc in table_view.columns:
        column_config[pc] = st.column_config.CheckboxColumn(pd_label, width="small")

# Everything else: pull a friendly label from FRIENDLY_COLUMN_LABELS
# (falling back to the raw column name only if something genuinely
# isn't in the map yet, so a future new column never silently breaks
# rather than just looking slightly less polished). Boolean-like
# columns get a CheckboxColumn for a cleaner glance-and-go read.
for col in table_view.columns:
    if col in column_config:
        continue  # already explicitly configured above
    label = FRIENDLY_COLUMN_LABELS.get(col, col)
    if col in BOOLEAN_LIKE_COLUMNS:
        column_config[col] = st.column_config.CheckboxColumn(label, width="small")
    else:
        column_config[col] = st.column_config.Column(label)

# Lookup table so the on_change callback below can resolve device
# identity and "what was there before" purely from session_state -
# callbacks run BEFORE the script reruns, so they have no access to
# table_view or any other script-body variable computed on this run;
# anything the callback needs has to be stashed in session_state first.
st.session_state["_data_table_row_lookup"] = table_view[
    [c for c in ("_AD_ObjectGUID", "_Name", "note", "NoteStatus") if c in table_view.columns]
].copy()


def handle_data_table_note_edits():
    """
    on_change callback for the main Data table editor. Replaces the
    previous approach (diff the editor's returned dataframe against a
    freshly-rebuilt table_view, after the fact, on the next script run).
    That approach had two real bugs, both stemming from the same root
    cause: st.data_editor persists an internal edit diff in
    st.session_state[key] and replays it against whatever data is
    passed in on EVERY rerun, not just the one where the edit happened.
    1. A one-edit-behind save lag - the diffed dataframe could be one
       rerun stale relative to what was actually just typed.
    2. The SAME persisted diff getting silently replayed against a
       freshly-reloaded table_view on an unrelated rerun (e.g. one
       triggered by saving a note via Device Overview instead),
       occasionally re-saving an old note/status value under whatever
       "Your Name" happened to be at that later moment - this is almost
       certainly why attribution looked wrong specifically in that
       scenario.
    Reading edited_rows directly here, in a callback that fires
    synchronously on the actual commit, sidesteps both - it only ever
    contains the row(s) that genuinely just changed, right now.
    """
    editor_state = st.session_state.get("main_data_editor")
    if not editor_state:
        return
    edited_rows = editor_state.get("edited_rows", {})
    if not edited_rows:
        return
    lookup = st.session_state.get("_data_table_row_lookup")
    if lookup is None:
        return
    editor_name = st.session_state.get("your_name", "").strip() or "Dashboard User"
    any_saved = False
    for row_pos, changes in edited_rows.items():
        if "note" not in changes and "NoteStatus" not in changes:
            continue
        row_pos = int(row_pos)
        if row_pos >= len(lookup):
            continue
        row = lookup.iloc[row_pos]
        guid = row.get("_AD_ObjectGUID")
        name = row.get("_Name")
        # pd.notna(), not a bare truthiness check - a missing GUID
        # comes back as NaN (a float), and "nan and str(nan).strip()"
        # evaluates to the truthy string "nan", which incorrectly
        # formed "GUID:nan" instead of falling back to "NAME:...".
        device_key = f"GUID:{guid}" if pd.notna(guid) and str(guid).strip() else f"NAME:{name}"
        new_note = changes.get("note", row.get("note"))
        new_status = changes.get("NoteStatus", row.get("NoteStatus"))
        save_note(device_key, name, new_note if not pd.isna(new_note) else "", new_status if not pd.isna(new_status) else "New",
                  updated_by=editor_name)
        any_saved = True
    if any_saved:
        load_devices.clear()


edited = st.data_editor(
    table_view,
    width='stretch',
    hide_index=True,
    column_config=column_config,
    # Derived from table_view's actual columns rather than table_cols -
    # this was the second half of the bug above: when table_cols came
    # back empty, disabled also came back empty, leaving every column in
    # the (accidental, oversized) fallback table editable.
    disabled=[c for c in table_view.columns if c not in ("note", "NoteStatus")],
    key="main_data_editor",
    on_change=handle_data_table_note_edits,
)

# ---------- Device Overview ----------
st.markdown(f"### Device Overview: {selected_device}")

device_rows = df.loc[df["Name"] == selected_device]
if device_rows.empty:
    st.warning("No data found for the selected device.")
    st.stop()

device_row = device_rows.head(1).iloc[0]

if device_row.get("IsPersonalDevice"):
    st.info("📱 This is a personal/MAM-managed mobile device (Entra-only). EventSentry and other corporate "
            "management checks are intentionally not applied.")

col1, col2, col3 = st.columns(3)
col1.metric("OS", device_row.get("OS") or "")
col2.metric("Device Type", device_row.get("DeviceType") or "")
mem_val = device_row.get("Memory")
col3.metric("Memory (GB)", f"{int(mem_val)}" if pd.notna(mem_val) else "")

col4, col5, col6 = st.columns(3)
col4.metric("Last Seen", format_datetime_display(device_row.get("LastSeen")))
col5.metric("Primary User", device_row.get("PrimaryUser") or "")
branch_location = device_row.get("BranchLocation")
if not branch_location and device_row.get("IsPersonalDevice"):
    branch_location_display = "Not Applicable"
else:
    branch_location_display = branch_location or ""
col6.metric("Physical Device Location", branch_location_display)

st.markdown("#### Health & Patch")
h1, h2, h3 = st.columns(3)
h1.metric("Device Health", device_row.get("DeviceHealth") or "")
h2.metric("Patch Status", device_row.get("PatchStatus") or "Unknown")
days_since = device_row.get("DaysSinceLastPatch")
# Falls back to "Not Applicable" rather than "Unknown" when PatchStatus
# itself is "Not Applicable" (personal/mobile devices) - otherwise this
# card read as a contradiction: "Patch Status: Not Applicable" right
# next to "Days Since Last Patch: Unknown", implying missing data
# worth chasing on a device that was never in scope to begin with.
if pd.notna(days_since):
    days_since_display = f"{int(days_since)}"
elif device_row.get("PatchStatus") == "Not Applicable":
    days_since_display = "Not Applicable"
else:
    days_since_display = "Unknown"
h3.metric("Days Since Last Patch", days_since_display)
# Title-based breakouts (Cumulative Update, Security Update) were both
# attempted and removed - see the comment in 02_views.sql's
# v_patch_agg for why. PatchStatus above is the single, trustworthy
# patch-currency signal for this dashboard.


def render_field_grid(title: str, icon: str, fields: list):
    """
    Compact label/value grid for the Identity/Compliance/Network/
    EventSentry sections, matching the original HTML render_section_grid()
    layout's look (small muted label directly above a bold value, two
    per row, light divider between sections) - but built entirely from
    native Streamlit components, no unsafe_allow_html anywhere:
      - st.caption() for the muted label (this is exactly what
        st.caption is for - small gray secondary text)
      - markdown bold ("**text**") for the value - this is standard
        Markdown syntax, not raw HTML, so st.markdown doesn't need
        unsafe_allow_html=True for it
      - st.divider() - a built-in Streamlit function for the section
        separator line, not a hand-rolled <hr>
    An earlier version of this helper used st.dataframe for a Field/
    Value table instead, which technically worked but didn't actually
    match this look - dataframes render with headers, gridlines, and
    a hover toolbar that the original layout never had.
    fields: list of (label, value) tuples. Values pass through _val()
    automatically so missing data renders as "—" consistently with
    the rest of the dashboard.
    """
    st.markdown(f"#### {icon} {title}")
    for i in range(0, len(fields), 2):
        pair = fields[i:i + 2]
        cols = st.columns(2)
        for col, (label, value) in zip(cols, pair):
            col.caption(label)
            col.markdown(f"**{_val(value)}**")
    st.divider()


def _val(v):
    """Card-friendly display value: blank instead of 'None'/'nan' for missing data."""
    if v is None or (isinstance(v, float) and pd.isna(v)) or v == "":
        return "—"
    return str(v)


# ---------- Presence, Duplicates ----------
# Converted from individual st.metric() boxes to the same compact
# field/value grid as Identity/Compliance/Network/EventSentry below -
# these are pure label+checkmark pairs (boolean presence flags, and
# duplicate-or-not per source), which is exactly the shape that grid
# already handles well. A bulky bordered card per single checkmark
# icon was a lot of visual weight for very little information.
render_field_grid("Presence", "📡", [
    (PRESENCE_DISPLAY[i], "✅" if device_row.get(pc, False) else "❌")
    for i, pc in enumerate(PRESENCE_COLS)
])

entra_dup = device_row.get("Entra_DuplicateFlag")
entra_count = device_row.get("Entra_InstanceCount")
sophos_dup = device_row.get("Sophos_DuplicateFlag")
sophos_count = device_row.get("Sophos_InstanceCount")
intune_dup = device_row.get("Intune_DuplicateFlag")
intune_count = device_row.get("Intune_InstanceCount")
render_field_grid("Duplicates", "🔁", [
    ("Entra", f"🔁 {entra_count} instances detected" if entra_dup else "✅ No duplicates found"),
    ("Sophos", f"🔁 {sophos_count} instances detected" if sophos_dup else "✅ No duplicates found"),
    ("Intune", f"🔁 {intune_count} instances detected" if intune_dup else "✅ No duplicates found"),
])

# ---------- Identity, Compliance, Network, EventSentry detail sections ----------
# Restored after the CSV->SQLite rewrite dropped these (the source data
# was always present in v_devices_final - only the Streamlit rendering
# of it was lost). Originally rebuilt as st.metric() card grids; now
# rebuilt again as compact Field/Value tables (render_field_grid above)
# per request - closer to the original HTML render_section_grid()
# layout's density, but via a native st.dataframe, not raw HTML.
render_field_grid("Identity", "🔐", [
    ("AD Object GUID", device_row.get("AD_ObjectGUID")),
    ("Entra Device ID", device_row.get("Entra_DeviceId")),
    ("Intune Device ID", device_row.get("Intune_DeviceId")),
    ("Intune Entra Device ID", device_row.get("Intune_AzureADDeviceIds")),
    ("KACE ID", device_row.get("KACE_ID")),
    ("Entra Join Type", device_row.get("Entra_JoinType")),
    ("DNS Hostname", device_row.get("AD_DNSHostName")),
    ("Serial Number", device_row.get("SerialNumber")),
])

render_field_grid("Compliance", "🛡️", [
    ("Intune Compliance", device_row.get("Intune_ComplianceState")),
    ("Intune Agent", device_row.get("Intune_ManagementAgent")),
    ("Entra Managed", device_row.get("Entra_IsManaged")),
    ("Entra Compliant", device_row.get("Entra_IsCompliant")),
])

kace_ip = device_row.get("KACE_Machine_Ip")
sophos_ip = device_row.get("Sophos_ipv4Addresses")
if kace_ip and sophos_ip and str(kace_ip) != str(sophos_ip):
    network_fields = [
        ("IP Address (KACE)", kace_ip),
        ("IP Address (Sophos)", sophos_ip),
    ]
else:
    network_fields = [("IP Address", kace_ip or sophos_ip)]
render_field_grid("Network", "🌐", network_fields)

is_personal = bool(device_row.get("IsPersonalDevice"))
render_field_grid("EventSentry", "🖥️", [
    ("Agent Present", "Not Applicable" if is_personal else ("✅" if device_row.get("EventSentry_AgentPresent") else "❌")),
    ("Agent Version", device_row.get("EventSentry_AgentVersion")),
    ("Stale", "Not Applicable" if is_personal else ("⚠ Yes" if device_row.get("EventSentry_Stale") else "✅ No")),
    ("Inventory Timestamp", device_row.get("EventSentry_InventoryTimestamp")),
    ("Manufacturer", device_row.get("EventSentry_Manufacturer")),
    ("Model", device_row.get("EventSentry_Model")),
])

st.markdown("#### Notes")
existing_note = device_row.get("note") or ""
existing_status = device_row.get("NoteStatus") or "New"

note_text = st.text_area("Notes for this device", value=existing_note, key=f"note_{selected_device}")
note_status = st.selectbox("Status", ["New", "Acknowledged", "Resolved"],
                            index=["New", "Acknowledged", "Resolved"].index(existing_status), key=f"status_{selected_device}")

bcol1, bcol2 = st.columns(2)
if bcol1.button("Save Notes", key=f"save_{selected_device}"):
    dkey = device_key_for_row(device_row)
    editor_name = st.session_state.get("your_name", "").strip() or "Dashboard User"
    save_note(dkey, selected_device, note_text, note_status, updated_by=editor_name)
    load_devices.clear()
    st.success("Saved.")
    st.rerun()

if bcol2.button("Delete Notes", key=f"delete_{selected_device}"):
    dkey = device_key_for_row(device_row)
    editor_name = st.session_state.get("your_name", "").strip() or "Dashboard User"
    save_note(dkey, selected_device, "", "New", updated_by=editor_name)
    load_devices.clear()
    st.success("Notes cleared.")
    st.rerun()

if existing_status != "New" or existing_note:
    last_updated_display = format_datetime_display(device_row.get("NoteUpdatedAt")) or "unknown"
    st.caption(f"Last updated: {last_updated_display} by {device_row.get('updated_by') or 'unknown'}")

with st.expander("Raw Source Data"):
    st.write({k: v for k, v in device_row.to_dict().items() if pd.notna(v) and v != ""})
