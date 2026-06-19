# =============================================================================
# RegisterVmDns - Event Grid triggered
# -----------------------------------------------------------------------------
# Reacts to Azure Resource Manager events for virtual machines (write/delete)
# emitted by an Event Grid system topic on each spoke subscription, and keeps an
# A record "<vm>.az.fx" in the central private DNS zone in sync.
#
#   VM created/updated -> upsert  A record  <vm>  ->  primary NIC private IP
#   VM deleted         -> remove  A record  <vm>  (only if managed by us)
#
# Records created by this function are tagged with metadata managedBy=<value>
# so the reconciliation job and the delete path never touch records created by
# hand or by other tooling.
# =============================================================================

param($eventGridEvent, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

# ---- Configuration (Function App application settings) ----------------------
$zoneSubscriptionId = $env:ZONE_SUBSCRIPTION_ID      # sub that hosts the az.fx zone
$zoneResourceGroup  = $env:ZONE_RESOURCE_GROUP       # RG that hosts the az.fx zone
$zoneName           = $env:ZONE_NAME                 # e.g. az.fx
$ttl                = [int]($env:RECORD_TTL)         # e.g. 3600
$managedByValue     = if ($env:MANAGED_BY_TAG) { $env:MANAGED_BY_TAG } else { 'az-fx-registrar' }

if (-not $zoneSubscriptionId -or -not $zoneResourceGroup -or -not $zoneName) {
    throw "Missing configuration. ZONE_SUBSCRIPTION_ID, ZONE_RESOURCE_GROUP and ZONE_NAME must be set."
}
if ($ttl -le 0) { $ttl = 3600 }

# ---- Parse the event --------------------------------------------------------
$operation  = $eventGridEvent.data.operationName
$resourceId = $eventGridEvent.data.resourceUri
if (-not $resourceId) { $resourceId = $eventGridEvent.subject }

Write-Host "Event: $($eventGridEvent.eventType) | operation: $operation | resource: $resourceId"

# Only act on virtual machine resource IDs.
$vmIdPattern = '(?i)^/subscriptions/(?<sub>[^/]+)/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.Compute/virtualMachines/(?<vm>[^/]+)$'
if ($resourceId -notmatch $vmIdPattern) {
    Write-Host "Resource is not a virtual machine. Ignoring."
    return
}

$spokeSubscriptionId = $Matches['sub']
$vmName              = $Matches['vm'].ToLower()
$recordName          = $vmName               # produces <vm>.az.fx

$isDelete = $operation -match '(?i)/delete$'

# ---- DELETE path ------------------------------------------------------------
if ($isDelete) {
    Set-AzContext -SubscriptionId $zoneSubscriptionId | Out-Null
    $existing = Get-AzPrivateDnsRecordSet -ResourceGroupName $zoneResourceGroup -ZoneName $zoneName `
        -Name $recordName -RecordType A -ErrorAction SilentlyContinue

    if (-not $existing) {
        Write-Host "No A record '$recordName' in $zoneName. Nothing to delete."
        return
    }
    if ($existing.Metadata['managedBy'] -ne $managedByValue) {
        Write-Host "A record '$recordName' is not managed by '$managedByValue'. Leaving it untouched."
        return
    }

    Remove-AzPrivateDnsRecordSet -RecordSet $existing -Confirm:$false
    Write-Host "Deleted A record '$recordName' from $zoneName."
    return
}

# ---- WRITE / CREATE path: read the VM's primary private IP ------------------
Set-AzContext -SubscriptionId $spokeSubscriptionId | Out-Null
$vm = Get-AzVM -ResourceId $resourceId -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "VM '$resourceId' not found (likely already deleted). Skipping."
    return
}

$nicRef = $vm.NetworkProfile.NetworkInterfaces | Where-Object { $_.Primary } | Select-Object -First 1
if (-not $nicRef) { $nicRef = $vm.NetworkProfile.NetworkInterfaces | Select-Object -First 1 }
if (-not $nicRef) {
    Write-Host "VM '$vmName' has no network interface. Skipping."
    return
}

$nic      = Get-AzNetworkInterface -ResourceId $nicRef.Id
$ipConfig = $nic.IpConfigurations | Where-Object { $_.Primary } | Select-Object -First 1
if (-not $ipConfig) { $ipConfig = $nic.IpConfigurations | Select-Object -First 1 }
$privateIp = $ipConfig.PrivateIpAddress

if (-not $privateIp) {
    # Dynamic IP not yet assigned (e.g. VM not started). Reconciliation will fix it.
    Write-Host "No private IP yet for '$vmName'. Deferring to reconciliation job."
    return
}

# ---- Upsert the A record in the central zone --------------------------------
Set-AzContext -SubscriptionId $zoneSubscriptionId | Out-Null
$metadata = @{ managedBy = $managedByValue; sourceVmId = $resourceId }
$record   = New-AzPrivateDnsRecordConfig -IPv4Address $privateIp

$existing = Get-AzPrivateDnsRecordSet -ResourceGroupName $zoneResourceGroup -ZoneName $zoneName `
    -Name $recordName -RecordType A -ErrorAction SilentlyContinue

if ($existing) {
    $existing.Records  = @($record)
    $existing.Ttl      = $ttl
    $existing.Metadata = $metadata
    Set-AzPrivateDnsRecordSet -RecordSet $existing | Out-Null
    Write-Host "Updated A record '$recordName' -> $privateIp in $zoneName."
} else {
    New-AzPrivateDnsRecordSet -ResourceGroupName $zoneResourceGroup -ZoneName $zoneName `
        -Name $recordName -RecordType A -Ttl $ttl -PrivateDnsRecords $record -Metadata $metadata | Out-Null
    Write-Host "Created A record '$recordName' -> $privateIp in $zoneName."
}
