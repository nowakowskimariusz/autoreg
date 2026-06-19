output "system_topic_id" {
  description = "Resource ID of the Event Grid system topic created in the spoke subscription."
  value       = azurerm_eventgrid_system_topic.subscription.id
}

output "event_subscription_id" {
  description = "Resource ID of the VM event subscription."
  value       = azurerm_eventgrid_system_topic_event_subscription.vm.id
}
