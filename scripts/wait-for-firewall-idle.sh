#!/usr/bin/env bash
#
# Waits until a hub resource group is safe to deploy into.
#
# Azure Firewall serialises configuration changes: a rule collection group
# update holds a lock on itself and on its parent policy for 3-5 minutes, and
# that update keeps running server-side even after the pipeline job that
# started it is cancelled. A run that starts while a previous one is still
# committing fails with FirewallPolicyRuleCollectionGroupUpdateNotAllowedWhenUpdatingOrDeleting.
#
# Usage: wait-for-firewall-idle.sh <resourceGroup> <firewallPolicyName> [timeoutSeconds]

set -uo pipefail

resourceGroup=${1:?resource group name required}
policyName=${2:?firewall policy name required}
timeoutSeconds=${3:-1800}
pollSeconds=30

deadline=$(( SECONDS + timeoutSeconds ))

while true; do
  # Deployments left running by an earlier (possibly cancelled) pipeline run.
  runningDeployments=$(az deployment group list \
    --resource-group "$resourceGroup" \
    --query "length([?properties.provisioningState=='Running'])" \
    --output tsv 2>/dev/null) || runningDeployments=0
  runningDeployments=${runningDeployments:-0}

  # Rule collection groups still committing. The policy does not exist on a
  # first deployment, in which case there is nothing to wait for.
  pendingGroups=$(az network firewall policy rule-collection-group list \
    --resource-group "$resourceGroup" \
    --policy-name "$policyName" \
    --query "length([?provisioningState!='Succeeded'])" \
    --output tsv 2>/dev/null) || pendingGroups=0
  pendingGroups=${pendingGroups:-0}

  if [ "$runningDeployments" -eq 0 ] && [ "$pendingGroups" -eq 0 ]; then
    echo "$resourceGroup is idle: no running deployments, no pending rule collection groups."
    exit 0
  fi

  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "##vso[task.logissue type=error]Timed out after ${timeoutSeconds}s waiting for $resourceGroup to become idle (${runningDeployments} running deployment(s), ${pendingGroups} pending rule collection group(s))."
    az deployment group list \
      --resource-group "$resourceGroup" \
      --query "[?properties.provisioningState=='Running'].{name:name,state:properties.provisioningState,started:properties.timestamp}" \
      --output table
    az network firewall policy rule-collection-group list \
      --resource-group "$resourceGroup" \
      --policy-name "$policyName" \
      --query "[?provisioningState!='Succeeded'].{name:name,state:provisioningState}" \
      --output table
    exit 1
  fi

  echo "Waiting for $resourceGroup to settle: ${runningDeployments} running deployment(s), ${pendingGroups} pending rule collection group(s). Retrying in ${pollSeconds}s..."
  sleep "$pollSeconds"
done
