#!/usr/bin/env bash
# Bootstrap installer.  Run it with:
#   curl -fsSL https://raw.githubusercontent.com/tschallacka/claude-usage/main/install.sh | bash
#
# Clones (or updates) the plugin, runs the real installer, and registers it with
# Claude Code.  Everything it touches lives under $HOME; nothing needs root.
set -euo pipefail

REPO=${CLAUDE_USAGE_REPO:-tschallacka/claude-usage}
BRANCH=${CLAUDE_USAGE_BRANCH:-main}
DEST=${CLAUDE_USAGE_DEST:-$HOME/.local/share/claude-usage-plugin}
INSTALL_ARGS=()

for a in "$@"; do case $a in
  --no-scheduler|--no-bashrc) INSTALL_ARGS+=("$a") ;;
  --no-plugin) NO_PLUGIN=1 ;;
  -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 2 ;;
esac; done

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

head_ "claude-usage"

missing=()
for c in git curl jq bash; do have "$c" || missing+=("$c"); done
if (( ${#missing[@]} )); then
  echo "  missing required command(s): ${missing[*]}" >&2
  echo "  install them first, e.g.  sudo apt install ${missing[*]}" >&2
  exit 1
fi

# 1. source
if [[ -d $DEST/.git ]]; then
  say "updating $DEST"
  git -C "$DEST" fetch --quiet origin "$BRANCH"
  git -C "$DEST" checkout --quiet "$BRANCH"
  git -C "$DEST" merge --quiet --ff-only "origin/$BRANCH" || {
    echo "  $DEST has local commits; not touching it" >&2; exit 1; }
else
  say "cloning $REPO into $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --quiet --depth 1 --branch "$BRANCH" "https://github.com/$REPO.git" "$DEST"
fi

# 2. prompt segment, poller, bin symlink
bash "$DEST/scripts/install.sh" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}

# 3. Claude Code plugin (slash commands: /claude-usage:status, :chart, :doctor)
if [[ -z ${NO_PLUGIN:-} ]] && have claude; then
  head_ "Claude Code plugin"
  if claude plugin marketplace add "$REPO" >/dev/null 2>&1; then
    say "marketplace added"
  else
    say "marketplace already known"
  fi
  if claude plugin install claude-usage@claude-usage >/dev/null 2>&1; then
    say "plugin installed - /claude-usage:status, :chart, :doctor"
  else
    say "plugin already installed (or needs 'claude plugin install claude-usage@claude-usage')"
  fi
fi

head_ "Next steps"
say "Open a new terminal, or:  . ~/.bashrc"
say "Optional Claude Code statusline - add to ~/.claude/settings.json:"
say '  "statusLine": { "type": "command", "command": "'"$DEST"'/scripts/statusline.sh" }'
