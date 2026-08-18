#!/usr/bin/env python3
"""iTerm2 status bar component showing Claude Code usage.

This is the only way to get a number that ticks while you sit at an idle prompt:
bash cannot repaint its own prompt, but iTerm2 re-runs a status bar component on
its own cadence.  It reads the same cache file the prompt does, so it makes no
API calls at all.

Install:
  mkdir -p ~/Library/Application\\ Support/iTerm2/Scripts/AutoLaunch
  cp extras/iterm2-statusbar.py ~/Library/Application\\ Support/iTerm2/Scripts/AutoLaunch/
Then in iTerm2: Settings > Profiles > Session > Status bar enabled > Configure,
and drag "Claude usage" into the layout.  (Scripts > Manage > Check for Updates
installs the Python runtime the first time, if you have not used it before.)
"""
import os
import time

import iterm2  # provided by the iTerm2 Python runtime

CACHE = os.path.expanduser(
    os.environ.get("CLAUDE_USAGE_CACHE", "~/.cache/claude-usage")
)
CURRENT = os.path.join(CACHE, "current.txt")
STALE_AFTER = 300


def read_line() -> str:
    try:
        with open(CURRENT) as fh:
            ts, sess, week, scoped, model, sev, sreset, wreset = \
                fh.readline().rstrip("\n").split("\t")
    except (OSError, ValueError):
        return "claude ?"
    parts = [f"5h {sess}%", f"7d {week}%"]
    try:
        if int(scoped) > 0:
            parts.append(f"{model} {scoped}%")
    except ValueError:
        pass
    line = " · ".join(parts)
    try:
        if time.time() - float(ts) > STALE_AFTER:
            line += "*"
    except ValueError:
        pass
    return line


async def main(connection):
    component = iterm2.StatusBarComponent(
        short_description="Claude usage",
        detailed_description="Claude Code 5-hour and 7-day limits, read from "
                             "the claude-usage cache (no API calls)",
        knobs=[],
        exemplar="5h 7% · 7d 24%",
        update_cadence=60,          # seconds; iTerm2 refreshes us this often
        identifier="dev.local.claude-usage",
    )

    @iterm2.StatusBarRPC
    async def callback(knobs):
        # Touching the heartbeat keeps the poller alive even if this window is
        # idle, which is exactly when you want the number to stay fresh.
        try:
            open(os.path.join(CACHE, "heartbeat"), "w").close()
        except OSError:
            pass
        return read_line()

    await component.async_register(connection, callback)


iterm2.run_forever(main)
