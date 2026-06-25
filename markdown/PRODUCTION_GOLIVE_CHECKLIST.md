# Production Go-Live Checklist — DeviceScope Dashboard

This assumes production already has a **working prior deployment** (NSSM service, gMSA-based Key Vault cert auth, Scheduled Task) — this is a **code update**, not a from-scratch first install. A few items below differ if that assumption is wrong; flagged where relevant.

---

## Part A — Get the code from dev into GitHub

1. From `C:\Apps-Dev\device-scope-dashboard-v2`, confirm this is a git repo with a remote pointed at your GitHub repo (`git remote -v`). Initialize/add the remote if not.
2. **Double-check `.gitignore` before committing anything**, specifically that these are *not* tracked:
   - `config.json` — contains per-environment paths/secrets; production needs its **own** copy, never a copy of dev's.
   - `data/devicescope.db` — the live database. If this were ever accidentally committed and later pulled on production, it would silently overwrite production's real device notes and history with dev's test data. Verify it's gitignored *now*, before your first push.
   - `.venv/`, `__pycache__/`, `.pytest_cache/`, `logs/*.log` — already confirmed gitignored in an earlier review of this project; just a sanity check.
3. Commit and push: `git add -A`, commit with a clear message, push to `main` (or your release branch). Tag the commit if you want a clean rollback point (e.g. `git tag v2.1-prod-golive`).

---

## Part B — What does NOT come from GitHub (must be created/updated on production separately)

`git pull` will never touch these — each needs manual attention on the production server itself:

| File | What to do |
|---|---|
| `config.json` | Production needs its own copy with its own `SqliteDbPath`, plus the **new `ITStaffNames` key** (added this session for the Your Name gate). Until this key exists, the gate will show the obvious placeholder text instead of real names — not broken, just unfinished until you add it. |
| `.streamlit/config.toml` | **This needs real edits, not just a copy of what's there today** — see Part E, this is tied directly to the IIS cutover. |
| `data/devicescope.db` | Production's existing database — **do not touch, do not replace.** New `02_views.sql` logic gets applied to it automatically the next time the pipeline runs (see Part D) — raw tables are untouched either way. |
| `logs/` | Fine to let regenerate; not a blocker. |

---

## Part C — Software prerequisites on production

Since this is assumed to be an existing deployment, most of this should already be in place — treat this as a verification pass, not a fresh install, unless something's actually missing:

- **Python** — same version as dev (per `PYTHON_3_14_INSTALLATION_GUIDE.md`). Production needs its **own** fresh virtual environment; venvs aren't portable between machines, and `.venv/` was never in git anyway.
  ```powershell
  python -m venv .venv
  .venv\Scripts\Activate.ps1
  pip install -r requirements.txt --break-system-packages
  pip install -r packages.txt --break-system-packages
  ```
- **PowerShell modules** — at minimum `PSSQLite` (required for *any* view refresh to work at all — the pipeline will fail immediately without it). Also whatever your collectors depend on for AD, Graph/Entra, KACE/Sophos API calls, and EventSentry's Postgres connection. Run `Get-Module -ListAvailable` to check, or just run the pipeline once manually and watch for "module not found" errors per collector.
- **Git** itself, plus a non-interactive auth method for pulling from GitHub on a server (a deploy key or a fine-grained, read-only PAT scoped to just this repo — not a personal account's interactive login).

---

## Part D — The actual pull and cutover sequence

1. **Stop the Streamlit NSSM service first**, before pulling new code — Python can hold file handles open on Windows, and you don't want a partially-updated `streamlit_app.py` running mid-pull.
   ```powershell
   Stop-Service <your-nssm-service-name>
   ```
2. **Back up the current production database** before doing anything else. Cheap insurance given how much `02_views.sql` logic changed this session.
   ```powershell
   Copy-Item data\devicescope.db data\devicescope.db.bak-$(Get-Date -Format yyyyMMdd)
   ```
3. Pull the new code: `git pull` (or `git clone` if this is genuinely the first deployment to this path).
4. Update `config.json` and `config.toml` per Parts B and E.
5. **Run the pipeline once manually**, *before* restarting the web UI — this re-applies `02_views.sql` (DROP+CREATE VIEW, raw tables untouched) so `DeviceHealth`, `PatchStatus`, `DeviceType`, etc. all reflect this session's logic immediately, rather than waiting for the next scheduled cycle.
   ```powershell
   .\Invoke-DeviceScopePipeline.ps1
   ```
   Confirm all 6 collectors + `EventSentryPatches` report `Success` before moving on.
6. Restart the Streamlit service.
   ```powershell
   Start-Service <your-nssm-service-name>
   ```

---

## Part E — Sequencing with the IIS reverse proxy cutover

**Don't do this piecemeal — it creates a real outage window if done out of order.** The `config.toml` changes from the IIS guide (remove `sslCertFile`/`sslKeyFile`, bind to `127.0.0.1`) and the IIS setup itself need to land together:

1. Finish the **entire** IIS reverse proxy setup first (cert installed, site created, ARR proxy enabled, rewrite rule in place) — but don't touch Streamlit's `config.toml` yet. Leave Streamlit on its current working setup for now.
2. Once IIS is fully configured, make the `config.toml` change (remove SSL settings, bind to `127.0.0.1`) **and** restart the Streamlit service **in the same maintenance window** as verifying IIS reaches it successfully.
3. Test `https://<your-fqdn>/` end-to-end — including clicking something interactive to confirm the WebSocket connection survives the proxy (see the IIS guide's testing section).
4. Only after that's confirmed working, communicate the new URL to staff and let the old direct `:8501` access habit die off naturally (it'll stop working anyway once Streamlit is bound to `127.0.0.1`).

If you'd rather not bundle this with the code update at all, that's completely reasonable — do the application code deployment (Parts A–D) on its own first, confirm it's healthy, and tackle the IIS cutover as a separate maintenance window later. Don't feel pressured to do both at once just because they're both "infrastructure work."

---

## Part F — Post-deploy validation checklist

- [ ] All 6 collectors + `EventSentryPatches` show `Success` in `source_run_log` after a manual pipeline run.
- [ ] Streamlit service starts cleanly, dashboard loads.
- [ ] **Click "Refresh Device Data" via the actual web UI, not just the manual PowerShell run.** This specifically tests the `powershell.exe` (PS 5.1) invocation path used by the button — confirm production doesn't have the same `??` operator / `Get-Content` encoding issues found and fixed on dev this session, since the Scheduled Task and the web button may not share the same PowerShell execution context historically.
- [ ] Your Name gate shows the real staff roster, not the `"(Add real names...)"` placeholder — confirms `ITStaffNames` was added to production's `config.json` correctly.
- [ ] A test note save round-trips correctly (save via Data table, confirm it appears with correct attribution and timestamp, no lag).
- [ ] If doing the IIS cutover in this same window: `https://<fqdn>/` loads and stays interactive after the page loads (WebSocket check).
- [ ] Update `PROJECT_REFERENCE.md`'s "Last updated" date and note the go-live, for your own future reference.