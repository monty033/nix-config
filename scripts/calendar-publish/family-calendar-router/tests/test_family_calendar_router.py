import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone
from email.message import Message
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError


REAL_SUBPROCESS_RUN = subprocess.run


ROUTER_PATH = Path(__file__).resolve().parents[1] / "router.py"
SPEC = importlib.util.spec_from_file_location("family_calendar_router", ROUTER_PATH)
assert SPEC is not None
router = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(router)


ICAL = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//MontyCasa//Family Calendar//EN
BEGIN:VEVENT
UID:test-proton-event@example.com
DTSTART:20260825T120000Z
DTEND:20260825T130000Z
SUMMARY:#patrick Proton test event
END:VEVENT
END:VCALENDAR
"""


def school_ical(*events: str) -> str:
    return "BEGIN:VCALENDAR\nVERSION:2.0\n" + "".join(
        f"BEGIN:VEVENT\n{event}\nEND:VEVENT\n" for event in events
    ) + "END:VCALENDAR\n"


SCHOOL_FILTER_ICAL = school_ical(
    "UID:hs-only@example.com\n"
    "DTSTART:20260910T180000\n"
    "DTEND:20260910T193000\n"
    "SUMMARY:High School Back to School Night",
    "UID:mixed-elementary@example.com\n"
    "DTSTART:20260911\n"
    "DTEND:20260912\n"
    "SUMMARY:Early Dismissal - HS & MS - ENF & ERD",
)


class FakeResponse:
    def __init__(self, body: str):
        self.body = body.encode()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self):
        return self.body


class FamilyCalendarRouterTests(unittest.TestCase):
    def test_fetch_proton_reads_url_file_and_parses_remote_calendar(self):
        with tempfile.TemporaryDirectory() as tmp:
            url_file = Path(tmp) / "proton-url"
            secret_url = "https://calendar.example.invalid/redacted-token"
            url_file.write_text(secret_url)
            original = getattr(router, "PROTON_ICAL_URL_FILE")
            setattr(router, "PROTON_ICAL_URL_FILE", str(url_file))
            try:
                with patch.object(router, "urlopen", return_value=FakeResponse(ICAL)) as fetch:
                    events = router.fetch_proton()
            finally:
                setattr(router, "PROTON_ICAL_URL_FILE", original)

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["source"], "proton")
        fetch.assert_called_once()
        self.assertNotIn(secret_url, str(fetch.call_args))

    def test_fetch_remote_ical_retries_transient_http_failure(self):
        error = HTTPError(
            "https://calendar.example.invalid/redacted-token",
            503,
            "unavailable",
            Message(),
            io.BytesIO(b"temporary failure"),
        )
        with patch.object(router, "urlopen", side_effect=[error, FakeResponse(ICAL)]) as fetch:
            with patch.object(router.time, "sleep") as sleep:
                raw = router.fetch_remote_ical(
                    "https://calendar.example.invalid/redacted-token",
                    "Proton",
                )

        self.assertTrue(raw.startswith("BEGIN:VCALENDAR"))
        self.assertEqual(fetch.call_count, 2)
        sleep.assert_called_once_with(2)

    def test_missing_proton_secret_fails_closed(self):
        original = getattr(router, "PROTON_ICAL_URL_FILE")
        setattr(router, "PROTON_ICAL_URL_FILE", "/does/not/exist/proton-url")
        try:
            with self.assertRaisesRegex(RuntimeError, "secret file not found") as raised:
                router.fetch_proton()
        finally:
            setattr(router, "PROTON_ICAL_URL_FILE", original)
        self.assertNotIn("calendar.example.invalid", str(raised.exception))

    def test_empty_proton_secret_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            url_file = Path(tmp) / "proton-url"
            url_file.write_text("\n")
            original = getattr(router, "PROTON_ICAL_URL_FILE")
            setattr(router, "PROTON_ICAL_URL_FILE", str(url_file))
            try:
                with self.assertRaisesRegex(RuntimeError, "secret file is empty"):
                    router.fetch_proton()
            finally:
                setattr(router, "PROTON_ICAL_URL_FILE", original)

    def test_fetch_remote_ical_sanitizes_malformed_url_errors(self):
        secret_url = "https://calendar.example.invalid/redacted-token"
        with patch.object(router, "urlopen", side_effect=ValueError(secret_url)):
            with patch.object(router.time, "sleep"):
                with patch("sys.stderr", new_callable=io.StringIO) as stderr:
                    with self.assertRaisesRegex(RuntimeError, "invalid URL"):
                        router.fetch_remote_ical(secret_url, "Proton")
        self.assertNotIn(secret_url, stderr.getvalue())

    def test_fetch_school_retries_and_refuses_partial_feeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            files = []
            for name in ("district", "enf"):
                path = Path(tmp) / name
                path.write_text(f"https://school.example.invalid/{name}")
                files.append(str(path))

            original_files = router.SDST_ICAL_URL_FILES
            router.SDST_ICAL_URL_FILES = files
            good = subprocess.CompletedProcess(
                args=["curl"], returncode=0, stdout=ICAL, stderr=""
            )
            bad = subprocess.CompletedProcess(
                args=["curl"], returncode=7, stdout="", stderr="network down"
            )
            try:
                with patch.object(router.subprocess, "run", side_effect=[good, bad, bad, bad, bad]) as run:
                    with patch.object(router.time, "sleep") as sleep:
                        self.assertEqual(router.fetch_school(), [])
            finally:
                router.SDST_ICAL_URL_FILES = original_files

        self.assertEqual(run.call_count, 5)
        self.assertEqual(sleep.call_args_list, [mock.call(2), mock.call(5), mock.call(15)])

        secret_url = "https://calendar.example.invalid/redacted-token"
        error = HTTPError(secret_url, 403, "forbidden", Message(), io.BytesIO())
        with patch.object(router, "urlopen", side_effect=error):
            with patch("sys.stderr", new_callable=io.StringIO) as stderr:
                with self.assertRaisesRegex(RuntimeError, "HTTP 403"):
                    router.fetch_remote_ical(secret_url, "Proton")
        self.assertNotIn(secret_url, stderr.getvalue())

    def test_fetch_school_excludes_hs_ms_only_events(self):
        with tempfile.TemporaryDirectory() as tmp:
            url_file = Path(tmp) / "district"
            url_file.write_text("https://school.example.invalid/district")
            original_files = router.SDST_ICAL_URL_FILES
            router.SDST_ICAL_URL_FILES = [str(url_file)]
            good = subprocess.CompletedProcess(
                args=["curl"], returncode=0, stdout=SCHOOL_FILTER_ICAL, stderr=""
            )
            try:
                with patch.object(router.subprocess, "run", return_value=good):
                    events = router.fetch_school()
            finally:
                router.SDST_ICAL_URL_FILES = original_files

        self.assertEqual(
            [event["summary"] for event in events],
            ["Early Dismissal - HS & MS - ENF & ERD"],
        )

    def test_fetch_school_deduplicates_same_event_across_feeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            files = []
            for name in ("district", "enf", "erd"):
                path = Path(tmp) / name
                path.write_text(f"https://school.example.invalid/{name}")
                files.append(str(path))

            feeds = [
                school_ical(
                    "UID:district-copy@example.com\n"
                    "DTSTART:20260921\nDTEND:20260922\n"
                    "SUMMARY:Holiday - All Schools Closed/Offices Open"
                ),
                school_ical(
                    "UID:enf-copy@example.com\n"
                    "DTSTART:20260921\nDTEND:20260922\n"
                    "SUMMARY:Holiday - All Schools Closed/Offices Open"
                ),
                school_ical(
                    "UID:erd-copy@example.com\n"
                    "DTSTART:20260921\nDTEND:20260922\n"
                    "SUMMARY:Holiday - All Schools Closed/Offices Open"
                ),
            ]
            original_files = router.SDST_ICAL_URL_FILES
            router.SDST_ICAL_URL_FILES = files
            try:
                with patch.object(
                    router.subprocess,
                    "run",
                    side_effect=[
                        subprocess.CompletedProcess(
                            args=["curl"], returncode=0, stdout=feed, stderr=""
                        )
                        for feed in feeds
                    ],
                ):
                    events = router.fetch_school()
            finally:
                router.SDST_ICAL_URL_FILES = original_files

        self.assertEqual(len(events), 1)
        self.assertEqual(
            events[0]["summary"],
            "Holiday - All Schools Closed/Offices Open",
        )

    def test_fetch_school_includes_new_district_closures(self):
        summaries = [
            "Thanksgiving Break - District Closed",
            "District Closed",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            url_file = Path(tmp) / "district"
            url_file.write_text("https://school.example.invalid/district")
            original_files = router.SDST_ICAL_URL_FILES
            router.SDST_ICAL_URL_FILES = [str(url_file)]
            good = subprocess.CompletedProcess(
                args=["curl"],
                returncode=0,
                stdout=school_ical(*[
                    f"UID:closure-{i}@example.com\nDTSTART:202610{i+1:02d}\n"
                    f"DTEND:202610{i+2:02d}\nSUMMARY:{summary}"
                    for i, summary in enumerate(summaries)
                ]),
                stderr="",
            )
            try:
                with patch.object(router.subprocess, "run", return_value=good):
                    events = router.fetch_school()
            finally:
                router.SDST_ICAL_URL_FILES = original_files

        self.assertEqual([event["summary"] for event in events], summaries)

    def test_fetch_school_includes_no_school_phrased_closures(self):
        # The district's second closure phrasing (9 live entries: Election Day,
        # conference days, PD days). None of these carry "closed" or a holiday
        # name, so they depend entirely on the "no school" keyword.
        summaries = [
            "Election Day - No School for Students/Professional Development Day",
            "Professional Development/Flex Day/No School for Student",
            "No School for Students - Professional Development Day",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            url_file = Path(tmp) / "district"
            url_file.write_text("https://school.example.invalid/district")
            original_files = router.SDST_ICAL_URL_FILES
            router.SDST_ICAL_URL_FILES = [str(url_file)]
            good = subprocess.CompletedProcess(
                args=["curl"],
                returncode=0,
                stdout=school_ical(*[
                    f"UID:noschool-{i}@example.com\nDTSTART:202610{i+1:02d}\n"
                    f"DTEND:202610{i+2:02d}\nSUMMARY:{summary}"
                    for i, summary in enumerate(summaries)
                ]),
                stderr="",
            )
            try:
                with patch.object(router.subprocess, "run", return_value=good):
                    events = router.fetch_school()
            finally:
                router.SDST_ICAL_URL_FILES = original_files

        self.assertEqual([event["summary"] for event in events], summaries)

    def test_fetch_school_excludes_non_closure_district_and_hs_ms_events(self):
        summaries = [
            "MS/HS MP1 Report Cards Issued",
            "Middle School Picture Day",
            "Book Fair",
            "World Teachers' Day",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            url_file = Path(tmp) / "district"
            url_file.write_text("https://school.example.invalid/district")
            original_files = router.SDST_ICAL_URL_FILES
            router.SDST_ICAL_URL_FILES = [str(url_file)]
            good = subprocess.CompletedProcess(
                args=["curl"], returncode=0,
                stdout=school_ical(*[
                    f"UID:excluded-{i}@example.com\nDTSTART:202610{i+1:02d}\n"
                    f"DTEND:202610{i+2:02d}\nSUMMARY:{summary}"
                    for i, summary in enumerate(summaries)
                ]),
                stderr="",
            )
            try:
                with patch.object(router.subprocess, "run", return_value=good):
                    events = router.fetch_school()
            finally:
                router.SDST_ICAL_URL_FILES = original_files

        self.assertEqual(events, [])

    def test_fetch_school_excludes_events_that_merely_name_a_holiday_word(self):
        # Regression for review finding: keyword matching is substring-based, so
        # the closure keywords must not sweep in events that only mention the
        # holiday in passing (concerts, clubs, meetings).
        summaries = [
            "Thanksgiving Concert",
            "Thanksgiving Board Meeting",
            "Indigenous Students Club",
            "Indigenous Heritage Night",
            # Bare holiday names, plus longer titles that merely name the
            # holiday. The district's own feed treats these as observances,
            # never as closures, so none may reach the public school feed.
            "Indigenous Peoples' Day Assembly",
            "Thanksgiving Break Planning Meeting",
            "Indigenous Peoples' Day",
            "Thanksgiving Break",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            url_file = Path(tmp) / "district"
            url_file.write_text("https://school.example.invalid/district")
            original_files = router.SDST_ICAL_URL_FILES
            router.SDST_ICAL_URL_FILES = [str(url_file)]
            good = subprocess.CompletedProcess(
                args=["curl"], returncode=0,
                stdout=school_ical(*[
                    f"UID:nonclosure-{i}@example.com\nDTSTART:202610{i+1:02d}\n"
                    f"DTEND:202610{i+2:02d}\nSUMMARY:{summary}"
                    for i, summary in enumerate(summaries)
                ]),
                stderr="",
            )
            try:
                with patch.object(router.subprocess, "run", return_value=good):
                    events = router.fetch_school()
            finally:
                router.SDST_ICAL_URL_FILES = original_files

        self.assertEqual(events, [])

    def test_fetch_school_includes_labor_day_district_closure(self):
        with tempfile.TemporaryDirectory() as tmp:
            url_file = Path(tmp) / "district"
            url_file.write_text("https://school.example.invalid/district")
            original_files = router.SDST_ICAL_URL_FILES
            router.SDST_ICAL_URL_FILES = [str(url_file)]
            good = subprocess.CompletedProcess(
                args=["curl"],
                returncode=0,
                stdout=school_ical(
                    "UID:labor-day@example.com\n"
                    "DTSTART:20260907\n"
                    "DTEND:20260908\n"
                    "SUMMARY:Labor Day - District Closed"
                ),
                stderr="",
            )
            try:
                with patch.object(router.subprocess, "run", return_value=good):
                    events = router.fetch_school()
            finally:
                router.SDST_ICAL_URL_FILES = original_files

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["summary"], "Labor Day - District Closed")

    def test_fetch_google_missing_secret_fails_closed(self):
        original = getattr(router, "LINA_ICAL_URL_FILE")
        setattr(router, "LINA_ICAL_URL_FILE", "/does/not/exist/google-url")
        try:
            with self.assertRaisesRegex(RuntimeError, "Google URL secret file not found"):
                router.fetch_google()
        finally:
            setattr(router, "LINA_ICAL_URL_FILE", original)

    def test_route_untagged_event_to_family(self):
        event = {
            "uid": "untagged@example.com",
            "summary": "Family dinner",
            "description": "",
            "start": datetime.now(timezone.utc),
            "rrule": None,
        }
        calendars = router.route_events([event])
        self.assertEqual(calendars["family"], [event])
    def test_scp_to_ha_preserves_unrelated_feeds_on_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            remote_dir = base / "calendars"
            remote_dir.mkdir()
            (remote_dir / "family.ics").write_text("old family")
            (remote_dir / "lina.ics").write_text("old Lina")
            (remote_dir / "unrelated.ics").write_text("leave me")
            outputs = {}
            for name, content in (("family", "new family"), ("lina", "new Lina")):
                path = base / f"{name}.ics"
                path.write_text(content)
                outputs[name] = str(path)

            original_target = router.HA_TARGET
            self._ha_fake_bin = None
            router.HA_TARGET = f"root@fake:{base}"
            try:
                with patch.object(router.subprocess, "run", side_effect=self._fake_ha_run):
                    self.assertTrue(router.scp_to_ha(outputs))
            finally:
                router.HA_TARGET = original_target
                self._ha_fake_bin = None

            self.assertEqual((remote_dir / "family.ics").read_text(), "new family")
            self.assertEqual((remote_dir / "lina.ics").read_text(), "new Lina")
            self.assertEqual((remote_dir / "unrelated.ics").read_text(), "leave me")

    def test_scp_to_ha_rolls_back_partial_feed_swap(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            remote_dir = base / "calendars"
            remote_dir.mkdir()
            (remote_dir / "family.ics").write_text("old family")
            (remote_dir / "lina.ics").write_text("old Lina")
            outputs = {}
            for name, content in (("family", "new family"), ("lina", "new Lina")):
                path = base / f"{name}.ics"
                path.write_text(content)
                outputs[name] = str(path)

            fake_bin = base / "bin"
            fake_bin.mkdir()
            fake_mv = fake_bin / "mv"
            fake_mv.write_text(
                "#!/bin/sh\n"
                "case \"$1\" in *lina.ics.new) exit 1;; esac\n"
                "exec /run/current-system/sw/bin/mv \"$@\"\n"
            )
            fake_mv.chmod(0o755)
            self._ha_fake_bin = fake_bin
            original_target = router.HA_TARGET
            router.HA_TARGET = f"root@fake:{base}"
            try:
                with patch.object(router.subprocess, "run", side_effect=self._fake_ha_run):
                    self.assertFalse(router.scp_to_ha(outputs))
            finally:
                router.HA_TARGET = original_target
                self._ha_fake_bin = None

            self.assertEqual((remote_dir / "family.ics").read_text(), "old family")
            self.assertEqual((remote_dir / "lina.ics").read_text(), "old Lina")
            self.assertFalse((remote_dir / "family.ics.new").exists())
            self.assertFalse((remote_dir / "lina.ics.new").exists())

    def test_scp_to_ha_cleans_uploaded_staging_files_on_upload_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            outputs = {}
            for name in ("family", "lina"):
                path = base / f"{name}.ics"
                path.write_text(name)
                outputs[name] = str(path)

            calls = []
            scp_count = 0

            def fail_second_upload(args, **kwargs):
                nonlocal scp_count
                calls.append(args)
                if args[0] == "scp":
                    scp_count += 1
                    if scp_count == 2:
                        raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0)

            original_target = router.HA_TARGET
            router.HA_TARGET = f"root@fake:{base}"
            try:
                with patch.object(router.subprocess, "run", side_effect=fail_second_upload):
                    self.assertFalse(router.scp_to_ha(outputs))
            finally:
                router.HA_TARGET = original_target

            cleanup_calls = [
                args[-1] for args in calls
                if args[0] == "ssh" and args[-1].startswith("rm -f")
            ]
            self.assertEqual(len(cleanup_calls), 1)
            self.assertIn("family.ics.new", cleanup_calls[0])
            self.assertIn("lina.ics.new", cleanup_calls[0])

    def test_school_publication_cleans_staging_file_on_unexpected_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            filepath = Path(tmp) / "school.ics"
            filepath.write_text("calendar")
            calls = []

            def fail_publish(args, **kwargs):
                calls.append(args)
                if len(calls) == 2:
                    raise RuntimeError("unexpected SSH failure")
                return subprocess.CompletedProcess(args, 0)

            with patch.object(router.subprocess, "run", side_effect=fail_publish):
                with self.assertRaisesRegex(RuntimeError, "unexpected SSH failure"):
                    router.scp_school_to_public(str(filepath))

            self.assertEqual(calls[-1][-1], "rm -f /var/www/ical/school.ics.new")

    def _fake_ha_run(self, args, **kwargs):
        def finish(result):
            if kwargs.get("check") and result.returncode:
                raise subprocess.CalledProcessError(result.returncode, args)
            return result

        if args[0] == "scp":
            source = Path(args[-2])
            destination = args[-1].split(":", 1)[1]
            destination = Path(destination)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.read_bytes())
            return subprocess.CompletedProcess(args, 0)

        if args[0] == "ssh":
            command = args[-1]
            if command.startswith("ls "):
                directory = Path(command[3:].rstrip("/"))
                stdout = "\n".join(path.name for path in directory.iterdir()) + "\n"
                return subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="")
            if command.startswith("rm "):
                Path(command[3:]).unlink(missing_ok=True)
                return subprocess.CompletedProcess(args, 0)
            env = os.environ.copy()
            fake_bin = getattr(self, "_ha_fake_bin", None)
            if fake_bin:
                env["PATH"] = f"{fake_bin}:{env['PATH']}"
            result = REAL_SUBPROCESS_RUN(
                ["/run/current-system/sw/bin/bash", "-c", command],
                capture_output=True,
                text=True,
                env=env,
            )
            return finish(result)

        return subprocess.CompletedProcess(args, 0)


if __name__ == "__main__":
    unittest.main()
