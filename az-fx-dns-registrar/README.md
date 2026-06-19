# az.fx Central DNS Registrar — Implementation Guide

Centralized, automatic registration of VM A records into the single `az.fx`
private DNS zone, across all project spoke subscriptions — without relying on
Azure Private DNS auto-registration (which is hard-capped at **100 vNet links
per zone**).

This repo contains everything the DevOps team needs: the Function code, the
Terraform for the central registrar and the per-spoke wiring, and the steps to
deploy, onboard, operate and roll back.

---

## 1. Why we are not using native auto-registration

Native auto-registration only supports **100 vNets linked to a zone with
registration enabled**, and a vNet can auto-register into **only one** zone.
With several hundred → ~1000 project spokes that ceiling is unreachable.

The two relevant limits are independent:

| Private DNS limit | Value |
|---|---|
| vNet links per zone **with auto-registration** | **100** ← the blocker |
| vNet links per zone (resolution only) | **1000** |
| Record sets per zone | 25,000 |

So **resolution is not the problem** — spokes keep resolving `az.fx` via ordinary
resolution-only links (registration disabled), and on-prem keeps resolving via
the existing DNS Private Resolver. We only replace the *registration* mechanism
with central automation that writes records directly through the Azure DNS API.

---

## 2. How it works

```
 Spoke subscription (project)                Platform / connectivity subscription
 ┌───────────────────────────┐               ┌──────────────────────────────────────┐
 │ VM created / updated /      │   ARM        │  Function App  (func-fxdnsreg)         │
 │ deleted                     │   events     │  ┌──────────────────────────────────┐ │
 │        │                    │  Write/Delete│  │ RegisterVmDns (Event Grid trigger)│ │
 │  Event Grid system topic    │ ───────────► │  │  write  -> upsert A <vm> -> IP    │ │
 │  (subscription source)      │   Success    │  │  delete -> remove A <vm>          │ │
 │  filter: VM write/delete    │              │  └──────────────────────────────────┘ │
 └───────────────────────────┘               │  ┌──────────────────────────────────┐ │
                                              │  │ ReconcileDns (Timer, hourly)      │ │
   (one system topic per spoke,              │  │  Resource Graph -> repair drift   │ │
    created at onboarding)                    │  └──────────────────────────────────┘ │
                                              │              │ Private DNS Zone Contributor
                                              │              ▼                          │
                                              │      Private DNS zone  az.fx            │
                                              └──────────────────────────────────────┘
```

- **`RegisterVmDns`** (Event Grid trigger) — fires on `Microsoft.Compute/virtualMachines`
  `write` and `delete` events from each spoke. On write it reads the VM's primary
  NIC private IP and upserts `<vm>.az.fx`; on delete it removes the record.
- **`ReconcileDns`** (timer, hourly by default) — the safety net. Event delivery is
  best-effort, so this job rebuilds desired state from Azure Resource Graph (every
  VM + primary private IP across all readable subscriptions) and repairs the zone:
  creates missing records, fixes changed IPs, deletes records with no backing VM.
- **Record naming** — `<vm>.az.fx`, taken directly from the VM resource name. This
  relies on your "next available number" naming convention guaranteeing unique VM
  names; the reconciler logs a warning if it ever sees a duplicate name.
- **Safety tag** — every record the registrar writes carries metadata
  `managedBy = az-fx-registrar`. The delete path and the reconciler **only ever
  modify or remove records carrying that tag**, so manually-created records are
  never touched.

### Why VM events (not NIC events)
Triggering on the VM resource gives us the VM name directly in the event for both
create *and* delete, which matches the `<vm>.az.fx` convention cleanly. The only
gap — a private IP changing without a VM PUT — is rare (VMs use the same IP across
stop/start) and is caught by the hourly reconciler.

---

## 3. Repository layout

```
az-fx-dns-registrar/
├── README.md                       ← this guide
├── azure-pipelines.yml             ← central CD: validate → platform → function → policy
├── function/                       ← Function App code (PowerShell 7.4)
│   ├── host.json
│   ├── requirements.psd1           ← Az modules (managed dependencies)
│   ├── profile.ps1                 ← signs in with managed identity at startup
│   ├── RegisterVmDns/              ← Event Grid trigger
│   │   ├── function.json
│   │   └── run.ps1
│   └── ReconcileDns/               ← Timer trigger (reconciliation)
│       ├── function.json
│       └── run.ps1
├── pipelines/
│   ├── onboard-spoke.yml           ← per-spoke onboarding pipeline (optional)
│   └── templates/
│       └── terraform-apply.yml     ← reusable terraform step template
└── terraform/
    ├── platform/                   ← deploy ONCE (central registrar + RBAC)
    ├── spoke/                      ← reusable module (Event Grid wiring)
    ├── spoke-root/                 ← thin root to apply the spoke module standalone
    └── policy/                     ← DeployIfNotExists policy: auto-wire every subscription
```

---

## 4. Prerequisites

- The `az.fx` private DNS zone already exists (it does) in the connectivity
  subscription. Note its **subscription ID** and **resource group**.
- A **management group** that contains all current and future spoke subscriptions
  (e.g. the `Landing Zones` / `Corp` MG in your CAF hierarchy). Note its ID.
- The principal that runs the **platform** Terraform needs, in the platform
  subscription: `Owner` (or `Contributor` + `User Access Administrator`) so it can
  create the role assignments, **plus** `User Access Administrator` at the
  management-group scope (to grant Reader there) and on the zone's resource group
  (to grant Private DNS Zone Contributor).
- The principal that runs the **spoke** Terraform needs `Contributor` +
  `EventGrid Contributor` in each spoke subscription. Your existing per-project
  service connection already deploys infra there, so extend that pipeline.
- Tooling: Terraform ≥ 1.5, Azure CLI, and Azure Functions Core Tools v4
  (`func`) for code deployment.

---

## 5. Deployment

### Step 1 — Deploy the central registrar (once)

```bash
cd terraform/platform

cat > terraform.tfvars <<'EOF'
platform_subscription_id = "<platform/connectivity sub id>"
zone_subscription_id     = "<sub id that hosts az.fx>"   # often same as platform
zone_resource_group      = "<rg that hosts az.fx>"
zone_name                = "az.fx"
location                 = "westeurope"
management_group_id      = "<MG id covering all spokes>"
record_ttl               = 3600
function_plan_sku        = "Y1"   # use "EP1" in production (see note below)
tags = { owner = "platform-team", purpose = "az-fx-dns-registrar" }
EOF

terraform init
terraform apply
```

> **If `az.fx` is in a different subscription than the Function App**: open
> `main.tf`, add `provider = azurerm.zone` to the
> `azurerm_role_assignment.dns_zone_contributor` resource, and make sure the
> deploy principal has `User Access Administrator` in that subscription. The
> `azurerm.zone` provider alias is already declared in `providers.tf`.

Record the outputs — you need `registrar_function_id` for every spoke:

```bash
terraform output registrar_function_id   # .../func-fxdnsreg/functions/RegisterVmDns
terraform output function_app_name        # func-fxdnsreg
```

### Step 2 — Deploy the Function code

Terraform creates the empty Function App; the code is deployed separately.

```bash
cd ../../function
func azure functionapp publish <function_app_name> --powershell
```

First run downloads the Az managed-dependency modules — allow a few minutes.

**Azure DevOps pipeline alternative** (recommended for repeatability):

```yaml
- task: AzureFunctionApp@2
  inputs:
    connectionType: AzureRM
    azureSubscription: '<platform service connection>'
    appType: functionApp
    appName: 'func-fxdnsreg'
    package: '$(System.DefaultWorkingDirectory)/function'
```

### Step 3 — Wire each spoke subscription

The `terraform/spoke` module creates the Event Grid system topic + filtered
event subscription in a spoke. Apply it with a provider pointed at that spoke.
Fold this into your **existing project-onboarding pipeline** so every new project
gets wired automatically.

Example root that calls the module for one spoke:

```hcl
# spoke-onboarding/main.tf
provider "azurerm" {
  features {}
  subscription_id = var.project_subscription_id   # the new project's sub
}

module "dns_registration" {
  source = "git::https://dev.azure.com/contoso/_git/az-fx-dns-registrar//terraform/spoke?ref=v1.0.0"

  subscription_id       = var.project_subscription_id
  location              = "westeurope"
  registrar_function_id = "<registrar_function_id from Step 1>"

  # Recommended in production:
  # dead_letter_storage_container_id = "<storageAccountId>/blobServices/default/containers/deadletter"

  tags = { project = var.project_name }
}
```

```bash
terraform init && terraform apply
```

> The very first time a subscription creates an Event Grid system topic, the
> `Microsoft.EventGrid` resource provider must be registered:
> `az provider register --namespace Microsoft.EventGrid --subscription <spoke>`.
> Add this as a one-liner in the onboarding pipeline.

### Step 4 — Resolution links (verify, don't duplicate)

Each spoke must have a **resolution-only** link to `az.fx`
(`registration_enabled = false`). You almost certainly create this already in the
module that peers the spoke to the hub — just confirm it sets
`registration_enabled = false`. Resolution links scale to ~1000 per zone, so this
is not a bottleneck. Do **not** enable registration on these links.

```hcl
resource "azurerm_private_dns_zone_virtual_network_link" "az_fx" {
  name                  = "link-${var.project_name}"
  resource_group_name   = "<az.fx zone RG>"
  private_dns_zone_name = "az.fx"
  virtual_network_id    = azurerm_virtual_network.spoke.id
  registration_enabled  = false   # <-- resolution only
}
```

---

## 6. RBAC model (what gets granted, where)

The Function App's **system-assigned managed identity** receives exactly two
standing grants (both created by the platform Terraform):

| Scope | Role | Purpose |
|---|---|---|
| `az.fx` zone's resource group | **Private DNS Zone Contributor** | Create / update / delete A records. (Not "DNS Zone Contributor" — that role is for *public* DNS.) |
| Management group over all spokes | **Reader** | Read VM + NIC objects (private IPs) in every project subscription. Read-only. |

The Reader grant at MG scope means **new spoke subscriptions inherit access
automatically** — no per-onboarding RBAC step. The only write surface is the
central zone, held by one identity the platform team controls. Project teams need
**no** access to `az.fx` and their subscription-scoped service connections are
unchanged.

---

## 7. Record lifecycle

| Event | Path | Result |
|---|---|---|
| VM created | `ResourceWriteSuccess` → `RegisterVmDns` | A record `<vm>` created → primary private IP |
| VM updated (IP change via PUT) | `ResourceWriteSuccess` → `RegisterVmDns` | A record updated |
| VM deleted | `ResourceDeleteSuccess` → `RegisterVmDns` | A record removed (if tagged `managedBy`) |
| Dropped / failed event | hourly `ReconcileDns` | Missing created, drifted IP fixed, orphaned records deleted |
| IP change without a VM PUT | hourly `ReconcileDns` | Corrected on next run |

TTL on records is `record_ttl` (default 3600s). Lower it (e.g. 300) if you expect
frequent IP churn.

---

## 8. Testing / validation

1. **Pilot on 2–3 spokes** before fleet-wide rollout.
2. Create a VM in a wired spoke. Within ~1–2 minutes:
   ```bash
   az network private-dns record-set a show \
     --resource-group <az.fx RG> --zone-name az.fx --name <vmname> \
     --subscription <zone sub>
   ```
   Confirm the A record exists with the VM's private IP and metadata
   `managedBy=az-fx-registrar`.
3. From another VM linked to `az.fx`, `nslookup <vmname>.az.fx` resolves.
4. Delete the VM → confirm the record disappears within ~1–2 minutes.
5. Manually delete a record for a live VM → confirm the next hourly reconcile
   recreates it.
6. Manually create an *untagged* record → confirm reconcile leaves it alone.
7. Watch invocations in Application Insights (`appi-fxdnsreg`):
   ```kusto
   traces | where operation_Name in ("RegisterVmDns","ReconcileDns")
         | order by timestamp desc
   ```

---

## 9. Operations & monitoring

- **Application Insights** captures every invocation, the upsert/delete decisions,
  and exceptions. Build an alert on `exceptions` for the two functions.
- **Dead-letter** (if configured per spoke): alert on any blob landing in the
  dead-letter container — it means an event exhausted 30 delivery attempts.
- **Reconciliation summary**: each run logs `created=… updated=… deleted=…`.
  A persistently non-zero `created`/`deleted` count means the event path is
  missing events — investigate Event Grid delivery metrics on the system topics.
- **Plan sizing**: `Y1` (Consumption) is fine for low VM-churn environments but
  has cold starts and must load several Az modules per cold start. For production
  at your scale, set `function_plan_sku = "EP1"` (Elastic Premium) to keep an
  always-warm instance and avoid module-load timeouts. This is a one-line change.
- **Throttling**: Private DNS allows ~60 record create/delete ops per minute per
  zone. A burst of >60 simultaneous VM deployments will queue (Event Grid retries
  handle it); reconciliation smooths the rest.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No record after VM create | Spoke not wired / EventGrid RP not registered | Confirm `terraform/spoke` applied; `az provider register --namespace Microsoft.EventGrid` in the spoke |
| Function runs but write fails (403) | Missing Private DNS Zone Contributor on zone RG | Re-check `azurerm_role_assignment.dns_zone_contributor`; if zone is cross-subscription add `provider = azurerm.zone` |
| Function can't read VM (403) | Reader not effective on spoke | Confirm the spoke is under the management group used in `management_group_id`; allow for RBAC propagation |
| Record created but no IP | Dynamic IP not yet assigned at event time | Expected; hourly reconcile fills it in. Lower impact by using static private IPs |
| Stale records linger | Delete event missed | Reconcile removes them on next run; check dead-letter / Event Grid metrics |
| Cold-start timeouts loading Az modules | Consumption plan | Switch to `EP1` |

---

## 11. Rollback / decommission

The design is additive and does not disturb existing resolution. To roll back:

1. **Stop registering**: in each spoke, `terraform destroy` the `spoke` module (or
   remove the module call) — deletes the system topic + event subscription. No
   more events flow.
2. **Stop reconciling**: stop or delete the Function App (`terraform destroy` in
   `terraform/platform`).
3. **Records**: existing A records remain until manually cleaned. To purge only
   registrar-managed records, delete record sets whose metadata is
   `managedBy=az-fx-registrar`.
4. Resolution links are untouched throughout — name resolution keeps working.

---

## 12. CI/CD pipelines (Azure DevOps)

Two pipelines are provided.

**`azure-pipelines.yml` — central CD** (runs on commits to `main`). Stages:

1. **Validate** — `terraform fmt`/`validate` on all modules + PSScriptAnalyzer on the function.
2. **DeployPlatform** — `terraform apply terraform/platform`, then exports the
   `registrar_function_id` and `function_app_name` outputs as pipeline variables.
3. **DeployFunction** — zips `function/` and deploys it with `AzureFunctionApp@2`.
4. **DeployPolicy** — `terraform apply terraform/policy`, consuming the function ID
   from stage 2 to assign the auto-onboarding policy at the management group.

Set up before first run:

- A **variable group** named `az-fx-dns-registrar` containing: `platformServiceConnection`,
  `platformSubscriptionId`, `zoneSubscriptionId`, `zoneResourceGroup`, `zoneName`,
  `managementGroupId`, `location`, `tfBackendResourceGroup`, `tfBackendStorageAccount`,
  `tfBackendContainer`.
- An **ARM service connection** (`platformServiceConnection`) scoped to the platform
  subscription **and** granted access at the management group (it creates the MG-scope
  Reader assignment, the policy, and the policy's role assignment).
- An **environment** `az-fx-dns-prod` — attach approvals/gates here to require sign-off
  before the platform and policy stages run.
- A terraform **state backend** (Azure Storage); values come from the variable group and
  are passed via `-backend-config`.

**`pipelines/onboard-spoke.yml` — per-spoke onboarding** (manual / orchestration-triggered).
Wires a single project subscription via `terraform/spoke-root` using that project's own
ARM service connection. Runtime parameters: `projectName`, `spokeServiceConnection`,
`spokeSubscriptionId`, `registrarFunctionId`, `location`, `deadLetterContainerId`. It also
registers the `Microsoft.EventGrid` resource provider in the spoke. Use this if you prefer
explicit, immediate per-spoke wiring over the policy (below), or fold its steps into your
existing project-onboarding pipeline.

## 13. Auto-onboarding via Azure Policy (`terraform/policy`)

For subscriptions created **outside** the onboarding pipeline, a `DeployIfNotExists`
policy guarantees the wiring still gets created. It is defined and assigned at the
management group and, for every subscription under it, deploys the Event Grid system
topic + VM event subscription pointing at the central registrar function — unless one
already exists.

How it works:

- The policy rule matches `type == Microsoft.Resources/subscriptions` with a
  **subscription-scope** deployment (`deploymentScope`/`existenceScope = subscription`),
  the same mechanism the built-in Defender-for-Cloud auto-provisioning policies use.
- `existenceCondition` checks for an existing system topic of type
  `Microsoft.Resources.Subscriptions`, so it is idempotent and won't duplicate the
  pipeline's wiring.
- The assignment's **system-assigned managed identity** is granted **Contributor** at the
  MG scope so it can create the resource group, system topic and event subscription in any
  spoke. (Least-privilege alternative: a custom role limited to `Microsoft.EventGrid/*`
  plus resource-group creation.)

Deploy it (the central pipeline does this automatically in the DeployPolicy stage):

```bash
cd terraform/policy
terraform init
terraform apply \
  -var "platform_subscription_id=<platform sub>" \
  -var "management_group_id=<MG id>" \
  -var "registrar_function_id=<registrar_function_id>"
```

**Remediating existing subscriptions.** `DeployIfNotExists` fires on subscription
create/update events, which are rare — so existing subscriptions need a one-time
remediation task:

```bash
az policy remediation create \
  --name remediate-vm-dns-egst \
  --management-group <MG id> \
  --policy-assignment "$(terraform -chdir=terraform/policy output -raw policy_assignment_id)" \
  --resource-discovery-mode ReEvaluateCompliance
```

**Pipeline or policy — which?** They are complementary. The policy is the safety net that
guarantees coverage with no manual step (recommended to keep enabled at `DeployIfNotExists`).
The `onboard-spoke` pipeline gives you explicit, immediate wiring during onboarding if you
don't want to wait for a policy evaluation/remediation cycle. Running both is fine — the
`existenceCondition` prevents duplication.

## 14. Design notes & references

- The `DeployIfNotExists` Azure Policy alternative was rejected for VMs because
  **policy cannot delete** records on VM teardown (no create/update event fires on
  delete), leaving stale records. The event-driven approach is the only one that
  cleanly handles the full create/update/**delete** lifecycle at scale.
- Zone **sharding** was rejected because it requires splitting the namespace into
  multiple differently-named zones; you cannot have multiple `az.fx` zones linked
  to the same vNets. We keep a single flat `az.fx`.
- Azure DNS Private Resolver does resolution/forwarding only and cannot register
  records — it stays in place purely for on-prem ⇄ Azure resolution.

Source documentation:
- [Azure DNS limits (100 auto-reg / 1000 resolution)](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-dns-limits)
- [Private DNS auto-registration](https://learn.microsoft.com/en-us/azure/dns/private-dns-autoregistration)
- [Azure subscription as an Event Grid source](https://learn.microsoft.com/en-us/azure/event-grid/event-schema-subscriptions)
- [DeployIfNotExists effect](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-deploy-if-not-exists)
- [Reference event-driven pattern (Paolo Salvatori)](https://github.com/paolosalvatori/handle-private-endopints-events-with-event-grid)
