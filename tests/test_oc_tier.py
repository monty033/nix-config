#!/run/current-system/sw/bin/python3
"""Tests for oc-tier. No live calls: catalogue, roster, quota and subprocess are patched."""

import importlib.machinery
import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import date
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SPEC = Path(__file__).resolve().parent.parent / "packages" / "oc-tier.py"
_loader = importlib.machinery.SourceFileLoader("oc_tier", str(SPEC))
_spec = importlib.util.spec_from_loader("oc_tier", _loader)
assert _spec is not None
oc = importlib.util.module_from_spec(_spec)
_loader.exec_module(oc)


def entry(model_id, tier, position=1, variant="high", free=False, off="", **extra):
    data = {
        "id": model_id, "variant": variant, "tiers": {tier: position}, "free": free,
        "off": off, "why": "because", "_file": f"{model_id.replace('/', '--')}.toml", "checked": "2026-11-02",
        "_source": extra.pop("_source", "local"),
    }
    data.update(extra)
    return data


class ResolveTest(unittest.TestCase):
    def resolve(self, roster, live, quota=None, **kwargs):
        quota = quota or {}
        tier = kwargs.pop("tier", "slice")
        with patch.object(oc, "quota_snapshot", side_effect=lambda key, cache=None: quota.get(key)):
            return oc.resolve(tier, roster, live, **kwargs)

    def test_picks_first_candidate(self):
        result = self.resolve([entry("a/one", "slice", 1)], {"a/one": ["high"]})
        self.assertTrue(result["ok"])
        self.assertEqual(result["entry"]["id"], "a/one")
        self.assertEqual(result["index"], 1)

    def test_absent_candidate_falls_to_next(self):
        result = self.resolve([entry("a/gone", "slice", 1), entry("a/live", "slice", 2)], {"a/live": ["high"]})
        self.assertEqual(result["entry"]["id"], "a/live")
        self.assertEqual(result["steps"][0]["cause"], "absent")
        self.assertEqual((result["index"], result["total"]), (2, 2))

    def test_off_candidate_is_skipped_with_its_text(self):
        result = self.resolve(
            [entry("a/off", "slice", 1, off="out of usage"), entry("a/live", "slice", 2)],
            {"a/off": ["high"], "a/live": ["high"]},
        )
        self.assertEqual(result["entry"]["id"], "a/live")
        self.assertEqual(result["steps"][0]["detail"], "out of usage")

    def test_private_refuses_free_candidate(self):
        result = self.resolve(
            [entry("a/free-x", "slice", 1, free=True), entry("a/paid", "slice", 2)],
            {"a/free-x": ["high"], "a/paid": ["high"]}, private=True,
        )
        self.assertEqual(result["entry"]["id"], "a/paid")
        self.assertEqual(result["steps"][0]["cause"], "private")

    def test_private_refusal_of_sole_candidate_exhausts(self):
        result = self.resolve([entry("a/free-x", "slice", 1, free=True)], {"a/free-x": ["high"]}, private=True)
        self.assertFalse(result["ok"])

    def test_spent_window_routes_when_extra_usage_is_declared(self):
        spent = {"status": "ok", "windows": [{"name": "monthly", "remainingPercent": 0}]}
        result = self.resolve(
            [entry("opencode-go/one", "slice", 1, extra_usage_until="2999-01-01")],
            {"opencode-go/one": ["high"]}, quota={"opencode-go": spent},
        )
        self.assertTrue(result["ok"])
        self.assertIn("on extra usage declared until 2999-01-01", result["quota"])

    def test_declared_extra_usage_does_not_rescue_a_spent_window_past_its_date(self):
        spent = {"status": "ok", "windows": [{"name": "monthly", "remainingPercent": 0}]}
        result = self.resolve(
            [entry("opencode-go/one", "slice", 1, extra_usage_until="2000-01-01")],
            {"opencode-go/one": ["high"]}, quota={"opencode-go": spent},
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["steps"][0]["cause"], "quota")

    def test_malformed_declaration_does_not_route_a_spent_window(self):
        spent = {"status": "ok", "windows": [{"name": "monthly", "remainingPercent": 0}]}
        result = self.resolve(
            [entry("opencode-go/one", "slice", 1, extra_usage_until="soon")],
            {"opencode-go/one": ["high"]}, quota={"opencode-go": spent},
        )
        self.assertFalse(result["ok"])

    def test_spent_window_without_a_declaration_stays_exhausted(self):
        spent = {"status": "ok", "windows": [{"name": "monthly", "remainingPercent": 0}]}
        result = self.resolve([entry("opencode-go/one", "slice", 1)], {"opencode-go/one": ["high"]}, quota={"opencode-go": spent})
        self.assertFalse(result["ok"])

    def test_excluded_author_model_is_skipped(self):
        result = self.resolve(
            [entry("a/author", "slice", 1), entry("a/other", "slice", 2)],
            {"a/author": ["high"], "a/other": ["high"]}, exclude=["a/author"],
        )
        self.assertEqual(result["entry"]["id"], "a/other")
        self.assertEqual(result["steps"][0]["cause"], "excluded")

    def test_exclude_accepts_a_id_with_a_variant_suffix(self):
        result = self.resolve(
            [entry("a/author", "slice", 1), entry("a/other", "slice", 2)],
            {"a/author": ["high"], "a/other": ["high"]}, exclude=["a/author:high"],
        )
        self.assertEqual(result["entry"]["id"], "a/other")

    def test_exclude_still_matches_an_openrouter_free_id(self):
        free_id = "openrouter/vendor/model:free"
        result = self.resolve([entry(free_id, "slice", 1)], {free_id: []}, exclude=[free_id], tier="slice")
        self.assertFalse(result["ok"])
        self.assertEqual(result["steps"][0]["cause"], "excluded")

    def test_variant_not_offered_is_a_skip(self):
        result = self.resolve([entry("a/one", "slice", 1, variant="max")], {"a/one": ["low"]})
        self.assertFalse(result["ok"])
        self.assertEqual(result["steps"][0]["cause"], "variant")

    def test_exhausted_quota_moves_to_next_candidate(self):
        exhausted = {"status": "ok", "windows": [{"name": "weekly", "remainingPercent": 4, "resetAtEdt": "Nov 4"}]}
        result = self.resolve(
            [entry("opencode-go/one", "slice", 1), entry("claude-code/two", "slice", 2)],
            {"opencode-go/one": ["high"], "claude-code/two": ["high"]}, quota={"opencode-go": exhausted},
        )
        self.assertEqual(result["entry"]["id"], "claude-code/two")
        self.assertEqual(result["steps"][0]["cause"], "quota")

    def test_whole_tier_exhausted_on_quota(self):
        exhausted = {"status": "ok", "windows": [{"name": "weekly", "remainingPercent": 4}]}
        result = self.resolve(
            [entry("opencode-go/one", "slice", 1), entry("opencode-go/two", "slice", 2)],
            {"opencode-go/one": ["high"], "opencode-go/two": ["high"]}, quota={"opencode-go": exhausted},
        )
        self.assertFalse(result["ok"])
        self.assertEqual([step["cause"] for step in result["steps"]], ["quota", "quota"])

    def test_unreadable_quota_never_blocks_dispatch(self):
        broken = {"status": "unknown", "reason": "collector unavailable"}
        result = self.resolve([entry("opencode-go/one", "slice", 1)], {"opencode-go/one": ["high"]},
                              quota={"opencode-go": broken})
        self.assertTrue(result["ok"])
        self.assertIn("quota: unknown", result["quota"])

    def test_rate_limited_window_is_exhausted_even_at_high_percent(self):
        limited = {"status": "ok", "windows": [{"name": "5h", "remainingPercent": 90, "windowStatus": "rate-limited"}]}
        result = self.resolve([entry("opencode-go/one", "slice", 1)], {"opencode-go/one": ["high"]},
                              quota={"opencode-go": limited})
        self.assertFalse(result["ok"])

    def test_binding_window_is_the_lowest_remaining(self):
        record = {"status": "ok", "windows": [
            {"name": "5h", "remainingPercent": 90},
            {"name": "monthly", "remainingPercent": 30},
        ]}
        self.assertEqual(oc.binding_window(record)["name"], "monthly")

    def test_announcement_carries_route_tier_and_position(self):
        roster = [entry("claude-code/claude-sonnet-5-5", "security", 1)]
        result = self.resolve(roster, {"claude-code/claude-sonnet-5-5": ["high"]}, tier="security")
        line = oc.finish(result["entry"], "security", result["index"], result["total"], result["quota"], "; plan S04")
        self.assertIn("via Claude subscription", line)
        self.assertIn("candidate 1 of 1; local; plan S04", line)
        self.assertIn("quota:", line)

    def test_the_announcement_says_which_layer_supplied_the_model(self):
        from_base = oc.finish(entry("claude-code/a", "security", 1, _source="base"), "security", 1, 1, "quota: n/a", "")
        overridden = oc.finish(entry("claude-code/a", "security", 1, _source="local (overrides base)"),
                               "security", 1, 1, "quota: n/a", "")
        self.assertIn("; base)", from_base)
        self.assertIn("; local (overrides base))", overridden)


class CatalogueTest(unittest.TestCase):
    def test_a_partial_read_is_not_reported_as_a_dead_route(self):
        roster = [entry("claude-code/a", "slice", 1)]
        partial = {"claude-code/b": ["high"]}
        full = {"claude-code/a": ["high"], "claude-code/b": ["high"]}
        with patch.object(oc, "catalogue", side_effect=[partial, full]):
            merged = oc.catalogue_for(roster)
        self.assertIn("claude-code/a", merged)
        self.assertIn("claude-code/b", merged)

    def test_an_empty_catalogue_is_retried_not_believed(self):
        with patch.object(oc, "catalogue", wraps=oc.catalogue) as wrapped, \
             patch.object(oc.subprocess, "run", side_effect=[
                 SimpleNamespace(returncode=0, stdout="", stderr=""),
                 SimpleNamespace(returncode=0, stdout="claude-code/a\thigh\n", stderr=""),
             ]), \
             patch.object(oc.time, "sleep", return_value=None):
            found = wrapped()
        self.assertEqual(found, {"claude-code/a": ["high"]})

    def test_a_complete_first_read_makes_one_call(self):
        roster = [entry("claude-code/a", "slice", 1)]
        calls = []

        def fake():
            calls.append(1)
            return {"claude-code/a": ["high"]}

        with patch.object(oc, "catalogue", side_effect=fake):
            oc.catalogue_for(roster)
        self.assertEqual(len(calls), 1)


class MergeTest(unittest.TestCase):
    """The base inventory and the local overlay, merged by model id."""

    def layers(self, base_files, local_files):
        import tempfile

        def write(directory, files):
            for name, body in files.items():
                (Path(directory) / name).write_text(body, encoding="utf-8")

        with tempfile.TemporaryDirectory() as tmp:
            base_dir, local_dir = Path(tmp) / "base", Path(tmp) / "local"
            base_dir.mkdir()
            local_dir.mkdir()
            write(base_dir, base_files)
            write(local_dir, local_files)
            with patch.object(oc, "ROSTER_BASE", base_dir), patch.object(oc, "ROSTER_LOCAL", local_dir):
                return oc.load_roster()

    BASE_ENTRY = 'id = "claude-code/a"\nvariant = "high"\ntiers = { slice = 1 }\nfree = false\nwhy = "base"\nchecked = "2026-11-02"\n'

    def test_base_and_local_are_both_present(self):
        entries = self.layers({"a.toml": self.BASE_ENTRY},
                              {"b.toml": 'id = "claude-code/b"\nvariant = "high"\ntiers = { plan = 1 }\nfree = false\nwhy = "local"\nchecked = "2026-11-02"\n'})
        sources = {entry["id"]: entry["_source"] for entry in entries}
        self.assertEqual(sources, {"claude-code/a": "base", "claude-code/b": "local"})

    def test_a_local_entry_can_take_a_position_the_base_already_uses(self):
        local = ('id = "claude-code/b"\nvariant = "high"\ntiers = { slice = 1 }\nfree = false\n'
                 'why = "inserted first"\nchecked = "2026-11-02"\n')
        entries = self.layers({"a.toml": self.BASE_ENTRY}, {"b.toml": local})
        ordered = oc.candidates(entries, "slice")
        self.assertEqual([e["id"] for e in ordered], ["claude-code/b", "claude-code/a"])

    def test_two_files_in_one_layer_cannot_share_a_position(self):
        other = self.BASE_ENTRY.replace('claude-code/a', 'claude-code/b')
        with self.assertRaises(oc.RosterError) as caught:
            self.layers({"a.toml": self.BASE_ENTRY, "b.toml": other}, {})
        self.assertIn("both use tier slice position 1", str(caught.exception))

    def test_a_local_entry_replaces_the_base_entry_whole(self):
        local = 'id = "claude-code/a"\nvariant = "low"\ntiers = { slice = 1 }\nfree = false\noff = "quota"\nwhy = "local"\nchecked = "2026-11-02"\n'
        entries = self.layers({"a.toml": self.BASE_ENTRY}, {"a.toml": local})
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["_source"], "local (overrides base)")
        self.assertEqual(entries[0]["variant"], "low")
        self.assertEqual(entries[0]["off"], "quota")
        self.assertEqual(entries[0]["why"], "local")

    def test_two_files_for_one_id_in_the_same_layer_is_an_error(self):
        with self.assertRaises(oc.RosterError) as caught:
            self.layers({"a.toml": self.BASE_ENTRY, "a-copy.toml": self.BASE_ENTRY}, {})
        self.assertIn("one id, one file per layer", str(caught.exception))

    def test_both_layers_empty_is_an_error(self):
        with self.assertRaises(oc.RosterError):
            self.layers({}, {})

    def test_a_missing_base_layer_is_an_error_with_the_path(self):
        with patch.object(oc, "ROSTER_BASE", Path("/nonexistent-base")), \
             patch.object(oc, "ROSTER_LOCAL", Path("/nonexistent-local")):
            with self.assertRaises(oc.RosterError) as caught:
                oc.load_roster()
        self.assertIn("/nonexistent-base", str(caught.exception))

    def test_a_missing_local_layer_is_normal(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "a.toml").write_text(self.BASE_ENTRY, encoding="utf-8")
            with patch.object(oc, "ROSTER_BASE", Path(tmp)), \
                 patch.object(oc, "ROSTER_LOCAL", Path(tmp) / "absent"):
                entries = oc.load_roster()
        self.assertEqual([e["_source"] for e in entries], ["base"])

    def test_an_empty_base_layer_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "local").mkdir()
            (Path(tmp) / "local" / "a.toml").write_text(self.BASE_ENTRY, encoding="utf-8")
            with patch.object(oc, "ROSTER_BASE", Path(tmp)), \
                 patch.object(oc, "ROSTER_LOCAL", Path(tmp) / "local"):
                with self.assertRaises(oc.RosterError) as caught:
                    oc.load_roster()
        self.assertIn("base layer is empty", str(caught.exception))


class QuotaTest(unittest.TestCase):
    def verdict(self, record):
        return oc.quota_verdict(record)[0]

    def test_float_percent_below_floor_is_exhausted(self):
        self.assertEqual(self.verdict({"status": "ok", "windows": [{"name": "5h", "remainingPercent": 4.0}]}), "exhausted")

    def test_string_percent_below_floor_is_exhausted(self):
        self.assertEqual(self.verdict({"status": "ok", "windows": [{"name": "5h", "remainingPercent": "4"}]}), "exhausted")

    def test_null_percent_is_unknown_not_a_crash(self):
        self.assertEqual(self.verdict({"status": "ok", "windows": [{"name": "5h", "remainingPercent": None}]}), "ok")

    def test_unreadable_percent_does_not_win_the_binding_window(self):
        record = {"status": "ok", "windows": [
            {"name": "5h", "remainingPercent": None},
            {"name": "weekly", "remainingPercent": 80},
        ]}
        self.assertEqual(oc.binding_window(record)["name"], "weekly")

    def test_collector_failure_is_unknown_and_fails_open(self):
        verdict, text = oc.quota_verdict({"status": "unknown", "reason": "collector unavailable"})
        self.assertEqual(verdict, "ok")
        self.assertIn("quota: unknown (collector unavailable)", text)

    def test_no_subscription_window(self):
        self.assertEqual(oc.quota_verdict(None), ("n/a", "quota: n/a (no subscription window)"))

    def test_declared_extra_usage_covers_a_spent_window(self):
        spent = {"status": "ok", "windows": [{"name": "monthly", "remainingPercent": 0}]}
        verdict, text = oc.quota_verdict(spent, {"extra_usage_until": "2999-01-01"})
        self.assertEqual(verdict, "ok")
        self.assertIn("quota: monthly 0% left", text)
        self.assertIn("on extra usage declared until 2999-01-01", text)

    def test_declared_extra_usage_stays_valid_through_its_date(self):
        spent = {"status": "ok", "windows": [{"name": "monthly", "remainingPercent": 0}]}
        today = date(2026, 11, 13)
        self.assertEqual(oc.quota_verdict(spent, {"extra_usage_until": "2026-11-13"}, today)[0], "ok")
        self.assertEqual(oc.quota_verdict(spent, {"extra_usage_until": "2026-11-12"}, today)[0], "exhausted")

    def test_declaration_does_not_lift_a_provider_flagged_window_with_allowance_left(self):
        flagged = {"status": "ok", "windows": [
            {"name": "weekly", "remainingPercent": 84, "windowStatus": "rate-limited"}]}
        self.assertEqual(oc.quota_verdict(flagged, {"extra_usage_until": "2999-01-01"})[0], "exhausted")
        erroring = {"status": "ok", "windows": [
            {"name": "weekly", "remainingPercent": 84, "windowStatus": "error"}]}
        self.assertEqual(oc.quota_verdict(erroring, {"extra_usage_until": "2999-01-01"})[0], "exhausted")

    def test_declaration_still_covers_a_spent_window_the_provider_also_flags(self):
        spent_and_flagged = {"status": "ok", "windows": [
            {"name": "monthly", "remainingPercent": 0, "windowStatus": "rate-limited"}]}
        self.assertEqual(
            oc.quota_verdict(spent_and_flagged, {"extra_usage_until": "2999-01-01"})[0], "ok")

    def test_expired_declaration_is_named_in_the_exhausted_text(self):
        spent = {"status": "ok", "windows": [{"name": "monthly", "remainingPercent": 0}]}
        verdict, text = oc.quota_verdict(
            spent, {"extra_usage_until": "2026-01-01"}, date(2026, 11, 13))
        self.assertEqual(verdict, "exhausted")
        self.assertIn("extra usage declaration expired 2026-01-01", text)

    def test_malformed_extra_usage_date_never_rescues_a_spent_window(self):
        spent = {"status": "ok", "windows": [{"name": "monthly", "remainingPercent": 0}]}
        self.assertEqual(oc.quota_verdict(spent, {"extra_usage_until": "soon"})[0], "exhausted")

    def test_extra_usage_does_not_override_a_healthy_window_reading(self):
        healthy = {"status": "ok", "windows": [{"name": "weekly", "remainingPercent": 84}]}
        verdict, text = oc.quota_verdict(healthy, {"extra_usage_until": "2999-01-01"})
        self.assertEqual(verdict, "ok")
        self.assertNotIn("extra usage", text)


class FreeGuardTest(unittest.TestCase):
    """An overlay must not be able to turn the shell guard off by asserting a flag."""

    def test_a_free_looking_id_is_free_even_when_the_flag_says_paid(self):
        self.assertTrue(oc.is_free(entry("opencode-go/some-model-free", "slice", 1, free=False)))
        self.assertTrue(oc.is_free(entry("openrouter/vendor/model:free", "slice", 1, free=False)))

    def test_an_id_the_free_audit_lists_is_free_even_when_the_flag_says_paid(self):
        self.assertTrue(oc.is_free(entry("opencode-go/mystery-route", "slice", 1, free=False),
                                   free_ids={"opencode-go/mystery-route"}))

    def test_lint_announces_a_missing_audit_instead_of_dying_on_it(self):
        """The diagnostic path runs when the audit is broken, so it must not traceback."""
        entries = [entry("opencode-go/f-free", "mechanical", 1, free=True)]
        err = io.StringIO()
        with patch.object(oc, "FREE_SNAPSHOTS", Path("/nonexistent-snapshots")), redirect_stderr(err):
            problems = oc.validate_live(entries, {"opencode-go/f-free": ["low"]})
        self.assertIn("no readable snapshot", err.getvalue())
        self.assertTrue(any("absent from the free-model audit" in p for p in problems))

    def test_a_missing_audit_snapshot_says_so_rather_than_degrading_quietly(self):
        err = io.StringIO()
        with patch.object(oc, "FREE_SNAPSHOTS", Path("/nonexistent-snapshots")), redirect_stderr(err):
            ids = oc.free_snapshot_ids()
        self.assertEqual(ids, set())
        self.assertIn("no readable snapshot", err.getvalue())

    def test_a_paid_route_with_no_free_evidence_is_not_free(self):
        self.assertFalse(oc.is_free(entry("claude-code/a", "slice", 1, free=False), free_ids=set()))

    def test_private_work_refuses_a_free_route_the_overlay_called_paid(self):
        result = oc.resolve("slice", [entry("opencode-go/thing-free", "slice", 1, free=False)],
                            {"opencode-go/thing-free": ["high"]}, private=True, free_ids=set())
        self.assertFalse(result["ok"])
        self.assertEqual(result["steps"][0]["cause"], "private")


class ValidateTest(unittest.TestCase):
    LIVE = {"claude-code/a": ["high"], "claude-code/b": ["high"], "opencode-go/f-x-free": ["low"],
            "minimax-coding-plan/mm": [], "openrouter/z-free": []}

    def problems(self, roster):
        with patch.object(oc, "FREE_SNAPSHOTS", Path("/nonexistent-snapshots")):
            return oc.validate(roster, self.LIVE)

    def test_review_only_entry_is_allowed(self):
        roster = [entry("minimax-coding-plan/mm", "review", 1, variant="")]
        self.assertEqual([p for p in self.problems(roster) if "work tiers" in p], [])

    def test_malformed_extra_usage_date_is_a_structural_problem(self):
        roster = [entry("claude-code/a", "cross_module", 1, extra_usage_until="next month")]
        self.assertTrue([p for p in self.problems(roster) if "extra_usage_until" in p])

    def test_well_formed_dates_pass_structure_including_a_past_one(self):
        # A past date is legal: expiry is a lint note, never a dispatch block.
        for declared in ("2027-01-01", "2020-01-01"):
            roster = [entry("claude-code/a", "cross_module", 1, extra_usage_until=declared)]
            self.assertEqual([p for p in self.problems(roster) if "extra_usage_until" in p], [], declared)

    def test_short_and_padded_dates_are_rejected_too(self):
        # The message promises YYYY-MM-DD; strptime alone would take 2027-1-1.
        for declared in ("2027-1-1", "2027-1-01", "2027-01-1"):
            roster = [entry("claude-code/a", "cross_module", 1, extra_usage_until=declared)]
            self.assertTrue([p for p in self.problems(roster) if "extra_usage_until" in p], declared)

    def test_lint_names_an_expired_declaration_on_a_subscription_route(self):
        roster = [entry("opencode-go/one", "slice", 1, extra_usage_until="2020-01-01")]
        buffer = io.StringIO()
        with patch.object(oc, "load_roster", return_value=roster), \
             patch.object(oc, "catalogue_for", return_value={"opencode-go/one": ["high"]}), \
             patch.object(oc, "validate", return_value=[]), \
             redirect_stdout(buffer):
            code = oc.cmd_lint(SimpleNamespace())
        self.assertIn("extra usage declaration expired 2020-01-01", buffer.getvalue())
        self.assertEqual(code, 0)

    def test_expired_declaration_is_quiet_for_a_route_with_no_subscription_window(self):
        roster = [entry("openrouter/thing", "slice", 1, extra_usage_until="2020-01-01")]
        buffer = io.StringIO()
        with patch.object(oc, "load_roster", return_value=roster), \
             patch.object(oc, "catalogue_for", return_value={"openrouter/thing": ["high"]}), \
             patch.object(oc, "validate", return_value=[]), \
             redirect_stdout(buffer):
            oc.cmd_lint(SimpleNamespace())
        self.assertNotIn("extra usage", buffer.getvalue())

    def test_compact_and_week_dates_are_rejected(self):
        for declared in ("20270101", "2027-W01-1", "01/01/2027"):
            roster = [entry("claude-code/a", "cross_module", 1, extra_usage_until=declared)]
            self.assertTrue([p for p in self.problems(roster) if "extra_usage_until" in p], declared)

    def test_two_work_tiers_is_a_problem(self):
        bad = entry("claude-code/a", "slice", 1)
        bad["tiers"]["security"] = 1
        self.assertTrue(any("work tiers" in p for p in self.problems([bad])))

    def test_mechanical_must_be_free(self):
        bad = entry("minimax-coding-plan/mm", "mechanical", 1, variant="", free=False)
        self.assertTrue(any("mechanical candidates must be free" in p for p in self.problems([bad])))

    def test_claude_on_an_opencode_route_is_a_problem(self):
        bad = entry("opencode-go/claude-haiku-5-5", "cross_module", 1)
        self.assertTrue(any("must use the claude-code/ route" in p for p in self.problems([bad])))

    def test_unknown_provider_is_a_problem(self):
        bad = entry("mystery/model", "slice", 1)
        self.assertTrue(any("not a known route" in p for p in self.problems([bad])))

    def test_a_cross_layer_position_tie_is_not_a_problem(self):
        """The overlay inserting a candidate ahead of a base one is the point."""
        roster = [entry("claude-code/a", "slice", 1, _source="base"),
                  entry("claude-code/b", "slice", 1, _source="local")]
        self.assertEqual([p for p in self.problems(roster) if "position" in p], [])

    def test_a_future_checked_date_does_not_block_dispatch(self):
        """A host clock behind the roster is a clock problem, not a roster problem."""
        ahead = entry("claude-code/a", "slice", 1, checked="2099-01-01")
        self.assertEqual([p for p in self.problems([ahead]) if "checked" in p], [])

    def test_unparseable_checked_date_is_a_problem(self):
        bad = entry("claude-code/a", "slice", 1, checked="soon")
        self.assertTrue(any("ISO date" in p for p in self.problems([bad])))

    def test_non_bool_free_is_a_problem(self):
        bad = entry("claude-code/a", "slice", 1)
        bad["free"] = "false"  # a TOML string, which is truthy
        self.assertTrue(any("free must be true or false" in p for p in self.problems([bad])))

    def test_slice_candidate_with_unadvertised_variant(self):
        bad = entry("claude-code/a", "slice", 1, variant="max")
        self.assertTrue(any("not offered" in p for p in self.problems([bad])))

    def test_clean_roster_has_no_problems(self):
        roster = [entry("claude-code/a", "slice", 1), entry("minimax-coding-plan/mm", "review", 1, variant="")]
        self.assertEqual([p for p in self.problems(roster) if "snapshot" not in p], [])


class CreateTest(unittest.TestCase):
    """cmd_create with subprocess faked, so the command line and the confirmation are observable."""

    def run_create(self, argv, roster=None, info_model=None, deny_rc=0, create_out="ses_abc\n",
                   free_ids=None, catalogue=None):
        roster = roster or [entry("claude-code/a", "slice", 1)]
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            if command[1] == "create":
                return SimpleNamespace(returncode=0, stdout=create_out, stderr="")
            if command[1] == "info":
                model = info_model if info_model is not None else {"providerID": "claude-code", "id": "a", "variant": "high"}
                return SimpleNamespace(returncode=0, stdout=json.dumps({"model": model}), stderr="")
            if command[1] in ("deny", "interrupt"):
                return SimpleNamespace(returncode=deny_rc if command[1] == "deny" else 0, stdout="", stderr="")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        out, err = io.StringIO(), io.StringIO()
        with patch.object(oc, "load_roster", return_value=roster), \
             patch.object(oc, "catalogue", return_value=catalogue or {"claude-code/a": ["high"], "minimax-coding-plan/mm": [], "opencode-go/f-free": ["low"]}), \
             patch.object(oc, "validate_structure", return_value=[]), \
             patch.object(oc, "free_snapshot_ids", return_value=set(free_ids or ())), \
             patch.object(oc, "quota_snapshot", return_value=None), \
             patch.object(oc.subprocess, "run", side_effect=fake_run), \
             redirect_stdout(out), redirect_stderr(err):
            code = oc.main(argv)
        return code, out.getvalue(), err.getvalue(), calls

    BASE = ["create", "--tier", "slice", "--dir", "/tmp/x", "--title", "poll"]

    def test_stdout_is_only_the_session_id(self):
        code, out, err, _ = self.run_create(self.BASE + ["--plan", "S04"])
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), "ses_abc")
        self.assertIn("announce:", err)

    def test_title_carries_the_plan_step(self):
        _, _, _, calls = self.run_create(self.BASE + ["--plan", "S04"])
        create = [c for c in calls if c[1] == "create"][0]
        self.assertEqual(create[create.index("--title") + 1], "slice/S04/poll")

    def test_provenance_keeps_both_plan_and_reason(self):
        code, _, err, calls = self.run_create(self.BASE + ["--plan", "S04", "--reason", "hotfix"])
        create = [c for c in calls if c[1] == "create"][0]
        reason = create[create.index("--reason") + 1]
        self.assertIn("plan S04", reason)
        self.assertIn("own: hotfix", reason)
        self.assertIn("plan S04; own: hotfix", err)

    def test_plan_tier_opens_a_plan_session(self):
        roster = [entry("claude-code/a", "plan", 1)]
        _, _, _, calls = self.run_create(
            ["create", "--tier", "plan", "--dir", "/tmp/x", "--title", "p", "--plan", "S06"], roster=roster)
        create = [c for c in calls if c[1] == "create"][0]
        self.assertEqual(create[create.index("--agent") + 1], "plan")

    def test_review_tier_opens_a_read_only_session(self):
        roster = [entry("minimax-coding-plan/mm", "review", 1, variant="")]
        _, _, _, calls = self.run_create(
            ["create", "--tier", "review", "--dir", "/tmp/x", "--title", "r", "--reason", "review the diff"],
            roster=roster, info_model={"providerID": "minimax-coding-plan", "id": "mm", "variant": "default"})
        create = [c for c in calls if c[1] == "create"][0]
        self.assertEqual(create[create.index("--agent") + 1], "plan")

    def test_free_model_gets_the_deny_list(self):
        roster = [entry("opencode-go/f-free", "mechanical", 1, variant="low", free=True)]
        code, _, err, calls = self.run_create(
            ["create", "--tier", "mechanical", "--dir", "/tmp/x", "--title", "m", "--plan", "S01"],
            roster=roster, info_model={"providerID": "opencode-go", "id": "f-free", "variant": "low"})
        self.assertEqual(code, 0)
        self.assertTrue(any(c[1] == "deny" and c[2] == "ses_abc" for c in calls))
        self.assertIn("deny-list attached", err)

    def test_a_free_route_declared_paid_still_gets_the_deny_list(self):
        """H1 end to end: the flag says paid, the audit says otherwise."""
        roster = [entry("opencode-go/mystery-route", "slice", 1, free=False)]
        code, _, err, calls = self.run_create(
            self.BASE + ["--plan", "S04"], roster=roster,
            info_model={"providerID": "opencode-go", "id": "mystery-route", "variant": "high"},
            free_ids={"opencode-go/mystery-route"},
            catalogue={"opencode-go/mystery-route": ["high"]})
        self.assertEqual(code, 0, err)
        self.assertTrue(any(c[1] == "deny" for c in calls), "no deny-list attached")
        self.assertIn("deny-list attached", err)

    def test_deny_failure_interrupts_the_session(self):
        roster = [entry("opencode-go/f-free", "mechanical", 1, variant="low", free=True)]
        code, out, err, calls = self.run_create(
            ["create", "--tier", "mechanical", "--dir", "/tmp/x", "--title", "m", "--plan", "S01"],
            roster=roster, info_model={"providerID": "opencode-go", "id": "f-free", "variant": "low"}, deny_rc=1)
        self.assertEqual(code, 2)
        self.assertEqual(out.strip(), "")
        self.assertTrue(any(c[1] == "interrupt" for c in calls))
        self.assertIn("deny-list could not be attached", err)

    def test_wrong_pair_is_interrupted_and_not_reported_as_usable(self):
        code, out, err, calls = self.run_create(
            self.BASE + ["--plan", "S04"], info_model={"providerID": "claude-code", "id": "other", "variant": "high"})
        self.assertEqual(code, 2)
        self.assertEqual(out.strip(), "")
        self.assertTrue(any(c[1] == "interrupt" for c in calls))
        self.assertIn("exists and is idle", err)
        self.assertIn("Do not prompt it", err)

    def test_empty_variant_accepts_a_default_reported_variant(self):
        roster = [entry("minimax-coding-plan/mm", "slice", 1, variant="")]
        code, _, err, _ = self.run_create(
            self.BASE + ["--plan", "S02"], roster=roster,
            info_model={"providerID": "minimax-coding-plan", "id": "mm", "variant": "default"})
        self.assertEqual(code, 0, err)

    def test_a_dead_route_does_not_block_create(self):
        """A candidate missing from the catalogue is a skip, not a roster outage."""
        roster = [entry("opencode-go/dead", "slice", 1), entry("claude-code/a", "slice", 2)]
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            if command[1] == "create":
                return SimpleNamespace(returncode=0, stdout="ses_live\n", stderr="")
            if command[1] == "info":
                return SimpleNamespace(returncode=0, stdout=json.dumps(
                    {"model": {"providerID": "claude-code", "id": "a", "variant": "high"}}), stderr="")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        err = io.StringIO()
        with patch.object(oc, "load_roster", return_value=roster), \
             patch.object(oc, "catalogue", return_value={"claude-code/a": ["high"]}), \
             patch.object(oc, "quota_snapshot", return_value=None), \
             patch.object(oc.subprocess, "run", side_effect=fake_run), \
             redirect_stdout(io.StringIO()), redirect_stderr(err):
            code = oc.main(["create", "--tier", "slice", "--dir", "/tmp/x", "--title", "poll", "--plan", "S04"])
        self.assertEqual(code, 0, err.getvalue())
        self.assertIn("skip slice 1/2 opencode-go/dead: absent", err.getvalue())
        self.assertIn("candidate 2 of 2", err.getvalue())

    def test_a_stale_roster_says_so_and_still_dispatches(self):
        roster = [entry("claude-code/a", "slice", 1, checked="2020-01-01")]
        code, _, err, calls = self.run_create(self.BASE + ["--plan", "S04"], roster=roster)
        self.assertEqual(code, 0)
        self.assertRegex(err, r"was last checked \d+ days ago")
        self.assertTrue([c for c in calls if c[1] == "create"])

    def test_missing_provenance_is_refused_before_creating(self):
        code, out, err, calls = self.run_create(self.BASE)
        self.assertEqual(code, 2)
        self.assertFalse([c for c in calls if c[1] == "create"])
        self.assertIn("one of --plan or --reason is required", err)


class EffortTest(unittest.TestCase):
    def run_effort(self, level="xhigh", session_model=None, offered=("low", "high", "xhigh"), after_model=None):
        roster = [entry("claude-code/a", "slice", 1)]
        session_model = session_model or {"providerID": "claude-code", "id": "a", "variant": "high"}
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            if command[1] == "info":
                payload = after_model if (after_model and len([c for c in calls if c[1] == "switch"])) else session_model
                return SimpleNamespace(returncode=0, stdout=json.dumps({"model": payload}), stderr="")
            if command[1] == "switch":
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        err = io.StringIO()
        with patch.object(oc, "load_roster", return_value=roster), \
             patch.object(oc, "catalogue", return_value={"claude-code/a": list(offered)}), \
             patch.object(oc.subprocess, "run", side_effect=fake_run), \
             redirect_stderr(err):
            code = oc.main(["effort", "ses_x", level])
        return code, err.getvalue(), calls

    def test_switches_effort_only_and_re_announces(self):
        code, err, calls = self.run_effort(
            after_model={"providerID": "claude-code", "id": "a", "variant": "xhigh"})
        switch = [c for c in calls if c[1] == "switch"][0]
        self.assertEqual(switch[3:], ["claude-code/a", "xhigh"])
        self.assertEqual(code, 0)
        self.assertIn("high -> xhigh", err)
        self.assertIn("same model", err)

    def test_a_level_the_model_does_not_offer_is_refused(self):
        code, err, calls = self.run_effort(level="max", offered=("low", "high"))
        self.assertEqual(code, 2)
        self.assertIn("not one of them", err)
        self.assertFalse([c for c in calls if c[1] == "switch"])

    def test_a_model_outside_the_roster_is_a_question_not_a_switch(self):
        code, err, calls = self.run_effort(session_model={"providerID": "opencode-go", "id": "mystery", "variant": "low"})
        self.assertEqual(code, 2)
        self.assertIn("not in the roster", err)
        self.assertFalse([c for c in calls if c[1] == "switch"])

    def test_a_no_op_effort_change_does_not_call_switch(self):
        code, err, calls = self.run_effort(level="high")
        self.assertEqual(code, 0)
        self.assertIn("already at high", err)
        self.assertFalse([c for c in calls if c[1] == "switch"])

    def test_a_switch_that_does_not_take_is_reported(self):
        code, err, _ = self.run_effort(after_model={"providerID": "claude-code", "id": "a", "variant": "high"})
        self.assertEqual(code, 2)
        self.assertIn("switch did not take", err)


class ExitCodeTest(unittest.TestCase):
    def test_exhausted_pick_exits_three(self):
        with patch.object(oc, "load_roster", return_value=[]), \
             patch.object(oc, "catalogue", return_value={}), \
             patch.object(oc, "resolve", return_value={"ok": False, "tier": "slice",
                                                       "steps": [{"label": "slice 1/1 a/b", "cause": "absent",
                                                                  "detail": "x", "id": "a/b"}]}), \
             redirect_stderr(io.StringIO()):
            self.assertEqual(oc.cmd_pick(SimpleNamespace(tier="slice", private=False, exclude=[])), 3)


if __name__ == "__main__":
    unittest.main()
