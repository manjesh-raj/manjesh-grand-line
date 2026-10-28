#!/usr/bin/env bash
# Prove a built binary targets the macOS version this app says it supports.
#
#   Scripts/check-deployment-target.sh [path/to/GrandLine]   # default .build/release/GrandLine
#
# TEST-10 of the first full review, carried as R4-PROC-04 by the fourth: the
# deployment target is `.macOS(.v13)` in `Package.swift`, and nothing in CI
# ever showed the shipped binary really is a macOS 13 binary. Three places
# state the floor and nothing tied them together:
#
#   - `Package.swift`'s `platforms: [.macOS(.vN)]`, which SwiftPM turns into
#     the `-target ...-macosxN.0` every Swift file is compiled against. That
#     is what makes the compiler refuse an API newer than the floor without an
#     `#available` check, so a build at this target is the availability check.
#   - the binary's own `LC_BUILD_VERSION` load command (`minos`), which is what
#     the loader enforces.
#   - `LSMinimumSystemVersion` in the Info.plist `build_native_app.sh` writes
#     (and the probe app's copy), which is what Finder and Launch Services
#     enforce before the loader is ever reached.
#
# This fails when any of those disagree, for every architecture slice in the
# binary. What it cannot do is *run* anything on macOS 13: GitHub retired its
# macOS 13 runner image in December 2025, and `macos-15` is the oldest image
# this project builds on. So the code behind an `#available(macOS 14, *)`
# check's `else` branch still never executes in CI - that half of TEST-10
# stays open, and native/MANUAL-CHECKS.md says so.
#
# CI's `swift build (release)` job runs this on the release binary.

set -euo pipefail

cd "$(dirname "$0")/.."
BIN="${1:-.build/release/GrandLine}"

if [ ! -f "$BIN" ]; then
  echo "check-deployment-target: no binary at $BIN - build it first with 'swift build -c release'" >&2
  exit 2
fi

declared="$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1/p' Package.swift | head -1)"
if [ -z "$declared" ]; then
  echo "check-deployment-target: Package.swift declares no .macOS(.vN) platform" >&2
  exit 2
fi
want="$declared.0"
problems=0

# One `minos` per architecture slice; a universal binary has two.
archs="$(lipo -archs "$BIN" 2>/dev/null || echo "")"
[ -n "$archs" ] || archs="$(uname -m)"
for arch in $archs; do
  minos="$(otool -arch "$arch" -l "$BIN" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
  if [ "$minos" = "$want" ]; then
    echo "✓ $BIN ($arch) is built for macOS $minos, the floor Package.swift declares"
  else
    echo "✗ $BIN ($arch) is built for macOS ${minos:-<no LC_BUILD_VERSION>}, but Package.swift declares .macOS(.v$declared)"
    problems=$((problems + 1))
  fi
done

for script in build_native_app.sh Scripts/build-probe-app.sh; do
  plist="$(awk '/<key>LSMinimumSystemVersion<\/key>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit }' "$script")"
  if [ "$plist" = "$want" ]; then
    echo "✓ $script writes LSMinimumSystemVersion $plist"
  else
    echo "✗ $script writes LSMinimumSystemVersion ${plist:-<none>}, but Package.swift declares .macOS(.v$declared)"
    problems=$((problems + 1))
  fi
done

[ "$problems" -eq 0 ]
