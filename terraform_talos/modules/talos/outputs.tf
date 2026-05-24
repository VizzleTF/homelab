output "client_configuration" {
  description = "Talos client configuration (for talosctl)"
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}

output "controlplane_machine_configuration" {
  description = "Rendered controlplane machineconfig (before per-node patch) — rescue for manual `talosctl apply-config --insecure`"
  value       = data.talos_machine_configuration.controlplane.machine_configuration
  sensitive   = true
}

output "worker_machine_configuration" {
  description = "Rendered worker machineconfig (before per-node patch) — rescue for manual `talosctl apply-config --insecure`"
  value       = data.talos_machine_configuration.worker.machine_configuration
  sensitive   = true
}

output "install_image" {
  description = "Effective Talos installer URL — use for `talosctl upgrade --image <URL>` (config apply does NOT trigger OS upgrade)"
  value       = local.effective_install_image
}

output "schematic_id" {
  description = "Talos image factory schematic ID — boot media at factory.talos.dev/image/<id>/<release>/metal-amd64.iso"
  value       = talos_image_factory_schematic.this.id
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint derived from VIP"
  value       = local.cluster_endpoint
}
