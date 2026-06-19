# az.fx Central DNS Registrar — Implementation Guide

Centralized, automatic registration of VM A records into the single `az.fx`
private DNS zone, across all project spoke subscriptions — without relying on
Azure Private DNS auto-registration (which is hard-capped at **100 vNet links
per zone**).

This repo contains everything the DevOps team needs: the Function code (Python),
the Terraform for the central registrar and the per-spoke wiring, an Azure Policy
that auto-onboards subscriptions, the CI/CD pipelines, and the operate/rollback steps.

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
 │ VM created / updated /      │   ARM        │  Flex Consumption Function App         │
 │ deleted                     │   events     │  (Python, user-assigned identity)      │
 │        │                    │  Write/Delete│  ┌──────────────────────────────────┐ │
 │  Event Grid system topic    │ ───────────► │  │ RegisterVmDns (Event Grid trigger)│ │
 │  (subscription source,      │   Success    │  │  write  -> upsert A <vm> -> IP    │ │
 │   in rg-network)            │              │  │  delete -> remove A <vm>          │ │
 └───────────────────────────┘               │  └──────────────────────────────────┘ │
                                              │  ┌──────────────────────────────────┐ │
   one shared system topic per spoke,        │  │ ReconcileDns (Timer, hourly)      │ │
   many event subscriptions hang off it       │  │  Resource Graph -> repair drift   │ │
                                              │  └──────────────────────────────────┘ │
                                              │   VNet-integrated → private storage    │
                                              │              │ Private DNS Zone Contributor
                                              │              ▼                          │
                                              │      Private DNS zone  az.fx            │
                                              └──────────────────────────────────────┘
```

- **`RegisterVmDns`** (Event Grid trigger) — fires on `Microsoft.Compute/virtualMachines`
  `write`/`delete` events. On write it reads the VM's primary NIC private IP and
  upserts `<vm>.az.fx`; on delete it removes the record.
- **`ReconcileDns`** (timer, hourly) — the safety net. Rebuilds desired state from
  Azure Resource Graph and repairs the zone: creates missing, fixes changed IPs,
  deletes records with no backing VM.
- **Record naming** — `<vm>.az.fx`, from the VM resource name (your "next available
  number" convention keeps these unique; the reconciler warns on duplicates).
- **Safety tag** — every record the registrar writes carries metadata
  `managedBy = az-fx-registrar`. The delete path and reconciler **only ever touch
  records carrying that tag**, so manually-created records are never modified.

### Language: Python (not PowerShell)
The function is **Python** because the app runs on the **Flex Consumption** plan,
and Flex does **not** support PowerShell managed dependencies (`requirements.psd1`)
— the clean way to pull the Az modules. Python on Flex uses a server-side remote
build (`pip install -r requirements.txt`), so dependencies are handled cleanly.

### Why VM events (not NIC events)
Triggering on the VM resource gives the VM name directly in the event for both
create and delete, matching the `<vm>.az.fx` convention. A private IP changing
without a VM PUT is rare and is caught by the hourly reconciler.

---

## 3. Repository layout

```
az-fx-dns-registrar/
├── README.md                       ← this guide
├── azure-pipelines.yml             ← central CD: validate → platform → function → policy
├── function/                       ← Function App code (Python, Functions v2 model)
│   ├── host.json
│   ├── requirements.txt            ← installed by Flex remote build
│   └── function_app.py             ← RegisterVmDns (Event Grid) + ReconcileDns (Timer)
├── pipelines/
│   ├── onboard-spoke.yml           ← per-spoke onboarding pipeline (optional)
│   └── templates/
│       └── terraform-apply.yml     ← reusable terraform step template
└── terraform/
    ├── platform/                   ← deploy ONCE: Flex app, private storage, network, RBAC
    ├── spoke/                      ← reusable module: shared system topic + event subscriptions
    ├── spoke-root/                 ← thin root to apply the spoke module standalone
    └── policy/                     ← DeployIfNotExists policy: auto-wire every subscription
```

---

## 4. Prerequisites

- The `az.fx` private DNS zone already exists in the connectivity subscription.
  Note its **subscription ID** and **resource group**.
- A **management group** containing all current/future spoke subscriptions. Note its ID.
- **Storage privatelink DNS zones** — the resource IDs of `privatelink.blob.core.windows.net`,
  `privatelink.queue.core.windows.net`, `privatelink.table.core.windows.net`
  (standard in CAF/ALZ connectivity). The platform Terraform attaches the storage
  private endpoints to these and links them to the registrar VNet.
- **Resource providers** registered in the platform subscription:
  `Microsoft.App` (Flex VNet integration delegation), `Microsoft.Web`, `Microsoft.EventGrid`,
  `Microsoft.Network`.
  `az provider register --namespace Microsoft.App --subscription <platform>`
- RBAC for the principal running the **platform** Terraform: `Owner` (or
  `Contributor` + `User Access Administrator`) in the platform subscription, plus
  `User Access Administrator` at the management group (to grant Reader) and on the
  zone's resource group (to grant Private DNS Zone Contributor).
- Tooling: Terraform ≥ 1.5 with the **azurerm (~>4.0)** and **azapi (~>2.0)** providers.

---

## 5. Architecture decisions baked into the platform Terraform

**Hosting — Flex Consumption.** `azurerm_service_plan` with `sku_name = "FC1"`,
`os_type = "Linux"`, and `azurerm_function_app_flex_consumption`. (Y1/Consumption is
now described by Microsoft as legacy.) Sizing is configurable
(`instance_memory_in_mb`, `maximum_instance_count`).

**Storage — private and identity-only.** The Function's storage account is created
with `shared_access_key_enabled = false`, `public_network_access_enabled = false`,
`default_action = Deny`. There are **no access keys** and **no public path**:

- The Function connects to host storage by identity: app settings
  `AzureWebJobsStorage__accountName`, `AzureWebJobsStorage__credential = managedidentity`,
  `AzureWebJobsStorage__clientId = <UAI client id>`.
- Private endpoints for **blob, queue, table** (Flex does **not** use Azure Files,
  so no `file` endpoint), attached to your existing privatelink DNS zones.
- The deployment package container is created via the **management plane** (the
  `azapi` provider) so Terraform doesn't need data-plane access to the locked-down
  account.

**Identity — user-assigned.** A user-assigned managed identity is created first, all
role assignments are made against it, then the Function references it. This avoids a
Terraform dependency cycle and the storage chicken-and-egg at app-create time.

**Networking.** A small VNet with two subnets: `snet-func-integration` (delegated to
`Microsoft.App/environments`, /27 — the Flex requirement) for outbound VNet
integration, and `snet-private-endpoints` for the storage PEs. The privatelink zones
are linked to this VNet so the Function resolves the PEs (toggle with
`link_privatelink_zones_to_vnet` if your platform already links them).

> The Function app keeps **public inbound** access (only the *storage* is private).
> This is deliberate: it lets Event Grid deliver events and lets a standard pipeline
> agent deploy code (see §14). To also lock down inbound, add a `sites` private
> endpoint and deploy from a VNet-connected agent.

---

## 6. RBAC model (what gets granted, where)

All assignments target the Function's **user-assigned managed identity** (created by
the platform Terraform):

| Scope | Role | Purpose |
|---|---|---|
| Storage account | **Storage Blob Data Owner** | Host metadata + deployment container (data-plane; Owner needed because the host creates containers). |
| Storage account | **Storage Queue Data Contributor** | Host queue operations. |
| Storage account | **Storage Table Data Contributor** | Host diagnostics / state. |
| `az.fx` zone's resource group | **Private DNS Zone Contributor** | Create/update/delete A records. |
| Management group over all spokes | **Reader** | Read VM + NIC private IPs in every spoke. Read-only. |

Reader at MG scope means **new spoke subscriptions inherit access automatically**.
Project teams need **no** access to `az.fx`; their subscription-scoped service
connections are unchanged. The only write surface is the central zone.

---

## 7. Deployment

### Step 1 — Deploy the central registrar (once)

```bash
cd terraform/platform

cat > terraform.tfvars <<'EOF'
platform_subscription_id      = "<platform/connectivity sub id>"
zone_subscription_id          = "<sub id that hosts az.fx>"
zone_resource_group           = "<rg that hosts az.fx>"
zone_name                     = "az.fx"
location                      = "westeurope"
management_group_id           = "<MG id covering all spokes>"
privatelink_blob_dns_zone_id  = "<.../privateDnsZones/privatelink.blob.core.windows.net>"
privatelink_queue_dns_zone_id = "<.../privateDnsZones/privatelink.queue.core.windows.net>"
privatelink_table_dns_zone_id = "<.../privateDnsZones/privatelink.table.core.windows.net>"
EOF

terraform init
terraform apply
```

> If `az.fx` is in a different subscription than the Function App, add
> `provider = azurerm.zone` to `azurerm_role_assignment.dns_zone_contributor` in
> `main.tf` (the alias is declared in `providers.tf`).

Capture the outputs you'll reuse:

```bash
terraform output registrar_function_id   # for the spokes / policy
terraform output function_app_name        # for code deploy
```

### Step 2 — Deploy the Function code

Flex uses "one deploy" (zip → deployment container, then remote build):

```bash
cd ../../function
func azure functionapp publish <function_app_name>
```

Because only the *storage* is private and the app keeps public inbound, a normal
agent/dev machine can deploy — the platform stages the package to the private
container using the app's identity. See §14 for the fully-private variant.

### Step 3 — Wire spokes (two complementary mechanisms)

- **Azure Policy (recommended baseline)** — `terraform/policy` auto-creates the
  wiring in every subscription under the MG. See §13.
- **Per-spoke pipeline/module (optional)** — `terraform/spoke-root` via
  `pipelines/onboard-spoke.yml` for explicit/immediate wiring. See §12.

Both deploy into the **existing `rg-network`** (workload subs only ever have
`rg-network`, `rg-secrets`, `rg-terraform`, so no new RG is created).

### Step 4 — Resolution links (verify, don't duplicate)

Each spoke needs a **resolution-only** link to `az.fx`
(`registration_enabled = false`). You almost certainly create this already in the
module that peers the spoke to the hub — just confirm registration is disabled.
Resolution links scale to ~1000 per zone, so this is not a bottleneck.

---

## 8. Record lifecycle

| Event | Path | Result |
|---|---|---|
| VM created | `ResourceWriteSuccess` → `RegisterVmDns` | A record `<vm>` created → primary private IP |
| VM IP changed (via PUT) | `ResourceWriteSuccess` → `RegisterVmDns` | A record updated |
| VM deleted | `ResourceDeleteSuccess` → `RegisterVmDns` | A record removed (if `managedBy` tag) |
| Missed/dropped event | hourly `ReconcileDns` | Missing created, drifted IP fixed, orphans removed |

---

## 9. Testing / validation

1. Pilot on 2–3 spokes before fleet rollout.
2. Create a VM in a wired spoke; within ~1–2 min:
   ```bash
   az network private-dns record-set a show \
     --resource-group <az.fx RG> --zone-name az.fx --name <vmname> --subscription <zone sub>
   ```
   Confirm the A record + `managedBy=az-fx-registrar` metadata.
3. From a VM linked to `az.fx`, `nslookup <vmname>.az.fx` resolves.
4. Delete the VM → record disappears within ~1–2 min.
5. Manually delete a record for a live VM → next hourly reconcile recreates it.
6. Create an *untagged* record → reconcile leaves it alone.
7. Application Insights (`appi-fxdnsreg`):
   ```kusto
   traces | where operation_Name in ("RegisterVmDns","ReconcileDns") | order by timestamp desc
   ```

---

## 10. Operations & monitoring

- **Application Insights** captures every invocation and exception (wired via
  `application_insights_connection_string`). Alert on `exceptions` for both functions.
- **Dead-letter** (if configured per spoke): alert on any blob in the dead-letter
  container — an event exhausted 30 delivery attempts.
- **Reconciliation summary** logs `created/updated/deleted` counts. Persistently
  non-zero create/delete means the event path is missing events — check Event Grid
  delivery metrics on the system topics.
- **Throttling**: Private DNS allows ~60 record ops/min per zone; bursts queue via
  Event Grid retries, and reconciliation smooths the rest.

---

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No record after VM create | Spoke not wired / EventGrid RP not registered | Confirm policy/spoke applied; `az provider register --namespace Microsoft.EventGrid` |
| Function 403 writing records | Missing Private DNS Zone Contributor | Re-check role; if cross-subscription zone add `provider = azurerm.zone` |
| Function can't read VM (403) | Reader not effective on spoke | Confirm spoke under the MG used in `management_group_id`; allow RBAC propagation |
| Function can't reach storage | Privatelink zones not linked to the VNet, or PE missing | Confirm `link_privatelink_zones_to_vnet`, the three PEs, and zone links |
| App won't start / deploy storage error | UAI missing Storage Blob Data Owner, or `Microsoft.App` RP not registered | Re-check storage role assignments + RP registration |
| Record created but no IP | Dynamic IP not yet assigned at event time | Expected; hourly reconcile fills it in |

---

## 12. CI/CD pipelines (Azure DevOps)

**`azure-pipelines.yml` — central CD** (on commits to `main`):

1. **Validate** — `terraform fmt`/`validate` on all modules + Python compile/import check.
2. **DeployPlatform** — `terraform apply terraform/platform`; exports
   `registrar_function_id` and `function_app_name`.
3. **DeployFunction** — zips `function/` and deploys with `AzureFunctionApp@2`
   (`appType: functionAppLinux`, `isFlexConsumption: true`).
4. **DeployPolicy** — `terraform apply terraform/policy` using the function ID.

Variable group `az-fx-dns-registrar` must include: `platformServiceConnection`,
`platformSubscriptionId`, `zoneSubscriptionId`, `zoneResourceGroup`, `zoneName`,
`managementGroupId`, `location`, `privatelinkBlobDnsZoneId`,
`privatelinkQueueDnsZoneId`, `privatelinkTableDnsZoneId`, `tfBackendResourceGroup`,
`tfBackendStorageAccount`, `tfBackendContainer`. Gate the `az-fx-dns-prod`
environment with approvals.

**`pipelines/onboard-spoke.yml` — per-spoke onboarding** (manual). Wires one
project subscription via `terraform/spoke-root` using that project's ARM service
connection. Parameters: `projectName`, `spokeServiceConnection`, `spokeSubscriptionId`,
`registrarFunctionId`, `resourceGroupName` (default `rg-network`), `deadLetterContainerId`.

---

## 13. Auto-onboarding via Azure Policy (`terraform/policy`)

**Built-in vs custom — verified: custom is required.** Every built-in Event Grid
DeployIfNotExists policy only creates *private endpoints* or *diagnostic settings* on
existing resources; none creates a system topic or event subscription. So we ship a
custom DINE policy.

It is defined and assigned at the management group and, for every subscription under
it, deploys the shared Event Grid system topic + the VM event subscription into the
existing `rg-network`, pointing at the central registrar function — unless one
already exists (`existenceCondition` makes it idempotent). The subscription-scope
DINE pattern (rule matches `Microsoft.Resources/subscriptions`,
`deploymentScope/existenceScope = subscription`) is the same one Microsoft's
Defender-for-Cloud auto-provisioning policies use.

The assignment's managed identity gets **Contributor** at the MG (least-privilege
alternative: a custom role limited to `Microsoft.EventGrid/*`).

Deploy (the central pipeline does this automatically):

```bash
cd terraform/policy
terraform init
terraform apply \
  -var "platform_subscription_id=<platform sub>" \
  -var "management_group_id=<MG id>" \
  -var "registrar_function_id=<registrar_function_id>"
```

**Remediate existing subscriptions** (DINE only fires on subscription create/update):

```bash
az policy remediation create \
  --name remediate-vm-dns-egst \
  --management-group <MG id> \
  --policy-assignment "$(terraform -chdir=terraform/policy output -raw policy_assignment_id)" \
  --resource-discovery-mode ReEvaluateCompliance
```

---

## 14. Extending the solution (future growth)

The design is built to grow. There is **one shared Event Grid system topic per
subscription** (`egst-subscription-events`) carrying *all* subscription-level ARM
events; each piece of functionality is just another **event subscription** (its own
filter → its own handler function) hanging off that same topic.

**Add a new action** (e.g. react to tag changes, NSG changes, anything):

1. Deploy a new handler function (extend `function_app.py` with another trigger, or
   a separate Function App).
2. Add an entry to `event_subscriptions` in `terraform/spoke-root/main.tf`:
   ```hcl
   tag-sync = {
     operation_names = ["Microsoft.Resources/tags/write"]
     function_id     = "<other-function-id>"
   }
   ```
3. Re-apply the spoke module across spokes (or via the onboarding pipeline).

**Change the filter** on an existing action — edit `operation_names` for that entry
and re-apply; the event subscription updates in place.

**Upgrade subscriptions on older config** — because the system topic is shared and
generically named, re-running the spoke module (or policy remediation) reconciles
each subscription to the current set of event subscriptions without recreating the
topic. New event subscriptions are added; the topic is untouched.

This keeps the per-subscription footprint to a single topic and makes "add another
automation" a config change, not a redesign.

### Fully-private inbound (optional hardening)
Today the Function app keeps public inbound (only storage is private), so Event Grid
delivery and standard pipeline deployment work out of the box. To also remove public
inbound: add a `sites` private endpoint to the app, set `public_network_access_enabled = false`,
and deploy code from a **self-hosted Azure DevOps agent / Managed DevOps Pool with VNet
line-of-sight** to the app's SCM and the storage blob PE (a fully internet-only agent
cannot deploy to a network-secured app). Event Grid → private function delivery then
also needs a private-link delivery topology.

---

## 15. Rollback / decommission

The design is additive and doesn't disturb resolution. To roll back:

1. **Stop registering**: remove the policy assignment and/or `terraform destroy` the
   spoke wiring — no more events flow.
2. **Stop reconciling**: `terraform destroy` `terraform/platform`.
3. **Records**: registrar-managed records remain until cleaned; delete record sets
   whose metadata is `managedBy=az-fx-registrar`.
4. Resolution links are untouched throughout — name resolution keeps working.

---

## 16. Design notes & references

- DeployIfNotExists for VMs was rejected because policy **cannot delete** records on
  VM teardown; the event-driven approach handles the full lifecycle.
- Zone **sharding** was rejected — it splits the namespace; you can't have multiple
  `az.fx` zones on the same vNets. Single flat `az.fx` kept.
- Azure DNS Private Resolver does resolution/forwarding only; it stays for on-prem ⇄
  Azure resolution.

References:
- [Azure DNS limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-dns-limits)
- [Flex Consumption plan](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan)
- [azurerm_function_app_flex_consumption](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/function_app_flex_consumption)
- [Functions identity-based connections](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference#connecting-to-host-storage-with-an-identity)
- [Functions networking options (Flex delegation, DNS)](https://learn.microsoft.com/en-us/azure/azure-functions/functions-networking-options)
- [Deployment to network-secured apps](https://learn.microsoft.com/en-us/azure/azure-functions/functions-deployment-technologies)
- [Event Grid subscription-source events](https://learn.microsoft.com/en-us/azure/event-grid/event-schema-subscriptions)
- [Event Grid built-in policies](https://learn.microsoft.com/en-us/azure/event-grid/policy-reference)
- [DeployIfNotExists effect](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-deploy-if-not-exists)
