#!/usr/bin/env bash
# Wrapper for the VictoriaMetrics stack (vmsingle/vmagent/vmalert/
# vmalertmanager/grafana in the `victoria-metrics` namespace).
#
# All actions hit each component's HTTP API via `kubectl exec wget` and
# parse the JSON locally with jq. Pod lookup always filters --field-selector
# status.phase=Running because deployments rotate replicas and the stale
# Succeeded pods are returned first by the default selector.
#
# Subcommands:
#   status                       components health + PVC + top metrics +
#                                vmagent up/down + vmalert firing count
#   alerts                       firing + pending alerts from vmalert,
#                                grouped by severity, with description
#   query    <promql>            run /api/v1/query against vmsingle
#   rules    [errors]            list rule groups; `errors` filters to
#                                rules with lastError
#   targets  [job-filter]        scrape targets from vmagent; optional
#                                substring filter on job name
#   silence  <alertname> [dur]   POST /api/v2/silences to alertmanager,
#                                default duration 2h
#   logs     <component> [-n N]  kubectl logs from the named component
#                                (vmsingle|vmagent|vmalert|alertmanager|
#                                 grafana)
#
# Skills that wrap this: managing-victoria-metrics (all actions),
# triaging-alerts (alerts + Alert→Memory triage matrix).
set -euo pipefail

VM_NS="${VM_NS:-victoria-metrics}"
AM_POD="${AM_POD:-vmalertmanager-victoria-metrics-k8s-stack-0}"
AM_CONTAINER="${AM_CONTAINER:-alertmanager}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 status
  $0 alerts
  $0 query    <promql>
  $0 rules    [errors]
  $0 targets  [job-filter]
  $0 silence  <alertname> [duration]      (default duration: 2h)
  $0 logs     <component> [--tail N]      (component: vmsingle|vmagent|vmalert|alertmanager|grafana)

Env:
  VM_NS          VictoriaMetrics namespace (default: $VM_NS)
  AM_POD         Alertmanager pod (default: $AM_POD)
  AM_CONTAINER   Alertmanager container (default: $AM_CONTAINER)
EOF
}

die_usage() { usage; exit 2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}

# pod_for <app-label-name>  → first Running pod for that label
pod_for() {
  local app="$1" out
  out=$(kubectl -n "$VM_NS" get pod \
    -l "app.kubernetes.io/name=$app" \
    --field-selector status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
  if [ -z "$out" ]; then
    echo "no Running pod found for app.kubernetes.io/name=$app in $VM_NS" >&2
    return 1
  fi
  printf '%s' "$out"
}

cmd_status() {
  require kubectl
  require jq

  echo "=== pods ==="
  kubectl -n "$VM_NS" get pod \
    -l 'app.kubernetes.io/instance=victoria-metrics-k8s-stack' \
    -o wide --no-headers 2>/dev/null \
    | awk '{printf "  %-60s  %-6s  %-10s  restarts=%-3s  age=%s\n", $1, $2, $3, $4, $5}' \
    | head -20

  echo
  echo "=== PVCs ==="
  kubectl -n "$VM_NS" get pvc --no-headers 2>/dev/null \
    | awk '{printf "  %-50s  %-6s  %-10s  %s\n", $1, $2, $3, $4}'

  local vmsingle vmagent vmalert
  vmsingle=$(pod_for vmsingle)
  vmagent=$(pod_for vmagent)
  vmalert=$(pod_for vmalert)

  echo
  echo "=== VMSingle ==="
  kubectl -n "$VM_NS" exec "$vmsingle" -- wget -qO- 'http://127.0.0.1:8428/-/healthy' 2>/dev/null \
    | sed 's/^/  /'
  kubectl -n "$VM_NS" exec "$vmsingle" -- wget -qO- 'http://127.0.0.1:8428/api/v1/status/tsdb?topN=5' 2>/dev/null \
    | jq -r '"  Top metrics by series:", (.data.seriesCountByMetricName // [] | .[:5][] | "    \(.name): \(.value)")'

  echo
  echo "=== VMAgent targets ==="
  kubectl -n "$VM_NS" exec "$vmagent" -c vmagent -- wget -qO- 'http://127.0.0.1:8429/api/v1/targets' 2>/dev/null \
    | jq -r '.data.activeTargets // [] | map(select(.health != "up")) as $down
      | "  Targets: \(length) total | \(length - ($down | length)) up | \($down | length) down",
        if ($down | length) > 0 then "  DOWN:" else empty end,
        ($down[] | "    \(.labels.job // "?") / \(.labels.instance // "?"): \((.lastError // "")[:100])")'

  echo
  echo "=== VMAlert ==="
  kubectl -n "$VM_NS" exec "$vmalert" -c vmalert -- \
    wget -qO- 'http://vmalert-victoria-metrics-k8s-stack.victoria-metrics.svc:8080/api/v1/alerts' 2>/dev/null \
    | jq -r '.data.alerts // [] | "  Alerts: \(length) total | \(map(select(.state == "firing")) | length) firing | \(map(select(.state == "pending")) | length) pending"'
}

cmd_alerts() {
  require kubectl
  require jq
  local vmalert; vmalert=$(pod_for vmalert)

  kubectl -n "$VM_NS" exec "$vmalert" -c vmalert -- \
    wget -qO- 'http://vmalert-victoria-metrics-k8s-stack.victoria-metrics.svc:8080/api/v1/alerts' 2>/dev/null \
    | jq -r '
      def sorted: sort_by([({critical: 0, warning: 1, info: 2}[.labels.severity // "z"] // 9), (.name // "")]);
      (.data.alerts // []) as $all
      | ($all | map(select(.state == "firing")) | sorted) as $firing
      | ($all | map(select(.state == "pending")) | sorted) as $pending
      | "Total: \($all | length) | Firing: \($firing | length) | Pending: \($pending | length)",
        if ($firing | length) > 0 then "", "=== FIRING ===" else empty end,
        ($firing[]
          | "  [\(.labels.severity // "?")] \(.name // "?") ns=\(.labels.namespace // "?")\(if (.labels.pod // "") != "" then " pod=\(.labels.pod)" else "" end)",
            ((.annotations.description // "")[:120] | select(. != "") | "    \(.)")),
        if ($pending | length) > 0 then "", "=== PENDING ===" else empty end,
        ($pending[] | "  [\(.labels.severity // "?")] \(.name // "?") ns=\(.labels.namespace // "?")")'
}

cmd_query() {
  local promql="${1:-}"
  [ -n "$promql" ] || { echo "promql query required" >&2; die_usage; }
  require kubectl
  require jq
  local vmsingle; vmsingle=$(pod_for vmsingle)
  local encoded
  encoded=$(jq -rn --arg q "$promql" '$q | @uri')
  kubectl -n "$VM_NS" exec "$vmsingle" -- \
    wget -qO- "http://127.0.0.1:8428/api/v1/query?query=${encoded}" 2>/dev/null \
    | jq -r '(.data.result // []) as $r
      | "Status: \(.status) | Results: \($r | length)",
        ($r[:20][] | "  \(.metric.__name__ // ""){\(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(", "))} = \(.value[1])"),
        if ($r | length) > 20 then "  ... and \(($r | length) - 20) more" else empty end'
}

cmd_rules() {
  local errors_only="${1:-}"
  require kubectl
  require jq
  local vmalert; vmalert=$(pod_for vmalert)
  kubectl -n "$VM_NS" exec "$vmalert" -c vmalert -- \
    wget -qO- 'http://vmalert-victoria-metrics-k8s-stack.victoria-metrics.svc:8080/api/v1/rules' 2>/dev/null \
    | jq -r --arg mode "$errors_only" '(.data.groups // []) as $g
      | [$g[] | .name as $gn | .rules[]? | select((.lastError // "") != "") | {g: ($gn // "?"), r: (.name // "?"), e: .lastError[:120]}] as $errs
      | "Groups: \($g | length) | Rules: \([$g[].rules[]?] | length) | Errors: \($errs | length)",
        if ($errs | length) > 0 then "", "=== RULES WITH ERRORS ===", ($errs[] | "  [\(.g)] \(.r)", "    \(.e)")
        elif $mode == "errors" then "", "No rule errors."
        else "", ($g[] | "  \(.name // "?") (\(.rules // [] | length) rules)")
        end'
}

cmd_targets() {
  local filter="${1:-}"
  require kubectl
  require jq
  local vmagent; vmagent=$(pod_for vmagent)
  kubectl -n "$VM_NS" exec "$vmagent" -c vmagent -- \
    wget -qO- 'http://127.0.0.1:8429/api/v1/targets' 2>/dev/null \
    | jq -r --arg f "$filter" '(.data.activeTargets // [])
      | map(select(($f == "") or ((.labels.job // "") | ascii_downcase | contains($f | ascii_downcase)))) as $t
      | ($t | map(select(.health == "up"))) as $up
      | ($t | map(select(.health != "up"))) as $down
      | "Targets: \($t | length) | Up: \($up | length) | Down: \($down | length)",
        if ($down | length) > 0 then "", "=== DOWN ===" else empty end,
        ($down[] | "  \(.labels.job // "?") / \(.labels.instance // "?")",
          ((.lastError // "")[:120] | select(. != "") | "    Error: \(.)")),
        "", "=== UP (by job) ===",
        ($up | group_by(.labels.job // "?")[] | "  \(.[0].labels.job // "?"): \(length) target(s)")'
}

cmd_silence() {
  local alertname="${1:-}" duration="${2:-2h}"
  [ -n "$alertname" ] || { echo "alertname required" >&2; die_usage; }
  case "$duration" in
    *h|*m) : ;;
    *) echo "duration must end in h or m (e.g. 2h, 30m)" >&2; exit 2 ;;
  esac
  require kubectl
  require jq

  echo "=== Active alerts matching $alertname ==="
  kubectl -n "$VM_NS" exec "$AM_POD" -c "$AM_CONTAINER" -- \
    wget -qO- 'http://127.0.0.1:9093/api/v2/alerts' 2>/dev/null \
    | jq -r --arg n "$alertname" 'map(select(.labels.alertname == $n))
      | "  matched=\(length)", (.[] | "    ns=\(.labels.namespace // "") pod=\(.labels.pod // "")")'

  echo
  echo "=== Creating silence ($duration) ==="
  local body
  local unit=60; [ "${duration: -1}" = h ] && unit=3600
  body=$(jq -cn --arg n "$alertname" --arg d "$duration" --argjson s "$(( ${duration%?} * unit ))" '
    "%Y-%m-%dT%H:%M:%S.000Z" as $fmt | now | floor as $now
    | {matchers: [{name: "alertname", value: $n, isRegex: false}],
       startsAt: ($now | strftime($fmt)), endsAt: ($now + $s | strftime($fmt)),
       createdBy: "scripts/vm.sh", comment: "Silenced via vm.sh (\($d))"}')

  kubectl -n "$VM_NS" exec -i "$AM_POD" -c "$AM_CONTAINER" -- \
    wget -qO- --post-data="$body" \
    --header='Content-Type: application/json' \
    'http://127.0.0.1:9093/api/v2/silences' 2>/dev/null
  echo
}

cmd_logs() {
  local component="${1:-}"
  [ -n "$component" ] || { echo "component required" >&2; die_usage; }
  shift
  local tail=100
  while [ $# -gt 0 ]; do
    case "$1" in
      --tail) tail="${2:?--tail requires N}"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; die_usage ;;
    esac
  done

  local label container
  case "$component" in
    vmsingle)      label=vmsingle;       container=vmsingle ;;
    vmagent)       label=vmagent;        container=vmagent ;;
    vmalert)       label=vmalert;        container=vmalert ;;
    alertmanager)  label=vmalertmanager; container=alertmanager ;;
    grafana)       label=grafana;        container=grafana ;;
    *) echo "unknown component: $component (use vmsingle|vmagent|vmalert|alertmanager|grafana)" >&2; exit 2 ;;
  esac
  require kubectl
  local pod; pod=$(pod_for "$label")
  kubectl -n "$VM_NS" logs "$pod" -c "$container" --tail="$tail"
}

case "${1:-}" in
  status)  shift; cmd_status  "$@" ;;
  alerts)  shift; cmd_alerts  "$@" ;;
  query)   shift; cmd_query   "$@" ;;
  rules)   shift; cmd_rules   "$@" ;;
  targets) shift; cmd_targets "$@" ;;
  silence) shift; cmd_silence "$@" ;;
  logs)    shift; cmd_logs    "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *) die_usage ;;
esac
