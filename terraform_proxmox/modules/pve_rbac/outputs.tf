output "exporter_token_id" {
  description = "Идентификатор токена в формате `user@realm!name` — удобно для ручной верификации."
  value       = proxmox_user_token.exporter.id
}

output "vault_exporter_path" {
  description = "Путь в Vault, куда записан секрет pve-exporter."
  value       = "${var.vault_mount}/${var.vault_exporter_path}"
}
