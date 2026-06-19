# =============================================================================
# ReconcileDns - Timer triggered (safety net)
# -----------------------------------------------------------------------------
# Event delivery is best-effort. This job runs on a schedule, builds the desired
# state from Azure Resource Graph (every VM + its primary private IP across all
# subscriptions the managed identity can read) and reconciles it against the A
# records in the central zone:
#
#   * missing record           -> create
#   * IP changed               -> update
#   * record with no live VM    -> delete  (only records tagged managedBy=<value>)
#
# Records that are NOT tagged managedBy=<value> are never modified or removed.
# =============================================================================

param($Timer)

$ErrorActionPreference = 'Stop'

$zoneSubscriptionId = $env:ZONE_SUBSCRIPTION_ID
$zoneResourceGroup  = $env:ZONE_RESOURCE_GROUP
$zoneName           = $env:ZONE_NAME
$ttl                = [int]($env:RECORD_TTL)
$managedByValue     = if ($env:MANAGED_BY_TAG) { $env:MANAGED_BY_TAG } else { 'az-fx-registrar' }
if ($ttl -le 0) { $ttl = 3600 }

Write-Host "Reconciliation started $(Get-Date -Format o)"

# ---- 1) Desired state from Resource Graph -----------------------------------
$query = @'
resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend nicId = tostring(properties.networkProfile.networkInterfaces[0].id)
| join kind=inner (
    resources
    | where type =~ 'microsoft.network/networkinterfaces'
    | mv-expand ipconfig = properties.ipConfigurations
    | extend isPrimary = tobool(ipconfig.properties.primary)
    | where isPrimary == true
    | project nicId = id, privateIp = tostring(ipconfig.properties.privateIPAddress)
) on nicId
| where isnotempty(privateIp)
| project vmName = tolower(name), privateIp
'@

$desired = @{}
$skip = 0
do {
    $page = Search-AzGraph -Query $query -First 1000 -Skip $skip
    foreach ($r in $page) {
        # If two VMs share a name across subscriptions the naming convention is
        # broken; log it and keep the first to avoid flapping.
        if (-not $desired.ContainsKey($r.vmName)) {
            $desired[$r.vmName] = $r.privateIp
        } else {
            Write-Warning "Duplicate VM name '$($r.vmName)'. Keeping first IP $($desired[$r.vmName]), ignoring $($r.privateIp)."
        }
    }
    $skip += 1000
} while ($page.Count -eq 1000)

Write-Host "Desired A records (live VMs): $($desired.Count)"

# ---- 2) Current state from the zone -----------------------------------------
Set-AzContext -SubscriptionId $zoneSubscriptionId | Out-Null
$current = Get-AzPrivateDnsRecordSet -ResourceGroupName $zoneResourceGroup -ZoneName $zoneName -RecordType A
$currentByName = @{}
foreach ($rs in $current) { $currentByName[$rs.Name.ToLower()] = $rs }

$created = 0; $updated = 0; $deleted = 0

# ---- 3) Create / update -----------------------------------------------------
foreach ($name in $desired.Keys) {
    $ip = $desired[$name]
    $rs = $currentByName[$name]
    if ($rs) {
        $currentIp = if ($rs.Records.Count -gt 0) { $rs.Records[0].Ipv4Address } else { $null }
        if ($currentIp -ne $ip -or $rs.Metadata['managedBy'] -ne $managedByValue) {
            $rs.Records  = @(New-AzPrivateDnsRecordConfig -IPv4Address $ip)
            $rs.Ttl      = $ttl
            $rs.Metadata = @{ managedBy = $managedByValue }
            Set-AzPrivateDnsRecordSet -RecordSet $rs | Out-Null
            Write-Host "Updated $name -> $ip"
            $updated++
        }
    } else {
        New-AzPrivateDnsRecordSet -ResourceGroupName $zoneResourceGroup -ZoneName $zoneName `
            -Name $name -RecordType A -Ttl $ttl `
            -PrivateDnsRecords (New-AzPrivateDnsRecordConfig -IPv4Address $ip) `
            -Metadata @{ managedBy = $managedByValue } | Out-Null
        Write-Host "Created $name -> $ip"
        $created++
    }
}

# ---- 4) Delete stale, managed records with no backing VM --------------------
foreach ($rs in $current) {
    $name = $rs.Name.ToLower()
    if ($rs.Metadata -and $rs.Metadata['managedBy'] -eq $managedByValue -and -not $desired.ContainsKey($name)) {
        Remove-AzPrivateDnsRecordSet -RecordSet $rs -Confirm:$false
        Write-Host "Removed stale $name"
        $deleted++
    }
}

Write-Host "Reconciliation complete. created=$created updated=$updated deleted=$deleted"
