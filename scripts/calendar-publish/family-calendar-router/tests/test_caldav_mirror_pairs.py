"""Multi-pair behaviour: one run reconciling several feed→collection pairs.

The single-pair contract lives in test_caldav_mirror.py and must keep passing
unchanged; these tests cover what only shows up with more than one calendar.
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

MIRROR_PATH = Path(__file__).resolve().parents[1] / "caldav_mirror.py"
SPEC = importlib.util.spec_from_file_location("caldav_mirror", MIRROR_PATH)
assert SPEC is not None
mirror = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
# dataclasses and pickling need the module registered under its own name.
sys.modules.setdefault("caldav_mirror", mirror)
SPEC.loader.exec_module(mirror)


def feed(*uids, summary="Event"):
    """A minimal feed holding one VEVENT per UID."""
    parts = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//test//EN"]
    for uid in uids:
        parts += [
            "BEGIN:VEVENT",
            f"UID:{uid}",
            "DTSTAMP:20260101T000000Z",
            "DTSTART;VALUE=DATE:20261112",
            f"SUMMARY:{summary} {uid}",
            "END:VEVENT",
        ]
    parts.append("END:VCALENDAR")
    return ("\n".join(parts) + "\n").encode("utf-8")


class CollectionView:
    """One collection inside FakeAccount."""

    def __init__(self, account, collection):
        self.account = account
        self.collection = collection
        self.remote = account.collections.setdefault(collection, {})
        self.puts = account.puts.setdefault(collection, [])
        self.deletes = account.deletes.setdefault(collection, [])
        self.ensure_called = account.ensure_called.setdefault(collection, [])
        self.bodies = account.bodies.setdefault(collection, {})

    def ensure_calendar(self):
        self.ensure_called.append(True)
        return mirror.calendar_path("tester", self.collection)

    def list_resources(self, ensure=True):
        if ensure:
            self.ensure_calendar()
        return dict(self.remote)

    def collection_exists(self):
        return self.collection not in self.account.missing

    def put(self, name, body):
        self.puts.append(name)
        self.remote[name] = f"etag-{self.collection}-{len(self.puts)}"
        self.bodies[name] = body

    def delete(self, name):
        self.deletes.append(name)
        self.remote.pop(name, None)
        self.bodies.pop(name, None)

    def get(self, name):
        return self.bodies.get(name)


class FakeAccount:
    """A DAV account with several collections, routed by for_collection()."""

    def __init__(self, missing=()):
        self.missing = set(missing)
        self.collections = {}
        self.puts = {}
        self.deletes = {}
        self.ensure_called = {}
        self.bodies = {}

    def for_collection(self, collection):
        return CollectionView(self, collection)


class PairTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.saved = self.tmp / "state.json"

    def tearDown(self):
        self._tmp.cleanup()

    def write_feed(self, name, data):
        path = self.tmp / f"{name}.ics"
        path.write_bytes(data)
        return path


class StateIsolationTests(PairTestCase):
    def test_same_uid_in_two_feeds_stays_independent(self):
        shared = "shared-event@example.com"
        family = mirror.Pair(self.write_feed("family", feed(shared, "fam-2")), "family")
        lina = mirror.Pair(self.write_feed("lina", feed(shared)), "lina")
        dav = FakeAccount()

        results, code = mirror.run_all([family, lina], apply=True, dav=dav,
                                       state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertTrue(all(r["ok"] for r in results))
        # The same UID lands in both collections, each under its own resource.
        self.assertIn(mirror.resource_name(shared), dav.collections["family"])
        self.assertIn(mirror.resource_name(shared), dav.collections["lina"])

        # Removing the event upstream in one feed deletes only that copy.
        lina.feed.write_bytes(feed("other@example.com"))
        results, code = mirror.run_all([family, lina], apply=True, dav=dav,
                                       state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertIn(mirror.resource_name(shared), dav.collections["family"])
        self.assertNotIn(mirror.resource_name(shared), dav.collections["lina"])
        self.assertEqual(dav.deletes["family"], [])

    def test_state_file_keys_by_pair(self):
        family = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        lina = mirror.Pair(self.write_feed("lina", feed("b@x")), "lina")
        mirror.run_all([family, lina], apply=True, dav=FakeAccount(), state_file=self.saved)
        state = json.loads(self.saved.read_text())
        self.assertEqual(state["version"], mirror.STATE_VERSION)
        self.assertEqual(sorted(state["pairs"]),
                         [f"family:{family.feed}", f"lina:{lina.feed}"])
        family_keys = set(state["pairs"][f"family:{family.feed}"])
        lina_keys = set(state["pairs"][f"lina:{lina.feed}"])
        self.assertEqual(family_keys, {mirror.resource_name("a@x")})
        self.assertEqual(lina_keys, {mirror.resource_name("b@x")})
        self.assertEqual(family_keys & lina_keys, set())

    def test_legacy_flat_state_is_adopted_only_by_the_spike_collection(self):
        legacy = {"abc.ics": {"hash": "h", "etag": "e"}}
        self.saved.write_text(json.dumps(legacy))
        state = mirror.load_state(self.saved)
        spike = mirror.Pair(self.tmp / "family.ics", mirror.DEFAULT_COLLECTION)
        other = mirror.Pair(self.tmp / "lina.ics", "lina")

        self.assertEqual(mirror.state_for(state, other), {})
        self.assertEqual(mirror.state_for(state, spike), legacy)
        self.assertNotIn("legacy", state)


class FailureIsolationTests(PairTestCase):
    def test_one_broken_feed_does_not_stop_the_others(self):
        good = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        broken = mirror.Pair(self.tmp / "missing.ics", "lina")
        dav = FakeAccount()

        results, code = mirror.run_all([good, broken], apply=True, dav=dav,
                                       state_file=self.saved)
        self.assertEqual(code, 11)
        by_name = {r["collection"]: r for r in results}
        self.assertTrue(by_name["family"]["ok"])
        self.assertFalse(by_name["lina"]["ok"])
        self.assertIn("SourceError", by_name["lina"]["error"])
        self.assertTrue(dav.collections["family"])

    def test_unparseable_feed_writes_nothing_for_that_pair(self):
        good = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        bad = mirror.Pair(self.write_feed("lina", b"not a calendar at all"), "lina")
        dav = FakeAccount()

        results, code = mirror.run_all([good, bad], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(code, 12)
        self.assertEqual(dav.puts["lina"], [])
        self.assertNotIn("lina", {k for k in dav.collections if dav.collections[k]})

    def test_shrink_refusal_is_per_pair(self):
        big = [f"e{i}@x" for i in range(12)]
        family = mirror.Pair(self.write_feed("family", feed(*big)), "family")
        lina = mirror.Pair(self.write_feed("lina", feed("l@x")), "lina")
        dav = FakeAccount()
        mirror.run_all([family, lina], apply=True, dav=dav, state_file=self.saved)

        # Family loses most of its events; lina keeps changing normally.
        family.feed.write_bytes(feed("e0@x"))
        lina.feed.write_bytes(feed("l@x", "l2@x"))
        results, code = mirror.run_all([family, lina], apply=True, dav=dav,
                                       state_file=self.saved)
        by_name = {r["collection"]: r for r in results}
        self.assertEqual(code, 13)
        self.assertFalse(by_name["family"]["ok"])
        self.assertIn("shrank", by_name["family"]["error"])
        self.assertTrue(by_name["lina"]["ok"])
        self.assertEqual(len(dav.collections["family"]), 12)   # untouched
        self.assertEqual(len(dav.collections["lina"]), 2)

    def test_exit_code_is_the_worst_pair_code(self):
        pairs = [
            mirror.Pair(self.write_feed("family", feed("a@x")), "family"),
            mirror.Pair(self.tmp / "gone.ics", "lina"),
        ]

        class Refusing(FakeAccount):
            def for_collection(self, collection):
                if collection == "aleandra":
                    raise mirror.GuardError("refused")
                return super().for_collection(collection)

        pairs.append(mirror.Pair(self.write_feed("aleandra", feed("z@x")), "aleandra"))
        _, code = mirror.run_all(pairs, apply=True, dav=Refusing(), state_file=self.saved)
        self.assertEqual(code, 13)


class PairConfigTests(PairTestCase):
    def test_disabled_pair_is_reported_skipped_and_not_touched(self):
        family = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        lina = mirror.Pair(self.write_feed("lina", feed("b@x")), "lina", enabled=False)
        dav = FakeAccount()
        results, code = mirror.run_all([family, lina], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertTrue(results[1]["skipped"])
        self.assertNotIn("lina", dav.collections)

    def test_pairs_file_round_trip(self):
        path = self.tmp / "pairs.json"
        path.write_text(json.dumps({"pairs": [
            {"feed": str(self.tmp / "family.ics"), "collection": "family"},
            {"feed": str(self.tmp / "lina.ics"), "collection": "lina", "enabled": False},
        ]}))
        pairs = mirror.load_pairs(path)
        self.assertEqual([p.collection for p in pairs], ["family", "lina"])
        self.assertFalse(pairs[1].enabled)

    def test_pairs_file_refuses_a_bad_collection_name(self):
        for bad in ["../family", "Family", "family/x", "", "a b"]:
            path = self.tmp / "pairs.json"
            path.write_text(json.dumps({"pairs": [
                {"feed": str(self.tmp / "f.ics"), "collection": bad}]}))
            with self.assertRaises(mirror.ConfigError):
                mirror.load_pairs(path)

    def test_pairs_file_refuses_an_empty_list(self):
        path = self.tmp / "pairs.json"
        path.write_text(json.dumps({"pairs": []}))
        with self.assertRaises(mirror.ConfigError):
            mirror.load_pairs(path)

    def test_pairs_file_refuses_missing_file(self):
        with self.assertRaises(mirror.ConfigError):
            mirror.load_pairs(self.tmp / "nope.json")


class GuardPerPairTests(PairTestCase):
    def test_every_collection_admits_only_its_own_leaves(self):
        for collection in ["family", "patrick", "lina", "aleandra", "emma",
                           "isabella", "juliana"]:
            own = mirror.calendar_path("bernie", collection)
            self.assertEqual(mirror._checked_path(own, "bernie", collection), own)
            leaf = own + "abc123.ics"
            self.assertEqual(mirror._checked_path(leaf, "bernie", collection), leaf)
            for bad in [
                mirror.calendar_path("bernie", "spike-family"),
                own + "abc123.ics/extra.ics",
                own + "..%2F..%2Ffamily%2Fx.ics",
                mirror.calendar_path("other", collection),
            ]:
                with self.assertRaises(mirror.GuardError):
                    mirror._checked_path(bad, "bernie", collection)

    def test_collection_name_is_validated_before_any_path_is_built(self):
        for bad in ["../x", "Family", "fam/x", ""]:
            with self.assertRaises(mirror.ConfigError):
                mirror.Pair(self.tmp / "f.ics", bad)


class DisplayNameTests(unittest.TestCase):
    def test_display_name_matches_the_entity_id_we_need(self):
        # Home Assistant slugs the display name into the entity id.
        self.assertEqual(mirror.display_name("family"), "Family")
        self.assertEqual(mirror.display_name("patrick"), "Patrick")
        self.assertEqual(mirror.display_name("spike-family"), "Spike Family")


class MissingCalendarTests(PairTestCase):
    def test_dry_run_reports_a_calendar_that_does_not_exist_yet(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        results, code = mirror.run_all([pair], apply=False,
                                       dav=FakeAccount(missing={"family"}),
                                       state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertTrue(results[0]["create_calendar"])
        self.assertFalse(self.saved.exists())

    def test_existing_empty_calendar_is_not_reported_as_missing(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        results, _ = mirror.run_all([pair], apply=False, dav=FakeAccount(),
                                    state_file=self.saved)
        self.assertFalse(results[0]["create_calendar"])

    def test_summary_marks_the_calendar_to_be_created(self):
        line = mirror.render([{"collection": "family", "create": 2, "update": 0,
                               "delete": 0, "resources": 2, "match": False,
                               "ok": True, "create_calendar": True}], apply=False)
        self.assertIn("+calendar", line)


class CreateCalendarTests(PairTestCase):
    def test_applying_to_a_missing_calendar_is_refused_by_default(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "famliy")  # typo on purpose
        dav = FakeAccount(missing={"famliy"})
        results, code = mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(code, 13)
        self.assertFalse(results[0]["ok"])
        self.assertIn("does not exist", results[0]["error"])
        self.assertEqual(dav.puts["famliy"], [])
        self.assertEqual(dav.ensure_called["famliy"], [])

    def test_an_allowed_pair_creates_its_calendar(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family",
                           create_calendar=True)
        dav = FakeAccount(missing={"family"})
        results, code = mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertTrue(results[0]["ok"])
        self.assertTrue(dav.ensure_called["family"])
        self.assertEqual(len(dav.collections["family"]), 1)

    def test_pairs_file_accepts_create_calendar(self):
        path = self.tmp / "pairs.json"
        path.write_text(json.dumps({"pairs": [
            {"feed": str(self.tmp / "f.ics"), "collection": "family",
             "create_calendar": True}]}))
        self.assertTrue(mirror.load_pairs(path)[0].create_calendar)

    def test_the_bit_does_not_disable_itself(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family",
                           create_calendar=True)
        self.assertTrue(pair.create_calendar)
        self.assertFalse(pair.allow_empty)


class StateKeyMigrationTests(PairTestCase):
    def test_a_slice_keyed_by_stem_is_adopted_by_the_path_key(self):
        feed_path = self.write_feed("family", feed("a@x"))
        pair = mirror.Pair(feed_path, "family")
        stem_key = f"family:{feed_path.stem}"
        state = {"version": mirror.STATE_VERSION,
                 "pairs": {stem_key: {"abc.ics": {"hash": "h", "etag": "e"}}}}
        self.assertEqual(mirror.state_for(state, pair)["abc.ics"]["hash"], "h")
        self.assertIn(f"family:{feed_path}", state["pairs"])
        self.assertNotIn(stem_key, state["pairs"])


class ReviewRoundOneTests(PairTestCase):
    """Cases the first review round asked to be provable, not merely fixed."""

    def test_legacy_spike_state_is_picked_up_from_its_old_location(self):
        spike_state = self.tmp / "caldav-spike" / "state.json"
        spike_state.parent.mkdir()
        legacy = {"abc.ics": {"hash": "h", "etag": "e"}}
        spike_state.write_text(json.dumps(legacy))

        saved_state_file = mirror.STATE_FILE
        saved_legacy = mirror.LEGACY_STATE_FILES
        try:
            mirror.STATE_FILE = self.tmp / "caldav-mirror" / "state.json"
            mirror.LEGACY_STATE_FILES = (spike_state,)
            state = mirror.load_state(mirror.STATE_FILE)
        finally:
            mirror.STATE_FILE = saved_state_file
            mirror.LEGACY_STATE_FILES = saved_legacy
        self.assertEqual(state.get("legacy"), legacy)
        spike = mirror.Pair(self.write_feed("family", feed("a@x")), mirror.DEFAULT_COLLECTION)
        self.assertEqual(mirror.state_for(state, spike), legacy)

    def test_a_corrupt_state_file_is_refused_not_discarded(self):
        self.saved.write_text("{not json")
        with self.assertRaises(mirror.ConfigError):
            mirror.load_state(self.saved)
        self.assertEqual(self.saved.read_text(), "{not json")

    def test_a_hand_added_event_does_not_count_as_drift(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        dav = FakeAccount()
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        view = dav.for_collection("family")
        view.remote["handmade.ics"] = "etag-hand"
        view.bodies["handmade.ics"] = "BEGIN:VCALENDAR\nEND:VCALENDAR\n"

        results, code = mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertTrue(results[0]["match"])
        self.assertIn("handmade.ics", view.remote)  # never deleted

    def test_an_existing_collection_is_never_asked_to_be_created(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family",
                           create_calendar=True)
        dav = FakeAccount()
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(dav.ensure_called["family"], [])

    def test_a_collection_name_cannot_smuggle_a_newline(self):
        for bad in ["family\n", "family\r\n"]:
            with self.assertRaises(mirror.ConfigError):
                mirror.Pair(self.write_feed("f", feed("a@x")), bad)

    def test_verify_drift_fails_a_checking_run_and_writes_nothing(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        dav = FakeAccount()
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        name = mirror.resource_name("a@x")
        dav.for_collection("family").bodies[name] = "BEGIN:VCALENDAR\nEND:VCALENDAR\n"

        results, code = mirror.run_all([pair], apply=False, dav=dav,
                                       state_file=self.saved, verify=True)
        self.assertEqual(code, mirror.POST_WRITE_MISMATCH)
        self.assertEqual(results[0]["verify_mismatch"], 1)
        self.assertEqual(dav.puts["family"], [name])  # only the original write


class ReviewRoundTwoTests(PairTestCase):
    """Repairs from the second round, each with a test that can fail."""

    def test_a_stale_event_only_a_delete_can_remove_fails_a_checking_run(self):
        # The feed drops an event the mirror still owns and the server still
        # has: the plan wants a delete, the bodies all match, and the old code
        # called that fine.
        pair = mirror.Pair(self.write_feed("family", feed("a@x", "b@x")), "family")
        dav = FakeAccount()
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        pair.feed.write_bytes(feed("a@x"))

        results, code = mirror.run_all([pair], apply=False, dav=dav,
                                       state_file=self.saved, verify=True)
        self.assertEqual(code, mirror.POST_WRITE_MISMATCH)
        self.assertEqual(results[0]["verify_mismatch"], 0)
        self.assertFalse(results[0]["match"])

    def test_a_failing_pair_is_named_in_the_printed_summary(self):
        import contextlib
        import io
        pairs_file = self.tmp / "pairs.json"
        pairs_file.write_text(json.dumps({"pairs": [
            {"feed": str(self.write_feed("family", feed("a@x"))), "collection": "family"},
            {"feed": str(self.tmp / "gone.ics"), "collection": "lina"},
        ]}))
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = mirror.main(["--pairs", str(pairs_file), "--state", str(self.saved)])
        printed = buffer.getvalue()
        self.assertEqual(code, 11)
        self.assertIn("lina FAILED", printed)
        self.assertIn("family +1", printed)

    def test_a_socket_error_during_dav_work_is_21(self):
        class Broken(FakeAccount):
            def for_collection(self, collection):
                view = super().for_collection(collection)
                def boom(name, body):
                    raise BrokenPipeError("pipe closed")
                view.put = boom
                return view

        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        results, code = mirror.run_all([pair], apply=True, dav=Broken(),
                                       state_file=self.saved)
        self.assertEqual(code, 21)
        self.assertFalse(results[0]["ok"])

    @unittest.skipIf(os.geteuid() == 0, "root ignores the mode bits")
    def test_an_unreadable_state_file_is_refused_not_treated_as_empty(self):
        self.saved.write_text("{}")
        self.saved.chmod(0o000)
        try:
            with self.assertRaises(mirror.ConfigError):
                mirror.load_state(self.saved)
        finally:
            self.saved.chmod(0o600)

    def test_the_state_lock_gives_up_rather_than_waiting_for_ever(self):
        saved_wait = mirror.LOCK_WAIT
        mirror.LOCK_WAIT = 0.0
        try:
            with mirror.state_lock(self.saved):
                with self.assertRaises(mirror.LockBusy):
                    with mirror.state_lock(self.saved):
                        pass
        finally:
            mirror.LOCK_WAIT = saved_wait


class ReviewRoundThreeTests(PairTestCase):
    """The third round's blocking finding and the repairs around it."""

    def test_a_run_level_failure_still_prints_and_keeps_its_code(self):
        import contextlib
        import io
        bad = self.tmp / "pairs.json"
        bad.write_text('{"pairs": [{"feed": "/tmp/x.ics", "collection": "Bad Name"}]}')
        buffer, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(errors):
            code = mirror.main(["--pairs", str(bad), "--state", str(self.saved)])
        # Code 2 with a summary, not a TypeError traceback.
        self.assertEqual(code, 2)
        self.assertIn("mirror:", errors.getvalue())
        self.assertNotIn("Traceback", errors.getvalue())

    def test_a_missing_pairs_file_is_a_configuration_failure(self):
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = mirror.main(["--pairs", str(self.tmp / "nope.json"),
                                "--state", str(self.saved)])
        self.assertEqual(code, 2)

    def test_a_pending_write_is_not_drift_but_a_pending_delete_is(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        dav = FakeAccount()
        # A feed event the calendar has never seen: ordinary gap, not drift.
        results, code = mirror.run_all([pair], apply=False, dav=dav,
                                       state_file=self.saved, verify=True)
        self.assertEqual(code, 0)
        self.assertEqual(results[0]["create"], 1)

        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        pair.feed.write_bytes(feed("a@x", "b@x"))     # publish
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        pair.feed.write_bytes(feed("a@x"))            # the feed drops b
        _, code = mirror.run_all([pair], apply=False, dav=dav,
                                 state_file=self.saved, verify=True)
        self.assertEqual(code, mirror.POST_WRITE_MISMATCH)

    def test_a_failed_pair_keeps_its_own_code_in_a_checking_run(self):
        pair = mirror.Pair(self.tmp / "gone.ics", "family")
        _, code = mirror.run_all([pair], apply=False, dav=FakeAccount(),
                                 state_file=self.saved, verify=True)
        self.assertEqual(code, 11)

    def test_the_dav_client_refuses_a_bad_collection_of_its_own(self):
        with self.assertRaises(mirror.ConfigError):
            mirror._checked_path("/remote.php/dav/calendars/bernie/x/a.ics",
                                 "bernie", "../evil")


class ReviewRoundFourTests(PairTestCase):
    EMPTY = b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"

    def test_an_empty_allowed_feed_makes_a_stale_calendar_fail_a_check(self):
        pair = mirror.Pair(self.write_feed("juliana", feed("keep@x")), "juliana",
                           allow_empty=True)
        dav = FakeAccount()
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        pair.feed.write_bytes(self.EMPTY)

        results, code = mirror.run_all([pair], apply=False, dav=dav,
                                       state_file=self.saved, verify=True)
        self.assertEqual(code, mirror.POST_WRITE_MISMATCH)
        self.assertTrue(results[0]["empty_stale"])
        self.assertEqual(len(dav.collections["juliana"]), 1)  # nothing deleted

        # With nothing owned there is nothing stale about it.
        fresh = mirror.Pair(self.write_feed("juliana", self.EMPTY),
                            "juliana", allow_empty=True)
        results, code = mirror.run_all([fresh], apply=False, dav=FakeAccount(),
                                       state_file=self.tmp / "other-state.json",
                                       verify=True)
        self.assertEqual(code, 0)
        self.assertFalse(results[0]["empty_stale"])

    def test_resources_the_pair_does_not_own_are_counted_not_deleted(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        dav = FakeAccount()
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        view = dav.for_collection("family")
        view.remote["someone-elses.ics"] = "etag"
        view.bodies["someone-elses.ics"] = "BEGIN:VCALENDAR\nEND:VCALENDAR\n"

        results, code = mirror.run_all([pair], apply=True, dav=dav,
                                       state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertEqual(results[0]["unowned"], 1)
        self.assertIn("someone-elses.ics", view.remote)

    def test_a_server_that_rewrites_line_endings_is_not_drift(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        dav = FakeAccount()
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        view = dav.for_collection("family")
        name = mirror.resource_name("a@x")
        body = view.bodies[name].replace("\r\n", "\n")
        view.bodies[name] = body.replace("\n", "\r\n")

        results, code = mirror.run_all([pair], apply=False, dav=dav,
                                       state_file=self.saved, verify=True)
        self.assertEqual(code, 0)
        self.assertEqual(results[0]["verify_mismatch"], 0)

    def test_a_nul_byte_in_the_pairs_file_is_a_configuration_failure(self):
        import contextlib
        import io
        bad = self.tmp / "pairs.json"
        bad.write_text('{"pairs": [{"feed": "/tmp/a\\u0000b.ics", "collection": "family"}]}')
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = mirror.main(["--pairs", str(bad), "--state", str(self.saved)])
        self.assertIn(code, (2, 11))
        self.assertNotIn("Traceback", err.getvalue())

    def test_a_run_level_failure_prints_the_summary(self):
        import contextlib
        import io
        bad = self.tmp / "pairs.json"
        bad.write_text('{"pairs": [{"feed": "/tmp/x.ics", "collection": "Bad Name"}]}')
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            mirror.main(["--pairs", str(bad), "--state", str(self.saved)])
        self.assertIn("caldav[", out.getvalue())


class ReviewRoundSixTests(PairTestCase):
    def test_a_lost_state_slice_is_adopted_not_refused(self):
        # A calendar that already holds resources, with no state to explain
        # them: the old code refused for ever, which is a dead end.
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        dav = FakeAccount()
        view = dav.for_collection("family")
        name = mirror.resource_name("a@x")
        view.remote[name] = "etag"
        view.bodies[name] = "BEGIN:VCALENDAR\nEND:VCALENDAR\n"

        results, code = mirror.run_all([pair], apply=True, dav=dav,
                                       state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertTrue(results[0]["state_lost"])
        self.assertIn(name, view.remote)                     # nothing deleted
        self.assertTrue(self.saved.exists())                 # state seeded
        state = json.loads(self.saved.read_text())
        self.assertIn(name, state["pairs"][pair.key])

        # A checking run still reports it, so a lost slice is visible.
        results, code = mirror.run_all([pair], apply=False, dav=dav,
                                       state_file=self.tmp / "fresh.json", verify=True)
        self.assertEqual(code, mirror.POST_WRITE_MISMATCH)


class ReviewRoundSevenTests(PairTestCase):
    EMPTY = b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"

    def test_the_single_pair_flags_do_not_load_the_default_pair_list(self):
        feed_path = self.write_feed("family", feed("a@x"))
        args = mirror.main.__globals__["argparse"].Namespace(
            pairs=None, ics=str(feed_path), collection="family", allow_empty=False,
            create_calendar=True)
        pairs = mirror._pairs_from_args(args)
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0].collection, "family")
        self.assertTrue(pairs[0].create_calendar)

    def test_an_adoption_stays_visible_to_a_check_until_a_run_is_clean(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        dav = FakeAccount()
        view = dav.for_collection("family")
        name = mirror.resource_name("a@x")
        view.remote[name] = "etag"
        view.bodies[name] = "BEGIN:VCALENDAR\nEND:VCALENDAR\n"

        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        _, code = mirror.run_all([pair], apply=False, dav=dav,
                                 state_file=self.saved, verify=True)
        self.assertEqual(code, mirror.POST_WRITE_MISMATCH)   # adoption unresolved

        # A second applied run owns the slice now, so the marker is gone.
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        _, code = mirror.run_all([pair], apply=False, dav=dav,
                                 state_file=self.saved, verify=True)
        self.assertEqual(code, 0)

    def test_an_empty_pair_still_refreshes_its_state(self):
        pair = mirror.Pair(self.write_feed("juliana", self.EMPTY), "juliana",
                           allow_empty=True)
        results, code = mirror.run_all([pair], apply=True, dav=FakeAccount(),
                                       state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertTrue(self.saved.exists())


class ReviewRoundEightTests(PairTestCase):
    def test_a_bare_run_uses_the_service_pair_list_when_it_exists(self):
        import argparse
        pairs_file = self.tmp / "pairs.json"
        pairs_file.write_text(json.dumps({"pairs": [
            {"feed": str(self.write_feed("family", feed("a@x"))), "collection": "family"},
            {"feed": str(self.write_feed("lina", feed("b@x"))), "collection": "lina"},
        ]}))
        saved = mirror.PAIRS_FILE
        try:
            mirror.PAIRS_FILE = pairs_file
            args = argparse.Namespace(pairs=None, ics=None, collection="spike-family",
                                      allow_empty=False, create_calendar=False)
            self.assertEqual([p.collection for p in mirror._pairs_from_args(args)],
                             ["family", "lina"])
            # An explicit --ics still means one feed.
            args.ics = str(pairs_file)
            args.collection = "family"
            self.assertEqual([p.collection for p in mirror._pairs_from_args(args)],
                             ["family"])
        finally:
            mirror.PAIRS_FILE = saved

    def test_a_state_file_with_a_broken_pairs_section_is_refused(self):
        self.saved.write_text('{"version": 2, "pairs": ["nope"]}')
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        with self.assertRaises(mirror.ConfigError):
            mirror.run_all([pair], apply=False, dav=FakeAccount(), state_file=self.saved)

    def test_a_state_key_without_a_colon_does_not_crash(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        state = {"version": 2, "pairs": {"no-colon": {"a.ics": {"hash": "h", "etag": "e"}}}}
        self.assertEqual(mirror.state_for(state, pair), {})


class EmptyFeedTests(PairTestCase):
    EMPTY = b"BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//test//EN\nEND:VCALENDAR\n"

    def test_empty_feed_fails_by_default(self):
        pair = mirror.Pair(self.write_feed("juliana", self.EMPTY), "juliana")
        dav = FakeAccount()
        results, code = mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(code, 13)
        self.assertFalse(results[0]["ok"])
        self.assertIn("EmptyFeed", results[0]["error"])
        self.assertEqual(dav.puts["juliana"], [])

    def test_empty_feed_is_skipped_when_the_pair_allows_it(self):
        pair = mirror.Pair(self.write_feed("juliana", self.EMPTY), "juliana",
                           allow_empty=True)
        dav = FakeAccount()
        results, code = mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(code, 0)
        self.assertTrue(results[0]["empty"])
        self.assertTrue(results[0]["match"])
        self.assertEqual(dav.puts["juliana"], [])
        self.assertEqual(dav.deletes["juliana"], [])

    def test_empty_feed_never_deletes_existing_events(self):
        pair = mirror.Pair(self.write_feed("juliana", feed("keep@x")), "juliana")
        dav = FakeAccount()
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(len(dav.collections["juliana"]), 1)

        loose = mirror.Pair(pair.feed, "juliana", allow_empty=True)
        pair.feed.write_bytes(self.EMPTY)
        mirror.run_all([loose], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(len(dav.collections["juliana"]), 1)

    def test_pairs_file_accepts_allow_empty(self):
        path = self.tmp / "pairs.json"
        path.write_text(json.dumps({"pairs": [
            {"feed": str(self.tmp / "juliana.ics"), "collection": "juliana",
             "allow_empty": True}]}))
        self.assertTrue(mirror.load_pairs(path)[0].allow_empty)

    def test_render_marks_an_empty_pair(self):
        line = mirror.render([{"collection": "juliana", "toggle": None,
                               "empty": True, "ok": True, "match": True}], apply=False)
        self.assertIn("juliana empty (no events)", line)


class EtagTests(unittest.TestCase):
    def test_escaped_etags_are_unescaped_for_comparison(self):
        chunk = ('<d:response><d:href>/remote.php/dav/calendars/b/family/a.ics</d:href>'
                 '<d:propstat><d:prop><d:getetag>&quot;abc123&quot;</d:getetag>'
                 '</d:prop></d:propstat></d:response>')
        self.assertEqual(mirror._tag(chunk, "getetag"), '"abc123"')

    def test_prodid_is_the_spike_value_so_bodies_do_not_churn(self):
        groups, tzs = mirror.group_events(feed("a@x"))
        payload = next(iter(mirror.build_payloads(groups, tzs).values()))
        self.assertIn("PRODID:-//MontyCasa//CalDAV mirror (spike)//EN", payload)


class ExitCodeTests(PairTestCase):
    def test_codes_are_stable_contract_values(self):
        self.assertEqual(mirror.ERROR_CODES[mirror.ConfigError], 2)
        self.assertEqual(mirror.ERROR_CODES[mirror.SourceError], 11)
        self.assertEqual(mirror.ERROR_CODES[mirror.ParseError], 12)
        self.assertEqual(mirror.ERROR_CODES[mirror.RefusalError], 13)
        self.assertEqual(mirror.ERROR_CODES[mirror.EmptyFeed], 13)
        self.assertEqual(mirror.ERROR_CODES[mirror.DavError], 21)
        self.assertEqual(mirror.STATE_WRITE_FAILURE, 31)
        self.assertEqual(mirror.POST_WRITE_MISMATCH, 14)

    def test_missing_feed_is_11_and_unparseable_is_12(self):
        missing = mirror.Pair(self.tmp / "nope.ics", "family")
        _, code = mirror.run_all([missing], apply=True, dav=FakeAccount(),
                                 state_file=self.saved)
        self.assertEqual(code, 11)

        bad = mirror.Pair(self.write_feed("lina", b"garbage"), "lina")
        _, code = mirror.run_all([bad], apply=True, dav=FakeAccount(), state_file=self.saved)
        self.assertEqual(code, 12)

    def test_post_write_mismatch_is_14(self):
        class Sticky(FakeAccount):
            def for_collection(self, collection):
                view = super().for_collection(collection)
                # The server accepts the PUT but does not keep the resource.
                def ignored_put(name, body, _real=view.put):
                    view.puts.append(name)
                view.put = ignored_put
                return view

        pair = mirror.Pair(self.write_feed("family", feed("a@x", "b@x")), "family")
        dav = Sticky()
        mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        pair.feed.write_bytes(feed("a@x"))
        results, code = mirror.run_all([pair], apply=True, dav=dav, state_file=self.saved)
        self.assertEqual(code, 14)
        self.assertFalse(results[0]["match"])

    @unittest.skipIf(os.geteuid() == 0, "root ignores the mode bits")
    def test_an_unusable_state_directory_is_31(self):
        pair = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        blocked = self.tmp / "blocked"
        blocked.mkdir()
        blocked.chmod(0o500)
        try:
            # The lock cannot be created, so the run stops before touching the
            # calendar; main() turns this into the state code, not a traceback.
            with self.assertRaises(mirror.StateError):
                mirror.run_all([pair], apply=True, dav=FakeAccount(),
                               state_file=blocked / "state.json")
        finally:
            blocked.chmod(0o700)
        self.assertEqual(mirror.ERROR_CODES[mirror.StateError], 31)


class SpoolTests(PairTestCase):
    def test_nothing_is_written_on_success(self):
        spool = self.tmp / "spool.jsonl"
        mirror.spool_record(spool, 0, [{"ok": True}])
        self.assertFalse(spool.exists())

    def test_a_failure_writes_one_counts_only_line(self):
        spool = self.tmp / "spool.jsonl"
        results = [{"collection": "family", "ok": True, "applied": True},
                   {"collection": "patrick", "ok": False, "error": "SourceError: /secret/path"}]
        mirror.spool_record(spool, 11, results)
        lines = spool.read_text().splitlines()
        self.assertEqual(len(lines), 1)
        record = json.loads(lines[0])
        self.assertEqual(record["code"], 11)
        self.assertEqual(record["pairs"], 2)
        self.assertEqual(record["failed"], 1)
        self.assertEqual(record["unit"], "calendar-caldav-mirror")
        self.assertNotIn("family", lines[0])
        self.assertNotIn("patrick", lines[0])
        self.assertNotIn("/secret/path", lines[0])
        self.assertEqual(spool.stat().st_mode & 0o777, 0o600)

    def test_appends_across_failures(self):
        spool = self.tmp / "spool.jsonl"
        mirror.spool_record(spool, 11, None)
        mirror.spool_record(spool, 21, None)
        self.assertEqual([json.loads(l)["code"] for l in spool.read_text().splitlines()],
                         [11, 21])


class RenderTests(unittest.TestCase):
    def test_summary_line_carries_every_pair(self):
        results = [
            {"collection": "family", "create": 3, "update": 1, "delete": 0,
             "resources": 27, "match": True, "ok": True},
            {"collection": "patrick", "create": 0, "update": 0, "delete": 0,
             "resources": 12, "match": True, "ok": True},
            {"collection": "lina", "ok": False, "error": "SourceError: empty", "match": False},
            {"collection": "emma", "skipped": True, "ok": True},
        ]
        line = mirror.render(results, apply=False)
        self.assertTrue(line.startswith("caldav[dry-run] "))
        self.assertIn("family +3 ~1 -0 =27 match=yes", line)
        self.assertIn("patrick +0 ~0 -0 =12 match=yes", line)
        self.assertIn("lina FAILED SourceError: empty", line)
        self.assertIn("emma skipped", line)

    def test_verify_counts_are_shown(self):
        results = [{"collection": "family", "create": 0, "update": 0, "delete": 0,
                    "resources": 3, "match": False, "ok": True, "verify_mismatch": 2}]
        self.assertIn("verify=2", mirror.render(results, apply=True))


class VerifyTests(PairTestCase):
    def test_verify_detects_a_body_that_differs_from_the_feed(self):
        family = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        dav = FakeAccount()
        mirror.run_all([family], apply=True, dav=dav, state_file=self.saved)

        name = mirror.resource_name("a@x")
        view = dav.for_collection("family")
        view.bodies[name] = "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n"

        results, code = mirror.run_all([family], apply=True, dav=dav,
                                       state_file=self.saved, verify=True)
        # A body that still differs after the write is a post-write mismatch:
        # that is code 14, the code the watchdog alerts on.
        self.assertEqual(code, mirror.POST_WRITE_MISMATCH)
        self.assertEqual(results[0]["verify_mismatch"], 1)
        self.assertFalse(results[0]["match"])

    def test_verify_never_writes(self):
        family = mirror.Pair(self.write_feed("family", feed("a@x")), "family")
        dav = FakeAccount()
        results, code = mirror.run_all([family], apply=False, dav=dav,
                                       state_file=self.saved, verify=True)
        # Nothing is there yet, which is a pending create, not drift: the check
        # reports it without failing and writes nothing.
        self.assertEqual(code, 0)
        self.assertEqual(dav.puts["family"], [])
        self.assertEqual(results[0]["create"], 1)
        self.assertEqual(results[0]["verify_mismatch"], 0)
        self.assertFalse(self.saved.exists())


if __name__ == "__main__":
    unittest.main()
