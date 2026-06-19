# Thin root wrapper so the spoke module can be applied standalone (e.g. from the
# onboarding pipeline) with a provider pointed at the target spoke subscription.

module "spoke" {
  source = "../spoke"

  subscription_id                  = var.subscription_id
  location                         = var.location
  registrar_function_id            = var.registrar_function_id
  dead_letter_storage_container_id = var.dead_letter_storage_container_id

  tags = var.project_name == "" ? {} : { project = var.project_name }
}
