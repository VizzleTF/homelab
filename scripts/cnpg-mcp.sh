#!/usr/bin/env bash
# Read-only Postgres MCP launcher for a CNPG cluster.
#
# Connects as a DEDICATED read-only login role (`mcp_ro`, granted the built-in
# pg_read_all_data) whose password lives in Vault — NOT the CNPG superuser.
# Establishes a kubectl port-forward to the cluster's `-ro` (replica) service,
# pulls the role password from Vault at runtime (nothing persisted to disk),
# then execs the MCP server bound to it.
#
# Defense in depth — writes are blocked three ways:
#   1. role has SELECT-only (pg_read_all_data), no INSERT/UPDATE/DDL grants
#   2. connection targets the `-ro` replica (physically read-only)
#   3. @modelcontextprotocol/server-postgres wraps every query in a READ ONLY txn
#
# One-time setup (see scripts/cnpg-mcp.README or the skill output):
#   psql as superuser:
#     CREATE ROLE mcp_ro LOGIN PASSWORD '<pw>';
#     GRANT pg_read_all_data TO mcp_ro;
#   vault kv put home/homelab/k8s/<ns>/mcp-ro username=mcp_ro password=<pw>
#
# Usage:  cnpg-mcp.sh <cluster>
#   cnpg    -> ns cnpg,   svc cnpg-cluster-ro    (nextcloud/authentik/forgejo)
#   immich  -> ns immich, svc immich-cluster-ro  (immich + vectorchord)
set -euo pipefail

CLUSTER="${1:-cnpg}"
case "$CLUSTER" in
  cnpg)   NS=cnpg;   SVC=cnpg-cluster-ro;  DBDEF=postgres ;;  # 3 instances → real replica
  immich) NS=immich; SVC=immich-cluster-r; DBDEF=immich ;;    # 1 instance → -ro has no endpoints; -r = any instance (writes still blocked by RO role + READ ONLY txn)
  *) echo "unknown cluster '$CLUSTER' (want: cnpg|immich)" >&2; exit 1 ;;
esac

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Read-only role creds from Vault (homelab convention: home/homelab/k8s/<ns>/<app>).
PGUSER="$(vault kv get -mount=home -field=username "homelab/k8s/${NS}/mcp-ro")"
PGPASS="$(vault kv get -mount=home -field=password "homelab/k8s/${NS}/mcp-ro")"
PGDB="${PGDATABASE:-$DBDEF}"

# Deterministic free local port per cluster to avoid collisions.
LPORT="$(( ( $$ % 20000 ) + 25000 ))"

kubectl -n "$NS" port-forward "svc/$SVC" "${LPORT}:5432" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# Wait for the forward to accept connections (max ~10s).
for _ in $(seq 1 50); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${LPORT}") 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 0.2
done

CONN="postgres://${PGUSER}:${PGPASS}@127.0.0.1:${LPORT}/${PGDB}?sslmode=disable"
exec npx -y @modelcontextprotocol/server-postgres "$CONN"
