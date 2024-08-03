variable "home_pc_public_key" {
  default = "ssh-ed25519 AAAA"
}

variable "endpoint" {
  default = "https://10.11.12.19:8006/"
}

variable "vm_password" {
  default = ""
}

variable "proxmox_username" {
  default = "root@pam"
}

variable "main_password" {
  default = ""
}
