variable "pve_hosts_config" {
  description = "Parsed content of configs/pve_hosts.yaml (hosts/trusted_cidrs/firewall_manager_host)"
  type = object({
    hosts                 = map(string)
    trusted_cidrs         = list(string)
    firewall_manager_host = string
  })
}

variable "inventory_dir" {
  description = "Куда писать inventory/group_vars (относительно path.root)."
  type        = string
  default     = "../ansible/inventory"
}

variable "pve_exporter_values_path" {
  description = "Путь к argocd/infra/pve-exporter/values.yaml в репозитории."
  type        = string
  default     = "../argocd/infra/pve-exporter/values.yaml"
}
