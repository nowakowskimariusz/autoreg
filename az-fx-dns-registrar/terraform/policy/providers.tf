terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate-platform"
  #   storage_account_name = "stcontosotfstate"
  #   container_name       = "tfstate"
  #   key                  = "az-fx-dns-registrar/policy.tfstate"
  # }
}

provider "azurerm" {
  features {}
  subscription_id = var.platform_subscription_id
}
