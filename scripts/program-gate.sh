#!/usr/bin/env bash
# Completion gate for a program tracker (see .claude/skills/running-program).
#   program-gate.sh TRACKER.json...  list items that keep the program open; exit 1 if any
#   program-gate.sh --stop-hook      Stop hook (skill frontmatter): when the final message
#                                    claims the program is finished while a tracker in
#                                    docs/programs/ is open, send Claude back once with the list
#   program-gate.sh --selftest       fixtures below (CI: scripts/hooks-selfcheck.sh)
# Closed = done with evidence, dropped with why, deferred with owner_said; any
# other status (owner included) keeps the program open.
set -euo pipefail

# P-reaudit and P-sweep must exist, so an empty tracker or one without the
# re-audit and sweep steps can never print "0 open".
open_items() {
  jq -r '
    def blank: (. // "") | if type == "string" then test("^\\s*$") else length == 0 end;
    (["P-reaudit", "P-sweep"] - [.items[]?.id] | .[] | "\(.)\tmissing\tprocess item"),
    (.items[]? | select(
        (.status | IN("done", "dropped", "deferred") | not)
        or (.status == "done" and (.evidence | blank))
        or (.status == "dropped" and (.why | blank))
        or (.status == "deferred" and (.owner_said | blank)))
      | "\(.id)\t\(.status)\t\(.title)")' "$1"
}

gate() {
  local f out rc=0
  for f in "$@"; do
    out=$(open_items "$f" 2>/dev/null) || out="unreadable tracker (jq failed)"
    [[ -z $out ]] && continue
    printf '%s\n%s\n' "$f" "$out"
    rc=1
  done
  ((rc)) || echo "0 open"
  return "$rc"
}

# A finished-claim in the final message; "не закончена", "незаконченных" and
# "жду завершения" (waiting on a background task) are not one.
CLAIM='(?<!не)(?<!не )(закончен|заверш[её]н)[аоы]?(?![а-яё])|(?<!не)(?<!не )готов[оа](?![а-яё])|больше ничего не (висит|осталось)|оставшееся сделано|вс[её] сделано|program (is )?(done|complete|finished)'

stop_hook() {
  local in out
  in=$(cat)
  # stop_hook_active: already sent back once this stop, let it end (no loop).
  # Unparsable or empty input, or a missing jq: let the session stop. Compare the
  # output, not `jq -e`: jq 1.6 (CI) exits 0 on empty input.
  [[ $(jq --arg re "$CLAIM" '(.stop_hook_active | not)
    and ((.last_assistant_message // "") | test($re; "i"))' <<<"$in" 2>/dev/null) == true ]] || return 0
  shopt -s nullglob
  local trackers=("${CLAUDE_PROJECT_DIR:-.}"/docs/programs/*.json)
  ((${#trackers[@]})) || return 0
  out=$(gate "${trackers[@]}") && return 0
  jq -n --arg open "$out" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext:
    ("The program tracker is still open, so do not report it as finished:\n" + $open
     + "\nContinue with an independent item, or end with this list and the owner commands.")}}'
}

selftest() {
  local fail=0 out rc
  tmp=$(mktemp -d)  # global: the EXIT trap runs after this function returns
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp"/{open,closed,broken}/docs/programs "$tmp/none"
  cat >"$tmp/open/docs/programs/x.json" <<'EOF'
{"program":"x","plan":"docs/x.md","runs":[],"items":[
 {"id":"F1","title":"done ok","status":"done","verify":"v","evidence":"#900 abc"},
 {"id":"F2","title":"done no evidence","status":"done","verify":"v"},
 {"id":"Q8","title":"decision","status":"needs-decision","verify":"v"},
 {"id":"F3","title":"owner step","status":"owner","verify":"v","owner_cmd":"! tofu apply"},
 {"id":"F4","title":"deferred no quote","status":"deferred","verify":"v"},
 {"id":"F5","title":"Done wrong case","status":"Done","verify":"v","evidence":"x"},
 {"id":"F6","title":"dropped no why","status":"dropped","verify":"v"},
 {"id":"F7","title":"done empty evidence list","status":"done","verify":"v","evidence":[]},
 {"id":"P-reaudit","title":"re-audit","status":"todo","verify":"v"}]}
EOF
  cat >"$tmp/closed/docs/programs/y.json" <<'EOF'
{"program":"y","items":[
 {"id":"F1","title":"a","status":"done","verify":"v","evidence":"#1"},
 {"id":"F2","title":"b","status":"deferred","verify":"v","owner_said":"after 2026-10-21 (2026-10-14)"},
 {"id":"F3","title":"c","status":"dropped","verify":"v","why":"already fixed in #940"},
 {"id":"P-reaudit","title":"re-audit","status":"done","verify":"v","evidence":"run wf_x, 0 new"},
 {"id":"P-sweep","title":"sweep","status":"done","verify":"v","evidence":"inventory empty"}]}
EOF
  printf '{"program":"z"\n' >"$tmp/broken/docs/programs/z.json"
  printf '{"items":[]}\n' >"$tmp/empty.json"

  ok() { echo "ok   $1"; }
  bad() { echo "FAIL $1"; fail=1; }

  # Gate on tracker files.
  rc=0; out=$(bash "$0" "$tmp/open/docs/programs/x.json") || rc=$?
  local id
  for id in F2 Q8 F3 F4 F5 F6 F7 P-reaudit P-sweep; do
    grep -q "^$id"$'\t' <<<"$out" || bad "open tracker does not list $id"
  done
  grep -q '^F1'$'\t' <<<"$out" && bad "open tracker lists closed F1"
  [[ $rc -eq 1 ]] && ok "open tracker: exit 1, lists every open item" || bad "open tracker: exit $rc, want 1"
  rc=0; out=$(bash "$0" "$tmp/closed/docs/programs/y.json") || rc=$?
  [[ $rc -eq 0 && $out == "0 open" ]] && ok "closed tracker: 0 open" || bad "closed tracker: exit $rc, '$out'"
  rc=0; out=$(bash "$0" "$tmp/empty.json") || rc=$?
  [[ $rc -eq 1 && $out == *P-reaudit*P-sweep* ]] && ok "empty tracker: P-reaudit and P-sweep missing" || bad "empty tracker: exit $rc"
  rc=0; out=$(bash "$0" "$tmp/broken/docs/programs/z.json") || rc=$?
  [[ $rc -eq 1 && $out == *"unreadable tracker"* ]] && ok "broken JSON: unreadable tracker" || bad "broken JSON: exit $rc, '$out'"
  rc=0; bash "$0" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] && ok "no arguments: usage, exit 2" || bad "no arguments: exit $rc, want 2"

  # Stop hook on Claude Code's Stop input. want: "" = stays silent, else a substring of additionalContext.
  hook() {  # hook <project dir> <stop_hook_active> <last_assistant_message> <want> <what>
    local in
    in=$(jq -nc --arg m "$3" --argjson a "$2" '{session_id: "s", transcript_path: "/dev/null",
      cwd: "/", permission_mode: "auto", hook_event_name: "Stop", stop_hook_active: $a,
      last_assistant_message: $m, background_tasks: [], session_crons: []}')
    hook_raw "$1" "$in" "$4" "$5"
  }
  hook_raw() {  # hook_raw <project dir> <stdin> <want> <what>
    local rc=0 out
    out=$(CLAUDE_PROJECT_DIR=$1 bash "$0" --stop-hook <<<"$2" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then bad "stop hook: $4: exit $rc"
    elif [[ -z $3 ]]; then [[ -z $out ]] && ok "stop hook: $4: silent" || bad "stop hook: $4: printed '$out'"
    elif jq -e --arg w "$3" '.hookSpecificOutput.hookEventName == "Stop"
           and (.hookSpecificOutput.additionalContext | contains($w))' <<<"$out" >/dev/null 2>&1; then
      ok "stop hook: $4: sends Claude back"
    else bad "stop hook: $4: '$out'"
    fi
  }
  local claim="Программа закончена: все PR смёржены, больше ничего не висит."
  hook "$tmp/open" false "$claim" "Q8" "open tracker, finished claim"
  hook "$tmp/open" false "ПРОГРАММА ЗАВЕРШЕНА" "P-sweep" "open tracker, upper-case claim"
  hook "$tmp/open" false "The program is complete." "F3" "open tracker, English claim"
  hook "$tmp/open" false "Готово, всё в main." "F7" "open tracker, готово"
  hook "$tmp/open" false "Готовлю PR для F2, программа не готова." "" "готовлю / не готова is no claim"
  hook "$tmp/open" true "$claim" "" "stop_hook_active (sent back once already)"
  hook "$tmp/open" false "Программа не закончена: осталось 5 пунктов." "" "negated claim"
  hook "$tmp/open" false "Осталось 3 незаконченных пункта, дальше Q8." "" "незаконченных is no claim"
  hook "$tmp/open" false "Жду завершения воркфлоу wf_1, уведомление придёт само." "" "waiting for a background task"
  hook "$tmp/open" false "Волна 2: смёржены #901 и #902, дальше #903." "" "progress report"
  hook "$tmp/closed" false "$claim" "" "all items closed"
  hook "$tmp/none" false "$claim" "" "no docs/programs"
  hook "$tmp/broken" false "$claim" "unreadable tracker" "broken tracker JSON"
  hook_raw "$tmp/open" 'not json' "" "broken hook input"
  hook_raw "$tmp/open" '' "" "empty hook input"

  ((fail)) || echo "program-gate: clean"
  return "$fail"
}

case ${1:-} in
  --stop-hook) stop_hook ;;
  --selftest) selftest ;;
  "") echo "usage: program-gate.sh TRACKER.json... | --stop-hook | --selftest" >&2; exit 2 ;;
  *) gate "$@" ;;
esac
