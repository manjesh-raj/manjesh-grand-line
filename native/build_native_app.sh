#!/usr/bin/env bash
# Build Grand Line.app: a plain macOS app-bundle wrapper around the
# native Swift cockpit (native/, SwiftTerm-based). No notarization, but the
# bundle is codesigned with a stable local identity when one is available -
# see "Local signing" below and native/README.md's "Local signing setup" section.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Grand Line.app"
DIST_DIR="../dist"
APP_DIR="$DIST_DIR/$APP_NAME"
EXECUTABLE_NAME="GrandLine"
BUNDLE_ID="com.manjesh.grandline.native"
# GL-18: derive the version from git rather than hardcoding it. `git describe`
# gives `v0.2.0` on a tagged commit and `v0.2.0-7-g1a2b3c4` seven commits later,
# which is exactly what a dev build should say. Falls back to a short SHA (or
# `0.0.0-unknown` outside a checkout) so a build never fails just because tags
# are missing.
#
# `CFBundleShortVersionString` must be a plain dotted number for Launch
# Services, so the marketing version is the tag's numeric part only, while the
# full describe string (commits-ahead + SHA + `-dirty`) goes into
# `CFBundleVersion`, which is free-form.
GIT_DESCRIBE="$(git describe --tags --dirty --always 2>/dev/null || true)"
if [ -z "$GIT_DESCRIBE" ]; then
  GIT_DESCRIBE="0.0.0-unknown"
fi
# Strip a leading `v` and keep the leading dotted-number run for the short
# version; anything without one (a bare SHA) falls back to 0.0.0.
SHORT_VERSION="$(printf '%s' "${GIT_DESCRIBE#v}" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')"
if [ -z "$SHORT_VERSION" ]; then
  SHORT_VERSION="0.0.0"
fi
VERSION="$SHORT_VERSION"
BUILD_VERSION="${GIT_DESCRIBE#v}"
ICON_SRC="../assets/icon.icns"
SIGNING_IDENTITY="Grand Line Local Dev"
# The rename to "Grand Line" renamed this identity too, and a captain who has
# not yet created the new certificate would otherwise silently drop to an
# unsigned build - which gets a fresh ad-hoc code identity on every rebuild and
# loses Keychain ACL trust for the saved SSH keys, the exact failure the rename
# is careful to avoid everywhere else. So the old name is still accepted when
# only it exists. Creating the new cert and deleting the old one is the clean
# end state; native/README.md's "Local signing setup" has the commands.
LEGACY_SIGNING_IDENTITY="Firstmate Cockpit Local Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$LEGACY_SIGNING_IDENTITY"; then
    echo "Note: signing with the pre-rename identity \"$LEGACY_SIGNING_IDENTITY\"."
    echo "      See native/README.md's \"Local signing setup\" to create \"$SIGNING_IDENTITY\"."
    SIGNING_IDENTITY="$LEGACY_SIGNING_IDENTITY"
  fi
fi

# ---------------------------------------------------------------------------
# F21 (App Intents / Shortcuts).
#
# The five `AppIntent` types in Sources/GrandLine/GrandLineAppIntents.swift
# compile into the binary with a plain `swift build`, but Shortcuts, Siri and
# Spotlight do not find them that way: they are discovered from a
# `Metadata.appintents` bundle inside Contents/Resources, produced by Xcode's
# `appintentsmetadataprocessor`. SwiftPM never runs that tool - it is an Xcode
# build phase - and AGENTS.md's "Build, run, test" is explicit that this
# project builds with Command Line Tools and never Xcode.
#
# Both stay true here, because this is a *packaging* step and not a build one:
#
#   - `swift build` on its own is unchanged and needs nothing from Xcode. The
#     two extra swiftc flags below are added ONLY when the processor is
#     actually present, so a CLT-only machine takes the same command it always
#     did rather than failing on a flag its compiler may not know.
#   - A `.app` packaged without the processor is not broken. It simply
#     publishes no Shortcuts actions, and Settings' "Shortcuts & Siri" card
#     reads the bundle and says so (GL-14 - it never claims five working
#     actions it does not have).
#
# The processor needs two inputs the compiler has to be asked for: the list of
# source files, and the `.swiftconstvalues` file the Swift frontend emits when
# told which protocols to gather conformances for. That protocol list is
# written below rather than shipped by Xcode, which ships none.
APPINTENTS_PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
APPINTENTS_WORK="$(mktemp -d)"
trap 'rm -rf "$APPINTENTS_WORK"' EXIT
# The protocol list is the one App Intents input that goes on the *compiler's*
# command line, so unlike the two file lists below it must live at a **stable**
# path. It used to sit in `$APPINTENTS_WORK`, a fresh `mktemp -d` per run, and
# a changing `-const-gather-protocols-file` argument makes SwiftPM recompile one
# file on every build - which moves that object's mtime, which moves the `OSO`
# debug-map stab the linker writes into the binary, which moves the bundle's
# CDHash even though nothing was edited. Same class of defect as the App Intents
# metadata below (see `stabilize_appintents_metadata`), and the same cost to the
# captain: a Keychain ACL binds to the CDHash. Measured: with the path pinned,
# two consecutive builds relink to byte-identical binaries.
APPINTENTS_PROTOCOLS="$PWD/.build/appintents-protocols.json"
SWIFT_BUILD_EXTRA=()
if [ -n "$APPINTENTS_PROCESSOR" ] && [ -x "$APPINTENTS_PROCESSOR" ]; then
  mkdir -p "$(dirname "$APPINTENTS_PROTOCOLS")"
  cat > "$APPINTENTS_PROTOCOLS" <<'PROTOCOLS'
["AppEntity","AppEnum","AppIntent","AppShortcutsProvider","DynamicOptionsProvider","EntityIdentifierConvertible","EntityPropertyQuery","EntityQuery","EntityStringQuery","IndexedEntity","PersistentAppEntity","TransientAppEntity","URLRepresentableEntity","URLRepresentableEnum","URLRepresentableIntent"]
PROTOCOLS
  # Each -Xfrontend forwards exactly one following argument, which is why the
  # flag and its value each need their own pair. Getting this wrong makes
  # SwiftPM treat the JSON as an input source file, with a confusing
  # "unexpected input file" error.
  SWIFT_BUILD_EXTRA=(-Xswiftc -emit-const-values
                     -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
                     -Xswiftc -Xfrontend -Xswiftc "$APPINTENTS_PROTOCOLS")
else
  echo "⚠️  No appintentsmetadataprocessor (it ships with Xcode, not Command Line Tools)."
  echo "    The app will build and run normally, but its five Shortcuts/Siri actions"
  echo "    will not be registered with the system. Settings → Shortcuts & Siri says so."
fi

echo "Building $EXECUTABLE_NAME (release) - version $VERSION (build $BUILD_VERSION)…"
swift build -c release "${SWIFT_BUILD_EXTRA[@]}"

BIN="./.build/release/$EXECUTABLE_NAME"
[ -x "$BIN" ] || { echo "build did not produce $BIN"; exit 1; }

# R2: keep the previous bundle's App Intents metadata before the bundle is
# thrown away, so the step after the processor runs can compare against it.
# See the long comment beside `stabilize_appintents_metadata` for what this
# buys and why it is done this way rather than the obvious way.
PREVIOUS_APPINTENTS=""
if [ -d "$APP_DIR/Contents/Resources/Metadata.appintents" ]; then
  PREVIOUS_APPINTENTS="$APPINTENTS_WORK/previous-Metadata.appintents"
  cp -R "$APP_DIR/Contents/Resources/Metadata.appintents" "$PREVIOUS_APPINTENTS"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/icon.icns"
fi

# SRE Lead's read-only kubectl MCP tool (SRELead.swift resolves it via
# Bundle.main.resourceURL first, falling back to the source tree for
# swift run/swift build dev flows).
if [ -f "Scripts/sre_kubectl_mcp.py" ]; then
  cp "Scripts/sre_kubectl_mcp.py" "$APP_DIR/Contents/Resources/sre_kubectl_mcp.py"
fi

# The Straw Hat crew's read-only stores MCP tools (phase 2.5) - resolved by
# StrawHatCrew.resolveStoresScript() the same three ways, bundle Resources
# first.
if [ -f "Scripts/luffy_stores_mcp.py" ]; then
  cp "Scripts/luffy_stores_mcp.py" "$APP_DIR/Contents/Resources/luffy_stores_mcp.py"
fi

# The Whiteboard destination's vendored Excalidraw bundle (WhiteboardAssets.swift
# looks for it under Contents/Resources first, falling back to the source tree
# for the swift run/swift build dev flow - the same three-step resolution
# sre_kubectl_mcp.py already uses). Copied wholesale: the page loads index.html
# with read access scoped to this directory, and its fonts/ subtree is fetched
# from it at runtime.
if [ -d "Vendor/Excalidraw/web" ]; then
  cp -R "Vendor/Excalidraw/web" "$APP_DIR/Contents/Resources/ExcalidrawWeb"
else
  echo "⚠️  No Vendor/Excalidraw/web - the Whiteboard destination will show its"
  echo "    \"no bundle\" empty state. Run Scripts/build-excalidraw-web.sh to build it."
fi

# The Code Preview destination's vendored Monaco bundle - same three-step
# resolution (CodePreviewAssets.swift), same reason, same copy-wholesale rule:
# the page loads index.html with read access scoped to this directory.
if [ -d "Vendor/Monaco/web" ]; then
  cp -R "Vendor/Monaco/web" "$APP_DIR/Contents/Resources/MonacoWeb"
else
  echo "⚠️  No Vendor/Monaco/web - the Code Preview destination will show its"
  echo "    \"no bundle\" empty state. Run Scripts/build-monaco-web.sh to build it."
fi

# R2: `appintentsmetadataprocessor` writes semantically-identical JSON in a
# different order on every run - array order in `extract.actionsdata`, and
# object-key order in the `version.json` beside it. Those files are sealed into
# `_CodeSignature/CodeResources`, which is hashed into the CodeDirectory, so the
# bundle's CDHash moved on every build even when nothing had changed. A classic
# file-keychain ACL binds to the CDHash, which is why the captain got a Keychain
# password dialog on every launch after every rebuild. The measurements, and the
# causal experiment that pinned it to this directory, are in the scout report at
# `data/grandline-launch-permission-prompts-investigation/report.md` (firstmate's
# own repo).
#
# The fix is deliberately the conservative one. We do NOT canonicalise these
# files in place: parameter order in a Shortcuts action plausibly matters to the
# App Intents runtime and that was never verified. Instead each newly produced
# file is compared against the previous bundle's copy by deep-sorted canonical
# form - recursively sort object keys and every array - and when the two are
# semantically identical the previous file's exact bytes are kept. What ships is
# then always a file the processor itself produced, and it only changes when its
# content genuinely changed.
#
# Every file in the directory is considered rather than `extract.actionsdata`
# alone, because both files in it drift and a future toolchain may add a third.
# A file with no previous counterpart, or one that is not JSON, is simply left
# as produced.
#
# Best effort, like everything else in this block: no python3 and no previous
# bundle both just leave the new files in place.
stabilize_appintents_metadata() {
  local new_dir="$APP_DIR/Contents/Resources/Metadata.appintents"
  [ -n "$PREVIOUS_APPINTENTS" ] || return 0
  [ -d "$PREVIOUS_APPINTENTS" ] || return 0
  [ -d "$new_dir" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local kept=0 name previous
  for produced in "$new_dir"/*; do
    [ -f "$produced" ] || continue
    name="$(basename "$produced")"
    previous="$PREVIOUS_APPINTENTS/$name"
    [ -f "$previous" ] || continue
    if python3 - "$previous" "$produced" <<'CANON'
import json, sys

def deepsort(value):
    if isinstance(value, dict):
        return {k: deepsort(value[k]) for k in sorted(value)}
    if isinstance(value, list):
        return sorted((deepsort(v) for v in value),
                      key=lambda v: json.dumps(v, sort_keys=True))
    return value

try:
    with open(sys.argv[1], "rb") as f:
        previous = json.load(f)
    with open(sys.argv[2], "rb") as f:
        produced = json.load(f)
except Exception:
    sys.exit(1)

sys.exit(0 if deepsort(previous) == deepsort(produced) else 1)
CANON
    then
      cp "$previous" "$produced"
      kept=$((kept + 1))
    fi
  done

  if [ "$kept" -gt 0 ]; then
    echo "App Intents metadata is unchanged - kept the previous bytes for $kept file(s) (stable CDHash)."
  fi
}

# F21: the metadata bundle, from the const values the release build just
# emitted. Best effort by design - a failure here prints and carries on rather
# than failing the package, since everything else about the app is fine
# without it.
if [ -n "$APPINTENTS_PROCESSOR" ] && [ -x "$APPINTENTS_PROCESSOR" ]; then
  CONST_VALUES="$(find .build -path "*release/GrandLine.build/GrandLine.swiftconstvalues" -print -quit)"
  if [ -n "$CONST_VALUES" ]; then
    find "$PWD/Sources/GrandLine" -name '*.swift' > "$APPINTENTS_WORK/sources.txt"
    printf '%s\n' "$PWD/$CONST_VALUES" > "$APPINTENTS_WORK/constvals.txt"
    if "$APPINTENTS_PROCESSOR" \
        --output "$APP_DIR/Contents/Resources" \
        --toolchain-dir "$(dirname "$(dirname "$APPINTENTS_PROCESSOR")")" \
        --module-name "$EXECUTABLE_NAME" \
        --sdk-root "$(xcrun --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version 2>/dev/null | tail -1 | awk '{print $3}')" \
        --platform-family macOS \
        --deployment-target 13.0 \
        --target-triple "$(uname -m)-apple-macos13.0" \
        --source-file-list "$APPINTENTS_WORK/sources.txt" \
        --swift-const-vals-list "$APPINTENTS_WORK/constvals.txt" \
        --force >/dev/null 2>&1 \
       && [ -d "$APP_DIR/Contents/Resources/Metadata.appintents" ]; then
      echo "App Intents metadata written - Shortcuts/Siri actions will register."
      stabilize_appintents_metadata
    else
      echo "⚠️  appintentsmetadataprocessor did not produce Metadata.appintents."
      echo "    The app is fine; it just has no Shortcuts/Siri actions this build."
    fi
  else
    echo "⚠️  No .swiftconstvalues from the release build - skipping App Intents metadata."
  fi
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Grand Line</string>
    <key>CFBundleDisplayName</key>
    <string>Grand Line</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <!-- GL-05: Launch Services activates the running copy instead of starting
         a second process. Two instances share one set of JSON stores (all
         last-writer-wins) and one Shift git working tree, so the second one
         silently discards the first's saves. SingleInstanceGuard covers the
         paths that bypass Launch Services (open -n, an unbundled binary). -->
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Dictation uses your microphone to capture speech while you hold Right Option, so it can transcribe and paste it at your cursor.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Dictation uses Speech Recognition (on-device when available) to turn what you say into text.</string>
    <!-- F20: the daily review reads today's events to show them on Fleet.
         Read-only - DailyReviewCalendar.swift is the only file that imports
         EventKit and it never saves, removes or commits anything. Both keys
         are present because macOS 14 introduced the full-access spelling and
         an older system still reads the original. -->
    <key>NSCalendarsUsageDescription</key>
    <string>Grand Line shows today’s events in your daily review on Fleet. It only reads them - it never adds, edits or deletes anything in your calendar.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Grand Line shows today’s events in your daily review on Fleet. It only reads them - it never adds, edits or deletes anything in your calendar.</string>
</dict>
</plist>
PLIST

if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
  echo "Signing with local identity \"$SIGNING_IDENTITY\"…"
  codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
else
  echo "⚠️  No \"$SIGNING_IDENTITY\" codesigning identity found - building unsigned."
  echo "    Saved Keychain items (SSH keys/passphrases) may stop being readable"
  echo "    after a future rebuild, since an unsigned/ad-hoc binary gets a new"
  echo "    code identity on every rebuild. See native/README.md's"
  echo "    \"Local signing setup\" section to create this identity once per machine."
fi

# Install/update the copy in /Applications so the app behaves like a normal
# installed app - every rebuild keeps /Applications in sync automatically,
# with no separate manual install step. /Applications is normally writable by
# the admin user with no sudo needed on a single-user Mac, so this never
# prompts; if it can't write there (e.g. permissions, /Applications missing),
# warn and continue rather than failing the whole build - the dist/ build
# above must still succeed either way.
#
# Replacing the bundle at /Applications/$APP_NAME while a stale copy of the
# app is still running is safe on macOS: the running process keeps its own
# open file handles to the old bundle's files, so this doesn't disturb it -
# the replacement just means the *next* launch picks up the new build.
#
# P8 (2026-09-25 review): "there is no release cadence and no rollback". This
# step used to `rm -rf` the installed copy and then `ditto` the new one, which
# means that between those two commands there is no copy of this app on the
# machine at all, and afterwards there is no previous build to go back to.
#
# With 4-24 commits a day landing in /Applications the next time somebody runs
# this script, "roll back" meant remembering a good commit, checking it out and
# waiting for a full release build - and the captain only finds out a build is
# bad by using it, which is after the old one is gone.
#
# So the old copy is renamed aside rather than deleted, and exactly one
# generation is kept. The rename is on the same volume, so it is a directory
# entry change rather than a copy: it costs nothing and is atomic, which also
# closes the window where neither copy existed. If the `ditto` then fails, the
# previous copy is put straight back - the failure path is now "nothing
# changed" instead of "the app is gone".
#
# One generation on purpose. Two would be a retention policy to maintain and a
# second multi-hundred-megabyte bundle on the disk, and the thing this is
# actually for is the build that was fine an hour ago.
#
# **The `.bak` suffix is load-bearing, not decoration.** Every build of this app
# declares the same `com.manjesh.grandline.native` bundle identifier - that is
# the whole reason for this repo's "never launch a built copy from a worktree"
# rule - so a second *launchable* `.app` beside it in /Applications gives
# Launch Services two registrations for one identity, and which one `open -a`
# or a Dock item resolves to is then its business rather than the captain's. A
# directory whose name does not end in `.app` is not an app bundle, so it is
# never registered and never launched by accident. Rolling back is the rename
# back, which is also how it becomes launchable again.
INSTALLED_APP="/Applications/$APP_NAME"
PREVIOUS_APP="/Applications/${APP_NAME%.app} (previous).app.bak"
INSTALL_OK=1
KEPT_PREVIOUS=0
if [ -d "/Applications" ] && [ -w "/Applications" ]; then
  if [ -d "$INSTALLED_APP" ]; then
    # Drop the generation before last, then rename the current one aside.
    rm -rf "$PREVIOUS_APP" 2>/dev/null || true
    if mv "$INSTALLED_APP" "$PREVIOUS_APP" 2>/dev/null; then
      KEPT_PREVIOUS=1
    else
      # Could not rename it - fall back to the old behaviour rather than
      # refusing to install, but say so.
      echo "⚠️  Could not keep a previous copy at $PREVIOUS_APP - replacing in place."
      rm -rf "$INSTALLED_APP" 2>/dev/null || true
    fi
  fi
  if ditto "$APP_DIR" "$INSTALLED_APP" 2>/dev/null; then
    INSTALL_OK=1
  else
    INSTALL_OK=0
    # Put the previous copy back: a failed install must not leave the machine
    # with no app at all.
    if [ "$KEPT_PREVIOUS" -eq 1 ]; then
      rm -rf "$INSTALLED_APP" 2>/dev/null || true
      if mv "$PREVIOUS_APP" "$INSTALLED_APP" 2>/dev/null; then
        KEPT_PREVIOUS=0
        echo "⚠️  Install failed - the previous copy was restored to $INSTALLED_APP."
      fi
    fi
  fi
else
  INSTALL_OK=0
fi

if [ "$INSTALL_OK" -ne 1 ]; then
  echo "⚠️  Could not install to /Applications/$APP_NAME - leaving it unchanged."
  echo "    The build in $DIST_DIR/$APP_NAME is unaffected."
fi

echo ""
echo "✓ Built: $(cd "$DIST_DIR" && pwd)/$APP_NAME"
if [ "$INSTALL_OK" -eq 1 ]; then
  echo "✓ Installed: $INSTALLED_APP"
fi
if [ "$KEPT_PREVIOUS" -eq 1 ]; then
  echo "✓ Previous build kept: $PREVIOUS_APP"
  echo "    To roll back, with the app quit:"
  echo "      rm -rf \"$INSTALLED_APP\" && mv \"$PREVIOUS_APP\" \"$INSTALLED_APP\""
fi
echo "  Open with:  open $APP_DIR"
