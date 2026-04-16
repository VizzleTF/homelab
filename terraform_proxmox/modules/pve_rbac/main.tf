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

resource "proxmox_virtual_environment_user" "exporter" {
  user_id = var.exporter_user_id
  comment = "prometheus-pve-exporter (managed by terraform)"
  enabled = true
}

resource "proxmox_virtual_environment_user_token" "exporter" {
  user_id               = proxmox_virtual_environment_user.exporter.user_id
  token_name            = var.exporter_token_name
  comment               = "prometheus-pve-exporter (managed by terraform)"
  privileges_separation = true
}

# С privsep=true ACL привязывается к токену, а не к юзеру —
# иначе токен остаётся без привилегий, сколько бы ни было ACL на юзере.
resource "proxmox_virtual_environment_acl" "exporter_auditor" {
  token_id  = proxmox_virtual_environment_user_token.exporter.id
  role_id   = "PVEAuditor"
  path      = "/"
  propagate = true
}

locals {
  # bpg/proxmox отдаёт value в формате "user@realm!name=UUID".
  # prometheus-pve-exporter ждёт в token_value только сам UUID.
  exporter_token_uuid = regex("=([0-9a-f-]+)$", proxmox_virtual_environment_user_token.exporter.value)[0]
}

resource "vault_kv_secret_v2" "exporter" {
  mount = var.vault_mount
  name  = var.vault_exporter_path
  data_json = jsonencode({
    user        = proxmox_virtual_environment_user.exporter.user_id
    token_name  = proxmox_virtual_environment_user_token.exporter.token_name
    token_value = local.exporter_token_uuid
  })
}
