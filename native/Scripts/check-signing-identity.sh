#!/usr/bin/env bash
# Notice when a build is signed with a different code identity than the copy
# it replaces, and say exactly what the captain has to do about it once.
#
#   Scripts/check-signing-identity.sh requirement <bundle>
#       Print the bundle's designated requirement, or nothing when it has no
#       readable signature (missing, unsigned). Always exits 0.
#
#   Scripts/check-signing-identity.sh compare <previous-requirement> <bundle>
#       Exit 0 and print nothing when <previous-requirement> is empty (a first
#       build) or matches <bundle>'s. Otherwise print the one-time repair and
#       exit 3. `build_native_app.sh` treats that as a warning, not a failure.
#
# Why this exists (fm/grand-line-dictation-autopaste-denied): macOS records
# every privacy grant against the designated requirement the app had when the
# grant was made. A build signed with the "Grand Line Local Dev" identity has
# a requirement of the form
#
#   identifier "com.manjesh.grandline.native" and certificate leaf = H"<sha1>"
#
# so ordinary rebuilds keep every grant, and replacing that certificate breaks
# all of them at once. That happened on 2026-11-15, when the certificate was
# recreated with native/README.md's corrected recipe. From then on `tccd`
# logged "Failed to match existing code requirement" for Accessibility and
# Screen Recording on every check and denied both, while System Settings kept
# showing Grand Line switched on. Dictation therefore copied instead of
# pasting. Nothing in the build said a thing.
#
# Switching the row off and on does not repair it. Measured on the captain's
# machine: System Settings writes that as a `Modify` of the existing record,
# and the very next check still compared against the old certificate. The
# app's own `CGRequestPostEventAccess()` cannot repair it either, because macOS
# only prompts when no record exists. The record has to be removed.

set -euo pipefail

designated_requirement() {
  # `codesign -d -r-` prints "designated => <requirement>" on stdout and the
  # "Executable=" line on stderr. An ad-hoc signature has only the implicit
  # requirement macOS derives from its cdhash, printed as a comment
  # ("# designated => cdhash H\"...\""), and `tccd` pins grants to that one
  # just the same. An unsigned or missing bundle prints nothing on stdout,
  # which is the "no previous identity" answer.
  codesign -d -r- "$1" 2>/dev/null | sed -n 's/^\(# \)\{0,1\}designated => //p' | head -n 1
}

signing_identifier() {
  codesign -d -v "$1" 2>&1 | sed -n 's/^Identifier=//p' | head -n 1
}

usage() {
  echo "usage: $0 requirement <bundle>" >&2
  echo "       $0 compare <previous-requirement> <bundle>" >&2
  exit 2
}

[ $# -ge 1 ] || usage

case "$1" in
  requirement)
    [ $# -eq 2 ] || usage
    designated_requirement "$2" || true
    ;;
  compare)
    [ $# -eq 3 ] || usage
    previous="$2"
    bundle="$3"
    [ -n "$previous" ] || exit 0
    current="$(designated_requirement "$bundle" || true)"
    [ "$current" != "$previous" ] || exit 0

    identifier="$(signing_identifier "$bundle" || true)"
    identifier="${identifier:-com.manjesh.grandline.native}"
    cat <<WARNING

⚠️  This build is signed with a different code identity than the copy it replaces.
      before: $previous
      now:    ${current:-<unsigned>}

    macOS ties every privacy grant to the old identity. System Settings will
    still show Grand Line switched on under Accessibility, but macOS now denies
    it, so dictation copies the transcript instead of pasting it. Turning that
    switch off and on keeps the old record and does not fix it.

    Do this once, with Grand Line quit:

      tccutil reset All $identifier

    Or, in System Settings > Privacy & Security > Accessibility, select Grand
    Line, remove it with the minus button and add it back with plus.
    Then open Grand Line and allow each permission again when it asks.

    Saved SSH keys in the Keychain were bound to the old identity too, so
    expect macOS to ask once before Grand Line can read each of them.
WARNING
    exit 3
    ;;
  *)
    usage
    ;;
esac
