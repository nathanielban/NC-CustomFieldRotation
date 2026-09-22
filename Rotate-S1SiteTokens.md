# Rotate-S1SiteTokens.ps1

Rotates SentinelOne **site registration tokens** and writes an updated CSV for re-import into N-Central.

See the [README](README.md) for the overall workflow, CSV format, and security notes.

Bulk export and import of the custom property is done with the
[N-central Custom Properties Tool](https://developer.n-able.com/n-central/recipes/n-central-custom-properties-tool)
(CPT). This script reads the CPT's `workflow-results-filtered.csv` and produces a new file you re-import with it.

## What it does

1. Exchanges your SentinelOne API token for a session token.
2. Lists all **active** SentinelOne sites.
3. Reads the CPT export (`workflow-results-filtered.csv`) and picks the rows where `propertyName` is `N-able EDR Site Token`.
4. Matches each row to a SentinelOne site by name.
5. Regenerates the site's registration token.
6. Writes every input row to a new CSV, with the new token in `new_value`.
7. You then [prepare the file and re-import it](#importing-the-results) with the CPT.

## Usage

```powershell
./Rotate-S1SiteTokens.ps1 `
    -ApiUrl   "https://yours1dashboard.sentinelone.net" `
    -ApiToken "<sentinelone-api-token>" `
    -InputCsv "workflow-results-filtered.csv"
```

Preview matches without rotating anything:

```powershell
./Rotate-S1SiteTokens.ps1 -ApiUrl ... -ApiToken ... -InputCsv workflow-results-filtered.csv -DryRun
```

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-ApiUrl` | Yes | Your SentinelOne management console URL, e.g. `https://yours1dashboard.sentinelone.net`. A trailing `/` is ignored. |
| `-ApiToken` | Yes | SentinelOne API token (Settings > Users > API Token). |
| `-InputCsv` | Yes | Path to the CPT export, `workflow-results-filtered.csv`. |
| `-OutputCsv` | No | Output path. Defaults to `s1-token-rotation-<yyyyMMdd-HHmmss>.csv` in the current directory. |
| `-DryRun` | No | Report matches only. No tokens are rotated; `new_value` is set to `(dry-run)`. |

The property name (`N-able EDR Site Token`) is fixed in the script.

## Matching rules

For each `N-able EDR Site Token` row:

1. `siteName` is compared to the SentinelOne site name.
2. If that finds nothing, `customerName` is compared to the SentinelOne site name.

Comparison is case-insensitive and needs an exact name. Rows with no match are reported as `[SKIP]` and left with a
blank `new_value`.

Things to be aware of:

- Only **active** sites are considered.
- If two SentinelOne sites share a name, the **first one returned wins**. Make sure site names are unique.
- Matching is against site names only, not accounts.

## API calls

| Step | Call |
|---|---|
| Login | `POST /web/api/v2.1/users/login/by-api-token` with `{ "data": { "apiToken": "..." } }`, returns `data.token` |
| List sites | `GET /web/api/v2.1/sites?limit=1000&state=active`, following `pagination.nextCursor` |
| Rotate | `PUT /web/api/v2.1/sites/{id}/regenerate-key`, returns `data.registrationToken` |

Requests after login send `Authorization: Token <session-token>`.

## Output

Same columns as the input (`customerName, siteName, orgUnitId, propertyName, propertyId, propertyType, value, new_value`),
one row per input row. See [Reading `new_value`](README.md#reading-new_value).

Console output ends with a summary:

```
── Results ──────────────────────────────────────────
  Matched / rotated : 38
  No S1 match found : 1
  Output            : s1-token-rotation-20260101-120000.csv
```

An `Errors` line appears if any API call failed. Those rows have `ERROR: <message>` in `new_value`.

## Importing the results

The output has the old token in `value` and the new one in `new_value`. To import it with the CPT:

1. Delete rows whose `new_value` is blank, `(dry-run)`, or starts with `ERROR:`. That includes any properties
   other than `N-able EDR Site Token` and any unmatched sites, or they would overwrite existing values on import.
2. Rename the `value` column to `old_value` (or delete it).
3. Rename `new_value` to `value`.
4. Import the file manually with the CPT.

Details and the expected result are in the README under
[Preparing the import file](README.md#preparing-the-import-file).

## Limitations

- The output CSV is written **after** the loop finishes. If the script is killed part-way through (for example,
  Ctrl+C), tokens already rotated will not be in a CSV. Use `-DryRun` first, and consider running in smaller batches.
- A rotated token cannot be retrieved again afterwards, except by rotating it again.

---

This script was written with the help of Claude Code and is provided "AS IS", without warranty of any kind, express or
implied. See the [README](README.md#disclaimer).

SentinelOne and N-able are trademarks of their respective owners. This is not an official or affiliated tool.
