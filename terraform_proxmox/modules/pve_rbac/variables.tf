variable "exporter_user_id" {
  description = "PVE user ID для prometheus-pve-exporter. Realm `pve` — не требует OS-пользователя."
  type        = string
  default     = "exporter@pve"
}

variable "exporter_token_name" {
  description = "Имя API-токена для exporter. Итоговый идентификатор: `<user_id>!<token_name>`."
  type        = string
  default     = "metrics"
}

variable "vault_mount" {
  description = "Имя KV v2 mount в Vault (см. ClusterSecretStore vault-backend-cluster)."
  type        = string
  default     = "home"
}

variable "vault_exporter_path" {
  description = "Путь в Vault KV v2 для секретов pve-exporter (без префикса data/)."
  type        = string
  default     = "homelab/k8s/victoria-metrics/pve-exporter"
}
