locals {
  bootstrap_node_ip = try(
    [for name, n in var.nodes : n.address if n.role == "controlplane" && n.talos_managed][0],
    null,
  )
}

# For an imported existing cluster this is a no-op marker:
#   terraform import 'module.talos.talos_machine_bootstrap.this' bootstrap
# Do NOT destroy or recreate — it would attempt to re-bootstrap etcd.
resource "talos_machine_bootstrap" "this" {
  count = local.bootstrap_node_ip == null ? 0 : 1

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.bootstrap_node_ip

  depends_on = [talos_machine_configuration_apply.this]

  lifecycle {
    prevent_destroy = true
  }
}
