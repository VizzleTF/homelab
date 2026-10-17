#!/usr/bin/env bash
# Validate the Talos machine config that terraform_talos/ would apply, for every
# enabled node in terraform_talos/configs/nodes.yaml: base config generated for
# the contract (vX.Y of cluster.talos_release) and Kubernetes version, plus
# the patches rendered by the same module terraform uses
# (terraform_talos/modules/talos/patches), then `talosctl validate -m metal`.
#
# Offline apart from `terraform init` of a local module: no state, no provider,
# throwaway secrets. Catches a contract or Talos bump whose patches conflict
# with the generated documents ("... is already set in v1alpha1 config") before
# `terraform apply` hits it on a node.
#
# Shared by the CI talos-validate job and `task ci:talos-validate`. Requires
# `terraform`, `talosctl` and `jq` on PATH (.mise.toml). Pass --strict to fail
# on warnings too (deprecated v1alpha1 fields). TALOS_VALIDATE_OUT=<dir> keeps
# the merged config per node there.
set -euo pipefail

STRICT=()
[ "${1:-}" = "--strict" ] && STRICT=(--strict)

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TF="$ROOT/terraform_talos"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Same node filter and shape as terraform_talos/main.tf.
cat > "$WORK/main.tf" <<EOF
locals {
  c = yamldecode(file("$TF/configs/nodes.yaml"))
  nodes = {
    for name, n in local.c.nodes : name => {
      address      = split("/", n.address)[0]
      address_cidr = n.address
      role         = n.role
      install_disk = n.install_disk
      mac          = n.mac
      labels       = try(n.labels, {})
    } if try(n.enabled, false)
  }
}

module "patches" {
  source              = "$TF/modules/talos/patches"
  install_image       = "factory.talos.dev/metal-installer/validate:\${local.c.cluster.talos_release}"
  gateway             = local.c.cluster.gateway
  vip                 = local.c.cluster.vip
  apiserver_cert_sans = local.c.cluster.apiserver_cert_sans
  nodes               = local.nodes
}

output "patches" {
  value = module.patches
}
output "cluster" {
  # Contract as in terraform_talos/main.tf.
  value = merge(local.c.cluster, { talos_version = regex("^v[0-9]+\\\\.[0-9]+", local.c.cluster.talos_release) })
}
output "roles" {
  value = { for name, n in local.nodes : name => n.role }
}
EOF

terraform -chdir="$WORK" init -input=false -no-color >/dev/null
terraform -chdir="$WORK" apply -input=false -no-color -auto-approve >/dev/null
terraform -chdir="$WORK" output -json > "$WORK/out.json"

jq -r '.patches.value.common' "$WORK/out.json" > "$WORK/common.yaml"
jq -r '.patches.value.controlplane' "$WORK/out.json" > "$WORK/controlplane.yaml"
contract=$(jq -r '.cluster.value.talos_version' "$WORK/out.json")
k8s=$(jq -r '.cluster.value.kubernetes_version' "$WORK/out.json")

# gen prints progress on stderr; show it only on failure.
gen() { local out; out=$("$@" 2>&1) || { echo "$out" >&2; exit 1; }; }
gen talosctl gen secrets -o "$WORK/secrets.yaml"
gen talosctl gen config validate https://127.0.0.1:6443 \
  --with-secrets "$WORK/secrets.yaml" --talos-version "$contract" \
  --kubernetes-version "$k8s" --with-docs=false --with-examples=false \
  -o "$WORK/base"

echo "contract $contract, kubernetes $k8s"
rc=0
while read -r name role; do
  jq -r --arg n "$name" '.patches.value.node[$n]' "$WORK/out.json" > "$WORK/node-$name.yaml"
  if [ "$role" = controlplane ]; then
    base="$WORK/base/controlplane.yaml"
    patches=(-p "@$WORK/common.yaml" -p "@$WORK/controlplane.yaml")
  else
    base="$WORK/base/worker.yaml"
    patches=(-p "@$WORK/common.yaml")
  fi
  if talosctl machineconfig patch "$base" "${patches[@]}" -p "@$WORK/node-$name.yaml" \
       -o "$WORK/$name.yaml" 2>"$WORK/$name.err" \
     && talosctl validate -m metal "${STRICT[@]}" -c "$WORK/$name.yaml" >>"$WORK/$name.err" 2>&1; then
    echo "ok   $name ($role)"
  else
    echo "FAIL $name ($role)"
    sed 's/^/     /' "$WORK/$name.err"
    rc=1
  fi
done < <(jq -r '.roles.value | to_entries[] | "\(.key) \(.value)"' "$WORK/out.json")
[ -n "${TALOS_VALIDATE_OUT:-}" ] && mkdir -p "$TALOS_VALIDATE_OUT" && cp "$WORK"/talos-*.yaml "$TALOS_VALIDATE_OUT"/
exit "$rc"
