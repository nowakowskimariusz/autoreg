locals {
  # Resource ID of the zone's resource group (works whether or not the zone is
  # in the same subscription as the Function App).
  zone_rg_scope = "/subscriptions/${var.zone_subscription_id}/resourceGroups/${var.zone_resource_group}"

  mg_scope = "/providers/Microsoft.Management/managementGroups/${var.management_group_id}"

  # Storage account names: lowercase, <= 24 chars, globally unique.
  storage_name = substr(replace("st${var.name_prefix}${random_string.suffix.result}", "-", ""), 0, 24)
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Storage + monitoring for the Function App
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "this" {
  name                            = local.storage_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Function App (PowerShell, Windows)
# ---------------------------------------------------------------------------
resource "azurerm_service_plan" "this" {
  name                = "asp-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  os_type             = "Windows"
  sku_name            = var.function_plan_sku
  tags                = var.tags
}

resource "azurerm_windows_function_app" "this" {
  name                = "func-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  service_plan_id     = azurerm_service_plan.this.id

  storage_account_name       = azurerm_storage_account.this.name
  storage_account_access_key = azurerm_storage_account.this.primary_access_key

  builtin_logging_enabled = true
  https_only              = true

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
    application_insights_key               = azurerm_application_insights.this.instrumentation_key
    ftps_state                             = "Disabled"

    application_stack {
      powershell_core_version = "7.4"
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME = "powershell"
    # Code is deployed by the pipeline (see README). Remove if you use zip_deploy_file.
    WEBSITE_RUN_FROM_PACKAGE = "1"

    # --- Registrar configuration consumed by the function code ---
    ZONE_SUBSCRIPTION_ID = var.zone_subscription_id
    ZONE_RESOURCE_GROUP  = var.zone_resource_group
    ZONE_NAME            = var.zone_name
    RECORD_TTL           = tostring(var.record_ttl)
    MANAGED_BY_TAG       = var.managed_by_tag
    RECONCILE_SCHEDULE   = var.reconcile_schedule
  }

  tags = var.tags

  lifecycle {
    # The deployment pipeline manages the code package; don't let Terraform fight it.
    ignore_changes = [app_settings["WEBSITE_RUN_FROM_PACKAGE"]]
  }
}

# ---------------------------------------------------------------------------
# RBAC for the registrar's managed identity
# ---------------------------------------------------------------------------

# 1) Write A records in the central zone's resource group.
#    If the zone is in a DIFFERENT subscription than the Function App, add:
#        provider = azurerm.zone
#    to this resource (and ensure the deploy principal has access there).
resource "azurerm_role_assignment" "dns_zone_contributor" {
  scope                = local.zone_rg_scope
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_windows_function_app.this.identity[0].principal_id
}

# 2) Read VMs / NICs across every spoke subscription under the management group.
resource "azurerm_role_assignment" "reader_mg" {
  scope                = local.mg_scope
  role_definition_name = "Reader"
  principal_id         = azurerm_windows_function_app.this.identity[0].principal_id
}
