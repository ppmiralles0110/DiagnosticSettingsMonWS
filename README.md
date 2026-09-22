# Diagnostic Settings Inspector

A simple, read-only Azure Workbook v1: **selected-scope resource inventory, then live diagnostic metadata for one exact resource ID**. No backend, collector, Log Analytics dependency, DCR, Azure Policy assignment, remediation, or infrastructure deployment.

**[Open the workbook JSON](DiagnosticSettingsInspector.workbook.json)** | **[Raw JSON for import](https://raw.githubusercontent.com/ppmiralles0110/DiagnosticSettingsMonWS/ppmiralles0110-diagnostic-workbook-v1/DiagnosticSettingsInspector.workbook.json)**

The published branch can be imported before its PR is merged. The file is decoded `Notebook/1.0` content, not an ARM deployment template or an escaped `serializedData` string.

## Import into Azure

1. Open the **Raw JSON** link above and copy the entire file, including the outer braces. Do not copy GitHub's HTML page or Markdown fences.
2. In the Azure portal, go to **Azure Monitor > Workbooks > New** (or the **Empty** template). Select **Edit** if not already editing.
3. Open **Advanced Editor** using the **`</>`** toolbar button. Select **Gallery Template** if the editor offers a template-type selector/tab. Use the workbook-content JSON editor, **not ARM Template**.
4. Replace the editor contents with the complete JSON, then select **Apply**. Select **Done Editing** to use the workbook.
5. Select **Save**. Enter a name such as `Diagnostic Settings Inspector`, choose your approved **subscription, existing resource group, and location**, then save. Use normal workbook storage; this workbook does not require a storage account or managed identity.

Saving creates a workbook resource only; it does not modify diagnostic settings. The person importing must have permission to save it. Review/clear parameter values before saving or sharing if you do not want resource IDs stored as workbook defaults.

These steps follow Microsoft's [create/edit workbook](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook), [Advanced Editor / Gallery Template](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-automate#arm-template-for-deploying-a-workbook-template), and [save a workbook](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-manage#save-a-workbook) documentation. No deploy-to-Azure button or IaC is involved.

## Use it

1. Select one or more **Inventory subscriptions**, then **Inventory resource groups**. RG values use full IDs; labels include the subscription ID to distinguish duplicate names. Recheck RG selections after changing subscriptions.
2. Read the selected-scope count and resource list. Click a **ResourceId** cell to view/copy its full value.
3. Paste one ID into **Exact resource ID to inspect**. This required, validated text parameter is the single-resource selector. The inspector starts blank and does not automatically pick an inventory row.
4. Check the prominently displayed **Exact ARM target**. Read the **Live diagnostic settings** and **Live supported categories** tables. Click **LogEntries**, **MetricEntries**, and **CategoryGroups** to expand the JSON cells. Click a **Setting** for row details or scroll horizontally to read all destination IDs. Use **Refresh** to reread metadata.

**Inventory filters do not constrain the inspector.** Its target can be outside the selected inventory subscriptions/RGs. Changing inventory filters leaves the explicit target unchanged; clear or replace it to inspect another resource. There is no hidden grid-selection export that can silently retain an old target.

Each setting stays on its own row, with its complete log/metric arrays, enabled **and** disabled flags, category/group choices, and its own destination identifiers: workspace, storage account, Event Hubs authorization rule and hub name, marketplace partner, and Log Analytics destination type. Missing optional fields remain missing, not inferred. This is a manual comparison of configuration against availability, not a compliance evaluator. **Available != recommended**; `allLogs` is not recommended by default.

### Inspect a child resource

Copy a resource ID from the resource's **Properties** or **JSON View** in Azure. For an existing storage account's Blob service, append `/blobServices/default` to that account's ID and paste the resulting exact child ID. Other services may use different child types; obtain the exact ID from their resource metadata/documentation rather than guessing.

The inspector accepts resource-group-scoped resource IDs with provider/type/name pairs, including service children. It rejects URLs, trailing slashes, query strings, fragments, whitespace, and encoded characters. Subscription/RG/tenant/management-group targets and resource names containing those excluded characters are outside v1.

ARG does not expose every child resource. v1 does not enumerate children, inherit settings from parents, or aggregate parent/child results. In particular, inspecting a storage account is **not** equivalent to inspecting `blobServices/default`. See [Blob Storage monitoring](https://learn.microsoft.com/en-us/azure/storage/blobs/monitor-blob-storage).

## Permissions and data access

| Purpose | Required access |
| --- | --- |
| Inventory | Resource Graph access to the selected scope and source-resource read access, including subscription/RG discovery. ARG returns only resources the viewer can read. |
| Inspect the exact resource | `Microsoft.Insights/DiagnosticSettings/Read` and `Microsoft.Insights/DiagnosticSettingsCategories/Read` on that target, including a child target if applicable. |
| Open a saved workbook | `Microsoft.Insights/Workbooks/Read`, **plus** the underlying access above. |
| Import/save | Workbook write access (`Microsoft.Insights/Workbooks/Write`) in the approved RG, with the portal's required subscription/RG read access; for example, an approved Workbook Contributor assignment. This is separate from viewing. |

Reader on the relevant scope is convenient but broader than strict diagnostic-metadata-only access. Have your administrator scope custom roles/resource reads appropriately; this repository creates no roles or assignments. Workbook access alone does not grant source access.

Only two ARM metadata collection operations run for the target:

```text
GET {resourceId}/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview
GET {resourceId}/providers/Microsoft.Insights/diagnosticSettingsCategories?api-version=2021-05-01-preview
```

The workbook uses ARM `GETARRAY` to follow `nextLink` / `@odata.nextLink` pages for those collections. It is pagination, **not resource fanout**. Workbooks supplies the signed-in user's ARM authentication; no custom headers, secrets, `listKeys`, log-content reads, or writes are present. Destination IDs are configuration metadata; destinations are not queried.

## Empty results, failures, and limits

- **Empty versus failed:** `No diagnostic settings returned` and `No categories returned` are native query `noDataMessage` values for successful empty results only. Requests go directly to visible ARM query controls; there is no hidden result parameter, default-to-zero conversion, fallback JSON, or success/compliance badge. A 403, 404, 429, timeout, or other native request error must be read as an error, not as empty or unsupported. A 404 alone does not establish whether diagnostics are supported. Do not interpret loading, stale, or failed panels as a completed inspection.
- **Inventory is not coverage:** the server-side count uses the same subscription/RG filters as the list and counts ARG resources, not configured/missing diagnostic settings. No production rule is inferred. ARG is eventually consistent and RBAC-filtered.
- **Bounded results:** the inventory query deliberately takes at most **1,000 rows**, matching an ARG result page. No inventory paging/export engine is provided. The count is aggregated before any row limit, so it can exceed the displayed list. The count/list are separate reads. Narrow subscriptions/RGs when necessary. ARG source queries support at most 1,000 subscriptions; dropdowns have a 1,000-item limit. A grid's row limit does not enable paging. ARM grids have a 10,000-row ceiling (the general workbook query-result ceiling); this is not a completeness guarantee for arbitrarily large responses. Grid search affects returned rows only.
- **Scope and freshness:** one exact resource at a time; no estate-wide diagnostic totals, baseline approval, exemptions, compliance, recommendation engine, historical snapshots, or remediation. The two ARM reads are not an atomic snapshot; refresh after external changes. Unsupported services, wrong IDs, cloud/API availability, RBAC, and throttling can prevent reads.
- **Logs versus metrics:** exported platform metrics differ from resource logs and Metrics Explorer availability. Not every metric/dimension is exportable through diagnostic settings. Enabled configuration does not prove delivery, ingestion, retention, or destination health. See [diagnostic settings](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings).

## Local validation and first-run check

Run from the repository root with **PowerShell 7** (no packages required):

```powershell
pwsh -NoProfile -File .\tests\Test-Workbook.ps1
```

The check parses the outer/nested JSON, checks parameter dependencies, matching inventory scopes, read-only endpoint allowlists, and fixture projection of multiple settings, groups, disabled entries, missing optional arrays, pagination, empty results, a child target, and failed/malformed reads. It models only the JSONPath subset this workbook uses, **not the Azure Workbooks runtime**.

To additionally check the official schema, download the pinned public schema locally and pass its path (no Azure connection):

```powershell
$schema = Join-Path $env:TEMP 'azure-workbook-schema.json'
Invoke-WebRequest 'https://raw.githubusercontent.com/microsoft/Application-Insights-Workbooks/d37985b5b8588e644b0f3ff67700df12da3cd7f7/schema/workbook.json' -OutFile $schema
pwsh -NoProfile -File .\tests\Test-Workbook.ps1 -SchemaPath $schema
```

The official schema is permissive: schema/fixture success cannot prove portal rendering, KQL execution, parameter gating, RBAC, or service responses. **No Azure tenant was accessed and no live Azure validation was performed.** After import, verify a known resource with multiple settings, a successful empty resource, and an approved child target. Confirm blank/invalid targets do not run the inspector and that an approved known-inaccessible/missing target leaves native errors visible. No permission changes are needed for this check.

## Implementation references

- [Workbook ARM and ARG data sources](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-data-sources)
- [Workbook JSONPath transformations](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-jsonpath), [text parameter validation](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-text#add-validations), and [cell/row details links](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-link-actions)
- [Official scoped resource picker example](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Azure%20Monitor%20-%20Getting%20Started/Resource%20Picker/Resource%20Picker.workbook)
- [Official ARM/GETARRAY serialization example](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Windows%20Virtual%20Desktop/CheckAMAConfiguration/CheckAMAConfiguration.workbook) and [workbook schema](https://github.com/microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json)
- [Diagnostic settings List API](https://learn.microsoft.com/en-us/rest/api/monitor/diagnostic-settings/list?view=rest-monitor-2021-05-01-preview), [categories List API](https://learn.microsoft.com/en-us/rest/api/monitor/diagnostic-settings-category/list?view=rest-monitor-2021-05-01-preview), and [current REST specification](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/monitor/resource-manager/Microsoft.Insights/Insights/preview/2021-05-01-preview/openapi.json)
- [ARG large-result limits](https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/work-with-data#data-set-result-size) and [Azure Monitor service limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-monitor-limits)
