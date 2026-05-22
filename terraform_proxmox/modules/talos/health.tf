# Post-apply health gate. terraform plan/apply reads cluster health (etcd / apiserver
# / kubelet on every node) and fails loudly if anything is unhealthy. Without this
# a broken bootstrap surfaces only when someone runs `kubectl get nodes` later.
#
# Escape hatch: `skip_health_check = true` (see variables.tf) disables the check
# when debugging a known-broken cluster.

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = [for _, n in var.nodes : n.address]
  endpoints            = [for _, n in var.nodes : n.address if n.role == "controlplane"]
}

data "talos_cluster_health" "this" {
  count = var.skip_health_check ? 0 : 1

  client_configuration   = data.talos_client_configuration.this.client_configuration
  control_plane_nodes    = [for _, n in var.nodes : n.address if n.role == "controlplane"]
  worker_nodes           = [for _, n in var.nodes : n.address if n.role == "worker"]
  endpoints              = data.talos_client_configuration.this.endpoints
  skip_kubernetes_checks = false

  timeouts = {
    read = "10m"
  }

  depends_on = [
    talos_machine_bootstrap.this,
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
  ]
}
