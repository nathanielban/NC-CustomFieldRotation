# Rotate-DNSFilterSiteKeys.ps1
# Rotates DNSFilter network secret keys ("Site Keys") and outputs an updated CSV for N-Central re-import.
#
# Usage:
#   ./Rotate-DNSFilterSiteKeys.ps1 -ApiToken "your-api-key" -InputCsv "ncentralexport.csv"
#   ./Rotate-DNSFilterSiteKeys.ps1 ... -DryRun    # preview matches without rotating anything
#
# Auth (per Swagger spec):
#   Authorization: <api-key>      (raw key in the header - no "Bearer"/"Token" prefix)
#   Keys are created in the DNSFilter dashboard under Account Settings > API Tokens.
#
# Rotation flow:
#   GET   /v1/organizations/all            →  list all organizations (id -> name)
#   GET   /v1/networks/all                 →  list all networks (id, name, org, current secret_key)
#   PATCH /v1/networks/{id}/secret_key     →  rotate key, returns data.attributes.secret_key
#   POST  /v1/networks/{id}/secret_key     →  generate key when the network has none (or PATCH returns 422)
#
# Matching (first hit wins):
#   1. siteName     == network name
#   2. customerName == network name
#   3. customerName == organization name (only if that org has exactly one network)
#   4. N-Central "value" == a network's current secret_key
# Anything ambiguous (several networks would match) is skipped, never guessed.
#
# ─────────────────────────────────────────────────────────────────────────────
# Written with the help of Claude Code (https://claude.com/claude-code).
# Provided "AS IS", without warranty of any kind, express or implied. Use at
# your own risk. This rotates live credentials — run with -DryRun first,
# review the matches, and test on a small set of sites before running
# against everything. See the repo README for full details.
#
# DNSFilter and N-able are trademarks of their respective owners. This is
# not an official or affiliated tool.
# ─────────────────────────────────────────────────────────────────────────────

param(
    [Parameter(Mandatory=$true)]
    [string]$ApiToken,      # DNSFilter API key

    [Parameter(Mandatory=$true)]
    [string]$InputCsv,      # Path to N-Central CSV export

    [string]$ApiUrl = "https://api.dnsfilter.com",

    [string]$PropertyName = "DNS Filter Site Key",

    [string]$OutputCsv = "dnsfilter-key-rotation-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    [switch]$DryRun         # Preview matches only; do NOT rotate any keys
)

$ErrorActionPreference = "Stop"
$ApiUrl = $ApiUrl.TrimEnd("/")
$headers = @{ "Authorization" = $ApiToken }

# ── Helper: REST call with 429 back-off ───────────────────────────────────────
function Invoke-DnsFilter {
    param([string]$Path, [string]$Method = "Get")
    for ($attempt = 1; ; $attempt++) {
        try {
            $req = @{
                Uri = "$script:ApiUrl$Path"; Headers = $script:headers; Method = $Method
                SkipHeaderValidation = $true
            }
            if ($Method -ne "Get") { $req.Body = "{}"; $req.ContentType = "application/json" }
            return Invoke-RestMethod @req
        } catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 429 -and $attempt -lt 5) {
                $wait = 5
                $retryAfter = $_.Exception.Response.Headers | Where-Object Key -eq "Retry-After" | ForEach-Object { $_.Value[0] }
                if ($retryAfter -as [int]) { $wait = [int]$retryAfter }
                Write-Warning "  Rate limited; retrying in ${wait}s..."
                Start-Sleep -Seconds $wait
            } else { throw }
        }
    }
}

# ── Helper: paginated GET (JSON:API style page[number] / page[size]) ──────────
function Get-DnsFilterPaged {
    param([string]$Endpoint)
    $size   = 100
    $items  = [System.Collections.Generic.List[object]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new()
    for ($page = 1; ; $page++) {
        $sep  = if ($Endpoint.Contains("?")) { "&" } else { "?" }
        $resp = Invoke-DnsFilter "$Endpoint${sep}page%5Bnumber%5D=$page&page%5Bsize%5D=$size"
        $rows = @($resp.data)
        $new  = 0
        foreach ($r in $rows) { if ($seen.Add([string]$r.id)) { $items.Add($r); $new++ } }
        # Stop on a short page, or if the API ignored paging and repeated itself
        if ($rows.Count -lt $size -or $new -eq 0) { break }
    }
    return $items
}

# ── 1. Load organizations + networks ──────────────────────────────────────────
Write-Host "`nFetching DNSFilter organizations..." -ForegroundColor Cyan
$orgList = Get-DnsFilterPaged "/v1/organizations/all"
$orgName = @{}
foreach ($o in $orgList) { $orgName[[string]$o.id] = $o.attributes.name }
Write-Host "Found $($orgList.Count) organizations." -ForegroundColor Green

Write-Host "Fetching DNSFilter networks..." -ForegroundColor Cyan
$netList = @(Get-DnsFilterPaged "/v1/networks/all?force_truncate_ips=true" |
             Where-Object { -not $_.attributes.deleted_at })

# Flatten to the fields we need
$networks = foreach ($n in $netList) {
    $orgId = [string]$n.relationships.organization.data.id
    [PSCustomObject]@{
        id      = $n.id
        name    = $n.attributes.name
        orgId   = $orgId
        orgName = [string]$orgName[$orgId]
        key     = $n.attributes.secret_key
    }
}
$networks = @($networks)
Write-Host "Found $($networks.Count) active networks." -ForegroundColor Green

$byName = $networks | Group-Object name    -AsHashTable -AsString
$byOrg  = $networks | Group-Object orgName -AsHashTable -AsString
$byKey  = @{}
foreach ($n in $networks) { if ($n.key) { $byKey[$n.key] = $n } }

# Returns @{ Network = <obj|$null>; Note = <string> }
function Find-Network {
    param($Row)
    $ambiguous = $null

    foreach ($name in @($Row.siteName, $Row.customerName)) {
        if (-not $name) { continue }
        $hits = @($script:byName[$name] | Where-Object { $_ })
        if ($hits.Count -gt 1) {
            # Same network name in several orgs - narrow by customer/org name
            $hits = @($hits | Where-Object { $_.orgName -eq $Row.customerName })
        }
        if ($hits.Count -eq 1) { return @{ Network = $hits[0]; Note = "name" } }
        if ($hits.Count -gt 1) { $ambiguous = "$($hits.Count) networks named '$name'" }
    }

    if ($Row.customerName) {
        $hits = @($script:byOrg[$Row.customerName] | Where-Object { $_ })
        if ($hits.Count -eq 1) { return @{ Network = $hits[0]; Note = "organization" } }
        if ($hits.Count -gt 1) { $ambiguous = "organization '$($Row.customerName)' has $($hits.Count) networks" }
    }

    if ($Row.value -and $script:byKey.ContainsKey($Row.value)) {
        return @{ Network = $script:byKey[$Row.value]; Note = "existing key" }
    }

    return @{ Network = $null; Note = $ambiguous }
}

# ── 2. Load N-Central CSV ─────────────────────────────────────────────────────
if (-not (Test-Path $InputCsv)) { throw "Input CSV not found: $InputCsv" }
$allRows   = Import-Csv -Path $InputCsv
$tokenRows = @($allRows | Where-Object { $_.propertyName -eq $PropertyName })
Write-Host "Found $($tokenRows.Count) '$PropertyName' rows in N-Central export." -ForegroundColor Cyan
if ($tokenRows.Count -eq 0) { throw "No rows with propertyName '$PropertyName' in $InputCsv." }

if ($DryRun) { Write-Host "`n[DRY RUN] No keys will be rotated.`n" -ForegroundColor Yellow }

# ── 3. Match + rotate ─────────────────────────────────────────────────────────
$results = [System.Collections.Generic.List[object]]::new()
$claimed = @{}      # network id -> row label, so two rows never rotate one network twice
$matched = 0
$created = 0
$noMatch = 0
$errored = 0

# try/finally: keys are rotated live, so the CSV must be written even if the run dies midway
try {
    foreach ($row in $allRows) {
        $newValue = ""

        if ($row.propertyName -eq $PropertyName) {
            $label = "$($row.customerName) / $($row.siteName)"
            $found = Find-Network $row
            $net   = $found.Network

            if ($net -and $claimed.ContainsKey($net.id)) {
                $found = @{ Network = $null; Note = "network '$($net.name)' already used by '$($claimed[$net.id])'" }
                $net   = $null
            }

            if ($net) {
                $claimed[$net.id] = $label
                $keyPath = "/v1/networks/$($net.id)/secret_key"
                if ($DryRun) {
                    $action = if ($net.key) { "rotate" } else { "GENERATE - no existing key" }
                    Write-Host "  [MATCH]  '$label'  =>  DNSFilter '$($net.name)' (org '$($net.orgName)', by $($found.Note)) [$action]" -ForegroundColor Yellow
                    $newValue = "(dry-run)"
                    $matched++
                } else {
                    try {
                        $generated = $false
                        if ($net.key) {
                            try {
                                $resp = Invoke-DnsFilter $keyPath -Method Patch
                            } catch {
                                # 422 = nothing to rotate (list may not have exposed the key) - fall back to generating one
                                if ($_.Exception.Response.StatusCode.value__ -ne 422) { throw }
                                $generated = $true
                                $resp = Invoke-DnsFilter $keyPath -Method Post
                            }
                        } else {
                            $generated = $true
                            $resp = Invoke-DnsFilter $keyPath -Method Post
                        }
                        $newValue = $resp.data.attributes.secret_key
                        if (-not $newValue) { throw "DNSFilter returned no secret_key." }
                        $verb = if ($generated) { "GENERATED" } else { "OK" }
                        Write-Host "  [$verb]  $label  =>  '$($net.name)'" -ForegroundColor Green
                        $matched++
                        if ($generated) { $created++ }
                    } catch {
                        $msg = $_.Exception.Message
                        if ($_.ErrorDetails.Message) { $msg += " - $($_.ErrorDetails.Message)" }
                        Write-Warning "  [ERR]  ${label}: $msg"
                        $newValue = "ERROR: $msg"
                        $errored++
                    }
                }
            } else {
                $why = if ($found.Note) { " ($($found.Note))" } else { "" }
                Write-Warning "  [SKIP]  No DNSFilter match for '$label'$why"
                $noMatch++
            }
        }

        $results.Add([PSCustomObject]@{
            customerName = $row.customerName
            siteName     = $row.siteName
            orgUnitId    = $row.orgUnitId
            propertyName = $row.propertyName
            propertyId   = $row.propertyId
            propertyType = $row.propertyType
            value        = $row.value
            new_value    = $newValue
        })
    }
}
finally {
    # ── 4. Export ─────────────────────────────────────────────────────────────
    if ($results.Count -gt 0) {
        $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    }
}

Write-Host "`n── Results ──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Matched / rotated    : $matched" -ForegroundColor Green
if ($created -gt 0) { Write-Host "    of which newly generated: $created" -ForegroundColor Green }
Write-Host "  No DNSFilter match   : $noMatch" -ForegroundColor Yellow
if ($errored -gt 0) { Write-Host "  Errors               : $errored" -ForegroundColor Red }
Write-Host "  Output               : $OutputCsv" -ForegroundColor Cyan
Write-Host ""
