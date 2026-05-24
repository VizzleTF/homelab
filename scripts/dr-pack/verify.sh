#!/usr/bin/env bash
# scripts/dr-pack/verify.sh — sanity-check the DR pack BEFORE you need it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../dr/lib/common.sh
source "$SCRIPT_DIR/../dr/lib/common.sh"

DRILL=0
[ "${1:-}" = "--drill" ] && DRILL=1

fail=0

check() {
  if eval "$2"; then
    log_ok "$1"
  else
    log_error "$1"
    fail=$((fail + 1))
  fi
}

log_info "verifying DR pack at $DR_PACK_DIR"

check "00-shamir.json.gpg exists"           "[ -f '$DR_PACK_DIR/00-shamir.json.gpg' ]"
check "01-bootstrap.env exists"             "[ -f '$DR_PACK_DIR/01-bootstrap.env' ]"
check "02-vault-raft-snapshot.snap exists"  "[ -f '$DR_PACK_DIR/02-vault-raft-snapshot.snap' ]"
check "03-cluster.env exists"               "[ -f '$DR_PACK_DIR/03-cluster.env' ]"

if [ -f "$DR_PACK_DIR/00-shamir.json.gpg" ]; then
  tmp=$(mktemp)
  if gpg --quiet --batch --decrypt "$DR_PACK_DIR/00-shamir.json.gpg" > "$tmp" 2>/dev/null; then
    keys=$(jq -r '.unseal_keys_b64 | length' "$tmp" 2>/dev/null || echo 0)
    root=$(jq -r '.root_token | length' "$tmp" 2>/dev/null || echo 0)
    check "shamir bundle has 3 unseal keys" "[ '$keys' = '3' ]"
    check "shamir bundle has root_token"    "[ '$root' -gt 20 ]"
  else
    log_error "shamir decrypt failed (passphrase?)"
    fail=$((fail + 1))
  fi
  shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
fi

if [ -f "$DR_PACK_DIR/01-bootstrap.env" ]; then
  if grep -q 'MISSING' "$DR_PACK_DIR/01-bootstrap.env"; then
    log_error "01-bootstrap.env contains MISSING placeholders"
    fail=$((fail + 1))
  else
    log_ok "01-bootstrap.env has no MISSING markers"
  fi
fi

if [ -f "$DR_PACK_DIR/02-vault-raft-snapshot.snap" ]; then
  size=$(stat -c '%s' "$DR_PACK_DIR/02-vault-raft-snapshot.snap")
  age_days=$(( ( $(date +%s) - $(stat -c '%Y' "$DR_PACK_DIR/02-vault-raft-snapshot.snap") ) / 86400 ))
  check "raft snapshot >1KB"        "[ '$size' -gt 1024 ]"
  check "raft snapshot <7 days old" "[ '$age_days' -lt 7 ]"
fi

if [ -d "$HOME/.config/Bitwarden CLI" ] || command -v bw >/dev/null 2>&1; then
  if bw status 2>/dev/null | grep -q '"status":"unlocked"'; then
    if bw list items 2>/dev/null | jq -e '.[] | select(.name == "00 - DR Pack Passphrase")' >/dev/null; then
      log_ok "Vaultwarden has '00 - DR Pack Passphrase' note"
    else
      log_error "Vaultwarden missing '00 - DR Pack Passphrase' note"
      fail=$((fail + 1))
    fi
  else
    log_warn "bw not unlocked — skipping Vaultwarden passphrase check (run: export BW_SESSION=\$(bw unlock --raw))"
  fi
fi

if [ "$DRILL" -eq 1 ]; then
  log_info "drill mode — would now spawn kind cluster + replay phases 00-06"
  log_warn "drill replay not implemented yet (TODO)"
fi

if [ "$fail" -eq 0 ]; then
  log_ok "DR pack verification PASSED"
  exit 0
else
  log_error "DR pack verification FAILED ($fail issue(s))"
  exit 1
fi
