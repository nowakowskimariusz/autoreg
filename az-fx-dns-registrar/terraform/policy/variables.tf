variable "platform_subscription_id" {
  type        = string
  description = "Subscription used to run this Terraform (platform/connectivity). The policy itself is defined and assigned at management-group scope."
}

variable "management_group_id" {
  type        = string
  description = "Management group ID where the policy is defined and assigned (must cover all spoke subscriptions)."
}

variable "registrar_function_id" {
  type        = string
  description = "Resource ID of the central RegisterVmDns function (output 'registrar_function_id' from the platform deployment)."
}

variable "spoke_resource_group_name" {
  type        = string
  description = "Resource group created in each spoke to hold the Event Grid system topic."
  default     = "rg-dns-registration"
}

variable "deployment_location" {
  type        = string
  description = "Region for the spoke resource group and the subscription deployment metadata."
  default     = "westeurope"
}

variable "assignment_location" {
  type        = string
  description = "Location for the policy assignment's managed identity (required for system-assigned identity)."
  default     = "westeurope"
}

variable "effect" {
  type        = string
  description = "Policy effect: DeployIfNotExists (enforce), AuditIfNotExists (report only), or Disabled."
  default     = "DeployIfNotExists"
}
