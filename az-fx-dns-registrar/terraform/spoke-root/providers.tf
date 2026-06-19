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
  #   storage_account_name = "stfrontextfstate"
  #   container_name       = "tfstate"
  #   key                  = "az-fx-dns-registrar/spoke-<project>.tfstate"
  # }
}

# Provider is pointed at the spoke subscription being onboarded.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
