# Rotate-S1SiteTokens.ps1
# Rotates SentinelOne site registration tokens and outputs an updated CSV for N-Central re-import.
#
# Usage:
#   ./Rotate-S1SiteTokens.ps1 -ApiUrl "https://usea1-swprd2.sentinelone.net" -ApiToken "your-api-token" -InputCsv "ncentralexport.csv"
#   ./Rotate-S1SiteTokens.ps1 ... -DryRun    # preview matches without rotating anything
#
# Auth flow (per Swagger spec):
#   1. POST /users/login/by-api-token  →  exchange API token for a session token
#   2. Use session token as:  Authorization: Token <session-token>
#
# Rotation flow:
#   GET  /sites                          →  list all sites (get IDs)
#   PUT  /sites/{id}/regenerate-key      →  rotate token, returns data.registrationToken
#
# ─────────────────────────────────────────────────────────────────────────────
# Written with the help of Claude Code (https://claude.com/claude-code).
# Provided "AS IS", without warranty of any kind, express or implied. Use at
# your own risk. This rotates live credentials — run with -DryRun first,
# review the matches, and test on a small set of sites before running
# against everything. See the repo README for full details.
#
# SentinelOne and N-able are trademarks of their respective owners. This is
# not an official or affiliated tool.
# ─────────────────────────────────────────────────────────────────────────────

param(
    [Parameter(Mandatory=$true)]
    [string]$ApiUrl,        # e.g. https://usea1-swprd2.sentinelone.net

    [Parameter(Mandatory=$true)]
    [string]$ApiToken,      # SentinelOne API token from Settings > Users > API Token

    [Parameter(Mandatory=$true)]
    [string]$InputCsv,      # Path to N-Central CSV export

    [string]$OutputCsv = "s1-token-rotation-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    [switch]$DryRun         # Preview matches only; do NOT rotate any tokens
)

$ErrorActionPreference = "Stop"
$ApiUrl = $ApiUrl.TrimEnd("/")

# ── 1. Exchange API token for session token ───────────────────────────────────
Write-Host "`nAuthenticating with SentinelOne..." -ForegroundColor Cyan

$loginBody = @{ data = @{ apiToken = $ApiToken } } | ConvertTo-Json
$loginResp  = Invoke-RestMethod -Uri "$ApiUrl/web/api/v2.1/users/login/by-api-token" `
                                -Method Post `
                                -Body $loginBody `
                                -ContentType "application/json" `
                                -SkipHeaderValidation

$sessionToken = $loginResp.data.token
if (-not $sessionToken) { throw "Login succeeded but no session token returned." }

$headers = @{ "Authorization" = "Token $sessionToken" }
Write-Host "Authenticated successfully." -ForegroundColor Green

# ── Helper: paginated GET ─────────────────────────────────────────────────────
function Get-S1Paged {
    param([string]$Endpoint)
    $items  = [System.Collections.Generic.List[object]]::new()
    $cursor = $null
    do {
        $url  = "$script:ApiUrl$Endpoint" + $(if ($cursor) { "&cursor=$cursor" } else { "" })
        $resp = Invoke-RestMethod -Uri $url -Headers $script:headers -Method Get -SkipHeaderValidation
        # /sites returns data.sites (nested); most other endpoints return data directly as an array
        $page = if ($resp.data.sites) { $resp.data.sites } else { $resp.data }
        $items.AddRange([object[]]$page)
        $cursor = $resp.pagination.nextCursor
    } while ($cursor)
    return $items
}

# ── 2. Load all SentinelOne sites ─────────────────────────────────────────────
Write-Host "Fetching SentinelOne sites..." -ForegroundColor Cyan
$s1SiteList = Get-S1Paged "/web/api/v2.1/sites?limit=1000&state=active"

$byName = @{}
foreach ($s in $s1SiteList) {
    if (-not $byName.ContainsKey($s.name)) { $byName[$s.name] = $s }
}
Write-Host "Found $($s1SiteList.Count) active S1 sites." -ForegroundColor Green

# ── 3. Load N-Central CSV ─────────────────────────────────────────────────────
if (-not (Test-Path $InputCsv)) { throw "Input CSV not found: $InputCsv" }
$allRows   = Import-Csv -Path $InputCsv
$tokenRows = @($allRows | Where-Object { $_.propertyName -eq "N-able EDR Site Token" })
Write-Host "Found $($tokenRows.Count) 'N-able EDR Site Token' rows in N-Central export." -ForegroundColor Cyan

if ($DryRun) { Write-Host "`n[DRY RUN] No tokens will be rotated.`n" -ForegroundColor Yellow }

# ── 4. Match + rotate ─────────────────────────────────────────────────────────
$results = [System.Collections.Generic.List[object]]::new()
$matched = 0
$noMatch = 0
$errored = 0

foreach ($row in $allRows) {
    $newValue = ""

    if ($row.propertyName -eq "N-able EDR Site Token") {

        # Match by siteName first, fall back to customerName
        $s1 = $byName[$row.siteName]
        if (-not $s1) { $s1 = $byName[$row.customerName] }

        if ($s1) {
            if ($DryRun) {
                Write-Host "  [MATCH]  '$($row.customerName) / $($row.siteName)'  =>  S1 '$($s1.name)'" -ForegroundColor Yellow
                $newValue = "(dry-run)"
                $matched++
            } else {
                try {
                    $resp     = Invoke-RestMethod -Uri "$ApiUrl/web/api/v2.1/sites/$($s1.id)/regenerate-key" `
                                                  -Headers $headers -Method Put -Body "{}" `
                                                  -ContentType "application/json" -SkipHeaderValidation
                    $newValue = $resp.data.registrationToken
                    Write-Host "  [OK]  $($row.customerName) / $($row.siteName)" -ForegroundColor Green
                    $matched++
                } catch {
                    $msg = $_.Exception.Message
                    Write-Warning "  [ERR]  $($row.customerName) / $($row.siteName): $msg"
                    $newValue = "ERROR: $msg"
                    $errored++
                }
            }
        } else {
            Write-Warning "  [SKIP]  No S1 match for '$($row.customerName) / $($row.siteName)'"
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

# ── 5. Export ─────────────────────────────────────────────────────────────────
$results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "`n── Results ──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Matched / rotated : $matched" -ForegroundColor Green
Write-Host "  No S1 match found : $noMatch" -ForegroundColor Yellow
if ($errored -gt 0) { Write-Host "  Errors            : $errored" -ForegroundColor Red }
Write-Host "  Output            : $OutputCsv" -ForegroundColor Cyan
Write-Host ""