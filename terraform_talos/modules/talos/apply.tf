locals {
  managed_cp = {
    for name, n in var.nodes : name => n if n.role == "controlplane"
  }
  managed_worker = {
    for name, n in var.nodes : name => n if n.role == "worker"
  }
}

# Control-plane machineconfig. Separate from the worker resource so it can carry
# prevent_destroy: on_destroy below RESETS + REBOOTS the node (wipes it).
# Disabling a CP node via configs/nodes.yaml `enabled: false` — or a stray
# `-replace` — would otherwise silently wipe a control-plane / etcd member.
# To deliberately replace a CP member, set prevent_destroy = false here first.
resource "talos_machine_configuration_apply" "controlplane" {
  for_each = local.managed_cp

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.value.address
  # auto — Talos decides reboot vs. in-place. No reboot for certSANs / hostEntries /
  # install.image. Reboot for cluster endpoint / kernel args / first install.
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

  lifecycle {
    prevent_destroy = true
  }
}

# Worker machineconfig. No prevent_destroy — workers are decommissioned by
# flipping `enabled: false` in configs/nodes.yaml (drain the node first).
resource "talos_machine_configuration_apply" "worker" {
  for_each = local.managed_worker

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.address
  apply_mode                  = "auto"

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
}
