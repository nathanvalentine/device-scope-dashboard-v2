<#
AllDeviceExports_Merge.ps1

Design Principle:
  - Prefer accurate, recent, and authoritative data sources over simply "available" data.

Purpose:
  - Aggregate device data from multiple sources:
      • Entra (Azure AD)
      • Intune
      • Active Directory (on-prem)
      • Sophos Central
      • KACE SMA
      • EventSentry (PostgreSQL)
  - Normalize and flatten all source data into a consistent, CSV-friendly schema.
  - Namespace all source-specific fields (Entra.*, Intune.*, AD.*, Sophos.*, KACE.*, EventSentry.*).
  - Merge all sources into a single "device-centric" dataset keyed by normalized hostname/identifier.
  - Resolve overlapping fields (e.g., OS, Memory, LastSeen) using deterministic priority rules.
  - Derive additional intelligence fields:
      • Presence flags per source
      • Duplicate / instance tracking
      • EventSentry agent health (presence, age, stale)
      • Cross-source anomaly detection (e.g., stale or missing agent while active)

Output:
  - Single merged CSV with:
      • Source-specific raw fields
      • Unified (preferred) fields
      • Derived health/anomaly indicators

Key Features:
  - Multi-source correlation using normalized device identity
  - Deterministic field prioritization (no random "last write wins")
  - Robust paging for API-based sources (Sophos, KACE)
  - Graph SDK usage with -All for full dataset retrieval
  - EventSentry integration via direct PostgreSQL query
  - Designed for unattended execution (Scheduled Task / gMSA)

Configuration:
  - Script uses inline variables (no param() block)
  - Supports non-interactive authentication:
      • Azure via certificate-based service principal
      • Sophos via OAuth2 client credentials
      • KACE via session-based authentication
      • Optional SecretManagement integration

Requirements:
  - Microsoft Graph PowerShell SDK
  - ActiveDirectory module
  - Network/API access to:
      • Entra / Intune
      • Sophos Central
      • KACE SMA
      • EventSentry PostgreSQL database

Notes:
  - EventSentry data is treated as real-time telemetry (high fidelity for hardware + uptime).
  - Some sources may contain stale or partial data; merge logic prioritizes accuracy and recency.
  - Anomaly fields highlight inconsistencies across systems rather than relying on a single source.
#>

# ==============================
# Utility Functions
# ==============================
function EnsureModule {
    param([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Output "Installing missing module: $ModuleName"
        Install-Module -Name $ModuleName -Force -Scope CurrentUser
    }
}

function Convert-SecureStringToPlainText {
    param([Security.SecureString]$Secure)
    if ($null -eq $Secure) { return "" }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
    finally { if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } }
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

function FilterRow {
    param([PSCustomObject]$row, [string[]]$keys)
    # Convert PSCustomObject to hashtable for reliable lookup
    $h = @{}
    foreach ($p in $row.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $filtered = @{}
    foreach ($k in $keys) {
        $kk = [string]$k; $kk = $kk.Trim()
        # $filtered[$kk] = ($h.ContainsKey($kk)) ? $h[$kk] : '' # The ternary operator only works in PS 7
        $filtered[$kk] = if ($h.ContainsKey($kk)) { $h[$kk] } else { '' }
    }
    return [PSCustomObject]$filtered
}

# Return a readable string for values that may be complex objects, arrays, or enums
function Get-Readable {
    param($value)

    if ($null -eq $value) { return $null }

    # Strings are fine as-is
    if ($value -is [string]) { return $value }

    # Collections: join elements into a single string
    if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
        $items = @()
        foreach ($x in $value) {
            $items += (Get-Readable $x)
        }
        return ($items -join '; ')
    }

    # PSCustomObject or objects with common display/name properties
    if ($value -is [psobject]) {
        $candidateProps = @(
            'displayName','name','categoryDisplayName','deviceCategoryDisplayName',
            'title','label','value','id','type'
        )
        foreach ($p in $candidateProps) {
            if ($value.PSObject.Properties.Match($p)) {
                $v = $value.$p
                if ($v) { return (Get-Readable $v) }
            }
        }
        # Fallback to ToString() if nothing matched
        return $value.ToString()
    }

    # Enums/other primitives
    return $value.ToString()
}

# Like your existing helper, but ensures the returned value is readable text
function Get-AnyReadableFromSources {
    param([object[]]$sources, [string[]]$keys)
    foreach ($src in $sources) {
        if ($null -eq $src) { continue }
        foreach ($k in $keys) {
            if ($src.PSObject.Properties.Match($k)) {
                $v = $src.$k
                if ($v) {
                    $t = Get-Readable $v
                    if ($t) { return $t }
                }
            }
        }
    }
    return $null
}

# Determine device type (Virtual Machine, Server, Laptop, Desktop, Mobile/Personal) based on signals from all sources.
function Get-DeviceType {
    param(
        $es,  # EventSentry row
        $c,   # KACE row
        $d,   # AD row
        $s,   # Sophos row
        $e    # Entra row
    )

    # --- Virtual Machine (strongest signal) ---
    if ($es.'EventSentry.isvm' -eq 1) {
        return "Virtual Machine"
    }

    # --- Server detection ---
    if ($d.'AD.OperatingSystem' -match "Server" -or
        $s.'Sophos.type' -eq "server" -or
        $es.'EventSentry.producttype' -eq "SERVER") {
        return "Server"
    }

    # --- Laptop detection (EventSentry chassis) ---
    if ($es.'EventSentry.chassistype' -match "Laptop|Notebook|Portable|Book") {
        return "Laptop"
    }

    # --- Laptop (hostname fallback ✅ CRITICAL) ---
    if ($d.'AD.Name' -match '^LAPTOP-' -or
        $e.'Entra.DisplayName' -match '^LAPTOP-') {
        return "Laptop"
    }

    # --- Desktop detection ---
    if ($es.'EventSentry.chassistype' -match "Tower|Desktop") {
        return "Desktop"
    }

    # --- OS-based fallback classification ---
    $osCombined = (
        $es.'EventSentry.os',
        $e.'Entra.OperatingSystem',
        $c.'KACE.Os_name'
    ) -join " "

    if ($osCombined -match "iOS|Android|iPhone|iPad") {
        return "Mobile"
    }

    if ($osCombined -match "Windows") {
        return "Desktop"
    }

    # --- Mobile / personal devices (must be intentionally scoped) ---
    if (
        $e.'Entra.profileType' -eq "RegisteredDevice" -and
        -not (
            $d -or $c -or $s -or $es
        )
    ) {
        return "Mobile/Personal"
    }

    # --- Fallback ---
    return "Unknown"
}

# -------------------------------
# Normalization helpers (source-aware)
# -------------------------------
# Hostname-style normalization for AD/Intune/KACE/Sophos
function NormalizeComputerName {
    param([string]$n)
    if (-not $n) { return $null }
    $x = $n.Trim()
    if ($x -eq '') { return $null }

    # Remove trailing $ (AD machine accounts)
    $x = $x.TrimEnd('$')

    # Uppercase for consistent matching
    $x = $x.ToUpper()

    # If there's a dot and NO spaces, treat as FQDN and take the host label
    if ($x.Contains('.') -and -not ($x -match '\s')) {
        $x = $x.Split('.')[0]
    }

    return $x
}

# Entra display-name normalization (DO NOT split on dots)
function NormalizeDisplayName {
    param([string]$n)
    if (-not $n) { return $null }
    $x = $n.Trim().ToUpper()
    $x = $x.TrimEnd('$')
    return $x
}

# -------------------------------
# OU parsing helpers
# -------------------------------

# Return first OU name from a DN (OU=BranchX,OU=Computers,DC=example,DC=com -> BranchX)
function Get-FirstOUNameFromDN {
    param([string]$distinguishedName)
    if (-not $distinguishedName) { return $null }
    $m = [regex]::Match($distinguishedName, 'OU=([^,]+)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}


# Return full OU path from DN in a readable format (e.g., OU=Computers,OU=BranchX -> BranchX/Computers)
function Get-OUPathFromDN {
    param(
        [string]$distinguishedName,
        [switch]$RootToLeaf  # if set, returns "Branch/Computers"; else "Computers/Branch"
    )

    if (-not $distinguishedName) { return $null }

    # Pull all OU segments in the order they appear in the DN (leaf -> root)
    $ous = [regex]::Matches($distinguishedName, 'OU=([^,]+)', 'IgnoreCase') |
           ForEach-Object { $_.Groups[1].Value }

    if ($ous.Count -eq 0) { return $null }

    if ($RootToLeaf.IsPresent) {
        # Reverse to get root -> leaf (e.g., Branch/Computers)
        $arr = @($ous)     # make a copy; @() ensures it's an array
        [array]::Reverse($arr)
        return ($arr -join '/')
    }
    else {
        # Keep DN order (leaf -> root), e.g., Computers/Branch
        return ($ous -join '/')
    }
}

# If your OU naming embeds the location name (e.g., OU=Logan,OU=Computers,...), define the rule here.
# This returns the "location" derived from OU naming convention (you can refine to match your exact OU tree).
function DeriveLocationFromOU {
    param(
        [string]$ouName,
        [string]$ouPath
    )
    # Prefer the root OU from the path (root -> leaf)
    if ($ouPath) {
        $segments = $ouPath.Split('/')
        if ($segments.Count -gt 0) { return $segments[0] }
    }
    # Fallback to the first OU captured from DN
    if ($ouName) { return $ouName }
    return $null
}

# -------------------------------
# ---- DPAPI Helpers ----
# -------------------------------
# This function uses Windows Data Protection API (DPAPI) to securely retrieve secrets.
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
            $encrypted, $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        [System.Text.Encoding]::UTF8.GetString($decrypted)
    } catch {
        Write-Warning "Failed to decrypt DPAPI secret at $Path : $($_.Exception.Message)"
        return $null
    }
}

# This function attempts to resolve a secret value by first checking a provided current value (e.g., from config or SecretManagement), 
# and if that is not available, falling back to retrieving it from DPAPI. It also logs the source of the secret for transparency.
$SecretSources = @{}
function Resolve-SecretWithFallback {
    param(
        [string]$Name,
        $CurrentValue,
        [string]$DpapiPath
    )

    if ($CurrentValue) {
        $SecretSources[$Name] = "KeyVault/Config"
        Write-Host "Secret source [$Name]: KeyVault/Config"
        return $CurrentValue
    }

    $v = Get-DpapiSecret -Path $DpapiPath
    if ($v) {
        $SecretSources[$Name] = "DPAPI"
        Write-Host "Secret source [$Name]: DPAPI"
        return $v
    }

    $SecretSources[$Name] = "MISSING"
    Write-Warning "Secret source [$Name]: MISSING"
    return $null
}

# -------------------------------
# ---- Load required assemblies (Npgsql + Logging.Abstractions) for EventSentry calls ----
# -------------------------------
# EventSentry's PostgreSQL integration relies on Npgsql, which is not a native .NET assembly and must be loaded at runtime.
# This function searches common NuGet package cache locations for the required DLLs and loads them into the PowerShell session.
# Make sure to install the correct versions of these packages (e.g., via Install-Package) so that the expected DLLs are present.
function Import-EventSentryPostgresAssemblies {
    <#
      Loads Npgsql + required dependencies for PowerShell runtime.
      Searches common PackageManagement locations (user + admin contexts).
      REQUIRES:
        - Microsoft.Extensions.Logging.Abstractions.dll v6.0.0 (net6.0)
        - Npgsql.dll v7.0.6 (net6.0)
       If not found, throws an error with instructions to install the missing packages.
    #>

    $roots = @()

    if ($env:LOCALAPPDATA -and -not ($env:LOCALAPPDATA -is [array])) {
        $p = Join-Path $env:LOCALAPPDATA "PackageManagement\NuGet\Packages"
        if (Test-Path $p) { $roots += $p }
    }

    if ($env:ProgramFiles -and -not ($env:ProgramFiles -is [array])) {
        $p = Join-Path $env:ProgramFiles "PackageManagement\NuGet\Packages"
        if (Test-Path $p) { $roots += $p }
    }

    if (-not $roots) {
        throw "No valid PackageManagement NuGet paths found"
    }

    function Find-Dll($pattern, $extraMatch) {
        foreach ($r in $roots) {
            $hit = Get-ChildItem $r -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match $extraMatch } |
                Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
        return $null
    }

    # Pin versions that we KNOW worked in the session:
    # - Npgsql 7.0.6
    # - Microsoft.Extensions.Logging.Abstractions 6.0.0
    $logDll   = Find-Dll "Microsoft.Extensions.Logging.Abstractions.dll" "6\.0\.0.*net6\.0"
    $npgsqlDll= Find-Dll "Npgsql.dll" "Npgsql\.7\.0\.6.*net6\.0"

    if (-not $logDll)    { throw "Missing Microsoft.Extensions.Logging.Abstractions.dll v6.0.0 (net6.0). Install-Package Microsoft.Extensions.Logging.Abstractions -RequiredVersion 6.0.0" }
    if (-not $npgsqlDll) { throw "Missing Npgsql.dll v7.0.6 (net6.0). Install-Package Npgsql -RequiredVersion 7.0.6" }

    # Load dependency first, then Npgsql
    [System.Reflection.Assembly]::LoadFrom($logDll)    | Out-Null
    [System.Reflection.Assembly]::LoadFrom($npgsqlDll) | Out-Null
}

# Invoke a SQL query against EventSentry's PostgreSQL database and return results as PSCustomObjects.
# Make sure to call Import-EventSentryPostgresAssemblies() before using this function to ensure the required Npgsql assembly is loaded.
# Parameters:
# - ConnectionString: the PostgreSQL connection string for EventSentry (e.g., "Host=...;Port=...;Username=...;Password=...;Database=...")
function Invoke-EventSentryQuery {
    param(
        [Parameter(Mandatory=$true)][string]$ConnectionString,
        [Parameter(Mandatory=$true)][string]$Sql
    )

    $conn = New-Object Npgsql.NpgsqlConnection($ConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql

        $dt = New-Object System.Data.DataTable
        $dt.Load($cmd.ExecuteReader())

        foreach ($row in $dt.Rows) {
            # Convert DataRow to PSCustomObject
            $obj = [ordered]@{}
            foreach ($col in $dt.Columns) {
                $val = $row[$col.ColumnName]
                if ($val -is [DBNull]) { $val = $null }
                $obj[$col.ColumnName] = $val
            }
            [PSCustomObject]$obj
        }
    }
    finally {
        if ($conn.State -ne 'Closed') { $conn.Close() }
    }
}

# -------------------------------
# Index rows by NameKey (per source)
# -------------------------------
function IndexByNameKey {
    param(
        $rows,
        [scriptblock]$selector
    )
    $h = @{}
    # Loop through rows and build hashtable indexed by NameKey
    foreach ($r in @($rows)) {
        # Assign NameKey using the provided selector
        $k = & $selector $r
        if ($k) { $h[$k] = $r }   # map one representative row per name
    }
    return $h
}

# -------------------------------
# Map NameKey -> array of rows (captures all instances per source)
# -------------------------------
function IndexByNameKeyMulti {
  param(
    $rows,
    [scriptblock]$selector
  )
  $h = @{}
  foreach ($r in @($rows)) {
    $k = & $selector $r
    if ($k) {
      if (-not $h.ContainsKey($k)) { $h[$k] = @() }
      $h[$k] += $r
    }
  }
  return $h
}

# -------------------------------
# Helper: get first non-empty property across sources
# -------------------------------
function Get-AnyFromSources {
    param([object[]]$sources, [string[]]$keys)
    foreach ($src in $sources) {
        if ($null -eq $src) { continue }
        foreach ($k in $keys) {
            if ($src.PSObject.Properties.Match($k)) {
                $v = $src.$k
                if ($v) { return $v }
            }
        }
    }
    return $null
}

# --------------------------------
# Helper: Local data folder cleanup
# --------------------------------
function Remove-CleanupOldLocalFiles {
    param(
        [Parameter(Mandatory=$true)][string]$FolderPath,
        [Parameter(Mandatory=$true)][string]$Prefix,
        [Parameter(Mandatory=$true)][int]$Days
    )
    $cutoff = (Get-Date).AddDays(-$Days)
    $pattern = "$Prefix*.csv"
    $files = Get-ChildItem -Path $FolderPath -Filter $pattern -File
    foreach ($file in $files) {
        if ($file.LastWriteTime -lt $cutoff) {
            Write-Output "Deleting old file: $($file.FullName) (LastWriteTime=$($file.LastWriteTime))"
            Remove-Item $file.FullName -Force
        }
    }
}

# ==============================
# CONFIG (load from config.json)
# ==============================

# Load config from config.json in parent directory
$configPath = Join-Path (Split-Path $PSScriptRoot) "config.json"
$config = $null
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath | ConvertFrom-Json
        Write-Output "Loaded configuration from: $configPath"
    } catch {
        Write-Warning "Failed to load config.json: $($_.Exception.Message). Using defaults."
    }
}

# --- Configurable Paths (with intelligent defaults) ---
# Initialize FIRST, before any DPAPI or Key Vault logic, so paths are always set
if ($config.SecureDataFolder) {
    $secureCandidate = $config.SecureDataFolder
    if (Test-Path $secureCandidate) {
        $SecureDataFolder = $secureCandidate
    } else {
        Write-Warning "SecureDataFolder from config not found: $secureCandidate. Using fallback."
        $SecureDataFolder = if (Test-Path "C:\Secure") { "C:\Secure" } else { Join-Path $env:USERPROFILE "AppData\Local\DeviceScope\Secure" }
    }
} else {
    $SecureDataFolder = if (Test-Path "C:\Secure") { "C:\Secure" } else { Join-Path $env:USERPROFILE "AppData\Local\DeviceScope\Secure" }
}

if ($config.LogsFolder) {
    $logsCandidate = $config.LogsFolder
    if (Test-Path $logsCandidate) {
        $LogsFolder = $logsCandidate
    } else {
        Write-Warning "LogsFolder from config not found: $logsCandidate. Using fallback."
        $LogsFolder = if (Test-Path "C:\Logs") { "C:\Logs" } else { Join-Path $env:TEMP "DeviceScope" }
    }
} else {
    $LogsFolder = if (Test-Path "C:\Logs") { "C:\Logs" } else { Join-Path $env:TEMP "DeviceScope" }
}

# Dynamically resolve the data folder relative to this script's location
$dataFolder = Join-Path -Path $PSScriptRoot -ChildPath ".."
$dataFolder = Join-Path -Path $dataFolder -ChildPath "data"
# Resolve to absolute path to avoid issues with relative paths across contexts
$dataFolder = (Resolve-Path $dataFolder -ErrorAction Stop).Path
# Use the resolved data folder for the merged export path
$MergedExportPath = Join-Path -Path $dataFolder -ChildPath "DeviceScope_Merged.csv"

# Helper function to retrieve secrets from Key Vault (defined early for later use)
function Get-KeyVaultSecretPlain {
    param(
        [Parameter(Mandatory=$true)][string]$VaultName,
        [Parameter(Mandatory=$true)][string]$SecretName
    )
    try {
        $s = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -ErrorAction Stop
        if ($null -eq $s) { return $null }
        return Convert-SecureStringToPlainText -Secure $s.SecretValue
    } catch {
        Write-Warning "Failed to retrieve secret '$SecretName' from vault '$VaultName': $($_.Exception.Message)"
        return $null
    }
}

# -----------------------------------------
# Azure Key Vault bootstrap (certificate auth)
# If `KeyVaultName` is present in config, authenticate using the service principal
# certificate and fetch runtime secrets from Key Vault. Falls back to DPAPI files
# if Key Vault retrieval is not configured or fails.
try {
    if ($config -and $config.KeyVaultName) {
        Write-Output "Key Vault configuration detected. Preparing Az modules and authenticating..."

        # Ensure helper Install function exists earlier (EnsureModule)
        EnsureModule -ModuleName 'Az.Accounts'
        EnsureModule -ModuleName 'Az.KeyVault'

        # Pick bootstrap values from config
        $BootstrapTenantId = $config.TenantId
        $BootstrapClientId = $config.ClientId
        $BootstrapThumb   = $config.CertificateThumbprint
        $KeyVaultName     = $config.KeyVaultName

        if (-not ($BootstrapTenantId -and $BootstrapClientId -and $BootstrapThumb -and $KeyVaultName)) {
            Write-Warning "Incomplete Key Vault bootstrap configuration. Falling back to DPAPI secrets where available."
        } else {
            try {
                Write-Output "Connecting to Azure using certificate thumbprint $BootstrapThumb"
                Connect-AzAccount -ServicePrincipal -Tenant $BootstrapTenantId -ApplicationId $BootstrapClientId -CertificateThumbprint $BootstrapThumb -ErrorAction Stop
                Write-Output "Authenticated to Azure for app $BootstrapClientId"

                # Initialize password and secret variables to null; we'll populate if Key Vault retrieval succeeds
                $SophosClientId = $null
                $SophosClientSecret = $null
                $KacePassword = $null
                $MgClientSecret = $null
                $EventSentryDbPassword = $null

                # Map secret names from config (expected present)
                $kvSecrets = $config.KeyVaultSecrets
                if ($kvSecrets) {
                    $sophosIdName = $kvSecrets.SophosClientId
                    $sophosSecretName = $kvSecrets.SophosClientSecret
                    $kacePwName = $kvSecrets.KacePassword
                    $entraSecretName = $kvSecrets.EntraClientSecret
                    $eventSentryPwName = $kvSecrets.EventSentryDbPassword
                }

                # Fetch runtime secrets from Key Vault
                if ($sophosIdName)      { $SophosClientId     = Get-KeyVaultSecretPlain -VaultName $KeyVaultName -SecretName $sophosIdName }
                if ($sophosSecretName)  { $SophosClientSecret = Get-KeyVaultSecretPlain -VaultName $KeyVaultName -SecretName $sophosSecretName }
                if ($kacePwName)        { $KacePassword       = Get-KeyVaultSecretPlain -VaultName $KeyVaultName -SecretName $kacePwName }
                if ($eventSentryPwName) { $EventSentryDbPassword = Get-KeyVaultSecretPlain -VaultName $KeyVaultName -SecretName $eventSentryPwName }


                # Entra: if config says 'Certificate-Only' then no client secret is expected
                if ($entraSecretName -and ($entraSecretName -ne 'Certificate-Only')) {
                    $MgClientSecret = Get-KeyVaultSecretPlain -VaultName $KeyVaultName -SecretName $entraSecretName
                } else {
                    # No client secret; rely on certificate for Graph auth where appropriate
                    $MgClientSecret = $null
                }

                # Bootstrapped identifiers
                if ($config.ClientId) { $MgClientId = $config.ClientId }
                if ($config.TenantId) { $MgTenantId = $config.TenantId }
                if ($config.KaceUsername) { $KaceUsername = $config.KaceUsername }
                if ($config.EventSentryDbUser) { $EventSentryDbUser = $config.EventSentryDbUser }

                Write-Output "Key Vault secrets fetched (missing secrets will remain null)."
            } catch {
                Write-Warning "Azure authentication or Key Vault retrieval failed: $($_.Exception.Message). Falling back to DPAPI where available."
            }
        }
    }
} catch {
    Write-Warning "Unexpected error during Key Vault bootstrap: $($_.Exception.Message)"
}# ---- Entra / Intune (Microsoft Graph) ----
# Only load from DPAPI if Key Vault did not already populate these
$MgTenantId = Resolve-SecretWithFallback -Name "Graph TenantId" -CurrentValue $MgTenantId -DpapiPath (Join-Path $SecureDataFolder "MgTenantId.bin")
$MgClientId = Resolve-SecretWithFallback -Name "Graph ClientId" -CurrentValue $MgClientId -DpapiPath (Join-Path $SecureDataFolder "MgClientId.bin")
$MgClientSecret = Resolve-SecretWithFallback -Name "Graph ClientSecret" -CurrentValue $MgClientSecret -DpapiPath (Join-Path $SecureDataFolder "MgClientSecret.bin")
#$GraphProfile   = "v1.0"            # or "beta" if needed # Note: for SharePoint uploads, v1.0 is recommended as the shares API is fully supported there. ... though this is never used directly in the script since we hardcode the endpoint URLs, so it's more for documentation/reference if you want to switch to beta for other Graph calls.

# ---- Sophos Central ----
# Only load from DPAPI if Key Vault did not already populate these
$SophosClientId = Resolve-SecretWithFallback -Name "Sophos ClientId" -CurrentValue $SophosClientId -DpapiPath (Join-Path $SecureDataFolder "SophosClientId.bin")
$SophosClientSecret = Resolve-SecretWithFallback -Name "Sophos ClientSecret" -CurrentValue $SophosClientSecret -DpapiPath (Join-Path $SecureDataFolder "SophosClientSecret.bin")

# ---- KACE SMA ----
$KaceBaseUrl        = if ($config.KaceBaseUrl) { $config.KaceBaseUrl } else { "https://helpdesk.image.local" }
$KaceOrganization   = if ($config.KaceOrganization) { $config.KaceOrganization } else { "Default" }
$KaceApiVersion     = if ($config.KaceApiVersion) { $config.KaceApiVersion } else { "5" }
$KacePageLimit      = if ($config.KacePageLimit) { $config.KacePageLimit } else { 1000 }
# Only load from DPAPI if Key Vault did not already populate these
$KaceUsername = Resolve-SecretWithFallback -Name "KACE Username" -CurrentValue $KaceUsername -DpapiPath (Join-Path $SecureDataFolder "KaceUser.bin")
$KacePassword = Resolve-SecretWithFallback -Name "KACE Password" -CurrentValue $KacePassword -DpapiPath (Join-Path $SecureDataFolder "KacePw.bin")

$VerbosePaging       = $true    # prints paging URLs and counts for KACE/Sophos

# ---- EventSentry PostgreSQL (inventory enrichment) ----
$EventSentryDbHost = $config.EventSentryDbHost
$EventSentryDbPort = if ($config.EventSentryDbPort) { [int]$config.EventSentryDbPort } else { 5432 }
$EventSentryDbName = if ($config.EventSentryDbName) { $config.EventSentryDbName } else { "EventSentry" }
# DPAPI fallback (create this bin similarly to your others)
$EventSentryDbUser = Resolve-SecretWithFallback -Name "EventSentry DB User" -CurrentValue $EventSentryDbUser -DpapiPath (Join-Path $SecureDataFolder "EventSentryDbUser.bin")
$EventSentryDbPassword = Resolve-SecretWithFallback -Name "EventSentry DB Password" -CurrentValue $EventSentryDbPassword -DpapiPath (Join-Path $SecureDataFolder "EventSentryDbPassword.bin")
# Build connection string only if we have minimum fields
$EventSentryConnString = $null
if ($EventSentryDbHost -and $EventSentryDbUser -and $EventSentryDbPassword) {
    $EventSentryConnString = "Host=$EventSentryDbHost;Port=$EventSentryDbPort;Username=$EventSentryDbUser;Password=$EventSentryDbPassword;Database=$EventSentryDbName;Timeout=10;Command Timeout=30"
}

# Report prefix for cleanup of old files (e.g., if prefix is "DeviceScope_Merged", it will target files like "DeviceScope_Merged_20240601.csv")
$ReportPrefix = [IO.Path]::GetFileNameWithoutExtension($MergedExportPath) # "DeviceScope_Merged"

# Logging
New-Item -ItemType Directory -Path $LogsFolder -Force | Out-Null

# ==============================
# Entra + Intune (Microsoft Graph REST API)
# ==============================
$entraFlat  = @()
$intuneFlat = @()
try {
    # If we have a client secret, use the OAuth token endpoint. Otherwise, if Az session is available
    # (certificate-based Connect-AzAccount succeeded), use Get-AzAccessToken to get a Graph token.
    if (-not ($MgTenantId -and $MgClientId) -and -not $MgClientSecret) {
        Write-Warning "Missing Graph identifiers; skipping Entra/Intune."
    } else {
        if ($MgClientSecret) {
            # Get access token using client credentials (client secret)
            try {
                $tokenBody = @{ client_id = $MgClientId; client_secret = $MgClientSecret; scope = "https://graph.microsoft.com/.default"; grant_type = "client_credentials" }
                $tokenResp = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$MgTenantId/oauth2/v2.0/token" -Body $tokenBody
                $accessToken = $tokenResp.access_token
                $headers = @{ Authorization = "Bearer $accessToken" }
            } catch {
                Write-Warning "Failed to acquire token via client_secret: $($_.Exception.Message)"
                $accessToken = $null; $headers = $null
            }
        } else {
            # No client secret: attempt to use Az module's Get-AzAccessToken (certificate auth via Connect-AzAccount)
            try {
                $at = Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue
                if ($at) {
                    $t = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/"
                    if ($t -and $t.Token) {
                        # Convert SecureString token to plaintext safely
                        $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($t.Token)
                        try {
                            $accessToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto($tokenPtr)
                        } finally {
                            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
                        }
                        $headers = @{ Authorization = "Bearer $accessToken" }
                        Write-Output "Acquired Graph token via certificate (Get-AzAccessToken)"
                    } else {
                        Write-Warning "Get-AzAccessToken returned no token. Skipping Entra/Intune."
                        $accessToken = $null; $headers = $null
                    }
                } else {
                    Write-Warning "Get-AzAccessToken not available. Ensure Az.Accounts module is loaded and authenticated. Skipping Entra/Intune."
                    $accessToken = $null; $headers = $null
                }
            } catch {
                Write-Warning "Failed to acquire token via Az module: $($_.Exception.Message)"
                $accessToken = $null; $headers = $null
            }
        }
        
        if (-not $headers) {
            Write-Warning "No access token available; skipping Entra/Intune."
            $entraFlat = @()
            $intuneFlat = @()
        } else {
            $uri = "https://graph.microsoft.com/v1.0/devices?`$select=*"
            do {
                $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
                if ($resp.value) { $entraAll += $resp.value }
                $uri = $resp.'@odata.nextLink'
            } while ($uri)

            $entraFlat = $entraAll | ForEach-Object {
                $flat = FlattenObject -obj $_ -prefix 'Entra'
                $flat['Source'] = 'Entra'
                [PSCustomObject]$flat
            }

            # Fetch Intune managed devices with pagination
            $intuneAll = @()
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=*"
            do {
                $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
                if ($resp.value) { $intuneAll += $resp.value }
                $uri = $resp.'@odata.nextLink'
            } while ($uri)

            $intuneFlat = $intuneAll | ForEach-Object {
                $flat = FlattenObject -obj $_ -prefix 'Intune'
                $flat['Source'] = 'Intune'
                [PSCustomObject]$flat
            }

            Write-Output "Entra: fetched $($entraFlat.Count) devices; Intune: fetched $($intuneFlat.Count) devices"
        }
    }
} catch {
    Write-Warning "Graph REST calls failed: $($_.Exception.Message). Continuing without Entra/Intune."
}

# ==============================
# Active Directory (on-prem)
# ==============================
$adFlat = @()
try {
    #Import-Module ActiveDirectory -ErrorAction SilentlyContinue | Out-Null
    $adRaw = Get-ADComputer -Filter * -Properties *
    $adFlat = $adRaw | ForEach-Object {
        $flat = FlattenObject -obj $_ -prefix 'AD'
        $flat['Source'] = 'AD'

        $dn = $flat['AD.DistinguishedName']

        $ouName = Get-FirstOUNameFromDN $dn
        $ouPath = Get-OUPathFromDN $dn -RootToLeaf  # request root -> leaf
        $locFromOu = DeriveLocationFromOU $ouName $ouPath

        $flat['AD.OUName'] = $ouName
        $flat['AD.OUPath'] = $ouPath
        $flat['AD.LocationFromOU'] = $locFromOu

        [PSCustomObject]$flat
    }
} catch {
    Write-Warning "AD query failed: $($_.Exception.Message). Continuing without AD."
}

# ==============================
# Sophos Central
# ==============================
$sophosFlat   = @()
try {
    # Obtain OAuth2 Access
    # Token
    $body = @{ grant_type = 'client_credentials'; client_id = $SophosClientId; client_secret = $SophosClientSecret; scope = 'token' }
    $tokenResp = Invoke-RestMethod -Uri "https://id.sophos.com/api/v2/oauth2/token" -Method Post -Body $body
    $accessToken = $tokenResp.access_token

    # whoami -> region host + tenant id
    $whoHeaders = @{ Authorization = "Bearer $accessToken" }
    $whoamiResp = Invoke-RestMethod -Uri "https://api.central.sophos.com/whoami/v1" -Headers $whoHeaders
    $tenantId   = $whoamiResp.id
    $regionHost = $whoamiResp.apiHosts.dataRegion   # e.g., https://api-us01.central.sophos.com

    # endpoints with pagination (pageFromKey)
    $headersSophos = @{ Authorization = "Bearer $accessToken"; 'X-Tenant-ID' = $tenantId }
    $allEndpoints = @(); $nextKey = $null
    do {
        $uri = "$regionHost/endpoint/v1/endpoints?view=full&pageSize=500"
        if ($nextKey) { $uri += "&pageFromKey=$nextKey" }
        if ($VerbosePaging) { Write-Output "[Sophos] GET $uri" }
        $resp = Invoke-RestMethod -Uri $uri -Headers $headersSophos
        if ($resp.items) { $allEndpoints += $resp.items }
        $nextKey = $resp.pages.nextKey
    } while ($nextKey)

    $sophosFlat = $allEndpoints | ForEach-Object {
        $flat = FlattenObject -obj $_ -prefix 'Sophos'
        $flat['Source'] = 'Sophos'
        [PSCustomObject]$flat
    }

    # Clear secrets
    $SophosClientId = $null; $SophosClientSecret = $null

} catch {
    Write-Warning "Sophos calls failed: $($_.Exception.Message). Continuing without Sophos."
}

# ==============================
# KACE SMA
# ==============================
# Helper to normalize KACE machine response into array
# Note: KACE rarely has duplicates if naming convention is clean; instance counts for KACE are commented out below
function Convert-ToMachineArray($resp) {
    if ($null -eq $resp) { return @() }
    if ($resp -is [System.Collections.IEnumerable]) { return @($resp) }
    if ($resp.Machines) { return @($resp.Machines) }
    return @($resp)
}

$kaceFlat = @()
try {
    # KACE AMS session + inventory retrieval
    $sessionKace = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $headersKace = @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json'; 'x-kace-api-version' = $KaceApiVersion }

    # AMS login
    $loginUri = "$KaceBaseUrl/ams/shared/api/security/login"
    # $loginBody = @{ userName = $credKace.UserName; password = $plainPassword; organizationName = $KaceOrganization } | ConvertTo-Json
    $loginBody = @{ userName = $KaceUsername; password = $KacePassword; organizationName = $KaceOrganization } | ConvertTo-Json
    $loginResp = Invoke-RestMethod -Method Post -Uri $loginUri -Headers $headersKace -Body $loginBody -WebSession $sessionKace

    # Clear secrets
    $KaceUsername = $null; $KacePassword = $null

    if (-not $loginResp) {
        throw "KACE AMS login failed: $($loginResp.message)"
    }

    $allMachines = @()

    # Strategy A: limit ALL
    $uriAll = "$KaceBaseUrl/api/inventory/machines?paging=limit ALL"
    if ($VerbosePaging) { Write-Output "[KACE A] GET $uriAll" }
    try { $respA = Invoke-RestMethod -Method Get -Uri $uriAll -Headers $headersKace -WebSession $sessionKace } catch { $respA = $null }
    $batchA = Convert-ToMachineArray $respA
    if ($batchA.Count -gt 50) { $allMachines = $batchA }

    # Strategy B: limit/offset (space-separated)
    if ($allMachines.Count -eq 0) {
        $offset = 0; $effectiveLimit = $KacePageLimit; $pageIndex = 0
        while ($true) {
            $invUri = "$KaceBaseUrl/api/inventory/machines?paging=limit $effectiveLimit offset $offset"
            if ($VerbosePaging) { Write-Output ('[KACE B] GET {0}' -f $invUri) }
            try { $respB = Invoke-RestMethod -Method Get -Uri $invUri -Headers $headersKace -WebSession $sessionKace } catch { break }
            $batchB = Convert-ToMachineArray $respB
            $countB = $batchB.Count
            if ($VerbosePaging) { Write-Output ('[KACE B] Page {0}: {1} items (offset {2}, limit {3})' -f $pageIndex, $countB, $offset, $effectiveLimit) }
            if ($countB -eq 0) { break }
            if ($pageIndex -eq 0 -and $countB -lt $effectiveLimit) { $effectiveLimit = $countB }
            $allMachines += $batchB
            $offset += $countB
            $pageIndex++
        }
    }

    # Strategy C: pageSize + page
    if ($allMachines.Count -eq 0) {
        $page = 1; $effectiveSize = $KacePageLimit
        while ($true) {
            $invUri = "$KaceBaseUrl/api/inventory/machines?page=$page&pageSize=$effectiveSize"
            if ($VerbosePaging) { Write-Output ('[KACE C] GET {0}' -f $invUri) }
            try { $respC = Invoke-RestMethod -Method Get -Uri $invUri -Headers $headersKace -WebSession $sessionKace } catch { break }
            $batchC = Convert-ToMachineArray $respC
            $countC = $batchC.Count
            if ($VerbosePaging) { Write-Output ('[KACE C] Page {0}: {1} items (pageSize {2})' -f $page, $countC, $effectiveSize) }
            if ($countC -eq 0) { break }
            if ($page -eq 1 -and $countC -lt $effectiveSize) { $effectiveSize = $countC }
            $allMachines += $batchC
            $page++
        }
    }

    $kaceFlat = $allMachines | ForEach-Object {
        $flat = FlattenObject -obj $_ -prefix 'KACE'
        $flat['Source'] = 'KACE'
        [PSCustomObject]$flat
    }

} catch {
    Write-Warning "KACE calls failed: $($_.Exception.Message). Continuing without KACE."
}

# ==============================
# EventSentry (PostgreSQL) - Inventory Enrichment ONLY
# ==============================
$eventsentryFlat = @()
try {
    if (-not $EventSentryConnString) {
        Write-Warning "EventSentry connection not configured (missing host/user/password). Skipping EventSentry."
    } else {
        Import-EventSentryPostgresAssemblies

        $sql = @"
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
LEFT JOIN eventsentry.essysinfo si
  ON si.computer = c.id
"@

        $rows = Invoke-EventSentryQuery -ConnectionString $EventSentryConnString -Sql $sql

        # Convert to your standard flattened format
        $eventsentryFlat = @($rows | ForEach-Object {
            $flat = FlattenObject -obj $_ -prefix 'EventSentry'
            $flat['Source'] = 'EventSentry'
            [PSCustomObject]$flat
        })

        $beforeCount = $eventsentryFlat.Count

        # ✅ --- CLEAN UP EVENTSENTRY GARBAGE ENTRIES ---
        $eventsentryFlat = $eventsentryFlat | Where-Object {
            $hostname = ($_.'EventSentry.hostname' | ForEach-Object { ($_ -as [string]).Trim() })

            $hostname -and
            $hostname -notmatch '^MININT-' -and
            $hostname -ne '-' -and
            $hostname -ne '' -and
            $hostname -notmatch '^[0-9]+$' -and
            $hostname -match '^[A-Za-z0-9\-]+$'
        }
        # Note: if you have a lot of garbage entries, consider adding more filters above (e.g., exclude names with lots of special chars, or very short names, etc.)

        $afterCount = $eventsentryFlat.Count

        Write-Output "EventSentry cleanup: removed $(($beforeCount - $afterCount)) invalid rows"

        Write-Output "EventSentry: fetched $($eventsentryFlat.Count) inventory rows"
    }
}
catch {
    Write-Warning "EventSentry query failed: $($_.Exception.Message). Continuing without EventSentry."
}
finally {
    # clear password from memory
    $EventSentryDbPassword = $null
}

# -------------------------------
# Per-source name selectors
# -------------------------------
# Using scriptblocks keeps it PS 5.1-friendly and explicit

$NameSelectors = @{
    Entra       = { param($row) NormalizeDisplayName  $row.'Entra.DisplayName' }
    Intune      = { param($row) NormalizeComputerName $row.'Intune.deviceName' }
    AD          = { param($row) NormalizeComputerName $row.'AD.Name' }
    Sophos      = { param($row) NormalizeComputerName $row.'Sophos.hostname' }
    KACE        = { param($row) NormalizeComputerName $row.'KACE.Name' }
    EventSentry = { param($row) NormalizeComputerName $row.'EventSentry.hostname' }
}

# -------------------------------
# Build source indexes (explicit)
# -------------------------------
# Build representative (single-row) indexes as before
$hEntra       = IndexByNameKey $entraFlat  $NameSelectors['Entra']
$hIntune      = IndexByNameKey $intuneFlat $NameSelectors['Intune']
$hAD          = IndexByNameKey $adFlat     $NameSelectors['AD']
$hSophos      = IndexByNameKey $sophosFlat $NameSelectors['Sophos']
$hKACE        = IndexByNameKey $kaceFlat   $NameSelectors['KACE']
$hEventSentry = IndexByNameKey $eventsentryFlat $NameSelectors['EventSentry']

# # Union of all normalized name keys
# $keys = @($hEntra.Keys + $hIntune.Keys + $hAD.Keys + $hSophos.Keys + $hKACE.Keys) | Sort-Object -Unique

# Build multi-row (all instances) indexes for per-source duplication analysis
$gEntra       = IndexByNameKeyMulti $entraFlat  $NameSelectors['Entra']
$gIntune      = IndexByNameKeyMulti $intuneFlat $NameSelectors['Intune']
$gAD          = IndexByNameKeyMulti $adFlat     $NameSelectors['AD']
$gSophos      = IndexByNameKeyMulti $sophosFlat $NameSelectors['Sophos']
$gKACE        = IndexByNameKeyMulti $kaceFlat   $NameSelectors['KACE']
$gEventSentry = IndexByNameKeyMulti $eventsentryFlat $NameSelectors['EventSentry']

# Union of all normalized name keys (use multi-row indexes to catch names that exist only as duplicates)
$keys = @( $gEntra.Keys + $gIntune.Keys + $gAD.Keys + $gSophos.Keys + $gKACE.Keys + $gEventSentry.Keys ) | Sort-Object -Unique

# -------------------------------
# Merge by NameKey and compute presence flags
# -------------------------------
$merged = foreach ($k in $keys) {
    # Representative rows (for your existing snapshot columns)
    $e = $hEntra[$k];   $i = $hIntune[$k];   $d = $hAD[$k];   $s = $hSophos[$k];   $c = $hKACE[$k];   $es = $hEventSentry[$k]

    # All instances per source for this NameKey
    $listE = $gEntra[$k];   $listI = $gIntune[$k];   $listD = $gAD[$k];   $listS = $gSophos[$k] # ;   $listC = $gKACE[$k]

    $InEntra       = [bool]$e
    $InIntune      = [bool]$i
    $InAD          = [bool]$d
    $InSophos      = [bool]$s
    $InKACE        = [bool]$c
    $InEventSentry = [bool]$es
    # EventSentry presence (inventory-aware)
    $EventSentry_AgentPresent = [bool]($es.'EventSentry.agentVersion' -and $es.'EventSentry.agentVersion'.Trim() -ne "")
    $EventSentry_InventoryTimestamp = $es.'EventSentry.inventoryTimestamp'

    # Presence bitfield: Entra=1, Intune=2, AD=4, Sophos=8, KACE=16, EventSentry=32
    $PresenceBits =
        ([int]$InEntra)*1        +
        ([int]$InIntune)*2       +
        ([int]$InAD)*4           +
        ([int]$InSophos)*8       +
        ([int]$InKACE)*16        +
        ([int]$InEventSentry)*32

    $contexts = @()
    if ($InEntra)       { $contexts += 'Entra'  }
    if ($InIntune)      { $contexts += 'Intune' }
    if ($InAD)          { $contexts += 'AD'     }
    if ($InSophos)      { $contexts += 'Sophos' }
    if ($InKACE)        { $contexts += 'KACE'   }
    if ($InEventSentry) { $contexts += 'EventSentry' }
    $Contexts = ($contexts -join ' | ')

    # --- Duplication analysis ---

    # ENTRA: counts by trust/join type
    $entraDeviceIdsAll = @()
    $entraHybridRows   = @()
    $entraRegisteredRows = @()
    $entraOtherRows    = @()

    foreach ($rowE in @($listE)) {
        $entraDeviceIdsAll += @($rowE.'Entra.DeviceId')
        $trust = $rowE.'Entra.trustType'
        $join  = $rowE.'Entra.joinType'
        # Hybrid signals: trustType 'ServerAd' OR joinType contains 'Hybrid'
        if      ($trust -eq 'ServerAd' -or ($join -match 'Hybrid'))            { $entraHybridRows     += $rowE }
        # Registered signals: trustType 'Workplace' OR joinType contains 'Registered'
        elseif  ($trust -eq 'Workplace' -or ($join -match 'Registered'))       { $entraRegisteredRows += $rowE }
        else                                                                   { $entraOtherRows      += $rowE }
    }

    $Entra_InstanceCount     = @($listE).Count
    $Entra_HybridCount       = @($entraHybridRows).Count
    $Entra_RegisteredCount   = @($entraRegisteredRows).Count
    $Entra_DeviceIds         = ($entraDeviceIdsAll | Where-Object { $_ } | Select-Object -Unique) -join '; '

    # AD ObjectGUIDs (string) for same NameKey
    $adGuids = @()
    foreach ($rowD in @($listD)) {
        $g = $rowD.'AD.ObjectGUID'
        if ($g) { $adGuids += $g.ToString() }
    }
    $adGuids = $adGuids | Select-Object -Unique

    # Hybrid DeviceId match/mismatch vs AD.ObjectGUID
    $hybridIds = ($entraHybridRows | ForEach-Object { $_.'Entra.DeviceId' }) | Where-Object { $_ }
    $Entra_HybridIdMatchesAD       = ($hybridIds | Where-Object { $adGuids -contains $_ }) | Select-Object -First 1 | ForEach-Object { $true }
    if ($null -eq $Entra_HybridIdMatchesAD) { $Entra_HybridIdMatchesAD = $false }

    $Entra_HybridIdMismatchExists  = ($hybridIds | Where-Object { -not ($adGuids -contains $_) }) | Select-Object -First 1 | ForEach-Object { $true }
    if ($null -eq $Entra_HybridIdMismatchExists) { $Entra_HybridIdMismatchExists = $false }

    # Overall Entra duplicate flag: more than one instance OR both hybrid & registered present OR more than one hybrid
    $Entra_DuplicateFlag = ($Entra_InstanceCount -gt 1) -or (($Entra_HybridCount -gt 0) -and ($Entra_RegisteredCount -gt 0)) -or ($Entra_HybridCount -gt 1)

    # INTUNE: instance count and link checks against Entra DeviceIds
    $Intune_InstanceCount = @($listI).Count
    $intuneAzureIds = ($listI | ForEach-Object { $_.'Intune.azureADDeviceId' }) | Where-Object { $_ }
    $Intune_AzureADDeviceIds = ($intuneAzureIds | Select-Object -Unique) -join '; '

    $entraIdsForLink = @($entraDeviceIdsAll | Where-Object { $_ }) | Select-Object -Unique
    $Intune_AzureADLinkMatchesEntraCount = (@($intuneAzureIds | Where-Object { $entraIdsForLink -contains $_ })).Count
    $Intune_AzureADLinkMismatchCount     = (@($intuneAzureIds | Where-Object { $_ -and -not ($entraIdsForLink -contains $_) })).Count
    $Intune_DuplicateFlag = ($Intune_InstanceCount -gt 1) -or ($Intune_AzureADLinkMismatchCount -gt 0)

    # SOPHOS: instance count & duplicate flag
    $Sophos_InstanceCount = @($listS).Count
    $Sophos_DuplicateFlag = ($Sophos_InstanceCount -gt 1)
    $Sophos_Ids = (($listS | ForEach-Object { $_.'Sophos.id' }) | Where-Object { $_ } | Select-Object -Unique) -join '; '

    # %%% KACE really shouldn't have any duplicates if the naming is well-managed
    # # (Optional) KACE duplicate info for consistency
    # $KACE_InstanceCount = @($listC).Count
    # $KACE_DuplicateFlag = ($KACE_InstanceCount -gt 1)
    # $KACE_IDs = (($listC | ForEach-Object { $_.'KACE.Id' }) | Where-Object { $_ } | Select-Object -Unique) -join '; '

    # Global flag: any source has multiple instances
    $MultiInstanceFlag = ($Entra_InstanceCount -gt 1) -or ($Intune_InstanceCount -gt 1) -or ($Sophos_InstanceCount -gt 1) # -or ($KACE_InstanceCount -gt 1)

    # Display name = the normalized key we merged on
    $Name = $k

    # Overview fields (existing logic retained)
    $DeviceType = Get-DeviceType -es $es -c $c -d $d -s $s -e $e
    $OS = Get-AnyReadableFromSources @($i,$e,$d,$s,$c) @(
        'Intune.operatingSystem','Entra.OperatingSystem','AD.OperatingSystem','Sophos.os.name','KACE.Os_name'
    )
    $SerialNumber = Get-AnyReadableFromSources @($i,$s,$c) @(
        'Intune.serialNumber','Sophos.serialNumber','KACE.ServiceTag'
    )
    $PrimaryUser = Get-AnyReadableFromSources @($i,$s,$e,$c) @('Intune.userPrincipalName','Sophos.associatedPerson.name','Entra.userNames','KACE.User')
    $Location = Get-AnyReadableFromSources @($d,$c) @('AD.physicalDeliveryOfficeName','AD.LocationFromOU','KACE.Location')
    $LastSeen = Get-AnyReadableFromSources @($i,$s,$e,$c) @(
        'Intune.lastSyncDateTime','Sophos.lastSeenAt','Entra.approximateLastSignInDateTime','KACE.LastInventory'
    )

    $Memory = Get-AnyReadableFromSources @($es,$c) @('EventSentry.totalMemory','KACE.Ram Total'
    )

    # Snapshot fields from EventSentry inventory (enrichment)
    $EventSentry_AgentVersion = Get-AnyFromSources @($es) @('EventSentry.agentVersion')
    $EventSentry_InventoryTimestamp = Get-AnyFromSources @($es) @('EventSentry.inventoryTimestamp')
    $EventSentry_Manufacturer = Get-AnyFromSources @($es) @('EventSentry.manufacturer')
    $EventSentry_Model        = Get-AnyFromSources @($es) @('EventSentry.model')
    $EventSentry_OS           = Get-AnyFromSources @($es) @('EventSentry.os','EventSentry.osEdition')
    $EventSentry_TotalMemory  = Get-AnyFromSources @($es) @('EventSentry.totalMemory')
    $EventSentry_BitLocker    = Get-AnyFromSources @($es) @('EventSentry.bitlocker')
    $EventSentry_Uptime       = Get-AnyFromSources @($es) @('EventSentry.uptime')

    # --- Staleness analysis for EventSentry inventory data ---
    $StaleThresholdDays = 7
    $EventSentry_AgeDays = $null
    $EventSentry_Stale = $false

    # Consider agent "present" if we have a version string
    $EventSentry_AgentPresent = [bool]($EventSentry_AgentVersion -and ($EventSentry_AgentVersion.ToString().Trim() -ne ""))

    $tsRaw = $EventSentry_InventoryTimestamp

    if ($tsRaw -and $tsRaw -ne [DBNull]::Value) {

        $ts = $null

        if ($tsRaw -is [datetime]) {
            $ts = $tsRaw
        }
        else {
            # Safe parse for string timestamps
            if ([datetime]::TryParse($tsRaw.ToString(), [ref]$ts)) {
                # parsed successfully
            }
        }

        if ($ts) {
            $age = (Get-Date) - $ts

            if ($age.TotalDays -lt 0) {
                $EventSentry_AgeDays = 0
                $EventSentry_Stale = $false
            }
            else {
                $EventSentry_AgeDays = [math]::Round($age.TotalDays, 1)

                if ($EventSentry_AgentPresent -and $age.TotalDays -gt $StaleThresholdDays) {
                    $EventSentry_Stale = $true
                }
                else {
                    $EventSentry_Stale = $false
                }
            }
        }
        elseif ($EventSentry_AgentPresent -and $tsRaw) {
            # timestamp exists but couldn't be parsed → treat as stale
            $EventSentry_Stale = $true
        }

    }
    elseif ($EventSentry_AgentPresent) {
        # Agent present but no inventory timestamp → treat as stale
        $EventSentry_Stale = $true
    }

    # --- Cross-source analysis ---
    # Active elsewhere
    $IsActiveElsewhere = ($InIntune -or $InEntra -or $InAD)

    # Anomaly: stale in EventSentry while the device is active elsewhere
    $Anomaly_ES_StaleWhileActive = (
        $EventSentry_AgentPresent -and
        $EventSentry_Stale -and
        $IsActiveElsewhere
    )

    # Anomaly: missing EventSentry agent while the device is active elsewhere   
    $IsMobileLike = ($DeviceType -eq 'RegisteredDevice') -or ($OS -match 'Android|IPhone|IPad')
    $Anomaly_ES_MissingWhileActive = ((-not $EventSentry_AgentPresent) -and $IsActiveElsewhere -and (-not $IsMobileLike))

    
    [PSCustomObject]@{
        # --- Core (existing) ---
        Name = $Name
        SerialNumber = $SerialNumber
        PresenceBits = $PresenceBits
        Contexts = $Contexts
        InEntra = $InEntra
        InIntune = $InIntune
        InAD = $InAD
        InSophos = $InSophos
        InKACE = $InKACE
        InEventSentry = $InEventSentry
        DeviceType = $DeviceType
        OS = $OS
        Memory = $Memory
        LastSeen = $LastSeen
        PrimaryUser = $PrimaryUser
        Location = $Location
        # Status = ''

        # --- New duplication monitoring ---
        MultiInstanceFlag = $MultiInstanceFlag

        Entra_InstanceCount = $Entra_InstanceCount
        Entra_HybridCount = $Entra_HybridCount
        Entra_RegisteredCount = $Entra_RegisteredCount
        Entra_DuplicateFlag = $Entra_DuplicateFlag
        Entra_DeviceIds = $Entra_DeviceIds
        Entra_HybridIdMatchesAD = $Entra_HybridIdMatchesAD
        Entra_HybridIdMismatchExists = $Entra_HybridIdMismatchExists

        Intune_InstanceCount = $Intune_InstanceCount
        Intune_DuplicateFlag = $Intune_DuplicateFlag
        Intune_AzureADLinkMatchesEntraCount = $Intune_AzureADLinkMatchesEntraCount
        Intune_AzureADLinkMismatchCount = $Intune_AzureADLinkMismatchCount
        Intune_AzureADDeviceIds = $Intune_AzureADDeviceIds

        Sophos_InstanceCount = $Sophos_InstanceCount
        Sophos_DuplicateFlag = $Sophos_DuplicateFlag
        Sophos_Ids = $Sophos_Ids

        # KACE_InstanceCount = $KACE_InstanceCount
        # KACE_DuplicateFlag = $KACE_DuplicateFlag
        # KACE_IDs = $KACE_IDs

        # --- Snapshot fields (existing) ---
        Entra_DeviceId = Get-AnyFromSources @($e) @('Entra.DeviceId')
        Entra_JoinType = Get-AnyFromSources @($e) @('Entra.joinType','Entra.trustType')
        Entra_OperatingSystem = Get-AnyFromSources @($e) @('Entra.OperatingSystem')
        Entra_OperatingSystemVersion = Get-AnyFromSources @($e) @('Entra.OperatingSystemVersion')
        Entra_IsManaged = Get-AnyFromSources @($e) @('Entra.isManaged')
        Entra_IsCompliant = Get-AnyFromSources @($e) @('Entra.isCompliant')
        Entra_LastSignIn = Get-AnyFromSources @($e) @('Entra.approximateLastSignInDateTime')

        Intune_DeviceId = Get-AnyFromSources @($i) @('Intune.id')
        Intune_DeviceName = Get-AnyFromSources @($i) @('Intune.deviceName')
        Intune_OperatingSystem = Get-AnyFromSources @($i) @('Intune.operatingSystem')
        Intune_ComplianceState = Get-AnyFromSources @($i) @('Intune.complianceState')
        Intune_ManagementAgent = Get-AnyFromSources @($i) @('Intune.managementAgent')
        Intune_LastSync = Get-AnyFromSources @($i) @('Intune.lastSyncDateTime')

        AD_Name = Get-AnyFromSources @($d) @('AD.Name')
        AD_DNSHostName = Get-AnyFromSources @($d) @('AD.DNSHostName')
        AD_OperatingSystem = Get-AnyFromSources @($d) @('AD.OperatingSystem')
        AD_LastLogonDate = Get-AnyFromSources @($d) @('AD.LastLogonDate')
        AD_Enabled = Get-AnyFromSources @($d) @('AD.Enabled')
        AD_ObjectGUID = Get-AnyFromSources @($d) @('AD.ObjectGUID')

        Sophos_Id = Get-AnyFromSources @($s) @('Sophos.id')
        Sophos_Hostname = Get-AnyFromSources @($s) @('Sophos.hostname')
        Sophos_OS = Get-AnyFromSources @($s) @('Sophos.os.name')
        Sophos_LastSeenAt = Get-AnyFromSources @($s) @('Sophos.lastSeenAt')
        Sophos_Health = Get-AnyFromSources @($s) @('Sophos.health.overall')
        Sophos_ipv4Addresses = Get-AnyFromSources @($s) @('Sophos.ipv4Addresses')

        KACE_ID = Get-AnyFromSources @($c) @('KACE.Id')
        KACE_Machine_Name = Get-AnyFromSources @($c) @('KACE.Name')
        KACE_Os_name = Get-AnyFromSources @($c) @('KACE.Os_name')
        KACE_Machine_Ip = Get-AnyFromSources @($c) @('KACE.Ip')
        KACE_Machine_RAM_Used = Get-AnyFromSources @($c) @('KACE.Ram_used')
        KACE_Machine_RAM_Total = Get-AnyFromSources @($c) @('KACE.Ram Total')
        KACE_LastInventory = Get-AnyFromSources @($c) @('KACE.Last_inventory')

        EventSentry_AgentPresent       = $EventSentry_AgentPresent
        EventSentry_AgentVersion       = $EventSentry_AgentVersion
        EventSentry_InventoryTimestamp = $EventSentry_InventoryTimestamp
        EventSentry_AgeDays            = $EventSentry_AgeDays
        EventSentry_Stale              = $EventSentry_Stale

        EventSentry_Manufacturer       = $EventSentry_Manufacturer
        EventSentry_Model              = $EventSentry_Model
        EventSentry_OS                 = $EventSentry_OS
        EventSentry_TotalMemory        = $EventSentry_TotalMemory
        EventSentry_BitLocker          = $EventSentry_BitLocker
        EventSentry_Uptime             = $EventSentry_Uptime

        Anomaly_ES_StaleWhileActive    = $Anomaly_ES_StaleWhileActive
        Anomaly_ES_MissingWhileActive  = $Anomaly_ES_MissingWhileActive
    }
}

# Timestamped filename (Local time zone)
$stamp = (Get-Date).ToString("yyyy-MM-dd_HHmmss")
$RemoteName = "{0}_{1}.csv" -f $ReportPrefix, $stamp
$TimestampedExportPath = Join-Path (Split-Path $MergedExportPath) $RemoteName

# Export
$merged | Export-Csv -Path $TimestampedExportPath -NoTypeInformation
Write-Output "DeviceScope_Merged.csv written to: $TimestampedExportPath (presence by AD.Name, Entra.DisplayName, Intune.deviceName, KACE.Name, Sophos.hostname, EventSentry.hostname)"

# Clean up old data folder reports
Remove-CleanupOldLocalFiles -FolderPath $dataFolder -Prefix "DeviceScope_Merged" -Days 2

# Clear sensitive Graph values and hint GC
    $accessToken = $null
    $MgClientSecret = $null
    # Nudge GC after handling sensitive file content in memory
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
