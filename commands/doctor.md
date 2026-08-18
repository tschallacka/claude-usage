---
description: Diagnose the claude-usage poller, cache and shell integration
allowed-tools: Bash(*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/claude-usage" doctor`
!`cat ~/.cache/claude-usage/last-error 2>/dev/null || echo "(no last-error file)"`

Diagnose from the above. Common causes, in order of likelihood:
- `token MISSING` on macOS: the background agent never got Keychain approval. Fix: run `claude-usage fetch --force` in a terminal and click "Always Allow".
- `auth-failed` present: the OAuth token expired. Running any `claude` command rewrites the credentials, and the fetcher retries automatically once the credentials file changes.
- `heartbeat missing`: the ~/.bashrc block is not loaded, so the fetcher deliberately stays idle. Check the `bashrc hook` line.
- HTTP 429 in last-error: something else is polling too. Raise `CLAUDE_USAGE_INTERVAL`.

Report the diagnosis and the exact fix command. Do not change anything without asking.
