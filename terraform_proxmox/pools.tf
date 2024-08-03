resource "proxmox_virtual_environment_pool" "k8s_pool" {
  comment = "Managed by Terraform"
  pool_id = "k8s-pool"
}
