# Thin root wrapper so the spoke module can be applied standalone (e.g. from the
# onboarding pipeline) with a provider pointed at the target spoke subscription.
#
# This wires the VM DNS registration event subscription. To add future
# functionality, add more entries to event_subscriptions (each points a filter
# at its own handler function on the same shared system topic).

module "spoke" {
  source = "../spoke"

  subscription_id                  = var.subscription_id
  resource_group_name              = var.resource_group_name
  dead_letter_storage_container_id = var.dead_letter_storage_container_id

  event_subscriptions = {
    vm-dns-registration = {
      operation_names = [
        "Microsoft.Compute/virtualMachines/write",
        "Microsoft.Compute/virtualMachines/delete",
      ]
      function_id = var.registrar_function_id
    }

    # Example of future growth - add another handler with a different filter:
    # tag-sync = {
    #   operation_names = ["Microsoft.Resources/tags/write"]
    #   function_id     = "<other-function-id>"
    # }
  }

  tags = var.project_name == "" ? {} : { project = var.project_name }
}
