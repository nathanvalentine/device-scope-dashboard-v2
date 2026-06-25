# NSSM / gMSA Service Troubleshooting Reference — DeviceScope Dashboard

Built from a real incident (2026-06-22/23) where the `DeviceScopeDashboard` NSSM service stopped starting cleanly during IIS reverse-proxy setup. **The root cause turned out to be completely unrelated to IIS** — but the two got tangled together during live troubleshooting, costing significant time. This reference is organized by symptom, not chronologically, so the next person hitting one of these doesn't have to relive the whole investigation.

---

## First: get the actual error, don't guess

`Get-Service` showing `Running` does **not** mean the app is actually listening — NSSM can keep a wrapper "Running" while the wrapped process crash-loops underneath it. Always confirm with both:

```powershell
Get-Service DeviceScopeDashboard
netstat -ano | findstr :8501
```

If `Running` but nothing is `LISTENING`, get the *real* error from the Windows Event Log — this is more reliable than NSSM's own log files, especially when the process fails before logging even initializes:

```powershell
Get-WinEvent -LogName Application -MaxEvents 20 | Where-Object {$_.ProviderName -eq "nssm"} | Format-Table TimeCreated, Message -Wrap
Get-WinEvent -LogName System -MaxEvents 20 | Where-Object {$_.TimeCreated -gt (Get-Date).AddMinutes(-10)} | Format-Table TimeCreated, Id, Message -Wrap
```

If you want NSSM's own stdout/stderr captured going forward (see the caveat on this below before relying on it):

```powershell
nssm set DeviceScopeDashboard AppStdout C:\apps\device-scope-dashboard-v2\logs\stdout.log
nssm set DeviceScopeDashboard AppStderr C:\apps\device-scope-dashboard-v2\logs\stderr.log
nssm restart DeviceScopeDashboard
Get-Content C:\apps\device-scope-dashboard-v2\logs\stderr.log -Tail 30
```

---

## Symptom: `CreateFile() failed to open ...stderr.log: Access is denied` — service won't start *at all* the moment logging is configured

This happened twice in the same incident, both times immediately after running the `AppStdout`/`AppStderr` commands above. **Cause unconfirmed** — the service account was already a local administrator on this box, which should normally bypass NTFS permission issues, so this wasn't a simple ACL gap. Suspected but unverified: another agent on the box (EventSentry was actively logging service state changes during this exact incident) locking or scanning new files the instant they're created.

**Fastest unblock — this logging was only ever a diagnostic aid, never required for the app to run:**
```powershell
nssm reset DeviceScopeDashboard AppStdout
nssm reset DeviceScopeDashboard AppStderr
```
**Important:** `nssm set X ""` does **not** reliably clear the parameter — it left the path still configured during this incident, causing the exact same failure to recur. Use `nssm reset`, then verify it's actually empty:
```powershell
nssm get DeviceScopeDashboard AppStdout
nssm get DeviceScopeDashboard AppStderr
```

If you want to actually fix the permission gap rather than work around it (only bother with this once the service is back up and stable):
```powershell
icacls "C:\apps\device-scope-dashboard-v2\logs" /grant "IMAGE\gMSA_DevScope$:(OI)(CI)M"
```
This did **not** resolve the issue in this incident even though it was the leading theory at the time — flagging that so it isn't assumed to be a confirmed fix if it recurs.

---

## Symptom: Service shows `Running`/`Starting` in a tight loop every few seconds

This is a crash loop, not a slow startup — NSSM auto-restarts the wrapped process every time it exits, and a fast, repeated crash looks exactly like this. Confirm via `netstat`: you'll see `TIME_WAIT`/`SYN_SENT` entries but never `LISTENING`.

---

## The technique that actually found the real root cause: bypass NSSM entirely

When NSSM-launched and manually-launched versions of the *same exact command* behave differently, that's the single most useful fact you can establish — it isolates the problem to NSSM's launch mechanism itself, ruling out the app, the code, and (with the right test) the service account.

**Step 1 — run it manually, in the foreground, with the exact same arguments NSSM uses:**
```powershell
nssm get DeviceScopeDashboard AppParameters   # confirm the exact current launch args first
cd C:\apps\device-scope-dashboard-v2
& ".\.venv\Scripts\streamlit.exe" run streamlit_app.py --server.port 8501 --server.address 0.0.0.0
```
If this works under your own interactive login but the service still won't start, the difference is the **account**, not the app.

**Step 2 — isolate the account specifically, using a one-shot Scheduled Task instead of NSSM:**
```powershell
$action = New-ScheduledTaskAction -Execute "C:\apps\device-scope-dashboard-v2\.venv\Scripts\streamlit.exe" -Argument "run C:\apps\device-scope-dashboard-v2\streamlit_app.py --server.port 8501 --server.address 0.0.0.0" -WorkingDirectory "C:\apps\device-scope-dashboard-v2"
$principal = New-ScheduledTaskPrincipal -UserId "IMAGE\gMSA_DevScope$" -LogonType Password -RunLevel Highest
Register-ScheduledTask -TaskName "TempGMSATest" -Action $action -Principal $principal -Force
Start-ScheduledTask -TaskName "TempGMSATest"
Start-Sleep -Seconds 10
Get-ScheduledTaskInfo -TaskName "TempGMSATest"
netstat -ano | findstr :8501
```
`LastTaskResult` of `267009` (`0x41301`) means **"task is currently running"** — not an error. A genuine `LISTENING` entry in the `netstat` output is the real confirmation.

If this succeeds — same account, same command, same working directory, outside NSSM — you've now proven the gMSA and the app are both fine, and the problem is narrowed entirely to NSSM's own process. **This is exactly what happened in this incident**, and it's what justified moving to the fix below rather than continuing to patch the existing service object.

Clean up the test task once done (this only removes the task definition, not an already-running process):
```powershell
Unregister-ScheduledTask -TaskName "TempGMSATest" -Confirm:$false
```

---

## The actual fix in this incident: recreate the service from scratch

Given enough back-and-forth configuration changes to a service object (`AppDirectory`, `AppParameters`, `AppStdout`/`AppStderr` set and reset multiple times), NSSM's internal state can end up inconsistent in ways that are impractical to fully unwind by hand. Once the account and app are proven fine via the scheduled-task test above, recreating the service is a reasonable, low-risk move — not a desperate one.

```powershell
nssm stop DeviceScopeDashboard
nssm remove DeviceScopeDashboard confirm
nssm install DeviceScopeDashboard "C:\apps\device-scope-dashboard-v2\.venv\Scripts\streamlit.exe" "run C:\apps\device-scope-dashboard-v2\streamlit_app.py --server.port 8501 --server.address 0.0.0.0"
nssm set DeviceScopeDashboard AppDirectory C:\apps\device-scope-dashboard-v2
```

### The specific gMSA gotcha that blocked this the first time

```
nssm set DeviceScopeDashboard ObjectName "IMAGE\gMSA_DevScope$"
Setting "ObjectName" requires both a username and password!
```

NSSM's `ObjectName` command always expects two arguments, even for an account type (gMSA) that has no manually-set password to provide — Windows handles a gMSA's password rotation internally regardless of what's passed. **Pass an empty string as the second argument:**

```powershell
nssm set DeviceScopeDashboard ObjectName "IMAGE\gMSA_DevScope$" ""
```

If that still doesn't behave correctly, `sc.exe` (built into Windows) natively understands gMSA accounts without requiring a password argument at all:
```powershell
sc.exe config DeviceScopeDashboard obj= "IMAGE\gMSA_DevScope$"
```
(Note the required space after `obj=` — easy to mistype.)

Then start and verify:
```powershell
nssm start DeviceScopeDashboard
Start-Sleep -Seconds 10
netstat -ano | findstr :8501
```

---

## Post-incident cleanup checklist

- [ ] Kill any leftover manual/foreground `streamlit.exe` processes from testing: `Get-Process -Id <PID> | Stop-Process -Force`
- [ ] Confirm the test Scheduled Task was removed: `Get-ScheduledTask -TaskName "TempGMSATest"` should return nothing
- [ ] Confirm `AppStdout`/`AppStderr` are in the state you actually want long-term (empty, or pointed at logs — if the latter, retest that the access-denied issue doesn't recur with the freshly-recreated service)
- [ ] **Reboot once**, when convenient — confirms the recreated service comes up cleanly from a cold start, not just within the same session where everything's already "warmed up"
- [ ] If this incident happened during an IIS cutover like it did here, don't forget the separate `enableCORS = false` regression risk this can introduce — see `IIS_REVERSE_PROXY_SETUP.md` §9
