---
description: Install the claude-usage prompt segment, background poller and history logging
allowed-tools: Bash(*)
---

Run the installer and report what it did:

!`"${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" $ARGUMENTS`

Then tell the user, briefly:
- the current usage numbers,
- which scheduler was installed (launchd / systemd timer / cron / shell-fallback),
- that they need a new terminal (or `. ~/.bashrc`) for the prompt segment,
- the iTerm status-bar line if they are on macOS.

If the first fetch failed, run `"${CLAUDE_PLUGIN_ROOT}/scripts/claude-usage" doctor` and diagnose from its output instead of guessing.
