<#
Get-EventSentryDevices.ps1

Collector for EventSentry inventory + patch data via direct PostgreSQL
query. Writes to BOTH eventsentry_raw (one row per device) and
eventsentry_patches_raw (one row per Microsoft update per device).

PATCH TABLE NOTE (CONFIRMED against production EventSentry schema):
  Patch data lives in eventsentry.esappstatus, which is EventSentry's
  general application-inventory table, NOT a dedicated patch table.
  Updates are distinguished via the iswindowsupdate flag (integer,
  not boolean - compare with = 1, not = true).

  application/publisher are integer foreign keys into lookup tables
  (esappname, esapppublisher) - both joins are required to get
  human-readable text.

  KNOWN DATA QUALITY ISSUE: KB2267602 ("Update for Removal of
  Outdated ActiveX Controls") reinstalls itself periodically and
  shows up with recent/rotating install dates on most devices
  regardless of actual patch currency. It is explicitly excluded
  below so it doesn't artificially inflate PatchStatus to "Current"
  for devices that haven't had a real cumulative/security update
  recently. If other similarly-recurring non-patch KBs are
  discovered later, add them to the same exclusion list.

  myversion/licensekey are USER-DEFINED (custom Postgres domain)
  types - version is empty in practice for nearly all rows, so it
  is not relied upon for patch-currency logic, only carried through
  for display/debugging.
#>
param(
    [Parameter(Mandatory=$true)][string]$DbPath,
    [Parameter(Mandatory=$true)][string]$RunId,
    [string]$ConfigPath
)

Import-Module (Join-Path $PSScriptRoot "DeviceScope.Common.psm1") -Force

function Import-EventSentryPostgresAssemblies {
    $roots = @()
    if ($env:LOCALAPPDATA) {
        $p = Join-Path $env:LOCALAPPDATA "PackageManagement\NuGet\Packages"
        if (Test-Path $p) { $roots += $p }
    }
    if ($env:ProgramFiles) {
        $p = Join-Path $env:ProgramFiles "PackageManagement\NuGet\Packages"
        if (Test-Path $p) { $roots += $p }
    }
    if (-not $roots) { throw "No valid PackageManagement NuGet paths found" }

    function Find-Dll($pattern, $extraMatch) {
        foreach ($r in $roots) {
            $hit = Get-ChildItem $r -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match $extraMatch } | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
        return $null
    }

    $logDll    = Find-Dll "Microsoft.Extensions.Logging.Abstractions.dll" "6\.0\.0.*net6\.0"
    $npgsqlDll = Find-Dll "Npgsql.dll" "Npgsql\.7\.0\.6.*net6\.0"
    if (-not $logDll)    { throw "Missing Microsoft.Extensions.Logging.Abstractions.dll v6.0.0" }
    if (-not $npgsqlDll) { throw "Missing Npgsql.dll v7.0.6" }

    [System.Reflection.Assembly]::LoadFrom($logDll)    | Out-Null
    [System.Reflection.Assembly]::LoadFrom($npgsqlDll) | Out-Null
}

function Invoke-EventSentryQuery {
    param([Parameter(Mandatory=$true)][string]$ConnectionString, [Parameter(Mandatory=$true)][string]$Sql)
    $conn = New-Object Npgsql.NpgsqlConnection($ConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        $dt = New-Object System.Data.DataTable
        $dt.Load($cmd.ExecuteReader())
        foreach ($row in $dt.Rows) {
            $obj = [ordered]@{}
            foreach ($col in $dt.Columns) {
                $val = $row[$col.ColumnName]
                if ($val -is [DBNull]) { $val = $null }
                $obj[$col.ColumnName] = $val
            }
            [PSCustomObject]$obj
        }
    } finally {
        if ($conn.State -ne 'Closed') { $conn.Close() }
    }
}

$startedAt = Get-Date
$eventsentryFlat = @()
$patchesFlat = @()

try {
    $configPath = if ($ConfigPath) { $ConfigPath } else { Join-Path (Split-Path $PSScriptRoot -Parent) "config.json" }
    $config = if (Test-Path $configPath) { Get-Content $configPath | ConvertFrom-Json } else { $null }
    $SecureDataFolder = if ($config.SecureDataFolder -and (Test-Path $config.SecureDataFolder)) { $config.SecureDataFolder } else { Join-Path $env:USERPROFILE "AppData\Local\DeviceScope\Secure" }

    $EventSentryDbHost = $config.EventSentryDbHost
    $EventSentryDbPort = if ($config.EventSentryDbPort) { [int]$config.EventSentryDbPort } else { 5432 }
    $EventSentryDbName = if ($config.EventSentryDbName) { $config.EventSentryDbName } else { "EventSentry" }

    # ---- Credential resolution: Key Vault first, DPAPI fallback ----
    # Mirrors the pattern in Get-SophosDevices.ps1 / Get-KACEDevices.ps1.
    # EventSentryDbUser is not a secret (just an account name), so it
    # can come from config directly; only the password is treated as
    # sensitive and goes through the Key Vault -> DPAPI chain.
    $EventSentryDbUser = $config.EventSentryDbUser
    if (-not $EventSentryDbUser) { $EventSentryDbUser = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "EventSentryDbUser.bin") }

    $EventSentryDbPassword = $null

    if ($config.KeyVaultName -and $config.KeyVaultSecrets.EventSentryDbPassword `
        -and (Get-Command Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        try {
            $s = Get-AzKeyVaultSecret -VaultName $config.KeyVaultName `
                -Name $config.KeyVaultSecrets.EventSentryDbPassword -ErrorAction Stop
            $EventSentryDbPassword = Convert-SecureStringToPlainText -Secure $s.SecretValue
            Write-Output "EventSentry DB password resolved via Key Vault."
        } catch {
            Write-Warning "Key Vault EventSentry DB password retrieval failed, will fall back to DPAPI: $($_.Exception.Message)"
        }
    }

    if (-not $EventSentryDbPassword) {
        $EventSentryDbPassword = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "EventSentryDbPassword.bin")
        if ($EventSentryDbPassword) { Write-Output "EventSentry DB password resolved via DPAPI fallback." }
    }

    if (-not ($EventSentryDbHost -and $EventSentryDbUser -and $EventSentryDbPassword)) {
        throw "EventSentry connection not fully configured (missing host/user/password from both Key Vault and DPAPI)."
    }

    $connString = "Host=$EventSentryDbHost;Port=$EventSentryDbPort;Username=$EventSentryDbUser;Password=$EventSentryDbPassword;Database=$EventSentryDbName;Timeout=10;Command Timeout=30"

    Import-EventSentryPostgresAssemblies

    # ---------- Inventory query (existing, unchanged) ----------
    $sqlInventory = @"
SELECT
  c.eventcomputer    AS hostname,
  si.esagentversion  AS "agentVersion",
  si.recorddate      AS "inventoryTimestamp",
  si.manufacturer    AS manufacturer,
  si.model           AS model,
  si.os              AS os,
  si.osedition       AS osEdition,
  si.totalmemory     AS totalMemory,
  si.bitlocker       AS bitlocker,
  si.uptimetimestamp AS uptimeTimestamp,
  si.uptime          AS uptime,
  si.chassistype     AS chassistype,
  si.producttype     AS producttype,
  si.isvm            AS isvm
FROM eventsentry.eseventlogcomputer c
LEFT JOIN eventsentry.essysinfo si ON si.computer = c.id
"@
    $invRows = Invoke-EventSentryQuery -ConnectionString $connString -Sql $sqlInventory

    $eventsentryFlat = @($invRows | ForEach-Object {
        $hostname = ([string]$_.hostname).Trim()
        if (-not $hostname -or $hostname -match '^MININT-' -or $hostname -eq '-' `
            -or $hostname -match '^[0-9]+$' -or $hostname -notmatch '^[A-Za-z0-9\-]+$') { return }

        $nameKey = NormalizeComputerName $hostname
        if (-not $nameKey) { return }

        [PSCustomObject]@{
            name_key             = $nameKey
            hostname              = $hostname
            agent_version           = $_.agentVersion
            inventory_timestamp      = [string]$_.inventoryTimestamp
            manufacturer            = $_.manufacturer
            model                  = $_.model
            os                    = $_.os
            os_edition              = $_.osEdition
            total_memory            = [string]$_.totalMemory
            bitlocker              = [string]$_.bitlocker
            uptime                 = [string]$_.uptime
            chassis_type            = $_.chassistype
            product_type            = $_.producttype
            is_vm                  = [int][bool]$_.isvm
        }
    }) | Where-Object { $_ -ne $null }

    Write-Output "EventSentry: fetched $($eventsentryFlat.Count) inventory rows"

    # ---------- Patch query (CONFIRMED against production schema) ----------
    # esappstatus is general app inventory; iswindowsupdate=1 isolates
    # Windows/Microsoft updates. application/publisher are FK lookups.
    # KB2267602 excluded - it's a recurring ActiveX-removal update, not
    # a real patch signal (see header note for detail).
    $sqlPatches = @"
SELECT
  c.eventcomputer  AS hostname,
  ap.name          AS publisher,
  an.name          AS securityupdate,
  s.myversion::text AS version,
  s.is64bit        AS is64bit,
  s.installdate    AS installdate
FROM eventsentry.esappstatus s
JOIN eventsentry.eseventlogcomputer c ON c.id = s.computer
LEFT JOIN eventsentry.esapppublisher ap ON ap.id = s.publisher
LEFT JOIN eventsentry.esappname an ON an.id = s.application
WHERE s.iswindowsupdate = 1
  AND ap.name ILIKE 'Microsoft%'
  AND an.name NOT ILIKE '%KB2267602%'
"@
    try {
        $patchRows = Invoke-EventSentryQuery -ConnectionString $connString -Sql $sqlPatches

        $patchesFlat = @($patchRows | ForEach-Object {
            $hostname = ([string]$_.hostname).Trim()
            $nameKey = NormalizeComputerName $hostname
            if (-not $nameKey) { return }

            [PSCustomObject]@{
                name_key         = $nameKey
                hostname          = $hostname
                publisher          = $_.publisher
                security_update     = $_.securityupdate
                version            = $_.version
                is_64bit           = [int][bool]$_.is64bit
                install_date        = [string]$_.installdate
            }
        }) | Where-Object { $_ -ne $null }

        Write-Output "EventSentry: fetched $($patchesFlat.Count) patch records"
    } catch {
        Write-Warning "EventSentry patch query failed: $($_.Exception.Message)"
        $patchesFlat = @()
    }

} catch {
    Write-Warning "EventSentry collection failed: $($_.Exception.Message)"
    $eventsentryFlat = @()
    $patchesFlat = @()
} finally {
    $EventSentryDbPassword = $null
}

Write-SourceRawTable -DbPath $DbPath -TableName "eventsentry_raw" -SourceName "EventSentry" `
    -RunId $RunId -StartedAt $startedAt -Rows $eventsentryFlat

# Patches are logged under a distinct source name so a patch-query
# failure doesn't mask/overwrite the inventory pull's success status.
Write-SourceRawTable -DbPath $DbPath -TableName "eventsentry_patches_raw" -SourceName "EventSentryPatches" `
    -RunId $RunId -StartedAt $startedAt -Rows $patchesFlat