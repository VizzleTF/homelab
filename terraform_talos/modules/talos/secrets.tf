resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version

  lifecycle {
    # Raising it plans every cert unknown (provider 0.12.0), lowering forces a
    # replace: either risks new cluster CAs and the SA-token cascade.
    ignore_changes = [talos_version]
  }
}
