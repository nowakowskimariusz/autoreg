terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# This module is applied with an azurerm provider already pointed at the spoke
# subscription (var.subscription_id). The platform pipeline configures that
# provider per project when onboarding a new subscription.
#
# NOTE on resolution links: the resolution-only vNet link to az.fx
# (registration_enabled = false) is intentionally NOT created here, because the
# link resource lives under the zone in the connectivity subscription and needs
# a provider pointed there. Keep that link in your existing project-onboarding
# module (the one that already peers the spoke to the hub) - just ensure it sets
# registration_enabled = false. See the README, "Resolution links" section.

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Event Grid system topic on the spoke SUBSCRIPTION (emits ARM events).
# topic_type "Microsoft.Resources.Subscriptions" requires location = "Global".
# ---------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic" "subscription" {
  name                   = "egst-vm-dns-registration"
  resource_group_name    = azurerm_resource_group.this.name
  location               = "Global"
  source_arm_resource_id = "/subscriptions/${var.subscription_id}"
  topic_type             = "Microsoft.Resources.Subscriptions"
  tags                   = var.tags
}

# ---------------------------------------------------------------------------
# Event subscription: only VM create/update + delete, delivered to the central
# registrar function in the platform subscription.
# ---------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic_event_subscription" "vm" {
  name                = "vm-dns-registration"
  system_topic        = azurerm_eventgrid_system_topic.subscription.name
  resource_group_name = azurerm_resource_group.this.name

  included_event_types = [
    "Microsoft.Resources.ResourceWriteSuccess",
    "Microsoft.Resources.ResourceDeleteSuccess",
  ]

  # Narrow to virtual machine PUT/DELETE operations only. This keeps the
  # function from being invoked for every unrelated control-plane operation.
  advanced_filter {
    string_in {
      key = "data.operationName"
      values = [
        "Microsoft.Compute/virtualMachines/write",
        "Microsoft.Compute/virtualMachines/delete",
      ]
    }
  }

  azure_function_endpoint {
    function_id                       = var.registrar_function_id
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440 # minutes (24h)
  }

  # Optional dead-letter destination for events that exhaust retries.
  dynamic "storage_blob_dead_letter_destination" {
    for_each = var.dead_letter_storage_container_id == "" ? [] : [1]
    content {
      storage_account_id          = regex("^(.*)/blobServices/.*$", var.dead_letter_storage_container_id)[0]
      storage_blob_container_name = regex("/containers/([^/]+)$", var.dead_letter_storage_container_id)[0]
    }
  }
}
