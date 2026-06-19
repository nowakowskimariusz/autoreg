# Centralized VM DNS Registration into `az.fx` — Architecture Options & Recommendation

**Context:** Contoso ALZ (CAF) on Azure vWAN. Microsoft-managed virtual hub, spoke vNets per project, each project locked to its own subscription, Azure DevOps service connections scoped per-subscription, Terraform for all deployments, Azure DNS Private Resolver already deployed for on-prem integration. Goal: every project VM gets an A record in the single central private DNS zone `az.fx`, with create/update/**delete** handled automatically and centrally.

**Date:** June 2026

---

## 1. Reframing the problem — what is and isn't actually limited

The 100-vNet cap applies **only to auto-registration links**. Resolution links are a separate, much larger budget. Confirmed against the current (Feb/May 2026) Microsoft limits page:

| Private DNS limit | Value |
|---|---|
| vNet links per zone **with auto-registration** | **100** |
| vNet links per zone (resolution, total) | **1000** |
| Record sets per zone | 25,000 |
| Records per record set | 20 |
| Zones a vNet can auto-register into | 1 |

These are **independent** limits, and the private DNS limits carry **no "raise via support" footnote** — treat 100 as a hard architectural ceiling.

**Consequence for Contoso:** you do not have a *resolution* problem. You can link up to ~1000 spoke vNets to `az.fx` as resolution-only links (and your Private DNS Resolver already covers on-prem). You only have a *registration* problem. So the design goal is: **stop relying on per-spoke auto-registration, and register records centrally via the Azure DNS API instead.** Resolution stays exactly as it is today.

---

## 2. What does NOT work for your constraints

**Native auto-registration scaled out** — capped at 100 links, and a vNet can auto-register into only one zone. Dead end past 100 spokes.

**Zone sharding** (Microsoft's own documented pattern, *Sharding private DNS zones*, 2026) — creates *multiple* zones, each with its own 100-link budget. But it requires **partitioning the namespace** (e.g. `prod.az.fx`, `team1.az.fx`). You cannot have multiple zones all named `az.fx` linked to the same vNets — Azure forbids it. Sharding therefore **breaks your single flat `az.fx` namespace requirement**, so it's out (unless you're willing to give up the flat namespace).

**DNS VMs / domain controllers in the hub doing Dynamic DNS** — not possible: the vWAN virtual hub is Microsoft-managed; you cannot deploy components into it. (DNS VMs in a shared-services spoke is theoretically possible but you said you'd rather not run DNS infrastructure, and it adds HA/patching burden. Excluded.)

**Azure DNS Private Resolver doing the registration** — it can't. Confirmed: the resolver only does *resolution* and *conditional forwarding* (inbound/outbound endpoints, forwarding rulesets). It has no record-writing capability. It stays in your design purely for resolution (on-prem ⇄ Azure), deployed in a shared-services/hub-extension spoke vNet — which is exactly where you already have it.

**No new native feature** (2025–2026) raises the 100 limit or adds native cross-vNet registration. Verified against Azure Updates, Learn, and the Azure blog. Nothing is coming that changes this.

---

## 3. Recommended architecture — Event-driven central registration

This is the only approach that fully replicates native auto-registration's lifecycle (create **and delete**) at scale, while keeping all logic central and leaving project subscriptions untouched.

```
 Spoke subscription (project)                 Connectivity / platform subscription
 ┌──────────────────────────┐                 ┌─────────────────────────────────────┐
 │ VM / NIC created/deleted  │                 │                                     │
 │        │                  │   ARM events    │   Azure Function (or Logic App)     │
 │  Event Grid system topic  │ ──────────────► │   - reads NIC private IP            │
 │  (Azure subscription src) │  Write/Delete   │   - upserts / deletes A record      │
 │  filtered to NIC write/   │  Success        │        │                            │
 │  delete operations        │                 │        ▼                            │
 └──────────────────────────┘                 │   Private DNS zone  az.fx           │
                                               │   (resolution links to all spokes)  │
                                               └─────────────────────────────────────┘
```

**How it works**

1. Each spoke subscription has an **Event Grid system topic** (source = the Azure subscription) with an event subscription filtered on `data.operationName` to `Microsoft.Network/networkInterfaces/write` and `.../delete` (alternatively key off `Microsoft.Compute/virtualMachines/*`).
2. Two ARM management events drive everything:
   - `Microsoft.Resources.ResourceWriteSuccess` → VM/NIC created or updated → **create/update** the A record.
   - `Microsoft.Resources.ResourceDeleteSuccess` → VM/NIC deleted → **delete** the A record. *(This is the piece the policy approach below cannot do.)*
3. Events route to a single central **Azure Function** (in the connectivity/platform subscription) that reads the NIC's private IP and upserts/deletes the record in `az.fx` via the Azure DNS SDK/REST API, using its managed identity.
4. A **scheduled reconciliation job** (Function timer or Automation runbook) periodically queries all NICs via Azure Resource Graph and compares against the zone, cleaning up any records missed due to dropped events. This is your safety net — events are best-effort, so dead-lettering + reconciliation are mandatory for correctness.

**Why this fits Contoso specifically**
- **Central by design** — all registration logic lives in the platform subscription. Project teams keep deploying VMs through their subscription-scoped service connections and never touch `az.fx`. No delegation of zone permissions to projects.
- **Full lifecycle** — create, update, *and* delete, matching what native auto-registration did before you outgrew it.
- **No hub components** — nothing is deployed into the managed vWAN hub. The Function lives in a normal platform subscription; the resolver stays where it is.
- **Scales past 1000** — limited only by record-set count (25,000), not by vNet links.

**Reference to adapt:** the canonical published implementation is Paolo Salvatori's `handle-private-endopints-events-with-event-grid` (built for private endpoints, but the mechanism is NIC + private-IP based and ports directly to VMs). Note: there is **no** Microsoft-published, VM-specific repo for this — all official references target *private endpoints*. You'll be adapting, not lifting wholesale.

---

## 4. RBAC / permission model (cross-subscription)

The Function's **managed identity** needs:

| Scope | Role | Why |
|---|---|---|
| Resource group hosting `az.fx` (platform sub) | **Private DNS Zone Contributor** | Create/update/delete A records. (Not "DNS Zone Contributor" — that's for *public* DNS.) |
| All spoke subscriptions (assign at a Management Group covering them) | **Reader** | Read NIC objects / private IPs across every project subscription. |

Assigning Reader at the management-group level means new project subscriptions inherit it automatically — no per-onboarding RBAC step. This is the only standing cross-subscription grant, and it is read-only on the spoke side; the only *write* surface is the central zone, held by one identity you control.

---

## 5. Where the DeployIfNotExists policy alternative falls short

A common first instinct is an Azure Policy **DeployIfNotExists** that creates an A record when a NIC appears. It can create/update, and the cross-sub RBAC is similar (policy MI gets Private DNS Zone Contributor on the central zone's RG). **But DINE cannot delete** — there's no create/update event on VM teardown, so it leaves stale records, and it has fragile timing (may fire before the NIC's private IP is queryable). It works well for *private endpoints* only because the DNS record there is a child of the endpoint and cascades on delete; a VM's A record has no such parent.

**However, policy still has a valuable role here:** use a DINE/`DeployIfNotExists` policy assigned at the management group to **auto-provision the Event Grid system topic + event subscription on every new spoke subscription**. That keeps your "new project = fully wired up" onboarding promise without manual steps — the policy builds the plumbing, the event pipeline does the registration.

---

## 6. How Terraform + Azure DevOps fit

**Platform/DevOps-team Terraform (central, one-time + per-onboarding):**
- The central Function/Logic App, its managed identity, dead-letter storage, and monitoring.
- The `az.fx` zone (already exists) and its resolution-only vNet links to spokes (you likely already create these as part of spoke onboarding — keep them, just ensure `registration_enabled = false`).
- The management-group RBAC (Reader on spokes, Private DNS Zone Contributor on the zone RG).
- The Azure Policy that auto-deploys the Event Grid system topic + subscription per spoke — **or** create the system topic + event subscription directly in your existing per-project Terraform onboarding module. Either works; policy is more self-healing for subscriptions created outside the pipeline.

**Project-team pipelines:** completely unchanged. They deploy VMs with their subscription-scoped service connection. Registration is invisible to them and requires no zone access — which is exactly the isolation model you want.

---

## 7. Record lifecycle summary

| Event | Mechanism | Result |
|---|---|---|
| VM/NIC created | `ResourceWriteSuccess` → Function | A record created in `az.fx` |
| VM IP changed | `ResourceWriteSuccess` → Function | A record updated |
| VM/NIC deleted | `ResourceDeleteSuccess` → Function | A record removed |
| Missed/dropped event | Scheduled Resource Graph reconciliation | Stale records cleaned, missing records added |

Naming: derive the record name from VM/NIC name (and optionally a project prefix) to keep the flat `az.fx` namespace collision-free across projects — decide a convention (e.g. `<vmname>.az.fx` vs `<vmname>-<project>.az.fx`) up front.

---

## 8. Implementation outline

1. **Confirm resolution path** — ensure all spokes have resolution-only links (`registration_enabled = false`) to `az.fx`; on-prem resolution continues via the existing Private DNS Resolver. No change needed if already in place.
2. **Build the central registrar** — Function (.NET/PowerShell/Python) with system-assigned managed identity; Event Grid webhook/trigger; logic to read NIC IP and upsert/delete A record via Azure DNS SDK. Add dead-lettering.
3. **Grant RBAC** — Private DNS Zone Contributor on the zone RG; Reader at the MG over spoke subscriptions.
4. **Wire spokes** — Terraform module (or DINE policy) to create the Event Grid system topic + filtered event subscription per spoke, pointing at the Function.
5. **Add reconciliation** — timer-triggered Resource Graph sweep to repair drift.
6. **Pilot** — enable on 2–3 spokes, validate create/update/delete + reconciliation, monitor dead-letter queue.
7. **Roll out** — fold the wiring into the standard project-onboarding pipeline; decommission native auto-registration links as spokes migrate.

---

## Sources
- [Azure subscription & service limits — Azure DNS limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-dns-limits) (100 auto-reg / 1000 resolution; current 2026)
- [Private DNS virtual network links (registration vs resolution)](https://learn.microsoft.com/en-us/azure/dns/private-dns-virtual-network-links)
- [Private DNS auto-registration overview](https://learn.microsoft.com/en-us/azure/dns/private-dns-autoregistration)
- [Sharding private DNS zones](https://learn.microsoft.com/en-us/azure/dns/sharding-private-dns-zones)
- [Azure DNS Private Resolver overview](https://learn.microsoft.com/en-us/azure/dns/dns-private-resolver-overview)
- [Private Link & DNS in Virtual WAN (resolver in hub-extension vNet)](https://learn.microsoft.com/en-us/azure/architecture/networking/guide/private-link-virtual-wan-dns-guide)
- [Private Link & DNS integration at scale — DINE + cross-sub RBAC](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/private-link-and-dns-integration-at-scale)
- [DeployIfNotExists effect (cannot delete)](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-deploy-if-not-exists)
- [Azure subscription as Event Grid source (event types & filtering)](https://learn.microsoft.com/en-us/azure/event-grid/event-schema-subscriptions)
- [Reference event-driven implementation — paolosalvatori/handle-private-endopints-events-with-event-grid](https://github.com/paolosalvatori/handle-private-endopints-events-with-event-grid)
