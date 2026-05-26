#!/usr/bin/env bash
# DEPRECATED (2026-05-26): tuppr controller now drives upgrades declaratively
# via TalosUpgrade + KubernetesUpgrade CRDs (argocd/infra/tuppr/). Use this
# script only as break-glass: when the tuppr controller itself is broken,
# during DR-restore before tuppr is up, or for ad-hoc single-node maintenance
# outside the configured maintenance window.
#
# Wrapper for routine Talos OS and Kubernetes version upgrades on the
# bare-metal homelab cluster (currently talos-cp-{01,02,03}; future workers
# will be picked up automatically from terraform_talos/configs/nodes.yaml).
#
# Scope of this script — operational upgrades only:
#   * talosctl upgrade --image <factory.talos.dev URL>      (per node)
#   * talosctl upgrade-k8s --to <version>                   (cluster-wide)
#
# Out of scope — handled elsewhere:
#   * Changing schematic_id (image extensions) — requires node REPLACEMENT,
#     not in-place upgrade. See skill replacing-talos-node.
#   * Adding nodes — see skill provisioning-talos-node.
#   * Terraform pins (terraform_talos/configs/nodes.yaml) — the script READS
#     them for the `check` subcommand, but does NOT modify them. After an
#     operational upgrade, update terraform_talos/configs/nodes.yaml via a
#     separate PR so Terraform state matches the live cluster.
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

TF_DIR="${TF_DIR:-terraform_talos}"
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
  TF_DIR                 (default: $TF_DIR) — directory with configs/nodes.yaml
  INSTALLER_REGISTRY     (default: $INSTALLER_REGISTRY) — factory URL prefix
  NODE_READY_TIMEOUT     (default: ${NODE_READY_TIMEOUT}s) — per-node Ready wait
  NODE_POLL_INTERVAL     (default: ${NODE_POLL_INTERVAL}s) — Ready poll cadence
EOF
}

die_usage() { usage; exit 2; }
require()   { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }

# Read a scalar pin from terraform_talos/configs/nodes.yaml. Values live
# under `cluster.<key>: v1.x.y` (no quotes, single-line). Robust against
# horizontal-whitespace variation; assumes one definition per file.
tf_pin() {
  local key="$1"
  awk -F': *' -v k="$key" '
    $0 ~ "^[[:space:]]+" k ":" { gsub(/[ \t"]+$/, "", $2); print $2; exit }
  ' "$TF_DIR/configs/nodes.yaml"
}

# Schematic ID is not pinned anywhere — it's the content hash of
# modules/talos/schematic.yaml computed by factory.talos.dev. Cached for the
# duration of the script run to avoid duplicate POSTs.
SCHEMATIC_FILE_DEFAULT="$TF_DIR/modules/talos/schematic.yaml"
_schematic_id_cache=""
schematic_id_from_file() {
  local file="${1:-$SCHEMATIC_FILE_DEFAULT}"
  [ -n "$_schematic_id_cache" ] && { printf '%s' "$_schematic_id_cache"; return 0; }
  [ -f "$file" ] || { echo "missing schematic file: $file" >&2; return 1; }
  require curl; require jq
  _schematic_id_cache=$(curl -fsSL -X POST --data-binary @"$file" \
    https://factory.talos.dev/schematics | jq -r .id) || {
      echo "factory POST failed for $file" >&2; return 1; }
  printf '%s' "$_schematic_id_cache"
}

current_terraform_pins() {
  printf 'kubernetes_version=%s\ntalos_version=%s\ntalos_release=%s\nschematic_id=%s\n' \
    "$(tf_pin kubernetes_version)" \
    "$(tf_pin talos_version)" \
    "$(tf_pin talos_release)" \
    "$(schematic_id_from_file)"
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

# Check whether ghcr.io/siderolabs/kubelet:<tag> exists. Talos builds its
# own kubelet image and publishes it alongside Talos patch releases — so
# upstream k8s v1.36.1 can exist days/weeks before the matching kubelet
# image. talosctl upgrade-k8s pre-pulls this image and aborts on NotFound,
# so we gate on it before suggesting/running an upgrade.
# Returns: 0=exists, 1=not found, 2=unknown (couldn't reach registry).
kubelet_image_exists() {
  local tag="$1" token code
  command -v curl >/dev/null 2>&1 || return 2
  command -v jq   >/dev/null 2>&1 || return 2
  token=$(curl -fsSL --max-time 10 \
            "https://ghcr.io/token?service=ghcr.io&scope=repository:siderolabs/kubelet:pull" 2>/dev/null \
          | jq -r '.token // empty' 2>/dev/null)
  [ -n "$token" ] || return 2
  code=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' \
           -H "Authorization: Bearer $token" \
           -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
           "https://ghcr.io/v2/siderolabs/kubelet/manifests/$tag" 2>/dev/null)
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *)   return 2 ;;
  esac
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

  local k8s_pin talos_pin release_pin schematic_id
  k8s_pin=$(tf_pin kubernetes_version)
  talos_pin=$(tf_pin talos_version)
  release_pin=$(tf_pin talos_release)
  schematic_id=$(schematic_id_from_file)

  echo "=== Terraform pins ($TF_DIR/configs/nodes.yaml) ==="
  printf '  kubernetes_version    = %s\n' "$k8s_pin"
  printf '  talos_version (schema)= %s\n' "$talos_pin"
  printf '  talos_release         = %s\n' "$release_pin"
  printf '  schematic_id (factory)= %s\n' "$schematic_id"

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
    if kubelet_image_exists "$k8s_latest"; then
      printf '  ! Kubernetes upgrade available: %s -> %s\n' "$first_node_kver" "$k8s_latest"
    else
      local rc=$?
      if [ "$rc" = "1" ]; then
        printf '  - Kubernetes %s released upstream, but ghcr.io/siderolabs/kubelet:%s\n' "$k8s_latest" "$k8s_latest"
        printf '    not published yet — wait for next Talos patch release.\n'
      else
        printf '  ? Kubernetes %s released upstream — could not verify kubelet image availability\n' "$k8s_latest"
      fi
    fi
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

  local schematic; schematic=$(schematic_id_from_file) || exit 1
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
      if kubelet_image_exists "$k8s_target"; then
        echo "    talosctl upgrade-k8s --to $k8s_target   (Talos rolls the cluster)"
      else
        local rc=$?
        if [ "$rc" = "1" ]; then
          echo "    BLOCKED — ghcr.io/siderolabs/kubelet:$k8s_target not published yet."
          echo "    Talos builds its own kubelet; wait for next Talos patch release."
        else
          echo "    WARNING — could not verify ghcr.io/siderolabs/kubelet:$k8s_target availability."
        fi
      fi
    fi
  fi
  echo
  echo "  Reminder: after the upgrade succeeds, update $TF_DIR/configs/nodes.yaml pins"
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

  local schematic; schematic=$(schematic_id_from_file) || exit 1
  [ -n "$schematic" ] || { echo "no schematic_id resolved from $SCHEMATIC_FILE_DEFAULT" >&2; exit 1; }
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
  echo "  Remember to bump talos_release in $TF_DIR/configs/nodes.yaml and open a PR."
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

  echo "=== Pre-flight: kubelet image published ==="
  if kubelet_image_exists "$target"; then
    echo "  ghcr.io/siderolabs/kubelet:$target OK"
  else
    local rc=$?
    if [ "$rc" = "1" ]; then
      echo "  ghcr.io/siderolabs/kubelet:$target NOT FOUND" >&2
      echo "  Talos builds its own kubelet image; upstream k8s $target may be released" >&2
      echo "  before the matching Talos patch. Wait for the next Talos release." >&2
      exit 1
    else
      echo "  could not verify ghcr.io/siderolabs/kubelet:$target — proceeding anyway" >&2
    fi
  fi

  echo
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
  echo "  Remember to bump kubernetes_version in $TF_DIR/configs/nodes.yaml and open a PR."
}

case "${1:-}" in
  check)        shift; cmd_check       "$@" ;;
  plan)         shift; cmd_plan        "$@" ;;
  upgrade-os)   shift; cmd_upgrade_os  "$@" ;;
  upgrade-k8s)  shift; cmd_upgrade_k8s "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *) die_usage ;;
esac
