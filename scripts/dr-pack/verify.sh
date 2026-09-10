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
  # --batch без passphrase не спросит её и просто провалится; с GPG_PASSPHRASE
  # проверка проходит неинтерактивно, без него — обычный pinentry.
  if [ -n "${GPG_PASSPHRASE:-}" ]; then
    gpg_decrypt() { gpg --quiet --batch --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" --decrypt "$1"; }
  else
    gpg_decrypt() { gpg --quiet --decrypt "$1"; }
  fi
  if gpg_decrypt "$DR_PACK_DIR/00-shamir.json.gpg" > "$tmp" 2>/dev/null; then
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
  # Без паролей restic пакет бесполезен: репозитории VolSync не открыть, а
  # OpenBao (где они лежат в обычной жизни) сам восстанавливается из бэкапа,
  # зашифрованного ими. Проверяем явно, а не только на отсутствие MISSING.
  for k in RESTIC_PASSWORD_GARAGE RESTIC_PASSWORD_OVH GARAGE_RESTIC_ACCESS_KEY OVH_S3_ACCESS_KEY; do
    if grep -qE "^${k}=.+" "$DR_PACK_DIR/01-bootstrap.env"; then
      log_ok "01-bootstrap.env carries $k"
    else
      log_error "01-bootstrap.env is missing $k — restore would have no way into the repositories"
      fail=$((fail + 1))
    fi
  done
fi

if [ -f "$DR_PACK_DIR/02-vault-raft-snapshot.snap" ]; then
  size=$(stat -c '%s' "$DR_PACK_DIR/02-vault-raft-snapshot.snap")
  age_days=$(( ( $(date +%s) - $(stat -c '%Y' "$DR_PACK_DIR/02-vault-raft-snapshot.snap") ) / 86400 ))
  check "raft snapshot >1KB"        "[ '$size' -gt 1024 ]"
  check "raft snapshot <7 days old" "[ '$age_days' -lt 7 ]"
fi

# Что должно лежать в Vaultwarden, чтобы восстановление было возможно без
# кластера. Парольная фраза пакета отдельной записью НЕ проверяется: она равна
# мастер-паролю хранилища (см. ~/.zshrc, GPG_PASSPHRASE=$BW_PASSWORD) —
# записывать её внутрь того же хранилища смысла нет.
VW_ITEMS='08 - Restic repo passwords (backup v2)
09 - S3 keys backup v2 (restic-apps, snapshots, OVH)'

vw_client=""
if command -v rbw >/dev/null 2>&1 && rbw unlocked >/dev/null 2>&1; then
  vw_client=rbw
elif command -v bw >/dev/null 2>&1 && bw status 2>/dev/null | grep -q '"status":"unlocked"'; then
  vw_client=bw
fi

if [ -n "$vw_client" ]; then
  [ "$vw_client" = "rbw" ] && rbw sync >/dev/null 2>&1
  while IFS= read -r item; do
    if [ -z "$item" ]; then continue; fi
    if [ "$vw_client" = "rbw" ]; then
      found=$(rbw list 2>/dev/null | grep -Fxc "$item" || true)
    else
      found=$(bw list items 2>/dev/null | jq -r '.[].name' | grep -Fxc "$item" || true)
    fi
    if [ "${found:-0}" -gt 0 ]; then
      log_ok "Vaultwarden has '$item'"
    else
      log_error "Vaultwarden missing '$item' — run scripts/dr-pack/to-bitwarden.sh"
      fail=$((fail + 1))
    fi
  done <<< "$VW_ITEMS"
else
  log_warn "хранилище заблокировано — проверка записей Vaultwarden пропущена (rbw unlock)"
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
