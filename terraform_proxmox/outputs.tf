# Rescue outputs: when talos_machine_configuration_apply fails with
# "no route to host :50000" on a freshly booted VM, extract via
#   terraform output -json talos_{controlplane,worker}_machineconfig | jq -r > /tmp/mc.yaml
# and apply manually: talosctl apply-config --insecure -e <ip> -n <ip> -f /tmp/mc.yaml
output "talos_controlplane_machineconfig" {
  description = "Rendered controlplane machineconfig (before per-node patch) — rescue for manual talosctl apply-config"
  value       = module.talos.controlplane_machine_configuration
  sensitive   = true
}

output "talos_worker_machineconfig" {
  description = "Rendered worker machineconfig (before per-node patch) — rescue for manual talosctl apply-config"
  value       = module.talos.worker_machine_configuration
  sensitive   = true
}

output "talos_client_configuration" {
  description = "Talos client config (for talosctl)"
  value       = module.talos.client_configuration
  sensitive   = true
}
