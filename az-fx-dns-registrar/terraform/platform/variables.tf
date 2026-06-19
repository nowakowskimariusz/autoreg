variable "platform_subscription_id" {
  type        = string
  description = "Subscription that hosts the Function App + its networking (platform / connectivity subscription)."
}

variable "zone_subscription_id" {
  type        = string
  description = "Subscription that hosts the az.fx private DNS zone. Usually the same as platform_subscription_id."
}

variable "zone_resource_group" {
  type        = string
  description = "Resource group that hosts the az.fx private DNS zone."
}

variable "zone_name" {
  type        = string
  description = "Private DNS zone name."
  default     = "az.fx"
}

variable "location" {
  type        = string
  description = "Azure region for the registrar resources (must match the VNet region)."
  default     = "westeurope"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create for the registrar (in the platform subscription)."
  default     = "rg-az-fx-dns-registrar"
}

variable "name_prefix" {
  type        = string
  description = "Short prefix for resource names (lowercase, alphanumeric, <= 12 chars)."
  default     = "fxdnsreg"
}

variable "management_group_id" {
  type        = string
  description = "Management group ID covering all spoke subscriptions. The registrar identity gets Reader here."
}

variable "record_ttl" {
  type        = number
  description = "TTL (seconds) for the A records the registrar creates."
  default     = 3600
}

variable "managed_by_tag" {
  type        = string
  description = "Metadata value stamped on records the registrar manages. Reconciliation/delete only touch records with this value."
  default     = "az-fx-registrar"
}

variable "reconcile_schedule" {
  type        = string
  description = "NCRONTAB schedule for the reconciliation timer (6 fields). Default: top of every hour."
  default     = "0 0 */1 * * *"
}

# --- Flex Consumption sizing ------------------------------------------------
variable "instance_memory_in_mb" {
  type        = number
  description = "Flex Consumption per-instance memory: 512, 2048 or 4096."
  default     = 2048
}

variable "maximum_instance_count" {
  type        = number
  description = "Flex Consumption maximum instance count (1-1000)."
  default     = 40
}

variable "python_version" {
  type        = string
  description = "Python runtime version for the Flex Consumption app."
  default     = "3.12"
}

# --- Networking -------------------------------------------------------------
variable "vnet_address_space" {
  type        = list(string)
  description = "Address space for the registrar VNet."
  default     = ["10.80.0.0/24"]
}

variable "integration_subnet_prefix" {
  type        = string
  description = "Prefix for the Flex VNet-integration subnet (delegated to Microsoft.App/environments, /27 minimum). No underscores in the subnet name."
  default     = "10.80.0.0/27"
}

variable "private_endpoint_subnet_prefix" {
  type        = string
  description = "Prefix for the private-endpoint subnet (blob/queue/table PEs)."
  default     = "10.80.0.32/27"
}

# Existing ALZ storage privatelink DNS zones (resource IDs). These typically
# already exist centrally in the connectivity subscription.
variable "privatelink_blob_dns_zone_id" {
  type        = string
  description = "Resource ID of the privatelink.blob.core.windows.net private DNS zone."
}

variable "privatelink_queue_dns_zone_id" {
  type        = string
  description = "Resource ID of the privatelink.queue.core.windows.net private DNS zone."
}

variable "privatelink_table_dns_zone_id" {
  type        = string
  description = "Resource ID of the privatelink.table.core.windows.net private DNS zone."
}

variable "link_privatelink_zones_to_vnet" {
  type        = bool
  description = "Create vNet links from the storage privatelink zones to the registrar VNet so the function resolves the storage private endpoints. Set false if your platform already links these zones to this VNet."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}
