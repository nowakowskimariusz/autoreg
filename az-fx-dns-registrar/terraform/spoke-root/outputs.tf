output "system_topic_id" {
  value       = module.spoke.system_topic_id
  description = "Event Grid system topic created in the spoke."
}

output "event_subscription_id" {
  value       = module.spoke.event_subscription_id
  description = "VM event subscription created in the spoke."
}
