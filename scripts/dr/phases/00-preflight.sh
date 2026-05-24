#!/usr/bin/env bash
# Phase 00 — DR pack + cluster + tooling preflight.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

log_info "checking required binaries"
for bin in kubectl helm jq gpg ssh openssl curl; do
  command -v "$bin" >/dev/null || die "missing binary: $bin"
done
log_ok "binaries present"

require_kubectl
log_ok "kubectl reachable: $(kubectl config current-context)"

log_info "checking DR pack: $DR_PACK_DIR"
required_files=(
  "00-shamir.json.gpg"
  "01-bootstrap.env"
  "02-vault-raft-snapshot.snap"
  "03-cluster.env"
)
for f in "${required_files[@]}"; do
  [ -f "$DR_PACK_DIR/$f" ] || die "DR pack missing: $DR_PACK_DIR/$f — run scripts/dr-pack/build.sh"
done
log_ok "DR pack files present"

# Validate bootstrap env has required keys
load_bootstrap_env
for v in CF_API_TOKEN GARAGE_VELERO_ACCESS_KEY GARAGE_VELERO_SECRET; do
  require_env "$v"
done
log_ok "bootstrap env has CF + Garage creds"

# Validate Shamir bundle decrypts (caller will be prompted for passphrase only here)
log_info "validating Shamir bundle decrypts"
tmp=$(mktemp)
trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' EXIT
gpg --quiet --batch --decrypt "$DR_PACK_DIR/00-shamir.json.gpg" > "$tmp" 2>/dev/null \
  || die "Shamir decrypt failed. Check GPG passphrase or DR pack integrity."
keys=$(jq -r '.unseal_keys_b64 | length' "$tmp")
[ "$keys" = "3" ] || die "Shamir bundle has $keys keys, expected 3"
log_ok "Shamir bundle valid (3 unseal keys + root token)"

# Validate Raft snapshot is non-empty
size=$(stat -c '%s' "$DR_PACK_DIR/02-vault-raft-snapshot.snap")
[ "$size" -gt 1024 ] || die "Raft snapshot suspiciously small: ${size} bytes"
log_ok "Raft snapshot present (${size} bytes)"

log_ok "preflight passed"
