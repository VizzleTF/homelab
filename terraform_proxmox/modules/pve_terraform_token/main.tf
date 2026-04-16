terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
    vault = {
      source = "hashicorp/vault"
    }
  }
}

resource "proxmox_virtual_environment_user" "tf" {
  user_id = var.user_id
  comment = "terraform provider (managed by terraform)"
  enabled = true
}

resource "proxmox_virtual_environment_user_token" "tf" {
  user_id = proxmox_virtual_environment_user.tf.user_id
  token_name = var.token_name
  comment = "terraform provider (managed by terraform)"
  # privsep=false: токен наследует Administrator у юзера. См. reference_terraform_proxmox_modules
  # про баг bpg с `token:` префиксом в /etc/pve/user.cfg.
  privileges_separation = false
}

resource "proxmox_virtual_environment_acl" "tf_admin" {
  user_id   = proxmox_virtual_environment_user.tf.user_id
  role_id   = "Administrator"
  path      = "/"
  propagate = true
}

resource "vault_kv_secret_v2" "tf" {
  mount = var.vault_mount
  name  = var.vault_path
  data_json = jsonencode({
    # Полный формат, который ожидает bpg/proxmox в api_token.
    api_token = proxmox_virtual_environment_user_token.tf.value
    # Компоненты для удобства (если понадобятся отдельно).
    user       = proxmox_virtual_environment_user.tf.user_id
    token_name = proxmox_virtual_environment_user_token.tf.token_name
  })
}
