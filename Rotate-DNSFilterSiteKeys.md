# Rotate-DNSFilterSiteKeys.ps1

Rotates DNSFilter **network secret keys** (the "Site Key" used by DNSFilter agents) and writes an updated CSV for
re-import into N-Central. Networks that have no key yet get one generated.

See the [README](README.md) for the overall workflow, CSV format, and security notes.

Bulk export and import of the custom property is done with the
[N-central Custom Properties Tool](https://developer.n-able.com/n-central/recipes/n-central-custom-properties-tool)
(CPT). This script reads the CPT's `workflow-results-filtered.csv` and produces a new file you re-import with it.

## What it does

1. Lists all DNSFilter organizations and networks.
2. Reads the CPT export (`workflow-results-filtered.csv`) and picks the rows where `propertyName` is `DNS Filter Site Key`.
3. Matches each row to a DNSFilter network.
4. Rotates the network's secret key, or generates one if the network has none.
5. Writes every input row to a new CSV, with the new key in `new_value`.
6. You then [prepare the file and re-import it](#importing-the-results) with the CPT.

## Usage

```powershell
./Rotate-DNSFilterSiteKeys.ps1 `
    -ApiToken "<dnsfilter-api-key>" `
    -InputCsv "workflow-results-filtered.csv"
```

Preview matches without changing anything:

```powershell
./Rotate-DNSFilterSiteKeys.ps1 -ApiToken ... -InputCsv workflow-results-filtered.csv -DryRun
```

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-ApiToken` | Yes | DNSFilter API key (dashboard > Account Settings > API Tokens). |
| `-InputCsv` | Yes | Path to the CPT export, `workflow-results-filtered.csv`. It must contain `DNS Filter Site Key` rows. |
| `-ApiUrl` | No | Defaults to `https://api.dnsfilter.com`. |
| `-PropertyName` | No | N-Central property to process. Defaults to `DNS Filter Site Key`. |
| `-OutputCsv` | No | Output path. Defaults to `dnsfilter-key-rotation-<yyyyMMdd-HHmmss>.csv` in the current directory. |
| `-DryRun` | No | Report matches and what would happen (`[rotate]` or `[GENERATE]`). Nothing is changed; `new_value` is set to `(dry-run)`. |

The script stops immediately if the input CSV has no rows for the property.

## Matching rules

DNSFilter organizations contain networks, and keys belong to networks. For each `DNS Filter Site Key` row, the first
rule that gives a single result wins:

1. `siteName` equals a network name.
2. `customerName` equals a network name.
3. `customerName` equals an organization name **and that organization has exactly one network**.
4. The row's `value` equals a network's current secret key. This is a last-resort fallback that helps when names differ.

Safeguards:

- If a name matches several networks (for example, the same network name in two organizations), the script tries to
  narrow it using `customerName` vs. the organization name. If it is still ambiguous, the row is **skipped**.
- An organization with several networks and no network-name match is **skipped**, because N-Central holds one key per
  row and the script won't guess which network you mean.
- Two rows can never resolve to the same network. The second is skipped.
- Deleted networks are ignored.

Skipped rows are reported as `[SKIP]` with the reason, and left with a blank `new_value`.

## Rotate vs. generate

| Network state | Action |
|---|---|
| Has a secret key | `PATCH /v1/networks/{id}/secret_key` (rotate) |
| Has no secret key | `POST /v1/networks/{id}/secret_key` (generate) |
| Rotate returns HTTP 422 | Falls back to generate |

Newly generated keys are logged as `[GENERATED]` and counted separately in the summary. In `-DryRun`, each match is
tagged `[rotate]` or `[GENERATE - no existing key]`.

## API calls

| Step | Call |
|---|---|
| List organizations | `GET /v1/organizations/all` |
| List networks | `GET /v1/networks/all?force_truncate_ips=true` |
| Rotate | `PATCH /v1/networks/{id}/secret_key`, returns `data.attributes.secret_key` |
| Generate | `POST /v1/networks/{id}/secret_key`, returns `data.attributes.secret_key` |

- Authentication is the raw API key in the `Authorization` header (no `Bearer` prefix).
- List calls are paginated with `page[number]` / `page[size]` (100 per page).
- HTTP 429 (rate limit) responses are retried up to 5 times, honouring `Retry-After`.

## Output

Same columns as the input (`customerName, siteName, orgUnitId, propertyName, propertyId, propertyType, value, new_value`),
one row per input row. See [Reading `new_value`](README.md#reading-new_value).

Console output ends with a summary:

```
── Results ──────────────────────────────────────────
  Matched / rotated    : 38
    of which newly generated: 2
  No DNSFilter match   : 1
  Output               : dnsfilter-key-rotation-20260101-120000.csv
```

An `Errors` line appears if any API call failed. Those rows have `ERROR: <message>` in `new_value`, including
DNSFilter's response text where available.

## Importing the results

The output has the old key in `value` and the new one in `new_value`. To import it with the CPT:

1. Delete rows whose `new_value` is blank, `(dry-run)`, or starts with `ERROR:`. That includes any properties
   other than `DNS Filter Site Key` and any unmatched networks, or they would overwrite existing values on import.
2. Rename the `value` column to `old_value` (or delete it).
3. Rename `new_value` to `value`.
4. Import the file manually with the CPT.

Details and the expected result are in the README under
[Preparing the import file](README.md#preparing-the-import-file).

## Safety

The output CSV is written in a `finally` block, so it is still produced if the run fails part-way. Keys rotated
before the failure are preserved in the file.

A rotated key cannot be retrieved again afterwards, except by rotating it again. Import the output CSV promptly.

---

This script was written with the help of Claude Code and is provided "AS IS", without warranty of any kind, express or
implied. See the [README](README.md#disclaimer).

DNSFilter and N-able are trademarks of their respective owners. This is not an official or affiliated tool.
