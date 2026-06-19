variable "platform_subscription_id" {
  type        = string
  description = "Subscription that hosts the Function App (platform / connectivity subscription)."
}

variable "zone_subscription_id" {
  type        = string
  description = "Subscription that hosts the az.fx private DNS zone. Usually the same as platform_subscription_id in a standard ALZ connectivity layout."
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
  description = "Azure region for the registrar resources."
  default     = "westeurope"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create for the registrar (in the platform subscription)."
  default     = "rg-az-fx-dns-registrar"
}

variable "name_prefix" {
  type        = string
  description = "Short prefix for resource names (lowercase, alphanumeric)."
  default     = "fxdnsreg"
}

variable "management_group_id" {
  type        = string
  description = "Management group ID covering all spoke subscriptions. The registrar identity gets Reader here so it can read VMs/NICs in every spoke."
}

variable "record_ttl" {
  type        = number
  description = "TTL (seconds) for the A records the registrar creates."
  default     = 3600
}

variable "managed_by_tag" {
  type        = string
  description = "Metadata value stamped on records the registrar manages. Reconciliation/delete only ever touch records carrying this value."
  default     = "az-fx-registrar"
}

variable "reconcile_schedule" {
  type        = string
  description = "NCRONTAB schedule for the reconciliation timer (6 fields). Default: top of every hour."
  default     = "0 0 */1 * * *"
}

variable "function_plan_sku" {
  type        = string
  description = "App Service plan SKU. Y1 = Consumption (cheapest). EP1 = Elastic Premium (recommended for production: no cold starts, faster Az module load)."
  default     = "Y1"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}
