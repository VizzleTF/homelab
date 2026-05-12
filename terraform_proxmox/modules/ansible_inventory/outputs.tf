output "inventory_path" {
  description = "Путь к сгенерированному ansible inventory."
  value       = local_file.inventory.filename
}

output "group_vars_path" {
  description = "Путь к сгенерированному group_vars/pve.yaml."
  value       = local_file.group_vars_pve.filename
}

output "pve_exporter_values_path" {
  description = "Путь к сгенерированному argocd/infra/pve-exporter/values.yaml."
  value       = local_file.pve_exporter_values.filename
}
