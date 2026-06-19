variable "subscription_id" {
  type        = string
  description = "The spoke (project) subscription ID. Must match the subscription the azurerm provider is pointed at."
}

variable "resource_group_name" {
  type        = string
  description = "EXISTING resource group in the spoke to hold the Event Grid system topic. Workload subscriptions already have rg-network / rg-secrets / rg-terraform - reuse one (default rg-network) instead of creating a new RG."
  default     = "rg-network"
}

variable "system_topic_name" {
  type        = string
  description = "Name of the shared subscription-level Event Grid system topic. One per subscription; reused by all event subscriptions (DNS registration today, more later)."
  default     = "egst-subscription-events"
}

variable "event_subscriptions" {
  type = map(object({
    operation_names = list(string)
    function_id     = string
    included_event_types = optional(list(string), [
      "Microsoft.Resources.ResourceWriteSuccess",
      "Microsoft.Resources.ResourceDeleteSuccess",
    ])
  }))
  description = <<-EOT
    Map of event subscriptions to attach to the shared system topic. Add an entry
    to grow the solution (new filter -> new function) without touching the topic.
    Example:
      {
        vm-dns-registration = {
          operation_names = [
            "Microsoft.Compute/virtualMachines/write",
            "Microsoft.Compute/virtualMachines/delete",
          ]
          function_id = "<registrar_function_id>"
        }
      }
  EOT
}

variable "dead_letter_storage_container_id" {
  type        = string
  description = "Optional. Storage blob container resource ID for dead-lettered events. Format: <storageAccountId>/blobServices/default/containers/<name>. Empty disables it."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to created resources."
  default     = {}
}
