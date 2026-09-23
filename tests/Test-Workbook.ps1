#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $WorkbookPath = (Join-Path $PSScriptRoot '..\DiagnosticSettingsInspector.workbook.json'),
    [string] $SchemaPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:checks = 0

function Assert-That([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Assert-Throws([scriptblock] $Action, [string] $Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-That $threw $Message
}

function Get-Strings($Node) {
    if ($Node -is [string]) { $Node }
    elseif ($Node -is [System.Collections.IDictionary]) {
        foreach ($value in $Node.Values) { Get-Strings $value }
    }
    elseif ($Node -is [array]) {
        foreach ($value in $Node) { Get-Strings $value }
    }
}

function Assert-References($Node, [string[]] $KnownNames) {
    foreach ($text in (Get-Strings $Node)) {
        foreach ($match in [regex]::Matches($text, '\{([A-Za-z][A-Za-z0-9_]*)(?::[^{}]+)?\}')) {
            Assert-That ($match.Groups[1].Value -cin $KnownNames) "Unknown/forward parameter reference: $($match.Value)"
        }
    }
}

function Get-ProjectedColumns([string] $Query) {
    $lines = @($Query -split "`n" | Where-Object { $_.TrimStart().StartsWith('| project ') })
    if ($lines.Count -ne 1) { throw 'Query must have exactly one project clause.' }
    ($lines[0].Trim().Substring(10) -split ',') | ForEach-Object { ($_ -split '=')[0].Trim() }
}

function Resolve-JsonPath($Entry, [string] $Path, [bool] $Rooted) {
    $value = $Entry
    $trimmed = if ($Rooted) { $Path.Substring(2) } else { $Path }
    foreach ($part in $trimmed.Split('.')) {
        if ($value -is [System.Collections.IDictionary] -and $value.Contains($part)) { $value = $value[$part] }
        else { return $null }
    }
    if ($value -is [array]) { return ,$value }
    return $value
}

# Fixture adapters model only successful responses and the simple JSONPaths used
# here. They are not the portal's request engine, merge engine, or renderer.

# GETARRAY: follows nextLink/@odata.nextLink and merges pages into one array.
function Convert-CollectionFixture([System.Collections.IDictionary] $Query, [array] $Pages) {
    if ($Pages.Count -eq 0) { throw 'Missing response, not an empty collection.' }
    $rows = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Pages.Count; $i++) {
        $page = $Pages[$i]
        if ($page.status -ne 200) { throw "ARM request failed: HTTP $($page.status)" }
        if ($page.body -isnot [System.Collections.IDictionary] -or
            -not $page.body.Contains('value') -or $page.body.value -isnot [array]) {
            throw 'Malformed collection, not an empty result.'
        }
        $next = $page.body['nextLink']
        if (-not $next) { $next = $page.body['@odata.nextLink'] }
        if ([bool]$next -ne ($i -lt $Pages.Count - 1)) { throw 'Incomplete or unexpected fixture page chain.' }
        foreach ($entry in $page.body.value) {
            $row = [ordered]@{}
            foreach ($column in $Query.transformers[0].settings.columns) {
                $row[$column.columnid] = Resolve-JsonPath $entry $column.path $true
            }
            $rows.Add($row)
        }
    }
    return ,$rows
}

# GET fanned out over a multi-select parameter: one request per value, rows from
# $.value of each successful response, concatenated. A failed request is an error.
function Convert-FanoutFixture([System.Collections.IDictionary] $Query, [array] $Responses) {
    if ($Responses.Count -eq 0) { throw 'Missing responses, not an empty result.' }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($response in $Responses) {
        if ($response.status -ne 200) { throw "ARM request failed: HTTP $($response.status)" }
        if ($response.body -isnot [System.Collections.IDictionary] -or
            -not $response.body.Contains('value') -or $response.body.value -isnot [array]) {
            throw 'Malformed collection, not an empty result.'
        }
        foreach ($entry in $response.body.value) {
            $row = [ordered]@{}
            foreach ($column in $Query.transformers[0].settings.columns) {
                $value = Resolve-JsonPath $entry $column.path $false
                if ($column.Contains('substringRegexMatch') -and $value -is [string]) {
                    if ($value -notmatch $column.substringRegexMatch) { throw 'Row cannot be attributed to a resource.' }
                    $value = [regex]::Replace($value, $column.substringRegexMatch, $column.substringReplace)
                }
                $row[$column.columnid] = $value
            }
            $rows.Add($row)
        }
    }
    return ,$rows
}

# Merge/1.0 over already-retrieved tables. Joins are string comparisons.
function Invoke-MergeFixture([System.Collections.IDictionary] $Merge, [hashtable] $Tables) {
    $join = $Merge.merges[0]
    foreach ($side in @($join.leftTable, $join.rightTable)) {
        if (-not $Tables.ContainsKey($side)) { throw "Merge references an unknown table: $side" }
    }
    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($left in $Tables[$join.leftTable]) {
        $matched = @($Tables[$join.rightTable] | Where-Object { $_[$join.rightColumn] -ceq $left[$join.leftColumn] })
        switch ($join.mergeType) {
            'leftouter' {
                if ($matched.Count -eq 0) { $pairs.Add(@{ left = $left; right = $null }) }
                else { foreach ($right in $matched) { $pairs.Add(@{ left = $left; right = $right }) } }
            }
            'leftanti' { if ($matched.Count -eq 0) { $pairs.Add(@{ left = $left; right = $null }) } }
            default { throw "Unsupported merge type: $($join.mergeType)" }
        }
    }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($pair in $pairs) {
        $row = [ordered]@{}
        foreach ($projection in $Merge.projectRename) {
            if (-not $projection.Contains('mergedName')) { continue }
            if ($projection.Contains('isNewItem') -and $projection.isNewItem) {
                $value = $null
                foreach ($criteria in $projection.newItemData) {
                    $context = $criteria.criteriaContext
                    if ($context.operator -ceq 'Default') { $value = $context.resultVal; break }
                    if (-not $row.Contains($context.leftOperand)) { throw "Criteria reads an undefined column: $($context.leftOperand)" }
                    if ($context.operator -ceq 'isNotNull' -and $null -ne $row[$context.leftOperand]) {
                        $value = $context.resultVal
                        break
                    }
                }
                $row[$projection.mergedName] = $value
                continue
            }
            if ($projection.originalName -notmatch '^\[(?<table>.+)\]\.(?<column>.+)$') { throw "Unparsable projection: $($projection.originalName)" }
            $table = $Matches.table
            $column = $Matches.column
            $source = if ($table -ceq $join.leftTable) { $pair.left } elseif ($table -ceq $join.rightTable) { $pair.right } else { throw "Projection from an unjoined table: $table" }
            $row[$projection.mergedName] = if ($null -eq $source) { $null } else { $source[$column] }
        }
        $result.Add($row)
    }
    return ,$result
}

$raw = Get-Content -LiteralPath $WorkbookPath -Raw
$workbook = $raw | ConvertFrom-Json -AsHashtable -Depth 100
Assert-That ($workbook.version -ceq 'Notebook/1.0') 'Must be decoded Notebook/1.0 content.'
Assert-That ($workbook.items.Count -gt 0) 'Workbook must have content.'
Assert-That (-not $workbook.ContainsKey('resources') -and -not $workbook.ContainsKey('serializedData')) 'Do not ship IaC or encoded content.'
if ($SchemaPath) {
    Assert-That (Test-Json -Json $raw -SchemaFile $SchemaPath) 'Official workbook schema validation failed.'
}

$names = @()
$parameters = @{}
$items = @{}
$itemIndex = @{}
$armQueries = @{}
$merges = @{}
$detailSuffixes = @{
    DiagnosticSettings = 'diagnosticSettings'
    SupportedCategories = 'diagnosticSettingsCategories'
}
$position = 0
foreach ($item in $workbook.items) {
    Assert-That (-not $items.ContainsKey($item.name)) "Duplicate item name: $($item.name)"
    $items[$item.name] = $item
    $itemIndex[$item.name] = $position
    $position++
    Assert-That ($item.type -in @(1, 3, 9)) 'Only text, parameter, and query items are expected.'
    if ($item.type -eq 9) {
        Assert-That ($item.content.version -ceq 'KqlParameterItem/1.0') 'Unexpected parameter version.'
        foreach ($parameter in $item.content.parameters) {
            Assert-References $parameter $names
            Assert-That (-not $parameters.ContainsKey($parameter.name)) "Duplicate parameter: $($parameter.name)"
            $parameters[$parameter.name] = $parameter
            $names += $parameter.name
        }
    }
    else {
        Assert-References $item $names
    }
    if ($item.ContainsKey('conditionalVisibility')) {
        Assert-That ($item.conditionalVisibility.parameterName -cin $names) 'Visibility must reference a defined parameter.'
    }
    if ($item.type -ne 3) { continue }
    Assert-That ($item.content.version -ceq 'KqlItem/1.0') 'Unexpected query item version.'
    Assert-That ($item.content.queryType -in @(1, 7, 12)) 'No Log Analytics, fallback JSON, or backend sources.'
    if ($item.content.ContainsKey('exportedParameters')) {
        Assert-That ($item.name -ceq 'Coverage') 'Only the coverage grid may set the detail target.'
        $exported = $item.content.exportedParameters
        Assert-That ($exported.Count -eq 1 -and $exported[0].fieldName -ceq 'ResourceId' -and
            $exported[0].parameterName -ceq 'SelectedResource' -and $exported[0].parameterType -eq 5 -and
            $exported[0].defaultValue -ceq 'NotSelected') 'Selection must export the resource ID with an explicit unselected default.'
        $names += $exported[0].parameterName
    }
    if ($item.content.queryType -eq 1) {
        Assert-That ($item.content.resourceType -ceq 'microsoft.resourcegraph/resources') 'Inventory must use ARG.'
        Assert-That (($item.content.crossComponentResources -join '') -ceq '{Subscriptions}') 'Inventory query must use selected subscriptions.'
        continue
    }
    $query = $item.content.query | ConvertFrom-Json -AsHashtable -Depth 100
    if ($item.content.queryType -eq 7) {
        Assert-That ($query.version -ceq 'Merge/1.0' -and $query.merges.Count -eq 1) 'Only a single documented join per merged view.'
        $merges[$item.name] = $query
        continue
    }
    $armQueries[$item.name] = $query
    Assert-That ($query.version -ceq 'ARMEndpoint/1.0') 'ARM panels must use the ARM endpoint source.'
    Assert-That ($null -eq $query.data -and $query.headers.Count -eq 0) 'No bodies or custom credentials.'
    Assert-That ($query.transformers.Count -eq 1 -and $query.transformers[0].type -ceq 'jsonpath') 'Only a direct JSONPath projection is expected.'
    if ($item.name -ceq 'DiagnosticSettingsFanout') {
        Assert-That ($query.method -ceq 'GET') 'Bulk reads fan a plain GET across the selected resources.'
        Assert-That ($query.path -ceq '{TargetResources}/providers/Microsoft.Insights/diagnosticSettings') 'Bulk path must fan out over the resource parameter.'
        Assert-That ($query.urlParams.Count -eq 1 -and $query.urlParams[0].key -ceq 'api-version' -and
            $query.urlParams[0].value -ceq '2021-05-01-preview') 'Pin the documented diagnostic settings API version.'
        Assert-That ($query.transformers[0].settings.tablePath -ceq '$.value') 'A plain GET returns a value wrapper.'
        $attribution = @($query.transformers[0].settings.columns | Where-Object { $_.columnid -ceq 'ResourceId' })
        Assert-That ($attribution.Count -eq 1 -and $attribution[0].path -ceq 'id' -and
            $attribution[0].substringReplace -ceq '$1') 'Bulk rows must be attributed back to their own resource ID.'
        Assert-That ($item.conditionalVisibility.parameterName -ceq 'TargetResources') 'Bulk reads must wait for an explicit resource selection.'
        continue
    }
    Assert-That ($detailSuffixes.ContainsKey($item.name)) 'Unexpected ARM panel.'
    Assert-That ($query.method -ceq 'GETARRAY') 'Detail panels must follow collection pages.'
    $expectedPath = '{SelectedResource:escapejson}{ChildPath:escapejson}/providers/Microsoft.Insights/' + $detailSuffixes[$item.name] + '?api-version=2021-05-01-preview'
    Assert-That ($query.path -ceq $expectedPath) "Unexpected ARM path: $($query.path)"
    Assert-That ($query.urlParams.Count -eq 0) 'No extra request options on detail reads.'
    Assert-That ($query.transformers[0].settings.tablePath -ceq '') 'GETARRAY returns a merged array, not a value wrapper.'
    foreach ($column in $query.transformers[0].settings.columns) {
        Assert-That ($column.path -cmatch '^\$\.[A-Za-z]+(?:\.[A-Za-z]+)*$') 'Paths must preserve entire arrays, with no first-item selection/filtering.'
        Assert-That (-not $column.ContainsKey('columnType') -and -not $column.ContainsKey('substringReplace')) 'Do not coerce flags/arrays or manufacture result values.'
    }
    Assert-That ($item.conditionalVisibility.parameterName -ceq 'SelectedResource' -and
        $item.conditionalVisibility.comparison -ceq 'isNotEqualTo' -and
        $item.conditionalVisibility.value -ceq 'NotSelected') 'Detail panels must be gated on an explicit selection.'
}
Assert-That ($armQueries.Count -eq 3) 'One bulk read and two detail collections are expected.'
Assert-That ($merges.Count -eq 2) 'A coverage view and an explicit no-settings view are expected.'
Assert-That ($parameters.Count -eq 5) 'No hidden error-to-empty/status parameters are expected.'

Assert-That ($parameters.Subscriptions.type -eq 6 -and $parameters.Subscriptions.multiSelect -and $parameters.Subscriptions.isRequired) 'Require explicit multi-subscription scope.'
Assert-That ($parameters.ResourceGroups.type -eq 2 -and $parameters.ResourceGroups.multiSelect -and $parameters.ResourceGroups.isRequired) 'Require RG multiselect.'
Assert-That (-not $parameters.ResourceGroups.ContainsKey('value')) 'Resource groups must not default to every group: each one costs live ARM reads.'
Assert-That (($parameters.ResourceGroups.crossComponentResources -join '') -ceq '{Subscriptions}') 'RG list must depend on subscriptions.'
Assert-That ($parameters.ResourceGroups.query.Contains("type =~ 'microsoft.resources/subscriptions/resourcegroups'") -and
    $parameters.ResourceGroups.query.Contains('value = tolower(id)') -and
    $parameters.ResourceGroups.query.Contains("strcat(name, '  |  ', subscriptionId)")) 'RG choices need full IDs and distinguishable labels.'
Assert-That ($parameters.ResourceGroups.typeSettings.selectAllValue -ceq '*' -and
    $parameters.ResourceGroups.typeSettings.additionalResourceOptions[0] -ceq 'value::all') 'RG All sentinel must match the scope queries.'
Assert-That ($parameters.ResourceTypes.type -eq 2 -and $parameters.ResourceTypes.multiSelect -and
    $parameters.ResourceTypes.isRequired) 'Type filter must be a required multiselect.'
# A single failing sub-request fails the whole batched ARM query, so the type filter
# must not offer an "All" escape hatch that silently re-adds unsupported types.
Assert-That (-not $parameters.ResourceTypes.ContainsKey('value') -and
    $parameters.ResourceTypes.typeSettings.additionalResourceOptions.Count -eq 0 -and
    -not $parameters.ResourceTypes.typeSettings.ContainsKey('selectAllValue')) 'Type filter must not offer a blanket All option.'
Assert-That ($parameters.TargetResources.type -eq 5 -and $parameters.TargetResources.multiSelect -and $parameters.TargetResources.isRequired -and
    -not $parameters.TargetResources.ContainsKey('value') -and -not $parameters.TargetResources.ContainsKey('defaultValue') -and
    $parameters.TargetResources.typeSettings.additionalResourceOptions[0] -ceq 'value::all') 'Bulk target list must start empty and still offer All.'
foreach ($parameter in @($parameters.Subscriptions, $parameters.ResourceGroups, $parameters.ResourceTypes, $parameters.TargetResources)) {
    Assert-That ($parameter.quote -ceq "'" -and $parameter.delimiter -ceq ',') 'KQL multiselect must be quoted and comma delimited.'
}

$rgFilter = "| where '*' in ({ResourceGroups}) or ResourceGroupId in~ ({ResourceGroups})"
$typeFilter = '| where tolower(type) in~ ({ResourceTypes})'
foreach ($query in @($parameters.TargetResources.query, $items.ScopeInventory.content.query)) {
    Assert-That ($query.Contains($rgFilter) -and $query.Contains($typeFilter)) 'The picker and the inventory must share every scope filter.'
}
Assert-That ($parameters.ResourceTypes.query.Contains($rgFilter)) 'Type choices must be scoped to the selected resource groups.'

# The pre-selected set is the documented "has platform logs or metrics" list. Types
# outside it stay listed but unselected, so the user still chooses.
Assert-That ($parameters.ResourceTypes.query.Contains('| extend Supported = TypeName in (') -and
    $parameters.ResourceTypes.query.Contains('selected = Supported')) 'Supported types must be pre-selected, not hidden.'
foreach ($supported in "'microsoft.storage/storageaccounts'", "'microsoft.keyvault/vaults'",
    "'microsoft.compute/virtualmachines'", "'microsoft.cognitiveservices/accounts'",
    "'microsoft.storage/storageaccounts/blobservices'", "'microsoft.web/sites'") {
    Assert-That ($parameters.ResourceTypes.query.Contains($supported)) "Supported-type list must contain $supported."
}
Assert-That (-not $parameters.ResourceTypes.query.Contains("'microsoft.managedidentity/userassignedidentities'")) 'Types with no platform logs or metrics must not be pre-selected.'
Assert-That ($parameters.ResourceTypes.query.Contains('not documented for platform logs or metrics')) 'Unlisted types must be labelled, not silently dropped.'

Assert-That ($items.ScopeInventory.content.query.Contains('| where id in~ ({TargetResources})')) 'Inventory must cover exactly the resources that are read.'

# Resources that were skipped must be reported as skipped, never folded into coverage.
$notChecked = $items.NotChecked
Assert-That ($null -ne $notChecked -and $notChecked.content.queryType -eq 1) 'Skipped resources need their own Azure Resource Graph grid.'
Assert-That ($notChecked.content.query.Contains('| where tolower(type) !in~ ({ResourceTypes})')) 'The skipped grid must be the exact complement of the checked types.'
Assert-That ($notChecked.content.query.Contains("Status = 'Not checked")) 'Skipped resources must be labelled Not checked.'
foreach ($forbidden in 'compliant', 'Compliant', 'not configured', 'No setting returned') {
    Assert-That (-not $notChecked.content.query.Contains($forbidden)) "Skipped resources must not be given a $forbidden verdict."
}
Assert-That (-not $merges.Values.projectRename.originalName.Contains('[NotChecked].ResourceId')) 'Skipped resources must stay out of the coverage merges.'
Assert-That ($items.ScopeInventory.content.query.EndsWith('| take 1000') -and
    $items.ScopeInventory.content.gridSettings.rowLimit -eq 1000) 'Inventory has an explicit, documented 1,000-row cap.'

$inventoryColumns = Get-ProjectedColumns $items.ScopeInventory.content.query
$fanoutColumns = $armQueries.DiagnosticSettingsFanout.transformers[0].settings.columns.columnid
$sourceColumns = @{ ScopeInventory = $inventoryColumns; DiagnosticSettingsFanout = $fanoutColumns }
foreach ($name in $merges.Keys) {
    $merge = $merges[$name]
    $join = $merge.merges[0]
    Assert-That ($join.leftTable -ceq 'ScopeInventory' -and $join.rightTable -ceq 'DiagnosticSettingsFanout') 'Merged views must join the inventory to the live ARM reads.'
    Assert-That ($items.ContainsKey($join.leftTable) -and $items.ContainsKey($join.rightTable)) 'Merged views must reference real steps by name.'
    # A merge step can only read steps that appear before it; otherwise the portal
    # reports "no steps that export data at this point" / "Could not find table".
    foreach ($side in @($join.leftTable, $join.rightTable)) {
        Assert-That ($itemIndex[$side] -lt $itemIndex[$name]) "Merge '$name' must appear after its source step '$side'."
    }
    Assert-That ($join.leftColumn -ceq 'ResourceId' -and $join.rightColumn -ceq 'ResourceId') 'Join on the resource ID only.'
    foreach ($projection in $merge.projectRename) {
        if ($projection.Contains('isNewItem') -and $projection.isNewItem) {
            Assert-That ($projection.originalName -ceq '[Added column]' -and $null -eq $projection.fromId) 'Computed columns must be declared as added columns.'
            $defaults = @($projection.newItemData | Where-Object { $_.criteriaContext.operator -ceq 'Default' })
            Assert-That ($defaults.Count -eq 1 -and $defaults[0].criteriaContext.resultValType -ceq 'static') 'Every computed column needs one explicit static fallback.'
            continue
        }
        Assert-That ($projection.originalName -match '^\[(?<table>.+)\]\.(?<column>.+)$') "Unparsable projection: $($projection.originalName)"
        Assert-That ($Matches.column -cin $sourceColumns[$Matches.table]) "Projection reads a column its step never returns: $($projection.originalName)"
    }
}
$status = @($merges.Coverage.projectRename | Where-Object { $_.Contains('mergedName') -and $_.mergedName -ceq 'Diagnostic settings' })
Assert-That ($status.Count -eq 1 -and $status[0].newItemData[0].criteriaContext.leftOperand -ceq 'Setting name' -and
    $status[0].newItemData[0].criteriaContext.operator -ceq 'isNotNull') 'Coverage status must be derived from whether a setting was actually returned.'
Assert-That ($status[0].newItemData[0].criteriaContext.resultVal -ceq 'Setting returned' -and
    $status[0].newItemData[1].criteriaContext.resultVal -ceq 'No setting returned') 'Status wording must describe what was returned, not compliance.'
Assert-That ($merges.Coverage.merges[0].mergeType -ceq 'leftouter') 'Coverage must keep every in-scope resource, including ones with no settings.'
Assert-That ($merges.NoSettingsReturned.merges[0].mergeType -ceq 'leftanti') 'The no-settings view must be an anti-join, not a filter on a manufactured value.'

Assert-That ($items.DiagnosticSettings.content.noDataMessage -ceq 'No diagnostic settings returned') 'Use a native success-empty settings message.'
Assert-That ($items.SupportedCategories.content.noDataMessage -ceq 'No categories returned') 'Empty categories must not mean unsupported.'
Assert-That ($raw -notmatch '(?i)listkeys|armActionContext|"method"\s*:\s*"(POST|PUT|PATCH|DELETE)"') 'No keys or mutation actions.'
Assert-That ($raw -notmatch '(?i)/subscriptions/[0-9a-f]{8}-') 'No embedded tenant resource IDs.'
foreach ($word in @('compliant', 'non-compliant', 'baseline', 'unsupported resource', 'recommended setting')) {
    Assert-That ($items.GuidanceAndLimits.content.json -notmatch "(?i)\bis $word\b") 'Do not state a compliance verdict.'
}
foreach ($phrase in @('No setting returned', 'one ARM request per resource', 'casing', 'blobServices')) {
    $documented = ($items.GuidanceAndLimits.content.json -match [regex]::Escape($phrase)) -or
        ($items.GuidanceAndLimits.content.json -match '(?i)' + [regex]::Escape($phrase))
    Assert-That $documented "Limitations must document: $phrase"
}

$child = $parameters.ChildPath
Assert-That ($child.type -eq 1 -and -not $child.isRequired -and $child.value -ceq '' -and -not $child.ContainsKey('query')) 'The child suffix is optional, blank by default, and typed by hand.'
$rule = $child.typeSettings.paramValidationRules[0]
Assert-That ($rule.match -and $rule.message.Length -gt 0) 'Child suffix validation must report invalid input.'
$sub = '00000000-0000-0000-0000-000000000001'
$resource = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.Storage/storageAccounts/fixtureaccount"
foreach ($valid in @('', '/blobServices/default', '/blobServices/default/containers/fixture')) {
    Assert-That ([regex]::IsMatch($valid, $rule.regExp)) "Valid child suffix rejected: '$valid'"
    foreach ($query in @($armQueries.DiagnosticSettings, $armQueries.SupportedCategories)) {
        $expanded = $query.path.Replace('{SelectedResource:escapejson}', $resource).Replace('{ChildPath:escapejson}', $valid)
        Assert-That ($expanded.StartsWith("$resource$valid/providers/Microsoft.Insights/") -and
            -not $expanded.Contains('//')) 'Keep the exact child target and avoid double slashes.'
    }
}
foreach ($invalid in @('blobServices/default', '/blobServices', '/blobServices/default/', 'https://portal.azure.com/',
    "/blobServices/default`n", '/blobServices/def ault', '/blobServices/default?api-version=x', '/blobServices/{Other}')) {
    Assert-That (-not [regex]::IsMatch($invalid, $rule.regExp)) "Invalid child suffix accepted: '$invalid'"
}

$settings = @(
    @{ name = 'workspace'; id = "$resource/providers/microsoft.insights/diagnosticSettings/workspace"; properties = @{
        logs = @(@{ categoryGroup = 'audit'; enabled = $true }, @{ category = 'StorageRead'; enabled = $false })
        metrics = @(@{ category = 'AllMetrics'; enabled = $true })
        workspaceId = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.OperationalInsights/workspaces/fixtureworkspace"
        logAnalyticsDestinationType = 'Dedicated'
    } },
    @{ name = 'events'; id = "$resource/providers/Microsoft.Insights/diagnosticSettings/events"; properties = @{
        logs = @(@{ categoryGroup = 'allLogs'; enabled = $false }, @{ category = 'StorageWrite'; enabled = $true })
        eventHubAuthorizationRuleId = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.EventHub/namespaces/fixturehub/authorizationRules/fixture-rule"
        eventHubName = 'fixture-events'
        marketplacePartnerId = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.Example/partners/fixture-partner"
    } },
    @{ name = 'metrics-only'; id = "$resource/providers/Microsoft.Insights/diagnosticSettings/metrics-only"; properties = @{
        metrics = @(@{ category = 'AllMetrics'; enabled = $false })
        storageAccountId = $resource
    } },
    @{ name = 'empty-arrays'; id = "$resource/providers/Microsoft.Insights/diagnosticSettings/empty-arrays"; properties = @{
        logs = @(); metrics = @()
    } }
)
$pages = @(
    @{ status = 200; body = @{ value = @($settings[0], $settings[1]); nextLink = 'fixture-page-2' } },
    @{ status = 200; body = @{ value = @($settings[2], $settings[3]) } }
)
$rows = Convert-CollectionFixture $armQueries.DiagnosticSettings $pages
Assert-That ($rows.Count -eq 4) 'Every setting on every page must survive.'
Assert-That ($rows[0].LogEntries.Count -eq 2 -and $rows[0].LogEntries[0].categoryGroup -ceq 'audit') 'Preserve all log entries and groups.'
Assert-That ($rows[0].LogEntries[0].enabled -ceq $true -and $rows[0].LogEntries[1].enabled -ceq $false) 'Preserve both boolean states.'
Assert-That ($rows[0].WorkspaceId -ceq $settings[0].properties.workspaceId -and $rows[0].LogAnalyticsDestinationType -ceq 'Dedicated') 'Keep workspace and destination mode on their own setting.'
Assert-That ($rows[1].EventHubAuthorizationRuleId -ceq $settings[1].properties.eventHubAuthorizationRuleId -and
    $rows[1].EventHubName -ceq 'fixture-events' -and $null -eq $rows[1].WorkspaceId -and
    $rows[1].MarketplacePartnerId -ceq $settings[1].properties.marketplacePartnerId) 'Keep Event Hubs/partner destinations distinct from the workspace setting.'
Assert-That ($null -eq $rows[1].MetricEntries -and $null -eq $rows[2].LogEntries -and
    $rows[2].MetricEntries[0].enabled -ceq $false -and $rows[2].StorageAccountId -ceq $resource) 'Absent optional arrays and metrics-only settings must survive.'
Assert-That ($rows[3].LogEntries -is [array] -and $rows[3].LogEntries.Count -eq 0 -and $rows[3].MetricEntries.Count -eq 0) 'Preserve empty arrays without deleting their setting.'
Assert-That ($rows[0].SettingId -ceq $settings[0].id -and $rows[2].Setting -ceq 'metrics-only') 'Keep setting identifiers.'
$pages[0].body.Remove('nextLink')
$pages[0].body['@odata.nextLink'] = 'fixture-page-2'
Assert-That ((Convert-CollectionFixture $armQueries.DiagnosticSettings $pages).Count -eq 4) 'Both pagination link conventions are modeled.'

$categoryPages = @(@{ status = 200; body = @{ value = @(
    @{ name = 'StorageRead'; id = "$resource/blobServices/default/providers/Microsoft.Insights/diagnosticSettingsCategories/StorageRead"; properties = @{ categoryType = 'Logs'; categoryGroups = @('audit', 'allLogs') } },
    @{ name = 'StorageWrite'; properties = @{ categoryType = 'Logs'; categoryGroups = @() } },
    @{ name = 'AllMetrics'; properties = @{ categoryType = 'Metrics' } }
) } })
$categories = Convert-CollectionFixture $armQueries.SupportedCategories $categoryPages
Assert-That ($categories.Count -eq 3 -and $categories[0].CategoryGroups.Count -eq 2 -and
    $categories[0].CategoryId.StartsWith("$resource/blobServices/default") -and $categories[2].CategoryType -ceq 'Metrics' -and
    $null -eq $categories[2].CategoryGroups) 'Preserve categories, groups, metrics, missing groups, and child identity.'
foreach ($query in @($armQueries.DiagnosticSettings, $armQueries.SupportedCategories)) {
    Assert-That ((Convert-CollectionFixture $query @(@{ status = 200; body = @{ value = @() } })).Count -eq 0) 'A successful empty collection is empty.'
    foreach ($status in @(403, 404, 429, 500)) {
        Assert-Throws { Convert-CollectionFixture $query @(@{ status = $status; body = @{ error = @{ code = 'FixtureFailure' } } }) } "HTTP $status must not become empty."
    }
    Assert-Throws { Convert-CollectionFixture $query @() } 'Missing responses must not become empty.'
    Assert-Throws { Convert-CollectionFixture $query @(@{ status = 200; body = @{} }) } 'Missing value array must not become empty.'
    Assert-Throws { Convert-CollectionFixture $query @(@{ status = 200; body = @{ value = $null } }) } 'Null value must not become empty.'
    Assert-Throws { Convert-CollectionFixture $query @(@{ status = 200; body = @{ value = @(); nextLink = 'fixture-page-2' } }) } 'An incomplete page chain must not count as success.'
    Assert-Throws { Convert-CollectionFixture $query @($pages[0], @{ status = 429; body = @{ error = @{ code = 'Throttled' } } }) } 'A later-page error must not return partial success.'
}

$configured = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.Storage/storageAccounts/fixtureaccount"
$bare = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.Network/networkSecurityGroups/fixture-nsg"
$denied = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.KeyVault/vaults/fixturevault"
$inventory = @(
    [ordered]@{ Name = 'fixtureaccount'; Type = 'microsoft.storage/storageaccounts'; ResourceGroup = 'fixture-rg'; SubscriptionId = $sub; Location = 'westeurope'; ResourceId = $configured },
    [ordered]@{ Name = 'fixture-nsg'; Type = 'microsoft.network/networksecuritygroups'; ResourceGroup = 'fixture-rg'; SubscriptionId = $sub; Location = 'westeurope'; ResourceId = $bare },
    [ordered]@{ Name = 'fixturevault'; Type = 'microsoft.keyvault/vaults'; ResourceGroup = 'fixture-rg'; SubscriptionId = $sub; Location = 'westeurope'; ResourceId = $denied }
)
$fanoutQuery = $armQueries.DiagnosticSettingsFanout
$fanoutResponses = @(
    @{ status = 200; body = @{ value = @($settings[0], $settings[1]) } },
    @{ status = 200; body = @{ value = @() } }
)
$fanoutRows = Convert-FanoutFixture $fanoutQuery $fanoutResponses
Assert-That ($fanoutRows.Count -eq 2) 'Only resources that returned settings contribute rows.'
Assert-That ($fanoutRows[0].ResourceId -ceq $configured -and $fanoutRows[1].ResourceId -ceq $configured) 'Rows must be attributed to their own resource, whatever the provider casing.'
Assert-That ($fanoutRows[0].SettingName -ceq 'workspace' -and $fanoutRows[0].LogEntries[0].enabled -ceq $true -and
    $fanoutRows[0].LogEntries[1].enabled -ceq $false -and $fanoutRows[0].WorkspaceId -ceq $settings[0].properties.workspaceId) 'Bulk rows keep enabled flags, groups, and destinations.'
Assert-That ($fanoutRows[1].EventHubName -ceq 'fixture-events' -and $null -eq $fanoutRows[1].WorkspaceId) 'Each bulk row keeps only its own destinations.'
Assert-Throws { Convert-FanoutFixture $fanoutQuery @($fanoutResponses[0], @{ status = 403; body = @{ error = @{ code = 'AuthorizationFailed' } } }) } 'A denied resource must surface as an error, never as coverage.'
Assert-Throws { Convert-FanoutFixture $fanoutQuery @(@{ status = 404; body = @{ error = @{ code = 'ResourceTypeNotSupported' } } }) } 'An unsupported type must surface as an error, not as zero settings.'
Assert-Throws { Convert-FanoutFixture $fanoutQuery @() } 'Missing bulk responses must not become empty coverage.'

$tables = @{ ScopeInventory = $inventory; DiagnosticSettingsFanout = $fanoutRows }
$coverage = Invoke-MergeFixture $merges.Coverage $tables
Assert-That ($coverage.Count -eq 4) 'Every in-scope resource stays visible, once per returned setting.'
Assert-That (@($coverage | Where-Object { $_.ResourceId -ceq $configured }).Count -eq 2) 'A resource with two settings shows both.'
Assert-That ((@($coverage | Where-Object { $_.ResourceId -ceq $configured }).'Diagnostic settings' | Sort-Object -Unique) -ceq 'Setting returned') 'Returned settings must be labelled as returned.'
foreach ($id in @($bare, $denied)) {
    $row = @($coverage | Where-Object { $_.ResourceId -ceq $id })
    Assert-That ($row.Count -eq 1 -and $row[0].'Diagnostic settings' -ceq 'No setting returned' -and $null -eq $row[0].'Setting name') 'Resources without returned settings stay listed with an honest status.'
}
Assert-That ($coverage[0].Resource -ceq 'fixtureaccount' -and $coverage[0].'Log Analytics workspace' -ceq $settings[0].properties.workspaceId -and
    $coverage[0].'Log entries'.Count -eq 2) 'Coverage rows keep inventory identity and setting detail together.'
$noSettings = Invoke-MergeFixture $merges.NoSettingsReturned $tables
Assert-That ($noSettings.Count -eq 2 -and ($noSettings.ResourceId -ccontains $bare) -and ($noSettings.ResourceId -ccontains $denied) -and
    -not ($noSettings.ResourceId -ccontains $configured)) 'The anti-join lists exactly the resources that returned nothing.'
Assert-That ($noSettings[0].Subscription -ceq $sub -and $noSettings[0].Location -ceq 'westeurope') 'The no-settings list keeps enough identity to act on.'

$mismatched = @([ordered]@{ ResourceId = $configured.ToUpperInvariant(); SettingName = 'workspace'; LogEntries = $null; MetricEntries = $null
    WorkspaceId = $null; StorageAccountId = $null; EventHubAuthorizationRuleId = $null; EventHubName = $null
    MarketplacePartnerId = $null; LogAnalyticsDestinationType = $null; SettingId = $settings[0].id })
$mismatchedCoverage = Invoke-MergeFixture $merges.Coverage @{ ScopeInventory = $inventory; DiagnosticSettingsFanout = $mismatched }
Assert-That ((@($mismatchedCoverage | Where-Object { $_.ResourceId -ceq $configured })[0]).'Diagnostic settings' -ceq 'No setting returned') 'A resource ID casing mismatch degrades to the documented no-setting status, which is why the detail panel is authoritative.'

$schemaResult = if ($SchemaPath) { 'included' } else { 'not requested (use -SchemaPath)' }
Write-Output "PASS: $script:checks local assertions; official schema: $schemaResult. No Azure requests were made. Portal behavior is not verified by these checks."
