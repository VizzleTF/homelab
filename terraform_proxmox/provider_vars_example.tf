variable "endpoint" {
  description = "Proxmox API endpoint"
  default     = "https://YOUR_PROXMOX_IP:8006/"
}

variable "vm_password" {
  description = "Password for the VMs"
  default     = "change_me"
}

variable "proxmox_username" {
  description = "Proxmox username"
  default     = "root@pam"
}

variable "main_password" {
  description = "Proxmox password"
  default     = "change_me"
} 
