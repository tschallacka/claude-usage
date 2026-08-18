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

# bar  = 5h [██▌░░░░░░░] 24% · 7d [█░░░░░░░░░]  7%, each bar coloured by its own
#        percentage, so a hot 7d is visible while 5h is still green.
# text = the original one-colour line, 5h 7% · 7d 24%.
CLAUDE_USAGE_STYLE=${CLAUDE_USAGE_STYLE:-bar}
CLAUDE_USAGE_BAR_WIDTH=${CLAUDE_USAGE_BAR_WIDTH:-10}
CLAUDE_USAGE_BAR_FULL=${CLAUDE_USAGE_BAR_FULL:-█}
CLAUDE_USAGE_BAR_HALF=${CLAUDE_USAGE_BAR_HALF:-▌}
CLAUDE_USAGE_BAR_EMPTY=${CLAUDE_USAGE_BAR_EMPTY:-░}
CLAUDE_USAGE_BAR_TROUGH=${CLAUDE_USAGE_BAR_TROUGH:-238}   # colour of the unfilled part
CLAUDE_USAGE_BAR_BRACKET=${CLAUDE_USAGE_BAR_BRACKET:-1}   # 1 = wrap each bar in [ ]
# Label the blocks with the time left until they reset instead of "5h" / "7d":
# session | both | off.  Falls back to the static label whenever the cache has
# no reset epoch yet (a current.txt written by an older version).
CLAUDE_USAGE_COUNTDOWN=${CLAUDE_USAGE_COUNTDOWN:-both}

CLAUDE_USAGE=''
CLAUDE_USAGE_AGE=999999

_claude_usage_now() {   # -> $REPLY, no fork
  if [[ -n ${EPOCHSECONDS:-} ]]; then REPLY=$EPOCHSECONDS
  else printf -v REPLY '%(%s)T' -1 2>/dev/null || REPLY=0; fi
}

# $2 = fine keeps the minutes (the 5h window is short enough that 4h25m is
# worth knowing).  Otherwise coarse: 6d 14h, then 14h, and minutes only inside
# the last hour, so a week-long label does not reflow every 60 seconds.
_claude_usage_dur() {   # $1 = seconds, $2 = fine|coarse -> $REPLY
  local t=$1 fine=${2:-coarse} d h m
  (( t < 0 )) && t=0
  d=$(( t / 86400 )); h=$(( t % 86400 / 3600 )); m=$(( t % 3600 / 60 ))
  if   (( d > 0 )); then REPLY="${d}d ${h}h"
  elif (( h > 0 )); then
    REPLY="${h}h"
    [[ $fine == fine ]] && (( m > 0 )) && REPLY+="${m}m"
  elif (( m > 0 )); then REPLY="${m}m"
  else                   REPLY='<1m'
  fi
  return 0
}

_claude_usage_colour() {   # $1 = percent -> $REPLY = 256-colour index
  if   (( $1 >= 90 )); then REPLY=197
  elif (( $1 >= 75 )); then REPLY=208
  elif (( $1 >= 50 )); then REPLY=178
  else                      REPLY=71
  fi
  return 0
}

# $1 = percent -> $REPLY = filled part, $REPLY_EMPTY = trough.  Pure bash: one
# loop of at most CLAUDE_USAGE_BAR_WIDTH iterations, no fork, no subshell, and
# no substring arithmetic on multi-byte characters (locale-independent).
_claude_usage_bar() {
  local pct=$1 w=$CLAUDE_USAGE_BAR_WIDTH halves full half i
  (( pct < 0 ))   && pct=0
  (( pct > 100 )) && pct=100
  (( w < 1 ))     && w=1
  halves=$(( (pct * w * 2 + 50) / 100 ))        # round to the nearest half cell
  (( pct > 0 && halves == 0 )) && halves=1      # never render "in use" as empty
  full=$(( halves / 2 ))
  half=$(( halves % 2 ))
  REPLY=''
  REPLY_EMPTY=''
  for (( i = 0; i < full; i++ )); do REPLY+=$CLAUDE_USAGE_BAR_FULL; done
  (( half )) && REPLY+=$CLAUDE_USAGE_BAR_HALF
  for (( i = full + half; i < w; i++ )); do REPLY_EMPTY+=$CLAUDE_USAGE_BAR_EMPTY; done
  return 0
}

# $1 = label, $2 = percent, $3 = colour -> $REPLY = one coloured "5h [██░░] 20%".
# \001/\002 = readline "zero width from here to here".  Required because these
# bytes arrive through parameter expansion, where PS1's own \[ \] markers are no
# longer interpreted - without them long lines wrap wrong.  Every escape in the
# segment needs its own pair, not just the outermost one.
_claude_usage_seg() {
  local lbl=$1 pct=$2 col=$3 fill trough REPLY_EMPTY
  local on=$'\001\033[38;5;'"$col"$'m\002'
  local dim=$'\001\033[38;5;'"$CLAUDE_USAGE_BAR_TROUGH"$'m\002'
  local off=$'\001\033[0m\002'
  _claude_usage_bar "$pct"
  fill=$REPLY trough=$REPLY_EMPTY
  REPLY="$lbl "
  (( CLAUDE_USAGE_BAR_BRACKET )) && REPLY+="$dim[$off"
  REPLY+="$on$fill$off$dim$trough$off"
  (( CLAUDE_USAGE_BAR_BRACKET )) && REPLY+="$dim]$off"
  REPLY+=" $on$pct%$off"
  return 0
}

# Pure bash: one `read` from a small file, integer compares, no subshell.
_claude_usage_render() {
  CLAUDE_USAGE=''
  local f=$CLAUDE_USAGE_CACHE/current.txt
  [[ -r $f ]] || return 0
  local ts sess week scoped model sev sreset wreset sepoch wepoch REPLY
  IFS=$'\t' read -r ts sess week scoped model sev sreset wreset sepoch wepoch < "$f" || return 0
  [[ -n $ts && $ts != *[!0-9]* ]] || return 0
  _claude_usage_now
  local nowsec=$REPLY
  CLAUDE_USAGE_AGE=$(( nowsec - ts ))

  [[ -z $sess   || $sess   == *[!0-9-]* ]] && sess=0
  [[ -z $week   || $week   == *[!0-9-]* ]] && week=0
  [[ -z $scoped || $scoped == *[!0-9-]* ]] && scoped=-1
  [[ -z $sepoch || $sepoch == *[!0-9]* ]] && sepoch=0
  [[ -z $wepoch || $wepoch == *[!0-9]* ]] && wepoch=0

  local stale=0
  (( CLAUDE_USAGE_AGE > CLAUDE_USAGE_STALE_AFTER )) && stale=1

  # Labels: time left until each window resets.  Integer maths off $nowsec, so
  # this costs no fork either.
  local slbl=5h wlbl=7d
  if [[ $CLAUDE_USAGE_COUNTDOWN != off ]]; then
    if (( sepoch > 0 )); then _claude_usage_dur $(( sepoch - nowsec )) fine; slbl=$REPLY; fi
    if [[ $CLAUDE_USAGE_COUNTDOWN == both ]] && (( wepoch > 0 )); then
      _claude_usage_dur $(( wepoch - nowsec )); wlbl=$REPLY
    fi
  fi

  local txt c
  if [[ $CLAUDE_USAGE_STYLE == bar ]]; then
    if (( stale )); then c=244; else _claude_usage_colour "$sess"; c=$REPLY; fi
    _claude_usage_seg "$slbl" "$sess" "$c"; txt=$REPLY
    if (( stale )); then c=244; else _claude_usage_colour "$week"; c=$REPLY; fi
    _claude_usage_seg "$wlbl" "$week" "$c"; txt+=" $CLAUDE_USAGE_SEP $REPLY"
    if (( scoped > 0 )); then
      if (( stale )); then c=244; else _claude_usage_colour "$scoped"; c=$REPLY; fi
      _claude_usage_seg "$model" "$scoped" "$c"; txt+=" $CLAUDE_USAGE_SEP $REPLY"
    fi
    (( stale )) && txt+='*'
    CLAUDE_USAGE=$txt
    return 0
  fi

  local worst=$sess; (( week > worst )) && worst=$week
  if (( stale )); then c=244; else _claude_usage_colour "$worst"; c=$REPLY; fi
  txt="${slbl} ${sess}% ${CLAUDE_USAGE_SEP} ${wlbl} ${week}%"
  (( scoped > 0 )) && txt+=" ${CLAUDE_USAGE_SEP} ${model} ${scoped}%"
  (( stale )) && txt+='*'
  CLAUDE_USAGE=$'\001\033[38;5;'"$c"$'m\002'"$txt"$'\001\033[0m\002'
  return 0
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
