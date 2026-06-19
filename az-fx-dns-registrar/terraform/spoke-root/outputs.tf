output "system_topic_id" {
  value       = module.spoke.system_topic_id
  description = "Shared Event Grid system topic created in the spoke."
}

output "event_subscription_ids" {
  value       = module.spoke.event_subscription_ids
  description = "Event subscription IDs keyed by name."
}
