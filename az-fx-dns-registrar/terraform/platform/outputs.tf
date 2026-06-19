output "function_app_id" {
  description = "Resource ID of the registrar Function App."
  value       = azurerm_function_app_flex_consumption.this.id
}

output "function_app_name" {
  description = "Name of the registrar Function App (used for code deployment)."
  value       = azurerm_function_app_flex_consumption.this.name
}

output "registrar_function_id" {
  description = "Resource ID of the RegisterVmDns function. Pass this to every spoke event subscription (var.registrar_function_id)."
  value       = "${azurerm_function_app_flex_consumption.this.id}/functions/RegisterVmDns"
}

output "function_identity_client_id" {
  description = "Client ID of the Function App's user-assigned managed identity."
  value       = azurerm_user_assigned_identity.this.client_id
}

output "function_identity_principal_id" {
  description = "Object ID of the Function App's user-assigned managed identity."
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "storage_account_name" {
  description = "Name of the (private) storage account backing the Function App."
  value       = azurerm_storage_account.this.name
}

output "vnet_id" {
  description = "Resource ID of the registrar VNet (integration + private-endpoint subnets)."
  value       = azurerm_virtual_network.this.id
}

output "resource_group_name" {
  description = "Resource group that holds the registrar."
  value       = azurerm_resource_group.this.name
}
