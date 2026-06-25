<#
DeviceScope.Common.psm1

Shared helpers used by every per-source collector script and the
merge orchestrator. Centralizes:
  - Name key normalization (so every collector agrees on join keys)
  - SQLite access (via System.Data.SQLite or PSSQLite, see note below)
  - Run logging (source_run_log table) for the fallback-to-cache logic
  - DPAPI / Key Vault secret resolution (unchanged from prior version)

REQUIRES: PSSQLite module (Install-Module PSSQLite -Scope CurrentUser)
  PSSQLite is used here for simplicity/readability. If you prefer no
  third-party dependency, swap Invoke-SqliteQuery calls for raw
  System.Data.SQLite ADO.NET calls - the function signatures below
  are written so that swap only touches this one file.
#>

# ==============================
# Name key normalization
# ==============================
# IMPORTANT: every collector MUST use these two functions (never
# re-implement normalization inline). This is what guarantees all
# six sources join correctly on the same key.

function NormalizeComputerName {
    param([string]$n)
    if (-not $n) { return $null }
    $x = $n.Trim()
    if ($x -eq '') { return $null }
    $x = $x.TrimEnd('$')
    $x = $x.ToUpper()
    if ($x.Contains('.') -and -not ($x -match '\s')) {
        $x = $x.Split('.')[0]
    }
    return $x
}

function NormalizeDisplayName {
    param([string]$n)
    if (-not $n) { return $null }
    $x = $n.Trim().ToUpper()
    $x = $x.TrimEnd('$')
    return $x
}

# ==============================
# SQLite connection helpers
# ==============================

function Get-DeviceScopeDbPath {
    <#
    Resolves the path to the SQLite database file, relative to the
    repo root (one level up from /scripts). Override via config.json
    "SqliteDbPath" if present.
    #>
    param([string]$ConfigPath)

    $dbPath = $null
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        try {
            $cfg = Get-Content $ConfigPath | ConvertFrom-Json
            if ($cfg.SqliteDbPath) { $dbPath = $cfg.SqliteDbPath }
        } catch {
            Write-Warning "Could not read SqliteDbPath from config: $($_.Exception.Message)"
        }
    }

    if (-not $dbPath) {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $dbPath = Join-Path $repoRoot "data\devicescope.db"
    }

    return $dbPath
}

function Initialize-DeviceScopeDb {
    <#
    Runs the schema + view SQL files against the target database.
    Safe to re-run; schema file DROPs/CREATEs tables (raw data is
    lost only on first init - see note in 01_schema.sql about not
    re-running it after go-live unless you intend to wipe history).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$DbPath,
        [Parameter(Mandatory=$true)][string]$SqlSchemaDir
    )

    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        throw "PSSQLite module not found. Install with: Install-Module PSSQLite -Scope CurrentUser"
    }
    Import-Module PSSQLite -ErrorAction Stop

    $schemaFile = Join-Path $SqlSchemaDir "01_schema.sql"
    $viewsFile  = Join-Path $SqlSchemaDir "02_views.sql"

    if (-not (Test-Path $schemaFile)) { throw "Schema file not found: $schemaFile" }
    if (-not (Test-Path $viewsFile))  { throw "Views file not found: $viewsFile" }

    Write-Output "Applying schema: $schemaFile"
    # -Encoding UTF8 required - see the matching note in
    # Invoke-DeviceScopePipeline.ps1's view-refresh branch. Without it,
    # Windows PowerShell 5.1's Get-Content defaults to the system ANSI
    # codepage rather than UTF-8, corrupting any multi-byte character
    # (e.g. the emoji literals in 02_views.sql's DeviceHealth/
    # HealthReason CASE expressions) into mojibake on read. Applied to
    # both files here for consistency, even though 01_schema.sql itself
    # doesn't currently contain any non-ASCII text.
    Invoke-SqliteQuery -DataSource $DbPath -Query (Get-Content $schemaFile -Raw -Encoding UTF8)

    Write-Output "Applying views: $viewsFile"
    Invoke-SqliteQuery -DataSource $DbPath -Query (Get-Content $viewsFile -Raw -Encoding UTF8)
}

function New-DeviceScopeRunId {
    <# Generates a single run identifier shared across all collectors
       for one pipeline execution, so source_run_log entries can be
       correlated to "this morning's 4:30am run". #>
    return (Get-Date).ToString("yyyyMMdd_HHmmss") + "_" + [guid]::NewGuid().ToString("N").Substring(0,8)
}

function Write-SourceRunLog {
    param(
        [Parameter(Mandatory=$true)][string]$DbPath,
        [Parameter(Mandatory=$true)][string]$SourceName,
        [Parameter(Mandatory=$true)][string]$RunId,
        [Parameter(Mandatory=$true)][ValidateSet('Success','Failed','SkippedUsedCache')][string]$Status,
        [int]$RowCount = 0,
        [string]$ErrorMessage = $null,
        [Parameter(Mandatory=$true)][datetime]$StartedAt,
        [datetime]$CompletedAt = (Get-Date)
    )

    Import-Module PSSQLite -ErrorAction Stop
    $query = @"
INSERT INTO source_run_log (source_name, run_id, status, row_count, error_message, started_at, completed_at)
VALUES (@source_name, @run_id, @status, @row_count, @error_message, @started_at, @completed_at)
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $query -SqlParameters @{
        source_name   = $SourceName
        run_id        = $RunId
        status        = $Status
        row_count     = $RowCount
        error_message = $ErrorMessage
        started_at    = $StartedAt.ToString("o")
        completed_at  = $CompletedAt.ToString("o")
    }
}

function Get-LastSuccessfulPullTimestamp {
    <# Used by collectors (and by Streamlit) to report data freshness
       per source - roadmap item #9. #>
    param(
        [Parameter(Mandatory=$true)][string]$DbPath,
        [Parameter(Mandatory=$true)][string]$SourceName
    )
    Import-Module PSSQLite -ErrorAction Stop
    $row = Invoke-SqliteQuery -DataSource $DbPath -Query @"
SELECT completed_at FROM source_run_log
WHERE source_name = @source_name AND status = 'Success'
ORDER BY completed_at DESC LIMIT 1
"@ -SqlParameters @{ source_name = $SourceName }

    if ($row) { return $row.completed_at }
    return $null
}

# ==============================
# Generic raw-table writer with fallback-to-cache behavior
# ==============================
function Write-SourceRawTable {
    <#
    Writes a collector's flattened rows into its raw table, tagged
    with run_id and pulled_at. If $Rows is empty, DOES NOT touch the
    table (preserves prior data) and logs a SkippedUsedCache status,
    instead of wiping the source's visibility to zero for the day.

    PERFORMANCE NOTE: earlier versions of this function used
    Out-DataTable + Invoke-SQLiteBulkCopy (PSSQLite), which turned out
    to be extremely slow in practice (minutes for a few hundred rows -
    PSObject reflection overhead plus per-row ADO.NET behavior in
    PSSQLite's bulk copy implementation). This version opens a single
    raw System.Data.SQLite connection, wraps all inserts for one
    source in ONE transaction, and uses a precompiled parameterized
    command reused across rows. This is the same pattern a hand-written
    .NET bulk loader would use, with no PSSQLite-specific bulk copy
    path involved. Typical throughput: well under a second for
    ~1000 rows, vs. minutes previously.

    This is the core of roadmap item #3 (per-source resilience).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$DbPath,
        [Parameter(Mandatory=$true)][string]$TableName,
        [Parameter(Mandatory=$true)][string]$SourceName,
        [Parameter(Mandatory=$true)][string]$RunId,
        [Parameter(Mandatory=$true)][datetime]$StartedAt,
        [array]$Rows
    )

    Import-Module PSSQLite -ErrorAction Stop  # ensures the SQLite ADO.NET provider assembly is loaded

    if (-not $Rows -or @($Rows).Count -eq 0) {
        Write-Warning "$SourceName returned 0 rows - leaving $TableName untouched, using last successful pull."
        Write-SourceRunLog -DbPath $DbPath -SourceName $SourceName -RunId $RunId `
            -Status 'SkippedUsedCache' -RowCount 0 -StartedAt $StartedAt
        return
    }

    $pulledAt = (Get-Date).ToString("o")

    foreach ($r in $Rows) {
        $r | Add-Member -NotePropertyName pulled_at     -NotePropertyValue $pulledAt -Force
        $r | Add-Member -NotePropertyName source_run_id -NotePropertyValue $RunId    -Force
    }

    # Column list comes from the first row - every row from one
    # collector's ForEach-Object shares the same shape.
    $columns = $Rows[0].PSObject.Properties.Name
    $colList = ($columns -join ", ")
    $paramList = ($columns | ForEach-Object { "@$_" }) -join ", "

    $conn = $null
    try {
        $conn = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$DbPath;Version=3;")
        $conn.Open()

        $tx = $conn.BeginTransaction()

        $deleteCmd = $conn.CreateCommand()
        $deleteCmd.Transaction = $tx
        $deleteCmd.CommandText = "DELETE FROM $TableName"
        [void]$deleteCmd.ExecuteNonQuery()

        $insertCmd = $conn.CreateCommand()
        $insertCmd.Transaction = $tx
        $insertCmd.CommandText = "INSERT INTO $TableName ($colList) VALUES ($paramList)"

        # Pre-create parameter objects once, reuse (set .Value) per row -
        # this is what makes the loop fast: no per-row command parsing.
        $paramObjs = @{}
        foreach ($col in $columns) {
            $p = $insertCmd.CreateParameter()
            $p.ParameterName = "@$col"
            [void]$insertCmd.Parameters.Add($p)
            $paramObjs[$col] = $p
        }

        foreach ($row in $Rows) {
            foreach ($col in $columns) {
                $val = $row.$col
                $paramObjs[$col].Value = if ($null -eq $val) { [DBNull]::Value } else { [string]$val }
            }
            [void]$insertCmd.ExecuteNonQuery()
        }

        $tx.Commit()

        Write-SourceRunLog -DbPath $DbPath -SourceName $SourceName -RunId $RunId `
            -Status 'Success' -RowCount @($Rows).Count -StartedAt $StartedAt
        Write-Output "$SourceName -> wrote $(@($Rows).Count) rows to $TableName"
    } catch {
        if ($tx -and $tx.Connection) { try { $tx.Rollback() } catch {} }
        Write-Warning "$SourceName -> failed writing to $TableName : $($_.Exception.Message)"
        Write-SourceRunLog -DbPath $DbPath -SourceName $SourceName -RunId $RunId `
            -Status 'Failed' -RowCount 0 -ErrorMessage $_.Exception.Message -StartedAt $StartedAt
    } finally {
        if ($conn -and $conn.State -eq 'Open') { $conn.Close() }
    }
}

# ==============================
# Secret resolution (unchanged behavior from prior version)
# ==============================
function Convert-SecureStringToPlainText {
    param([Security.SecureString]$Secure)
    if ($null -eq $Secure) { return "" }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
    finally { if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } }
}

function Get-DpapiSecret {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        if (-not (Test-Path $Path)) {
            Write-Warning "DPAPI secret file not found: $Path"
            return $null
        }
        [System.Reflection.Assembly]::LoadWithPartialName("System.Security") | Out-Null
        $encrypted = [System.IO.File]::ReadAllBytes($Path)
        $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        [System.Text.Encoding]::UTF8.GetString($decrypted)
    } catch {
        Write-Warning "Failed to decrypt DPAPI secret at $Path : $($_.Exception.Message)"
        return $null
    }
}

function FlattenObject {
    param([Parameter(Mandatory=$true)]$obj, [string]$prefix = "")
    $flat = @{}
    if ($null -eq $obj) { return $flat }
    foreach ($prop in $obj.PSObject.Properties) {
        $name = if ($prefix) { "$prefix.$($prop.Name)" } else { $prop.Name }
        $val  = $prop.Value
        if ($null -eq $val) { $flat[$name] = $null; continue }
        if ($val -is [PSCustomObject]) {
            $nested = FlattenObject -obj $val -prefix $name
            foreach ($k in $nested.Keys) { $flat[$k] = $nested[$k] }
            continue
        }
        if ($val -is [System.Collections.IDictionary]) {
            foreach ($k in $val.Keys) { $flat["$name.$k"] = $val[$k] }
            continue
        }
        if ($val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
            try { $flat[$name] = ($val | ForEach-Object { $_ }) -join "; " }
            catch { $flat[$name] = [string]$val }
            continue
        }
        $flat[$name] = $val
    }
    return $flat
}

Export-ModuleMember -Function `
    NormalizeComputerName, NormalizeDisplayName, `
    Get-DeviceScopeDbPath, Initialize-DeviceScopeDb, New-DeviceScopeRunId, `
    Write-SourceRunLog, Get-LastSuccessfulPullTimestamp, Write-SourceRawTable, `
    Convert-SecureStringToPlainText, Get-DpapiSecret, FlattenObject