#!/usr/bin/env python3
"""Tests for draft_release_notes.py (R2-PROC-04).

Run with: python3 -m unittest test_draft_release_notes -v
(from `native/Scripts/`). `run-all-tests.sh` discovers it by its name.

The parsing and rendering are tested as pure functions. The end-to-end case
builds a throwaway local repository in a temporary directory with two tags
and a squash-merge-shaped history, so it reads real `git log` output without
touching this repository or the network.
"""

import os
import subprocess
import tempfile
import unittest

import draft_release_notes as notes


class ParseTests(unittest.TestCase):
    def test_a_squash_merge_subject_carries_its_number(self):
        change = notes.parse_subject("Fix review #2's sixteen bugs, R2-BUG-01 to R2-BUG-16 (#528)")
        self.assertEqual(change.number, 528)
        self.assertEqual(change.title, "Fix review #2's sixteen bugs, R2-BUG-01 to R2-BUG-16")

    def test_a_hash_inside_the_title_is_not_the_number(self):
        change = notes.parse_subject("Fix review #2's process findings")
        self.assertIsNone(change.number)

    def test_a_direct_commit_has_no_number(self):
        self.assertIsNone(notes.parse_subject("Bump the pinned Pillow").number)

    def test_github_remotes_give_a_pull_url(self):
        want = "https://github.com/manjesh-raj/manjesh-grand-line/pull/"
        for remote in ("https://github.com/manjesh-raj/manjesh-grand-line.git",
                       "git@github.com:manjesh-raj/manjesh-grand-line.git",
                       "https://github.com/manjesh-raj/manjesh-grand-line"):
            self.assertEqual(notes.github_pull_url(remote), want, remote)
        self.assertIsNone(notes.github_pull_url("/tmp/bare.git"))


class RenderTests(unittest.TestCase):
    def test_pull_requests_are_listed_with_links_in_order(self):
        text = notes.render([notes.Change("First", 1), notes.Change("Direct", None), notes.Change("Second", 2)],
                            "v0.1.0", "v0.2.0", "https://github.com/o/r/pull/")
        self.assertIn("2 pull request(s) merged between `v0.1.0` and `v0.2.0`.", text)
        self.assertLess(text.index("First"), text.index("Second"))
        self.assertIn("- First ([#1](https://github.com/o/r/pull/1))", text)
        self.assertIn("### Commits with no pull request", text)
        self.assertIn("- Direct", text)

    def test_an_empty_range_says_so(self):
        self.assertIn("Nothing was merged", notes.render([], "v1", "v1", None))


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.env = env

        def git(*args):
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                           cwd=self.repo, env=env, check=True, capture_output=True)

        git("init", "-q")
        git("commit", "-q", "--allow-empty", "-m", "Initial")
        git("tag", "v0.1.0")
        git("commit", "-q", "--allow-empty", "-m", "Sidebar layout stage 7 (#525)")
        git("commit", "-q", "--allow-empty", "-m", "Fix review #2's sixteen bugs (#528)")
        git("tag", "v0.2.0")
        git("commit", "-q", "--allow-empty", "-m", "After the tag (#600)")

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_range_between_two_tags(self):
        text = notes.draft("v0.1.0", "v0.2.0", cwd=self.repo)
        self.assertIn("2 pull request(s)", text)
        self.assertIn("- Sidebar layout stage 7 (#525)", text)
        self.assertIn("- Fix review #2's sixteen bugs (#528)", text)
        self.assertNotIn("After the tag", text)
        self.assertNotIn("Initial", text)

    def test_an_unknown_tag_is_an_error_not_an_empty_draft(self):
        with self.assertRaises(RuntimeError):
            notes.draft("v9.9.9", cwd=self.repo)

    def test_it_creates_no_tag_and_writes_no_file(self):
        before = sorted(os.listdir(self.repo))
        tags = subprocess.run(["git", "tag"], cwd=self.repo, capture_output=True, text=True).stdout
        notes.draft("v0.1.0", cwd=self.repo)
        self.assertEqual(sorted(os.listdir(self.repo)), before)
        self.assertEqual(subprocess.run(["git", "tag"], cwd=self.repo, capture_output=True, text=True).stdout, tags)


if __name__ == "__main__":
    unittest.main()
