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

    Each config/firewall-rules-<env>.json is an ARM template declaring rule
    collection groups, identified by which group name parameter each resource is
    named after. A file uses one of two layouts:

      legacy  network, application and DNAT groups, one rule type each
      tiered  the five das-* groups, each free to mix rule collection types

    Priorities and names written as [variables('...')] are resolved against the
    template's variables before they are checked.

    .PARAMETER Path
    Rule templates to check. Defaults to every config/firewall-rules-*.json.

    .EXAMPLE
    ./scripts/validate-firewall-rules.ps1
#>
[CmdletBinding()]
param(
    [String[]]$Path
)

$MaxRuleCollectionGroupBytes = 1MB
$PriorityMin = 100
$PriorityMax = 65000

$LegacyGroups = [ordered]@{
    networkRuleCollectionGroupName     = 'FirewallPolicyFilterRuleCollection'
    applicationRuleCollectionGroupName = 'FirewallPolicyFilterRuleCollection'
    dnatRuleCollectionGroupName        = 'FirewallPolicyNatRuleCollection'
}

$TieredGroups = @(
    'criticalInfrastructureRuleCollectionGroupName'
    'securityServicesRuleCollectionGroupName'
    'applicationNetworkRuleCollectionGroupName'
    'externalIntegrationsRuleCollectionGroupName'
    'generalOutboundRuleCollectionGroupName'
)

$AllowedActions = @{
    FirewallPolicyFilterRuleCollection = @('Allow', 'Deny')
    FirewallPolicyNatRuleCollection    = @('DNAT')
}

$AllowedRuleTypes = @{
    FirewallPolicyFilterRuleCollection = @('NetworkRule', 'ApplicationRule')
    FirewallPolicyNatRuleCollection    = @('NatRule')
}

function Resolve-Value {
    param($Value, $Variables)

    if ($Value -is [String] -and $Value -match "^\[variables\('([^']+)'\)\]$") {
        $variableName = $Matches[1]
        if ($null -eq $Variables -or @($Variables.PSObject.Properties.Name) -notcontains $variableName) {
            throw "references undefined variable '$variableName'"
        }
        return $Variables.$variableName
    }
    return $Value
}

function Test-Priority {
    param($Priority, [String]$Where, [Hashtable]$Seen, [String]$Owner, [System.Collections.Generic.List[String]]$Errors)

    if ($null -eq $Priority) {
        $Errors.Add("${Where}: missing 'priority'")
    }
    elseif ($Priority -isnot [Int32] -and $Priority -isnot [Int64]) {
        $Errors.Add("${Where}: priority must be an integer, got '$Priority'")
    }
    elseif ($Priority -lt $PriorityMin -or $Priority -gt $PriorityMax) {
        $Errors.Add("${Where}: priority $Priority outside the allowed range $PriorityMin-$PriorityMax")
    }
    elseif ($Seen.ContainsKey($Priority)) {
        $Errors.Add("${Where}: duplicate priority $Priority, already used by '$($Seen[$Priority])'")
    }
    else {
        $Seen[$Priority] = $Owner
    }
}

function Test-RuleCollections {
    param(
        [String]$FilePath,
        [String]$GroupLabel,
        [String]$ExpectedType,
        $Collections,
        $Variables,
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

        try {
            $name = Resolve-Value -Value $collection.name -Variables $Variables
            $priority = Resolve-Value -Value $collection.priority -Variables $Variables
        }
        catch {
            $Errors.Add("${where}: $($_.Exception.Message)")
            continue
        }

        if ([String]::IsNullOrWhiteSpace($name)) {
            $Errors.Add("${where}: missing 'name'")
        }
        elseif ($seenName.ContainsKey($name)) {
            $Errors.Add("${where}: duplicate collection name '$name', also at index $($seenName[$name])")
        }
        else {
            $seenName[$name] = $index
        }

        $where = "$where ('$name')"
        Test-Priority -Priority $priority -Where $where -Seen $seenPriority -Owner $name -Errors $Errors

        $collectionType = $collection.ruleCollectionType
        if (-not $AllowedActions.ContainsKey([String]$collectionType)) {
            $Errors.Add("${where}: unknown ruleCollectionType '$collectionType'")
            continue
        }
        if ($ExpectedType -and $collectionType -ne $ExpectedType) {
            $Errors.Add("${where}: ruleCollectionType is '$collectionType', expected '$ExpectedType'")
        }

        $action = $collection.action
        if ($action -isnot [PSCustomObject] -or @($action.PSObject.Properties.Name) -notcontains 'type') {
            $Errors.Add("${where}: missing action.type")
        }
        elseif ($AllowedActions[$collectionType] -notcontains $action.type) {
            $Errors.Add("${where}: action '$($action.type)' is not valid for $collectionType; use $($AllowedActions[$collectionType] -join ' or ')")
        }

        if (@($collection.PSObject.Properties.Name) -notcontains 'rules' -or $collection.rules -isnot [Array]) {
            $Errors.Add("${where}: 'rules' must be an array")
            continue
        }
        if ($collection.rules.Count -eq 0) {
            $Warnings.Add("${where}: contains no rules")
            continue
        }

        $ruleTypes = @($collection.rules | ForEach-Object { $_.ruleType } | Sort-Object -Unique)
        foreach ($ruleType in $ruleTypes) {
            if ($AllowedRuleTypes[$collectionType] -notcontains $ruleType) {
                $Errors.Add("${where}: rule type '$ruleType' cannot sit in a $collectionType")
            }
        }
        if ($ruleTypes.Count -gt 1) {
            $Errors.Add("${where}: mixes rule types $($ruleTypes -join ', '); a rule collection holds one type only")
        }

        $seenRuleName = @{}
        for ($ruleIndex = 0; $ruleIndex -lt $collection.rules.Count; $ruleIndex++) {
            $ruleName = $collection.rules[$ruleIndex].name
            if ([String]::IsNullOrWhiteSpace($ruleName)) {
                $Errors.Add("${where}: rule $ruleIndex is missing 'name'")
            }
            elseif ($seenRuleName.ContainsKey($ruleName)) {
                $Errors.Add("${where}: duplicate rule name '$ruleName' at rules[$ruleIndex], also at rules[$($seenRuleName[$ruleName])]")
            }
            else {
                $seenRuleName[$ruleName] = $ruleIndex
            }
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

    $knownGroups = @($LegacyGroups.Keys) + $TieredGroups
    $seenGroups = @{}
    $seenGroupPriority = @{}

    foreach ($resource in $document.resources) {
        if ($resource.type -ne 'Microsoft.Network/firewallPolicies/ruleCollectionGroups') {
            $errors.Add("${FilePath}: unexpected resource type '$($resource.type)'; this template should only declare rule collection groups")
            continue
        }

        $matched = @($knownGroups | Where-Object { $resource.name -like "*parameters('$_')*" })
        if ($matched.Count -ne 1) {
            $errors.Add("${FilePath}: cannot tell which rule collection group '$($resource.name)' is; its name must reference exactly one of $($knownGroups -join ', ')")
            continue
        }

        $groupLabel = $matched[0]
        if ($seenGroups.ContainsKey($groupLabel)) {
            $errors.Add("${FilePath}: more than one resource named after $groupLabel")
            continue
        }
        $seenGroups[$groupLabel] = $true

        try {
            $groupPriority = Resolve-Value -Value $resource.properties.priority -Variables $document.variables
            Test-Priority -Priority $groupPriority -Where "${FilePath}: $groupLabel" -Seen $seenGroupPriority -Owner $groupLabel -Errors $errors
        }
        catch {
            $errors.Add("${FilePath}: ${groupLabel}: priority $($_.Exception.Message)")
        }

        Test-RuleCollections -FilePath $FilePath -GroupLabel $groupLabel `
            -ExpectedType $LegacyGroups[$groupLabel] `
            -Collections $resource.properties.ruleCollections `
            -Variables $document.variables `
            -Errors $errors -Warnings $warnings
    }

    $usesTiered = @($TieredGroups | Where-Object { $seenGroups.ContainsKey($_) }).Count -gt 0
    $usesLegacy = @($LegacyGroups.Keys | Where-Object { $seenGroups.ContainsKey($_) }).Count -gt 0

    if ($usesTiered -and $usesLegacy) {
        $errors.Add("${FilePath}: declares both legacy and tiered rule collection groups; the same rules would be enforced twice under different priorities")
    }

    $expectedGroups = if ($usesTiered) { $TieredGroups } else { @($LegacyGroups.Keys) }
    foreach ($groupLabel in $expectedGroups) {
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
