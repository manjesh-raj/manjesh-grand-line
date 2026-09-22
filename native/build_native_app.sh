#!/usr/bin/env bash
# Build Manjesh Grand Line.app: a plain macOS app-bundle wrapper around the
# native Swift cockpit (native/, SwiftTerm-based). No notarization, but the
# bundle is codesigned with a stable local identity when one is available -
# see "Local signing" below and native/README.md's "Local signing setup" section.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Manjesh Grand Line.app"
DIST_DIR="../dist"
APP_DIR="$DIST_DIR/$APP_NAME"
EXECUTABLE_NAME="FirstmateCockpit"
BUNDLE_ID="com.firstmate.cockpit.native"
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
SIGNING_IDENTITY="Firstmate Cockpit Local Dev"

# ---------------------------------------------------------------------------
# F21 (App Intents / Shortcuts).
#
# The five `AppIntent` types in Sources/FirstmateCockpit/GrandLineAppIntents.swift
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
SWIFT_BUILD_EXTRA=()
if [ -n "$APPINTENTS_PROCESSOR" ] && [ -x "$APPINTENTS_PROCESSOR" ]; then
  cat > "$APPINTENTS_WORK/protocols.json" <<'PROTOCOLS'
["AppEntity","AppEnum","AppIntent","AppShortcutsProvider","DynamicOptionsProvider","EntityIdentifierConvertible","EntityPropertyQuery","EntityQuery","EntityStringQuery","IndexedEntity","PersistentAppEntity","TransientAppEntity","URLRepresentableEntity","URLRepresentableEnum","URLRepresentableIntent"]
PROTOCOLS
  # Each -Xfrontend forwards exactly one following argument, which is why the
  # flag and its value each need their own pair. Getting this wrong makes
  # SwiftPM treat the JSON as an input source file, with a confusing
  # "unexpected input file" error.
  SWIFT_BUILD_EXTRA=(-Xswiftc -emit-const-values
                     -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
                     -Xswiftc -Xfrontend -Xswiftc "$APPINTENTS_WORK/protocols.json")
else
  echo "⚠️  No appintentsmetadataprocessor (it ships with Xcode, not Command Line Tools)."
  echo "    The app will build and run normally, but its five Shortcuts/Siri actions"
  echo "    will not be registered with the system. Settings → Shortcuts & Siri says so."
fi

echo "Building $EXECUTABLE_NAME (release) - version $VERSION (build $BUILD_VERSION)…"
swift build -c release "${SWIFT_BUILD_EXTRA[@]}"

BIN="./.build/release/$EXECUTABLE_NAME"
[ -x "$BIN" ] || { echo "build did not produce $BIN"; exit 1; }

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

# F21: the metadata bundle, from the const values the release build just
# emitted. Best effort by design - a failure here prints and carries on rather
# than failing the package, since everything else about the app is fine
# without it.
if [ -n "$APPINTENTS_PROCESSOR" ] && [ -x "$APPINTENTS_PROCESSOR" ]; then
  CONST_VALUES="$(find .build -path "*release/FirstmateCockpit.build/FirstmateCockpit.swiftconstvalues" -print -quit)"
  if [ -n "$CONST_VALUES" ]; then
    find "$PWD/Sources/FirstmateCockpit" -name '*.swift' > "$APPINTENTS_WORK/sources.txt"
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
    <string>Manjesh Grand Line</string>
    <key>CFBundleDisplayName</key>
    <string>Manjesh Grand Line</string>
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
         Read-only - `DailyReviewCalendar.swift` is the only file that imports
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
INSTALLED_APP="/Applications/$APP_NAME"
INSTALL_OK=1
if [ -d "/Applications" ] && [ -w "/Applications" ]; then
  if rm -rf "$INSTALLED_APP" 2>/dev/null && ditto "$APP_DIR" "$INSTALLED_APP" 2>/dev/null; then
    INSTALL_OK=1
  else
    INSTALL_OK=0
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
echo "  Open with:  open $APP_DIR"
