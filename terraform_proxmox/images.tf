
locals {
  nodes = toset(["home", "pve3", "pve4", "pve5"])
}

resource "proxmox_virtual_environment_download_file" "oracle_cloud_image" {
  for_each = local.nodes

  content_type = "iso"
  datastore_id = "local"
  node_name    = each.value
  url          = "https://yum.oracle.com/templates/OracleLinux/OL9/u4/x86_64/OL9U4_x86_64-kvm-b234.qcow2"
  file_name    = "oracle94.img"
}