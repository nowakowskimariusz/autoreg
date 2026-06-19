locals {
  zone_rg_scope = "/subscriptions/${var.zone_subscription_id}/resourceGroups/${var.zone_resource_group}"
  mg_scope      = "/providers/Microsoft.Management/managementGroups/${var.management_group_id}"
  storage_name  = substr(replace("st${var.name_prefix}${random_string.suffix.result}", "-", ""), 0, 24)

  # Storage privatelink zones, keyed for iteration over private endpoints.
  privatelink_zones = {
    blob  = var.privatelink_blob_dns_zone_id
    queue = var.privatelink_queue_dns_zone_id
    table = var.privatelink_table_dns_zone_id
  }
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

# User-assigned identity for the Function App. Created first so all role
# assignments can be made BEFORE the app exists (avoids a dependency cycle and
# the storage chicken-and-egg at app-create time).
resource "azurerm_user_assigned_identity" "this" {
  name                = "id-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------
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
# Networking: VNet with an integration subnet (Flex) and a private-endpoint subnet
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

# Flex Consumption VNet integration subnet - delegated to Microsoft.App/environments.
resource "azurerm_subnet" "integration" {
  name                 = "snet-func-integration"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.integration_subnet_prefix]

  delegation {
    name = "flex-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "snet-private-endpoints"
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [var.private_endpoint_subnet_prefix]
  private_endpoint_network_policies = "Disabled"
}

# ---------------------------------------------------------------------------
# Storage account - private, identity-only (no shared keys, no public access)
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "this" {
  name                            = local.storage_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false # RBAC / identity auth only
  public_network_access_enabled   = false # reachable only via private endpoints
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = var.tags
}

# Deployment package container - created via the management plane (azapi) so it
# works even though the storage data plane has no public access.
resource "azapi_resource" "deployment_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = "deployment"
  parent_id = "${azurerm_storage_account.this.id}/blobServices/default"
  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

# Private endpoints for blob / queue / table (Flex does NOT need the file share).
resource "azurerm_private_endpoint" "storage" {
  for_each = local.privatelink_zones

  name                = "pe-${var.name_prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = each.key
    private_dns_zone_ids = [each.value]
  }
}

# Link the storage privatelink zones to the registrar VNet so the function
# resolves the private endpoints. Skip if your platform already links them.
resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  for_each = var.link_privatelink_zones_to_vnet ? local.privatelink_zones : {}

  name                  = "link-${var.name_prefix}-${each.key}"
  resource_group_name   = regex("/resourceGroups/([^/]+)/", each.value)[0]
  private_dns_zone_name = regex("/privateDnsZones/([^/]+)$", each.value)[0]
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}

# ---------------------------------------------------------------------------
# Function App (Python, Flex Consumption)
# ---------------------------------------------------------------------------
resource "azurerm_service_plan" "this" {
  name                = "asp-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  os_type             = "Linux"
  sku_name            = "FC1" # Flex Consumption
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                = "func-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  service_plan_id     = azurerm_service_plan.this.id

  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.this.primary_blob_endpoint}${azapi_resource.deployment_container.name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.this.id

  runtime_name    = "python"
  runtime_version = var.python_version

  instance_memory_in_mb  = var.instance_memory_in_mb
  maximum_instance_count = var.maximum_instance_count

  virtual_network_subnet_id = azurerm_subnet.integration.id
  https_only                = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
  }

  app_settings = {
    # Identity-based host storage (no connection string, no shared key).
    AzureWebJobsStorage__accountName = azurerm_storage_account.this.name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = azurerm_user_assigned_identity.this.client_id

    # Tell DefaultAzureCredential (in function_app.py) which identity to use.
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.this.client_id

    # Registrar configuration consumed by function_app.py
    ZONE_SUBSCRIPTION_ID = var.zone_subscription_id
    ZONE_RESOURCE_GROUP  = var.zone_resource_group
    ZONE_NAME            = var.zone_name
    RECORD_TTL           = tostring(var.record_ttl)
    MANAGED_BY_TAG       = var.managed_by_tag
    RECONCILE_SCHEDULE   = var.reconcile_schedule
  }

  depends_on = [
    azurerm_role_assignment.func_storage_blob_owner,
    azurerm_role_assignment.func_storage_queue,
    azurerm_role_assignment.func_storage_table,
    azurerm_private_endpoint.storage,
    azurerm_private_dns_zone_virtual_network_link.storage,
  ]
}

# ---------------------------------------------------------------------------
# RBAC for the registrar's managed identity
# ---------------------------------------------------------------------------

# Host storage + deployment container (data-plane roles; control-plane roles do
# NOT grant blob data access). Blob Data Owner is required because the host
# creates containers; it is also a superset of the deployment Contributor role.
resource "azurerm_role_assignment" "func_storage_blob_owner" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "func_storage_queue" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "func_storage_table" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# Write A records in the central zone's resource group.
# If the zone is in a DIFFERENT subscription, add: provider = azurerm.zone
resource "azurerm_role_assignment" "dns_zone_contributor" {
  scope                = local.zone_rg_scope
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# Read VMs / NICs across every spoke subscription under the management group.
resource "azurerm_role_assignment" "reader_mg" {
  scope                = local.mg_scope
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}
