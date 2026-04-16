variable "endpoint" {
  description = "Hostname or IP of Proxmox server"
  type        = string
}

variable "proxmox_api_token" {
  description = "Полный API-токен для PVE в формате `user@realm!name=UUID`. Читается из Vault: home/homelab/terraform/proxmox-api-token field=api_token. Если задан — приоритет над username/password."
  type        = string
  sensitive   = true
  default     = null
}

variable "proxmox_username" {
  description = "Proxmox API username (bootstrap, когда токена ещё нет)."
  type        = string
  default     = null
}

variable "main_password" {
  description = "Proxmox API password (bootstrap, когда токена ещё нет)."
  type        = string
  sensitive   = true
  default     = null
}

variable "pc_public_key" {
  description = "Public key for SSH access"
  type        = string
  sensitive   = true
}

variable "vm_password" {
  description = "Password for the VM"
  type        = string
  default     = null
}