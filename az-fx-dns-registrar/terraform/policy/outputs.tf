output "policy_definition_id" {
  description = "Resource ID of the custom policy definition."
  value       = azurerm_policy_definition.deploy_vm_dns_eventgrid.id
}

output "policy_assignment_id" {
  description = "Resource ID of the management-group policy assignment. Use this to create remediation tasks for existing subscriptions."
  value       = azurerm_management_group_policy_assignment.deploy_vm_dns_eventgrid.id
}

output "policy_assignment_principal_id" {
  description = "Object ID of the policy assignment's managed identity."
  value       = azurerm_management_group_policy_assignment.deploy_vm_dns_eventgrid.identity[0].principal_id
}
