#!/usr/bin/env bash
# Prove a release binary carries no test-only symbol of this app's own (GL-27).
#
#   Scripts/check-release-symbols.sh [path/to/GrandLine]   # default .build/release/GrandLine
#
# The self-test suites are compiled into debug builds only, and so is every
# `debug*` hook and `*ForTests` seam a production file exposes to them - each
# one sits inside `#if FM_SELFTESTS`. A hook left outside the guard still
# compiles, and a release build usually drops it again through dead-stripping,
# which is why nobody noticed: R2-ARCH-09 of the second full review found
# four `debug*` and eleven `*ForTests` symbols in the release binary that way
# (thirteen on the commit that guarded them). Dead-stripping is not a guard:
# a production caller of any of them would have shipped the hook it called.
#
# So this reads the symbol table rather than trusting the compiler to drop
# anything. It fails on any symbol in the `GrandLine` module whose name has a
# `debug<Upper>` member or ends in `ForTests`, and prints each one. Two
# families are deliberately allowed, because neither is test code:
#
#   - `debugDescription`, which is `CustomDebugStringConvertible` - every
#     `Codable` enum's synthesised `CodingKeys` carries one.
#   - Symbols outside this app's own module (SwiftTerm's `debugDescription`,
#     its `LocalProcess.debugIO`), which are vendored code and not this app's
#     to guard.
#
# CI's `swift build (release)` job runs this after the release compile, beside
# the `FM_RUN_*` strings check. `E2ETestingPolicySelfTest` fails the run if the
# workflow stops calling it.

set -euo pipefail

cd "$(dirname "$0")/.."
BIN="${1:-.build/release/GrandLine}"

if [ ! -f "$BIN" ]; then
  echo "check-release-symbols: no binary at $BIN - build it first with 'swift build -c release'" >&2
  exit 2
fi

# `nm` lists every symbol, `swift-demangle` turns the mangled Swift names into
# `GrandLine.Type.member` form, and the module prefix keeps vendored code out.
# The member pattern needs a `.` before `debug` so `isDebugBuild`-style names
# in the middle of an identifier are not caught, and the `ForTests` pattern is
# anchored to the end of an identifier.
found=$(nm "$BIN" | xcrun swift-demangle \
  | grep -E 'GrandLine\.' \
  | grep -oE '[A-Za-z_][A-Za-z0-9_.]*\.(debug[A-Z][A-Za-z0-9_]*|[A-Za-z0-9_]*ForTests)\b' \
  | grep -vE '\.debugDescription$' \
  | sort -u || true)

if [ -n "$found" ]; then
  count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
  echo "::error::the release binary carries $count test-only symbol(s) - guard each with #if FM_SELFTESTS (GL-27):"
  printf '%s\n' "$found"
  exit 1
fi

echo "release binary: no debug* or *ForTests symbols of this app's own ($BIN)"
