# Git / GitHub Cleanup Reference — DeviceScope Dashboard

**Date:** 2026-06-25
**Purpose:** A standalone, copy-pasteable record of the git/GitHub commands worked through during the repository cleanup, the `feature/re-engineer-with-database` push, and the subsequent production cutover pull. Companion to `PROJECT_REFERENCE.md` §7b/§7c, which explain *why* each of these was needed. Useful as a template if this class of problem (per-environment files committed before being gitignored, core files never added, or a downstream server still carrying old tracked copies) comes up again.

---

## 1. Diagnosing what's actually changed before staging anything

```powershell
git status
git branch --show-current
git diff                    # review unstaged changes before adding
git diff --cached           # review staged changes before committing
```

Always run `git status`/`git diff` *before* `git add -A` or similar — several of the issues below were caught only because the diff was reviewed first instead of staged blindly.

---

## 2. Confirming a file was never committed (the "scary one" check)

Before trusting that a sensitive-looking file (e.g. a live database) is safe, confirm it never made it into history at all:

```powershell
git log --all --oneline -- data/devicescope.db
```
No output = never committed. Any output = it's in history and needs a different conversation (untrack + possibly history rewrite).

---

## 3. Confirming a file isn't being silently gitignored vs. just never added

```powershell
git check-ignore -v collectors/Get-ADDevices.ps1
git check-ignore -v sql/01_schema.sql
```
No output = nothing is ignoring it; if it's untracked, it was simply never `git add`-ed.

---

## 4. Untracking files that were committed before `.gitignore` rules existed

`.gitignore` only affects *future* commits — it cannot retroactively untrack something already in the repo. `git rm --cached` removes a file from git's tracking **without touching the file on disk**:

```powershell
git rm --cached "config.json"
git rm --cached ".streamlit/config.toml"
git rm --cached "Archive - Project Files/sharepoint.config"
git rm --cached "__pycache__/streamlit_app.cpython-313.pyc"
git rm --cached "__pycache__/test_streamlit_app.cpython-313-pytest-9.0.1.pyc"
git rm --cached "logs/DeviceScope_Upload.log"
git rm --cached "logs/streamlit_debug.log"
git rm --cached "logs/test_output.log"
git rm --cached "data/old/DeviceScope_Merged.csv"
git rm --cached "data/old/DeviceScope_Merged_DuplicateHandlingAndColumnCorrections.csv"
```

To untrack an entire folder at once:
```powershell
git rm -r --cached "Archive - Project Files"
```

---

## 5. Closing the actual `.gitignore` gaps

```powershell
Add-Content .gitignore "`n# Per-environment / sensitive (added during cleanup)"
Add-Content .gitignore ".streamlit/config.toml"
Add-Content .gitignore "data/devicescope.db"
Add-Content .gitignore "data/old/"
Add-Content .gitignore "sharepoint.config"
```

Note: `data/*.csv` does **not** recurse into `data/old/*.csv` — glob patterns in `.gitignore` need the subdirectory spelled out explicitly if the existing rule doesn't cover it.

---

## 6. Staging deliberately, not all at once

```powershell
git add collectors/ sql/ Invoke-DeviceScopePipeline.ps1
git status                  # confirm exactly what landed before committing
```

To back out a staged file before committing (doesn't touch the working copy):
```powershell
git restore --staged <path>
```

---

## 7. The actual commit sequence used (4 separate, deliberate commits)

Splitting unrelated changes into separate commits, rather than one `git add -A && git commit`, keeps history reviewable and rollback-able:

```powershell
# Commit 1 — gitignore / untracking cleanup
git add .gitignore
git commit -m "Untrack per-environment configs, stale cached files, and dead SharePoint archive; close gitignore gaps"

# Commit 2 — application code
git add streamlit_app.py style.css
git commit -m "Migrate dashboard to SQLite-backed data layer; restore overview sections, notes, trend deltas; fix stale CSS selectors"

# Commit 3 — core files that had never been added to git at all
git add Invoke-DeviceScopePipeline.ps1 collectors/ sql/
git commit -m "Add pipeline orchestrator, collectors, and SQL schema/views"

# Commit 4 — markdown reorganization (move into archive folder)
git add markdown/
git commit -m "Archive stale point-in-time dev session summaries; add IIS, NSSM, go-live, and project reference docs"
```

---

## 8. Final check before pushing

```powershell
git status     # must show "nothing to commit, working tree clean"
git log --oneline -5
```

---

## 9. Push and open the PR

```powershell
git push origin feature/re-engineer-with-database
```
GitHub returns a direct PR-creation URL in the push output — no separate command needed to start the PR.

---

## 10. PowerShell version gotcha hit along the way

`&&` as a command separator requires PowerShell 7+ (`pwsh`). Under Windows PowerShell 5.1, use a semicolon or separate lines instead:
```powershell
git add <path>; git status
# or just:
git add <path>
git status
```
Worth remembering this is a *different* PowerShell instance than the one NSSM/the Refresh button invokes (`powershell.exe` = 5.1) — confirming which shell you're typing into matters before assuming `&&` will or won't work.

---

## 11. Deferred: scrubbing old commits from history entirely

`git rm --cached` does not remove a file's content from *past* commits — only `git filter-repo` (the current recommended tool over the older `filter-branch`/BFG) rewrites history itself:

```powershell
# Run from a FRESH CLONE, never your active working copy —
# every commit hash repo-wide changes after this
git clone https://github.com/<org>/<repo>.git repo-cleanup
cd repo-cleanup
git filter-repo --path config.json --path "Archive - Project Files/sharepoint.config" --invert-paths
git push --force          # requires re-cloning or hard-reset on every other clone afterward
```

**Not run this session** — judged not urgent given no live secrets and an already-dead SharePoint link, but documented here for when/if it's revisited. See `PROJECT_REFERENCE.md` §7b for the reasoning.

A spot-check of `config.json`'s tracked history (`git log -p -- config.json | findstr /i "password key secret token"`) confirmed the matches are Key Vault *secret names* and DPAPI *filenames* — lookup references, not actual credential values. Slightly more informed than the original "no live secrets" read, but the same conclusion either way: no rotation-worthy material, just internal naming-convention disclosure if this is ever scrubbed.

---

## 12. Confirming whether a given commit has reached a particular branch/server (added 2026-06-25)

Before assuming an untracking fix (or any commit) has propagated everywhere, check it directly on the branch/checkout in question rather than inferring from where it was originally made:

```powershell
git log --oneline -- config.json
git log --oneline -- .streamlit/config.toml
git log --oneline origin/dev -- config.json    # same check against a remote branch ref
```

This is what confirmed the untracking commit (`9e6d7ec`) existed on `dev` but had **not yet reached `main`** — i.e., production's next pull would be the first time that commit's effects applied there, which is exactly the scenario in §13 below.

---

## 13. Pulling an untracking commit onto a server with locally-modified tracked copies (added 2026-06-25)

This is the production-specific sequence: a server whose `main` branch predates an untracking commit (§4/§5 above), and which has its own live, locally-modified values in the files being untracked. A plain `git pull` will correctly refuse rather than silently overwrite:

```powershell
git pull origin main
```
```
error: Your local changes to the following files would be overwritten by merge:
        .streamlit/config.toml
        config.json
Please commit your changes or stash them before you merge.
Aborting
```

**Do not run `git rm --cached` again here** — that decision was already made and committed upstream (§4); this server just needs to *receive* it. The correct sequence:

```powershell
# 1. Back up the real, live values OUTSIDE git's reach first
copy config.json config.json.keep
copy .streamlit\config.toml .streamlit\config.toml.keep

# 2. Discard local modifications so the merge has nothing to conflict with
git checkout -- config.json .streamlit/config.toml

# 3. Pull — the untracking commit now applies cleanly
git pull origin main

# 4. Restore the real values (files are now untracked + gitignored,
#    so this will never show up in git status again)
copy config.json.keep config.json
copy .streamlit\config.toml.keep .streamlit\config.toml

# 5. Confirm clean — neither file should appear at all
git status

# 6. Clean up the temp copies once confirmed
Remove-Item config.json.keep, .streamlit\config.toml.keep
```

**A transient Windows file-lock can interrupt step 3** if a stale tracked `__pycache__/*.pyc` is being removed as part of the same merge and something (a running Python process, AV scan) has it open:
```
Unlink of file '__pycache__/streamlit_app.cpython-313.pyc' failed. Should I try again? (y/n)
```
Answering `y` once was sufficient in this case; if it loops, check for a running process holding the file first (`Get-Process python, streamlit`) rather than retrying indefinitely.

---

## 14. PowerShell module scope — install location must match the *running* identity (added 2026-06-25)

Not a git command, but caught during this same production session and worth keeping alongside the rest of this reference since it's the same root-cause pattern as the per-environment file issues above: **what's installed/visible depends entirely on which identity is asking.**

```powershell
# This only makes the module visible to the CURRENT interactive user:
Install-Module PSSQLite -Scope CurrentUser -Force
```
An NSSM-run service (a different account) won't see it, and will fail with:
```
Import-Module : The specified module 'PSSQLite' was not loaded because no valid module file was found...
FullyQualifiedErrorId : Modules_ModuleNotFound,...
```

Fix — install for all users (requires an elevated session), then restart the service so it picks up the new module path rather than a stale snapshot:
```powershell
Install-Module PSSQLite -Scope AllUsers -Force
nssm restart <serviceName>
```

To confirm scope after the fact:
```powershell
Get-Module PSSQLite -ListAvailable | Select-Object Name, Path
```
A path under `C:\Program Files\WindowsPowerShell\Modules` confirms `AllUsers` scope landed correctly.
