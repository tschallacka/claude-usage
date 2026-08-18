#!/usr/bin/env bash
# Installs claude-usage: bin symlink, background poller, ~/.bashrc hook.
# Idempotent; --uninstall reverses everything it did.
set -euo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR=$HOME/.local/bin
BIN=$BIN_DIR/claude-usage
CACHE=$HOME/.cache/claude-usage
DATA=$HOME/.local/share/claude-usage
BASHRC=${CLAUDE_USAGE_BASHRC:-$HOME/.bashrc}
BEGIN_MARK='# >>> claude-usage >>>'
END_MARK='# <<< claude-usage <<<'
PLIST=$HOME/Library/LaunchAgents/dev.local.claude-usage.plist
LABEL=dev.local.claude-usage
SYSTEMD_DIR=$HOME/.config/systemd/user
INTERVAL=${CLAUDE_USAGE_INTERVAL:-60}

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Every other path here is $HOME-scoped, but launchctl, `systemctl --user` and
# crontab are scoped to the login session instead - they ignore $HOME entirely.
# So when $HOME has been redirected (the test suite, a container, a bare
# `HOME=/tmp/x ./install.sh`), touching a scheduler would reach straight out of
# the sandbox and stop the real user's poller.  Detect that and skip it.
real_home() {
  local u h=''
  u=$(id -un 2>/dev/null) || return 1
  h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6) || true
  [[ -n $h ]] || h=$(eval "printf '%s' ~$u" 2>/dev/null) || true
  [[ $h == /* ]] || h=''          # ~u stays literal when the user is unknown
  printf '%s' "$h"
}
home_redirected() {
  local rh; rh=$(real_home)
  [[ -n $rh && $rh != "$HOME" ]]
}
say_sandboxed() {
  say "\$HOME is redirected to $HOME - leaving this login session's scheduler alone"
  say "(launchctl, systemctl --user and crontab are per session, not per \$HOME)"
}

uninstall=0; no_scheduler=0; no_bashrc=0
for a in "$@"; do case $a in
  --uninstall) uninstall=1 ;;
  --no-scheduler) no_scheduler=1 ;;
  --no-bashrc) no_bashrc=1 ;;
  -h|--help) sed -n '2,4p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 2 ;;
esac; done

remove_bashrc_block() {
  [[ -f $BASHRC ]] || return 0
  grep -qF "$BEGIN_MARK" "$BASHRC" || return 0
  cp "$BASHRC" "$BASHRC.claude-usage.bak.$(date +%Y%m%dT%H%M%S)"
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0,b){skip=1} !skip{print} index($0,e){skip=0}' "$BASHRC" > "$BASHRC.tmp"
  mv "$BASHRC.tmp" "$BASHRC"
}

if (( uninstall )); then
  head_ "Uninstalling claude-usage"
  if home_redirected; then
    say_sandboxed
  elif [[ $(uname -s) == Darwin ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST" && say "removed launchd agent"
  else
    if have systemctl; then
      systemctl --user disable --now claude-usage.timer 2>/dev/null || true
      rm -f "$SYSTEMD_DIR/claude-usage.timer" "$SYSTEMD_DIR/claude-usage.service"
      systemctl --user daemon-reload 2>/dev/null || true
      say "removed systemd user timer"
    fi
    if have crontab && crontab -l 2>/dev/null | grep -q 'claude-usage fetch'; then
      crontab -l 2>/dev/null | grep -v 'claude-usage fetch' | crontab - && say "removed crontab entry"
    fi
  fi
  remove_bashrc_block && say "removed ~/.bashrc block (backup kept)"
  rm -f "$BIN" && say "removed $BIN"
  say "history kept in $DATA (delete it yourself if you want it gone)"
  echo; say "Open a new terminal to drop the prompt segment."
  exit 0
fi

head_ "Installing claude-usage"
have jq   || { echo "jq is required. macOS: brew install jq   Debian: sudo apt install jq" >&2; exit 1; }
have curl || { echo "curl is required" >&2; exit 1; }

mkdir -p "$BIN_DIR" "$CACHE" "$DATA"
ln -sfn "$SELF_DIR/claude-usage" "$BIN"
say "linked $BIN -> $SELF_DIR/claude-usage"

# 1. first fetch, so the prompt has something to show immediately.
: > "$CACHE/heartbeat"
if "$BIN" fetch --force >/dev/null 2>&1; then
  say "first fetch OK: $("$BIN" line --plain)"
else
  say "first fetch FAILED - run '$BIN doctor' (on macOS approve the Keychain prompt)"
fi

# 2. background poller
if (( ! no_scheduler )) && home_redirected; then
  head_ "Background poller"
  say_sandboxed
elif (( ! no_scheduler )); then
  if [[ $(uname -s) == Darwin ]]; then
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>fetch</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>/tmp/claude-usage.out</string>
  <key>StandardErrorPath</key><string>/tmp/claude-usage.err</string>
</dict>
</plist>
PLISTEOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null; then
      say "launchd agent loaded (every ${INTERVAL}s, one process for all terminals)"
    else
      say "could not load launchd agent; the shell fallback will keep data fresh"
    fi
  elif have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p "$SYSTEMD_DIR"
    cat > "$SYSTEMD_DIR/claude-usage.service" <<EOF
[Unit]
Description=Fetch Claude Code usage limits
[Service]
Type=oneshot
ExecStart=$BIN fetch
Nice=10
EOF
    cat > "$SYSTEMD_DIR/claude-usage.timer" <<EOF
[Unit]
Description=Poll Claude Code usage limits every ${INTERVAL}s
[Timer]
OnBootSec=30
OnUnitActiveSec=${INTERVAL}
AccuracySec=5s
Unit=claude-usage.service
[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now claude-usage.timer
    say "systemd user timer enabled (every ${INTERVAL}s)"
    say "tip: 'loginctl enable-linger $USER' keeps it polling with no session open"
  elif have crontab; then
    ( crontab -l 2>/dev/null | grep -v 'claude-usage fetch'; echo "* * * * * $BIN fetch >/dev/null 2>&1" ) | crontab -
    say "crontab entry added (every 60s - cron cannot go finer)"
  else
    say "no scheduler found; relying on the shell fallback (still 1 call/min total)"
  fi
fi

# 3. ~/.bashrc hook
if (( ! no_bashrc )); then
  remove_bashrc_block
  cat >> "$BASHRC" <<EOF
$BEGIN_MARK
# Claude usage in the prompt. Reads a cache file; never calls the API itself.
# Tunables: CLAUDE_USAGE_PROMPT_SIDE=prefix|suffix|off  CLAUDE_USAGE_SEP='|'
[ -f "$SELF_DIR/../shell/claude-usage.bash" ] && . "$SELF_DIR/../shell/claude-usage.bash"
$END_MARK
EOF
  say "added block to $BASHRC (backup kept alongside)"
fi

head_ "Done"
say "now:      $("$BIN" line --plain)"
say "check:    claude-usage status | claude-usage doctor"
say "chart:    claude-usage chart --open"
say "prompt:   open a new terminal, or run: . $BASHRC"
if [[ $(uname -s) == Darwin ]]; then
  say "iTerm:    for a segment that ticks while you sit idle, install"
  say "          extras/iterm2-statusbar.py - see README 'Refreshing without pressing Enter'"
fi
