#!/usr/bin/env bash
# scripts/dr/restore.sh — disaster recovery orchestrator.
#
# Usage:
#   scripts/dr/restore.sh all                 # run every phase in order
#   scripts/dr/restore.sh phase 03-tls        # run a single phase
#   scripts/dr/restore.sh list                # list available phases

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PHASES_DIR="$SCRIPT_DIR/phases"

list_phases() {
  ls "$PHASES_DIR" | sed -n 's/\.sh$//p' | sort
}

run_phase() {
  local name="$1"
  local file="$PHASES_DIR/$name.sh"
  [ -f "$file" ] || die "no such phase: $name (available: $(list_phases | tr '\n' ' '))"
  log_info "=============================================================="
  log_info "PHASE: $name"
  log_info "=============================================================="
  # shellcheck disable=SC1090
  bash "$file"
  log_ok "phase complete: $name"
}

cmd="${1:-help}"
case "$cmd" in
  all)
    for p in $(list_phases); do
      run_phase "$p"
    done
    log_ok "ALL PHASES COMPLETE"
    ;;
  phase)
    [ $# -ge 2 ] || die "usage: $0 phase <name>"
    run_phase "$2"
    ;;
  list)
    list_phases
    ;;
  help|*)
    cat <<EOF
Usage: $0 <command>
  all                run every phase in order
  phase <name>       run a single phase (idempotent)
  list               list available phases

Phases available:
$(list_phases | sed 's/^/  /')

Env vars:
  DR_PACK_DIR        location of DR pack (default: \$HOME/dr-pack)
  KUBECONFIG         kubeconfig path
  VAULT_TOKEN        OpenBao root token (alternative to decrypting Shamir bundle)
EOF
    ;;
esac
