#!/usr/bin/env python3
"""Tests for suite_history.py (R2-PROC-06).

Run with: python3 -m unittest test_suite_history -v
(from `native/Scripts/`). `run-all-tests.sh` discovers it by its name.

Every case writes into its own temporary directory and removes it.
"""

import json
import os
import tempfile
import unittest

import suite_history as history


def tsv(*rows):
    return "\n".join("\t".join(str(c) for c in row) for row in rows) + "\n"


class ParseTests(unittest.TestCase):
    def test_a_results_file_round_trips(self):
        suites = history.parse_results(tsv(("FM_RUN_A_TESTS", "pass", 1200, 42), ("FM_RUN_B_TESTS", "flaky", 900, "-")))
        self.assertEqual(suites["FM_RUN_A_TESTS"], {"result": "pass", "ms": 1200, "checks": 42})
        self.assertIsNone(suites["FM_RUN_B_TESTS"]["checks"])

    def test_an_unknown_result_is_refused(self):
        with self.assertRaises(ValueError):
            history.parse_results(tsv(("FM_RUN_A_TESTS", "green", 1, 1)))


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "nested", "history.json")

    def tearDown(self):
        self.tmp.cleanup()

    def run_once(self, run, rows, lane="headless"):
        data = history.load(self.path)
        history.save(history.record(data, lane, run, history.parse_results(tsv(*rows)), now="2026-10-26T00:00:00Z"),
                     self.path)

    def test_runs_accumulate_across_calls_and_record_count_and_time(self):
        self.run_once("1", [("FM_RUN_A_TESTS", "pass", 1000, 3), ("FM_RUN_S_TESTS", "skip", 0, "-")])
        self.run_once("2", [("FM_RUN_A_TESTS", "fail", 2000, 3)])
        runs = history.load(self.path)["runs"]
        self.assertEqual([r["run"] for r in runs], ["1", "2"])
        self.assertEqual(runs[0]["suite_count"], 1, "a skipped suite did not run")
        self.assertEqual(runs[1]["lane_ms"], 2000)

    def test_the_history_is_capped(self):
        for n in range(history.MAX_RUNS + 5):
            self.run_once(str(n), [("FM_RUN_A_TESTS", "pass", 1, 1)])
        runs = history.load(self.path)["runs"]
        self.assertEqual(len(runs), history.MAX_RUNS)
        self.assertEqual(runs[-1]["run"], str(history.MAX_RUNS + 4))

    def test_an_unreadable_file_is_an_error_not_a_fresh_start(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as handle:
            handle.write("{not json")
        with self.assertRaises(ValueError):
            history.load(self.path)
        self.assertEqual(history.main(["record", "--file", self.path, "--lane", "x", "--run", "1",
                                       "--results", os.devnull]), 1)
        with open(self.path) as handle:
            self.assertEqual(handle.read(), "{not json", "a failed record must not overwrite the file")


class SummaryTests(unittest.TestCase):
    def build(self, *runs, lane="windowed-shard-2"):
        data = {"version": 1, "runs": []}
        for n, rows in enumerate(runs):
            history.record(data, lane, str(n), history.parse_results(tsv(*rows)), now="t%d" % n)
        return data

    def test_a_flaky_suite_is_named_and_the_run_still_says_it_failed(self):
        data = self.build([("FM_RUN_MAIN_SPLIT_SHELL_TESTS", "flaky", 60000, 10), ("FM_RUN_A_TESTS", "pass", 1000, 2)])
        text = history.summary(data, "windowed-shard-2")
        self.assertIn("`FM_RUN_MAIN_SPLIT_SHELL_TESTS`", text)
        self.assertIn("the run still fails", text)
        self.assertNotIn("`FM_RUN_A_TESTS`", text)

    def test_a_suite_that_passed_and_failed_across_runs_is_mixed(self):
        data = self.build([("FM_RUN_A_TESTS", "pass", 1, 1), ("FM_RUN_B_TESTS", "fail", 1, 1)],
                          [("FM_RUN_A_TESTS", "fail", 1, 1), ("FM_RUN_B_TESTS", "fail", 1, 1)])
        self.assertEqual(set(history.mixed_suites(data["runs"])), {"FM_RUN_A_TESTS"},
                         "a suite that fails every time is broken, not flaky")
        text = history.summary(data, "windowed-shard-2")
        self.assertIn("| `FM_RUN_A_TESTS` | 1 fail, 1 pass |", text)

    def test_count_and_lane_time_are_shown_per_run(self):
        data = self.build([("FM_RUN_A_TESTS", "pass", 90000, 1), ("FM_RUN_B_TESTS", "pass", 30000, 1)])
        self.assertIn("| t0 | 0 | 2 | 2.0 min |", history.summary(data, "windowed-shard-2"))

    def test_other_lanes_are_not_mixed_in(self):
        data = self.build([("FM_RUN_A_TESTS", "flaky", 1, 1)], lane="headless")
        self.assertIn("No run of this lane is recorded yet.", history.summary(data, "windowed-shard-2"))


class FileFormatTests(unittest.TestCase):
    def test_the_saved_file_is_plain_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "h.json")
            history.save(history.record({"version": 1, "runs": []}, "l", "1", {}), path)
            with open(path) as handle:
                self.assertEqual(json.load(handle)["version"], 1)
            self.assertEqual(sorted(os.listdir(tmp)), ["h.json"], "no temporary file left behind")


if __name__ == "__main__":
    unittest.main()
