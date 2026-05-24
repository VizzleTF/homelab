#!/usr/bin/env bash
# Common helpers sourced by every DR script.

set -euo pipefail

# Colors only on TTY
if [ -t 1 ]; then
  COLOR_RED=$'\033[0;31m'
  COLOR_GREEN=$'\033[0;32m'
  COLOR_YELLOW=$'\033[0;33m'
  COLOR_BLUE=$'\033[0;34m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_RESET=""
fi

log_info()  { printf "%b[INFO]%b  %s\n"  "$COLOR_BLUE"   "$COLOR_RESET" "$*"; }
log_ok()    { printf "%b[OK]%b    %s\n"  "$COLOR_GREEN"  "$COLOR_RESET" "$*"; }
log_warn()  { printf "%b[WARN]%b  %s\n"  "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; }
log_error() { printf "%b[ERROR]%b %s\n"  "$COLOR_RED"    "$COLOR_RESET" "$*" >&2; }
log_skip()  { printf "%b[SKIP]%b  %s\n"  "$COLOR_YELLOW" "$COLOR_RESET" "$*"; }

die() { log_error "$*"; exit 1; }

# Resolve repo root (relative to this lib file, $REPO_ROOT/scripts/dr/lib/common.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DR_LIB_DIR="$SCRIPT_DIR"
DR_DIR="$(cd "$DR_LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DR_DIR/../.." && pwd)"

# DR pack location (override via env)
DR_PACK_DIR="${DR_PACK_DIR:-$HOME/dr-pack}"

# Wait for a kubectl condition with a sane timeout and progress logging.
# Usage: wait_for "label" "command that returns 0 when ready" [timeout_seconds]
wait_for() {
  local label="$1" cmd="$2" timeout="${3:-300}"
  local deadline=$(( $(date +%s) + timeout ))
  log_info "wait: $label (timeout ${timeout}s)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if eval "$cmd" >/dev/null 2>&1; then
      log_ok "ready: $label"
      return 0
    fi
    sleep 5
  done
  die "timeout waiting for: $label"
}

# Require an env var to be set and non-empty
require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    die "missing env var: $name"
  fi
}

# Source ~/dr-pack/01-bootstrap.env (CF_API_TOKEN + Garage + OVH creds)
load_bootstrap_env() {
  local f="$DR_PACK_DIR/01-bootstrap.env"
  [ -f "$f" ] || die "missing $f — run scripts/dr-pack/build.sh"
  # shellcheck disable=SC1090
  set -a
  source "$f"
  set +a
}

# Same for 03-cluster.env (gateway IPs, etc)
load_cluster_env() {
  local f="$DR_PACK_DIR/03-cluster.env"
  [ -f "$f" ] || die "missing $f — run scripts/dr-pack/build.sh"
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}

# kubectl reachable?
require_kubectl() {
  kubectl cluster-info --request-timeout=5s >/dev/null 2>&1 \
    || die "kubectl not configured / cluster unreachable. Set KUBECONFIG."
}

# helm upgrade --install wrapper: idempotent, --wait
helm_apply() {
  local release="$1" chart="$2" namespace="$3" ; shift 3
  local extra_args=("$@")
  log_info "helm upgrade --install $release ($chart) -n $namespace"
  kubectl get ns "$namespace" >/dev/null 2>&1 \
    || kubectl create namespace "$namespace" >/dev/null
  helm upgrade --install "$release" "$chart" \
    --namespace "$namespace" \
    --wait --timeout 10m \
    "${extra_args[@]}"
}
