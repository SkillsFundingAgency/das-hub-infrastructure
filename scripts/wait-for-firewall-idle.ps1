#!/usr/bin/env pwsh
<#
    .SYNOPSIS
    Waits until a hub resource group is safe to deploy into.

    .DESCRIPTION
    Azure Firewall serialises configuration changes: a rule collection group
    update holds a lock on itself and on its parent policy for 3-5 minutes, and
    that update keeps running server-side even after the pipeline job that
    started it is cancelled. A run that starts while a previous one is still
    committing fails with
    FirewallPolicyRuleCollectionGroupUpdateNotAllowedWhenUpdatingOrDeleting.

    .EXAMPLE
    ./wait-for-firewall-idle.ps1 -ResourceGroupName das-at-hub-rg -FirewallPolicyName das-at-hub-fw-policy-0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][String]$ResourceGroupName,
    [Parameter(Mandatory = $true)][String]$FirewallPolicyName,
    [Int]$TimeoutSeconds = 1800,
    [Int]$PollSeconds = 30
)

function Get-AzCount {
    # az writes to stderr and returns non-zero for a missing policy, which is
    # not an error here: nothing to wait for.
    param([String[]]$Arguments)
    $value = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0 -or [String]::IsNullOrWhiteSpace($value)) {
        return 0
    }
    return [Int]$value
}

# On a first deployment the resource group does not exist yet, so there is
# nothing in flight to wait for.
if ((& az group exists --name $ResourceGroupName) -ne 'true') {
    Write-Host "$ResourceGroupName does not exist yet; nothing to wait for."
    exit 0
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

while ($true) {
    # Deployments left running by an earlier, possibly cancelled, pipeline run.
    $runningDeployments = Get-AzCount @(
        'deployment', 'group', 'list',
        '--resource-group', $ResourceGroupName,
        '--query', "length([?properties.provisioningState=='Running'])",
        '--output', 'tsv'
    )

    # Rule collection groups still committing.
    $pendingGroups = Get-AzCount @(
        'network', 'firewall', 'policy', 'rule-collection-group', 'list',
        '--resource-group', $ResourceGroupName,
        '--policy-name', $FirewallPolicyName,
        '--query', "length([?provisioningState!='Succeeded'])",
        '--output', 'tsv'
    )

    if ($runningDeployments -eq 0 -and $pendingGroups -eq 0) {
        Write-Host "$ResourceGroupName is idle: no running deployments, no pending rule collection groups."
        exit 0
    }

    if ((Get-Date) -ge $deadline) {
        Write-Host "##vso[task.logissue type=error]Timed out after $TimeoutSeconds seconds waiting for $ResourceGroupName to become idle ($runningDeployments running deployment(s), $pendingGroups pending rule collection group(s))."
        & az deployment group list --resource-group $ResourceGroupName `
            --query "[?properties.provisioningState=='Running'].{name:name,state:properties.provisioningState,started:properties.timestamp}" `
            --output table
        & az network firewall policy rule-collection-group list --resource-group $ResourceGroupName `
            --policy-name $FirewallPolicyName `
            --query "[?provisioningState!='Succeeded'].{name:name,state:provisioningState}" `
            --output table
        exit 1
    }

    Write-Host "Waiting for $ResourceGroupName to settle: $runningDeployments running deployment(s), $pendingGroups pending rule collection group(s). Retrying in $PollSeconds seconds..."
    Start-Sleep -Seconds $PollSeconds
}
