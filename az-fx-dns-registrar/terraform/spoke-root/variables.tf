variable "subscription_id" {
  type        = string
  description = "Spoke (project) subscription ID being onboarded."
}

variable "registrar_function_id" {
  type        = string
  description = "Resource ID of the central RegisterVmDns function."
}

variable "resource_group_name" {
  type        = string
  default     = "rg-network"
  description = "Existing RG in the spoke to hold the system topic (reuses rg-network)."
}

variable "project_name" {
  type        = string
  default     = ""
  description = "Optional project tag value."
}

variable "dead_letter_storage_container_id" {
  type        = string
  default     = ""
  description = "Optional dead-letter blob container resource ID."
}
