resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version

  lifecycle {
    # The contract only shapes a new secrets bundle. Raising it on existing
    # secrets plans every cert as unknown (provider 0.12.0: no
    # UseStateForUnknown on machine_secrets), lowering it forces a replace;
    # either one risks new cluster CAs and the SA-token cascade.
    ignore_changes = [talos_version]
  }
}
