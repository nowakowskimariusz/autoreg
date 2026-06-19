output "function_app_id" {
  description = "Resource ID of the registrar Function App."
  value       = azurerm_windows_function_app.this.id
}

output "function_app_name" {
  description = "Name of the registrar Function App (used for code deployment)."
  value       = azurerm_windows_function_app.this.name
}

output "registrar_function_id" {
  description = "Resource ID of the RegisterVmDns function. Pass this to every spoke event subscription (var.registrar_function_id)."
  value       = "${azurerm_windows_function_app.this.id}/functions/RegisterVmDns"
}

output "function_principal_id" {
  description = "Object ID of the Function App's managed identity."
  value       = azurerm_windows_function_app.this.identity[0].principal_id
}

output "resource_group_name" {
  description = "Resource group that holds the registrar."
  value       = azurerm_resource_group.this.name
}
