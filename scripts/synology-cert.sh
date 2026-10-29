#!/usr/bin/env bash
# Renew the Synology NAS (memini) LE cert via acme.sh + Cloudflare DNS-01, then
# update the DSM cert archive and reload nginx; subcommands in usage().
#
# acme.sh uses custom paths (as ~/.acme.sh/renew.sh on the box): --home
# ~/.acme.sh --config-home ~/.acme.sh/data --cert-home ~/.acme.sh/certs.
# ~/.acme.sh/cf.env holds the same CF token as OpenBao
# home/homelab/k8s/external-dns/cloudflare.
# DSM archive ids are random 6-char dirs; the right one is found by matching
# cert.pem subject/SAN against the domain.
set -euo pipefail

SYNOLOGY_SSH="${SYNOLOGY_SSH:-ivan@10.11.12.237}"
SYNOLOGY_HOME="${SYNOLOGY_HOME:-/var/services/homes/ivan}"
ACME_HOME="${ACME_HOME:-$SYNOLOGY_HOME/.acme.sh}"
DSM_ARCHIVE="${DSM_ARCHIVE:-/usr/syno/etc/certificate/_archive}"
SYNOW3TOOL="${SYNOW3TOOL:-/usr/syno/bin/synow3tool}"
DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-*.example.com}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 status [<domain>]
  $0 renew  [<domain>]

Subcommands:
  status  list cert archive entries (id, subject, notAfter); pass a domain
          to show only matching entries + cron + endpoint check
  renew   force-renew via acme.sh, copy into DSM archive, synow3tool reload.
          Default domain: $DEFAULT_DOMAIN (quote glob chars on the CLI).

Env:
  SYNOLOGY_SSH    ssh target (default: $SYNOLOGY_SSH)
  ACME_HOME       acme.sh root on NAS (default: $ACME_HOME)
  DSM_ARCHIVE     DSM cert archive root (default: $DSM_ARCHIVE)
  SYNOW3TOOL      DSM nginx admin binary (default: $SYNOW3TOOL)
  DEFAULT_DOMAIN  domain used when none provided (default: $DEFAULT_DOMAIN)
EOF
}

die_usage() { usage; exit 2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}

ssh_nas() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 \
    "$SYNOLOGY_SSH" "$@"
}

probe_health() {
  ssh_nas "test -d $ACME_HOME && test -f $ACME_HOME/cf.env && test -d $DSM_ARCHIVE" \
    || { echo "acme.sh, cf.env, or DSM_ARCHIVE missing on $SYNOLOGY_SSH" >&2; exit 1; }
}

# One TSV line per real archive entry: id<TAB>subject<TAB>notAfter
list_certs_remote() {
  ssh_nas "sudo bash -s" "$DSM_ARCHIVE" <<'REMOTE'
    archive="$1"
    cd "$archive" || exit 1
    for entry in */; do
      entry=${entry%/}
      case "$entry" in
        INFO*|SERVICES|DEFAULT|_*) continue ;;
      esac
      [ -f "$entry/cert.pem" ] || continue
      subj=$(openssl x509 -in "$entry/cert.pem" -noout -subject 2>/dev/null | sed 's/^subject= *//')
      san=$(openssl x509 -in "$entry/cert.pem" -noout -ext subjectAltName 2>/dev/null \
            | tr '\n,' '  ' | sed 's/^.*Alternative Name: *//; s/DNS://g; s/  */ /g')
      end=$(openssl x509 -in "$entry/cert.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
      printf '%s\t%s\t%s\t%s\n' "$entry" "$subj" "$san" "$end"
    done
REMOTE
}

cmd_status() {
  require ssh
  probe_health
  local filter="${1:-}"

  echo "=== DSM cert archive ==="
  printf '%-8s  %-50s  %s\n' "ID" "Subject" "notAfter"
  list_certs_remote | while IFS=$'\t' read -r id subj san end; do
    if [ -z "$filter" ] || printf '%s %s' "$subj" "$san" | grep -qF -- "$filter"; then
      printf '%-8s  %-50s  %s\n' "$id" "$subj" "$end"
    fi
  done

  echo
  echo "=== acme.sh cron entry ==="
  ssh_nas 'grep -E "acme|renew\.sh" /etc/crontab || echo "(no acme cron found)"'

  echo
  echo "=== acme.sh last run (tail of renew.log) ==="
  ssh_nas "test -f $ACME_HOME/renew.log && tail -5 $ACME_HOME/renew.log || echo '(no renew.log)'"

  if [ -n "$filter" ]; then
    echo
    echo "=== external TLS handshake for hostname matching '$filter' (best-effort) ==="
    case "$filter" in
      \**|*\**) echo "(skip — filter is a glob/wildcard)" ;;
      *)
        echo | openssl s_client -connect "${filter}:443" -servername "$filter" 2>/dev/null \
          | openssl x509 -noout -subject -dates 2>&1 | head -5
        ;;
    esac
  fi
}

# Domain → DSM archive id by subject or SAN; empty on no or multiple matches.
resolve_archive_id() {
  local domain="$1" id subj san matches=""
  while IFS=$'\t' read -r id subj san _end; do
    if printf '%s %s' "$subj" "$san" | grep -qF -- "$domain"; then
      matches="$matches $id"
    fi
  done < <(list_certs_remote)
  matches=$(printf '%s' "$matches" | tr ' ' '\n' | grep -v '^$' | head -2)
  # grep -c, not wc -l: BSD wc pads the count with spaces, so "1)" never matched.
  case "$(printf '%s' "$matches" | grep -c . || true)" in
    0) return ;;
    1) printf '%s' "$matches" ;;
    *) printf 'AMBIGUOUS\n%s' "$matches" ;;
  esac
}

cmd_renew() {
  require ssh
  probe_health
  local domain="${1:-$DEFAULT_DOMAIN}"
  echo "renewing cert for: $domain"
  echo "(acme.sh home: $ACME_HOME; DSM archive: $DSM_ARCHIVE)"
  echo

  echo "=== 1/6 acme.sh --renew --force -d '$domain' (CF DNS-01) ==="
  # As renew.sh does: set HOME and source the CF env.
  local rc=0
  ssh_nas "sudo -u ivan bash -s" "$ACME_HOME" "$domain" <<'REMOTE' || rc=$?
    set -euo pipefail
    acme_home="$1"; domain="$2"
    export HOME=/var/services/homes/ivan
    # shellcheck disable=SC1091
    source "$acme_home/cf.env"
    "$acme_home/acme.sh" --renew \
      --home "$acme_home" \
      --config-home "$acme_home/data" \
      --cert-home "$acme_home/certs" \
      -d "$domain" --force
REMOTE
  if [ $rc -ne 0 ]; then
    echo "acme.sh --renew failed (rc=$rc; CF token expired? DNS-01 challenge timeout?)" >&2
    exit 1
  fi

  echo
  echo "=== 2/6 find DSM archive id matching '$domain' ==="
  local archive_id; archive_id=$(resolve_archive_id "$domain")
  case "$archive_id" in
    "")
      echo "no DSM archive entry matches '$domain' — first-time setup needed via DSM UI:" >&2
      echo "  Control Panel → Security → Certificate → Add → Import from $ACME_HOME/certs/${domain}_ecc/" >&2
      exit 1 ;;
    AMBIGUOUS*)
      echo "multiple DSM archive entries match — resolve manually:" >&2
      printf '%s\n' "$archive_id" >&2
      exit 1 ;;
  esac
  echo "  archive id: $archive_id"

  echo
  echo "=== 3/6 copy ECC cert files into $DSM_ARCHIVE/$archive_id/ ==="
  ssh_nas "sudo bash -s" "$ACME_HOME" "$domain" "$DSM_ARCHIVE" "$archive_id" <<'REMOTE'
    set -euo pipefail
    acme_home="$1"; domain="$2"; archive="$3"; id="$4"
    src="$acme_home/certs/${domain}_ecc"
    dst="$archive/$id"
    [ -d "$src" ] || { echo "ECC cert dir not found: $src" >&2; exit 1; }
    cp "$src/${domain}.cer"        "$dst/cert.pem"
    cp "$src/ca.cer"               "$dst/chain.pem"
    cp "$src/fullchain.cer"        "$dst/fullchain.pem"
    cp "$src/${domain}.key"        "$dst/privkey.pem"
    chmod 644 "$dst/cert.pem" "$dst/chain.pem" "$dst/fullchain.pem"
    chmod 600 "$dst/privkey.pem"
REMOTE

  echo
  echo "=== 4/6 synow3tool --gen-all ==="
  ssh_nas "sudo $SYNOW3TOOL --gen-all"

  echo
  echo "=== 5/6 synow3tool --nginx=reload + --sync-enable ==="
  ssh_nas "sudo $SYNOW3TOOL --nginx=reload"
  ssh_nas "sudo $SYNOW3TOOL --sync-enable" || echo "(--sync-enable failed; benign if no custom sites changed)"

  echo
  echo "=== 6/6 verify ==="
  ssh_nas "sudo openssl x509 -in $DSM_ARCHIVE/$archive_id/cert.pem -noout -subject -dates" \
    | head -3
  case "$domain" in
    \**|*\**)
      # Wildcard: probe the most likely consumer.
      echo "(wildcard cert; probing s3.example.com as consumer)"
      echo | openssl s_client -connect s3.example.com:443 -servername s3.example.com 2>/dev/null \
        | openssl x509 -noout -subject -dates 2>&1 | head -3
      ;;
    *)
      echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null \
        | openssl x509 -noout -subject -dates 2>&1 | head -3
      ;;
  esac
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  renew)  shift; cmd_renew  "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *) die_usage ;;
esac
