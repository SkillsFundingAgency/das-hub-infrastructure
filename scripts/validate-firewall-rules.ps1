#!/usr/bin/env pwsh
<#
    .SYNOPSIS
    Validate the firewall rule templates before they reach Azure.

    .DESCRIPTION
    Every check here corresponds to something Azure rejects, or silently accepts
    and then behaves confusingly, halfway through a 15 minute deployment. A
    failed rule collection group update also holds its lock while it rolls back,
    which can block the following run, so catching these up front is worth more
    than the few seconds it costs.

    Each config/firewall-rules-<env>.json is an ARM template declaring three
    rule collection groups, identified by which group name parameter each
    resource is named after.

    .PARAMETER Path
    Rule templates to check. Defaults to every config/firewall-rules-*.json.

    .EXAMPLE
    ./scripts/validate-firewall-rules.ps1
#>
[CmdletBinding()]
param(
    [String[]]$Path
)

# https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-firewall-limits
$MaxRuleCollectionGroupBytes = 1MB  # policies created before July 2022
$PriorityMin = 100
$PriorityMax = 65000

$ExpectedCollectionType = [ordered]@{
    networkRuleCollectionGroupName     = 'FirewallPolicyFilterRuleCollection'
    applicationRuleCollectionGroupName = 'FirewallPolicyFilterRuleCollection'
    dnatRuleCollectionGroupName        = 'FirewallPolicyNatRuleCollection'
}

function Test-RuleCollections {
    param(
        [String]$FilePath,
        [String]$GroupLabel,
        [String]$ExpectedType,
        $Collections,
        [System.Collections.Generic.List[String]]$Errors,
        [System.Collections.Generic.List[String]]$Warnings
    )

    if ($Collections -isnot [Array]) {
        $Errors.Add("${FilePath}: ${GroupLabel}: ruleCollections must be an array")
        return
    }

    $size = [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $Collections -Depth 100 -Compress))
    if ($size -gt $MaxRuleCollectionGroupBytes) {
        $Errors.Add(("{0}: {1} is {2:N2} MB, over the {3} MB rule collection group limit" -f `
                    $FilePath, $GroupLabel, ($size / 1MB), ($MaxRuleCollectionGroupBytes / 1MB)))
    }

    $seenPriority = @{}
    $seenName = @{}

    for ($index = 0; $index -lt $Collections.Count; $index++) {
        $collection = $Collections[$index]
        $where = "${FilePath}: ${GroupLabel}[$index]"

        if ($collection -isnot [PSCustomObject]) {
            $Errors.Add("${where}: expected an object")
            continue
        }

        $properties = @($collection.PSObject.Properties.Name)

        $name = $collection.name
        if ([String]::IsNullOrWhiteSpace($name)) {
            $Errors.Add("${where}: missing 'name'")
        }
        elseif ($seenName.ContainsKey($name)) {
            $Errors.Add("${where}: duplicate collection name '$name', also at index $($seenName[$name])")
        }
        else {
            $seenName[$name] = $index
        }

        $priority = $collection.priority
        if ($properties -notcontains 'priority' -or $null -eq $priority) {
            $Errors.Add("$where ('$name'): missing 'priority'")
        }
        elseif ($priority -isnot [Int32] -and $priority -isnot [Int64]) {
            $Errors.Add("$where ('$name'): priority must be an integer, got '$priority'")
        }
        elseif ($priority -lt $PriorityMin -or $priority -gt $PriorityMax) {
            $Errors.Add("$where ('$name'): priority $priority outside the allowed range $PriorityMin-$PriorityMax")
        }
        elseif ($seenPriority.ContainsKey($priority)) {
            # Azure rejects the whole rule collection group for this.
            $Errors.Add("$where ('$name'): duplicate priority $priority, already used by '$($seenPriority[$priority])'")
        }
        else {
            $seenPriority[$priority] = $name
        }

        $collectionType = $collection.ruleCollectionType
        if ($collectionType -ne $ExpectedType) {
            $Errors.Add("$where ('$name'): ruleCollectionType is '$collectionType', expected '$ExpectedType'")
        }

        $action = $collection.action
        if ($action -isnot [PSCustomObject] -or @($action.PSObject.Properties.Name) -notcontains 'type') {
            $Errors.Add("$where ('$name'): missing action.type")
        }

        if ($properties -notcontains 'rules' -or $collection.rules -isnot [Array]) {
            $Errors.Add("$where ('$name'): 'rules' must be an array")
        }
        elseif ($collection.rules.Count -eq 0) {
            # Deploys fine, matches nothing, and reads as an oversight.
            $Warnings.Add("$where ('$name'): contains no rules")
        }
    }
}

function Test-RuleFile {
    param([String]$FilePath)

    $errors = [System.Collections.Generic.List[String]]::new()
    $warnings = [System.Collections.Generic.List[String]]::new()

    try {
        $document = Get-Content -Path $FilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $errors.Add("${FilePath}: invalid JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ Errors = $errors; Warnings = $warnings }
    }

    if ($document -isnot [PSCustomObject] -or $document.resources -isnot [Array]) {
        $errors.Add("${FilePath}: expected an ARM template with a 'resources' array")
        return [PSCustomObject]@{ Errors = $errors; Warnings = $warnings }
    }

    $seenGroups = @{}

    foreach ($resource in $document.resources) {
        if ($resource.type -ne 'Microsoft.Network/firewallPolicies/ruleCollectionGroups') {
            $errors.Add("${FilePath}: unexpected resource type '$($resource.type)'; this template should only declare rule collection groups")
            continue
        }

        # Which group a resource is depends on the parameter it is named after.
        $matched = @($ExpectedCollectionType.Keys | Where-Object { $resource.name -like "*$_*" })
        if ($matched.Count -ne 1) {
            $errors.Add("${FilePath}: cannot tell which rule collection group '$($resource.name)' is; its name must reference exactly one of $($ExpectedCollectionType.Keys -join ', ')")
            continue
        }

        $groupLabel = $matched[0]
        if ($seenGroups.ContainsKey($groupLabel)) {
            $errors.Add("${FilePath}: more than one resource named after $groupLabel")
            continue
        }
        $seenGroups[$groupLabel] = $true

        Test-RuleCollections -FilePath $FilePath -GroupLabel $groupLabel `
            -ExpectedType $ExpectedCollectionType[$groupLabel] `
            -Collections $resource.properties.ruleCollections `
            -Errors $errors -Warnings $warnings
    }

    foreach ($groupLabel in $ExpectedCollectionType.Keys) {
        if (-not $seenGroups.ContainsKey($groupLabel)) {
            $warnings.Add("${FilePath}: no resource for $groupLabel; that rule collection group will not be deployed")
        }
    }

    return [PSCustomObject]@{ Errors = $errors; Warnings = $warnings }
}

if (-not $Path) {
    $Path = @(Get-ChildItem -Path 'config' -Recurse -Filter 'firewall-rules-*.json' -ErrorAction SilentlyContinue |
              Sort-Object FullName |
              Select-Object -ExpandProperty FullName)
}

if (-not $Path) {
    Write-Host 'No rule files found. Run from the repository root.'
    exit 1
}

$totalErrors = 0
foreach ($file in $Path) {
    $result = Test-RuleFile -FilePath $file
    $totalErrors += $result.Errors.Count
    $status = if ($result.Errors.Count -gt 0) { 'FAIL' } else { 'ok' }
    Write-Host ("{0,-4} {1} ({2} error(s), {3} warning(s))" -f $status, $file, $result.Errors.Count, $result.Warnings.Count)
    foreach ($message in $result.Errors) { Write-Host "     ERROR   $message" }
    foreach ($message in $result.Warnings) { Write-Host "     warning $message" }
}

Write-Host ''
if ($totalErrors -gt 0) {
    Write-Host "$totalErrors error(s) found."
    exit 1
}
Write-Host 'All rule files valid.'
exit 0
