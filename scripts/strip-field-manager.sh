#!/usr/bin/env bash
# Remove one field manager's entry from metadata.managedFields.
#
# Why: server-side apply keeps a field for as long as any manager owns it.
# Resources bootstrapped with `helm` (operation Apply) still list it next to
# argocd-controller, so a field dropped from values stays in the cluster.
# ArgoCD's ClientSideApplyMigration only moves Update-operation managers, so
# Apply-operation leftovers have to be removed by hand.
# Plan and batches: docs/helm-managedfields-cleanup.md
#
# Only metadata.managedFields is patched: generation does not change and no
# pod is restarted. Fields owned by nobody else become unowned and stay as-is.
#
# Usage:
#   scripts/strip-field-manager.sh [--dry-run] [--backup-dir DIR] <manager> app <app> [<app> ...]
#   scripts/strip-field-manager.sh [--dry-run] [--backup-dir DIR] <manager> crds [<name-regex>]
#
#   app   objects from the ArgoCD Application's status.resources
#   crds  CustomResourceDefinitions (optionally filtered by name regex)
#
# Every entry is saved to BACKUP_DIR before patching
# (default: ~/.cache/strip-field-manager/<utc timestamp>).
set -euo pipefail

DRY_RUN=0
BACKUP_DIR="${HOME}/.cache/strip-field-manager/$(date -u +%Y%m%dT%H%M%SZ)"

usage() { sed -n '14,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --backup-dir) BACKUP_DIR="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; usage ;;
    *) break ;;
  esac
done

[ "$#" -ge 2 ] || usage
MANAGER="$1"; MODE="$2"; shift 2
case "$MANAGER" in
  argocd-controller|kube-controller-manager|kube-apiserver)
    echo "refusing to strip $MANAGER: it is an active owner" >&2; exit 2 ;;
esac

command -v kubectl >/dev/null || { echo "kubectl not in PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not in PATH" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Prints "<kubectl resource ref>|<namespace or empty>|<name>|<label>" per object.
list_objects() {
  case "$MODE" in
    app)
      [ "$#" -ge 1 ] || usage
      for app in "$@"; do
        kubectl -n argocd get application "$app" -o json | python3 -c '
import json, sys
app = sys.argv[1]
for r in json.load(sys.stdin).get("status", {}).get("resources", []):
    ref = r["kind"].lower() + ("." + r["group"] if r.get("group") else "")
    print("%s|%s|%s|%s" % (ref, r.get("namespace", ""), r["name"], app))
' "$app"
      done ;;
    crds)
      kubectl get crd -o json | python3 -c '
import json, re, sys
rx = re.compile(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else None
for o in json.load(sys.stdin)["items"]:
    n = o["metadata"]["name"]
    if rx is None or rx.search(n):
        print("customresourcedefinition.apiextensions.k8s.io||%s|crds" % n)
' "${1:-}" ;;
    *) usage ;;
  esac
}

# Reads an object's JSON on stdin. Prints: indices|generation|unowned count|unowned sample
analyze() {
  python3 -c '
import json, sys
mgr = sys.argv[1]
o = json.load(sys.stdin)
mf = o["metadata"].get("managedFields") or []

def paths(fv, pre=()):
    out = set()
    for k, v in (fv or {}).items():
        if k == ".":
            continue
        p = pre + (k,)
        if isinstance(v, dict) and v:
            sub = paths(v, p)
            out |= sub if sub else {p}
        else:
            out.add(p)
    return out

idx = [i for i, m in enumerate(mf) if m["manager"] == mgr and not m.get("subresource")]
mine, others = set(), set()
for i, m in enumerate(mf):
    if m.get("subresource"):
        continue
    (mine if i in idx else others).update(paths(m.get("fieldsV1")))
unowned = sorted("/".join(p).replace("f:", "") for p in mine - others)
print("%s|%s|%d|%s" % (",".join(map(str, idx)), o["metadata"].get("generation", 0),
                       len(unowned), " ".join(unowned[:4])))
' "$MANAGER"
}

total=0; found=0; patched=0; failed=0; unowned_total=0
if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN: nothing will be patched"
else
  mkdir -p "$BACKUP_DIR"
fi

while IFS='|' read -r ref ns name label; do
  total=$((total + 1))
  nsarg=(); [ -n "$ns" ] && nsarg=(-n "$ns")
  id="$ref ${ns:+$ns/}$name"
  obj="$TMP/obj.json"
  if ! kubectl get "$ref" "$name" "${nsarg[@]}" --show-managed-fields -o json >"$obj" 2>"$TMP/err"; then
    echo "SKIP  $id: $(head -c 160 "$TMP/err")"; continue
  fi
  IFS='|' read -r idx gen unowned sample < <(analyze <"$obj")
  [ -n "$idx" ] || continue
  found=$((found + 1)); unowned_total=$((unowned_total + unowned))
  note=""; [ "$unowned" -gt 0 ] && note=" (becomes unowned: $unowned — $sample)"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "WOULD $id [$label] entries=$idx$note"; continue
  fi

  mkdir -p "$BACKUP_DIR/$label"
  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["metadata"]["managedFields"], sys.stdout, indent=1)' \
    "$obj" >"$BACKUP_DIR/$label/${ref%%.*}_${ns:-cluster}_${name//[:\/]/_}.json"

  # test+remove per entry, highest index first so earlier indices stay valid.
  patch=$(python3 -c '
import json, sys
mgr, idx = sys.argv[1], sorted(map(int, sys.argv[2].split(",")), reverse=True)
ops = []
for i in idx:
    ops += [{"op": "test", "path": "/metadata/managedFields/%d/manager" % i, "value": mgr},
            {"op": "remove", "path": "/metadata/managedFields/%d" % i}]
print(json.dumps(ops))
' "$MANAGER" "$idx")

  if kubectl patch "$ref" "$name" "${nsarg[@]}" --type=json -p "$patch" >/dev/null 2>"$TMP/err"; then
    after=$(kubectl get "$ref" "$name" "${nsarg[@]}" -o jsonpath='{.metadata.generation}')
    if [ "${after:-0}" != "$gen" ]; then
      echo "WARN  $id: generation changed $gen -> $after"
    fi
    patched=$((patched + 1)); echo "DONE  $id [$label]$note"
  else
    failed=$((failed + 1)); echo "FAIL  $id: $(head -c 200 "$TMP/err")"
  fi
done < <(list_objects "$@")

echo "---"
echo "objects checked: $total, with $MANAGER entry: $found, patched: $patched, failed: $failed, fields becoming unowned: $unowned_total"
[ "$DRY_RUN" -eq 1 ] || echo "backup: $BACKUP_DIR"
[ "$failed" -eq 0 ]
