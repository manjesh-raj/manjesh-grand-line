#!/usr/bin/env python3
"""Tests for check-signing-identity.sh (fm/grand-line-dictation-autopaste-denied).

Run with: python3 -m unittest test_check_signing_identity -v
(from `native/Scripts/`). `run-all-tests.sh` discovers it by its name.

Every case signs throwaway app bundles ad hoc in a temporary directory, so it
needs `codesign` and nothing else: no certificate, no keychain, and nothing
outside the temporary directory. An ad-hoc requirement is `cdhash H"..."`
rather than the local identity's `certificate leaf = H"..."`, but the script
compares the requirement as text, so the shape does not matter to it.
"""

import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-signing-identity.sh")


def make_bundle(root, name, identifier, sign=True):
    bundle = os.path.join(root, name + ".app")
    macos = os.path.join(bundle, "Contents", "MacOS")
    os.makedirs(macos)
    shutil.copy("/usr/bin/true", os.path.join(macos, name))
    with open(os.path.join(bundle, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump({
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
        }, f)
    if sign:
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", identifier, bundle],
                       check=True, capture_output=True)
    else:
        # /usr/bin/true arrives with Apple's own signature, which would make
        # the "unsigned" fixture signed after all.
        subprocess.run(["codesign", "--remove-signature", os.path.join(macos, name)],
                       check=True, capture_output=True)
    return bundle


def run(*args):
    return subprocess.run([SCRIPT, *args], capture_output=True, text=True)


class CheckSigningIdentityTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="check-signing-identity-")
        self.addCleanup(shutil.rmtree, self.root)
        self.first = make_bundle(self.root, "First", "com.example.grandline.first")
        self.second = make_bundle(self.root, "Second", "com.example.grandline.second")

    def requirement(self, bundle):
        result = run("requirement", bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_the_fixtures_really_have_different_identities(self):
        # Discriminating power first: if both fixtures read the same, every
        # "changed" case below would be testing nothing.
        first, second = self.requirement(self.first), self.requirement(self.second)
        self.assertTrue(first)
        self.assertTrue(second)
        self.assertNotEqual(first, second)

    def test_a_missing_or_unsigned_bundle_has_no_requirement(self):
        unsigned = make_bundle(self.root, "Unsigned", "com.example.grandline.unsigned", sign=False)
        self.assertEqual(self.requirement(unsigned), "")
        self.assertEqual(self.requirement(os.path.join(self.root, "Missing.app")), "")

    def test_a_first_build_has_nothing_to_compare(self):
        result = run("compare", "", self.first)
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_the_same_identity_is_silent(self):
        result = run("compare", self.requirement(self.first), self.first)
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_a_changed_identity_prints_the_one_time_reset(self):
        before = self.requirement(self.first)
        result = run("compare", before, self.second)
        self.assertEqual(result.returncode, 3)
        self.assertIn("before: " + before, result.stdout)
        self.assertIn("now:    " + self.requirement(self.second), result.stdout)
        # The reset names the bundle being installed, which is the identifier
        # every stale grant is filed under.
        self.assertIn("tccutil reset All com.example.grandline.second", result.stdout)
        # The captain's own attempt was the toggle; the warning must rule it out.
        self.assertIn("does not fix it", result.stdout)

    def test_a_requirement_the_new_build_still_satisfies_is_silent(self):
        # What lets the CA-issued certificate be reissued quietly: the text
        # differs, but tccd only asks whether the new code satisfies the old
        # requirement, and it does.
        previous = 'identifier "com.example.grandline.first"'
        self.assertNotEqual(previous, self.requirement(self.first))
        result = run("compare", previous, self.first)
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_moving_onto_a_local_ca_says_it_is_the_last_time(self):
        # Ad hoc with an explicit requirement: codesign records the text as
        # given, which is all `compare` reads of the new build's own side.
        anchored = 'identifier "com.example.grandline.second" and certificate root = H"%s"' % ("ab" * 20)
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "com.example.grandline.second",
                        "-r", "=designated => " + anchored, self.second], check=True, capture_output=True)
        self.assertEqual(self.requirement(self.second), anchored)

        result = run("compare", self.requirement(self.first), self.second)
        self.assertEqual(result.returncode, 3)
        self.assertIn("should not be needed again", result.stdout)

        # A CA replaced by another CA is the old failure, and gets no promise.
        other_ca = anchored.replace("ab" * 20, "cd" * 20)
        result = run("compare", other_ca, self.second)
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("should not be needed again", result.stdout)

    def test_dropping_to_an_unsigned_build_is_a_change_too(self):
        unsigned = make_bundle(self.root, "Unsigned", "com.example.grandline.unsigned", sign=False)
        result = run("compare", self.requirement(self.first), unsigned)
        self.assertEqual(result.returncode, 3)
        self.assertIn("now:    <unsigned>", result.stdout)


if __name__ == "__main__":
    unittest.main()
