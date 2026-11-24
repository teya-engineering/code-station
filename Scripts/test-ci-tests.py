#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("ci_tests", Path(__file__).with_name("ci-tests.py"))
ci_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_tests)


class ShardTests(unittest.TestCase):
    def test_every_test_runs_once_and_nested_suites_stay_together(self):
        tests = {
            "MenuBarAppTests.Alpha/first()", "MenuBarAppTests.Alpha.Nested/second()",
            "MenuBarAppTests.Beta/third()", "MenuBarAppTests.Gamma/fourth()",
            "MenuBarAppTests.AlphaExtra/fifth()",
        }
        groups = [ci_tests.select_tests(tests, index, 2)[1] for index in range(2)]
        self.assertEqual(groups[0] | groups[1], tests)
        self.assertFalse(groups[0] & groups[1])
        for group in groups:
            self.assertEqual("MenuBarAppTests.Alpha/first()" in group,
                             "MenuBarAppTests.Alpha.Nested/second()" in group)
        pattern, selected = ci_tests.select_tests(tests, 0, 2)
        self.assertEqual({test for test in tests if re.search(pattern, test)}, selected)
        self.assertFalse(re.search(pattern, "MenuBarAppTestsXAlpha/first()"))

    def test_discovery_order_does_not_change_the_shards(self):
        tests = ["MenuBarAppTests.Alpha/one()", "MenuBarAppTests.Beta/two()"]
        self.assertEqual(ci_tests.select_tests(tests, 0, 2),
                         ci_tests.select_tests(reversed(tests), 0, 2))

    def test_invalid_and_empty_shards_fail(self):
        for shard, count in [(-1, 2), (2, 2), (0, 0), (1, 2)]:
            with self.subTest(shard=shard, count=count), self.assertRaises(ValueError):
                ci_tests.select_tests({"MenuBarAppTests.Alpha/one()"}, shard, count)
        with self.assertRaises(ValueError):
            ci_tests.select_tests(set(), 0, 2)

    def test_batches_bound_process_lifetime_without_omitting_or_repeating_tests(self):
        tests = {f"MenuBarAppTests.Suite{index}/one()" for index in range(101)}
        tests.add("MenuBarAppTests.Suite0.Nested/two()")
        completed = set()
        for pattern, batch in ci_tests.test_batches(tests):
            self.assertFalse(completed & batch)
            self.assertLessEqual(len({test.split(".")[1] for test in batch}), 25)
            self.assertEqual({test for test in tests if re.search(pattern, test)}, batch)
            self.assertEqual("MenuBarAppTests.Suite0/one()" in batch,
                             "MenuBarAppTests.Suite0.Nested/two()" in batch)
            completed |= batch
        self.assertEqual(completed, tests)


class ReportTests(unittest.TestCase):
    test_id = "MenuBarAppTests.Alpha/one()"

    def check(self, events):
        with tempfile.TemporaryDirectory(prefix="code-station-ci-report-") as scratch:
            path = Path(scratch) / "events.jsonl"
            path.write_text("".join(json.dumps({"version": 0, "kind": "event", "payload": event})
                                    + "\n" for event in events))
            ci_tests.check_results(path, {self.test_id})

    def test_completed_and_skipped_tests_are_accounted_for(self):
        for kind in ["testEnded", "testSkipped"]:
            with self.subTest(kind=kind):
                self.check([{"kind": kind, "testID": self.test_id + "/Alpha.swift:10:6"},
                            {"kind": "runEnded"}])

    def test_an_early_successful_exit_does_not_pass(self):
        with self.assertRaisesRegex(ValueError, "stopped before"):
            self.check([{"kind": "testEnded", "testID": self.test_id + "/Alpha.swift:10:6"}])

    def test_an_early_exit_names_the_last_test_started(self):
        with self.assertRaisesRegex(ValueError, "Last started: MenuBarAppTests.Alpha/one"):
            self.check([{"kind": "testStarted", "testID": self.test_id + "/Alpha.swift:10:6"}])

    def test_a_run_that_did_not_execute_the_selected_tests_does_not_pass(self):
        with self.assertRaisesRegex(ValueError, "did not finish"):
            self.check([{"kind": "runEnded"}])

    def test_failed_assertions_fail_even_when_the_process_exits_successfully(self):
        with self.assertRaisesRegex(ValueError, "unexpected issues"):
            self.check([{"kind": "issueRecorded", "issue": {"isKnown": False}},
                        {"kind": "runEnded"}])


if __name__ == "__main__":
    unittest.main()
