<#
Get-KACEDevices.ps1

Collector for KACE SMA machine inventory.
Writes results to kace_raw.
#>
param(
    [Parameter(Mandatory=$true)][string]$DbPath,
    [Parameter(Mandatory=$true)][string]$RunId,
    [string]$ConfigPath,
    [bool]$VerbosePaging = $true
)

Import-Module (Join-Path $PSScriptRoot "DeviceScope.Common.psm1") -Force

function Convert-ToMachineArray($resp) {
    if ($null -eq $resp) { return @() }
    if ($resp -is [System.Collections.IEnumerable]) { return @($resp) }
    if ($resp.Machines) { return @($resp.Machines) }
    return @($resp)
}

$startedAt = Get-Date
$kaceFlat = @()

try {
    $configPath = if ($ConfigPath) { $ConfigPath } else { Join-Path (Split-Path $PSScriptRoot -Parent) "config.json" }
    $config = if (Test-Path $configPath) { Get-Content $configPath | ConvertFrom-Json } else { $null }
    $SecureDataFolder = if ($config.SecureDataFolder -and (Test-Path $config.SecureDataFolder)) { $config.SecureDataFolder } else { Join-Path $env:USERPROFILE "AppData\Local\DeviceScope\Secure" }

    $KaceBaseUrl      = if ($config.KaceBaseUrl) { $config.KaceBaseUrl } else { "https://helpdesk.image.local" }
    $KaceOrganization = if ($config.KaceOrganization) { $config.KaceOrganization } else { "Default" }
    $KaceApiVersion   = if ($config.KaceApiVersion) { $config.KaceApiVersion } else { "5" }
    $KacePageLimit    = if ($config.KacePageLimit) { $config.KacePageLimit } else { 1000 }

    $KaceUsername = $config.KaceUsername
    if (-not $KaceUsername) { $KaceUsername = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "KaceUser.bin") }
    $KacePassword = $null
    if ($config.KeyVaultName -and (Get-Command Get-AzKeyVaultSecret -ErrorAction SilentlyContinue) -and $config.KeyVaultSecrets.KacePassword) {
        try {
            $s = Get-AzKeyVaultSecret -VaultName $config.KeyVaultName -Name $config.KeyVaultSecrets.KacePassword -ErrorAction Stop
            $KacePassword = Convert-SecureStringToPlainText -Secure $s.SecretValue
        } catch { Write-Warning "Key Vault KACE password retrieval failed: $($_.Exception.Message)" }
    }
    if (-not $KacePassword) { $KacePassword = Get-DpapiSecret -Path (Join-Path $SecureDataFolder "KacePw.bin") }

    if (-not $KaceUsername -or -not $KacePassword) { throw "KACE credentials not available." }

    $sessionKace = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $headersKace = @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json'; 'x-kace-api-version' = $KaceApiVersion }

    $loginUri = "$KaceBaseUrl/ams/shared/api/security/login"
    $loginBody = @{ userName = $KaceUsername; password = $KacePassword; organizationName = $KaceOrganization } | ConvertTo-Json
    $loginResp = Invoke-RestMethod -Method Post -Uri $loginUri -Headers $headersKace -Body $loginBody -WebSession $sessionKace
    $KaceUsername = $null; $KacePassword = $null

    if (-not $loginResp) { throw "KACE AMS login failed." }

    # Using System.Collections.Generic.List here instead of a plain
    # PowerShell array - "+=" on a native array is O(n^2) (every
    # append copies the whole array), which is the likely cause of
    # KACE collection taking 15-30+ minutes despite a small page
    # count. List<T>.Add() is O(1) amortized.
    # NOTE: This API has been observed to ignore the offset parameter
    # entirely for this endpoint - it just returns the same full batch
    # every time. Relying solely on "page returned 0 items" to stop
    # paging caused a real run to spin past offset 1,000,000+ (33+
    # minutes) re-fetching the same ~593 machines forever. The real
    # termination condition here is "did this page contribute any
    # machine ID we haven't already seen" - not "did the server return
    # an empty page" or "did the count drop below the limit".
    $allMachines = New-Object System.Collections.Generic.List[object]
    $seenIds = New-Object System.Collections.Generic.HashSet[string]
    $offset = 0; $effectiveLimit = $KacePageLimit; $pageIndex = 0
    $maxPages = 200  # safety cap - normal inventories should finish in a handful of pages
    $pagingStart = Get-Date
    while ($true) {
        if ($pageIndex -ge $maxPages) {
            Write-Warning "KACE: hit safety cap of $maxPages pages without the API signaling completion. Stopping with $($allMachines.Count) machines collected. This almost certainly means the API is not honoring offset/paging as expected - investigate the endpoint/paging syntax rather than raising this cap."
            break
        }

        $invUri = "$KaceBaseUrl/api/inventory/machines?paging=limit $effectiveLimit offset $offset"
        $pageStart = Get-Date
        try { $resp = Invoke-RestMethod -Method Get -Uri $invUri -Headers $headersKace -WebSession $sessionKace } catch { break }
        $pageElapsed = ((Get-Date) - $pageStart).TotalSeconds
        $batch = Convert-ToMachineArray $resp
        $count = $batch.Count
        if ($count -eq 0) {
            if ($VerbosePaging) { Write-Output ("[KACE] page {0}: 0 items in {1:N1}s (offset {2}, limit {3}) - done" -f $pageIndex, $pageElapsed, $offset, $effectiveLimit) }
            break
        }

        $newCount = 0
        foreach ($m in $batch) {
            $idVal = [string]$m.Id
            if ($idVal -and $seenIds.Add($idVal)) {
                $allMachines.Add($m)
                $newCount++
            }
        }

        if ($VerbosePaging) { Write-Output ("[KACE] page {0}: {1} items ({2} new) in {3:N1}s (offset {4}, limit {5})" -f $pageIndex, $count, $newCount, $pageElapsed, $offset, $effectiveLimit) }

        if ($newCount -eq 0) {
            if ($VerbosePaging) { Write-Output "[KACE] page contributed 0 new machine IDs - API is not advancing through offset. Stopping (this is the actual fix for the runaway-pagination bug)." }
            break
        }

        if ($pageIndex -eq 0 -and $count -lt $effectiveLimit) { $effectiveLimit = $count }
        $offset += $count
        $pageIndex++
    }
    $pagingElapsed = ((Get-Date) - $pagingStart).TotalSeconds
    Write-Output ("KACE: paging complete - {0} pages, {1} unique machines, {2:N1}s total" -f $pageIndex, $allMachines.Count, $pagingElapsed)

    $kaceFlat = $allMachines | ForEach-Object {
        $nameKey = NormalizeComputerName $_.Name
        if (-not $nameKey) { return }
        [PSCustomObject]@{
            name_key        = $nameKey
            kace_id           = [string]$_.Id
            kace_name          = $_.Name
            os_name           = $_.Os_name
            ip_address         = $_.Ip
            ram_used           = [string]$_.Ram_used
            ram_total          = [string]$_.'Ram Total'
            last_inventory      = [string]$_.Last_inventory
            service_tag         = $_.ServiceTag
            location           = $_.Location
            user_name          = $_.User
        }
    } | Where-Object { $_ -ne $null }

    Write-Output "KACE: fetched $($kaceFlat.Count) machines"

} catch {
    Write-Warning "KACE collection failed: $($_.Exception.Message)"
    $kaceFlat = @()
}

Write-SourceRawTable -DbPath $DbPath -TableName "kace_raw" -SourceName "KACE" `
    -RunId $RunId -StartedAt $startedAt -Rows $kaceFlat