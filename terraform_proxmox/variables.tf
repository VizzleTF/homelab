variable "endpoint" {
  description = "Hostname or IP of Proxmox server"
  type        = string
}

variable "proxmox_username" {
  description = "User for Proxmox API"
  type        = string
}

variable "main_password" {
  description = "Password for Proxmox API"
  type        = string
  sensitive   = true
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