locals {
  managed_nodes = {
    for name, n in var.nodes : name => n if n.talos_managed
  }
}

# Sentinel mirroring the bpg/proxmox VM identity per node. `var.vm_ids` comes
# from `module.vms.vm_ids` (a map of computed `vm.id` attributes). When a VM is
# destroyed/recreated, `vm_ids[<node>]` is "(known after apply)" at plan time;
# that unknown propagates here → forces replacement of this terraform_data →
# cascades to talos_machine_configuration_apply via replace_triggered_by below.
#
# Why this trampoline exists: `replace_triggered_by` only accepts resource
# references inside the same module, and Terraform refuses to pass resource
# references through `variable`s. The terraform_data sentinel re-anchors the
# cross-module dependency as an in-module resource reference.
resource "terraform_data" "vm_identity" {
  for_each = local.managed_nodes

  # `triggers_replace` (not `input`) so any change to vm_ids[<node>] forces a
  # REPLACE of this resource — `replace_triggered_by` on talos_machine_configuration_apply
  # then fires unambiguously. With `input` the resource would in-place update,
  # whose cascade semantics are version-dependent.
  triggers_replace = [var.vm_ids[each.key]]
}

# Buffer between VM creation and talos_machine_configuration_apply so the
# provider doesn't hit a freshly-booted VM before Talos maintenance mode has
# opened :50000. Empirically Talos answers in ~20–45s; 75s gives slack.
# `triggers.vm_id` ensures the sleep re-fires when the underlying VM is
# recreated (without it, only `node` IP change would re-trigger — but IPs stay
# stable across replace).
resource "time_sleep" "wait_maintenance" {
  for_each = local.managed_nodes

  create_duration = "75s"

  triggers = {
    node  = each.value.address
    vm_id = var.vm_ids[each.key]
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

  lifecycle {
    # Cascade VM destroy/recreate → re-apply machineconfig. Without this a fresh
    # VM with the same IP would never receive the config and stay stuck in
    # maintenance mode (input attributes here don't change on VM recreate).
    replace_triggered_by = [terraform_data.vm_identity[each.key]]
  }
}
