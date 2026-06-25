<#
Invoke-DeviceScopePipeline.ps1

Orchestrator for the DeviceScope data pipeline. Replaces the old
monolithic AllDeviceExports_Merge.ps1.

Responsibilities (and ONLY these - all normalization/merge logic
lives in SQL views, not here):
  1. Resolve DB path, ensure schema/views are current
  2. Generate one RunId shared by all 6 collectors
  3. Call each collector script in turn
  4. Each collector independently succeeds/fails and logs to
     source_run_log; a single source failing does NOT abort the
     other five (this is the resilience behavior from roadmap #3)
  5. Print a run summary

This is what your existing 4:30am Scheduled Task should call instead
of AllDeviceExports_Merge.ps1.

Usage:
  .\Invoke-DeviceScopePipeline.ps1
  .\Invoke-DeviceScopePipeline.ps1 -ConfigPath C:\apps\devicescope\config.json
#>
param(
    [string]$ConfigPath,
    [switch]$SkipSchemaInit   # pass this on subsequent runs once schema is stable, to skip re-applying views every time (views are cheap to reapply, but flag is here for explicitness)
)

$repoRoot     = $PSScriptRoot
$collectorsDir = Join-Path $repoRoot "collectors"
$sqlDir       = Join-Path $repoRoot "sql"

Import-Module (Join-Path $collectorsDir "DeviceScope.Common.psm1") -Force

if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot "config.json" }

$DbPath = Get-DeviceScopeDbPath -ConfigPath $ConfigPath
$dbDir = Split-Path $DbPath -Parent
if (-not (Test-Path $dbDir)) { New-Item -ItemType Directory -Path $dbDir -Force | Out-Null }

Write-Output "================================================"
Write-Output "DeviceScope Pipeline starting: $(Get-Date)"
Write-Output "Database: $DbPath"
Write-Output "================================================"

# Views are safe to re-apply every run (DROP+CREATE VIEW only, never
# touches table data). Re-applying the *schema* file would wipe raw
# tables, so we only ever run 02_views.sql here after first-time setup.
if (-not $SkipSchemaInit) {
    if (-not (Test-Path $DbPath)) {
        Write-Output "Database file does not exist - running full schema initialization (tables + views)."
        Initialize-DeviceScopeDb -DbPath $DbPath -SqlSchemaDir $sqlDir
    } else {
        Write-Output "Database exists - refreshing views only (raw tables preserved)."
        Import-Module PSSQLite -ErrorAction Stop
        $viewsFile = Join-Path $sqlDir "02_views.sql"
        # -Encoding UTF8 is required here, not optional. Without it,
        # Windows PowerShell 5.1's Get-Content defaults to the system's
        # ANSI codepage (not UTF-8) for files without a UTF-8 BOM. The
        # emoji literals in DeviceHealth/HealthReason (e.g. '✅ Healthy',
        # '🧹 Removal Needed') are multi-byte UTF-8 sequences - read
        # under the wrong codepage, each byte gets reinterpreted as a
        # separate single-byte character, producing exactly the
        # "âœ… Healthy" / "ðŸ§¹ Removal Needed" mojibake pattern. PowerShell
        # 7+ defaults Get-Content to UTF-8 already, which is why this
        # may have looked fine in any environment that happened to run
        # this via pwsh.exe - it's specifically a PS 5.1 (powershell.exe)
        # problem, the same binary the Streamlit Refresh button invokes.
        Invoke-SqliteQuery -DataSource $DbPath -Query (Get-Content $viewsFile -Raw -Encoding UTF8)
    }
}

$runId = New-DeviceScopeRunId
Write-Output "Run ID: $runId"
Write-Output ""

$collectors = @(
    @{ Name = "Entra";       Script = "Get-EntraDevices.ps1" }
    @{ Name = "Intune";      Script = "Get-IntuneDevices.ps1" }
    @{ Name = "AD";          Script = "Get-ADDevices.ps1" }
    @{ Name = "Sophos";      Script = "Get-SophosDevices.ps1" }
    @{ Name = "KACE";        Script = "Get-KACEDevices.ps1" }
    @{ Name = "EventSentry"; Script = "Get-EventSentryDevices.ps1" }
)

$results = @()

foreach ($c in $collectors) {
    $scriptPath = Join-Path $collectorsDir $c.Script
    Write-Output "---- Running collector: $($c.Name) ----"

    try {
        if ($c.Name -eq "AD") {
            # AD collector has no -ConfigPath param (uses Get-ADComputer directly, no API secrets needed)
            & $scriptPath -DbPath $DbPath -RunId $runId
        } else {
            & $scriptPath -DbPath $DbPath -RunId $runId -ConfigPath $ConfigPath
        }
        $results += [PSCustomObject]@{ Source = $c.Name; Outcome = "Completed (see log above for Success/Failed/SkippedUsedCache)" }
    } catch {
        Write-Warning "Collector $($c.Name) threw an unhandled exception: $($_.Exception.Message)"
        $results += [PSCustomObject]@{ Source = $c.Name; Outcome = "Unhandled exception - see warning above" }
    }
    Write-Output ""
}

Write-Output "================================================"
Write-Output "Pipeline run complete: $(Get-Date)"
Write-Output "================================================"
$results | Format-Table -AutoSize

# Print freshness summary - same data Streamlit will show in its
# freshness banner (roadmap item #9)
Write-Output ""
Write-Output "Per-source last successful pull:"
Import-Module PSSQLite -ErrorAction Stop
foreach ($c in $collectors) {
    $ts = Get-LastSuccessfulPullTimestamp -DbPath $DbPath -SourceName $c.Name
    # NOTE: $ts ?? "NEVER SUCCEEDED" (null-coalescing) is PowerShell 7.0+
    # only - it parses fine under pwsh.exe but throws a hard parser
    # error under powershell.exe (Windows PowerShell 5.1), which is
    # exactly what the Streamlit "Refresh Device Data" button invokes
    # (its subprocess call is literally ["powershell", ...], not
    # ["pwsh", ...]). Rewritten as an explicit if/else so this script
    # parses correctly under both PS 5.1 and PS 7+, regardless of
    # which one any given caller happens to use.
    $tsDisplay = if ($ts) { $ts } else { "NEVER SUCCEEDED" }
    Write-Output ("  {0,-12} : {1}" -f $c.Name, $tsDisplay)
}