terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# Applied with an azurerm provider already pointed at the spoke subscription.
#
# Reuses an EXISTING resource group (rg-network by default) - workload
# subscriptions only ever have rg-network / rg-secrets / rg-terraform, so we do
# not create a dedicated RG here.
#
# The shared system topic is intentionally generic: one Event Grid system topic
# per subscription carries ALL subscription-level ARM events, and any number of
# event subscriptions (each with its own filter -> its own handler function) hang
# off it. To grow the solution later, add entries to var.event_subscriptions -
# no change to the topic itself.

# Shared subscription-level system topic (ARM events for the whole subscription).
resource "azurerm_eventgrid_system_topic" "subscription" {
  name                   = var.system_topic_name
  resource_group_name    = var.resource_group_name
  location               = "Global"
  source_arm_resource_id = "/subscriptions/${var.subscription_id}"
  topic_type             = "Microsoft.Resources.Subscriptions"
  tags                   = var.tags
}

# One event subscription per entry in var.event_subscriptions.
resource "azurerm_eventgrid_system_topic_event_subscription" "this" {
  for_each = var.event_subscriptions

  name                = each.key
  system_topic        = azurerm_eventgrid_system_topic.subscription.name
  resource_group_name = var.resource_group_name

  included_event_types = each.value.included_event_types

  advanced_filter {
    string_in {
      key    = "data.operationName"
      values = each.value.operation_names
    }
  }

  azure_function_endpoint {
    function_id                       = each.value.function_id
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440 # minutes (24h)
  }

  dynamic "storage_blob_dead_letter_destination" {
    for_each = var.dead_letter_storage_container_id == "" ? [] : [1]
    content {
      storage_account_id          = regex("^(.*)/blobServices/.*$", var.dead_letter_storage_container_id)[0]
      storage_blob_container_name = regex("/containers/([^/]+)$", var.dead_letter_storage_container_id)[0]
    }
  }
}
