#!/usr/bin/env python3
"""
Graph provider usage history from SQLite.

Usage:
    python3 graph.py --from 12h --to now          # last 12 hours
    python3 graph.py --from 2026-08-22T00:00 --to 2026-08-22T12:00
    python3 graph.py --from 3d --to now            # last 3 days
    python3 graph.py --from 1w --to now            # last week
    python3 graph.py --from 12h --to now --out /tmp/usage.png

Relative suffixes: m (minutes), h (hours), d (days), w (weeks)
"""
import argparse
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

DB_PATH = Path.home() / ".hermes" / "data" / "usage-history.db"
DEFAULT_OUT = Path("/tmp/usage-graph.png")

# Colors per provider (provider_key -> color)
PROVIDER_COLORS = {
    "codex": "#10b981",       # emerald (will be overridden per window)
    "claude": "#f59e0b",      # orange (will be overridden per window)
    # "minimax": "#f59e0b",     # amber
    "opencodeGo": "#3b82f6",  # blue (base, overridden per window below)
}

# Window overrides: (provider, window) -> (color, linestyle, marker)
WINDOW_OVERRIDES = {
    ("codex", "5h"):      ("#86efac", "-", "o"),      # light green, solid
    ("codex", "weekly"):  ("#15803d", "--", "s"),     # dark green, dashed
    ("claude", "5h"):     ("#fed7aa", "-", "o"),      # light orange, solid
    ("claude", "weekly"): ("#ea580c", "--", "s"),     # dark orange, dashed
    ("opencodeGo", "5h"):     ("#93c5fd", "-",  "o"),    # light blue, solid
    ("opencodeGo", "weekly"): ("#3b82f6", "--", "s"),    # medium blue, dashed
    ("opencodeGo", "monthly"):("#1e40af", ":",  "^"),    # dark blue, dotted
}

# Group by provider: codex first (5h then weekly), claude second (5h then
# weekly), OpenCode Go last (5h, weekly, monthly) to keep clusters adjacent.
SERIES_ORDER = [
    ("codex", "5h"),
    ("codex", "weekly"),
    ("claude", "5h"),
    ("claude", "weekly"),
    ("opencodeGo", "5h"),
    ("opencodeGo", "weekly"),
    ("opencodeGo", "monthly"),
    # ("minimax", "5h"),
]

PROVIDER_LABELS = {
    "codex": "Codex",
    "claude": "Claude",
    "claudePro": "Claude",  # for legacy db entries
    # "minimax": "MiniMax",
    "opencodeGo": "OpenCode Go",
}

WINDOW_LABELS = {
    "5h": "5h",
    "weekly": "weekly",
    "monthly": "monthly",
}

# Default line style per window name
WINDOW_STYLES = {
    "5h": "-",
    "weekly": "--",
    "monthly": ":",
}


def parse_relative(s: str, now: datetime) -> datetime:
    """Parse a relative time string like '12h', '3d', '1w', '45m'."""
    s = s.strip().lower()
    if s == "now":
        return now
    multiplier = {"m": 1, "h": 60, "d": 1440, "w": 10080}
    for suffix, mins in multiplier.items():
        if s.endswith(suffix):
            val = int(s[: -len(suffix)])
            return now - timedelta(minutes=val * mins)
    # Try ISO format
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def fetch_data(conn: sqlite3.Connection, dt_from: str, dt_to: str) -> list[dict]:
    """Fetch snapshots in the time range.

    Claude Pro only reports 5-hour and weekly subscription windows. Ignore
    legacy monthly rows written by the short-lived placeholder collector.
    Filter out minimax data (disabled provider).
    Normalize claudePro to claude for consistent display.
    """
    rows = conn.execute(
        """SELECT ts, provider, window, used_pct, reset_epoch
           FROM snapshots
           WHERE ts >= ? AND ts <= ?
             AND NOT (provider = 'claudePro' AND window = 'monthly')
             AND NOT (provider = 'minimax')
           ORDER BY ts ASC""",
        (dt_from, dt_to),
    ).fetchall()
    return [
        {
            "ts": r[0],
            "provider": "claude" if r[1] == "claudePro" else r[1],
            "window": r[2],
            "used_pct": r[3],
            "reset_epoch": r[4],
        }
        for r in rows
    ]


def render_chart(
    data: list[dict],
    dt_from: datetime,
    dt_to: datetime,
    out_path: Path,
) -> None:
    """Render the usage chart as PNG."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    from matplotlib.dates import AutoDateLocator, DateFormatter
    from matplotlib.ticker import PercentFormatter

    fig, ax = plt.subplots(figsize=(14, 7))
    fig.patch.set_facecolor("#1a1a2e")
    ax.set_facecolor("#16213e")

    # Convert all timestamps to Eastern, then strip tzinfo so matplotlib's
    # date locator picks clean EDT-aligned ticks.
    eastern = ZoneInfo("US/Eastern")

    def to_eastern_naive(dt):
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=ZoneInfo("UTC"))
        return dt.astimezone(eastern).replace(tzinfo=None)

    # Group by (provider, window)
    series = {}
    for row in data:
        key = (row["provider"], row["window"])
        if key not in series:
            series[key] = {"ts": [], "pct": [], "reset_epoch": []}
        ts_naive = to_eastern_naive(datetime.fromisoformat(row["ts"]))
        series[key]["ts"].append(ts_naive)
        series[key]["pct"].append(row["used_pct"])
        series[key]["reset_epoch"].append(row["reset_epoch"])

    def format_next_reset(pts) -> str:
        """Format the latest provider-reported next reset for a series."""
        reset_epochs = [epoch for epoch in pts["reset_epoch"] if epoch]
        if not reset_epochs:
            return "next reset unknown"
        reset_dt = datetime.fromtimestamp(reset_epochs[-1], tz=timezone.utc).astimezone(eastern)
        return f"next reset {reset_dt.strftime('%b %-d %I:%M %p %Z')}"

    # Plot each series in a deterministic order so the legend is stable.
    ordered_keys = [key for key in SERIES_ORDER if key in series]
    ordered_keys.extend(sorted(key for key in series if key not in SERIES_ORDER))
    legend_handles = []
    legend_labels = []
    for (provider, window) in ordered_keys:
        pts = series[(provider, window)]
        key = (provider, window)
        color = PROVIDER_COLORS.get(provider, "#94a3b8")
        style = WINDOW_STYLES.get(window, "-")
        marker = "o"
        if key in WINDOW_OVERRIDES:
            color, style, marker = WINDOW_OVERRIDES[key]
        label = (
            f"{PROVIDER_LABELS.get(provider, provider)} — "
            f"{WINDOW_LABELS.get(window, window)} · {format_next_reset(pts)}"
        )
        (line,) = ax.plot(
            pts["ts"],
            [100 - p for p in pts["pct"]],
            color=color,
            linestyle=style,
            linewidth=2,
            marker=marker,
            markersize=5,
            label=label,
            alpha=0.9,
        )
        legend_handles.append(line)
        legend_labels.append(label)

    # Mark reset events — only show reset lines if a sample was taken
    # near a reset (within 1 hour of the snapshot time). This avoids
    # painting every future reset_epoch as a vertical line.
    reset_shown = set()
    for row in data:
        if not row["reset_epoch"]:
            continue
        ts_dt = datetime.fromisoformat(row["ts"])
        reset_utc = datetime.fromtimestamp(row["reset_epoch"], tz=timezone.utc)
        if not (dt_from <= reset_utc <= dt_to):
            continue
        if abs((reset_utc - ts_dt).total_seconds()) > 3600:
            continue
        reset_dt_est = to_eastern_naive(reset_utc)
        # Round to nearest hour to dedupe
        hour_key = reset_dt_est.replace(minute=0, second=0, microsecond=0)
        if hour_key in reset_shown:
            continue
        reset_shown.add(hour_key)
        ax.axvline(x=reset_dt_est, color="#ef4444", linestyle="--", alpha=0.4, linewidth=1)
        ax.annotate(
            "reset",
            xy=(reset_dt_est, 95),
            fontsize=8,
            color="#ef4444",
            alpha=0.7,
            ha="center",
        )

    # Set axis labels and title
    ax.set_ylim(0, 105)
    ax.yaxis.set_major_formatter(PercentFormatter(100))
    ax.set_ylabel("Remaining %", color="white", fontsize=11)
    ax.set_xlabel("Time (EDT)", color="white", fontsize=11)
    ax.set_title("Provider Usage History", color="white", fontsize=13, fontweight="bold")

    # Time axis — 12-hour EDT
    ax.xaxis.set_major_locator(AutoDateLocator(minticks=3, maxticks=8))
    range_hours = (dt_to - dt_from).total_seconds() / 3600
    if range_hours <= 12:
        ax.xaxis.set_major_formatter(DateFormatter("%I:%M %p"))
    elif range_hours <= 72:
        ax.xaxis.set_major_formatter(DateFormatter("%m/%d %I:%M %p"))
    else:
        ax.xaxis.set_major_formatter(DateFormatter("%m/%d"))

    fig.autofmt_xdate(rotation=30, ha="right")

    # Grid
    ax.grid(True, alpha=0.15, color="white")
    ax.tick_params(colors="white")
    for spine in ax.spines.values():
        spine.set_color("#334155")

    # Legend sits above the axes so it cannot cover plotted data. A single
    # column keeps OpenCode Go monthly directly below weekly.
    legend = fig.legend(
        legend_handles,
        legend_labels,
        loc="upper right",
        bbox_to_anchor=(0.99, 0.98),
        ncol=1,
        fontsize=9,
        framealpha=0.3,
    )
    for text in legend.get_texts():
        text.set_color("white")

    plt.tight_layout(rect=(0, 0, 1, 0.84))
    fig.savefig(str(out_path), dpi=150, facecolor=fig.get_facecolor())
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description="Graph provider usage history")
    parser.add_argument("--from", dest="time_from", default="12h", help="Start time (relative or ISO)")
    parser.add_argument("--to", dest="time_to", default="now", help="End time (relative or ISO)")
    parser.add_argument("--out", dest="out_path", default=str(DEFAULT_OUT), help="Output PNG path")
    parser.add_argument("--db", dest="db_path", default=str(DB_PATH), help="SQLite DB path")
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    dt_from = parse_relative(args.time_from, now)
    dt_to = parse_relative(args.time_to, now)

    if dt_from >= dt_to:
        print("ERROR: --from must be before --to", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(args.db_path)
    data = fetch_data(conn, dt_from.isoformat(), dt_to.isoformat())
    conn.close()

    if not data:
        print(f"NO DATA: No snapshots found between {dt_from.isoformat()} and {dt_to.isoformat()}", file=sys.stderr)
        sys.exit(1)

    out = Path(args.out_path)
    render_chart(data, dt_from, dt_to, out)
    print(str(out))


if __name__ == "__main__":
    main()
