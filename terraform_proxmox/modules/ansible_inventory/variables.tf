variable "pve_hosts_config" {
  description = "Parsed content of configs/pve_hosts.yaml (hosts/admin/trusted_cidrs/firewall_manager_host)"
  type = object({
    hosts = map(string)
    admin = object({
      user   = string
      groups = list(string)
    })
    trusted_cidrs         = list(string)
    firewall_manager_host = string
  })
}

variable "admin_ssh_pubkey" {
  description = "Публичный SSH-ключ, который Ansible установит для admin@pve (authorized_keys)."
  type        = string
  sensitive   = true
}

variable "inventory_dir" {
  description = "Куда писать inventory/group_vars (относительно path.root)."
  type        = string
  default     = "../ansible/inventory"
}

variable "pve_exporter_values_path" {
  description = "Путь к values/infrastructure/pve-exporter.yaml в private репозитории (home-proxmox-values)."
  type        = string
  default     = "../../home-proxmox-values/values/infrastructure/pve-exporter.yaml"
}
