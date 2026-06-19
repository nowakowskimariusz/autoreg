locals {
  mg_scope = "/providers/Microsoft.Management/managementGroups/${var.management_group_id}"
}

# ---------------------------------------------------------------------------
# Policy definition (custom, management-group scoped).
# Subscription-scope DeployIfNotExists: ensures every subscription under the MG
# has the Event Grid system topic + VM event subscription pointing at the
# central registrar function.
# ---------------------------------------------------------------------------
resource "azurerm_policy_definition" "deploy_vm_dns_eventgrid" {
  name                = "deploy-vm-dns-registration-eventgrid"
  display_name        = "Deploy VM DNS registration Event Grid wiring to subscriptions"
  description         = "Creates an Event Grid system topic and VM (write/delete) event subscription in each subscription, delivering events to the central az.fx DNS registrar function."
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = local.mg_scope
  metadata = jsonencode({
    category = "DNS"
    version  = "1.0.0"
  })

  policy_rule = file("${path.module}/files/policy_rule.json")
  parameters  = file("${path.module}/files/parameters.json")
}

# ---------------------------------------------------------------------------
# Assignment at management-group scope, with a system-assigned identity used to
# run the DeployIfNotExists remediation deployments.
# ---------------------------------------------------------------------------
resource "azurerm_management_group_policy_assignment" "deploy_vm_dns_eventgrid" {
  name                 = "deploy-vm-dns-egst"
  display_name         = "Deploy VM DNS registration Event Grid wiring"
  policy_definition_id = azurerm_policy_definition.deploy_vm_dns_eventgrid.id
  management_group_id  = local.mg_scope
  location             = var.assignment_location

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    effect              = { value = var.effect }
    registrarFunctionId = { value = var.registrar_function_id }
    resourceGroupName   = { value = var.spoke_resource_group_name }
    deploymentLocation  = { value = var.deployment_location }
  })
}

# ---------------------------------------------------------------------------
# The policy identity needs to create resource groups, system topics and event
# subscriptions in any spoke -> Contributor at MG scope. (Least-privilege
# alternative: a custom role limited to Microsoft.EventGrid/* plus RG create.)
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "policy_contributor" {
  scope                = local.mg_scope
  role_definition_name = "Contributor"
  principal_id         = azurerm_management_group_policy_assignment.deploy_vm_dns_eventgrid.identity[0].principal_id
}
