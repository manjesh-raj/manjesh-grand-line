#!/usr/bin/env bash
# Render the widget extension's SwiftUI views off-screen, to PNG.
#
# This is F23's answer to "assert what is painted, not what was computed".
# A widget is not an `NSView`, so this repo's usual `cacheDisplay` probe has
# nothing to render, and the real widget host will not load the extension
# until the App Group entitlement has a Team ID behind it - so `ImageRenderer`
# over the same views the extension registers is the only real render
# available. It is not a preview: the output is PNG, at both families' real
# point sizes, in both registers, which an agent can read back with `Read`.
#
# It found a real defect on its first run (see Widgets/Preview/main.swift).
#
# Usage:
#   Scripts/render-widget-previews.sh [output-directory]
#
# With no argument the PNGs go under .build/widget-previews/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-.build/widget-previews}"
BIN=".build/widget-previews/render-probe"
SDK="$(xcrun --show-sdk-path)"
[ -d "$SDK" ] || { echo "no macOS SDK found (xcrun --show-sdk-path)" >&2; exit 1; }

mkdir -p "$OUT" "$(dirname "$BIN")"

# Deliberately the same source list as build-widget-extension.sh, minus the
# `@main` bundle (this probe supplies its own entry point) - so what is
# rendered is the extension's real views and not a copy.
xcrun swiftc \
  -target "$(uname -m)-apple-macos14.0" \
  -sdk "$SDK" \
  -warnings-as-errors \
  -O \
  -o "$BIN" \
  Sources/GrandLine/WidgetSharedContract.swift \
  Widgets/GrandLineWidgets/WidgetPalette.swift \
  Widgets/GrandLineWidgets/WidgetChrome.swift \
  Widgets/GrandLineWidgets/CompleteTaskIntent.swift \
  Widgets/GrandLineWidgets/TasksDueWidget.swift \
  Widgets/GrandLineWidgets/StickyNoteWidget.swift \
  Widgets/Preview/main.swift

echo "Rendering into $OUT …"
"$BIN" "$OUT"
echo "✓ Read the PNGs above to check the layout."
