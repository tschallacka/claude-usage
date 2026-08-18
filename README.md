# claude-usage

Claude Code usage limits in your bash prompt, your iTerm status bar, and Claude
Code's own statusline — plus a CSV history you can chart later.

```
4h25m [█░░░░░░░░░] 9% · 6d 14h [██▌░░░░░░░] 25%  mdibbets:~/www/proforto$
```

Each bar is coloured by its own percentage, so a hot 7-day window is visible
while the session is still green.  Both blocks are labelled with the time left
until they reset rather than a flat `5h` / `7d`.  The 5h window is short enough
to be worth the minutes (`4h25m`); the 7d one is deliberately coarse - `6d 14h`,
then `14h`, dropping to minutes only inside the last hour - so a week-long label
does not reflow every 60 seconds.  Set `CLAUDE_USAGE_STYLE=text` for
the original one-line form, `5h 7% · 7d 24% · Opus 55%`.

## Why not just call the API from `PS1`

The usual recipe fetches once per prompt render. With a dozen iTerm tabs that is
a dozen HTTPS round trips per keystroke-return, a visible stall on every prompt,
and a fast track to HTTP 429. This plugin splits the two jobs:

| | who | cost |
|---|---|---|
| **fetch** | one background poller, once per minute, whole machine | 1 request/min |
| **display** | every prompt, reading one small cache file | no network, no fork |

Three independent gates keep the request count at exactly one per minute no
matter how many terminals you open and close:

1. **Heartbeat** — every prompt truncates `~/.cache/claude-usage/heartbeat`
   (a shell builtin, no fork). If no prompt has been drawn for 5 minutes the
   fetcher exits without calling the API. Closed terminals cost nothing.
2. **Freshness** — if `current.json` is younger than `CLAUDE_USAGE_INTERVAL`,
   the fetcher exits immediately.
3. **Lock** — `mkdir` is atomic, so of 40 simultaneous fetchers exactly one
   proceeds. (Verified in `tests/run-tests.sh`: 30 concurrent cold fetches → 1
   API call.)

Because of gates 2 and 3 the plugin is correct *without* any scheduler at all —
a shell that notices stale data starts one background refresh. The launchd /
systemd timer just keeps the numbers current while you sit idle.

## Install

```bash
claude plugin marketplace add ~/claude-usage-plugin
claude plugin install claude-usage@local-usage
```

Then, inside Claude Code:

```
/claude-usage:install
```

or straight from a shell:

```bash
~/claude-usage-plugin/scripts/install.sh
```

It requires `jq` and `curl`, and it:

- symlinks `~/.local/bin/claude-usage`
- fetches once so the prompt has something to show
- installs the poller: **launchd** agent on macOS, **systemd user timer** on
  Linux, `crontab` if neither, nothing if you pass `--no-scheduler`
- appends a marked, backed-up block to `~/.bashrc`

**macOS, important:** the first fetch triggers a Keychain prompt for
`Claude Code-credentials`. Click **Always Allow**, otherwise the background
launchd job will sit there blocked forever. Running the installer from a
terminal (not from a background context) is what gets you that dialog.

Open a new terminal, or `. ~/.bashrc`.

## Commands

| | |
|---|---|
| `usage` | current numbers and reset times |
| `usage-now` | force a refresh, then print them |
| `claude-usage doctor` | why isn't it updating |
| `claude-usage chart --text` | sparklines + per-block burn rate |
| `claude-usage chart --open` | PNG (needs `pip install matplotlib`) |
| `claude-usage line --plain` | one uncoloured line, for other status bars |

Inside Claude Code: `/claude-usage:status`, `:chart`, `:doctor`, `:install`,
`:uninstall`.

## Refreshing without pressing Enter

bash cannot repaint an idle prompt — there is no zsh `TRAPALRM` equivalent — so
the prompt segment updates whenever a new prompt is drawn. That covers the
"always visible" half of the ask. For a number that ticks on its own while you
sit idle, you need something other than `PS1`:

**iTerm2** (this is the real answer on macOS). Its status bar re-runs a
component on its own cadence:

```bash
mkdir -p ~/Library/Application\ Support/iTerm2/Scripts/AutoLaunch
cp ~/claude-usage-plugin/extras/iterm2-statusbar.py \
   ~/Library/Application\ Support/iTerm2/Scripts/AutoLaunch/
```

Restart iTerm2, then **Settings → Profiles → Session → Status bar enabled →
Configure** and drag **Claude usage** into the layout. It refreshes every 60s
(`update_cadence` in the script) and reads the same cache file, so it costs no
API calls. First run may prompt you to install iTerm2's Python runtime.

Note: iTerm2's built-in *Interpolated String* component cannot run a shell
command — it only interpolates iTerm variables — which is why this is a small
Python component rather than a one-line setting.

**tmux**, if you use it, is the easiest interval refresh of all:

```tmux
set -g status-interval 60
set -g status-right '#(~/.local/bin/claude-usage line --plain) | %H:%M'
```

## Claude Code statusline

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/claude-usage-plugin/scripts/statusline.sh"
  }
}
```

Shows cwd, model, and the same cached usage numbers — bars, per-window colours
and the reset countdown included, driven by the same `CLAUDE_USAGE_STYLE`,
`CLAUDE_USAGE_COUNTDOWN` and `CLAUDE_USAGE_BAR_*` variables as the prompt.
Export them from the statusline's own environment, not just `~/.bashrc`, since
Claude Code does not run the command through an interactive shell.

## Tuning

Set these before the `~/.bashrc` block (or export them anywhere):

| variable | default | meaning |
|---|---|---|
| `CLAUDE_USAGE_PROMPT_SIDE` | `prefix` | `prefix`, `suffix`, or `off` |
| `CLAUDE_USAGE_SEP` | `·` | separator between windows |
| `CLAUDE_USAGE_INTERVAL` | `60` | minimum seconds between API calls |
| `CLAUDE_USAGE_IDLE_AFTER` | `300` | stop polling this long after the last prompt |
| `CLAUDE_USAGE_STALE_AFTER` | `300` | after this, the segment greys out and gets a `*` |
| `CLAUDE_USAGE_SELF_FETCH` | `1` | let shells refresh stale data themselves |
| `CLAUDE_USAGE_STYLE` | `bar` | `bar` or `text` |
| `CLAUDE_USAGE_COUNTDOWN` | `both` | label blocks with time-to-reset: `both`, `session`, `off` |
| `CLAUDE_USAGE_BAR_WIDTH` | `10` | cells per bar |
| `CLAUDE_USAGE_BAR_BRACKET` | `1` | `0` drops the `[ ]` around each bar |
| `CLAUDE_USAGE_BAR_TROUGH` | `238` | 256-colour index of the unfilled part |
| `CLAUDE_USAGE_BAR_FULL` / `_HALF` / `_EMPTY` | `█` `▌` `░` | bar characters |

Colours: green < 50%, yellow < 75%, orange < 90%, red above, grey when stale.
In `bar` mode each window is coloured independently; in `text` mode the whole
segment takes the colour of the worst window.

Bars round to the nearest half cell, and anything above 0% always shows at
least a half cell, so "barely used" never renders as "untouched".  Rendering
stays fork-free: the poller writes the reset times to `current.txt` as epoch
seconds, so the countdown is integer arithmetic in bash rather than a `date`
call on every prompt.

## Data for charts

```
~/.local/share/claude-usage/history-YYYY-MM.csv   one row per fetch
~/.local/share/claude-usage/raw-YYYY-MM.jsonl     full payload, only when values change
```

CSV columns: `ts,iso,session,weekly,weekly_scoped,scoped_model,severity,session_resets_at,weekly_resets_at,extra_utilization,spend_percent`

`session_resets_at` is what makes per-block analysis possible: when it changes,
a new 5-hour window has started. That is how `chart --text` computes burn rate
in percentage points per hour. The monthly split keeps any single file small,
and `raw-*.jsonl` preserves fields this plugin does not read yet, so old data
stays useful if the API grows.

Rough size: a row is ~140 bytes and only written while a terminal is open, so
heavy use is a few MB a year.

```python
import glob, pandas as pd
df = pd.concat(pd.read_csv(f, parse_dates=["iso"])
               for f in sorted(glob.glob("~/.local/share/claude-usage/history-*.csv")))
```

## What the API actually returns

`/api/oauth/usage` is undocumented — found by inspecting Claude Code's own
traffic — so treat it as unstable. Two things worth knowing:

- The blog posts that popularised this endpoint read `five_hour`, `seven_day`
  and `seven_day_opus`. On current accounts `seven_day_opus` is `null`; the
  per-model window now lives in `limits[]` as `kind: "weekly_scoped"`, with the
  model in `scope.model.display_name`. `scripts/normalise.jq` reads `limits[]`
  first and falls back to the old flat keys, so both shapes work.
- The payload also carries `extra_usage` and `spend`, which are logged to the
  CSV but kept out of the prompt.

Failure is deliberately quiet: a non-200, a garbage body or a network error
leaves the last good numbers in place and the segment simply greys out. A 401
writes an `auth-failed` marker and stops retrying until `~/.claude/.credentials.json`
changes — Claude Code rewrites it when it refreshes the token, and the poller
picks up automatically.

Scheduler installation is skipped when `$HOME` does not match the invoking
user's real home.  `launchctl`, `systemctl --user` and `crontab` are scoped to
the login session rather than to `$HOME`, so a redirected-`$HOME` run - a test
suite, a container - would otherwise reach out of its sandbox and stop the real
user's poller.

## Tests

```bash
tests/run-tests.sh
```

25 checks against a local fake API in a throwaway `$HOME`: concurrency gating,
idle gating, 500/401/garbage handling, backoff, CSV and JSONL writing, readline
escaping, and uninstall reversibility. It never touches the real API or your
real config.

## Uninstall

```bash
~/claude-usage-plugin/scripts/install.sh --uninstall
```

Removes the scheduler, the `~/.bashrc` block (keeping a timestamped backup) and
the symlink. Your history is left alone.
