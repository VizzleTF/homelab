#!/usr/bin/env bash
# Wrapper for the VictoriaMetrics stack (vmsingle/vmagent/vmalert/
# vmalertmanager/grafana in the `victoria-metrics` namespace).
#
# All actions hit each component's HTTP API via `kubectl exec wget` (logsql
# and silence delete: apiserver service proxy, since the VictoriaLogs image
# has no wget and busybox wget cannot DELETE) and parse the JSON locally
# with jq; no port-forward anywhere. Pod lookup always filters
# --field-selector status.phase=Running because deployments rotate replicas
# and the stale Succeeded pods are returned first by the default selector.
#
# Subcommands:
#   status                       components health + PVC + top metrics +
#                                vmagent up/down + vmalert firing count
#   alerts                       firing + pending alerts from vmalert,
#                                grouped by severity, with description
#   query    <promql> [--limit N] [--raw]   /api/v1/query against vmsingle
#   range    <promql> [--start 1h] [--end now] [--step 5m] [--limit N] [--raw]
#                                /api/v1/query_range against vmsingle
#   logsql   <query> [--limit 100] [--start 1h]   LogsQL against VictoriaLogs
#                                (/select/logsql/query via apiserver service
#                                proxy), JSONL output
#   rules    [errors]            list rule groups; `errors` filters to
#                                rules with lastError
#   targets  [job-filter]        scrape targets from vmagent; optional
#                                substring filter on job name
#   silence  <alertname> [dur]   POST /api/v2/silences to alertmanager,
#                                default duration 2h
#   silence  delete <silence-id> DELETE /api/v2/silence/<id> (service proxy)
#   logs     <component> [--tail N]  kubectl logs from the named component
#                                (vmsingle|vmagent|vmalert|alertmanager|
#                                 grafana)
#
# Skill that wraps this: managing-monitoring (all actions, plus
# the Alert→Memory triage matrix in its reference.md).
set -euo pipefail

VM_NS="${VM_NS:-victoria-metrics}"
AM_POD="${AM_POD:-vmalertmanager-victoria-metrics-k8s-stack-0}"
AM_CONTAINER="${AM_CONTAINER:-alertmanager}"
VL_NS="${VL_NS:-victoria-logs}"
VL_SVC="${VL_SVC:-victoria-logs-server:9428}"
AM_SVC="${AM_SVC:-vmalertmanager-victoria-metrics-k8s-stack:9093}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 status
  $0 alerts
  $0 query    <promql> [--limit N] [--raw]  (default limit 20, 0 = all; --raw = API JSON)
  $0 range    <promql> [--start 1h] [--end now] [--step 5m] [--limit N] [--raw]
                                          (times: 24h = ago, RFC3339 or unix)
  $0 logsql   <logsql> [--limit 100] [--start 1h]   (VictoriaLogs, JSONL; limit >= 1)
  $0 rules    [errors]
  $0 targets  [job-filter]
  $0 silence  <alertname> [duration]      (default duration: 2h)
  $0 silence  delete <silence-id>
  $0 logs     <component> [--tail N]      (component: vmsingle|vmagent|vmalert|alertmanager|grafana)

Env:
  VM_NS          VictoriaMetrics namespace (default: $VM_NS)
  AM_POD         Alertmanager pod (default: $AM_POD)
  AM_CONTAINER   Alertmanager container (default: $AM_CONTAINER)
  VL_NS          VictoriaLogs namespace (default: $VL_NS)
  VL_SVC         VictoriaLogs service:port (default: $VL_SVC)
  AM_SVC         Alertmanager service:port (default: $AM_SVC)
EOF
}

die_usage() { usage; exit 2; }
unknown_arg() { echo "unknown arg: $1" >&2; die_usage; }

# uri <string> → percent-encoded (RFC3339 "+03:00" must not become a space)
uri() { jq -rn --arg q "$1" '$q | @uri'; }

# need_int <flag> <value> [min] → exit 2 unless value is an integer >= min
need_int() {
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge "${3:-0}" ] \
    || { echo "$1 needs an integer >= ${3:-0}, got: $2" >&2; exit 2; }
}

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

# vm_get <path?query> → raw JSON from vmsingle's HTTP API
vm_get() {
  local vmsingle; vmsingle=$(pod_for vmsingle)
  kubectl -n "$VM_NS" exec "$vmsingle" -- wget -T 60 -qO- "http://127.0.0.1:8428$1" \
    || { echo "vmsingle rejected query (bad PromQL?)" >&2; exit 1; }
}

# print_series <limit> <raw> — format /api/v1/query{,_range} JSON from stdin.
# limit 0 = all series; raw=1 prints the API JSON untouched.
print_series() {
  if [ "$2" = 1 ]; then cat; return; fi
  jq -r --argjson n "$1" '(.data.result // []) as $r
    | (if $n > 0 then $r[:$n] else $r end) as $shown
    | def m: "\(.metric.__name__ // ""){\(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(", "))}";
      "Status: \(.status) | Results: \($r | length)",
      ($shown[] | if .values then "  \(m)", (.values[] | "    \(.[0] | floor | todate) \(.[1])")
                  else "  \(m) = \(.value[1])" end),
      if ($r | length) > ($shown | length) then "  ... and \(($r | length) - ($shown | length)) more (--limit 0 = all)" else empty end'
}

# rel_time <24h|RFC3339|unix> → VM-accepted time arg (bare duration = ago)
rel_time() {
  if [[ "$1" =~ ^[0-9]+[smhdw]$ ]]; then printf -- '-%s' "$1"; else printf '%s' "$1"; fi
}

cmd_query() {
  local promql="" limit=20 raw=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:?--limit requires N}"; shift 2 ;;
      --raw)   raw=1; shift ;;
      --*) unknown_arg "$1" ;;
      *) [ -z "$promql" ] || unknown_arg "$1"; promql="$1"; shift ;;
    esac
  done
  [ -n "$promql" ] || { echo "promql query required" >&2; die_usage; }
  need_int --limit "$limit"
  require kubectl
  require jq
  local json; json=$(vm_get "/api/v1/query?query=$(uri "$promql")")
  print_series "$limit" "$raw" <<<"$json"
}

cmd_range() {
  local promql="" start=1h end="" step=5m limit=20 raw=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --start) start="${2:?--start requires a time}"; shift 2 ;;
      --end)   end="${2:?--end requires a time}"; shift 2 ;;
      --step)  step="${2:?--step requires a duration}"; shift 2 ;;
      --limit) limit="${2:?--limit requires N}"; shift 2 ;;
      --raw)   raw=1; shift ;;
      --*) unknown_arg "$1" ;;
      *) [ -z "$promql" ] || unknown_arg "$1"; promql="$1"; shift ;;
    esac
  done
  [ -n "$promql" ] || { echo "promql query required" >&2; die_usage; }
  need_int --limit "$limit"
  require kubectl
  require jq
  local q json
  q="query=$(uri "$promql")&start=$(uri "$(rel_time "$start")")&step=$(uri "$step")"
  [ -z "$end" ] || [ "$end" = now ] || q+="&end=$(uri "$(rel_time "$end")")"
  json=$(vm_get "/api/v1/query_range?$q")
  print_series "$limit" "$raw" <<<"$json"
}

# VictoriaLogs image has no wget → go through the apiserver service proxy.
cmd_logsql() {
  local logsql="" limit=100 start=1h
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:?--limit requires N}"; shift 2 ;;
      --start) start="${2:?--start requires a time}"; shift 2 ;;
      --*) unknown_arg "$1" ;;
      *) [ -z "$logsql" ] || unknown_arg "$1"; logsql="$1"; shift ;;
    esac
  done
  [ -n "$logsql" ] || { echo "LogsQL query required" >&2; die_usage; }
  # VictoriaLogs treats limit=0 as unlimited (MBs per minute) — require >= 1.
  need_int --limit "$limit" 1
  require kubectl
  require jq
  kubectl get --request-timeout=60s --raw \
    "/api/v1/namespaces/$VL_NS/services/$VL_SVC/proxy/select/logsql/query?query=$(uri "$logsql")&limit=$(uri "$limit")&start=$(uri "$start")" \
    || { echo "VictoriaLogs rejected query (bad LogsQL?)" >&2; exit 1; }
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

# DELETE via the apiserver service proxy: busybox wget in the pod cannot.
cmd_silence_delete() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || { echo "silence id (UUID) required, got: ${id:-<empty>}" >&2; die_usage; }
  [ $# -eq 1 ] || unknown_arg "$2"
  require kubectl
  kubectl delete --request-timeout=60s --raw \
    "/api/v1/namespaces/$VM_NS/services/$AM_SVC/proxy/api/v2/silence/$id" \
    || { echo "alertmanager rejected delete (unknown silence id?)" >&2; exit 1; }
  echo "silence $id expired"
}

cmd_silence() {
  [ "${1:-}" = delete ] && { shift; cmd_silence_delete "$@"; return; }
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
  range)   shift; cmd_range   "$@" ;;
  logsql)  shift; cmd_logsql  "$@" ;;
  rules)   shift; cmd_rules   "$@" ;;
  targets) shift; cmd_targets "$@" ;;
  silence) shift; cmd_silence "$@" ;;
  logs)    shift; cmd_logs    "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *) die_usage ;;
esac
