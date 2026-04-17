locals {
  managed_nodes = {
    for name, n in var.nodes : name => n if n.talos_managed
  }
}

# Buffer between VM creation and talos_machine_configuration_apply so the
# provider doesn't hit a freshly-booted VM before Talos maintenance mode has
# opened :50000. Empirically Talos answers in ~20–45s; 75s gives slack.
# Only fires at first create per node — on VM destroy+recreate also target-destroy
# this resource so the sleep re-runs.
resource "time_sleep" "wait_maintenance" {
  for_each = local.managed_nodes

  create_duration = "75s"

  triggers = {
    node = each.value.address
  }
}

resource "talos_machine_configuration_apply" "this" {
  for_each = local.managed_nodes

  client_configuration = talos_machine_secrets.this.client_configuration
  machine_configuration_input = each.value.role == "controlplane" ? (
    data.talos_machine_configuration.controlplane.machine_configuration
    ) : (
    data.talos_machine_configuration.worker.machine_configuration
  )
  node = each.value.address
  # "auto" — Talos сам решает, нужен ли reboot (certSAN/extraHostEntries — без reboot,
  # endpoint/install image — с reboot). Было "reboot" (всегда перезагружалось) — избыточно.
  apply_mode = "auto"

  config_patches = [
    local.node_patch[each.key],
  ]

  on_destroy = {
    reset    = true
    graceful = true
    reboot   = true
  }

  timeouts = {
    create = "15m"
    update = "10m"
  }

  depends_on = [time_sleep.wait_maintenance]
}
