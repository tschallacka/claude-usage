---
description: Show current Claude Code usage limits from the local cache
allowed-tools: Bash(*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/claude-usage" status`

Summarise in one or two lines: how close each window is to its limit, when it resets (convert the UTC reset timestamps to the user's local time), and flag anything above 75%. If the data age is over 300s, say the poller looks stalled and suggest `/claude-usage:doctor`.
