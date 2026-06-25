# DeviceScope Dashboard — Project Reference

**Last updated:** 2026-06-25
**Purpose of this document:** a single, current reference for the DeviceScope dashboard's architecture and the full set of changes made since the CSV→SQLite migration. The other files in `markdown/` (CLEANUP_ANALYSIS.md, ENHANCEMENTS.md, FINAL_REPORT.md, etc.) are point-in-time development snapshots and are likely stale relative to this document — treat this one as the source of truth going forward, and update it as the project continues to evolve.

---

## 1. What this project is

A Streamlit dashboard (`streamlit_app.py`) that gives IT staff a unified, cross-referenced view of every device across six systems of record:

- **Entra ID** (Azure AD) — device identity, join type, compliance
- **Intune** — MDM enrollment, compliance state, management agent
- **Active Directory** — on-prem computer objects, OU/location, last logon
- **Sophos** — endpoint protection health, IP, device type
- **KACE** — hardware inventory, IP, RAM, location
- **EventSentry** — agent inventory, patch/update history, hardware specs

It replaced an earlier CSV-based pipeline (`AllDeviceExports_Merge.ps1` → timestamped CSV exports → `streamlit_app_beforeDB.py`) with a SQLite-backed architecture: per-source PowerShell collectors write raw tables, and **all normalization, health derivation, and business logic lives in SQL views** — Streamlit and PowerShell never re-derive these fields themselves. This is the single most important architectural principle in the codebase; it was not always perfectly followed in this session, and a few mismatches are noted below.

---

## 2. Architecture

```
device-scope-dashboard-v2/
├── config.json                       # per-environment paths/secrets (gitignored)
├── streamlit_app.py                  # the dashboard itself
├── streamlit_app_beforeDB.py         # pre-migration reference copy — keep for now,
│                                       # has repeatedly been useful for recovering
│                                       # functionality dropped during the rewrite
├── Invoke-DeviceScopePipeline.ps1    # orchestrator: runs all collectors + refreshes views
├── requirements.txt / packages.txt
├── style.css
├── collectors/
│   ├── DeviceScope.Common.psm1       # shared helpers, DB init, run logging
│   ├── Get-EntraDevices.ps1
│   ├── Get-IntuneDevices.ps1
│   ├── Get-ADDevices.ps1
│   ├── Get-SophosDevices.ps1
│   ├── Get-KACEDevices.ps1
│   └── Get-EventSentryDevices.ps1    # also pulls Windows update install history
├── sql/
│   ├── 01_schema.sql                  # raw tables, device_notes, source_run_log —
│   │                                   # DO NOT re-run against a live DB (wipes data)
│   └── 02_views.sql                   # ALL normalization logic — safe to re-run
│                                       # anytime (views only, drops/recreates)
├── scripts/
│   ├── AllDeviceExports_Merge.ps1     # legacy pre-SQLite merge script — source of
│   │                                   # several restored features (see §6)
│   ├── Initialize-DpapiSecrets.ps1
│   └── test-keyvault-auth.ps1
├── data/
│   └── devicescope.db                 # the live SQLite database
├── images/                            # logo assets
├── logs/
└── markdown/                          # documentation, including this file
```

**Pipeline flow:** `Invoke-DeviceScopePipeline.ps1` runs each collector (writing to its own raw table, independent of the others' success/failure), logs each run to `source_run_log`, then re-applies `02_views.sql`. The Streamlit "🔄 Refresh Device Data" button triggers this same script via `subprocess`. On first run against a path with no DB file present, it instead calls `Initialize-DeviceScopeDb` to run the full `01_schema.sql` (tables + views) — this is expected, normal behavior the first time a fresh environment (a new dev checkout, or production after the §7c cutover) is pointed at a `data/` folder with nothing in it yet, not an error condition.

**Deployment:** Streamlit runs via NSSM as a Windows service, bound to `0.0.0.0:8501`. As of 2026-06-23, production sits behind an **IIS reverse proxy** terminating HTTPS at `https://devicedashboard.image.local/` (see §7a for the full setup and a regression risk to watch for). Direct `:8501` access still works during the transition period. **Still no authentication at any layer** — IIS proxies the request through, it doesn't gate it — so anyone with network access can use the dashboard. This was an accepted tradeoff for an internal LAN tool; Windows Integrated Auth via IIS is sketched as a design (not yet implemented) in §9.

---

## 3. Database schema (`01_schema.sql`)

Raw tables, one per source: `entra_raw`, `intune_raw`, `ad_raw`, `sophos_raw`, `kace_raw`, `eventsentry_raw`, plus `eventsentry_patches_raw` (one row per installed Microsoft update per device). Each row carries `pulled_at` and `source_run_id`; only the most recent successful pull per source is used (via `v_<source>_latest` views).

Also in this file: `source_run_log` (per-source success/failure/row-count per pipeline run, powers the freshness banner) and `device_notes` (persistent user notes/status, keyed on `AD_ObjectGUID` when available, else `NAME:<name_key>` — never touched by the daily import).

**Not in this file, created lazily by Streamlit itself:** `metric_snapshots` — a daily snapshot of fleet-wide totals (always computed from the *unfiltered* dataset) used to drive the "vs. yesterday" trend deltas. It lives outside the schema/views lifecycle deliberately, since it's dashboard presentation state, not raw device data.

**Monitoring collector health day-to-day** — three places to look, in order of usefulness:
1. **`source_run_log` table** — the authoritative, queryable record (per-source status/row-count/error per run); this is what powers the freshness banner in the app, so it's the right first stop for "did last night's pull work?" Query via `sqlite3`, Python's built-in `sqlite3` module, or PowerShell's `PSSQLite` module (see the `-Scope AllUsers` note in §7c if `Invoke-SqliteQuery` reports the module isn't found when called from the NSSM service context):
   ```powershell
   sqlite3 data\devicescope.db "SELECT source_name, status, row_count, error_message, started_at, completed_at FROM source_run_log ORDER BY started_at DESC LIMIT 20;"
   ```
2. **Live console output** — if running `Invoke-DeviceScopePipeline.ps1` manually/interactively, `Write-Output` streams the same per-source detail (secret-resolution source, rows written, final summary) straight to the terminal in real time.
3. **`logs\streamlit_stdout.log` / `logs\streamlit_stderr.log`** — the NSSM service's own stdout/stderr, separate from the pipeline's own logging. This is where to look when the *app* misbehaves rather than the *pipeline* — e.g. the Refresh button's `subprocess` call failing before the pipeline's own `Write-Output` lines would even appear (see the PSSQLite scope issue in §7c for a real example of this).

---

## 4. SQL views (`02_views.sql`) — the business-logic layer

### 4.1 Aggregation views
`v_<source>_agg` views collapse multiple raw rows per device into one row per `name_key`, computing instance counts and duplicate-relevant breakdowns (e.g. `entra_hybrid_count`, `entra_registered_count`, `entra_hybrid_device_ids` for the AD-GUID comparison below).

### 4.2 `v_devices_unified` — key derived columns

| Column | Logic |
|---|---|
| `IsPersonalDevice` | Entra-only with nothing else, **or** Entra+Intune where the OS string contains Android/iOS/iPhone/iPad — catches BYOD phones that are MDM-enrolled but still personal |
| `IsCorporateDevice` | Present in AD, Intune, Sophos, **or** KACE (deliberately *not* triggered by Entra or EventSentry alone) |
| `BranchLocation` | Physical location derived from **KACE's IP address only** (no Sophos fallback — matches the original `SUBNET_TO_BRANCH` logic), via a 30-entry subnet `CASE`/`LIKE` chain. `NULL` if no IP, `'Unknown'` if IP present but unmatched. This is intentionally separate from the AD-OU/KACE-location field (which still exists but isn't surfaced in the app) — IP subnet is the only reliable source of truth for *physical* location |
| `DeviceType` | Priority cascade ported from the old `Get-DeviceType` in `AllDeviceExports_Merge.ps1`: **Virtual Machine** (EventSentry `is_vm`) → **Server** (AD OS string, Sophos device_type, or EventSentry product_type) → **Laptop** (EventSentry chassis_type, or `LAPTOP-` hostname prefix fallback) → **Desktop** (chassis_type) → **Mobile/Personal** (mobile OS string match, *or* Entra-registered + isolated from every other source — these two conditions were originally separate "Mobile" and "Mobile/Personal" outcomes; merged into one, since the OS-string check almost always fired first and made the second condition nearly unreachable) → **Desktop** (Windows OS-string fallback) → **Unknown** |
| `Entra_JoinType` | `COALESCE(join_type, trust_type)` — fixes hybrid-joined **server** objects, which Microsoft Graph often leaves `join_type` blank for while populating `trust_type` (e.g. `'ServerAd'`) instead |
| `Entra_HybridIdMatchesAD` / `Entra_HybridIdMismatchExists` | For hybrid-joined devices, Entra's `DeviceId` is expected to equal the on-prem AD object's `ObjectGUID`. These two flags automate that comparison (not mutually exclusive — a device with two distinct hybrid Entra IDs, one matching and one not, shows both as true) |
| `Memory` | Whole-number GB. Source priority is **KACE first, EventSentry second** (deliberately reversed from the original PowerShell script's EventSentry-first priority, because EventSentry's agent has proven unreliable in this environment). `CAST(text AS REAL)` handles both raw formats (`"16384 Bytes"` from KACE — mislabeled, it's actually MB — and plain `"16131"` from EventSentry) without manual string parsing |
| `EventSentry_Stale` / `EventSentry_AgeDays` | Based on `inventory_timestamp_iso` (converted from EventSentry's `MM/DD/YYYY HH:MM:SS` text). Stale if agent present but >7 days old, or if the timestamp is missing/unparseable. `AgeDays` rounds to a whole number |
| `PatchStatus` / `DaysSinceLastPatch` | Current (≤30 days) / Behind (31-60) / Critical (60+) / Unknown (no install date at all), based on the most recent Microsoft-published update install date. **Cumulative Update and Security Update title-based breakouts were both attempted and removed** — see §6 |

### 4.3 `v_devices_health` — anomaly + status derivation

| Column | Logic |
|---|---|
| `IsEventSentryOnly` | In EventSentry but in **no** other source at all → triggers `🧹 Removal Needed` status. EventSentry is corporate-only; a device with no footprint anywhere else has almost certainly been decommissioned without being cleaned out of EventSentry |
| `EventSentry_StubRecordOnly` | In EventSentry (`InEventSentry=1`) but `agent_version` is null → triggers `ℹ️ Informational` status, **not** Critical. Root cause: EventSentry's `eseventlogcomputer` table (passive event-log discovery) can have a row with no matching `essysinfo` row (real agent inventory) — these devices exist in EventSentry's database but never show up in its Management Console/Web Reports |
| `Anomaly_ES_MissingWhileActive` | Corporate, non-personal, no agent, **and no EventSentry record at all** (excludes the stub-record case above, which gets its own status) → `🚨 Critical` |
| `Anomaly_ES_StaleWhileActive` | Corporate, non-personal, agent present but stale → `⚠ Warning`. No longer requires presence in Intune/Entra/AD (that gate used to mean KACE-only devices like loaner laptops could never trigger this) |
| `DeviceHealth` priority order | `🧹 Removal Needed` → `ℹ️ Informational` → `🚨 Critical` → `⚠ Warning` (stale agent, duplicate instances, or bad Sophos health) → `✅ Healthy` |
| `HealthReason` | Human-readable explanation, built as `"; "`-joined fragments with the leading separator trimmed |

### 4.4 `v_devices_final`
The consumer-facing view — `v_devices_health` joined with `device_notes`. This is the only view Streamlit queries for the Data table and Device Overview.

---

## 5. Streamlit app (`streamlit_app.py`) structure

### Sidebar
- **Your Name** — free-text field, persisted via `session_state`, used to attribute Notes/Status edits. Honor-system only (no authentication exists); defaults to `dashboard_user` if left blank.
- **🔍 Data Table Filters** (expander, defaults open) — Context, OS, Device Type, Branch, Duplicate Devices (dropdown, not radio — radio's `horizontal=True` still wraps in a narrow sidebar), Patch Status, "Only show problem devices."
- **📋 Columns** (expander, defaults **closed**) — the column picker; tucked away since it was the single largest contributor to sidebar scroll length (17 default columns rendering as wrapping chips).
- Device Overview device selector, then the footer.

### Main page
- **📊 Analytics** — `st.toggle`-driven section (not `st.expander` — expanders don't report their open/closed state back to the script at all, so a toggle is the only way to conditionally show/hide content based on it) wrapping Metrics, Problem Summary, Patch Management, and Charts. Defaults **off**, since the Data table is the actual day-to-day workflow, not this orientation view. A one-line teaser (`🚨 N problem devices · 🩹 N patch-critical · ⚠ N stale`) shows only while collapsed, computed from the same `filtered_df`.
- **Metrics / Problem Summary / Patch Management / Charts** are all **filter-reactive** — computed from `filtered_df`, matching whatever the Data table currently shows. The **daily snapshot** used for trend deltas is always computed from the unfiltered `df` regardless, to protect cross-day trend integrity; delta arrows are suppressed entirely whenever any filter is active, since comparing a filtered subset against yesterday's whole-fleet snapshot would be misleading.
- **Data table** — friendly column labels throughout (`FRIENDLY_COLUMN_LABELS` dict, with a generic fallback for anything not yet mapped), columns ordered by a fixed canonical list (not click order) so related groups like the AD GUID / Entra Device ID(s) / Intune Device ID trio always stay adjacent regardless of pick order. Datetime columns (`LastSeen`, `NoteUpdatedAt`) are parsed with `pd.to_datetime(..., format='mixed', utc=True).dt.tz_localize(None)` to handle genuinely mixed per-row formats across sources, then rendered via `DatetimeColumn` in 12-hour format. Notes/Status are editable inline; everything else is read-only.
- **Device Overview** — Overview and Health & Patch sections kept as larger `st.metric()` cards (intentional — these are the headline numbers worth visual emphasis). Presence, Duplicates, Identity, Compliance, Network, and EventSentry all use `render_field_grid()` — a compact label-above/bold-value-below layout (`st.caption()` + Markdown bold + `st.divider()`, no `unsafe_allow_html`) that replicates the original CSV-app's HTML layout natively.
- **🔄 Refresh Device Data** — runs the pipeline via `subprocess`. On failure, surfaces the actual captured `stdout`/`stderr`, not just the generic `CalledProcessError` summary (which only ever says "exited with status 1" and nothing else). This surfaced behavior is what made the PSSQLite module-scope issue in §7c diagnosable in the first place — the raw stderr showed the exact `Modules_ModuleNotFound` exception rather than a generic failure.

---

## 6. Notable fixes and decisions this session

**Restored functionality that was silently dropped during the CSV→SQLite rewrite** (none of this was logged anywhere before — each one was found by inspecting `streamlit_app_beforeDB.py` and `AllDeviceExports_Merge.ps1` against user reports of "this used to show X"):
- `HealthReason` column, the Identity/Compliance/Network/EventSentry detail sections, DB-path config-driven resolution, the patch-status lexicographic-sort date bug (all logged in the original handoff doc, pre-dating this session)
- The "Advanced Context Analysis" legacy charts (context-overlap heatmap + device-association donut)
- `DeviceType`, `BranchLocation`, `Entra_HybridIdMatchesAD`/`MismatchExists`, Identity's "Intune Entra Device ID" field, instance-count and duplicate-flag columns in the Data table picker

**Bugs found and fixed:**
- `eventsentry_patches_raw.install_date` and `eventsentry_raw.inventory_timestamp` arrive as `MM/DD/YYYY HH:MM:SS` text — `MAX()` was sorting lexicographically and `julianday()` couldn't parse the format at all, silently breaking `PatchStatus` and `EventSentry_Stale` for everyone
- Data table: clearing the sidebar column picker fell back to the **entire unfiltered raw view** (70+ columns) with nothing disabled, making every column editable — both bugs traced to the same empty-list-is-falsy logic error
- `Get-Content` in both `Invoke-DeviceScopePipeline.ps1` and `DeviceScope_Common.psm1` was missing `-Encoding UTF8` — under Windows PowerShell 5.1 (which `powershell.exe` invokes, as opposed to `pwsh.exe` for PS7+), this defaults to the system ANSI codepage, corrupting every emoji in `DeviceHealth`/`HealthReason` into mojibake (`✅` → `âœ…`) on read
- `Invoke-DeviceScopePipeline.ps1` used the `??` null-coalescing operator, which is PowerShell 7.0+ only — caused a hard parser error under PS 5.1 (the Refresh button's invocation), blocking the *entire* script from running at all, which is also why the encoding bug above wasn't noticed until this was fixed
- `pd.to_datetime()` without `format='mixed'` only successfully parses whichever format matches the *first* valid value in a column, silently returning `NaT` for every differently-formatted row — caught while implementing 12-hour timestamp display, since `LastSeen` genuinely mixes formats across its 4 source systems

**Deliberately attempted and abandoned:**
- **Cumulative Update / Security Update title-based tracking** — `eventsentry_patches_raw.security_update` (despite the column name) holds the update title text, but confirmed against real data that it's sourced from a QFE/`Get-HotFix`-style inventory, not the rich Windows Update Catalog. Titles never contain "Cumulative," and "Security Update (KBxxxxx)" is itself a legacy ~2016-era Windows convention unreliable for the modern fleet. `PatchStatus` (no title filtering at all) is the one trustworthy signal and is what remains.
- **WSUS as a 7th data source** — technically would solve the above (WSUS's `SUSDB` has real classification/title data), but pointing the fleet at the existing unmanaged WSUS server would require new GPO changes and ongoing patch-approval maintenance the team doesn't want to take on. Declined.
- **Automatic AD-based note attribution** — no real authentication exists (single shared server, no SSO/reverse-proxy layer), so there's no way to know who's editing a note without either a manual name field (implemented) or real infrastructure work (IIS + Windows Integrated Auth + an AD lookup — a legitimate but separate future project, not pursued here). **Update 2026-06-25: this is no longer purely future work — production is now live behind the IIS reverse proxy (§7c), which is the actual prerequisite this item was waiting on. The design itself has been sketched in detail (§9) and is the next active thread, started in a separate chat to keep this one focused on the production cutover.**
- **Key Vault cert-based auth on the dev/test box** — production's cert-based auth is tied to a gMSA scoped specifically to the production server's Scheduled Task identity. Setting up the equivalent on dev would require either loosening the gMSA's authorized-host list or provisioning a separate dev-only identity. Declined: the DPAPI fallback already covers dev/test, and production's existing path is trusted to keep working independently.

---

## 7. Known limitations / accepted risk

- **No authentication at any layer.** The IIS reverse proxy (§7a) terminates TLS and proxies the connection through — it does not gate it. Anyone with the URL and network access can view device data and edit notes/status. Accepted for an internal LAN tool; Windows Integrated Auth design is sketched in §9 but not yet implemented.
- **Note/Status attribution is honor-system.** The "Your Name" field isn't verified against anything.
- **`PatchStatus` reflects "any Microsoft update installed recently," not specifically the monthly Cumulative Update** — see §6.
- **Dev vs. prod PowerShell version mismatch is a live risk.** The Refresh button hardcodes `powershell` (Windows PowerShell 5.1), not `pwsh`. Any future PS7+-only syntax added to the pipeline scripts will silently break under this invocation path — there's no automated check for this.
- **Dev/test box intentionally does not have Key Vault cert-based auth set up.** Production's cert-based auth is tied to a gMSA scoped to the production server's Scheduled Task identity (gMSAs are explicitly restricted to an authorized host list) — replicating that on a dev box would mean either loosening that authorization list or provisioning a separate identity just for dev, neither of which was judged worth it. The DPAPI fallback already covers dev/test adequately (confirmed working as designed via the `source_run_log` review on 2026-06-22, including a real instance of `SkippedUsedCache` triggering correctly when EventSentry had a transient hiccup). This was the last open item from the original project handoff's roadmap, and it's now closed by deliberate decision rather than oversight.
- **The NSSM service object is more fragile than its 6+ months of stable operation suggested.** During the IIS cutover (2026-06-23), repeatedly reconfiguring `AppStdout`/`AppStderr` on the existing service object left it unable to start at all, in a way that wasn't resolved by undoing the specific change that triggered it. The eventual fix was recreating the service from scratch, after first proving the app and the gMSA account were both fine via a one-shot Scheduled Task (bypassing NSSM entirely). See `NSSM_GMSA_TROUBLESHOOTING.md` for the full symptom-indexed reference — worth reading *before* touching `AppStdout`/`AppStderr` on this service again, not after.
- **PowerShell modules installed with `-Scope CurrentUser` are invisible to the NSSM service account.** See §7c — confirmed concretely with `PSSQLite`, but applies to any module installed this way going forward. The fix (`-Scope AllUsers`, elevated, then restart the service) is the same fragile-service-identity pattern as the row above; worth checking module scope first whenever a service-invoked script reports `Modules_ModuleNotFound` despite working fine when run interactively.

## 7a. Production deployment architecture (added 2026-06-23)

Production now runs behind an **IIS reverse proxy** (ARR + URL Rewrite) terminating HTTPS on port 443 using a wildcard cert from the internal AD CA, proxying to Streamlit on `localhost:8501` (plain HTTP — `sslCertFile`/`sslKeyFile` removed from `config.toml` once IIS took over TLS termination). Direct `:8501` access still works during the transition period but is expected to fall out of use naturally once `https://devicedashboard.image.local/` is the communicated URL. Full setup steps, the certificate reuse/conversion process, and the specific `config.toml`/CORS gotcha hit during cutover are in `IIS_REVERSE_PROXY_SETUP.md`.

**One regression risk specific to this setup, worth remembering if the NSSM service is ever recreated again:** `enableCORS = false` was originally only being set via an NSSM command-line flag, not in `config.toml` itself. If the service's launch arguments are ever rebuilt from scratch without that flag, CORS protection silently re-enables and the WebSocket handshake fails with a 403 — the exact failure mode that took the longest to diagnose during the original IIS setup. This has since been moved into `config.toml` directly so it can't be silently dropped this way again — confirm it's still there (`enableCORS = false` under `[server]`) if WebSocket connections start failing after any future service changes.

## 7b. Git/GitHub workflow and repository hygiene (added 2026-06-25)

**Branch workflow (the actual team-style flow now in use):** `feature/*` branches are developed and tested on the dev box, PR'd into `dev`, pulled locally to `dev` on the dev box for testing, then PR'd from `dev` into `main` and pulled on production. Production's `main` and the dev box's `feature`/`dev` branches are expected to diverge only in per-environment config files (see below) — application code should stay identical across them via this PR flow, not by hand-editing files on either server directly.

**Per-environment files were committed before `.gitignore` rules existed for them.** `.gitignore` cannot retroactively untrack a file already in a repo — adding a rule only stops *future* commits. This was caught when production's locally-modified `config.json` and `.streamlit/config.toml` showed as "modified" in `git status` instead of being invisible/untracked as intended. Fixed via `git rm --cached` (untracks going forward; does **not** touch the working file on disk) for:
- `config.json` — already gitignored, just never actually untracked after the rule was added
- `.streamlit/config.toml` — was missing from `.gitignore` entirely (not a tracking-order issue, a real gap) — added
- `data/devicescope.db` — confirmed via `git log --all -- data/devicescope.db` that it was **never** committed; added to `.gitignore` as a safety net regardless, since a future `git pull` overwriting the live production DB would be a serious incident
- `data/old/*.csv` — the existing `data/*.csv` glob doesn't recurse into subdirectories; added `data/old/` explicitly
- Stale-but-already-gitignored `__pycache__/*.pyc` and `logs/*.log` — untracked, no gitignore change needed

**`sharepoint.config` (found at `Archive - Project Files/sharepoint.config`) was tracked and contained a live SharePoint share link with an embedded sharing token** — not a password, but functionally a bearer credential for that folder. No rotation was needed: the SharePoint site it pointed to had already been deleted independently, so the link was already dead. Untracked and gitignored going forward.

**Core application files (`Invoke-DeviceScopePipeline.ps1`, `collectors/`, `sql/`) were never added to git on the `feature/re-engineer-with-database` branch at all** — confirmed via `git check-ignore -v` that nothing was silently excluding them; they had simply never been `git add`-ed. This was the most consequential finding of the cleanup pass: had this branch been merged without catching it, `dev`/`main` would have been missing the pipeline orchestrator, all six collectors, and the schema/views entirely. Added in their own commit.

**Open item, deliberately deferred:** old commits prior to the untracking fix still contain the full historical content of `config.json` and `sharepoint.config` (cert thumbprint, Key Vault name, tenant/client IDs, the now-dead SharePoint link). A check of `config.json`'s tracked history (`git log -p -- config.json`) confirmed the values present there are Key Vault *secret names* and DPAPI *filenames* (lookup references), not actual secret values — slightly better-informed than the original "no live secrets exposed" read, but the same practical conclusion: no live credential material, just internal naming-convention disclosure. `git rm --cached` does not remove any of this from history. A `git filter-repo` rewrite would scrub it, but rewrites every commit hash repo-wide, requires a force-push, and invalidates in-flight PRs/clones — judged not worth the disruption for what amounts to no live secrets in a repo whose actual visibility/access scope hasn't been re-confirmed as the reason for proceeding. Revisit if the repo's visibility ever changes, or before treating this as fully closed.

A full, copy-pasteable command reference for this cleanup pass lives in `markdown/GIT_CLEANUP_COMMANDS_REFERENCE.md`.

A file inventory taken during this session showed 12,431 files/folders under the project root — **98.1% (12,199) was `.venv`**, the Python virtual environment, fully regenerable via `pip install -r requirements.txt -r packages.txt` and already excluded in `.gitignore`. Also safe to clear (all already gitignored): `__pycache__/`, `.pytest_cache/`, `logs/*.log`, and the 15 leftover pre-SQLite `data/DeviceScope_Merged_*.csv` exports (`data/` and `data/old/`), now fully superseded by `devicescope.db`. `markdown/` has several point-in-time development summaries (`CLEANUP_ANALYSIS.md`, `CLEANUP_IMPLEMENTATION.md`, `CODE_CLEANUP_SUMMARY.md`, `BEFORE_AFTER_COMPARISON.md`, `ENHANCEMENTS.md`, `ENHANCEMENTS_COMPLETE.md`, `FINAL_AUTHENTICATION_SUMMARY.md`, `FINAL_REPORT.md`) that are likely stale and worth archiving now that this document exists.

## 7c. Dev→main production cutover and first-run gotchas (added 2026-06-25)

`feature/re-engineer-with-database` was merged through `dev` and PR'd from `dev` into `main`. Pulling that merge onto the **production** box (a different working directory than the dev box, with its own long-lived local config) surfaced two issues neither the dev-box cleanup pass nor a fresh clone would have caught — both are now closed, but the sequence is worth keeping as a reference for any future server that's still carrying pre-`9e6d7ec` tracked copies of these files.

**1. The untracking commit (`9e6d7ec`, §7b) reached production for the first time as part of this merge, while production's working copies of `config.json` and `.streamlit/config.toml` were locally modified (real, live values) relative to the old tracked baseline.** `git pull` correctly refused, rather than silently overwriting them:
```
error: Your local changes to the following files would be overwritten by merge:
        .streamlit/config.toml
        config.json
Please commit your changes or stash them before you merge.
```
Resolved by backing up both files outside the repo, then:
```powershell
git checkout -- config.json .streamlit/config.toml   # discard local mods, clears the way
git pull origin main                                  # untracking commit now applies cleanly
# restore real values from backup
copy config.json.keep config.json
copy .streamlit\config.toml.keep .streamlit\config.toml
git status   # should show neither file at all — confirms untracked + gitignored
```
This sequence is the correct playbook for any other clone/server still carrying tracked copies of these files from before `9e6d7ec`.

**2. The same pull hit a transient Windows file-lock on a stale tracked `__pycache__\*.pyc`:**
```
Unlink of file '__pycache__/streamlit_app.cpython-313.pyc' failed. Should I try again? (y/n)
```
Resolved by retrying once; did not block the merge. If this recurs, check for a running Python/Streamlit process holding the file open before retrying blindly.

**3. First production database initialization.** Production's `data/devicescope.db` did not exist after the merge (expected — it's gitignored and was never part of the repo). The app's own error message on first load is accurate and expected, not a bug:
```
No database found yet at: C:\apps\device-scope-dashboard-v2\data\devicescope.db
Run the pipeline once to initialize, or check config.json's SqliteDbPath if this looks like the wrong location.
```
Resolved by running `.\Invoke-DeviceScopePipeline.ps1` once manually from the production app directory — this calls `Initialize-DeviceScopeDb` (full `01_schema.sql` + `02_views.sql`) since no DB file is present, then runs all six collectors against live production credentials (Key Vault/gMSA path, not the dev-box DPAPI fallback).

**4. `PSSQLite` module scope mismatch — the most reusable lesson here.** Running the pipeline manually after `Install-Module PSSQLite -Scope CurrentUser` worked fine, and the manual DB initialization succeeded. But clicking "🔄 Refresh Device Data" in the running app failed:
```
Pipeline stderr:
Import-Module : The specified module 'PSSQLite' was not loaded because no valid module file was found...
FullyQualifiedErrorId : Modules_ModuleNotFound,...
```
Root cause: `-Scope CurrentUser` installs to the interactive admin's own profile path, which the NSSM service account (a different identity, per `DEPLOYMENT_GUIDE.md`'s `DOMAIN\svc-devicescope$`) does not see on its own `$PSModulePath`. Same category of issue as the gMSA/Key Vault host-authorization scoping already documented above (§7, "Dev/test box..." bullet) and the NSSM service fragility bullet — **whoever the process actually runs as determines what's visible to it**, and this needs to be checked explicitly any time a module/dependency is added post-deployment, not assumed from an interactive test alone.

Fixed via:
```powershell
Install-Module PSSQLite -Scope AllUsers -Force   # elevated session required
nssm restart <serviceName>                        # service may have a stale module-path snapshot
```
Confirmed resolved — Refresh Device Data button now succeeds end-to-end in production.

---

## 9. Possible future work (not started)

- **Real authentication (IIS + Windows Integrated Auth) for automatic, verified note attribution by AD Display Name — design sketched 2026-06-25, no code written yet. Now an actively in-progress thread (started in a separate chat 2026-06-25), since production is live behind IIS and the prerequisite infrastructure this item was blocked on now exists:**
  - IIS side: enable the Windows Authentication role service on the site, disable Anonymous Auth. ARR is a reverse proxy, so the authenticated Windows identity (`LOGON_USER` server variable) lives in IIS's pipeline only — it does **not** automatically reach the Streamlit process across the proxy boundary. Needs a URL Rewrite rule injecting `LOGON_USER` into a forwarded header (e.g. `X-Remote-User`), plus ARR's "Allow server variables to be rewritten" enabled for it.
  - Streamlit side: read the header via `st.context.headers` (confirm Streamlit version supports this), strip the `DOMAIN\` prefix, resolve sAMAccountName → Display Name via a small cached AD-lookup table (a lightweight 7th "collector" populating a new small table, rather than a live LDAP call on every page load — consistent with the "SQL views own all derivation" principle). If present and resolved, skip the manual "Your Name" gate entirely; if the header is missing (e.g. someone still on direct `:8501` access), fall back to today's honor-system gate rather than breaking the page — gives a clean migration path instead of a hard cutover.
  - Sequencing note: this depends on the current `feature/re-engineer-with-database` work already being deployed to production first — **this dependency is now satisfied (§7c)** — don't bundle the IIS auth config change with an unrelated code deploy in the same maintenance window.
- A KACE-only/EventSentry-only "removal needed" trend counter in Problem Summary, once devices in that state stabilize enough to be worth tracking separately from "missing agent"
- "Vs. yesterday" deltas are implemented for the headline metrics; nothing yet for longer trend windows (week-over-week, month-over-month)
- Charts tab has room to grow (Sankey diagram for source-overlap, treemap for patch-status-vs-health) — explicitly left as an open invitation in the Charts tab's own caption
- Decide on the `git filter-repo` history rewrite for `config.json`/`sharepoint.config` (see §7b) — deferred, not abandoned
