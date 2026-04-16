variable "user_id" {
  description = "PVE user для terraform-провайдера. Realm `pve` — не требует OS-пользователя."
  type        = string
  default     = "terraform@pve"
}

variable "token_name" {
  description = "Имя API-токена. Полный id: `<user_id>!<token_name>`."
  type        = string
  default     = "tf"
}

variable "vault_mount" {
  description = "KV v2 mount в Vault."
  type        = string
  default     = "home"
}

variable "vault_path" {
  description = "Путь в Vault KV v2 (без префикса data/)."
  type        = string
  default     = "homelab/terraform/proxmox-api-token"
}
