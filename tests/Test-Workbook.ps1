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

# This fixture adapter models only successful GETARRAY page merging and the
# simple property JSONPaths used here. It is not the portal's request engine.
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
                $value = $entry
                foreach ($part in $column.path.Substring(2).Split('.')) {
                    if ($value -is [System.Collections.IDictionary] -and $value.Contains($part)) {
                        $value = $value[$part]
                    }
                    else { $value = $null; break }
                }
                $row[$column.columnid] = $value
            }
            $rows.Add($row)
        }
    }
    return ,$rows
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
$armQueries = @{}
$allowedSuffixes = @{
    DiagnosticSettings = 'diagnosticSettings'
    SupportedCategories = 'diagnosticSettingsCategories'
}
foreach ($item in $workbook.items) {
    Assert-That (-not $items.ContainsKey($item.name)) "Duplicate item name: $($item.name)"
    $items[$item.name] = $item
    Assert-That ($item.type -in @(1, 3, 9)) 'v1 should contain only text, parameters, and queries.'
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
    Assert-That ($item.content.queryType -in @(1, 12)) 'No Log Analytics, fallback JSON, or backend sources.'
    Assert-That (-not $item.content.ContainsKey('exportedParameters')) 'Inventory must not silently retarget the inspector.'
    if ($item.content.queryType -eq 1) {
        Assert-That ($item.content.resourceType -ceq 'microsoft.resourcegraph/resources') 'Inventory must use ARG.'
        Assert-That (($item.content.crossComponentResources -join '') -ceq '{Subscriptions}') 'Inventory query must use selected subscriptions.'
        continue
    }
    $query = $item.content.query | ConvertFrom-Json -AsHashtable -Depth 100
    $armQueries[$item.name] = $query
    Assert-That ($allowedSuffixes.ContainsKey($item.name)) 'Unexpected ARM panel.'
    Assert-That ($query.version -ceq 'ARMEndpoint/1.0' -and $query.method -ceq 'GETARRAY') 'Use read-only paginated collection requests.'
    $expectedPath = '{TargetResourceId:escapejson}/providers/Microsoft.Insights/' + $allowedSuffixes[$item.name] + '?api-version=2021-05-01-preview'
    Assert-That ($query.path -ceq $expectedPath) "Unexpected ARM path: $($query.path)"
    Assert-That ($null -eq $query.data -and $query.headers.Count -eq 0 -and $query.urlParams.Count -eq 0) 'No bodies, credentials, or extra request options.'
    Assert-That ($query.transformers.Count -eq 1 -and $query.transformers[0].type -ceq 'jsonpath') 'Only a direct JSONPath projection is expected.'
    Assert-That ($query.transformers[0].settings.tablePath -ceq '') 'GETARRAY returns a merged array, not a value wrapper.'
    foreach ($column in $query.transformers[0].settings.columns) {
        Assert-That ($column.path -cmatch '^\$\.[A-Za-z]+(?:\.[A-Za-z]+)*$') 'Paths must preserve entire arrays, with no first-item selection/filtering.'
        Assert-That (-not $column.ContainsKey('columnType') -and -not $column.ContainsKey('substringReplace')) 'Do not coerce flags/arrays or manufacture result values.'
    }
    Assert-That ($item.conditionalVisibility.parameterName -ceq 'TargetResourceId' -and
        $item.conditionalVisibility.comparison -ceq 'isNotEqualTo' -and
        $item.conditionalVisibility.value -ceq '') 'ARM panels must be gated on an explicit target.'
}
Assert-That ($armQueries.Count -eq 2) 'Exactly two ARM metadata collections are expected.'
Assert-That ($parameters.Count -eq 3) 'No hidden error-to-empty/status parameters are expected.'
Assert-That ($parameters.Subscriptions.type -eq 6 -and $parameters.Subscriptions.multiSelect -and $parameters.Subscriptions.isRequired) 'Require explicit multi-subscription scope.'
Assert-That ($parameters.ResourceGroups.type -eq 2 -and $parameters.ResourceGroups.multiSelect) 'Require RG multiselect.'
Assert-That (($parameters.ResourceGroups.crossComponentResources -join '') -ceq '{Subscriptions}') 'RG list must depend on subscriptions.'
Assert-That ($parameters.ResourceGroups.query.Contains("type =~ 'microsoft.resources/subscriptions/resourcegroups'") -and
    $parameters.ResourceGroups.query.Contains('value = tolower(id)') -and
    $parameters.ResourceGroups.query.Contains("strcat(name, ' | ', subscriptionId)")) 'RG choices need full IDs and distinguishable labels.'
Assert-That ($parameters.ResourceGroups.typeSettings.selectAllValue -ceq '*' -and
    $parameters.ResourceGroups.value[0] -ceq 'value::all') 'RG All sentinel must match inventory queries.'
foreach ($parameter in @($parameters.Subscriptions, $parameters.ResourceGroups)) {
    Assert-That ($parameter.quote -ceq "'" -and $parameter.delimiter -ceq ',') 'KQL multiselect must be quoted and comma delimited.'
}
$scope = "Resources`n| extend ResourceGroupId = tolower(strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup))`n| where '*' in ({ResourceGroups}) or ResourceGroupId in~ ({ResourceGroups})"
Assert-That ($items.Inventory.content.query.StartsWith($scope + "`n") -and $items.InventoryCount.content.query.StartsWith($scope + "`n")) 'Count and inventory must share all scope filters.'
Assert-That ($items.InventoryCount.content.query -ceq ($scope + "`n| summarize Resources = count()")) 'Count must aggregate before limiting rows.'
Assert-That ($items.Inventory.content.query.EndsWith('| take 1000') -and $items.Inventory.content.gridSettings.rowLimit -eq 1000) 'Inventory has an explicit, documented 1,000-row cap.'
Assert-That ($items.DiagnosticSettings.content.noDataMessage -ceq 'No diagnostic settings returned') 'Use a native success-empty settings message.'
Assert-That ($items.SupportedCategories.content.noDataMessage -ceq 'No categories returned') 'Empty categories must not mean unsupported.'
Assert-That ($raw -notmatch '(?i)listkeys|armActionContext|"method"\s*:\s*"(POST|PUT|PATCH|DELETE)"') 'No keys or mutation actions.'
Assert-That ($raw -notmatch '(?i)/subscriptions/[0-9a-f]{8}-') 'No embedded tenant resource IDs.'

$target = $parameters.TargetResourceId
Assert-That ($target.type -eq 1 -and $target.isRequired -and $target.value -ceq '' -and -not $target.ContainsKey('query')) 'Inspector starts blank and is independent of inventory.'
$rule = $target.typeSettings.paramValidationRules[0]
Assert-That ($rule.match -and $rule.message.Length -gt 0) 'Target validation must report invalid input.'
$sub = '00000000-0000-0000-0000-000000000001'
$resource = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.Storage/storageAccounts/fixtureaccount"
$child = "$resource/blobServices/default"
foreach ($valid in @($resource, $child, "$resource/providers/Microsoft.Example/widgets/sample")) {
    Assert-That ([regex]::IsMatch($valid, $rule.regExp)) "Valid fixture ID rejected: $valid"
    foreach ($query in $armQueries.Values) {
        $expanded = $query.path.Replace('{TargetResourceId:escapejson}', $valid)
        Assert-That ($expanded.StartsWith("$valid/providers/Microsoft.Insights/") -and -not $expanded.StartsWith('//')) 'Keep exact child ID and avoid double slash.'
    }
}
foreach ($invalid in @('', 'https://portal.azure.com/', "$resource/", "${resource}?api-version=x", "$resource#fragment",
    "$resource%2Fextra", "$resource`n", "$resource`r`n", "$resource with space", "$resource`"", "$resource{OtherParameter}",
    "/subscriptions/$sub", "/subscriptions/$sub/resourceGroups/fixture-rg", "$resource/orphan-type")) {
    Assert-That (-not [regex]::IsMatch($invalid, $rule.regExp)) "Invalid target accepted: $invalid"
}

$settings = @(
    @{ name = 'workspace'; id = "$resource/providers/Microsoft.Insights/diagnosticSettings/workspace"; properties = @{
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
    @{ name = 'StorageRead'; id = "$child/providers/Microsoft.Insights/diagnosticSettingsCategories/StorageRead"; properties = @{ categoryType = 'Logs'; categoryGroups = @('audit', 'allLogs') } },
    @{ name = 'StorageWrite'; properties = @{ categoryType = 'Logs'; categoryGroups = @() } },
    @{ name = 'AllMetrics'; properties = @{ categoryType = 'Metrics' } }
) } })
$categories = Convert-CollectionFixture $armQueries.SupportedCategories $categoryPages
Assert-That ($categories.Count -eq 3 -and $categories[0].CategoryGroups.Count -eq 2 -and
    $categories[0].CategoryId.StartsWith($child) -and $categories[2].CategoryType -ceq 'Metrics' -and
    $null -eq $categories[2].CategoryGroups) 'Preserve categories, groups, metrics, missing groups, and child identity.'
foreach ($query in $armQueries.Values) {
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

$schemaResult = if ($SchemaPath) { 'included' } else { 'not requested (use -SchemaPath)' }
Write-Output "PASS: $script:checks local assertions; official schema: $schemaResult. No Azure requests were made. Portal behavior is not verified by these checks."
