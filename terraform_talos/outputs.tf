output "client_configuration" {
  description = "Talos client configuration (for talosctl)"
  value       = module.talos.client_configuration
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint derived from VIP"
  value       = module.talos.cluster_endpoint
}

output "install_image" {
  description = "Effective Talos installer URL — use for `talosctl upgrade --image <URL>`"
  value       = module.talos.install_image
}

output "schematic_id" {
  description = "Talos image factory schematic ID — cross-check ISO at factory.talos.dev/image/<id>/<release>/metal-amd64.iso"
  value       = module.talos.schematic_id
}

output "controlplane_machine_configuration" {
  description = "Rendered controlplane machineconfig (before per-node patch) — rescue for manual `talosctl apply-config --insecure`"
  value       = module.talos.controlplane_machine_configuration
  sensitive   = true
}

output "worker_machine_configuration" {
  description = "Rendered worker machineconfig (before per-node patch) — rescue for manual `talosctl apply-config --insecure`"
  value       = module.talos.worker_machine_configuration
  sensitive   = true
}
