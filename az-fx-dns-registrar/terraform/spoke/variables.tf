variable "subscription_id" {
  type        = string
  description = "The spoke (project) subscription ID this wiring is being deployed into. Must match the subscription the azurerm provider is pointed at."
}

variable "location" {
  type        = string
  description = "Region for the system-topic resource group."
  default     = "westeurope"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group created in the spoke subscription to hold the Event Grid system topic."
  default     = "rg-dns-registration"
}

variable "registrar_function_id" {
  type        = string
  description = "Resource ID of the central RegisterVmDns function (output 'registrar_function_id' from the platform deployment)."
}

variable "dead_letter_storage_container_id" {
  type        = string
  description = "Optional. Resource ID of a storage blob container for dead-lettered events (recommended in production). Format: <storageAccountId>/blobServices/default/containers/<name>. Leave empty to disable."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to created resources."
  default     = {}
}
