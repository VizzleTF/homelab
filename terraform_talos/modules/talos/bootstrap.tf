locals {
  bootstrap_node_ip = try(
    sort([for _, n in var.nodes : n.address if n.role == "controlplane"])[0],
    null,
  )
}

# Bootstraps etcd on the first control-plane node. Idempotent — provider no-ops
# if the cluster is already bootstrapped.
# Do NOT taint or destroy — re-bootstrap on an existing etcd is destructive.
resource "talos_machine_bootstrap" "this" {
  count = local.bootstrap_node_ip == null ? 0 : 1

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.bootstrap_node_ip

  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
  ]

  lifecycle {
    prevent_destroy = true
  }
}
