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

  # ACL задан отдельным ресурсом proxmox_acl.exporter_auditor.
  # Провайдер bpg читает ACL обратно в nested-атрибут user'а — без ignore_changes
  # каждый plan хочет "обнулить" этот список, и экспортёр всё время "обновляется".
  lifecycle {
    ignore_changes = [acl]
  }
}

resource "proxmox_user_token" "exporter" {
  user_id    = proxmox_virtual_environment_user.exporter.user_id
  token_name = var.exporter_token_name
  comment    = "prometheus-pve-exporter (managed by terraform)"
  # privsep=false: токен наследует права юзера. Провайдер bpg/proxmox v0.x
  # не добавляет префикс `token:` в /etc/pve/user.cfg при ACL на token_id,
  # из-за чего privsep=true + ACL на токен → эффективные права пусты.
  # Для readonly PVEAuditor-экспортёра потеря token/user boundary приемлема.
  privileges_separation = false
}

resource "proxmox_acl" "exporter_auditor" {
  user_id   = proxmox_virtual_environment_user.exporter.user_id
  role_id   = "PVEAuditor"
  path      = "/"
  propagate = true
}

locals {
  # bpg/proxmox отдаёт value в формате "user@realm!name=UUID".
  # prometheus-pve-exporter ждёт в token_value только сам UUID.
  exporter_token_uuid = regex("=([0-9a-f-]+)$", proxmox_user_token.exporter.value)[0]
}

resource "vault_kv_secret_v2" "exporter" {
  mount = var.vault_mount
  name  = var.vault_exporter_path
  data_json = jsonencode({
    user        = proxmox_virtual_environment_user.exporter.user_id
    token_name  = proxmox_user_token.exporter.token_name
    token_value = local.exporter_token_uuid
  })
}
