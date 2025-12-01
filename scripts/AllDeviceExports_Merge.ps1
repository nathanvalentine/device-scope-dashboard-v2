<#
AllDeviceExports_Merge.ps1

Purpose:
  - Export device data from Entra (Azure AD), Intune, AD (on-prem), Sophos Central, and KACE SMA.
  - Flatten all nested properties into CSV-friendly rows.
  - Namespace columns per source (Entra.*, Intune.*, AD.*, Sophos.*, KACE.*) and add Source field.
  - Support variables-only configuration (no param() block).
  - Optional PowerShell SecretManagement use for non-interactive secrets.
  - Robust paging for KACE and Sophos, -All for Graph SDK calls.
  - Merge into one CSV with DuplicateCount and DeviceKey computed from serial/hostname.

Notes:
  - Requires: Microsoft.Graph PowerShell SDK, ActiveDirectory module, internet connectivity for Sophos + Entra/Intune.
  - KACE SMA: cookie-based session after AMS login; include x-kace-api-version on each request.
  - Sophos: OAuth2 client credentials -> access token -> whoami for region host and tenant ID.
  - Adjust variables in the CONFIG section below to match your environment.
#>

# ==============================
# Utility Functions
# ==============================
function EnsureModule {
    param([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Host "Installing missing module: $ModuleName"
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
# ---- DPAPI Helper ----
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
function Cleanup-OldLocalFiles {
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
            Write-Host "Deleting old file: $($file.FullName) (LastWriteTime=$($file.LastWriteTime))"
            Remove-Item $file.FullName -Force
        }
    }
}

# --------------------------------
# Helper: Upload DeviceScope_Merged.csv to SharePoint via Graph REST
# --------------------------------
function Write-UploadLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] {1}" -f $ts, $Message
    $line | Add-Content -Path $UploadLogPath
}

# Small utility: sanitize any odd URL characters
function CleanUrl {
    param([string]$Url)
    if (-not $Url) { return $Url }
    # Remove LRM/RLM and trim
    $Url -replace "[\u200E\u200F]", "" | ForEach-Object { $_.Trim() }
}

# Convert a SharePoint sharing link to Graph shares token (u! + base64url)
# Ref: Access shared items (shares API) encoding guidance. [3](https://learn.microsoft.com/en-us/graph/api/shares-get?view=graph-rest-1.0)
function Convert-ShareUrlToShareId {
    param([Parameter(Mandatory=$true)][string]$Url)
    $clean = CleanUrl $Url
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($clean))
    $b64url = $b64.TrimEnd('=').Replace('/','_').Replace('+','-')
    "u!$b64url"
}

# Acquire Graph app-only token using client_credentials
function Get-GraphAccessToken {
    param(
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$ClientSecret  # Optional: if not provided, attempt certificate-based auth
    )
    
    if ($ClientSecret) {
        # Use client_secret flow (legacy)
        try {
            $body = @{
                client_id     = $ClientId
                client_secret = $ClientSecret
                scope         = "https://graph.microsoft.com/.default"
                grant_type    = "client_credentials"
            }
            $resp = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
            return $resp.access_token
        } catch {
            Write-Warning "Failed to acquire Graph token via client_secret: $($_.Exception.Message)"
            return $null
        }
    } else {
        # No client secret: attempt certificate-based auth via Get-AzAccessToken
        try {
            $at = Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue
            if ($at) {
                $t = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/"
                if ($t -and $t.Token) {
                    # Convert SecureString token to plaintext safely
                    $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($t.Token)
                    try {
                        $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($tokenPtr)
                    } finally {
                        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
                    }
                    Write-Host "Acquired Graph token via certificate for SharePoint"
                    return $token
                }
            }
        } catch {
            Write-Warning "Failed to acquire Graph token via Az module: $($_.Exception.Message)"
        }
        return $null
    }
}

# Generic REST invoker with retry/backoff for 429/5xx
function Invoke-GraphWithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Uri,
        [hashtable]$Headers,
        $Body,
        [int]$MaxAttempts = 5,
        [int]$InitialDelayMs = 750
    )

    $attempt = 0
    $delay = $InitialDelayMs
    while ($true) {
        try {
            $attempt++
            Write-UploadLog "HTTP $Method $Uri (attempt $attempt)"
            if ($Body -is [string] -or $Body -is [byte[]]) {
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $Body
            } elseif ($Body) {
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $Body
            } else {
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
            }
        } catch {
            $status = $_.Exception.Response.StatusCode.Value__
            $msg = $_.Exception.Message
            Write-UploadLog "Error ($status): $msg"
            if ($attempt -ge $MaxAttempts -or ($status -lt 500 -and $status -ne 429)) {
                throw
            }
            Start-Sleep -Milliseconds $delay
            $delay = [Math]::Min($delay * 2, 15000)
        }
    }
}

# Resolve the destination folder via the share link
# Returns @{ driveId = "..."; parentId = "..."; webUrl = "..." }
function Resolve-TargetFolder {
    param([Parameter(Mandatory=$true)][string]$ShareUrl, [Parameter(Mandatory=$true)][string]$AccessToken)

    $shareId = Convert-ShareUrlToShareId $ShareUrl
    $headers = @{ Authorization = "Bearer $AccessToken" }
    # GET /shares/{encoded}/driveItem gets the underlying driveItem (folder)
    # Docs: Access shared items (shares API). [3](https://learn.microsoft.com/en-us/graph/api/shares-get?view=graph-rest-1.0)
    $item = Invoke-GraphWithRetry -Method GET -Uri "https://graph.microsoft.com/v1.0/shares/$shareId/driveItem" -Headers $headers
    if (-not $item) { throw "Cannot resolve share link to driveItem." }

    # Extract driveId and parent folder id
    $driveId = $item.parentReference.driveId
    # When the share itself points to a folder, use its 'id' as parent target
    $parentId = $item.id

    return @{ driveId = $driveId; parentId = $parentId; webUrl = $item.webUrl }
}

# Upload a file (small or large) into the folder
# For small files (<=250MB) use single PUT to ...:/content; else use upload session.
# Docs: PUT content for small files; createUploadSession for large files. [1](https://learn.microsoft.com/en-us/graph/api/driveitem-put-content?view=graph-rest-1.0)[2](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0)
function UploadFileToFolder {
    param(
        [Parameter(Mandatory=$true)][string]$DriveId,
        [Parameter(Mandatory=$true)][string]$ParentId,
        [Parameter(Mandatory=$true)][string]$AccessToken,
        [Parameter(Mandatory=$true)][string]$LocalPath,
        [Parameter(Mandatory=$true)][string]$RemoteFileName
    )

    $headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "text/csv" }
    $fi = Get-Item -LiteralPath $LocalPath
    if ($fi.Length -le 262144000) {
        # Small file upload: PUT /drives/{driveId}/items/{parentId}:/{filename}:/content
        $url = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/${ParentId}:/${RemoteFileName}:/content"
        Invoke-GraphWithRetry -Method PUT -Uri $url -Headers $headers -Body ([System.IO.File]::ReadAllBytes($LocalPath)) | Out-Null
        Write-UploadLog "Uploaded (small) $RemoteFileName"
    } else {
        # Large upload: createUploadSession + chunk PUTs. [2](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0)
        $createUrl = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/${ParentId}:/${RemoteFileName}:/createUploadSession"
        $session = Invoke-GraphWithRetry -Method POST -Uri $createUrl -Headers @{ Authorization = "Bearer $AccessToken" } -Body (@{})
        $chunkSize = 8MB
        $fs = [IO.File]::OpenRead($LocalPath)
        try {
            $buffer = New-Object byte[] $chunkSize
            $offset = 0
            while (($read = $fs.Read($buffer,0,$buffer.Length)) -gt 0) {
                $from = $offset
                $to   = $offset + $read - 1
                $total= $fs.Length
                $chunkBody = $buffer[0..($read-1)]
                Invoke-GraphWithRetry -Method PUT -Uri $session.uploadUrl `
                    -Headers @{ "Content-Range" = "bytes $from-$to/$total" } -Body $chunkBody | Out-Null
                $offset += $read
            }
            Write-UploadLog "Uploaded (large) $RemoteFileName"
        } finally {
            $fs.Dispose()
        }
    }
}

# Delete report files older than $RetentionDays based on lastModifiedDateTime
# Lists children of the folder and deletes those matching $ReportPrefix*.csv
# Docs: Working with files (drive & driveItem children). [4](https://mynster9361.github.io/posts/ClientSecretAuthentication/)
function CleanupOldReports {
    param(
        [Parameter(Mandatory=$true)][string]$DriveId,
        [Parameter(Mandatory=$true)][string]$ParentId,
        [Parameter(Mandatory=$true)][string]$AccessToken,
        [Parameter(Mandatory=$true)][string]$Prefix,
        [Parameter(Mandatory=$true)][int]$Days
    )
    $headers = @{ Authorization = "Bearer $AccessToken" }
    $listUrl = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ParentId/children?`$select=name,id,lastModifiedDateTime"
    $items = Invoke-GraphWithRetry -Method GET -Uri $listUrl -Headers $headers

    $cutoff = (Get-Date).AddDays(-$Days)
    foreach ($it in @($items.value)) {
        if ($it.name -like "$Prefix*.csv") {
            $lm = Get-Date $it.lastModifiedDateTime
            if ($lm -lt $cutoff) {
                $delUrl = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$($it.id)"
                Write-UploadLog "Deleting old report: $($it.name) (lastModified=$lm)"
                Invoke-GraphWithRetry -Method DELETE -Uri $delUrl -Headers $headers | Out-Null
            }
        }
    }
}

# ---- Delete the merged export file with error logging ----
function Write-DeleteLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "[{0}] {1}" -f $ts, $Message | Add-Content -Path $DeleteLogPath
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
        Write-Host "Loaded configuration from: $configPath"
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
        Write-Host "Key Vault configuration detected. Preparing Az modules and authenticating..."

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
                Write-Host "Connecting to Azure using certificate thumbprint $BootstrapThumb"
                Connect-AzAccount -ServicePrincipal -Tenant $BootstrapTenantId -ApplicationId $BootstrapClientId -CertificateThumbprint $BootstrapThumb -ErrorAction Stop
                Write-Host "Authenticated to Azure for app $BootstrapClientId"

                # Map secret names from config (expected present)
                $kvSecrets = $config.KeyVaultSecrets
                if ($kvSecrets) {
                    $sophosIdName = $kvSecrets.SophosClientId
                    $sophosSecretName = $kvSecrets.SophosClientSecret
                    $kacePwName = $kvSecrets.KacePassword
                    $entraSecretName = $kvSecrets.EntraClientSecret
                }

                # Fetch runtime secrets from Key Vault
                if ($sophosIdName)     { $SophosClientId     = Get-KeyVaultSecretPlain -VaultName $KeyVaultName -SecretName $sophosIdName }
                if ($sophosSecretName) { $SophosClientSecret = Get-KeyVaultSecretPlain -VaultName $KeyVaultName -SecretName $sophosSecretName }
                if ($kacePwName)       { $KacePassword       = Get-KeyVaultSecretPlain -VaultName $KeyVaultName -SecretName $kacePwName }

                # Entra: if config says 'Certificate-Only' then no client secret is expected
                if ($entraSecretName -and ($entraSecretName -ne 'Certificate-Only')) {
                    $SPClientSecret = Get-KeyVaultSecretPlain -VaultName $KeyVaultName -SecretName $entraSecretName
                } else {
                    # No client secret; rely on certificate for Graph auth where appropriate
                    $SPClientSecret = $null
                }

                # Bootstrapped identifiers
                if ($config.ClientId) { $MgClientId = $config.ClientId }
                if ($config.TenantId) { $MgTenantId = $config.TenantId }
                if ($config.KaceUsername) { $KaceUsername = $config.KaceUsername }

                Write-Host "Key Vault secrets fetched (missing secrets will remain null)."
            } catch {
                Write-Warning "Azure authentication or Key Vault retrieval failed: $($_.Exception.Message). Falling back to DPAPI where available."
            }
        }
    }
} catch {
    Write-Warning "Unexpected error during Key Vault bootstrap: $($_.Exception.Message)"
}# ---- Entra / Intune (Microsoft Graph) ----
# Only load from DPAPI if Key Vault did not already populate these
if (-not $MgTenantId) { $MgTenantId     = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "MgTenantId.bin") }
if (-not $MgClientId) { $MgClientId     = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "MgClientId.bin") }
if (-not $SPClientSecret) { $MgClientSecretPlain = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "MgClientSecret.bin"); $SPClientSecret = $MgClientSecretPlain }
$GraphProfile   = "v1.0"            # or "beta" if needed

# ---- Sophos Central ----
# Only load from DPAPI if Key Vault did not already populate these
if (-not $SophosClientId) { $SophosClientId     = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "SophosClientId.bin") }
if (-not $SophosClientSecret) { $SophosClientSecret = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "SophosClientSecret.bin") }

# ---- KACE SMA ----
$KaceBaseUrl        = if ($config.KaceBaseUrl) { $config.KaceBaseUrl } else { "https://helpdesk.image.local" }
$KaceOrganization   = if ($config.KaceOrganization) { $config.KaceOrganization } else { "Default" }
$KaceApiVersion     = if ($config.KaceApiVersion) { $config.KaceApiVersion } else { "5" }
$KacePageLimit      = if ($config.KacePageLimit) { $config.KacePageLimit } else { 1000 }
# Only load from DPAPI if Key Vault did not already populate these
if (-not $KaceUsername) { $KaceUsername       = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "KaceUser.bin") }
if (-not $KacePassword) { $KacePassword       = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "KacePw.bin") }

$VerbosePaging       = $true    # prints paging URLs and counts for KACE/Sophos

# ---- SharePoint Upload Config ----
# Either hardcode the share link, or load from config file (more portable):
$SharePointConfigFile = Join-Path (Split-Path $PSScriptRoot) "sharepoint.config"
if (Test-Path $SharePointConfigFile) {
    try {
        $spConfig = Get-Content $SharePointConfigFile | ConvertFrom-Json
        $TargetFolderShareLink = $spConfig.TargetFolderShareLink
        if (-not $TargetFolderShareLink) {
            throw "TargetFolderShareLink not set in config."
        }
    } catch {
        Write-Warning "Failed to load SharePoint config from $SharePointConfigFile : $($_.Exception.Message)"
        $TargetFolderShareLink = $null
    }
} else {
    # Fallback to hardcoded value (change as needed)
    $TargetFolderShareLink = "https://cachevalleybank.sharepoint.com/:f:/s/m365appbuilder-devicescope-1110/IgA7_c00SIQ2QKpThfWjiMT-AWleUZWOXmbutpzUKv4akMU?e=CP1wea"
    if (-not $TargetFolderShareLink) {
        Write-Warning "No SharePoint config found and no hardcoded link. Upload will be skipped."
    }
}

# Your local file to upload: use the merged export your script already created
# $LocalCsvPath = $MergedExportPath   # e.g., "C:\...\DeviceScope_Merged.csv"
$ReportPrefix = [IO.Path]::GetFileNameWithoutExtension($MergedExportPath) # "DeviceScope_Merged"
$RetentionDays = if ($config.RetentionDays) { $config.RetentionDays } else { 30 }

# Logging
New-Item -ItemType Directory -Path $LogsFolder -Force | Out-Null
$UploadLogPath = Join-Path $LogsFolder "DeviceScope_Upload.log"
$DeleteLogPath = Join-Path $LogsFolder "DeviceScope_Delete.log"

# ==============================
# Entra + Intune (Microsoft Graph REST API)
# ==============================
$entraFlat  = @()
$intuneFlat = @()
try {
    # If we have a client secret, use the OAuth token endpoint. Otherwise, if Az session is available
    # (certificate-based Connect-AzAccount succeeded), use Get-AzAccessToken to get a Graph token.
    if (-not ($MgTenantId -and $MgClientId) -and -not $SPClientSecret) {
        Write-Warning "Missing Graph identifiers; skipping Entra/Intune."
    } else {
        if ($SPClientSecret) {
            # Get access token using client credentials (client secret)
            try {
                $tokenBody = @{ client_id = $MgClientId; client_secret = $SPClientSecret; scope = "https://graph.microsoft.com/.default"; grant_type = "client_credentials" }
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
                        Write-Host "Acquired Graph token via certificate (Get-AzAccessToken)"
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

            Write-Host "Entra: fetched $($entraFlat.Count) devices; Intune: fetched $($intuneFlat.Count) devices"
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
        if ($VerbosePaging) { Write-Host "[Sophos] GET $uri" }
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
    if ($VerbosePaging) { Write-Host "[KACE A] GET $uriAll" }
    try { $respA = Invoke-RestMethod -Method Get -Uri $uriAll -Headers $headersKace -WebSession $sessionKace } catch { $respA = $null }
    $batchA = Convert-ToMachineArray $respA
    if ($batchA.Count -gt 50) { $allMachines = $batchA }

    # Strategy B: limit/offset (space-separated)
    if ($allMachines.Count -eq 0) {
        $offset = 0; $effectiveLimit = $KacePageLimit; $pageIndex = 0
        while ($true) {
            $invUri = "$KaceBaseUrl/api/inventory/machines?paging=limit $effectiveLimit offset $offset"
            if ($VerbosePaging) { Write-Host ('[KACE B] GET {0}' -f $invUri) }
            try { $respB = Invoke-RestMethod -Method Get -Uri $invUri -Headers $headersKace -WebSession $sessionKace } catch { break }
            $batchB = Convert-ToMachineArray $respB
            $countB = $batchB.Count
            if ($VerbosePaging) { Write-Host ('[KACE B] Page {0}: {1} items (offset {2}, limit {3})' -f $pageIndex, $countB, $offset, $effectiveLimit) }
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
            if ($VerbosePaging) { Write-Host ('[KACE C] GET {0}' -f $invUri) }
            try { $respC = Invoke-RestMethod -Method Get -Uri $invUri -Headers $headersKace -WebSession $sessionKace } catch { break }
            $batchC = Convert-ToMachineArray $respC
            $countC = $batchC.Count
            if ($VerbosePaging) { Write-Host ('[KACE C] Page {0}: {1} items (pageSize {2})' -f $page, $countC, $effectiveSize) }
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

# -------------------------------
# Per-source name selectors
# -------------------------------
# Using scriptblocks keeps it PS 5.1-friendly and explicit

$NameSelectors = @{
    Entra  = { param($row) NormalizeDisplayName  $row.'Entra.DisplayName' }
    Intune = { param($row) NormalizeComputerName $row.'Intune.deviceName' }
    AD     = { param($row) NormalizeComputerName $row.'AD.Name' }
    Sophos = { param($row) NormalizeComputerName $row.'Sophos.hostname' }
    KACE   = { param($row) NormalizeComputerName $row.'KACE.Name' }
}

# -------------------------------
# Build source indexes (explicit)
# -------------------------------
# Build representative (single-row) indexes as before
$hEntra  = IndexByNameKey $entraFlat  $NameSelectors['Entra']
$hIntune = IndexByNameKey $intuneFlat $NameSelectors['Intune']
$hAD     = IndexByNameKey $adFlat     $NameSelectors['AD']
$hSophos = IndexByNameKey $sophosFlat $NameSelectors['Sophos']
$hKACE   = IndexByNameKey $kaceFlat   $NameSelectors['KACE']

# # Union of all normalized name keys
# $keys = @($hEntra.Keys + $hIntune.Keys + $hAD.Keys + $hSophos.Keys + $hKACE.Keys) | Sort-Object -Unique

# Build multi-row (all instances) indexes for per-source duplication analysis
$gEntra  = IndexByNameKeyMulti $entraFlat  $NameSelectors['Entra']
$gIntune = IndexByNameKeyMulti $intuneFlat $NameSelectors['Intune']
$gAD     = IndexByNameKeyMulti $adFlat     $NameSelectors['AD']
$gSophos = IndexByNameKeyMulti $sophosFlat $NameSelectors['Sophos']
$gKACE   = IndexByNameKeyMulti $kaceFlat   $NameSelectors['KACE']

# Union of all normalized name keys (use multi-row indexes to catch names that exist only as duplicates)
$keys = @($gEntra.Keys + $gIntune.Keys + $gAD.Keys + $gSophos.Keys + $gKACE.Keys) | Sort-Object -Unique

# -------------------------------
# Merge by NameKey and compute presence flags
# -------------------------------
$merged = foreach ($k in $keys) {
    # Representative rows (for your existing snapshot columns)
    $e = $hEntra[$k];   $i = $hIntune[$k];   $d = $hAD[$k];   $s = $hSophos[$k];   $c = $hKACE[$k]

    # All instances per source for this NameKey
    $listE = $gEntra[$k];   $listI = $gIntune[$k];   $listD = $gAD[$k];   $listS = $gSophos[$k] # ;   $listC = $gKACE[$k]

    $InEntra  = [bool]$e
    $InIntune = [bool]$i
    $InAD     = [bool]$d
    $InSophos = [bool]$s
    $InKACE   = [bool]$c

    # Presence bitfield: Entra=1, Intune=2, AD=4, Sophos=8, KACE=16
    $PresenceBits =
        ([int]$InEntra)*1   +
        ([int]$InIntune)*2  +
        ([int]$InAD)*4      +
        ([int]$InSophos)*8  +
        ([int]$InKACE)*16

    $contexts = @()
    if ($InEntra)  { $contexts += 'Entra'  }
    if ($InIntune) { $contexts += 'Intune' }
    if ($InAD)     { $contexts += 'AD'     }
    if ($InSophos) { $contexts += 'Sophos' }
    if ($InKACE)   { $contexts += 'KACE'   }
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
    $DeviceType = Get-AnyReadableFromSources @($s,$c,$e) @(
        'Sophos.type','KACE.Chassis_Type','Entra.profileType','Entra.trustType'
    )
    $OS = Get-AnyReadableFromSources @($c,$d,$i,$e,$s) @(
        'KACE.Os_name','AD.OperatingSystem','Intune.operatingSystem','Entra.OperatingSystem','Sophos.os.name'
    )
    $SerialNumber = Get-AnyReadableFromSources @($i,$s,$c) @(
        'Intune.serialNumber','Sophos.serialNumber','KACE.ServiceTag'
    )
    $PrimaryUser = Get-AnyReadableFromSources @($i,$s,$e,$c) @('Intune.userPrincipalName','Sophos.associatedPerson.name','Entra.userNames','KACE.User')
    $Location = Get-AnyReadableFromSources @($d,$c) @('AD.physicalDeliveryOfficeName','AD.LocationFromOU','KACE.Location')
    $LastSeen = Get-AnyReadableFromSources @($i,$s,$c,$e) @(
        'Intune.lastSyncDateTime','Sophos.lastSeenAt','KACE.LastInventory','Entra.approximateLastSignInDateTime'
    )

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
        DeviceType = $DeviceType
        OS = $OS
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
    }
}

# Timestamped filename (Local time zone)
$stamp = (Get-Date).ToString("yyyy-MM-dd_HHmmss")
$RemoteName = "{0}_{1}.csv" -f $ReportPrefix, $stamp
$TimestampedExportPath = Join-Path (Split-Path $MergedExportPath) $RemoteName

# Export
$merged | Export-Csv -Path $TimestampedExportPath -NoTypeInformation
Write-Host "DeviceScope_Merged.csv written to: $TimestampedExportPath (presence by AD.Name, Entra.DisplayName, Intune.deviceName, KACE.Name, Sophos.hostname)"

# Clean up old data folder reports
Cleanup-OldLocalFiles -FolderPath $dataFolder -Prefix "DeviceScope_Merged" -Days 2

# ============================================
# Upload DeviceScope_Merged.csv to SharePoint via Graph REST
# Timestamped versioning, 30-day cleanup, DPAPI secrets, retry + logging
# ============================================

# -------------------------------
# Run upload
# -------------------------------
try {
    if (-not (Test-Path -LiteralPath $TimestampedExportPath)) {
        throw "Local CSV not found: $TimestampedExportPath"
    }
    
    # Get Graph token (certificate-based if no client secret, otherwise client_secret flow)
    $AccessToken = Get-GraphAccessToken -TenantId $MgTenantId -ClientId $MgClientId -ClientSecret $SPClientSecret
    
    if (-not $AccessToken) {
        throw "Unable to acquire Graph access token for SharePoint upload"
    }

    # Resolve destination folder via share link
    $Target = Resolve-TargetFolder -ShareUrl $TargetFolderShareLink -AccessToken $AccessToken
    $DriveId  = $Target.driveId
    $ParentId = $Target.parentId

    # Upload
    UploadFileToFolder -DriveId $DriveId -ParentId $ParentId -AccessToken $AccessToken -LocalPath $TimestampedExportPath -RemoteFileName $RemoteName

    # Cleanup old report versions (> RetentionDays)
    CleanupOldReports -DriveId $DriveId -ParentId $ParentId -AccessToken $AccessToken -Prefix $ReportPrefix -Days $RetentionDays

    Write-Host "SharePoint upload complete: $RemoteName"
    Write-UploadLog "SUCCESS: $RemoteName uploaded to drive=$DriveId parent=$ParentId"
}
catch {
    Write-Warning "SharePoint upload failed: $($_.Exception.Message)"
    Write-UploadLog "FAILURE: $($_.Exception.Message)"
}
finally {
    # Clear sensitive variables and hint GC
    $AccessToken = $null; $MgTenantId = $null; $MgClientId = $null; $MgClientSecret = $null; $SPClientSecret = $null
    # Nudge GC after handling sensitive file content in memory
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}

