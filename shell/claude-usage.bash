# claude-usage bash integration.  Sourced from ~/.bashrc.
# Design rule: rendering the prompt must never make a network call and never
# fork.  A fork happens at most when the cached data has actually gone stale.
[[ $- == *i* ]] || return 0                      # interactive shells only
[[ -n ${CLAUDE_USAGE_LOADED:-} ]] && return 0
CLAUDE_USAGE_LOADED=1

CLAUDE_USAGE_CACHE=${CLAUDE_USAGE_CACHE:-$HOME/.cache/claude-usage}
CLAUDE_USAGE_BIN=${CLAUDE_USAGE_BIN:-$HOME/.local/bin/claude-usage}
CLAUDE_USAGE_INTERVAL=${CLAUDE_USAGE_INTERVAL:-60}
CLAUDE_USAGE_STALE_AFTER=${CLAUDE_USAGE_STALE_AFTER:-300}
# 1 = if the cached numbers are older than the interval, let one shell refresh
# them in the background.  The fetcher takes a lock and re-checks freshness, so
# 40 open terminals still produce at most one API call per interval.
CLAUDE_USAGE_SELF_FETCH=${CLAUDE_USAGE_SELF_FETCH:-1}
CLAUDE_USAGE_PROMPT_SIDE=${CLAUDE_USAGE_PROMPT_SIDE:-prefix}   # prefix|suffix|off
CLAUDE_USAGE_SEP=${CLAUDE_USAGE_SEP:-·}

CLAUDE_USAGE=''
CLAUDE_USAGE_AGE=999999

_claude_usage_now() {   # -> $REPLY, no fork
  if [[ -n ${EPOCHSECONDS:-} ]]; then REPLY=$EPOCHSECONDS
  else printf -v REPLY '%(%s)T' -1 2>/dev/null || REPLY=0; fi
}

# Pure bash: one `read` from a small file, integer compares, no subshell.
_claude_usage_render() {
  CLAUDE_USAGE=''
  local f=$CLAUDE_USAGE_CACHE/current.txt
  [[ -r $f ]] || return 0
  local ts sess week scoped model sev sreset wreset REPLY
  IFS=$'\t' read -r ts sess week scoped model sev sreset wreset < "$f" || return 0
  [[ -n $ts && $ts != *[!0-9]* ]] || return 0
  _claude_usage_now
  CLAUDE_USAGE_AGE=$(( REPLY - ts ))

  [[ -z $sess   || $sess   == *[!0-9-]* ]] && sess=0
  [[ -z $week   || $week   == *[!0-9-]* ]] && week=0
  [[ -z $scoped || $scoped == *[!0-9-]* ]] && scoped=-1

  local worst=$sess; (( week > worst )) && worst=$week
  local c
  if   (( CLAUDE_USAGE_AGE > CLAUDE_USAGE_STALE_AFTER )); then c=244
  elif (( worst >= 90 )); then c=197
  elif (( worst >= 75 )); then c=208
  elif (( worst >= 50 )); then c=178
  else c=71; fi

  local txt="5h ${sess}% ${CLAUDE_USAGE_SEP} 7d ${week}%"
  (( scoped > 0 )) && txt+=" ${CLAUDE_USAGE_SEP} ${model} ${scoped}%"
  (( CLAUDE_USAGE_AGE > CLAUDE_USAGE_STALE_AFTER )) && txt+='*'
  # \001/\002 = readline "zero width from here to here".  Required because
  # these bytes arrive through parameter expansion, where PS1's own \[ \]
  # markers are no longer interpreted - without them long lines wrap wrong.
  CLAUDE_USAGE=$'\001\033[38;5;'"$c"$'m\002'"$txt"$'\001\033[0m\002'
}

_claude_usage_precmd() {
  local REPLY
  : > "$CLAUDE_USAGE_CACHE/heartbeat" 2>/dev/null   # builtin redirect, no fork
  _claude_usage_render
  if (( CLAUDE_USAGE_SELF_FETCH )) && (( CLAUDE_USAGE_AGE >= CLAUDE_USAGE_INTERVAL )); then
    _claude_usage_now
    if (( REPLY - ${CLAUDE_USAGE_LAST_TRY:-0} >= CLAUDE_USAGE_INTERVAL )) && [[ -x $CLAUDE_USAGE_BIN ]]; then
      CLAUDE_USAGE_LAST_TRY=$REPLY
      # disowned, output-free: never blocks or dirties the prompt
      ( "$CLAUDE_USAGE_BIN" fetch >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
  fi
}

if [[ $CLAUDE_USAGE_PROMPT_SIDE != off ]]; then
  if [[ ${PROMPT_COMMAND:-} != *_claude_usage_precmd* ]]; then
    if [[ -n ${PROMPT_COMMAND:-} ]]; then
      PROMPT_COMMAND="_claude_usage_precmd;${PROMPT_COMMAND}"
    else
      PROMPT_COMMAND="_claude_usage_precmd"
    fi
  fi
  if [[ -z ${CLAUDE_USAGE_PS1_PATCHED:-} ]]; then
    CLAUDE_USAGE_PS1_PATCHED=1
    CLAUDE_USAGE_PS1_ORIG=$PS1
    if [[ $CLAUDE_USAGE_PROMPT_SIDE == suffix ]]; then
      PS1="${PS1}"'${CLAUDE_USAGE:+$CLAUDE_USAGE }'
    else
      PS1='${CLAUDE_USAGE:+$CLAUDE_USAGE }'"${PS1}"
    fi
  fi
fi

usage()     { "$CLAUDE_USAGE_BIN" status; }
usage-now() { "$CLAUDE_USAGE_BIN" fetch --force >/dev/null 2>&1; "$CLAUDE_USAGE_BIN" status; }
