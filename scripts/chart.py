#!/usr/bin/env python3
"""Chart Claude Code usage history collected by claude-usage.

Reads every ~/.local/share/claude-usage/history-*.csv and renders:
  - 5h session utilisation, split into separate blocks per reset window
  - 7d rolling utilisation
  - optional per-block burn rate (percent per hour)

Uses matplotlib when available; otherwise prints an ASCII sparkline summary so
the command is still useful on a box with no plotting stack.
"""
from __future__ import annotations

import argparse
import csv
import glob
import os
import sys
from datetime import datetime, timezone

DATA = os.environ.get("CLAUDE_USAGE_DATA", os.path.expanduser("~/.local/share/claude-usage"))


def load(days: float | None) -> list[dict]:
    rows: list[dict] = []
    cutoff = None
    if days:
        cutoff = datetime.now(timezone.utc).timestamp() - days * 86400
    for path in sorted(glob.glob(os.path.join(DATA, "history-*.csv"))):
        with open(path, newline="") as fh:
            for r in csv.DictReader(fh):
                try:
                    ts = float(r["ts"])
                except (TypeError, ValueError, KeyError):
                    continue
                if cutoff and ts < cutoff:
                    continue
                def num(key):
                    v = r.get(key) or ""
                    try:
                        return float(v)
                    except ValueError:
                        return None
                rows.append({
                    "ts": ts,
                    "dt": datetime.fromtimestamp(ts, timezone.utc).astimezone(),
                    "session": num("session"),
                    "weekly": num("weekly"),
                    "scoped": num("weekly_scoped"),
                    "scoped_model": r.get("scoped_model") or "scoped",
                    "session_reset": r.get("session_resets_at") or "",
                })
    rows.sort(key=lambda r: r["ts"])
    return rows


def blocks(rows: list[dict]) -> list[list[dict]]:
    """Split into 5-hour windows: a new resets_at value means a new block."""
    out: list[list[dict]] = []
    cur: list[dict] = []
    key = None
    for r in rows:
        if r["session_reset"] != key:
            if cur:
                out.append(cur)
            cur, key = [], r["session_reset"]
        cur.append(r)
    if cur:
        out.append(cur)
    return out


def spark(vals: list[float], width: int = 0) -> str:
    """Sparkline downsampled to `width` columns (peak per bucket)."""
    chars = "▁▂▃▄▅▆▇█"
    vals = [v for v in vals if v is not None]
    if not vals:
        return ""
    width = width or max(20, min(100, (os.get_terminal_size().columns - 14)
                                 if sys.stdout.isatty() else 72))
    if len(vals) > width:
        step = len(vals) / width
        vals = [max(vals[int(i * step):max(int((i + 1) * step), int(i * step) + 1)])
                for i in range(width)]
    lo, hi = 0.0, max(vals) or 1.0
    rng = (hi - lo) or 1.0
    return "".join(chars[min(7, int((v - lo) / rng * 7.99))] for v in vals)


def summarise(rows: list[dict]) -> None:
    print(f"{len(rows)} samples  {rows[0]['dt']:%Y-%m-%d %H:%M} -> {rows[-1]['dt']:%Y-%m-%d %H:%M}\n")
    print(f"5h  {spark([r['session'] for r in rows])}  now {rows[-1]['session']:.0f}%")
    print(f"7d  {spark([r['weekly'] for r in rows])}  now {rows[-1]['weekly']:.0f}%\n")
    print("5-hour blocks (burn rate = percentage points per hour):")
    for b in blocks(rows)[-12:]:
        span_h = (b[-1]["ts"] - b[0]["ts"]) / 3600
        peak = max((r["session"] or 0) for r in b)
        rate = peak / span_h if span_h > 0.05 else 0.0
        print(f"  {b[0]['dt']:%a %d %b %H:%M}  {span_h:5.2f}h  peak {peak:5.1f}%  {rate:5.1f} %/h")


def plot(rows: list[dict], out: str | None, open_it: bool) -> None:
    try:
        import matplotlib
        if out or not os.environ.get("DISPLAY") and sys.platform != "darwin":
            matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates
    except ImportError:
        print("matplotlib not installed - text summary instead "
              "(pip install matplotlib for graphs)\n", file=sys.stderr)
        summarise(rows)
        return

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 7), sharex=True,
                                   gridspec_kw={"height_ratios": [2, 1]})
    x = [r["dt"] for r in rows]
    ax1.plot(x, [r["weekly"] for r in rows], lw=2, label="7-day all", color="#4C78A8")
    if any(r["scoped"] and r["scoped"] > 0 for r in rows):
        label = f"7-day {rows[-1]['scoped_model']}"
        ax1.plot(x, [r["scoped"] for r in rows], lw=1.6, label=label, color="#B279A2")
    for i, b in enumerate(blocks(rows)):
        ax1.plot([r["dt"] for r in b], [r["session"] for r in b], lw=1.3,
                 color="#F58518", label="5-hour session" if i == 0 else None)
    ax1.axhline(100, ls=":", lw=1, color="#888")
    ax1.set_ylabel("utilisation %")
    ax1.set_ylim(0, max(105, max((r["weekly"] or 0) for r in rows) + 5))
    ax1.legend(loc="upper left", frameon=False)
    ax1.grid(alpha=.25)
    ax1.set_title("Claude Code usage limits")

    bs = blocks(rows)
    ax2.bar([b[0]["dt"] for b in bs],
            [max((r["session"] or 0) for r in b) for b in bs],
            width=0.18, color="#F58518", alpha=.8)
    ax2.set_ylabel("peak % per\n5h block")
    ax2.grid(alpha=.25)
    ax2.xaxis.set_major_formatter(mdates.DateFormatter("%a %d %b\n%H:%M"))
    fig.autofmt_xdate()
    fig.tight_layout()

    if out:
        fig.savefig(out, dpi=130)
        print(f"wrote {out}")
        if open_it:
            opener = "open" if sys.platform == "darwin" else "xdg-open"
            os.system(f'{opener} "{out}" >/dev/null 2>&1 &')
    else:
        plt.show()


def main() -> int:
    ap = argparse.ArgumentParser(prog="claude-usage chart")
    ap.add_argument("--days", type=float, default=14, help="how far back to read (0 = all)")
    ap.add_argument("--out", help="write a PNG here instead of showing a window")
    ap.add_argument("--open", action="store_true", dest="open_it",
                    help="open the PNG afterwards (implies --out if unset)")
    ap.add_argument("--text", action="store_true", help="text summary only")
    a = ap.parse_args()

    rows = load(a.days or None)
    if not rows:
        print(f"no history in {DATA} yet - let the poller run for a few minutes",
              file=sys.stderr)
        return 1
    if a.text:
        summarise(rows)
        return 0
    out = a.out or (os.path.join(DATA, "usage.png") if a.open_it else None)
    plot(rows, out, a.open_it)
    return 0


if __name__ == "__main__":
    sys.exit(main())
