locals {
  managed_cp = {
    for name, n in var.nodes : name => n if n.role == "controlplane"
  }
  managed_worker = {
    for name, n in var.nodes : name => n if n.role == "worker"
  }
}

# Separate from workers for prevent_destroy: on_destroy wipes the node, so
# `enabled: false` or a stray `-replace` would wipe an etcd member. To replace a
# CP member on purpose, set prevent_destroy = false first.
resource "talos_machine_configuration_apply" "controlplane" {
  for_each = local.managed_cp

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.value.address
  # Reboots for cluster endpoint, kernel args, first install; not for certSANs,
  # hostEntries, install.image.
  apply_mode = "auto"

  config_patches = [
    module.patches.node[each.key],
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

  lifecycle {
    prevent_destroy = true
  }
}

# Decommission: drain, then `enabled: false` in configs/nodes.yaml (wipes the node).
resource "talos_machine_configuration_apply" "worker" {
  for_each = local.managed_worker

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.address
  apply_mode                  = "auto"

  config_patches = [
    module.patches.node[each.key],
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
}
