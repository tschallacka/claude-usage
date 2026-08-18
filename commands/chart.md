---
description: Chart the collected usage history (PNG, or text summary)
argument-hint: "[--days N] [--out file.png] [--text]"
allowed-tools: Bash(*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/claude-usage" chart --text --days ${1:-14}`

That is the text summary. If the user asked for a picture, run the same command with `--out` and `--open` and hand them the path. Interpret the burn-rate table: point out the heaviest 5-hour blocks and whether the current 7-day trend is on course to hit 100% before it resets.
