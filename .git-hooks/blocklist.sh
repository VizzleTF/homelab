#!/usr/bin/env bash
# Filename blocklist — must mirror the step in .forgejo/workflows/gitleaks.yaml.
# Fails fast if any tracked file matches a known sensitive name pattern.
set -euo pipefail

PATTERNS='(^|/)((id_rsa.*)|.*\.(pem|key|pfx|p12|crt|kubeconfig)|kubeconfig.*|\.env(\..+)?|vault_secrets_backup.*|vault-unseal.*|.*shamir.*|terraform\.tfstate.*|terraform\.tfvars)$'
ALLOW='(\.example|\.sample)$'

if MATCHES=$(git ls-files | grep -E "$PATTERNS" | grep -Ev "$ALLOW" || true); [ -n "$MATCHES" ]; then
  echo "Blocked filename(s) detected:" >&2
  echo "$MATCHES" >&2
  exit 1
fi
