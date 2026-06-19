terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Recommended: store state in the platform/connectivity subscription.
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate-platform"
  #   storage_account_name = "stcontosotfstate"
  #   container_name       = "tfstate"
  #   key                  = "az-fx-dns-registrar/platform.tfstate"
  # }
}

# Default provider = the platform / connectivity subscription that hosts both
# the Function App and (in the standard ALZ layout) the az.fx private DNS zone.
provider "azurerm" {
  features {}
  subscription_id = var.platform_subscription_id
}

# Optional alias used ONLY when the az.fx zone lives in a different subscription
# than the Function App. If so, set var.zone_subscription_id accordingly and
# wire this alias into the zone role assignment in main.tf (see comment there).
provider "azurerm" {
  alias = "zone"
  features {}
  subscription_id = var.zone_subscription_id
}
