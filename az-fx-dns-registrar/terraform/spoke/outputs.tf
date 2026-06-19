output "system_topic_id" {
  description = "Resource ID of the shared Event Grid system topic in the spoke subscription."
  value       = azurerm_eventgrid_system_topic.subscription.id
}

output "event_subscription_ids" {
  description = "Resource IDs of the event subscriptions, keyed by name."
  value       = { for k, v in azurerm_eventgrid_system_topic_event_subscription.this : k => v.id }
}
