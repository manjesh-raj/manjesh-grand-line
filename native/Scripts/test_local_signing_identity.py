#!/usr/bin/env python3
"""Tests for local-signing-identity.sh (fm/grand-line-stable-signing-identity).

Run with: python3 -m unittest test_local_signing_identity -v
(from `native/Scripts/`). `run-all-tests.sh` discovers it by its name.

What a test can reach here is bounded by macOS itself. `codesign` refuses an
identity whose certificate is not trusted for code signing, and trusting one
changes the user's trust settings behind a password prompt. So nothing here
signs with the CA-issued identity. That end of it was measured with
throwaway bundles signed by another tool and evaluated by Apple's own
`codesign --verify -R`, and `setup` repeats the check on the captain's machine
with Apple's codesign the first time it runs. See docs/history/16-dictation.md.

What is covered: the certificate recipe, the requirement the build embeds,
how the CA is found (exact name, never two), that an untrusted leaf is never
used, and that both build scripts sign through this script only.

Every keychain operation goes to a throwaway keychain file in a temporary
directory through FM_SIGNING_KEYCHAIN. It is never added to the search list,
nothing is trusted, and nothing reads a keychain item's secret, so nothing
here can raise a prompt.
"""

import datetime
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "local-signing-identity.sh")
NATIVE = os.path.dirname(HERE)
CA_NAME = "Grand Line Local CA"
LEAF_NAME = "Grand Line Code Signing"
ORGANIZATION = "Grand Line Local"


def openssl(*args):
    return subprocess.run(["openssl", *args], check=True, capture_output=True, text=True).stdout


def x509(cert, *args):
    return openssl("x509", "-in", cert, "-noout", *args)


def name(cert, which):
    """The subject or issuer as a set of "KEY=value" parts.

    OpenSSL versions print names differently ("O=X" here, "O = X" on CI's
    runner), so ask for RFC 2253 and split it rather than match the text.
    """
    text = x509(cert, "-" + which, "-nameopt", "RFC2253").strip()
    return {part.strip() for part in text.split("=", 1)[1].split(",")}


def sha1(cert):
    return x509(cert, "-fingerprint", "-sha1").split("=", 1)[1].strip().replace(":", "").lower()


def not_after(cert):
    text = x509(cert, "-enddate").split("=", 1)[1].strip()
    return datetime.datetime.strptime(text, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="local-signing-identity-")
        self.addCleanup(shutil.rmtree, self.root)

    def run_script(self, *args, keychain=None):
        env = dict(os.environ)
        env.pop("FM_SIGNING_KEYCHAIN", None)
        if keychain:
            env["FM_SIGNING_KEYCHAIN"] = keychain
        return subprocess.run([SCRIPT, *args], capture_output=True, text=True, env=env)

    def certificates(self, name):
        directory = os.path.join(self.root, name)
        result = self.run_script("certificates", directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        return directory

    def keychain(self):
        path = os.path.join(self.root, "test.keychain-db")
        subprocess.run(["security", "create-keychain", "-p", "test", path], check=True, capture_output=True)
        self.addCleanup(subprocess.run, ["security", "delete-keychain", path], capture_output=True)
        # No auto-lock, so a slow runner never meets a locked keychain.
        subprocess.run(["security", "set-keychain-settings", path], check=True, capture_output=True)
        return path

    def import_certificate(self, keychain, cert):
        subprocess.run(["security", "import", cert, "-k", keychain], check=True, capture_output=True)

    def import_identity(self, keychain, directory):
        p12 = os.path.join(directory, "leaf.p12")
        legacy = ["-legacy"] if "-legacy" in subprocess.run(
            ["openssl", "pkcs12", "-help"], capture_output=True, text=True).stderr else []
        openssl("pkcs12", "-export", *legacy, "-inkey", os.path.join(directory, "leaf.key"),
                "-in", os.path.join(directory, "leaf.crt"), "-out", p12, "-passout", "pass:test")
        subprocess.run(["security", "import", p12, "-k", keychain, "-P", "test"],
                       check=True, capture_output=True)


class CertificateRecipeTests(Fixture):
    def setUp(self):
        super().setUp()
        self.dir = self.certificates("certs")
        self.ca = os.path.join(self.dir, "ca.crt")
        self.leaf = os.path.join(self.dir, "leaf.crt")

    def test_the_leaf_is_issued_by_the_ca_and_not_self_signed(self):
        # Discriminating power first: a leaf that signed itself would make
        # its root its own hash, which is the leaf-pinning this replaces.
        self.assertNotEqual(sha1(self.ca), sha1(self.leaf))
        self.assertIn("CN=" + LEAF_NAME, name(self.leaf, "subject"))
        self.assertIn("CN=" + CA_NAME, name(self.leaf, "issuer"))
        result = subprocess.run(["openssl", "verify", "-CAfile", self.ca, self.leaf],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_leaf_carries_what_macos_needs_for_code_signing(self):
        text = x509(self.leaf, "-text")
        # Without these three, macOS rejects the certificate - the defect the
        # 2026-11-15 recreation fixed in the old recipe.
        self.assertRegex(text, r"Basic Constraints: critical\s+CA:FALSE")
        self.assertRegex(text, r"Key Usage: critical\s+Digital Signature")
        self.assertRegex(text, r"Extended Key Usage: critical\s+Code Signing")

    def test_the_ca_can_only_issue_leaves(self):
        text = x509(self.ca, "-text")
        self.assertRegex(text, r"Basic Constraints: critical\s+CA:TRUE, pathlen:0")
        self.assertRegex(text, r"Key Usage: critical\s+Certificate Sign, CRL Sign")

    def test_both_carry_the_same_organization(self):
        # codesign's own default requirement walks up the chain while the
        # Organization matches, so this also makes the default anchor on the
        # CA rather than on the leaf.
        self.assertIn("O=" + ORGANIZATION, name(self.leaf, "subject"))
        self.assertIn("O=" + ORGANIZATION, name(self.ca, "subject"))

    def test_the_ca_outlives_the_machine(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        self.assertGreater(not_after(self.ca) - now, datetime.timedelta(days=365 * 29))
        self.assertGreater(not_after(self.ca), not_after(self.leaf))

    def test_two_runs_make_two_different_cas(self):
        # Why `setup` refuses to make a second one: the same recipe never
        # yields the same CA twice, so a second CA is always a new identity.
        other = self.certificates("other")
        self.assertNotEqual(sha1(self.ca), sha1(os.path.join(other, "ca.crt")))

    def test_the_ca_key_fits_what_setup_can_store(self):
        der = subprocess.run(["openssl", "pkey", "-in", os.path.join(self.dir, "ca.key"), "-outform", "DER"],
                             check=True, capture_output=True).stdout
        encoded = subprocess.run(["base64"], input=der, check=True, capture_output=True).stdout
        with open(SCRIPT) as f:
            limit = int(re.search(r"^MAX_STORED_KEY_CHARS=(\d+)", f.read(), re.M).group(1))
        self.assertLess(len(encoded.replace(b"\n", b"")), limit)


class KeychainTests(Fixture):
    def setUp(self):
        super().setUp()
        self.kc = self.keychain()
        self.dir = self.certificates("certs")
        self.ca = os.path.join(self.dir, "ca.crt")

    def test_no_ca_means_no_requirement(self):
        result = self.run_script("requirement", "com.example.app", keychain=self.kc)
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_the_requirement_anchors_on_the_ca(self):
        self.import_certificate(self.kc, self.ca)
        result = self.run_script("requirement", "com.example.app", keychain=self.kc)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(),
                         'identifier "com.example.app" and certificate root = H"%s"' % sha1(self.ca))

    def test_the_requirement_compiles(self):
        # The same compiler tccd's stored csreq came from.
        self.import_certificate(self.kc, self.ca)
        requirement = self.run_script("requirement", "com.example.app", keychain=self.kc).stdout.strip()
        blob = os.path.join(self.root, "req.bin")
        subprocess.run(["csreq", "-r=" + requirement, "-b", blob], check=True, capture_output=True)
        text = subprocess.run(["csreq", "-r", blob, "-t"], check=True, capture_output=True, text=True).stdout
        self.assertEqual(text.strip(), requirement)

    def test_a_longer_name_is_not_the_ca(self):
        # `security find-certificate -c` matches substrings.
        other = os.path.join(self.root, "longer")
        os.makedirs(other)
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
                "-keyout", os.path.join(other, "k"), "-out", os.path.join(other, "c"),
                "-subj", "/CN=%s Old" % CA_NAME)
        self.import_certificate(self.kc, os.path.join(other, "c"))
        result = self.run_script("requirement", "com.example.app", keychain=self.kc)
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_two_cas_with_the_name_are_refused(self):
        self.import_certificate(self.kc, self.ca)
        second = os.path.join(self.certificates("second"), "ca.crt")
        self.import_certificate(self.kc, second)
        result = self.run_script("requirement", "com.example.app", keychain=self.kc)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn(sha1(self.ca), result.stderr)
        self.assertIn(sha1(second), result.stderr)

    def test_nothing_to_sign_with_is_exit_4(self):
        bundle = os.path.join(self.root, "Unsigned.app")
        result = self.run_script("sign", bundle, "com.example.app", keychain=self.kc)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)

    def test_an_untrusted_leaf_is_never_used(self):
        self.import_certificate(self.kc, self.ca)
        self.import_identity(self.kc, self.dir)
        listed = subprocess.run(["security", "find-identity", "-p", "codesigning", self.kc],
                                capture_output=True, text=True).stdout
        # The identity is really there, so "not used" means "not valid".
        self.assertIn('"%s"' % LEAF_NAME, listed)
        result = self.run_script("sign", os.path.join(self.root, "X.app"), "com.example.app", keychain=self.kc)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("setup to reissue it", result.stdout)

    def test_status_reads_an_empty_keychain(self):
        result = self.run_script("status", keychain=self.kc)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("has not been set up", result.stdout)
        self.assertIn("Builds are unsigned.", result.stdout)


class CallSiteTests(unittest.TestCase):
    """Both build scripts must sign through local-signing-identity.sh.

    A second copy of the identity choice is how the extension or the
    re-signed host would end up on a different certificate - and a host
    re-signed without the explicit requirement falls back to codesign's
    default, which is a different requirement from the one granted.
    """

    def signing_lines(self, path):
        with open(path) as f:
            return [line.strip() for line in f
                    if re.search(r"\bcodesign\b.*(--sign|-s )", line) and not line.lstrip().startswith("#")]

    def test_the_app_build_never_calls_codesign_to_sign(self):
        self.assertEqual(self.signing_lines(os.path.join(NATIVE, "build_native_app.sh")), [])

    def test_the_widget_build_signs_locally_only_through_the_script(self):
        lines = self.signing_lines(os.path.join(HERE, "build-widget-extension.sh"))
        # Developer ID and the ad-hoc fallback are the two it owns itself.
        self.assertTrue(lines)
        for line in lines:
            self.assertRegex(line, r'--sign ("Developer ID Application"|-)\s')

    def test_both_use_the_script(self):
        for path in (os.path.join(NATIVE, "build_native_app.sh"), os.path.join(HERE, "build-widget-extension.sh")):
            with open(path) as f:
                self.assertIn("Scripts/local-signing-identity.sh sign", f.read(), path)


if __name__ == "__main__":
    unittest.main()
