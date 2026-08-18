#!/usr/bin/env bash
# Optional Claude Code statusline: cwd + model + cached usage.
# Wire it up with:  claude-usage install  (then see README) or in settings.json:
#   "statusLine": { "type": "command", "command": "~/.local/bin/claude-usage-statusline" }
set -uo pipefail
# Resolve our own directory through symlinks (~/.local/bin/claude-usage is
# a symlink into the plugin, and normalise.jq/chart.py live next to the real file).
_self=${BASH_SOURCE[0]}
while [[ -L $_self ]]; do
  _link=$(readlink "$_self")
  [[ $_link == /* ]] && _self=$_link || _self=$(cd -- "$(dirname -- "$_self")" && pwd)/$_link
done
SELF_DIR=$(cd -- "$(dirname -- "$_self")" && pwd)
unset _self _link
input=$(cat)
dir=$(jq -r '.workspace.current_dir // .cwd // ""' <<<"$input" 2>/dev/null)
model=$(jq -r '.model.display_name // ""' <<<"$input" 2>/dev/null)
"$SELF_DIR/claude-usage" heartbeat 2>/dev/null
usage=$("$SELF_DIR/claude-usage" line --ansi 2>/dev/null)
printf '\033[38;5;75m%s\033[0m' "${dir/#$HOME/~}"
[[ -n $model ]] && printf ' \033[38;5;244m%s\033[0m' "$model"
[[ -n $usage ]] && printf ' \033[38;5;244m|\033[0m %s' "$usage"
