#!/usr/bin/env bash
# Wrapper for routine Talos OS and Kubernetes version upgrades on the
# homelab cluster (talos-cp-{01,02,03} + talos-worker-{01,02,03}).
#
# Scope of this script — operational upgrades only:
#   * talosctl upgrade --image <factory.talos.dev URL>      (per node)
#   * talosctl upgrade-k8s --to <version>                   (cluster-wide)
#
# Out of scope — handled elsewhere:
#   * Changing schematic_id (image extensions) — requires node REPLACEMENT,
#     not in-place upgrade. See skill replacing-talos-node.
#   * Adding nodes — see skill provisioning-talos-node.
#   * Terraform pins (terraform_proxmox/main.tf) — the script READS them
#     for the `check` subcommand, but does NOT modify them. After an
#     operational upgrade, update terraform_proxmox/main.tf via a separate
#     PR so Terraform state matches the live cluster.
#
# Subcommands:
#   check                            current cluster + terraform pins +
#                                    upstream latest releases; warn on drift
#   plan   --talos <v> --k8s <v>     dry-run: show what `upgrade-os all` and
#                                    `upgrade-k8s` would do, no mutation
#   upgrade-os <node|all> [--release vX.Y.Z]
#                                    Talos OS upgrade. `all` walks nodes
#                                    sequentially, waiting for Ready=True
#                                    between each. CP nodes first, then
#                                    workers (etcd quorum protection).
#   upgrade-k8s --to <vX.Y.Z>        cluster-wide k8s upgrade; Talos does
#                                    the rolling internally.
#
# Skill that wraps this: NONE currently — exists as a standalone tool. If
# we want a skill later, the canonical SKILL.md shape (frontmatter →
# when/notwhen → how → gotchas → memory links) applies.
set -euo pipefail

TF_DIR="${TF_DIR:-terraform_proxmox}"
INSTALLER_REGISTRY="${INSTALLER_REGISTRY:-factory.talos.dev/installer}"

# How long to wait for a node to come back Ready after upgrade.
NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-600}"   # seconds
NODE_POLL_INTERVAL="${NODE_POLL_INTERVAL:-15}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 check
  $0 plan       --talos <vX.Y.Z> --k8s <vX.Y.Z>
  $0 upgrade-os <node-name|all> [--release vX.Y.Z]
  $0 upgrade-k8s --to <vX.Y.Z>

Env:
  TF_DIR                 (default: $TF_DIR) — directory with terraform main.tf
  INSTALLER_REGISTRY     (default: $INSTALLER_REGISTRY) — factory URL prefix
  NODE_READY_TIMEOUT     (default: ${NODE_READY_TIMEOUT}s) — per-node Ready wait
  NODE_POLL_INTERVAL     (default: ${NODE_POLL_INTERVAL}s) — Ready poll cadence
EOF
}

die_usage() { usage; exit 2; }
require()   { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }

# Read a string pin from terraform_proxmox/main.tf. Robust against
# horizontal-whitespace variation; assumes one definition per file.
tf_pin() {
  local key="$1"
  awk -F'"' -v k="$key" '
    $0 ~ "^[[:space:]]+" k "[[:space:]]+=" { print $2; exit }
  ' "$TF_DIR/main.tf"
}

current_terraform_pins() {
  printf 'kubernetes_version=%s\ntalos_version=%s\ntalos_release=%s\nschematic_id=%s\n' \
    "$(tf_pin kubernetes_version)" \
    "$(tf_pin talos_version)" \
    "$(tf_pin talos_release)" \
    "$(tf_pin install_schematic_id)"
}

# Map node-name → InternalIP via kubectl.
node_ip() {
  kubectl get node "$1" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null
}

# List node names; CP nodes first, then workers, each sorted alphabetically.
ordered_nodes() {
  ordered_nodes_with_meta | cut -f1
}

# Emit one line per node, TAB-separated: name role ip kubeletVersion.
# Sorted: CP nodes first (alphabetically), then workers (alphabetically).
ordered_nodes_with_meta() {
  kubectl get nodes -o json 2>/dev/null | python3 -c '
import sys, json
items = json.load(sys.stdin)["items"]
cp, wk = [], []
for n in items:
    name = n["metadata"]["name"]
    labels = n["metadata"].get("labels", {})
    role = "cp" if "node-role.kubernetes.io/control-plane" in labels else "worker"
    ip = ""
    for a in n["status"].get("addresses", []):
        if a.get("type") == "InternalIP":
            ip = a.get("address", ""); break
    kver = n["status"].get("nodeInfo", {}).get("kubeletVersion", "?")
    row = (name, role, ip, kver)
    (cp if role == "cp" else wk).append(row)
for tup in sorted(cp) + sorted(wk):
    print("\t".join(tup))
'
}

# kubelet version of one node, e.g. "v1.36.0"
node_kubelet_version() {
  kubectl get node "$1" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null
}

# Talos OS version reported by the node, e.g. "v1.13.0"
node_talos_version() {
  local ip="$1"
  talosctl version --nodes "$ip" --short 2>/dev/null \
    | awk '/Tag:/{print $2; exit}'
}

# Wait for a node to reach Ready=True. Returns 0 on success, 1 on timeout.
wait_node_ready() {
  local node="$1" start=$SECONDS
  while :; do
    local ready
    ready=$(kubectl get node "$node" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
    if [ "$ready" = "True" ]; then
      return 0
    fi
    if [ $((SECONDS - start)) -ge "$NODE_READY_TIMEOUT" ]; then
      echo "  timeout: $node still not Ready after ${NODE_READY_TIMEOUT}s (last=$ready)" >&2
      return 1
    fi
    sleep "$NODE_POLL_INTERVAL"
  done
}

cmd_check() {
  require kubectl
  require talosctl
  require python3

  local k8s_pin talos_pin release_pin schematic_pin
  k8s_pin=$(tf_pin kubernetes_version)
  talos_pin=$(tf_pin talos_version)
  release_pin=$(tf_pin talos_release)
  schematic_pin=$(tf_pin install_schematic_id)

  echo "=== Terraform pins ($TF_DIR/main.tf) ==="
  printf '  kubernetes_version    = %s\n' "$k8s_pin"
  printf '  talos_version (schema)= %s\n' "$talos_pin"
  printf '  talos_release         = %s\n' "$release_pin"
  printf '  install_schematic_id  = %s\n' "$schematic_pin"

  echo
  echo "=== Live cluster (per node) ==="
  printf '  %-18s  %-10s  %-10s  %s\n' "NODE" "KUBELET" "TALOS" "ROLE"
  while IFS=$'\t' read -r name role ip kver; do
    local tver; tver=$(node_talos_version "$ip")
    printf '  %-18s  %-10s  %-10s  %s\n' "$name" "$kver" "$tver" "$role"
  done < <(ordered_nodes_with_meta)

  echo
  echo "=== Upstream latest releases (GitHub) ==="
  require curl
  require jq
  local talos_latest k8s_latest
  talos_latest=$(curl -fsSL https://api.github.com/repos/siderolabs/talos/releases/latest 2>/dev/null \
                  | jq -r '.tag_name' || echo "?")
  k8s_latest=$(curl -fsSL https://api.github.com/repos/kubernetes/kubernetes/releases/latest 2>/dev/null \
                | jq -r '.tag_name' || echo "?")
  printf '  Talos latest:      %s\n' "$talos_latest"
  printf '  Kubernetes latest: %s\n' "$k8s_latest"

  echo
  echo "=== Drift summary ==="
  local first_node_tver first_node_kver
  first_node_kver=$(node_kubelet_version "$(ordered_nodes | head -1)")
  first_node_tver=$(node_talos_version "$(node_ip "$(ordered_nodes | head -1)")")
  if [ "$first_node_tver" = "$release_pin" ]; then
    printf '  cluster Talos %s == tf %s\n' "$first_node_tver" "$release_pin"
  else
    printf '  ! cluster Talos %s != tf %s — pin or cluster lags\n' "$first_node_tver" "$release_pin" >&2
  fi
  if [ "$first_node_kver" = "$k8s_pin" ]; then
    printf '  cluster K8s %s == tf %s\n' "$first_node_kver" "$k8s_pin"
  else
    printf '  ! cluster K8s %s != tf %s — pin or cluster lags\n' "$first_node_kver" "$k8s_pin" >&2
  fi
  if [ "$first_node_tver" != "$talos_latest" ] && [ "$talos_latest" != "?" ]; then
    printf '  ! Talos upgrade available: %s -> %s\n' "$first_node_tver" "$talos_latest"
  fi
  if [ "$first_node_kver" != "$k8s_latest" ] && [ "$k8s_latest" != "?" ]; then
    printf '  ! Kubernetes upgrade available: %s -> %s\n' "$first_node_kver" "$k8s_latest"
  fi
}

cmd_plan() {
  local talos_target="" k8s_target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --talos) talos_target="${2:?--talos requires value}"; shift 2 ;;
      --k8s)   k8s_target="${2:?--k8s requires value}";     shift 2 ;;
      *) echo "unknown flag: $1" >&2; die_usage ;;
    esac
  done
  [ -n "$talos_target" ] || [ -n "$k8s_target" ] || die_usage
  require kubectl
  require talosctl
  require python3

  local schematic; schematic=$(tf_pin install_schematic_id)
  echo "=== Plan (dry-run — nothing will be touched) ==="
  echo
  if [ -n "$talos_target" ]; then
    local image="$INSTALLER_REGISTRY/$schematic:$talos_target"
    echo "  Talos OS upgrade to $talos_target"
    echo "    image: $image"
    echo "    order: (sequential)"
    for n in $(ordered_nodes); do
      local ip; ip=$(node_ip "$n")
      local cur; cur=$(node_talos_version "$ip")
      if [ "$cur" = "$talos_target" ]; then
        printf '      - %s (%s)  SKIP — already at target\n' "$n" "$ip"
      else
        printf '      - %s (%s)  %s -> %s\n' "$n" "$ip" "$cur" "$talos_target"
      fi
    done
    echo
  fi
  if [ -n "$k8s_target" ]; then
    echo "  Kubernetes upgrade to $k8s_target"
    local first; first=$(ordered_nodes | head -1)
    local cur; cur=$(node_kubelet_version "$first")
    if [ "$cur" = "$k8s_target" ]; then
      echo "    SKIP — kubelet already at $cur"
    else
      echo "    talosctl upgrade-k8s --to $k8s_target   (Talos rolls the cluster)"
    fi
  fi
  echo
  echo "  Reminder: after the upgrade succeeds, update $TF_DIR/main.tf pins"
  echo "  (kubernetes_version / talos_release) and open a PR so Terraform"
  echo "  state matches the live cluster."
}

cmd_upgrade_os() {
  local target="${1:-}"
  [ -n "$target" ] || die_usage
  shift
  local release=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --release) release="${2:?--release requires value}"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; die_usage ;;
    esac
  done
  # Default release = whatever is pinned in terraform.
  [ -n "$release" ] || release=$(tf_pin talos_release)
  [ -n "$release" ] || { echo "could not resolve release (no --release, no tf pin)" >&2; exit 1; }

  require kubectl
  require talosctl

  local schematic; schematic=$(tf_pin install_schematic_id)
  [ -n "$schematic" ] || { echo "no schematic_id in $TF_DIR/main.tf" >&2; exit 1; }
  local image="$INSTALLER_REGISTRY/$schematic:$release"

  local nodes
  if [ "$target" = "all" ]; then
    nodes=$(ordered_nodes)
  else
    kubectl get node "$target" >/dev/null 2>&1 || {
      echo "no such node: $target" >&2; exit 1;
    }
    nodes="$target"
  fi

  echo "=== Pre-flight: all nodes Ready ==="
  local not_ready
  not_ready=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
              | grep -v '=True$' || true)
  if [ -n "$not_ready" ]; then
    echo "  cluster not fully Ready — aborting before any upgrade:" >&2
    printf '%s\n' "$not_ready" >&2
    exit 1
  fi
  echo "  all nodes Ready"

  echo
  echo "=== Upgrade image: $image ==="
  local i=0 total
  total=$(printf '%s\n' "$nodes" | wc -l | tr -d ' ')
  for n in $nodes; do
    i=$((i+1))
    local ip cur
    ip=$(node_ip "$n")
    cur=$(node_talos_version "$ip")
    echo
    echo "--- [$i/$total] $n ($ip) ---"
    if [ "$cur" = "$release" ]; then
      echo "  already at $release — skipping"
      continue
    fi
    echo "  $cur -> $release   (talosctl upgrade --nodes $ip --image $image)"
    talosctl upgrade --nodes "$ip" --image "$image" --wait
    echo "  waiting for kubelet Ready (timeout=${NODE_READY_TIMEOUT}s)..."
    wait_node_ready "$n" || exit 1
    local new; new=$(node_talos_version "$ip")
    echo "  Ready, now reports Talos $new"
    if [ "$new" != "$release" ]; then
      echo "  WARNING: node version $new != target $release" >&2
    fi
  done

  echo
  echo "=== Done ==="
  echo "  Remember to bump talos_release in $TF_DIR/main.tf and open a PR."
}

cmd_upgrade_k8s() {
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) target="${2:?--to requires value}"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; die_usage ;;
    esac
  done
  [ -n "$target" ] || die_usage
  require kubectl
  require talosctl

  echo "=== Pre-flight: all nodes Ready ==="
  local not_ready
  not_ready=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
              | grep -v '=True$' || true)
  if [ -n "$not_ready" ]; then
    echo "  cluster not fully Ready — aborting:" >&2
    printf '%s\n' "$not_ready" >&2
    exit 1
  fi
  echo "  all nodes Ready"

  echo
  echo "=== Current kubelet versions ==="
  for n in $(ordered_nodes); do
    printf '  %-18s  %s\n' "$n" "$(node_kubelet_version "$n")"
  done

  echo
  echo "=== Running talosctl upgrade-k8s --to $target ==="
  talosctl upgrade-k8s --to "$target"

  echo
  echo "=== Post-upgrade kubelet versions ==="
  for n in $(ordered_nodes); do
    printf '  %-18s  %s\n' "$n" "$(node_kubelet_version "$n")"
  done

  echo
  echo "=== Done ==="
  echo "  Remember to bump kubernetes_version in $TF_DIR/main.tf and open a PR."
}

case "${1:-}" in
  check)        shift; cmd_check       "$@" ;;
  plan)         shift; cmd_plan        "$@" ;;
  upgrade-os)   shift; cmd_upgrade_os  "$@" ;;
  upgrade-k8s)  shift; cmd_upgrade_k8s "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *) die_usage ;;
esac
