#!/usr/bin/env pwsh
<#
    .SYNOPSIS
    Validate the firewall rule config files before they reach Azure.

    .DESCRIPTION
    Every check here corresponds to something Azure rejects, or silently accepts
    and then behaves confusingly, halfway through a 15 minute deployment. A
    failed rule collection group update also holds its lock while it rolls back,
    which can block the following run, so catching these up front is worth more
    than the few seconds it costs.

    .PARAMETER Path
    Rule files to check. Defaults to every azure/*/firewall_rules_*.json.

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

$Sections = [ordered]@{
    networkRules     = 'FirewallPolicyFilterRuleCollection'
    applicationRules = 'FirewallPolicyFilterRuleCollection'
    dnatRules        = 'FirewallPolicyNatRuleCollection'
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

    if ($document -isnot [PSCustomObject]) {
        $errors.Add("${FilePath}: expected a JSON object at the top level")
        return [PSCustomObject]@{ Errors = $errors; Warnings = $warnings }
    }

    $topLevelKeys = @($document.PSObject.Properties.Name)
    $unknown = @($topLevelKeys | Where-Object { $Sections.Keys -notcontains $_ })
    if ($unknown.Count -gt 0) {
        $errors.Add("${FilePath}: unknown top-level key(s) $($unknown -join ', '); hub.template.json only reads $($Sections.Keys -join ', ')")
    }

    foreach ($section in $Sections.Keys) {
        $expectedType = $Sections[$section]

        if ($topLevelKeys -notcontains $section) {
            $warnings.Add("${FilePath}: no '$section' key; an empty rule collection group will be deployed")
            continue
        }

        $collections = $document.$section
        if ($collections -isnot [Array]) {
            $errors.Add("${FilePath}: '$section' must be an array")
            continue
        }

        $size = [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $collections -Depth 100 -Compress))
        if ($size -gt $MaxRuleCollectionGroupBytes) {
            $errors.Add(("{0}: '{1}' is {2:N2} MB, over the {3} MB rule collection group limit" -f `
                        $FilePath, $section, ($size / 1MB), ($MaxRuleCollectionGroupBytes / 1MB)))
        }

        $seenPriority = @{}
        $seenName = @{}

        for ($index = 0; $index -lt $collections.Count; $index++) {
            $collection = $collections[$index]
            $where = "${FilePath}: $section[$index]"

            if ($collection -isnot [PSCustomObject]) {
                $errors.Add("${where}: expected an object")
                continue
            }

            $properties = @($collection.PSObject.Properties.Name)

            $name = $collection.name
            if ([String]::IsNullOrWhiteSpace($name)) {
                $errors.Add("${where}: missing 'name'")
            }
            elseif ($seenName.ContainsKey($name)) {
                $errors.Add("${where}: duplicate collection name '$name', also at index $($seenName[$name])")
            }
            else {
                $seenName[$name] = $index
            }

            $priority = $collection.priority
            if ($properties -notcontains 'priority' -or $null -eq $priority) {
                $errors.Add("$where ('$name'): missing 'priority'")
            }
            elseif ($priority -isnot [Int32] -and $priority -isnot [Int64]) {
                $errors.Add("$where ('$name'): priority must be an integer, got '$priority'")
            }
            elseif ($priority -lt $PriorityMin -or $priority -gt $PriorityMax) {
                $errors.Add("$where ('$name'): priority $priority outside the allowed range $PriorityMin-$PriorityMax")
            }
            elseif ($seenPriority.ContainsKey($priority)) {
                # Azure rejects the whole rule collection group for this.
                $errors.Add("$where ('$name'): duplicate priority $priority, already used by '$($seenPriority[$priority])'")
            }
            else {
                $seenPriority[$priority] = $name
            }

            $collectionType = $collection.ruleCollectionType
            if ($collectionType -ne $expectedType) {
                $errors.Add("$where ('$name'): ruleCollectionType is '$collectionType', expected '$expectedType'")
            }

            $action = $collection.action
            if ($action -isnot [PSCustomObject] -or @($action.PSObject.Properties.Name) -notcontains 'type') {
                $errors.Add("$where ('$name'): missing action.type")
            }

            if ($properties -notcontains 'rules' -or $collection.rules -isnot [Array]) {
                $errors.Add("$where ('$name'): 'rules' must be an array")
            }
            elseif ($collection.rules.Count -eq 0) {
                # Deploys fine, matches nothing, and reads as an oversight.
                $warnings.Add("$where ('$name'): contains no rules")
            }
        }
    }

    return [PSCustomObject]@{ Errors = $errors; Warnings = $warnings }
}

if (-not $Path) {
    $Path = @(Get-ChildItem -Path 'azure' -Recurse -Filter 'firewall_rules_*.json' -ErrorAction SilentlyContinue |
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
