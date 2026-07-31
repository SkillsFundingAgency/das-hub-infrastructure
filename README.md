# das-hub-infrastructure

ARM templates and Azure Firewall rules for the DAS hub networks. One hub per
environment: a VNet with an Azure Firewall, a NAT gateway for outbound traffic,
and a Log Analytics workspace for firewall diagnostics.

## Layout

| Path | Purpose |
| --- | --- |
| `pipeline.yaml` | Azure DevOps pipeline. One stage per environment, each calling the shared deploy job. |
| `pipeline-templates/job/deploy-hub.yml` | The deploy job itself. All environments share it; they differ only in parameters and variable group. |
| `config/hub.template.json` | Top-level ARM template. Deploys everything else as linked deployments. |
| `config/CDS-FwRules/`, `config/FCS-FwRules/` | Firewall rules, one file per environment. |
| `templates/` | Linked ARM templates, fetched over HTTPS at deploy time (see below). |
| `scripts/` | Deployment helpers. |

## Deploying

One stage per environment, all depending on a `Validate` stage that runs the
rule checks once up front. Every stage runs in the same pipeline run; gating is
done by Azure DevOps **Environments**, not by the pipeline. Each deploy job is
a `deployment` job bound to an environment of the same name (`DTA`, `AT`,
`TEST`, `TEST2`, `DEMO`, `PP`), so approvals and checks configured there apply
before anything reaches the subscription.

> An environment with no approvals configured deploys unattended. Configure
> approvals on `PP` (and on `PRD` and `MO` when they are enabled) before
> relying on this.

The pipeline is still manual (`trigger: none`). To deploy on merge to `main`,
as the other DAS repos do, replace it with `trigger: batch: true` over `main` —
but only once environment approvals are in place.

Queue it **against the branch you want to deploy**. `checkout: self` means
templates, rules and scripts all come from that branch, and
`templateBaseUri` pins the linked templates to that exact commit. Deploying a
branch is therefore a real test of that branch, not of `main`.

## Firewall rules

Rules live in `config/<CDS|FCS>-FwRules/firewall_rules_<env>.json`, with three
top-level arrays — `networkRules`, `applicationRules`, `dnatRules` — each a
list of rule *collections* that becomes one rule collection group.

Validate before pushing:

```bash
python scripts/validate-firewall-rules.py
```

This checks duplicate priorities, priority range, collection types and rule
collection group size. CI runs it on every pull request.

## Things that will bite you

**Azure Firewall serialises configuration changes.** A rule collection group
update holds a lock on itself and on its parent policy for 3-5 minutes.
Deployments are therefore chained (`FirewallPolicies -> Network -> DNAT ->
Application`) rather than run in parallel, which is why a full run takes
12-15 minutes. Do not "optimise" this by removing the `dependsOn` chain in
`config/hub.template.json`; both groups will race and one will fail with
`FirewallPolicyRuleCollectionGroupUpdateNotAllowedWhenUpdatingOrDeleting`.

**That lock outlives the pipeline job.** Cancelling a run does not stop the
update Azure is already committing, so the next run collides with it.
`scripts/wait-for-firewall-idle.sh` blocks until the resource group is idle
before deploying. It is deliberately fatal if it cannot run.

**Linked templates are fetched over HTTPS, not from the checkout.**
`config/hub.template.json` builds each URI from `templateBaseUri`, which the
pipeline sets to the commit being deployed. `relativePath` is not usable here
because the parent template is deployed with `--template-file`. A consequence:
the repository must stay public for deployments to work.

**ARM cannot delete rule collection groups.** Removing a rule collection group
from a template does not remove it from Azure — [it is an unsupported
operation][arm-limits]. Renaming a group therefore leaves the old one live and
enforcing its rules. Delete the old one explicitly:

```bash
az network firewall policy rule-collection-group delete \
  -g <hub-rg> --policy-name <policy> -n <old-group-name>
```

**Rule collection groups at equal priority have undefined ordering.** If two
groups share a priority, which one's allow or deny wins is not defined. Keep
priorities distinct across groups in a policy.

[arm-limits]: https://learn.microsoft.com/troubleshoot/azure/firewall/firewall-known-issues

## Environments

Environments follow the DAS convention: resources are named `das-<env>-...`
where `<env>` is one of `dta`, `at`, `test`, `test2`, `demo`, `pp`, `mo`,
`prd`. `MO` and `PRD` stages exist in `pipeline.yaml` but are commented out
until their variable group, ADO environment and rule file exist.

Each stage pulls one variable group named `<ENV> das-hub-infrastructure`,
matching `das-shared-infrastructure` and `das-aodp-api`. It supplies resource
names, address prefixes and the rule collection group names. A stage cannot
run until its group exists and is authorised for the pipeline.

| Stage | Variable group | Service connection |
| --- | --- | --- |
| Deploy_DTA | `DTA das-hub-infrastructure` | `SFA-DAS-DevTest-ARM` |
| Deploy_AT | `AT das-hub-infrastructure` | `SFA-DAS-DevTest-ARM` |
| Deploy_TEST | `TEST das-hub-infrastructure` | `SFA-DAS-DevTest-ARM` |
| Deploy_TEST2 | `TEST2 das-hub-infrastructure` | `SFA-DAS-DevTest-ARM` |
| Deploy_DEMO | `DEMO das-hub-infrastructure` | `SFA-DAS-DevTest-ARM` |
| Deploy_PP | `PP das-hub-infrastructure` | `SFA-DIG-PreProd-ARM` |
| Deploy_MO *(commented)* | `MO das-hub-infrastructure` | `SFA-ASM-ModelOffice-ARM` |
| Deploy_PRD *(commented)* | `PRD das-hub-infrastructure` | `SFA-DIG-Prod-ARM` |

### `RELEASE das-hub-infrastructure`

Values identical in every environment. Add this group to the pipeline once,
at the top of `pipeline.yaml`, rather than repeating it per environment.

| Variable | Value | Notes |
| --- | --- | --- |
| `location` | `westeurope` | |
| `subnetName` | `AzureFirewallSubnet` | Azure requires this exact name for a firewall subnet; it is not a free choice |
| `NetworkGroup` | `Network-Rules-Outbound` | |
| `AppGroup` | `Application-Rules-Outbound` | |
| `DNATGroup` | `Dnat-Rules-Inbound` | |

DTA predates this naming and uses `NetworkGroup` / `AppGroup` / `DNAT-Rules`.
Rather than hold the shared values back, the `Deploy_DTA` stage overrides all
three through the `NetworkGroupName`, `AppGroupName` and `DnatGroupName`
template parameters.

### `<ENV> das-hub-infrastructure`

Ten of these are a straight `das-<env>-hub-<suffix>` substitution:

| Variable | Pattern |
| --- | --- |
| `resourceGroupName` | `das-<env>-hub-rg` |
| `vnetName` | `das-<env>-hub-vnet` |
| `natGatewayName` | `das-<env>-hub-natgw` |
| `publicIPAddressName` | `das-<env>-hub-natgw-pip-0` |
| `firewallName` | `das-<env>-hub-fw` |
| `firewallPublicIpName` | `das-<env>-hub-fw-pip-0` |
| `firewallPolicy1Name` | `das-<env>-hub-fw-policy-0` |
| `firewallPolicy2Name` | `das-<env>-hub-fw-policy-1` |
| `LA_Name` | `das-<env>-hub-log` |
| `FWDiagnosticsName` | `das-<env>-hub-diag-fw` |

The remaining two are the only genuinely per-environment values:

| Env | `addressPrefix` | `subnetPrefix` |
| --- | --- | --- |
| dta | `10.0.0.0/16` | `10.0.1.0/26` |
| at | `10.0.0.0/16` | `10.0.1.0/26` |
| test | `10.20.0.0/16` | `10.20.0.0/26` |
| test2 | `10.30.0.0/16` | `10.30.0.0/26` |
| demo | `10.40.0.0/16` | `10.40.0.0/26` |

DTA and AT share an address space, so those two VNets can never be peered.

An undefined variable in Azure DevOps expands to the literal string
`$(NetworkGroup)`, which would create a rule collection group by that name
rather than failing. Check every variable exists before the first run.
