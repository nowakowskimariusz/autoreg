# =============================================================================
# az.fx central DNS registrar (Python, Functions v2 model, Flex Consumption)
# -----------------------------------------------------------------------------
# RegisterVmDns (Event Grid trigger)
#   VM write/delete events from each spoke -> keep "<vm>.az.fx" A record in sync.
#     write  -> upsert A <vm> -> primary NIC private IP
#     delete -> remove A <vm>  (only if managed by us)
#
# ReconcileDns (Timer trigger)
#   Periodic safety net: rebuild desired state from Azure Resource Graph and
#   reconcile the zone (create missing, fix drifted IPs, delete orphans).
#
# Records written by this app carry metadata managedBy=<MANAGED_BY_TAG>; the
# delete path and the reconciler only ever touch records carrying that tag, so
# hand-created records are never modified or removed.
#
# Auth: the Function App's managed identity (DefaultAzureCredential) is granted
#   Reader on the spoke management group and Private DNS Zone Contributor on the
#   az.fx zone resource group.
# =============================================================================

import logging
import os
import re

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.privatedns import PrivateDnsManagementClient
from azure.mgmt.privatedns.models import ARecord, RecordSet
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions

app = func.FunctionApp()

# ---- Configuration (Function App application settings) ----------------------
ZONE_SUBSCRIPTION_ID = os.environ["ZONE_SUBSCRIPTION_ID"]
ZONE_RESOURCE_GROUP = os.environ["ZONE_RESOURCE_GROUP"]
ZONE_NAME = os.environ["ZONE_NAME"]
RECORD_TTL = int(os.environ.get("RECORD_TTL", "3600"))
MANAGED_BY = os.environ.get("MANAGED_BY_TAG", "az-fx-registrar")

# Single shared credential (managed identity in Azure).
_CRED = DefaultAzureCredential()

_VM_ID_RE = re.compile(
    r"^/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)"
    r"/providers/Microsoft\.Compute/virtualMachines/(?P<vm>[^/]+)$",
    re.IGNORECASE,
)
_NIC_ID_RE = re.compile(
    r"^/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)"
    r"/providers/Microsoft\.Network/networkInterfaces/(?P<nic>[^/]+)$",
    re.IGNORECASE,
)


def _dns_client() -> PrivateDnsManagementClient:
    return PrivateDnsManagementClient(_CRED, ZONE_SUBSCRIPTION_ID)


# ---------------------------------------------------------------------------
# Event Grid trigger
# ---------------------------------------------------------------------------
@app.function_name(name="RegisterVmDns")
@app.event_grid_trigger(arg_name="event")
def register_vm_dns(event: func.EventGridEvent) -> None:
    data = event.get_json() or {}
    operation = data.get("operationName", "") or ""
    resource_id = data.get("resourceUri") or event.subject or ""
    logging.info("Event %s | op %s | resource %s", event.event_type, operation, resource_id)

    match = _VM_ID_RE.match(resource_id)
    if not match:
        logging.info("Resource is not a virtual machine. Ignoring.")
        return

    spoke_sub = match.group("sub")
    record_name = match.group("vm").lower()  # produces <vm>.az.fx
    dns = _dns_client()

    # ---- DELETE path --------------------------------------------------------
    if operation.lower().endswith("/delete"):
        existing = _safe_get_record(dns, record_name)
        if existing is None:
            logging.info("No A record '%s'. Nothing to delete.", record_name)
            return
        if (existing.metadata or {}).get("managedBy") != MANAGED_BY:
            logging.info("A record '%s' not managed by '%s'. Leaving it.", record_name, MANAGED_BY)
            return
        dns.record_sets.delete(ZONE_RESOURCE_GROUP, ZONE_NAME, "A", record_name)
        logging.info("Deleted A record '%s'.", record_name)
        return

    # ---- WRITE / CREATE path ------------------------------------------------
    private_ip = _primary_private_ip(spoke_sub, match.group("rg"), match.group("vm"))
    if not private_ip:
        logging.info("No private IP for '%s' yet. Reconciliation will handle it.", record_name)
        return

    _upsert(dns, record_name, private_ip, resource_id)


def _safe_get_record(dns: PrivateDnsManagementClient, name: str):
    try:
        return dns.record_sets.get(ZONE_RESOURCE_GROUP, ZONE_NAME, "A", name)
    except Exception:  # noqa: BLE001 - 404 etc.
        return None


def _primary_private_ip(sub: str, rg: str, vm_name: str):
    compute = ComputeManagementClient(_CRED, sub)
    network = NetworkManagementClient(_CRED, sub)
    try:
        vm = compute.virtual_machines.get(rg, vm_name)
    except Exception:  # noqa: BLE001 - VM may have been deleted already
        logging.info("VM '%s' not found in sub %s. Skipping.", vm_name, sub)
        return None

    nics = (vm.network_profile.network_interfaces or []) if vm.network_profile else []
    if not nics:
        return None
    nic_ref = next((n for n in nics if n.primary), nics[0])

    nic_match = _NIC_ID_RE.match(nic_ref.id or "")
    if not nic_match:
        return None
    nic = network.network_interfaces.get(nic_match.group("rg"), nic_match.group("nic"))

    ip_cfgs = nic.ip_configurations or []
    if not ip_cfgs:
        return None
    ip_cfg = next((c for c in ip_cfgs if c.primary), ip_cfgs[0])
    return ip_cfg.private_ip_address


def _upsert(dns: PrivateDnsManagementClient, name: str, ip: str, vm_id: str) -> None:
    record_set = RecordSet(
        ttl=RECORD_TTL,
        a_records=[ARecord(ipv4_address=ip)],
        metadata={"managedBy": MANAGED_BY, "sourceVmId": vm_id},
    )
    dns.record_sets.create_or_update(ZONE_RESOURCE_GROUP, ZONE_NAME, "A", name, record_set)
    logging.info("Upserted A record '%s' -> %s.", name, ip)


# ---------------------------------------------------------------------------
# Timer trigger (reconciliation safety net)
# ---------------------------------------------------------------------------
@app.function_name(name="ReconcileDns")
@app.timer_trigger(schedule="%RECONCILE_SCHEDULE%", arg_name="timer", run_on_startup=False, use_monitor=True)
def reconcile_dns(timer: func.TimerRequest) -> None:
    logging.info("Reconciliation started.")
    desired = _desired_state()
    logging.info("Desired A records (live VMs): %d", len(desired))

    dns = _dns_client()
    current = {rs.name.lower(): rs for rs in dns.record_sets.list_by_type(ZONE_RESOURCE_GROUP, ZONE_NAME, "A")}

    created = updated = deleted = 0

    # create / update
    for name, ip in desired.items():
        rs = current.get(name)
        if rs is None:
            _upsert(dns, name, ip, vm_id="")
            created += 1
        else:
            cur_ip = rs.a_records[0].ipv4_address if rs.a_records else None
            if cur_ip != ip or (rs.metadata or {}).get("managedBy") != MANAGED_BY:
                _upsert(dns, name, ip, vm_id=(rs.metadata or {}).get("sourceVmId", ""))
                updated += 1

    # delete stale, managed records with no backing VM
    for name, rs in current.items():
        if (rs.metadata or {}).get("managedBy") == MANAGED_BY and name not in desired:
            dns.record_sets.delete(ZONE_RESOURCE_GROUP, ZONE_NAME, "A", rs.name)
            deleted += 1

    logging.info("Reconciliation complete. created=%d updated=%d deleted=%d", created, updated, deleted)


def _desired_state() -> dict:
    """Map of {vm_name(lower): primary_private_ip} for every VM the identity can read."""
    rg_client = ResourceGraphClient(_CRED)
    query = (
        "resources "
        "| where type =~ 'microsoft.compute/virtualmachines' "
        "| extend nicId = tostring(properties.networkProfile.networkInterfaces[0].id) "
        "| join kind=inner ( "
        "    resources "
        "    | where type =~ 'microsoft.network/networkinterfaces' "
        "    | mv-expand ipconfig = properties.ipConfigurations "
        "    | extend isPrimary = tobool(ipconfig.properties.primary) "
        "    | where isPrimary == true "
        "    | project nicId = id, privateIp = tostring(ipconfig.properties.privateIPAddress) "
        ") on nicId "
        "| where isnotempty(privateIp) "
        "| project vmName = tolower(name), privateIp"
    )

    desired: dict = {}
    skip = 0
    while True:
        options = QueryRequestOptions(top=1000, skip=skip)
        response = rg_client.resources(QueryRequest(query=query, options=options))
        rows = response.data or []
        for row in rows:
            name = row["vmName"]
            ip = row["privateIp"]
            if name not in desired:
                desired[name] = ip
            else:
                logging.warning("Duplicate VM name '%s'; keeping %s, ignoring %s.", name, desired[name], ip)
        if len(rows) < 1000:
            break
        skip += 1000
    return desired
