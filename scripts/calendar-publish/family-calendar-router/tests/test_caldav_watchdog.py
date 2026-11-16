"""Watchdog behaviour: silence when healthy, one fixed phrase per problem."""

import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

WATCHDOG_PATH = Path(__file__).resolve().parents[1] / "caldav_watchdog.py"
SPEC = importlib.util.spec_from_file_location("caldav_watchdog", WATCHDOG_PATH)
assert SPEC is not None
watchdog = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules.setdefault("caldav_watchdog", watchdog)
SPEC.loader.exec_module(watchdog)


class WatchdogCase(unittest.TestCase):
    NOW = datetime(2026, 11, 15, 12, 0, 0, tzinfo=timezone.utc)

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.calendars = self.tmp / "calendars"
        self.calendars.mkdir()
        self.state = self.tmp / "state.json"
        self.spool = self.tmp / "failures.jsonl"
        self.cursor = self.tmp / "watchdog.json"
        self.publish_state = self.tmp / "heartbeat.json"
        self.write_state(minutes_ago=1)
        self.write_feed(minutes_ago=2)

    def tearDown(self):
        self._tmp.cleanup()

    def write_state(self, minutes_ago=1):
        self.state.write_text('{"pairs": {}}')
        stamp = (self.NOW - timedelta(minutes=minutes_ago)).timestamp()
        import os
        os.utime(self.state, (stamp, stamp))

    def write_feed(self, name="family.ics", minutes_ago=2):
        path = self.calendars / name
        path.write_bytes(b"BEGIN:VCALENDAR\nEND:VCALENDAR\n")
        stamp = (self.NOW - timedelta(minutes=minutes_ago)).timestamp()
        import os
        os.utime(path, (stamp, stamp))

    def write_heartbeat(self, minutes_ago=1):
        stamp = self.NOW - timedelta(minutes=minutes_ago)
        self.publish_state.write_text(json.dumps({
            "last_success": stamp.isoformat(timespec="seconds"),
            "calendars": 7, "events": 100, "files": {},
        }))

    def write_failure(self, source="proton", detail="HTTP 429", minutes_ago=0):
        stamp = (self.NOW - timedelta(minutes=minutes_ago)).isoformat(timespec="seconds")
        (self.publish_state.parent / "last-failure.json").write_text(json.dumps({
            "at": stamp, "source": source, "detail": detail,
        }))

    def record(self, code, **extra):
        row = {"at": "2026-11-15T11:59:00+00:00", "unit": "calendar-caldav-mirror",
               "code": code, "pairs": 7, "failed": 1, "empty": 0}
        row.update(extra)
        with self.spool.open("a") as handle:
            handle.write(json.dumps(row) + "\n")

    def run_watchdog(self, now=None, extra=()):
        """Run the watchdog and return its lines."""
        import contextlib
        import io
        buffer = io.StringIO()
        argv = ["--spool", str(self.spool), "--state", str(self.state),
                "--calendars", str(self.calendars), "--cursor", str(self.cursor),
                "--publish-state", str(self.publish_state),
                "--publish-state", str(self.publish_state),
                "--now", (now or self.NOW).isoformat(), "--no-verify", *extra]
        with contextlib.redirect_stdout(buffer):
            code = watchdog.main(argv)
        lines = [line for line in buffer.getvalue().strip().splitlines() if line]
        # Exit code mirrors whether there was anything to say.
        self.assertEqual(code, 1 if lines else 0)
        return lines


class HealthyTests(WatchdogCase):
    def test_silent_when_everything_is_fine(self):
        self.assertEqual(self.run_watchdog(), [])


class FailureTests(WatchdogCase):
    def _run(self):
        return self.run_watchdog()

    def test_each_code_has_its_own_line(self):
        self.record(11)
        self.record(21)
        lines = self._run()
        self.assertEqual(len(lines), 2)
        self.assertIn("could not be read", lines[0])
        self.assertIn("could not write to Nextcloud", lines[1])

    def test_repeated_codes_are_counted_not_repeated(self):
        for _ in range(3):
            self.record(13)
        lines = self._run()
        self.assertEqual(len(lines), 1)
        self.assertIn("refused a feed", lines[0])
        self.assertIn("(3x)", lines[0])

    def test_the_mirror_and_the_hook_report_one_failure_once(self):
        import json as _json
        now = self.NOW
        rows = [
            {"at": now.isoformat(), "unit": "calendar-caldav-mirror",
             "source": "mirror", "code": 13, "pairs": 1, "failed": 1, "empty": 0},
            {"at": (now + timedelta(seconds=3)).isoformat(),
             "unit": "calendar-caldav-mirror", "source": "hook", "code": 13,
             "pairs": 0, "failed": 1, "empty": 0},
        ]
        self.spool.write_text("".join(_json.dumps(r) + "\n" for r in rows))
        lines = self._run()
        self.assertEqual(len(lines), 1)
        self.assertNotIn("(2x)", lines[0])

    def test_the_hook_record_counts_even_with_a_service_suffix(self):
        import json as _json
        self.NOW.isoformat()
        self.spool.write_text(_json.dumps(
            {"at": self.NOW.isoformat(), "unit": "calendar-caldav-mirror.service",
             "source": "hook", "code": 1, "pairs": 0, "failed": 1, "empty": 0}) + "\n")
        lines = self._run()
        self.assertEqual(len(lines), 1)
        self.assertIn("crashed", lines[0])

    def test_a_hook_record_with_a_different_code_is_its_own_failure(self):
        import json as _json
        rows = [
            {"at": self.NOW.isoformat(), "unit": "calendar-caldav-mirror",
             "source": "mirror", "code": 13, "pairs": 1, "failed": 1, "empty": 0},
            {"at": (self.NOW + timedelta(seconds=2)).isoformat(),
             "unit": "calendar-caldav-mirror.service", "source": "hook",
             "code": 1, "pairs": 0, "failed": 1, "empty": 0},
        ]
        self.spool.write_text("".join(_json.dumps(r) + "\n" for r in rows))
        lines = self._run()
        # A refusal followed by a crash is two facts, not one: the crash must
        # not be swallowed just because something else failed two seconds ago.
        self.assertEqual(len(lines), 2)
        self.assertTrue(any("refused a feed" in line for line in lines))
        self.assertTrue(any("crashed" in line for line in lines))

    def test_the_same_failure_reported_twice_is_one_line(self):
        import json as _json
        rows = [
            {"at": self.NOW.isoformat(), "unit": "calendar-caldav-mirror",
             "source": "mirror", "code": 13, "pairs": 1, "failed": 1, "empty": 0},
            {"at": (self.NOW + timedelta(seconds=2)).isoformat(),
             "unit": "calendar-caldav-mirror.service", "source": "hook",
             "code": 13, "pairs": 0, "failed": 1, "empty": 0},
        ]
        self.spool.write_text("".join(_json.dumps(r) + "\n" for r in rows))
        lines = self._run()
        self.assertEqual(len(lines), 1)
        self.assertIn("refused a feed", lines[0])

    def test_unknown_code_still_reports(self):
        self.record(99)
        self.assertIn("failed with code 99", self._run()[0])

    def test_spool_text_cannot_leak(self):
        # A record carrying a URL, a path or an event title must not reach the alert.
        self.record(21, error="GET https://user:pass@host/remote.php/dav/bernie/family/x.ics",
                    summary="Lina's Birthday")
        line = self._run()[0]
        for leaked in ("http", "bernie", "Birthday", "/remote.php"):
            self.assertNotIn(leaked, line)

    def test_cursor_prevents_repeating_an_alert(self):
        self.record(11)
        self.assertEqual(len(self._run()), 1)
        self.assertEqual(self._run(), [])

    def test_a_rotated_spool_is_read_from_the_start(self):
        self.record(11)
        self._run()
        self.spool.unlink()          # rotation: new file, new inode
        self.record(21)
        lines = self._run()
        self.assertTrue(any("Nextcloud" in line for line in lines))


class FreshnessTests(WatchdogCase):
    def _run(self):
        return self.run_watchdog()

    def test_age_behind_the_newest_feed_is_reported(self):
        self.write_feed(minutes_ago=0)
        self.write_state(minutes_ago=45)
        lines = self._run()
        self.assertTrue(any("behind the last published feed" in line for line in lines))

    def test_a_small_lag_is_tolerated(self):
        self.write_feed(minutes_ago=10)
        self.write_state(minutes_ago=11)
        self.assertEqual(self._run(), [])

    def test_an_old_heartbeat_means_the_publisher_stopped(self):
        self.write_feed(minutes_ago=600)
        self.write_heartbeat(minutes_ago=600)
        lines = self._run()
        self.assertTrue(any("no successful publish for 10 h" in line for line in lines))

    def test_a_fresh_heartbeat_is_silent_even_with_old_feeds(self):
        # An unchanged publish no longer rewrites the files, so an old feed with
        # a fresh heartbeat is a healthy, quiet pipeline.
        self.write_feed(minutes_ago=600)
        self.write_heartbeat(minutes_ago=5)
        self.assertEqual(self._run(), [])

    def test_old_feeds_without_a_heartbeat_fall_back_to_feed_age(self):
        self.write_feed(minutes_ago=600)
        line = next(l for l in self._run() if "publisher" in l)
        self.assertIn("the feeds are 10 h old", line)
        self.assertIn("no readable heartbeat", line)

    def test_a_quiet_mirror_is_not_a_dead_publisher(self):
        # The mirror only saves state when it changes something.
        self.write_state(minutes_ago=150)
        self.write_feed(minutes_ago=140)
        self.assertEqual(self._run(), [])

    def test_a_rate_limited_fetch_is_named(self):
        self.write_feed(minutes_ago=600)
        self.write_heartbeat(minutes_ago=180)
        self.write_failure(source="proton", detail="HTTP 429", minutes_ago=180)
        line = next(l for l in self._run() if "publisher" in l)
        self.assertIn("Proton fetch failing (HTTP 429)", line)
        self.assertIn("3 h", line)

    def test_a_failure_older_than_the_last_success_is_ignored(self):
        # The run after the failure succeeded, so the record is history.
        self.write_feed(minutes_ago=600)
        self.write_heartbeat(minutes_ago=180)
        self.write_failure(source="proton", detail="HTTP 429", minutes_ago=400)
        line = next(l for l in self._run() if "publisher" in l)
        self.assertNotIn("HTTP 429", line)
        self.assertIn("no successful publish for 3 h", line)

    def test_a_healthy_publisher_ignores_an_old_failure_record(self):
        self.write_feed(minutes_ago=5)
        self.write_heartbeat(minutes_ago=5)
        self.write_failure(source="google", detail="HTTP 500", minutes_ago=200)
        self.assertEqual(self._run(), [])

    def test_a_failure_without_a_timezone_is_not_used(self):
        self.write_feed(minutes_ago=600)
        self.write_heartbeat(minutes_ago=180)
        (self.publish_state.parent / "last-failure.json").write_text(
            '{"at": "2026-11-16T06:00:00", "source": "proton", "detail": "HTTP 429"}')
        line = next(l for l in self._run() if "publisher" in l)
        self.assertNotIn("HTTP 429", line)

    def test_a_heartbeat_without_a_timezone_is_not_trusted(self):
        self.publish_state.write_text('{"last_success": "2026-11-16T06:00:00"}')
        self.write_feed(minutes_ago=600)
        line = next(l for l in self._run() if "publisher" in l)
        self.assertIn("no readable heartbeat", line)

    def test_missing_state_is_reported(self):
        self.state.unlink()
        lines = self.run_watchdog()
        self.assertTrue(any("never completed" in line for line in lines))


class ContainsSummaryTests(unittest.TestCase):
    ICS = ("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nSUMMARY:CANARY #family\n"
           "DTSTART;VALUE=DATE:20261120\nEND:VEVENT\nEND:VCALENDAR\n")

    def test_exact_summary_found(self):
        self.assertTrue(watchdog.contains_summary(self.ICS, "CANARY #family"))

    def test_prefix_is_not_a_match(self):
        self.assertFalse(watchdog.contains_summary(self.ICS, "CANARY"))

    def test_unfolded_line_is_matched(self):
        folded = self.ICS.replace("SUMMARY:CANARY #family", "SUMMARY:CANARY #fam\n ily")
        self.assertTrue(watchdog.contains_summary(folded, "CANARY #family"))

    def test_missing_or_empty_inputs(self):
        self.assertFalse(watchdog.contains_summary("", "x"))
        self.assertFalse(watchdog.contains_summary(self.ICS, ""))


class CanaryTests(WatchdogCase):
    def run_with_canary(self, now=None, found=True):
        calls = []

        def fake(summary, collection):
            calls.append((summary, collection))
            return found

        original = watchdog.check_canary
        watchdog.check_canary = fake
        try:
            import contextlib
            import io
            buffer = io.StringIO()
            argv = ["--spool", str(self.spool), "--state", str(self.state),
                    "--calendars", str(self.calendars), "--cursor", str(self.cursor),
                    "--no-verify", "--now", (now or self.NOW).isoformat(),
                    "--canary-summary", "CANARY #family"]
            with contextlib.redirect_stdout(buffer):
                watchdog.main(argv)
        finally:
            watchdog.check_canary = original
        return buffer.getvalue().strip().splitlines(), calls

    def test_present_canary_is_silent(self):
        lines, calls = self.run_with_canary()
        self.assertEqual(lines, [])
        # The default target is the production family calendar now that the
        # trial pair is retired.
        self.assertEqual(calls, [("CANARY #family", "family")])

    def test_missing_canary_alerts(self):
        lines, _ = self.run_with_canary(found=False)
        self.assertTrue(any("canary event is missing" in line for line in lines))

    def test_uncheckable_canary_alerts_but_is_distinguishable(self):
        lines, _ = self.run_with_canary(found=None)
        self.assertTrue(any("could not check the canary" in line for line in lines))

    def test_checked_once_a_day(self):
        _, first = self.run_with_canary()
        _, second = self.run_with_canary(now=self.NOW + timedelta(hours=2))
        self.assertEqual(len(first), 1)
        self.assertEqual(len(second), 0)

    def test_rechecked_the_next_day(self):
        self.run_with_canary()
        _, again = self.run_with_canary(now=self.NOW + timedelta(hours=25))
        self.assertEqual(len(again), 1)


class DeepCheckWiringTests(WatchdogCase):
    def test_the_deep_check_receives_the_configured_pair_list(self):
        seen = []

        def fake(command, extra=None, timeout=300):
            seen.append([command, *(extra or [])])
            return 0

        original = watchdog.run_verify
        watchdog.run_verify = fake
        try:
            import contextlib
            import io
            pairs = str(self.tmp / "pairs.json")
            with contextlib.redirect_stdout(io.StringIO()):
                watchdog.main(["--spool", str(self.spool), "--state", str(self.state),
                               "--calendars", str(self.calendars), "--cursor", str(self.cursor),
                               "--now", self.NOW.isoformat(), "--verify", "/bin/true",
                               "--pairs", pairs, "--state-arg", str(self.state)])
        finally:
            watchdog.run_verify = original
        self.assertEqual(seen, [["/bin/true", "--pairs", pairs, "--state", str(self.state)]])


class CanaryGuardTests(unittest.TestCase):
    def test_a_bad_collection_name_is_refused_before_any_request(self):
        for bad in ["../spike-family", "Spike Family", "", "a/b"]:
            self.assertIsNone(watchdog.check_canary("CANARY #family", bad))


class VerifyTests(WatchdogCase):
    def test_daily_verify_runs_once_and_is_remembered(self):
        calls = []

        def fake_verify(command, extra=None, timeout=300):
            calls.append(command)
            return 0

        original = watchdog.run_verify
        watchdog.run_verify = fake_verify
        try:
            import contextlib
            import io
            with contextlib.redirect_stdout(io.StringIO()):
                watchdog.main(["--spool", str(self.spool), "--state", str(self.state),
                               "--calendars", str(self.calendars), "--cursor", str(self.cursor),
                               "--now", self.NOW.isoformat(), "--verify", "/bin/true"])
                watchdog.main(["--spool", str(self.spool), "--state", str(self.state),
                               "--calendars", str(self.calendars), "--cursor", str(self.cursor),
                               "--now", (self.NOW + timedelta(hours=2)).isoformat(),
                               "--verify", "/bin/true"])
        finally:
            watchdog.run_verify = original
        self.assertEqual(len(calls), 1)

    def test_a_failed_verify_is_reported_with_its_code(self):
        original = watchdog.run_verify
        watchdog.run_verify = lambda command, extra=None, timeout=300: 14
        try:
            import contextlib
            import io
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                watchdog.main(["--spool", str(self.spool), "--state", str(self.state),
                               "--calendars", str(self.calendars), "--cursor", str(self.cursor),
                               "--now", self.NOW.isoformat(), "--verify", "/bin/true"])
        finally:
            watchdog.run_verify = original
        self.assertIn("daily deep check the calendar still differs from the feed",
                      buffer.getvalue())


class PublisherSignalTests(WatchdogCase):
    """The publisher's check must not depend on the mirror having a state file."""

    def test_no_state_file_still_reports_a_dead_publisher(self):
        self.state.unlink()
        self.write_feed(minutes_ago=600)
        lines = self.run_watchdog()
        self.assertTrue(any("never completed" in line for line in lines))
        self.assertTrue(any("the feeds are 10 h old" in line for line in lines))

    def test_an_empty_calendars_directory_is_reported(self):
        for feed in self.calendars.glob("*.ics"):
            feed.unlink()
        lines = self.run_watchdog()
        self.assertTrue(any("no feed files" in line for line in lines))

    def test_a_heartbeat_without_a_timezone_is_reported(self):
        self.publish_state.write_text('{"last_success": "2026-11-16T06:00:00"}')
        self.write_feed(minutes_ago=600)
        line = next(l for l in self.run_watchdog() if "publisher" in l)
        self.assertIn("no readable heartbeat", line)


if __name__ == "__main__":
    unittest.main()
