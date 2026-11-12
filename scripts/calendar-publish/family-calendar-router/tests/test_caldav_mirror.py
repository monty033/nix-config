import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock
from pathlib import Path

MIRROR_PATH = Path(__file__).resolve().parents[1] / "caldav_mirror.py"
SPEC = importlib.util.spec_from_file_location("caldav_mirror", MIRROR_PATH)
assert SPEC is not None
mirror = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(mirror)

MASTER = b"""BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//test//EN
BEGIN:VTIMEZONE
TZID:America/New_York
BEGIN:STANDARD
DTSTART:19701101T020000
TZOFFSETFROM:-0400
TZOFFSETTO:-0500
TZNAME:EST
RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
END:STANDARD
END:VTIMEZONE
BEGIN:VEVENT
UID:birthday-1@example.com
DTSTAMP:20260101T000000Z
DTSTART;TZID=America/New_York:20000101T090000
RRULE:FREQ=YEARLY
SUMMARY:Lina's Birthday
END:VEVENT
BEGIN:VEVENT
UID:birthday-1@example.com
DTSTAMP:20260101T000000Z
RECURRENCE-ID;TZID=America/New_York:20270101T090000
DTSTART;TZID=America/New_York:20270101T100000
SUMMARY:Lina's Birthday (brunch)
END:VEVENT
BEGIN:VEVENT
UID:school-1@example.com
DTSTAMP:20260101T000000Z
DTSTART;VALUE=DATE:20261112
SUMMARY:No School
END:VEVENT
END:VCALENDAR
"""


class FakeDav:
    """Stands in for the DAV layer; records writes and whether ensure ran."""

    def __init__(self, remote=None, etags=None):
        self.remote = dict(remote or {})
        self.etags = dict(etags or {})
        self.puts = []
        self.deletes = []
        self.ensure_called = []
        self.etag_seq = 0

    def ensure_calendar(self):
        self.ensure_called.append(True)
        return mirror.calendar_path("tester")

    def list_resources(self, ensure=True):
        if ensure:
            self.ensure_calendar()
        if self.etags:
            return dict(self.etags)
        return {name: "etag-" + name[:6] for name in self.remote}

    def put(self, name, body):
        self.puts.append(name)
        self.etag_seq += 1
        self.remote[name] = "etag-" + name[:6]
        self.etags[name] = f"e{self.etag_seq}-{name[:4]}"

    def delete(self, name):
        self.deletes.append(name)
        self.remote.pop(name, None)
        self.etags.pop(name, None)


class ResourceNameTests(unittest.TestCase):
    def test_stable_and_shaped(self):
        first = mirror.resource_name("birthday-1@example.com")
        second = mirror.resource_name("birthday-1@example.com")
        self.assertEqual(first, second)
        self.assertEqual(len(first), 36)
        self.assertTrue(first.endswith(".ics"))
        self.assertNotEqual(first, mirror.resource_name("birthday-2@example.com"))
        self.assertTrue(mirror.LEAF_RE.match(first))


class GroupingTests(unittest.TestCase):
    def test_override_shares_one_uid(self):
        groups, _ = mirror.group_events(MASTER)
        self.assertEqual(sorted(groups), ["birthday-1@example.com", "school-1@example.com"])
        self.assertEqual(len(groups["birthday-1@example.com"]), 2)

    def test_timezones_carried(self):
        _, timezones = mirror.group_events(MASTER)
        self.assertEqual(len(timezones), 1)
        self.assertEqual(str(timezones[0]["TZID"]), "America/New_York")

    def test_empty_feed_is_an_error(self):
        with self.assertRaises(mirror.SourceError):
            mirror.group_events(b"BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n")

    def test_unparseable_feed_is_a_source_error(self):
        with self.assertRaises(mirror.SourceError):
            mirror.group_events(b"\x00not a calendar\x00")

    def test_missing_uid_skipped(self):
        raw = MASTER.replace(b"UID:school-1@example.com", b"")
        groups, _ = mirror.group_events(raw)
        self.assertNotIn("school-1@example.com", groups)


class PayloadTests(unittest.TestCase):
    def test_one_resource_per_uid_and_roundtrip(self):
        import icalendar

        groups, timezones = mirror.group_events(MASTER)
        payloads = mirror.build_payloads(groups, timezones)
        self.assertEqual(len(payloads), 2)
        birthday = payloads[mirror.resource_name("birthday-1@example.com")]
        parsed = icalendar.Calendar.from_ical(birthday)
        self.assertEqual(len(parsed.walk("VEVENT")), 2)
        self.assertEqual(len(parsed.walk("VTIMEZONE")), 1)
        self.assertIn("RRULE", birthday)

    def test_each_payload_is_wellformed_alone(self):
        import icalendar

        groups, timezones = mirror.group_events(MASTER)
        payloads = mirror.build_payloads(groups, timezones)
        for uid, comps in groups.items():
            body = payloads[mirror.resource_name(uid)]
            self.assertTrue(body.startswith("BEGIN:VCALENDAR"))
            self.assertEqual(len(icalendar.Calendar.from_ical(body).walk("VEVENT")), len(comps))


class PlanTests(unittest.TestCase):
    def test_empty_server_creates_everything(self):
        desired = {"a.ics": "A", "b.ics": "B"}
        actions = mirror.plan(desired, {}, {})
        self.assertEqual(actions, [("put", "a.ics"), ("put", "b.ics")])

    def test_identical_state_is_a_noop(self):
        desired = {"a.ics": "A"}
        state = {"a.ics": {"hash": mirror.body_hash("A"), "etag": "e1"}}
        self.assertEqual(mirror.plan(desired, {"a.ics": "e1"}, state), [])

    def test_changed_body_is_an_update(self):
        desired = {"a.ics": "A2"}
        state = {"a.ics": {"hash": mirror.body_hash("A"), "etag": "e1"}}
        self.assertEqual(mirror.plan(desired, {"a.ics": "e1"}, state), [("put", "a.ics")])

    def test_server_side_drift_is_repaired(self):
        """Same body, different ETag: the resource was edited elsewhere."""
        desired = {"a.ics": "A"}
        state = {"a.ics": {"hash": mirror.body_hash("A"), "etag": "e1"}}
        self.assertEqual(mirror.plan(desired, {"a.ics": "e2"}, state), [("put", "a.ics")])

    def test_missing_recorded_etag_is_not_treated_as_drift(self):
        desired = {"a.ics": "A"}
        state = {"a.ics": {"hash": mirror.body_hash("A"), "etag": ""}}
        self.assertEqual(mirror.plan(desired, {"a.ics": "e9"}, state), [])

    def test_vanished_upstream_resource_is_deleted(self):
        desired = {"a.ics": "A"}
        state = {"a.ics": {"hash": mirror.body_hash("A"), "etag": "e1"},
                 "gone.ics": {"hash": "x", "etag": "e2"}}
        self.assertEqual(mirror.plan(desired, {"a.ics": "e1", "gone.ics": "e2"}, state),
                         [("delete", "gone.ics")])

    def test_unknown_remote_resource_is_adopted(self):
        desired = {"a.ics": "A"}
        self.assertEqual(mirror.plan(desired, {"a.ics": "other"}, {}), [("put", "a.ics")])

    def test_hand_added_resource_is_never_deleted(self):
        """A resource the mirror did not create is left alone."""
        desired = {"a.ics": "A"}
        state = {"a.ics": {"hash": mirror.body_hash("A"), "etag": "e1"}}
        remote = {"a.ics": "e1", "added-by-hand.ics": "e9"}
        self.assertEqual(mirror.plan(desired, remote, state), [])


class ShrinkTests(unittest.TestCase):
    @staticmethod
    def _state(n):
        return {f"r{i}.ics": {"hash": "x", "etag": "e"} for i in range(n)}

    def test_large_drop_is_refused(self):
        with self.assertRaises(mirror.SourceError):
            mirror.check_shrink({f"r{i}.ics": "A" for i in range(2)}, self._state(20))

    def test_small_drop_is_allowed(self):
        mirror.check_shrink({f"r{i}.ics": "A" for i in range(18)}, self._state(20))

    def test_allow_shrink_overrides(self):
        mirror.check_shrink({"r0.ics": "A"}, self._state(20), allow_shrink=True)

    def test_tiny_history_is_not_guarded(self):
        mirror.check_shrink({"r0.ics": "A"}, self._state(3))


class GuardTests(unittest.TestCase):
    def test_calendar_path_is_the_spike_collection(self):
        self.assertEqual(mirror.calendar_path("bernie"),
                         "/remote.php/dav/calendars/bernie/spike-family/")

    def test_other_collections_are_refused(self):
        for bad in (
            "/remote.php/dav/calendars/bernie/family/",
            "/remote.php/dav/calendars/patrick/spike-family/",
            "/remote.php/dav/calendars/bernie/spike-family/other/",
        ):
            with self.assertRaises(mirror.GuardError):
                mirror._checked_path(bad, "bernie")

    def test_allowed_path_passes(self):
        allowed = mirror.calendar_path("bernie")
        self.assertEqual(mirror._checked_path(allowed, "bernie"), allowed)

    def test_direct_child_resource_is_allowed(self):
        child = mirror.calendar_path("bernie") + "abc123.ics"
        self.assertEqual(mirror._checked_path(child, "bernie"), child)

    def test_nested_path_under_the_collection_is_refused(self):
        nested = mirror.calendar_path("bernie") + "abc123.ics/extra.ics"
        with self.assertRaises(mirror.GuardError):
            mirror._checked_path(nested, "bernie")

    def test_percent_encoded_separator_is_refused(self):
        with self.assertRaises(mirror.GuardError):
            mirror._checked_path(
                mirror.calendar_path("bernie") + "..%2F..%2Ffamily%2Fx.ics", "bernie")

    def test_href_decoding_refuses_traversal(self):
        for href in (
            "/remote.php/dav/calendars/bernie/spike-family/..%2F..%2Ffamily%2Fx.ics",
            "/remote.php/dav/calendars/bernie/spike-family/",
            "",
        ):
            with self.assertRaises(mirror.GuardError):
                mirror.name_from_href(href)

    def test_href_decoding_accepts_a_plain_leaf(self):
        self.assertEqual(
            mirror.name_from_href("/remote.php/dav/calendars/bernie/spike-family/abc123.ics"),
            "abc123.ics")

    def test_href_decoding_refuses_nul_and_escaped_leaf(self):
        with self.assertRaises(mirror.GuardError):
            mirror.name_from_href("/x/spike-family/abc%00.ics")


class TransportTests(unittest.TestCase):
    def test_invalid_url_does_not_leak_the_url_or_password(self):
        dav = mirror.Dav("http://[bad-host", "bernie", "s3cr3t-value")
        with self.assertRaises(mirror.DavError) as ctx:
            dav._call("PROPFIND", mirror.calendar_path("bernie"))
        message = str(ctx.exception)
        self.assertNotIn("s3cr3t-value", message)
        self.assertNotIn("bad-host", message)

    def test_delete_of_a_traversing_name_is_refused_before_any_request(self):
        dav = mirror.Dav("http://127.0.0.1:1", "bernie", "x")
        with self.assertRaises(mirror.GuardError):
            dav.delete("../family/x.ics")

    def test_listing_skips_the_collection_and_parses_leaves(self):
        body = (
            '<d:multistatus xmlns:d="DAV:">'
            '<d:response><d:href>/remote.php/dav/calendars/bernie/spike-family/</d:href>'
            "<d:propstat><d:prop><d:getetag/></d:prop></d:propstat></d:response>"
            '<d:response><d:href>/remote.php/dav/calendars/bernie/spike-family/abc123.ics</d:href>'
            "<d:propstat><d:prop><d:getetag>\"e1\"</d:getetag></d:prop></d:propstat></d:response>"
            "</d:multistatus>"
        )
        dav = mirror.Dav("http://127.0.0.1:1", "bernie", "x")
        with mock.patch.object(dav, "_call", return_value=(207, body)):
            self.assertEqual(dav.list_resources(ensure=False), {"abc123.ics": '"e1"'})

    def test_listing_refuses_a_traversing_href(self):
        body = (
            '<d:multistatus xmlns:d="DAV:">'
            '<d:response><d:href>/remote.php/dav/calendars/bernie/spike-family/..%2F..%2Ffamily%2Fx.ics</d:href>'
            "<d:propstat><d:prop><d:getetag>\"e1\"</d:getetag></d:prop></d:propstat></d:response>"
            "</d:multistatus>"
        )
        dav = mirror.Dav("http://127.0.0.1:1", "bernie", "x")
        with mock.patch.object(dav, "_call", return_value=(207, body)):
            with self.assertRaises(mirror.GuardError):
                dav.list_resources(ensure=False)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ics = Path(self.tmp.name) / "family.ics"
        self.ics.write_bytes(MASTER)
        self.state = Path(self.tmp.name) / "state.json"

    def tearDown(self):
        self.tmp.cleanup()

    def test_dry_run_writes_nothing_and_creates_nothing(self):
        dav = FakeDav()
        result = mirror.run(self.ics, apply=False, dav=dav, state_file=self.state)
        self.assertEqual(dav.puts, [])
        self.assertEqual(dav.deletes, [])
        self.assertEqual(dav.ensure_called, [])
        self.assertEqual(result["create"], 2)
        self.assertFalse(result["applied"])
        self.assertFalse(self.state.exists())

    def test_apply_writes_then_second_run_matches(self):
        dav = FakeDav()
        first = mirror.run(self.ics, apply=True, dav=dav, state_file=self.state)
        self.assertTrue(first["applied"])
        self.assertEqual(len(dav.puts), 2)
        self.assertEqual(first["remote_after"], 2)
        self.assertTrue(first["match"])
        self.assertTrue(dav.ensure_called)

        second = mirror.run(self.ics, apply=True, dav=dav, state_file=self.state)
        self.assertEqual(second["create"], 0)
        self.assertEqual(second["update"], 0)
        self.assertEqual(second["delete"], 0)
        self.assertTrue(second["match"])

    def test_upstream_deletion_propagates(self):
        dav = FakeDav()
        mirror.run(self.ics, apply=True, dav=dav, state_file=self.state)
        self.ics.write_bytes(MASTER.split(b"BEGIN:VEVENT\nUID:school-1")[0] + b"END:VCALENDAR\n")
        result = mirror.run(self.ics, apply=True, dav=dav, state_file=self.state)
        self.assertEqual(result["delete"], 1)
        self.assertEqual(len(dav.deletes), 1)
        self.assertEqual(len(dav.remote), 1)

    def test_empty_source_refuses_to_wipe(self):
        self.ics.write_bytes(b"BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n")
        dav = FakeDav()
        with self.assertRaises(mirror.SourceError):
            mirror.run(self.ics, apply=True, dav=dav, state_file=self.state)
        self.assertEqual(dav.deletes, [])

    def test_shrunken_source_refuses_before_any_request(self):
        self.state.write_text(json.dumps(
            {f"r{i}.ics": {"hash": "x", "etag": "e"} for i in range(20)}))
        dav = FakeDav()
        with self.assertRaises(mirror.SourceError):
            mirror.run(self.ics, apply=True, dav=dav, state_file=self.state)
        self.assertEqual(dav.puts, [])
        self.assertEqual(dav.deletes, [])

    def test_state_file_is_private_and_leaves_no_temp(self):
        mirror.run(self.ics, apply=True, dav=FakeDav(), state_file=self.state)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        leftovers = [p.name for p in self.state.parent.iterdir() if p.name.startswith(".state-")]
        self.assertEqual(leftovers, [])


class CredentialTests(unittest.TestCase):
    def test_env_file_is_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".env"
            path.write_text("NEXTCLOUD_URL=https://example.test\n"
                            "NEXTCLOUD_USERNAME=bernie\n"
                            "NEXTCLOUD_PASSWORD=secret\n")
            self.assertEqual(
                mirror.credentials(env={}, env_file=path, use_process_env=False),
                ("https://example.test", "bernie", "secret"))

    def test_explicit_env_overrides_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".env"
            path.write_text("NEXTCLOUD_URL=https://file.test\n"
                            "NEXTCLOUD_USERNAME=fromfile\n"
                            "NEXTCLOUD_PASSWORD=filepw\n")
            got = mirror.credentials(env={"NEXTCLOUD_USERNAME": "explicit"},
                                     env_file=path, use_process_env=False)
            self.assertEqual(got[1], "explicit")
            self.assertEqual(got[2], "filepw")

    def test_missing_values_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(mirror.ConfigError):
                mirror.credentials(env={}, env_file=Path(tmp) / "absent",
                                   use_process_env=False)

    def test_process_env_is_ignored_when_disabled(self):
        os.environ["NEXTCLOUD_URL"] = "https://stale.test"
        try:
            with tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(mirror.ConfigError):
                    mirror.credentials(env={}, env_file=Path(tmp) / "absent",
                                       use_process_env=False)
        finally:
            del os.environ["NEXTCLOUD_URL"]


if __name__ == "__main__":
    unittest.main()
