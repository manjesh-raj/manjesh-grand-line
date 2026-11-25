#!/usr/bin/env python3
"""Tests for line_budget.py (P-05).

Run with: python3 -m unittest test_line_budget -v
(from `native/Scripts/`). `run-all-tests.sh` discovers it by its name.

Every case writes into its own temporary directory and removes it.
"""

import os
import tempfile
import unittest

import line_budget


class LineBudgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, lines, header=""):
        with open(os.path.join(self.tmp.name, name), "w", encoding="utf-8") as handle:
            handle.write(header + "".join(f"let a{i} = {i}\n" for i in range(lines)))

    def test_a_file_over_the_budget_is_named(self):
        self.write("Big.swift", 11)
        self.write("Small.swift", 10)
        found = line_budget.over_budget(self.tmp.name, budget=10)
        self.assertEqual([os.path.basename(p) for p, _ in found], ["Big.swift"])
        self.assertEqual(found[0][1], 11)

    def test_a_generated_file_is_skipped(self):
        self.write("Shader.swift", 50, header="// Grand Line\n//\n// GENERATED FILE - do not hand-edit.\n")
        self.assertEqual(line_budget.over_budget(self.tmp.name, budget=10), [])

    def test_the_marker_counts_only_in_the_header(self):
        self.write("Late.swift", 20, header="")
        with open(os.path.join(self.tmp.name, "Late.swift"), "a", encoding="utf-8") as handle:
            handle.write("// GENERATED FILE mentioned far below the header\n")
        found = line_budget.over_budget(self.tmp.name, budget=10)
        self.assertEqual([os.path.basename(p) for p, _ in found], ["Late.swift"])

    def test_the_report_is_a_warning_and_never_an_error(self):
        lines = line_budget.report([("Sources/GrandLine/Big.swift", 11)], budget=10, annotate=True)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("::warning file=native/Sources/GrandLine/Big.swift::"))
        self.assertIn("11 lines", lines[0])

    def test_largest_first(self):
        self.write("A.swift", 12)
        self.write("B.swift", 15)
        found = line_budget.over_budget(self.tmp.name, budget=10)
        self.assertEqual([os.path.basename(p) for p, _ in found], ["B.swift", "A.swift"])


if __name__ == "__main__":
    unittest.main()
