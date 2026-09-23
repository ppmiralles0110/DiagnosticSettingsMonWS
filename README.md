# Diagnostic Settings Coverage

A simple, read-only Azure Workbook: **pick subscriptions, then resource groups, and see which resources have and do not have diagnostic settings** - plus an authoritative single-resource detail view. No backend, collector, Log Analytics dependency, DCR, Azure Policy assignment, remediation, or infrastructure deployment.

**[Open the workbook JSON](DiagnosticSettingsInspector.workbook.json)** | **[Raw JSON for import](https://raw.githubusercontent.com/ppmiralles0110/DiagnosticSettingsMonWS/ppmiralles0110-diagnostic-workbook-v1/DiagnosticSettingsInspector.workbook.json)**

The published branch can be imported before its PR is merged. The file is decoded `Notebook/1.0` content, not an ARM deployment template or an escaped `serializedData` string.

## Why it works this way

Azure Resource Graph has **no diagnostic settings table**, so no single query can list configured and unconfigured resources. The only supported read is per resource. This workbook therefore:

1. lists the resources in your scope from Azure Resource Graph, and
2. fans a live ARM `GET` out across the selected resources, **one request per resource**, then
3. joins the two client-side so every in-scope resource is shown with or without the settings that came back.

That is the same fan-out pattern Microsoft uses in its published [AMA Health workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Azure%20Monitor%20-%20Agents/AMA%20Health/AMA%20Health.workbook). It also means **request volume grows with the number of selected resources**, which is why the scope filters are deliberately strict — and because the fan-out is one batched query, **it is only as reliable as its least-supported resource**. See [Why resource types are pre-filtered](#why-resource-types-are-pre-filtered).

## Import into Azure

1. Open the **Raw JSON** link above and copy the entire file, including the outer braces. Do not copy GitHub's HTML page or Markdown fences.
2. In the Azure portal, go to **Azure Monitor > Workbooks > New** (or the **Empty** template). Select **Edit** if not already editing.
3. Open **Advanced Editor** using the **`</>`** toolbar button. Select **Gallery Template** if the editor offers a template-type selector/tab. Use the workbook-content JSON editor, **not ARM Template**.
4. Replace the editor contents with the complete JSON, then select **Apply**. Select **Done Editing** to use the workbook.
5. Select **Save**. Enter a name such as `Diagnostic Settings Coverage`, choose your approved **subscription, existing resource group, and location**, then save. Use normal workbook storage; this workbook does not require a storage account or managed identity.

Saving creates a workbook resource only; it does not modify diagnostic settings. The person importing must have permission to save it. Review/clear parameter values before saving or sharing if you do not want resource IDs stored as workbook defaults.

These steps follow Microsoft's [create/edit workbook](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook), [Advanced Editor / Gallery Template](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-automate#arm-template-for-deploying-a-workbook-template), and [save a workbook](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-manage#save-a-workbook) documentation. No deploy-to-Azure button or IaC is involved.

## Use it

1. Select one or more **Subscriptions**.
2. Select **Resource groups**. Values are full RG IDs and labels include the subscription ID, so duplicate names stay distinct. There is intentionally **no default** here: choosing *All* across many subscriptions can queue thousands of live ARM reads. Recheck this after changing subscriptions.
3. Check **Resource types**. It is **pre-selected for you**: every type in scope that Azure Monitor documents as having platform logs or metrics is ticked, and every other type is listed but left unticked and labelled `[not documented for platform logs or metrics]`. There is deliberately no *All* option here — see [Why resource types are pre-filtered](#why-resource-types-are-pre-filtered).
4. **Resources to check** starts **empty**, so no ARM call runs until you choose. Pick *All* for the whole filtered scope, or pick individual resources. Each selection is one ARM request per run and refresh, so keep it to a few hundred at most.
5. Read **Step 1**. These are the raw sources — the Resource Graph inventory and the live ARM results — and they stay visible on purpose: **this is where request errors appear**. A third grid lists resources in your resource groups that were **not** checked because their type is not selected; no conclusion is drawn about those. If the ARM panel shows an error instead of a table, deselect resource types (or individual resources) until it succeeds; the last thing you removed is the one that fails.
6. Read **Step 2**. Every in-scope resource appears with a **Diagnostic settings** column of either `Setting returned` or `No setting returned`, one row per returned setting. Use the grid filter to split the list. A second grid below lists only the resources that returned nothing.
7. **Step 3**: select a row in the Step 2 grid to run a dedicated, paged read for that single resource. Use it to confirm anything the bulk lists suggest. Click **LogEntries**, **MetricEntries**, and **CategoryGroups** to expand the JSON cells; click a **Setting** for full row details, or scroll horizontally for all destination IDs.

> The sources come first because a Workbooks **merge step can only read steps that appear before it**. Moving the coverage grids above their sources makes the portal report *"There are no steps that export data at this point"* and *"Could not find table"*. `tests/Test-Workbook.ps1` now asserts that ordering.

Each setting stays on its own row, with its complete log/metric arrays, enabled **and** disabled flags, category/group choices, and its own destination identifiers: workspace, storage account, Event Hubs authorization rule and hub name, marketplace partner, and Log Analytics destination type. Missing optional fields remain missing, not inferred. This is a comparison of configuration against availability, not a compliance evaluator. **Available != recommended**; `allLogs` is not recommended by default.

### Why resource types are pre-filtered

The bulk read is a single **batched** ARM query: one sub-request per selected resource. Azure Workbooks has no per-request error tolerance for this, so **one failing sub-request fails the entire grid** and you get `'DiagnosticSettingsFanout' query failed: An unknown error has occurred.` instead of any results.

The most common cause is a resource whose type has no platform logs or metrics at all — user-assigned managed identities, for example. Reading `Microsoft.Insights/diagnosticSettings` on those does not return an empty list; it fails, and takes the whole grid with it.

So the **Resource types** picker pre-selects only the types that Azure Monitor's [supported resource log categories reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/logs-index) documents as having platform logs or metrics. This matches how Microsoft's own [AMA Health workbook](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Azure%20Monitor%20-%20Agents/AMA%20Health/AMA%20Health.workbook) constrains its fan-out parameter to two VM types.

Caveats, stated plainly:

- The list is a **documentation snapshot taken when this workbook was built**, not a live capability probe. A newly supported type can be missing from it.
- A type being on the list does not guarantee every resource of that type will read successfully.
- Unlisted types are **not hidden and not judged** — they are selectable, and any in-scope resource that is not checked is reported in the "NOT checked" grid in Step 1 rather than being counted as having no settings.
- Throttling (`429`) or a resource deleted mid-query can still fail the batch even when every type is supported. Reduce the selection and retry.

### `No setting returned` is not proof of "not configured"

A resource lands in that group when the ARM read returned an empty collection **or** when that read failed, was denied by RBAC, was throttled, or the resource type does not support diagnostic settings. A request that fails contributes no rows, exactly like a resource with no settings. Always check the Step 1 ARM panel for errors, and confirm individual resources in Step 3 before acting.

Bulk rows are attributed to a resource by stripping the `/providers/microsoft.insights/diagnosticSettings/...` suffix from each setting ID. If ARM returns the resource ID with different casing than Resource Graph stored it, that resource can show as `No setting returned` even though Step 3 shows settings. **Step 3 is authoritative.**

### Inspect a child resource

Resource Graph does not list service children such as a storage account's Blob service, so they never appear in the bulk lists. In Step 3, select the parent row and enter the child suffix in **Optional child suffix** - for example `/blobServices/default`. A parent storage account and its Blob service are different targets with different settings; see [Blob Storage monitoring](https://learn.microsoft.com/en-us/azure/storage/blobs/monitor-blob-storage).

The suffix accepts type/name pairs only. It rejects URLs, trailing slashes, query strings, fragments, whitespace, and encoded characters. Other services use different child types; get the exact ID from the resource's **Properties / JSON View** rather than guessing.

## Permissions and data access

| Purpose | Required access |
| --- | --- |
| Inventory and the resource picker | Resource Graph access to the selected scope and source-resource read access, including subscription/RG discovery. ARG returns only resources the viewer can read. |
| Bulk and detail diagnostic reads | `Microsoft.Insights/DiagnosticSettings/Read` and `Microsoft.Insights/DiagnosticSettingsCategories/Read` on every resource read, including a child target if applicable. |
| Open a saved workbook | `Microsoft.Insights/Workbooks/Read`, **plus** the underlying access above. |
| Import/save | Workbook write access (`Microsoft.Insights/Workbooks/Write`) in the approved RG, with the portal's required subscription/RG read access; for example, an approved Workbook Contributor assignment. This is separate from viewing. |

Reader on the relevant scope is convenient but broader than strict diagnostic-metadata-only access. Have your administrator scope custom roles/resource reads appropriately; this repository creates no roles or assignments. Workbook access alone does not grant source access.

Only these ARM metadata read operations run:

```text
GET {resourceId}/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview
GET {resourceId}/providers/Microsoft.Insights/diagnosticSettingsCategories?api-version=2021-05-01-preview
```

The bulk panel issues the first one per selected resource. The Step 3 panels use ARM `GETARRAY`, which follows `nextLink` / `@odata.nextLink` pages for a single target - pagination, **not** resource fan-out. Workbooks supplies the signed-in user's ARM authentication; no custom headers, secrets, `listKeys`, log-content reads, or writes are present. Destination IDs are configuration metadata; destinations are not queried.

## Empty results, failures, and limits

- **Empty versus failed:** `No diagnostic settings returned` and `No categories returned` in Step 3 are native `noDataMessage` values for successful empty results only. There is no hidden result parameter, default-to-zero conversion, fallback JSON, or success/compliance badge. A 403, 404, 429, timeout, or other native request error must be read as an error, not as empty or unsupported. A 404 alone does not establish whether diagnostics are supported. Do not interpret loading, stale, or failed panels as a completed check.
- **Coverage is per selected resource, not estate-wide:** there is no configured/missing total for a subscription, no production classification, no baseline, exemptions, compliance score, recommendation engine, historical snapshot, or remediation - and no Resource Graph table of diagnostic settings to build one from. ARG is eventually consistent and RBAC-filtered.
- **Stale selection:** the Step 3 target does not change when the Step 0 filters change. If you narrow the scope after selecting a row, the selection can stay behind. The exact ARM target is displayed above the panels - check it.
- **Bounded results:** the inventory query and the resource picker each take at most **1,000 rows/items**, matching an ARG result page and the dropdown limit. No paging/export engine is provided. ARG source queries support at most 1,000 subscriptions. Grids have a 10,000-row ceiling; a row limit is not a completeness guarantee, and grid search affects returned rows only.
- **Request volume:** every selected resource costs one ARM request on every run and refresh. The picker starts empty for this reason. Narrow by resource type and deselect resources you do not need.
- **One failure fails the grid:** the bulk read is a single batched ARM query with no per-request error tolerance. Any sub-request that fails — unsupported resource type, throttling, a resource deleted mid-query — fails the whole panel rather than returning partial results. See [Why resource types are pre-filtered](#why-resource-types-are-pre-filtered).
- **Not an atomic snapshot:** the panels are separate live reads; refresh after external changes.
- **Logs versus metrics:** exported platform metrics differ from resource logs and from Metrics Explorer availability. Not every metric/dimension is exportable through diagnostic settings. Enabled configuration does not prove delivery, ingestion, retention, or destination health. See [diagnostic settings](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings).

## Local validation and first-run check

Run from the repository root with **PowerShell 7** (no packages required):

```powershell
pwsh -NoProfile -File .\tests\Test-Workbook.ps1
```

The check parses the outer JSON and every nested ARM/merge query, validates parameter dependencies and forward references, confirms the scope filters are shared by the picker and the inventory, asserts the resource-type gate cannot be bypassed by an *All* option and that skipped resources are reported as skipped rather than as uncovered, enforces a read-only endpoint allowlist, and verifies that every merge column exists in the step it claims to come from. It then runs fixtures for multiple settings, disabled entries, category groups, metrics-only settings, missing optional arrays, empty arrays, pagination, a child target, bulk row attribution, the with/without join, the anti-join, a resource-ID casing mismatch, and denied/unsupported/malformed reads - asserting that failures stay failures and never become coverage. It models only the JSONPath and merge subset this workbook uses, **not the Azure Workbooks runtime**.

To additionally check the official schema, download the pinned public schema locally and pass its path (no Azure connection):

```powershell
$schema = Join-Path $env:TEMP 'azure-workbook-schema.json'
Invoke-WebRequest 'https://raw.githubusercontent.com/microsoft/Application-Insights-Workbooks/d37985b5b8588e644b0f3ff67700df12da3cd7f7/schema/workbook.json' -OutFile $schema
pwsh -NoProfile -File .\tests\Test-Workbook.ps1 -SchemaPath $schema
```

The official schema is permissive: schema/fixture success cannot prove portal rendering, KQL execution, fan-out behaviour, parameter gating, RBAC, or service responses. **No Azure tenant was accessed and no live Azure validation was performed.** After import, start with one small resource group and verify: a resource with multiple settings, a resource with none, a resource type that does not support diagnostic settings, and an approved child target. Confirm that errors stay visible in Step 1 rather than silently reducing Step 2. No permission changes are needed for this check.

## Implementation references

- [Workbook ARM and ARG data sources](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-data-sources)
- [Supported resource log categories by resource type](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/logs-index) - the source of the pre-selected resource-type list
- [Workbook JSONPath transformations](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-jsonpath), [merge data source](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-data-sources#merge), [text parameter validation](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-text#add-validations), and [cell/row details links](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-link-actions)
- [Official ARM fan-out example (AMA Health)](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Azure%20Monitor%20-%20Agents/AMA%20Health/AMA%20Health.workbook) and [official anti-join merge example](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Azure%20Advisor/Cost%20Optimization/Storage/Storage.workbook)
- [Official scoped resource picker example](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Azure%20Monitor%20-%20Getting%20Started/Resource%20Picker/Resource%20Picker.workbook), [official GETARRAY example](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Windows%20Virtual%20Desktop/CheckAMAConfiguration/CheckAMAConfiguration.workbook), and [workbook schema](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json)
- [Diagnostic settings List API](https://learn.microsoft.com/en-us/rest/api/monitor/diagnostic-settings/list?view=rest-monitor-2021-05-01-preview), [categories List API](https://learn.microsoft.com/en-us/rest/api/monitor/diagnostic-settings-category/list?view=rest-monitor-2021-05-01-preview), and [current REST specification](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/monitor/resource-manager/Microsoft.Insights/Insights/preview/2021-05-01-preview/openapi.json)
- [ARG large-result limits](https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/work-with-data#data-set-result-size) and [Azure Monitor service limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-monitor-limits)
