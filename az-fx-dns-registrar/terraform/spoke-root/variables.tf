variable "subscription_id" {
  type        = string
  description = "Spoke (project) subscription ID being onboarded."
}

variable "location" {
  type        = string
  default     = "westeurope"
  description = "Region for the system-topic resource group."
}

variable "registrar_function_id" {
  type        = string
  description = "Resource ID of the central RegisterVmDns function."
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
