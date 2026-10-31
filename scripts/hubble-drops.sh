#!/usr/bin/env bash
# Show policy drops (POLICY_DENIED) from every cilium agent, prefixed by node.
# Skill: managing-network-policy. Alert: CiliumPolicyDenied (argocd/infra/cilium/manifests/vmrule.yaml).
#
# Hubble Relay is off, so each agent sees only its own node: this loops over
# all agents instead of picking one. Read-only (kubectl exec hubble observe).
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage:
  $0 [--since 15m] [hubble filter...]       buffered drops per node (--since: s/m/h only)
  $0 --follow 60 [hubble filter...]         stream new drops from all nodes for N seconds
Filters go to 'hubble observe' as is, e.g. --to-namespace cnpg --from-namespace immich --port 5432
EOF
  exit 2
}

SINCE=15m FOLLOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:?}"; shift 2 ;;
    --follow) FOLLOW="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done
case "$FOLLOW" in ''|*[!0-9]*) [ -z "$FOLLOW" ] || usage ;; esac

AGENTS=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}={.spec.nodeName}{"\n"}{end}')
[ -n "$AGENTS" ] || { echo "no running cilium agents" >&2; exit 1; }

observe() { # $1=agent $2=node, rest = hubble args
  local agent=$1 node=$2; shift 2
  kubectl -n kube-system exec "$agent" -c cilium-agent -- \
    hubble observe --verdict DROPPED --drop-reason-desc POLICY_DENIED -o compact "$@" 2>&1 \
    | sed "s/^/[$node] /"
}

if [ -n "$FOLLOW" ]; then
  # timeout per agent; the stream never ends on its own
  for a in $AGENTS; do
    timeout "$FOLLOW" bash -c "$(declare -f observe); observe \"\$@\"" _ "${a%%=*}" "${a#*=}" -f "$@" &
  done
  wait || true
else
  for a in $AGENTS; do
    oldest=$(kubectl -n kube-system exec "${a%%=*}" -c cilium-agent -- hubble observe --first 1 -o jsonpb 2>/dev/null \
      | sed -n 's/.*"time":"\([^"]*\)".*/\1/p' | head -1)
    echo "== ${a#*=} (${a%%=*}), buffer since ${oldest:-?}"
    observe "${a%%=*}" "${a#*=}" --since "$SINCE" "$@"
  done
fi
