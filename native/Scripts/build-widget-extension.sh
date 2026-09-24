#!/usr/bin/env bash
# Build GrandLineWidgets.appex - F23's WidgetKit extension.
#
# SwiftPM has no bundle-product target, so this project's one app bundle is
# already assembled by hand (`native/build_native_app.sh` writes the
# Info.plist, copies the binary and codesigns). An `.appex` is the same job
# with three differences, all of them here:
#
#   * it links with `-e _NSExtensionMain` and compiles `-application-extension`
#     `-parse-as-library`, so the host loads it as an extension rather than
#     looking for a `main`;
#   * its Info.plist carries `NSExtension` / `NSExtensionPointIdentifier`
#     `com.apple.widgetkit-extension`;
#   * it is signed **with entitlements**, and that is the step this
#     environment cannot complete - see "Signing" below and
#     native/Widgets/README.md.
#
# The extension compiles the shared contract file straight out of the app's
# own sources (`SHARED_SOURCES` below) rather than duplicating it. That file
# imports nothing but Foundation precisely so this works.
#
# Usage:
#   Scripts/build-widget-extension.sh              # build + sign into .build/
#   Scripts/build-widget-extension.sh --embed      # also embed into dist/<app>
#   Scripts/build-widget-extension.sh --check      # compile only, no bundle
set -euo pipefail
cd "$(dirname "$0")/.."

EXT_NAME="GrandLineWidgets"
APP_BUNDLE_ID="com.manjesh.grandline.native"
EXT_BUNDLE_ID="$APP_BUNDLE_ID.widgets"
SRC_DIR="Widgets/$EXT_NAME"
OUT_DIR=".build/widgets"
APPEX="$OUT_DIR/$EXT_NAME.appex"
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
# Interactive widgets are macOS 14 (Button(intent:) inside a widget). The host
# app stays on 13.0 - only this bundle needs 14.
DEPLOYMENT_TARGET="14.0"

EMBED=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --embed) EMBED=1 ;;
    --check) CHECK_ONLY=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# The shared app/extension contract. One file, deliberately - see its header.
SHARED_SOURCES=(
  "Sources/GrandLine/WidgetSharedContract.swift"
)
EXT_SOURCES=(
  "$SRC_DIR/WidgetPalette.swift"
  "$SRC_DIR/WidgetChrome.swift"
  "$SRC_DIR/CompleteTaskIntent.swift"
  "$SRC_DIR/TasksDueWidget.swift"
  "$SRC_DIR/StickyNoteWidget.swift"
  "$SRC_DIR/GrandLineWidgetBundle.swift"
)

for file in "${SHARED_SOURCES[@]}" "${EXT_SOURCES[@]}"; do
  [ -f "$file" ] || { echo "missing source: $file" >&2; exit 1; }
done

SDK="$(xcrun --show-sdk-path)"
[ -d "$SDK" ] || { echo "no macOS SDK found (xcrun --show-sdk-path)" >&2; exit 1; }

# GL-18: the version comes from `git describe`, never a constant - same
# derivation as build_native_app.sh, so the app and its extension can never
# report different versions.
GIT_DESCRIBE="$(git describe --tags --dirty --always 2>/dev/null || true)"
[ -n "$GIT_DESCRIBE" ] || GIT_DESCRIBE="0.0.0-unknown"
SHORT_VERSION="$(printf '%s' "${GIT_DESCRIBE#v}" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')"
[ -n "$SHORT_VERSION" ] || SHORT_VERSION="0.0.0"
BUILD_VERSION="${GIT_DESCRIBE#v}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "Compiling $EXT_NAME (macOS $DEPLOYMENT_TARGET, $(uname -m))…"
BIN="$OUT_DIR/$EXT_NAME"
# -warnings-as-errors mirrors GL-07: CI fails the app's build on any warning
# in this app's own sources, and this bundle is this app's own sources.
xcrun swiftc \
  -target "$(uname -m)-apple-macos$DEPLOYMENT_TARGET" \
  -sdk "$SDK" \
  -application-extension \
  -parse-as-library \
  -warnings-as-errors \
  -O \
  -o "$BIN" \
  "${SHARED_SOURCES[@]}" "${EXT_SOURCES[@]}" \
  -Xlinker -e -Xlinker _NSExtensionMain

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "✓ Compiled and linked: $BIN (--check, no bundle assembled)"
  exit 0
fi

mkdir -p "$APPEX/Contents/MacOS"
mv "$BIN" "$APPEX/Contents/MacOS/$EXT_NAME"

sed -e "s|__BUNDLE_ID__|$EXT_BUNDLE_ID|" \
    -e "s|__SHORT_VERSION__|$SHORT_VERSION|" \
    -e "s|__BUILD_VERSION__|$BUILD_VERSION|" \
    "$SRC_DIR/Info.plist" > "$APPEX/Contents/Info.plist"

# ---------------------------------------------------------------------------
# Signing
#
# This is the step the report's own F23 entry calls "blocked on the Developer
# ID item", and it is worth being exact about what is and is not blocked.
#
# What works with the local self-signed identity: the bundle signs, and its
# entitlements are *attached*. What does not: an App Group entitlement is only
# honoured when its identifier is prefixed by a real Team ID and the binary is
# signed by that team. `codesign -dv` on this app reports
# `TeamIdentifier=not set`, so the sandbox this extension runs in will refuse
# to resolve the group container - which means the widget loads, renders, and
# reports "Not available", because it genuinely cannot read the snapshot.
#
# So the script signs anyway (a bundle has to be signed to be loadable at all)
# and says plainly which of the two it just did.
# ---------------------------------------------------------------------------
TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]\{10\}\))".*/\1/p' | head -1)"

if [ -n "$TEAM_ID" ]; then
  echo "Signing with Developer ID (team $TEAM_ID) and the App Group entitlement…"
  ENTITLEMENTS="$OUT_DIR/entitlements.plist"
  sed "s|group\.$APP_BUNDLE_ID|$TEAM_ID.group.$APP_BUNDLE_ID|" \
    "$SRC_DIR/$EXT_NAME.entitlements" > "$ENTITLEMENTS"
  codesign --force --sign "Developer ID Application" --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$EXT_BUNDLE_ID" "$APPEX"
  echo "  NOTE: GrandLineWidgetContainer.appGroupIdentifier must be"
  echo "        \"$TEAM_ID.group.$APP_BUNDLE_ID\" for the app and the"
  echo "        extension to agree. WidgetSnapshotSelfTest asserts it."
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
  echo "Signing with the local identity \"$SIGNING_IDENTITY\"…"
  codesign --force --sign "$SIGNING_IDENTITY" \
    --entitlements "$SRC_DIR/$EXT_NAME.entitlements" \
    --identifier "$EXT_BUNDLE_ID" "$APPEX"
  echo ""
  echo "⚠️  No Developer ID identity on this machine, so this bundle has no Team ID."
  echo "    The extension is built and signed, and it will NOT read the app's data:"
  echo "    an App Group entitlement needs a Team-ID-prefixed identifier and a"
  echo "    team-signed binary. Both widgets will render their \"Not available\""
  echo "    state, which is the honest one. See native/Widgets/README.md."
else
  echo "⚠️  No codesigning identity at all - signing ad-hoc. The widget host will"
  echo "    almost certainly refuse to load this. See native/Widgets/README.md."
  codesign --force --sign - --entitlements "$SRC_DIR/$EXT_NAME.entitlements" "$APPEX"
fi

echo "✓ Built: $(cd "$OUT_DIR" && pwd)/$EXT_NAME.appex"

if [ "$EMBED" -eq 1 ]; then
  APP_DIR="../dist/Grand Line.app"
  if [ ! -d "$APP_DIR" ]; then
    echo "⚠️  $APP_DIR does not exist - run build_native_app.sh first. Nothing embedded."
    exit 0
  fi
  mkdir -p "$APP_DIR/Contents/PlugIns"
  rm -rf "$APP_DIR/Contents/PlugIns/$EXT_NAME.appex"
  ditto "$APPEX" "$APP_DIR/Contents/PlugIns/$EXT_NAME.appex"
  # Re-sign the app: embedding a bundle invalidates the outer signature's
  # sealed resources.
  if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    codesign --force --sign "$SIGNING_IDENTITY" --identifier "$APP_BUNDLE_ID" "$APP_DIR"
  fi
  echo "✓ Embedded into $APP_DIR/Contents/PlugIns/$EXT_NAME.appex"
fi
