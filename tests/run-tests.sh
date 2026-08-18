#!/usr/bin/env bash
# Offline test suite: runs against a local fake API, never touches the real one
# and never touches your real $HOME.
set -uo pipefail
PLUGIN=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; [[ -n ${SRV:-} ]] && kill "$SRV" 2>/dev/null' EXIT
SB=$TMP/home; mkdir -p "$SB/.claude"
PORT=${PORT:-8899}
pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if [[ $2 == "$3" ]]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }

echo '{"claudeAiOauth":{"accessToken":"test-token"}}' > "$SB/.claude/.credentials.json"
echo 'PS1="\u:\w\$ "' > "$SB/.bashrc"

python3 - "$PORT" <<'PY' &
import http.server, json, sys, os
COUNT = 0; MODE = "ok"
STATE = "/tmp/claude-usage-test-mode"
def body():
    return json.dumps({"limits":[
      {"kind":"session","percent":7,"severity":"normal","resets_at":"2026-08-18T12:00:00+00:00","scope":None},
      {"kind":"weekly_all","percent":24,"severity":"normal","resets_at":"2026-08-21T11:00:00+00:00","scope":None},
      {"kind":"weekly_scoped","percent":55,"severity":"warning","resets_at":None,
       "scope":{"model":{"display_name":"Opus"}}}]}).encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global COUNT
        if self.path == "/count":
            b=str(COUNT).encode(); self.send_response(200)
            self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b); return
        COUNT += 1
        mode = open(STATE).read().strip() if os.path.exists(STATE) else "ok"
        if mode in ("401","429","500"):
            self.send_response(int(mode)); self.send_header("Content-Length","0"); self.end_headers(); return
        if mode == "garbage":
            b=b"<html>not json</html>"; self.send_response(200)
            self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b); return
        b=body(); self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
SRV=$!
MODE=/tmp/claude-usage-test-mode
echo ok > "$MODE"
for _ in $(seq 1 50); do curl -s -m 1 "http://127.0.0.1:$PORT/count" >/dev/null 2>&1 && break; done

export CLAUDE_USAGE_API="http://127.0.0.1:$PORT/usage"
CU=$SB/.local/bin/claude-usage
run() { env HOME="$SB" CLAUDE_USAGE_API="$CLAUDE_USAGE_API" "$@"; }
count() { curl -s -m 2 "http://127.0.0.1:$PORT/count"; }

echo; echo "install"
run bash "$PLUGIN/scripts/install.sh" --no-scheduler >/dev/null 2>&1
[[ -x $CU ]] && ok "bin symlink created" || no "bin symlink created"
grep -q 'claude-usage.bash' "$SB/.bashrc" && ok "bashrc block added" || no "bashrc block added"
check "scoped model picked up from limits[]" \
  "$(run env CLAUDE_USAGE_STYLE=text CLAUDE_USAGE_COUNTDOWN=off "$CU" line --plain)" \
  "5h 7% · 7d 24% · Opus 55%"
lineout=$(run "$CU" line --plain)
[[ $lineout == *"░"* && $lineout == *"7%"* ]] \
  && ok "line renders bars by default" || no "line renders bars by default ($lineout)"
[[ $lineout != 5h* ]] && ok "line session label is a countdown" || no "line session label is a countdown"

echo; echo "one API call per interval, regardless of terminal count"
rm -f "$SB/.cache/claude-usage/current.json" "$SB/.cache/claude-usage/current.txt"
: > "$SB/.cache/claude-usage/heartbeat"
burst() {  # $1 = how many parallel "terminals"
  local pids=() i
  for ((i=0; i<$1; i++)); do run "$CU" fetch & pids+=($!); done
  wait "${pids[@]}" 2>/dev/null
}
b=$(count); burst 30
check "30 cold, concurrent fetches" "$(( $(count) - b ))" "1"
b=$(count); burst 30
check "30 warm fetches (cache fresh)" "$(( $(count) - b ))" "0"

echo; echo "idle gating"
rm -f "$SB/.cache/claude-usage/heartbeat"
b=$(count); run env CLAUDE_USAGE_IDLE_AFTER=0 "$CU" fetch
check "no heartbeat = no request" "$(( $(count) - b ))" "0"
: > "$SB/.cache/claude-usage/heartbeat"
touch -d '2 hours ago' "$SB/.cache/claude-usage/heartbeat" 2>/dev/null || touch -A -020000 "$SB/.cache/claude-usage/heartbeat"
b=$(count); run "$CU" fetch
check "stale heartbeat = no request" "$(( $(count) - b ))" "0"
: > "$SB/.cache/claude-usage/heartbeat"

echo; echo "failure handling keeps the last good numbers"
# COUNTDOWN=off: the reset label ticks in real time, so two renders taken either
# side of a minute boundary would differ for reasons that have nothing to do
# with the cache under test.
snapshot() { run env CLAUDE_USAGE_COUNTDOWN=off "$CU" line --plain; }
before=$(snapshot)
echo 500 > "$MODE"; run "$CU" fetch --force >/dev/null 2>&1
check "HTTP 500 keeps old cache" "$(snapshot)" "$before"
[[ -s $SB/.cache/claude-usage/last-error ]] && ok "500 recorded in last-error" || no "500 recorded in last-error"
echo garbage > "$MODE"; run "$CU" fetch --force >/dev/null 2>&1
check "non-JSON body keeps old cache" "$(snapshot)" "$before"

echo; echo "401 backs off until credentials change"
echo 401 > "$MODE"; run "$CU" fetch --force >/dev/null 2>&1
[[ -f $SB/.cache/claude-usage/auth-failed ]] && ok "auth-failed marker written" || no "auth-failed marker written"
echo ok > "$MODE"
b=$(count); run "$CU" fetch; check "no retry while credentials unchanged" "$(( $(count) - b ))" "0"
# unambiguously newer than the auth-failed marker (mtimes are whole seconds)
touch -d '+5 seconds' "$SB/.claude/.credentials.json" 2>/dev/null || touch -A 05 "$SB/.claude/.credentials.json"
b=$(count); run "$CU" fetch --force >/dev/null 2>&1
check "retries after credentials change" "$(( $(count) - b ))" "1"
[[ -f $SB/.cache/claude-usage/auth-failed ]] && no "auth-failed cleared on success" || ok "auth-failed cleared on success"

echo; echo "history"
n=$(cat "$SB/.local/share/claude-usage/"history-*.csv | grep -vc '^ts,')
[[ $n -ge 2 ]] && ok "csv rows appended ($n)" || no "csv rows appended ($n)"
head -1 "$SB/.local/share/claude-usage/"history-*.csv | grep -q '^ts,iso,session,weekly' && ok "csv header" || no "csv header"
r=$(cat "$SB/.local/share/claude-usage/"raw-*.jsonl 2>/dev/null | wc -l)
[[ $r -ge 1 ]] && ok "raw jsonl written on change ($r)" || no "raw jsonl written on change"
run "$CU" fetch --force >/dev/null 2>&1
r2=$(cat "$SB/.local/share/claude-usage/"raw-*.jsonl 2>/dev/null | wc -l)
check "raw jsonl not duplicated when unchanged" "$r2" "$r"
env HOME="$SB" CLAUDE_USAGE_DATA="$SB/.local/share/claude-usage" python3 "$PLUGIN/scripts/chart.py" --text --days 0 >/dev/null 2>&1 \
  && ok "chart --text runs" || no "chart --text runs"

echo; echo "prompt integration"
render() {   # $* = extra env -> $out
  out=$(env HOME="$SB" CLAUDE_USAGE_SELF_FETCH=0 "$@" bash --norc -i -c '
    PS1="x"; . '"$PLUGIN"'/shell/claude-usage.bash
    _claude_usage_precmd
    printf "%s" "$CLAUDE_USAGE"' 2>/dev/null)
}

render CLAUDE_USAGE_STYLE=text CLAUDE_USAGE_COUNTDOWN=off
[[ $out == $'\001'* ]] && ok "readline markers present (\\001..\\002)" || no "readline markers present"
[[ $out == *"5h 7%"* ]] && ok "prompt shows cached numbers" || no "prompt shows cached numbers"

render
[[ $out == *"░"* ]] && ok "bar style is the default" || no "bar style is the default"
[[ $out == *"7%"* && $out == *"24%"* ]] && ok "bar prompt keeps the numbers" || no "bar prompt keeps the numbers"
[[ $out != *"5h"* ]] && ok "session label is a countdown, not 5h" || no "session label is a countdown"
# every escape needs its own \001..\002 pair or long lines wrap wrong
esc=${out//[!$'\033']/}; open=${out//[!$'\001']/}
[[ ${#open} -eq ${#esc} ]] && ok "every escape is readline-wrapped" || no "every escape is readline-wrapped (${#open} vs ${#esc})"

render CLAUDE_USAGE_COUNTDOWN=both
[[ -n $out ]] && ok "countdown=both renders" || no "countdown=both renders"

# countdown format: days+hours, hours, and minutes only inside the last hour
dur() { bash --norc -i -c '. '"$PLUGIN"'/shell/claude-usage.bash 2>/dev/null
  REPLY=; _claude_usage_dur '"$1 ${2:-coarse}"'; printf "%s" "$REPLY"' 2>/dev/null; }
durcheck() { check "countdown ${4:-coarse} $2 -> $3" "$(dur "$1" "${4:-coarse}")" "$3"; }
durcheck 571200 "6d14h" "6d 14h"
durcheck 86400  "24h"   "1d 0h"
durcheck 86399  "23h59" "23h"
durcheck 3600   "1h"    "1h"
durcheck 3540   "59m"   "59m"
durcheck 30     "30s"   "<1m"
durcheck -60    "past"  "<1m"
# the 5h window keeps its minutes
durcheck 15900  "4h25"  "4h25m" fine
durcheck 3600   "1h00"  "1h"    fine
durcheck 3540   "59m"   "59m"   fine

render CLAUDE_USAGE_BAR_WIDTH=20 CLAUDE_USAGE_COUNTDOWN=off
# 2 bars, or 3 when the payload carries a scoped model - each exactly 20 cells
bars=${out//[!░█▌]/}
(( ${#bars} >= 40 && ${#bars} % 20 == 0 )) \
  && ok "bar width honoured (${#bars} cells)" || no "bar width honoured (${#bars} cells)"
[[ $(env HOME="$SB" bash --norc -c '. '"$PLUGIN"'/shell/claude-usage.bash; echo LOADED=${CLAUDE_USAGE_LOADED:-no}') == "LOADED=no" ]] \
  && ok "non-interactive shells skipped" || no "non-interactive shells skipped"

echo; echo "uninstall"
cp "$SB/.bashrc" "$TMP/bashrc.before"
run bash "$PLUGIN/scripts/install.sh" --uninstall >/dev/null 2>&1
grep -q 'claude-usage' "$SB/.bashrc" && no "bashrc block removed" || ok "bashrc block removed"
[[ -e $CU ]] && no "bin symlink removed" || ok "bin symlink removed"
[[ -d $SB/.local/share/claude-usage ]] && ok "history preserved on uninstall" || no "history preserved on uninstall"

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
rm -f "$MODE"
[[ $fail -eq 0 ]]
