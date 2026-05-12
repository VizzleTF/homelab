#!/usr/bin/env bash
# Wrapper for the VictoriaMetrics stack (vmsingle/vmagent/vmalert/
# vmalertmanager/grafana in the `victoria-metrics` namespace).
#
# All actions hit each component's HTTP API via `kubectl exec wget` and
# parse JSON with inline python3 heredocs (python3 is present in every
# VM-stack image). Pod lookup always filters --field-selector
# status.phase=Running because deployments rotate replicas and the stale
# Succeeded pods are returned first by the default selector.
#
# Python heredoc style: this file uses `python3 -c '...'` (single-quoted
# bash heredoc), so the Python code MUST NOT contain any literal single
# quotes. All Python strings use double quotes; dict access is hoisted
# into named variables before f-string interpolation.
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
  require python3

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
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
top = d.get("data", {}).get("seriesCountByMetricName", [])[:5]
print("  Top metrics by series:")
for m in top:
    name = m["name"]
    val = m["value"]
    print(f"    {name}: {val}")
'

  echo
  echo "=== VMAgent targets ==="
  kubectl -n "$VM_NS" exec "$vmagent" -c vmagent -- wget -qO- 'http://127.0.0.1:8429/api/v1/targets' 2>/dev/null \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
active = d.get("data", {}).get("activeTargets", [])
up = sum(1 for t in active if t.get("health") == "up")
down = sum(1 for t in active if t.get("health") != "up")
print(f"  Targets: {len(active)} total | {up} up | {down} down")
if down:
    print("  DOWN:")
    for t in active:
        if t.get("health") != "up":
            labels = t.get("labels", {})
            job = labels.get("job", "?")
            inst = labels.get("instance", "?")
            err = (t.get("lastError") or "")[:100]
            print(f"    {job} / {inst}: {err}")
'

  echo
  echo "=== VMAlert ==="
  kubectl -n "$VM_NS" exec "$vmalert" -c vmalert -- \
    wget -qO- 'http://vmalert-victoria-metrics-k8s-stack.victoria-metrics.svc:8080/api/v1/alerts' 2>/dev/null \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
alerts = d.get("data", {}).get("alerts", [])
firing = sum(1 for a in alerts if a["state"] == "firing")
pending = sum(1 for a in alerts if a["state"] == "pending")
print(f"  Alerts: {len(alerts)} total | {firing} firing | {pending} pending")
'
}

cmd_alerts() {
  require kubectl
  require python3
  local vmalert; vmalert=$(pod_for vmalert)

  kubectl -n "$VM_NS" exec "$vmalert" -c vmalert -- \
    wget -qO- 'http://vmalert-victoria-metrics-k8s-stack.victoria-metrics.svc:8080/api/v1/alerts' 2>/dev/null \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
alerts = d.get("data", {}).get("alerts", [])
firing = [a for a in alerts if a["state"] == "firing"]
pending = [a for a in alerts if a["state"] == "pending"]
print(f"Total: {len(alerts)} | Firing: {len(firing)} | Pending: {len(pending)}")
SEV_ORDER = {"critical": 0, "warning": 1, "info": 2}
def keyfn(a):
    return (SEV_ORDER.get(a["labels"].get("severity", "z"), 9), a.get("name", ""))
if firing:
    print()
    print("=== FIRING ===")
    for a in sorted(firing, key=keyfn):
        labels = a["labels"]
        name = a.get("name", "?")
        ns = labels.get("namespace", "?")
        pod = labels.get("pod", "")
        sev = labels.get("severity", "?")
        desc = (a.get("annotations", {}).get("description") or "")[:120]
        line = f"  [{sev}] {name} ns={ns}"
        if pod:
            line += f" pod={pod}"
        print(line)
        if desc:
            print(f"    {desc}")
if pending:
    print()
    print("=== PENDING ===")
    for a in sorted(pending, key=keyfn):
        labels = a["labels"]
        name = a.get("name", "?")
        ns = labels.get("namespace", "?")
        sev = labels.get("severity", "?")
        print(f"  [{sev}] {name} ns={ns}")
'
}

cmd_query() {
  local promql="${1:-}"
  [ -n "$promql" ] || { echo "promql query required" >&2; die_usage; }
  require kubectl
  require python3
  local vmsingle; vmsingle=$(pod_for vmsingle)
  local encoded
  encoded=$(python3 -c '
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
' "$promql")
  kubectl -n "$VM_NS" exec "$vmsingle" -- \
    wget -qO- "http://127.0.0.1:8428/api/v1/query?query=${encoded}" 2>/dev/null \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
status = d.get("status")
results = d.get("data", {}).get("result", [])
print(f"Status: {status} | Results: {len(results)}")
for r in results[:20]:
    metric = r.get("metric", {})
    val = (r.get("value") or [None, None])[1]
    name = metric.get("__name__", "")
    labels = ", ".join(f"{k}={v}" for k, v in metric.items() if k != "__name__")
    print(f"  {name}{{{labels}}} = {val}")
if len(results) > 20:
    extra = len(results) - 20
    print(f"  ... and {extra} more")
'
}

cmd_rules() {
  local errors_only="${1:-}"
  require kubectl
  require python3
  local vmalert; vmalert=$(pod_for vmalert)
  kubectl -n "$VM_NS" exec "$vmalert" -c vmalert -- \
    wget -qO- 'http://vmalert-victoria-metrics-k8s-stack.victoria-metrics.svc:8080/api/v1/rules' 2>/dev/null \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
groups = d.get("data", {}).get("groups", [])
errors_only = sys.argv[1] == "errors" if len(sys.argv) > 1 else False
total = 0
errs = []
for g in groups:
    for r in g.get("rules", []):
        total += 1
        if r.get("lastError"):
            gname = g.get("name", "?")
            rname = r.get("name", "?")
            errs.append((gname, rname, r["lastError"][:120]))
print(f"Groups: {len(groups)} | Rules: {total} | Errors: {len(errs)}")
if errs:
    print()
    print("=== RULES WITH ERRORS ===")
    for gname, rname, err in errs:
        print(f"  [{gname}] {rname}")
        print(f"    {err}")
elif errors_only:
    print()
    print("No rule errors.")
else:
    print()
    for g in groups:
        gname = g.get("name", "?")
        rcount = len(g.get("rules", []))
        print(f"  {gname} ({rcount} rules)")
' "$errors_only"
}

cmd_targets() {
  local filter="${1:-}"
  require kubectl
  require python3
  local vmagent; vmagent=$(pod_for vmagent)
  kubectl -n "$VM_NS" exec "$vmagent" -c vmagent -- \
    wget -qO- 'http://127.0.0.1:8429/api/v1/targets' 2>/dev/null \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
active = d.get("data", {}).get("activeTargets", [])
flt = sys.argv[1].lower() if len(sys.argv) > 1 and sys.argv[1] else ""
if flt:
    active = [t for t in active if flt in t.get("labels", {}).get("job", "").lower()]
up = [t for t in active if t.get("health") == "up"]
down = [t for t in active if t.get("health") != "up"]
print(f"Targets: {len(active)} | Up: {len(up)} | Down: {len(down)}")
if down:
    print()
    print("=== DOWN ===")
    for t in down:
        labels = t.get("labels", {})
        job = labels.get("job", "?")
        inst = labels.get("instance", "?")
        err = (t.get("lastError") or "")[:120]
        print(f"  {job} / {inst}")
        if err:
            print(f"    Error: {err}")
print()
print("=== UP (by job) ===")
by_job = {}
for t in up:
    job = t.get("labels", {}).get("job", "?")
    by_job[job] = by_job.get(job, 0) + 1
for job, cnt in sorted(by_job.items()):
    print(f"  {job}: {cnt} target(s)")
' "$filter"
}

cmd_silence() {
  local alertname="${1:-}" duration="${2:-2h}"
  [ -n "$alertname" ] || { echo "alertname required" >&2; die_usage; }
  case "$duration" in
    *h|*m) : ;;
    *) echo "duration must end in h or m (e.g. 2h, 30m)" >&2; exit 2 ;;
  esac
  require kubectl
  require python3

  echo "=== Active alerts matching $alertname ==="
  kubectl -n "$VM_NS" exec "$AM_POD" -c "$AM_CONTAINER" -- \
    wget -qO- 'http://127.0.0.1:9093/api/v2/alerts' 2>/dev/null \
    | python3 -c '
import sys, json
alerts = json.load(sys.stdin)
name = sys.argv[1]
matched = [a for a in alerts if a.get("labels", {}).get("alertname") == name]
print(f"  matched={len(matched)}")
for a in matched:
    labels = a.get("labels", {})
    ns = labels.get("namespace", "")
    pod = labels.get("pod", "")
    print(f"    ns={ns} pod={pod}")
' "$alertname"

  echo
  echo "=== Creating silence ($duration) ==="
  local body
  body=$(python3 -c '
import sys, json
from datetime import datetime, timedelta, timezone
alertname, duration = sys.argv[1], sys.argv[2]
amount = int(duration[:-1])
unit = duration[-1]
delta = timedelta(hours=amount) if unit == "h" else timedelta(minutes=amount)
now = datetime.now(timezone.utc)
end = now + delta
fmt = "%Y-%m-%dT%H:%M:%S.000Z"
body = {
    "matchers": [{"name": "alertname", "value": alertname, "isRegex": False}],
    "startsAt": now.strftime(fmt),
    "endsAt": end.strftime(fmt),
    "createdBy": "scripts/vm.sh",
    "comment": f"Silenced via vm.sh ({duration})",
}
print(json.dumps(body))
' "$alertname" "$duration")

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
