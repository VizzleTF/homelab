output "client_configuration" {
  description = "Talos client configuration (for talosctl)"
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}

# Rendered machineconfigs exposed for rescue: when `talos_machine_configuration_apply`
# fails with "no route to host :50000" on a freshly booted VM, extract via
#   terraform output -json talos_{role}_machineconfig | jq -r > /tmp/mc.yaml
# and apply manually: talosctl apply-config --insecure -e <ip> -n <ip> -f /tmp/mc.yaml
output "controlplane_machine_configuration" {
  description = "Rendered controlplane machineconfig (before per-node patch) — rescue for manual talosctl apply-config"
  value       = data.talos_machine_configuration.controlplane.machine_configuration
  sensitive   = true
}

output "worker_machine_configuration" {
  description = "Rendered worker machineconfig (before per-node patch) — rescue for manual talosctl apply-config"
  value       = data.talos_machine_configuration.worker.machine_configuration
  sensitive   = true
}

output "install_image" {
  description = "Effective Talos installer URL — use for `talosctl upgrade --image <URL>` (provider issue #140: config apply does NOT trigger OS upgrade)"
  value       = local.effective_install_image
}
