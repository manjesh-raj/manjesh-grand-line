#!/usr/bin/env bash
# Build a disposable, separately-identified copy of this app for measuring the
# things a headless self-test provably cannot see.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# This repo's hard rule is: never launch a built copy of the app from an agent
# worktree (see native/README.md and AGENTS.md). The reason is bundle identity,
# not the build - every copy declares `com.firstmate.cockpit.native`, and
# `LSMultipleInstancesProhibited` plus `SingleInstanceGuard` are both keyed to
# it. Launching one therefore *activates or disturbs the captain's own running
# instance* rather than starting something separate, and the two would share
# one set of JSON stores and one Shift git working tree.
#
# That rule leaves a real measurement gap, which the full-app audit's §7
# enumerates: the *visible* half of WKWebView gating (a terminal-launched suite
# is never composited, so its pages report `hidden` even when shown), real
# SwiftTerm glyph rendering, popover/HUD behaviour, and Energy Impact. None of
# it is reachable from `run-all-tests.sh`.
#
# The Whiteboard task solved this once, by hand, and the recipe worked: give
# the copy its own bundle id, its own instance lock, and its own scratch stores.
# This script is that recipe checked in, so the next person does not have to
# re-derive it - or worse, re-derive it *incorrectly* and take the captain's
# session down.
#
# ---------------------------------------------------------------------------
# WHAT MAKES IT SAFE (all three are load-bearing - do not drop one)
# ---------------------------------------------------------------------------
#   1. A different CFBundleIdentifier. This is the whole reason the copy can
#      run at all: Launch Services and SingleInstanceGuard's own
#      NSRunningApplication check are both keyed to it, so a different id means
#      a genuinely separate process rather than an activation of the captain's.
#   2. A different FM_INSTANCE_LOCK_FILE. SingleInstanceGuard's third layer is
#      an advisory flock on a fixed path, which is id-independent - without
#      this, the probe and the real app contend for one lock.
#   3. Every FM_* store override pointed at a scratch directory. Otherwise the
#      probe reads and writes the captain's real hosts, keys, tasks and - via
#      ShiftGitSync - a real clone of their private config repo.
#
# `LSUIElement` is also forced true so the probe never takes over the Dock icon
# or the menu bar from the real app.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   ./Scripts/build-probe-app.sh              # build only, print how to launch
#   ./Scripts/build-probe-app.sh --launch     # build and `open` it
#   ./Scripts/build-probe-app.sh --clean      # remove the probe bundle + scratch
#
# Building is always safe. **Launching is a deliberate act**: do it only when
# the measurement genuinely needs a composited window, and prefer asking the
# captain to run it over doing it unattended - the safety above protects their
# *data* and *process*, not their attention.
#
# The probe is a debug build on purpose, so `FM_RUN_*` suites and every
# `debug*` hook are present for a probe to drive.
set -euo pipefail
cd "$(dirname "$0")/.."

PROBE_BUNDLE_ID="com.firstmate.cockpit.native.probe"
APP_NAME="Grand Line Probe.app"
DIST_DIR="../dist"
APP_DIR="$DIST_DIR/$APP_NAME"
EXECUTABLE_NAME="FirstmateCockpit"
SCRATCH="${FM_PROBE_SCRATCH:-${TMPDIR:-/tmp}/grand-line-probe}"

LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    --launch) LAUNCH=1 ;;
    --clean)
      rm -rf "$APP_DIR" "$SCRATCH"
      echo "removed $APP_DIR and $SCRATCH"
      exit 0 ;;
    -h|--help) sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
  esac
done

# A guard, not a courtesy: if this ever produced the real bundle id it would
# be the exact hazard the file exists to prevent.
if [ "$PROBE_BUNDLE_ID" = "com.firstmate.cockpit.native" ]; then
  echo "error: the probe must not share the real app's bundle identifier." >&2
  exit 1
fi

echo "==> swift build (debug - the probe wants the FM_RUN_* suites and debug* hooks)"
swift build
BIN=".build/debug/$EXECUTABLE_NAME"
[ -x "$BIN" ] || { echo "error: $BIN not found after build" >&2; exit 1; }

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

# The two vendored web bundles, so the WKWebView-hosted destinations - the very
# thing a probe most often needs to measure - actually load.
[ -d "Vendor/Excalidraw/web" ] && cp -R "Vendor/Excalidraw/web" "$APP_DIR/Contents/Resources/ExcalidrawWeb"
[ -d "Vendor/Monaco/web" ] && cp -R "Vendor/Monaco/web" "$APP_DIR/Contents/Resources/MonacoWeb"
[ -f "Scripts/sre_kubectl_mcp.py" ] && cp "Scripts/sre_kubectl_mcp.py" "$APP_DIR/Contents/Resources/sre_kubectl_mcp.py"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Grand Line Probe</string>
    <key>CFBundleDisplayName</key>
    <string>Grand Line Probe</string>
    <key>CFBundleIdentifier</key>
    <string>$PROBE_BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0</string>
    <key>CFBundleVersion</key>
    <string>probe</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Deliberately an agent (no Dock icon, no menu bar): a probe must never
         take the foreground away from the captain's real instance. -->
    <key>LSUIElement</key>
    <true/>
    <!-- Deliberately NOT prohibited: the probe is meant to coexist with the
         real app. The bundle id above is what keeps them separate. -->
    <key>LSMultipleInstancesProhibited</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Probe build. Dictation uses your microphone while you hold the dictation shortcut.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Probe build. Dictation uses Speech Recognition to turn speech into text.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. A probe needs no stable identity - unlike the real app,
# whose Keychain-backed SSH keys depend on one (see build_native_app.sh's
# "Local signing" note) - and an unsigned bundle is refused outright by
# recent macOS on Apple silicon.
codesign --force --sign - --identifier "$PROBE_BUNDLE_ID" "$APP_DIR" >/dev/null 2>&1 \
  && echo "==> ad-hoc signed" \
  || echo "⚠️  ad-hoc signing failed - the probe may refuse to launch"

mkdir -p "$SCRATCH"

# Every FM_* location override, in one place, so a launch cannot reach real
# data through a store somebody forgot. Keep this in sync with the README's
# env-var index; a store missing here falls back to the captain's real one.
ENV_ARGS=(
  --env "FM_INSTANCE_LOCK_FILE=$SCRATCH/instance.lock"
  --env "FM_HOSTS_FILE=$SCRATCH/hosts.json"
  --env "FM_KEYS_FILE=$SCRATCH/keys.json"
  --env "FM_SNIPPETS_FILE=$SCRATCH/snippets.json"
  --env "FM_SCHEDULES_FILE=$SCRATCH/schedules.json"
  --env "FM_SCHEDULE_HISTORY_DIR=$SCRATCH/schedule-history"
  --env "FM_SHIFT_DIR=$SCRATCH/tasks"
  --env "FM_DICTATION_DIR=$SCRATCH/dictation"
  --env "FM_DOCS_DIR=$SCRATCH/docs"
  --env "FM_DOCS_RUNBOOKS_DIR=$SCRATCH/runbooks"
  --env "FM_COMMAND_LIBRARY_DIR=$SCRATCH/commands"
  --env "FM_LOG_ANALYZER_DIR=$SCRATCH/investigations"
  --env "FM_FLEET_LOG_DIR=$SCRATCH/fleet-log"
  --env "FM_INCIDENTS_DIR=$SCRATCH/incidents"
  --env "FM_STICKY_BOARD_DIR=$SCRATCH/sticky-board"
  --env "FM_CODE_PREVIEW_DIR=$SCRATCH/code-snippets"
  --env "FM_WHISPER_MODEL_DIR=$SCRATCH/whisper"
)

echo ""
echo "Probe built: $APP_DIR"
echo "  bundle id: $PROBE_BUNDLE_ID   (real app: com.firstmate.cockpit.native)"
echo "  scratch:   $SCRATCH"

if [ "$LAUNCH" -eq 1 ]; then
  echo "==> launching"
  open -n "$APP_DIR" "${ENV_ARGS[@]}"
  echo "Launched. Quit it with:  osascript -e 'quit app id \"$PROBE_BUNDLE_ID\"'"
else
  echo ""
  echo "Not launched. To launch it deliberately:"
  echo "  ./Scripts/build-probe-app.sh --launch"
  echo "Then quit with:"
  echo "  osascript -e 'quit app id \"$PROBE_BUNDLE_ID\"'"
fi
