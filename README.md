# N-Central Key Rotation Scripts

PowerShell scripts that rotate security tokens in third-party tools and produce a CSV you can import back into
[N-able N-central](https://www.n-able.com/products/n-central) so the stored custom properties stay in sync.

Bulk export and import of the custom properties is done with the
[N-central Custom Properties Tool (CPT)](https://developer.n-able.com/n-central/recipes/n-central-custom-properties-tool).
The scripts read the CSV the CPT exports and produce a new CSV that you re-import with the CPT.

| Script | Tool | N-Central property | Docs |
|---|---|---|---|
| [`Rotate-S1SiteTokens.ps1`](Rotate-S1SiteTokens.ps1) | SentinelOne (N-able EDR) | `N-able EDR Site Token` | [Rotate-S1SiteTokens.md](Rotate-S1SiteTokens.md) |
| [`Rotate-DNSFilterSiteKeys.ps1`](Rotate-DNSFilterSiteKeys.ps1) | DNSFilter | `DNS Filter Site Key` | [Rotate-DNSFilterSiteKeys.md](Rotate-DNSFilterSiteKeys.md) |

Licensed under the [MIT License](LICENSE).

## How it works

Every script follows the same pattern:

1. Authenticate with the third-party tool's API.
2. Fetch all of its sites / networks.
3. Read the CPT's `workflow-results-filtered.csv` export.
4. Match each row to a site by name.
5. Rotate (or generate) the key for each matched site.
6. Write a new CSV containing the old value and the new value.
7. Rename the `new_value` column to `value` (see [Preparing the import file](#preparing-the-import-file)) and
   re-import the file with the CPT to update the stored custom property.

> **Rotation is live and irreversible.** As soon as a key is rotated, agents still using the old key stop
> working until N-Central pushes the new one. The old key cannot be recovered from the vendor. Keep the
> output CSV safe, and import it promptly.

## Requirements

- **PowerShell 7+** (`pwsh`). Windows PowerShell 5.1 is not supported.
- An API credential for the tool being rotated, with permission to manage sites/networks.
- The [N-central Custom Properties Tool](https://developer.n-able.com/n-central/recipes/n-central-custom-properties-tool)
  (Python 3.10+, launched with `START_HERE.bat`, authenticates with your N-central server URL and a JSON Web Token).
  It is used for the bulk export and import; the scripts never talk to N-central directly.

## Using the Custom Properties Tool

We recommend the CPT for both directions, because it moves custom properties in bulk and keeps the identifiers
(`orgUnitId`, `propertyId`) that N-central needs to put each value back in the right place.

### Exporting from the CPT

1. Launch the CPT.
2. Click **Manage Customer/Organization Custom Properties**.
3. Click **Display Custom Properties**, then **Display All Properties**.
   (Or go straight to
   `http://127.0.0.1:8090/workflow-group/device-custom-properties?section=display-device-custom-properties`
   while the CPT is running.)
4. When the page has finished loading, click **Export CSV**.

The export contains every custom property, not just the one you are rotating. That is fine: each script only acts on
rows whose `propertyName` matches its own property and passes the rest through unchanged. The exported file
(`workflow-results-filtered.csv`) is what you pass to the script as `-InputCsv`.

### Importing into the CPT

1. Prepare the script's output as described in [Preparing the import file](#preparing-the-import-file).
2. Launch the CPT.
3. Click **Manage Customer/Organization Custom Properties**.
4. Click **Import Custom Properties**.
5. Pick the file you prepared from the rotator script's output.

The import is manual by design. Nothing in this repo pushes values to N-central.

## Input format: `workflow-results-filtered.csv`

Both scripts expect a CSV in the layout the CPT generates:

```
customerName, siteName, orgUnitId, propertyName, propertyId, propertyType, value, new_value
```

| Column | Meaning |
|---|---|
| `customerName`, `siteName` | Used to match the row to a site in the third-party tool. `siteName` is often blank for customer-level properties. |
| `orgUnitId`, `propertyId`, `propertyType` | Passed through untouched; N-Central uses them to place the value on import. |
| `propertyName` | Selects which rows the script acts on. Other rows are passed through with a blank `new_value`. |
| `value` | Current (old) value. Passed through unchanged. |
| `new_value` | Filled in by the script with the new key. Left blank for rows that were not rotated. |

Every input row is written to the output file, with `value` and `new_value` side by side so you can compare old and
new.

### Reading `new_value`

| `new_value` | Meaning |
|---|---|
| A key | Rotated/generated successfully. |
| *(blank)* | Row was not processed (a different property, or no match found). |
| `(dry-run)` | `-DryRun` was used; nothing was rotated. |
| `ERROR: ...` | The API call failed for that row. Remove these rows before importing. |

## Recommended workflow

1. **[Export](#exporting-from-the-cpt)** the custom properties with the CPT. This gives you `workflow-results-filtered.csv`.
2. **Dry run** and review the matches:
   ```powershell
   ./Rotate-<Tool>.ps1 ... -DryRun
   ```
   Check the `[SKIP]` warnings. Anything unmatched needs a naming fix, on either side, before you continue.
3. **Rotate** by running again without `-DryRun`. Read the summary at the end.
4. **Prepare the import file** from the script's output CSV (see below).
5. **[Import](#importing-into-the-cpt)** the prepared file manually with the CPT.
6. **Spot-check** a few devices to confirm agents are picking up the new key.

### Preparing the import file

The script's output has both the old and new key, in columns named `value` and `new_value`. The CPT imports the
`value` column, so before importing:

1. **Remove rows that have nothing to import.** Delete every row whose `new_value` is blank, `(dry-run)`, or starts
   with `ERROR:`. Left in, they would overwrite existing properties with an empty or invalid value on import. Blank rows
   include the properties the script doesn't handle and the sites it couldn't match.
2. **Rename the old `value` column** (for example to `old_value`), or delete it. Two columns named `value` are
   ambiguous.
3. **Rename `new_value` to `value`.**
4. Save as CSV (UTF-8) and import it with the CPT.

The result should look like this (columns in this order, one row per key to update):

```
customerName,siteName,orgUnitId,propertyName,propertyId,propertyType,old_value,value
```

Keep the original output file until you have confirmed the import worked. It is the only record of the old keys.

## Security notes

- API tokens are passed as command-line parameters, so they can end up in shell history. Prefer running from a
  session where you can clear history, or read the token from a secret store and pass it in.
- Output CSVs contain live keys. Treat them as secrets, store them securely, and delete them once the import is
  confirmed.
- If you publish this repo, do **not** commit exports, output CSVs, or anything containing real keys or customer
  names. A `.gitignore` covering `*.csv` and `*.xlsx` is a sensible start.

## Notes on PowerShell

- All API calls use `-SkipHeaderValidation`. Tokens from these tools often contain characters (underscores,
  hyphens, equals signs) that PowerShell's HTTP header validator rejects.
- Output is written with `Export-Csv -NoTypeInformation -Encoding UTF8`.

## Disclaimer

These scripts were written with the help of [Claude Code](https://claude.com/claude-code). They are provided
"AS IS", without warranty of any kind, express or implied, including but not limited to warranties of
merchantability, fitness for a particular purpose, and non-infringement. Use them at your own risk. The scripts rotate
live credentials, so always run with `-DryRun` first, review the matches, and test on a small set of sites before
running against everything.

## Trademarks

SentinelOne, DNSFilter, and N-able (including N-central) are trademarks of their respective owners. This project is
not an official product of, and is not affiliated with, endorsed by, or supported by any of them.
