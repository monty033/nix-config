#!/usr/bin/env python3
"""
Philadelphia Sports Calendar Generator
Generates ICS files for Eagles, Phillies, and Flyers from public league APIs.
"""
import argparse
import json
import sys
import time
from urllib.error import HTTPError, URLError
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

OUT_DIR = Path(__file__).parent / "output"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
DTSTAMP = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
RETRY_DELAYS = (2, 5, 15)


def slug(name: str) -> str:
    return (name.lower()
            .replace(" ", "-").replace(".", "").replace("'", "")
            .replace("/", "-").replace("&", "and")
            .replace("ü", "u").replace("ö", "o").replace("ä", "a"))


def fmt_utc(dt: datetime) -> str:
    return dt.strftime("%Y%m%dT%H%M%SZ")


def active_nhl_season_year(now=None) -> int:
    now = now or datetime.now(timezone.utc)
    return now.year if now.month >= 7 else now.year - 1


def active_mlb_season_year(now=None) -> int:
    """Use the current season through winter, then switch at spring training."""
    now = now or datetime.now(timezone.utc)
    return now.year if now.month >= 3 else now.year - 1


def active_nfl_season_year(now=None) -> int:
    now = now or datetime.now(timezone.utc)
    return now.year - 1 if now.month <= 2 else now.year


def make_vevent(uid, summary, dtstart, dtend, location, description, categories, tz=""):
    summary = summary.replace("Philadelphia ", "")
    lines = [
        "BEGIN:VEVENT",
        f"UID:{uid}",
        f"DTSTART:{dtstart}",
        f"DTEND:{dtend}",
        f"SUMMARY:{summary}",
        f"DESCRIPTION:{description}",
        f"LOCATION:{location}",
        f"CATEGORIES:{categories}",
        "STATUS:CONFIRMED",
        f"DTSTAMP:{DTSTAMP}",
    ]
    if tz:
        lines.append(f"X-TIMEZONE:{tz}")
    lines.append("END:VEVENT")
    return "\r\n".join(lines)


def make_calendar(events, cal_name, prodid_label):
    header = "\r\n".join([
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        f"PRODID:-//philly-sports-cal//{prodid_label}//EN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        f"X-WR-CALNAME:{cal_name}",
        "X-WR-TIMEZONE:UTC",
    ])
    return f"{header}\r\n" + "\r\n".join(events) + "\r\nEND:VCALENDAR\r\n"


def fetch_json(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    attempts = len(RETRY_DELAYS) + 1
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read())
        except HTTPError as error:
            status = error.code
            # A permanent client error will not improve during this run. Log it
            # and let the next scheduled run retry the source four hours later.
            if 400 <= status < 500 and status not in (408, 429):
                print(
                    f"ERROR fetch_json url={url} attempt={attempt}/{attempts} "
                    f"status={status} permanent=true",
                    file=sys.stderr,
                )
                raise
            failure = f"status={status}"
            last_error = error
        except (URLError, TimeoutError, json.JSONDecodeError) as error:
            failure = type(error).__name__
            last_error = error

        if attempt == attempts:
            print(
                f"ERROR fetch_json url={url} attempts={attempts} "
                f"failure={failure} final=true",
                file=sys.stderr,
            )
            raise last_error

        delay = RETRY_DELAYS[attempt - 1]
        print(
            f"WARNING fetch_json url={url} attempt={attempt}/{attempts} "
            f"failure={failure} retry_in={delay}s",
            file=sys.stderr,
        )
        time.sleep(delay)


# ── NHL (Flyers) ──────────────────────────────────────────────

def fetch_flyers(season_year=None):
    print("Flyers: fetching from nhle.com...")
    season_year = season_year or active_nhl_season_year()
    games = {}
    failures = []
    start = datetime(season_year, 7, 1)
    end = datetime(season_year + 1, 6, 30)
    current = start

    while current <= end:
        date_str = current.strftime("%Y-%m-%d")
        try:
            data = fetch_json(f"https://api-web.nhle.com/v1/schedule/{date_str}")
            for day in data.get("gameWeek", []):
                for g in day.get("games", []):
                    game_type = g.get("gameType", 0)
                    if game_type not in (2, 3):
                        continue
                    home = g.get("homeTeam", {})
                    away = g.get("awayTeam", {})
                    home_name = f"{home.get('placeName', {}).get('default', '')} {home.get('commonName', {}).get('default', '')}".strip()
                    away_name = f"{away.get('placeName', {}).get('default', '')} {away.get('commonName', {}).get('default', '')}".strip()
                    if not home_name or not away_name:
                        failures.append((date_str, f"game {g.get('id', 'unknown')} has missing team names"))
                        continue
                    # Only want Flyers games
                    if "Flyers" not in home_name and "Flyers" not in away_name:
                        continue
                    if not g.get("id") or not g.get("startTimeUTC"):
                        failures.append((date_str, f"game {g.get('id', 'unknown')} has missing identity or start time"))
                        continue
                    games[g["id"]] = {
                        "id": g["id"],
                        "game_type": game_type,
                        "local_date": day.get("date", ""),
                        "home": home_name,
                        "away": away_name,
                        "venue": g.get("venue", {}).get("default", "TBD"),
                        "start_utc": g.get("startTimeUTC", ""),
                    }
        except Exception as e:
            failures.append((date_str, str(e)))
        current += timedelta(days=7)

    if failures:
        details = "; ".join(f"{date}: {error}" for date, error in failures[:3])
        raise RuntimeError(f"Flyers fetch incomplete ({len(failures)} failures): {details}")

    events = []
    for g in sorted(games.values(), key=lambda x: x["start_utc"]):
        try:
            dt = datetime.fromisoformat(g["start_utc"].replace("Z", "+00:00"))
        except ValueError as error:
            raise RuntimeError(f"Flyers game {g.get('id', 'unknown')} has invalid start time") from error
        if g["game_type"] == 3:
            uid = f"nhl-{season_year}-{str(season_year + 1)[-2:]}-{g['id']}@philly-sports-cal"
        else:
            away_s, home_s = slug(g["away"]), slug(g["home"])
            uid = f"nhl-{season_year}-{str(season_year + 1)[-2:]}-{g['local_date']}-{away_s}-vs-{home_s}@philly-sports-cal"
        summary = f"{g['away']} @ {g['home']}"
        description = f"NHL {season_year}-{str(season_year + 1)[-2:]}\\n{g['away']} @ {g['home']}\\n{g['venue']}"
        events.append(make_vevent(uid, summary, fmt_utc(dt), fmt_utc(dt + timedelta(hours=3)),
                                  g["venue"], description, "Hockey,NHL", "America/New_York"))

    print(f"  {len(events)} Flyers games")
    return events


# ── MLB (Phillies) ────────────────────────────────────────────

def fetch_phillies(season_year=None):
    print("Phillies: fetching from statsapi.mlb.com...")
    season_year = season_year or active_mlb_season_year()
    game_types = "R,F,D,L,W"
    months = [
        (f"{season_year}-03-20", f"{season_year}-03-31"),
        (f"{season_year}-04-01", f"{season_year}-04-30"),
        (f"{season_year}-05-01", f"{season_year}-05-31"),
        (f"{season_year}-06-01", f"{season_year}-06-30"),
        (f"{season_year}-07-01", f"{season_year}-07-31"),
        (f"{season_year}-08-01", f"{season_year}-08-31"),
        (f"{season_year}-09-01", f"{season_year}-09-30"),
        (f"{season_year}-10-01", f"{season_year}-11-10"),
    ]

    all_games = []
    failures = []
    for start, end in months:
        url = (f"https://statsapi.mlb.com/api/v1/schedule"
               f"?sportId=1&season={season_year}&gameType={game_types}"
               f"&startDate={start}&endDate={end}"
               f"&fields=dates,date,games,gamePk,gameDate,gameType,teams,away,home,team,name,venue")
        try:
            data = fetch_json(url)
            for date_obj in data.get("dates", []):
                for g in date_obj.get("games", []):
                    away = g["teams"]["away"]["team"]["name"]
                    home = g["teams"]["home"]["team"]["name"]
                    if "Phillies" not in home and "Phillies" not in away:
                        continue
                    if not g.get("gamePk"):
                        raise ValueError("Phillies game missing gamePk")
                    all_games.append({
                        "game_pk": g["gamePk"],
                        "game_type": g.get("gameType", "R"),
                        "date": date_obj["date"],
                        "dt_str": g["gameDate"],
                        "away": away,
                        "home": home,
                        "venue": g.get("venue", {}).get("name", "TBD"),
                    })
            print(f"  {start[:7]}: fetched")
        except Exception as e:
            failures.append((start[:7], str(e)))

    if failures:
        details = "; ".join(f"{month}: {error}" for month, error in failures[:3])
        raise RuntimeError(f"Phillies fetch incomplete ({len(failures)} failures): {details}")

    events = []
    seen = set()
    for g in all_games:
        try:
            dt = datetime.fromisoformat(g["dt_str"].replace("Z", "+00:00"))
        except ValueError as error:
            raise RuntimeError(f"Phillies game on {g.get('date', 'unknown')} has invalid start time") from error
        if g["game_type"] != "R":
            uid = f"mlb-{season_year}-{g['game_pk']}@philly-sports-cal"
        else:
            away_s, home_s = slug(g["away"]), slug(g["home"])
            uid = f"mlb-{season_year}-{g['date']}-{g['game_pk']}-{away_s}-vs-{home_s}@philly-sports-cal"
        if uid in seen:
            continue
        seen.add(uid)
        summary = f"{g['away']} @ {g['home']}"
        description = f"MLB {season_year}\\n{g['away']} @ {g['home']}\\n{g['venue']}"
        events.append(make_vevent(uid, summary, fmt_utc(dt), fmt_utc(dt + timedelta(hours=3)),
                                  g["venue"], description, "Baseball,MLB", "America/New_York"))

    print(f"  {len(events)} Phillies games")
    return events


# ── NFL (Eagles) ──────────────────────────────────────────────

def fetch_eagles(season_year=None):
    print("Eagles: fetching from ESPN API...")
    season_year = season_year or active_nfl_season_year()
    base_url = (
        "https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/"
        f"teams/phi/schedule?season={season_year}&region=us&lang=en&contentorigin=espn"
    )
    raw_events = []
    seen_ids = set()
    for url in (base_url, f"{base_url}&seasontype=3"):
        data = fetch_json(url)
        for event in data.get("events", []):
            event_id = event.get("id")
            if event_id in seen_ids:
                continue
            seen_ids.add(event_id)
            raw_events.append(event)

    events = []
    for event in raw_events:
        try:
            dt_str = event.get("date", "")
            if not dt_str or not event.get("id"):
                raise ValueError("missing event id or date")
            dt = datetime.fromisoformat(dt_str.replace("Z", "+00:00"))
        except ValueError as error:
            raise RuntimeError(f"Eagles event {event.get('id', 'unknown')} is malformed") from error

        name = event.get("name", "TBD")
        venue = event.get("venue", {}).get("fullName", "TBD")
        location = event.get("venue", {}).get("address", {}).get("city", "")
        if location:
            venue = f"{venue}, {location}"

        # Extract week number if available
        week_num = event.get("week", {}).get("number", "")
        try:
            season_type = int(event.get("seasonType", {}).get("type", 0))
        except (TypeError, ValueError):
            season_type = 0
        if season_type == 2:  # regular season
            summary = f"[Wk {week_num}] {name}" if week_num else name
            desc_type = "NFL Regular Season"
        elif season_type == 1:  # preseason
            summary = f"[Pre] {name}"
            desc_type = "NFL Preseason"
        elif season_type == 3:  # postseason
            summary = f"[Playoffs] {name}"
            desc_type = "NFL Playoffs"
        else:
            summary = name
            desc_type = "NFL"

        uid = f"nfl-eagles-{season_year}-{event.get('id', '')}@philly-sports-cal"
        description = f"{desc_type}\\n{summary}\\n{venue}"
        events.append(make_vevent(uid, summary, fmt_utc(dt), fmt_utc(dt + timedelta(hours=3)),
                                  venue, description, "Football,NFL", "America/New_York"))

    print(f"  {len(events)} Eagles games")
    return events


# ── Main ──────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).parent / "output",
        help="directory for the complete generated feed set",
    )
    args = parser.parse_args()
    out_dir = args.output_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    teams = [
        ("flyers", "Philadelphia Flyers", fetch_flyers),
        ("phillies", "Philadelphia Phillies", fetch_phillies),
        ("eagles", "Philadelphia Eagles", fetch_eagles),
    ]

    for slug_name, cal_name, fetch_fn in teams:
        try:
            events = fetch_fn()
            ics = make_calendar(events, cal_name, cal_name)
            out_path = out_dir / f"{slug_name}.ics"
            out_path.write_text(ics, encoding="utf-8")
            print(f"  Wrote {out_path} ({len(events)} events)")
        except Exception as e:
            print(f"ERROR {slug_name}: {e}", file=sys.stderr)
            sys.exit(1)

    print("\nDone.")

    # Validate the exact generated set before returning success.
    print("\nValidating...")
    from validate import validate_ics
    all_ok = True
    for slug_name, _, _ in teams:
        path = out_dir / f"{slug_name}.ics"
        errors = validate_ics(path)
        if errors:
            all_ok = False
            print(f"FAIL {path.name}:")
            for e in errors:
                print(f"  - {e}")
        else:
            print(f"OK   {path.name}")

    if not all_ok:
        print("\nValidation FAILED", file=sys.stderr)
        sys.exit(1)
    print("\nAll files valid.")


if __name__ == "__main__":
    main()
