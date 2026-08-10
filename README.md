# das-hub-infrastructure

ARM templates and Azure Firewall rules for the DAS hub networks. One hub per
environment: a VNet with an Azure Firewall, a NAT gateway for outbound traffic,
and a Log Analytics workspace for firewall diagnostics.

## Layout

| Path | Purpose |
| --- | --- |
| `pipeline.yaml` | Azure DevOps pipeline. One stage per environment, each calling the shared deploy job. |
| `pipeline-templates/job/deploy-hub.yml` | The deploy job itself. All environments share it; they differ only in parameters and variable group. |
| `pipeline-templates/job/build.yml` | Validates the rule templates and publishes `azure/**`, `config/**` and `scripts/**` as the `drop` artifact. |
| `azure/hub.template.json` | Top-level ARM template, deployed at **subscription** scope. Creates the resource group and deploys everything else as linked deployments. |
| `azure/templates/` | Linked ARM templates, fetched over HTTPS at deploy time (see below). |
| `config/` | Firewall rules, one `firewall-rules-<env>.json` per environment. Each is an ARM template declaring the three rule collection groups, linked from `hub.template.json`. |
| `scripts/` | Deployment helpers. |

## Deploying

One stage per environment, all depending on a `Build` stage that validates the
rule templates once up front and publishes `azure/**`, `config/**` and
`scripts/**` as the `drop` artifact, which
the deploy stages deploy from. Every stage runs in the same pipeline run; gating is
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

Queue it **against the branch you want to deploy**. The `Build` stage checks
out that branch and publishes it as the artifact, and `templateBaseUri` and
`configBaseUri` pin the linked templates and rule files to that exact commit.
Deploying a branch is therefore a real test of that branch, not of `main`.
The deploy job itself checks out nothing: it works from the artifact, and
`arm-deploy.yml` checks out `das-platform-automation` for its own scripts.

## Firewall rules

Rules live in `config/firewall-rules-<env>.json`. Each is an ARM template
declaring the three rule collection groups, with the rule collections inline
under `properties.ruleCollections`. To add a rule, add a collection to the
relevant group's array.

They are templates rather than plain data because the deployment uses the
shared `arm-deploy.yml` step, which builds its parameters file from environment
variables. A Windows environment variable holds 32,767 characters and the
larger rule sets are over 60 KB, so they cannot travel as a parameter. Linking
them as a template means ARM fetches them itself.

Validate before pushing:

```powershell
./scripts/validate-firewall-rules.ps1
```

This checks duplicate priorities, priority range, collection types and rule
collection group size. The `Build` stage runs it before any environment is
touched. Nothing validates a pull request, because the pipeline is
`trigger: none` and `pr: none`.

## Things that will bite you

**Azure Firewall serialises configuration changes.** A rule collection group
update holds a lock on itself and on its parent policy for 3-5 minutes. The
three groups are therefore chained network -> DNAT -> application by the
`dependsOn` between the resources in `config/firewall-rules-<env>.json`, which
is why a full run takes 12-15 minutes. Do not "optimise" this by removing that
chain; the groups will race and one will fail with
`FirewallPolicyRuleCollectionGroupUpdateNotAllowedWhenUpdatingOrDeleting`.

**That lock outlives the pipeline job.** Cancelling a run does not stop the
update Azure is already committing, so the next run collides with it.
`scripts/wait-for-firewall-idle.ps1` blocks until the resource group is idle
before deploying. It is deliberately fatal if it cannot run. It is PowerShell
because the `DAS - Continuous Deployment Agents` pool is Windows, which has no
`bash`.

**Linked templates and rule files are fetched over HTTPS, not from the
artifact.** `azure/hub.template.json` builds each URI from `templateBaseUri`
and `configBaseUri`, which the pipeline sets to the commit being deployed. A
consequence: the repository must stay public for deployments to work.

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
| `serviceName` | `hub` | Second half of the `das-<env>-<serviceName>` name prefix |
| `subnetName` | `AzureFirewallSubnet` | Azure requires this exact name for a firewall subnet; it is not a free choice |
| `networkRuleCollectionGroupName` | `Network-Rules-Outbound` | |
| `applicationRuleCollectionGroupName` | `Application-Rules-Outbound` | |
| `dnatRuleCollectionGroupName` | `Dnat-Rules-Inbound` | |
| `tags` | `{"Environment":"$(EnvironmentTag)", ...}` | JSON object; `EnvironmentTag` comes from the per-environment group |

> DTA's live rule collection groups are named `NetworkGroup` / `AppGroup` /
> `DNAT-Rules`. Deploying the shared names above will create new groups
> alongside them rather than renaming them, and ARM cannot delete the old ones.
> Either set the DTA-specific names in `DTA das-hub-infrastructure`, or delete
> the old groups with the Azure CLI first.

### `<ENV> das-hub-infrastructure`

Resource names are derived inside the template from
`das-<resourceEnvironmentName>-<serviceName>`, so only these are needed:

| Variable | AT example |
| --- | --- |
| `resourceEnvironmentName` | `at` |
| `addressPrefix` | `10.0.0.0/16` |
| `subnetPrefix` | `10.0.1.0/26` |
| `SubscriptionId` | `68208b91-0105-498e-a1bc-40d75596c01a` |
| `EnvironmentTag` | `Dev/Test` |

Addressing per environment:

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
