# Imported from existing cluster on first apply:
#   terraform import 'module.talos.talos_machine_secrets.this' _out/secrets.yaml
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}
