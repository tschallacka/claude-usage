---
description: Remove the claude-usage poller, prompt segment and scheduler (keeps history)
allowed-tools: Bash(*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" --uninstall`

Confirm what was removed and remind the user their CSV history is still in `~/.local/share/claude-usage/` if they want to delete it.
