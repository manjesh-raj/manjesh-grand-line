#!/usr/bin/env bash
# Regenerate native/Vendor/ScheduleX/web/ - the self-contained, offline
# Schedule-X bundle the Tasks page's Calendar view loads.
#
# Run this by hand after changing native/Vendor/ScheduleX/src/*, or after
# bumping a pinned version in src/package.json. It is NOT part of `swift build`
# and never runs at app launch: the output is committed, exactly like the
# Monaco and Excalidraw bundles (native/Scripts/build-monaco-web.sh is the
# model, and this script follows it step for step).
#
# Needs node/npm and network access - the one and only time either is needed.
# The app itself never touches node or the network for this feature.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Vendor/ScheduleX/src"
OUT="Vendor/ScheduleX/web"
WORK="$(mktemp -d /tmp/grandline-schedule-x-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# `--check` rebuilds into a scratch directory and diffs it against the
# committed bundle instead of replacing it. Reproducible because the install is
# `npm ci` against the committed lockfile. Not wired into CI's `generated` job,
# for the reason build-monaco-web.sh gives (a node install per pull request for
# a bundle that changes a few times a year).
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    *) echo "unknown argument: $arg (--check is the only one)" >&2; exit 2 ;;
  esac
done

command -v npm >/dev/null || { echo "npm is required (build-time only)"; exit 1; }

echo "Installing pinned deps into $WORK …"
cp "$SRC/package.json" "$WORK/package.json"
cp "$SRC/package-lock.json" "$WORK/package-lock.json"
(cd "$WORK" && npm ci --silent --no-audit --no-fund)

# Every package that ends up in the bundle must be free and open source. The
# paid Schedule-X plugins live under the `@sx-premium` scope; refusing the
# scope outright means a later edit to package.json cannot pull one in by
# accident, and refusing any licence outside the short allow-list below means
# a transitive dependency cannot either.
node - "$WORK/package-lock.json" <<'NODE'
const lock = require(process.argv[2])
const allowed = new Set(['MIT', 'ISC', 'BSD-2-Clause', 'BSD-3-Clause', 'Apache-2.0', '0BSD'])
let bad = []
for (const [path, pkg] of Object.entries(lock.packages)) {
  if (!path) continue
  if (path.includes('@sx-premium/')) bad.push(`${path}: a paid Schedule-X package`)
  if (pkg.dev) continue
  if (!allowed.has(pkg.license)) bad.push(`${path}: licence ${pkg.license}`)
}
if (bad.length) {
  console.error('Refusing to bundle:\n  ' + bad.join('\n  '))
  process.exit(1)
}
NODE

VERSION="$(node -p "require('$WORK/node_modules/@schedule-x/calendar/package.json').version")"
DND_VERSION="$(node -p "require('$WORK/node_modules/@schedule-x/drag-and-drop/package.json').version")"
echo "Bundling @schedule-x/calendar $VERSION (+ drag-and-drop $DND_VERSION) …"

cp "$SRC/task-calendar.js" "$WORK/task-calendar.js"
cp "$SRC/task-calendar.css" "$WORK/task-calendar.css"

# One classic IIFE script and one stylesheet, everything inlined - see
# src/index.html for why a module graph is avoided on a file:// origin.
(cd "$WORK" && ./node_modules/.bin/esbuild task-calendar.js \
  --bundle \
  --format=iife \
  --minify \
  --target=safari16 \
  --legal-comments=none \
  '--define:process.env.NODE_ENV="production"' \
  --loader:.svg=dataurl \
  --outfile=out/task-calendar.js \
  --log-level=warning)

if [ "$CHECK_ONLY" -eq 1 ]; then DEST="$WORK/check-out"; else DEST="$OUT"; fi
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$WORK/out/task-calendar.js" "$DEST/task-calendar.js"
cp "$WORK/out/task-calendar.css" "$DEST/task-calendar.css"
cp "$SRC/index.html" "$DEST/index.html"

# The licence notices ship inside the bundle, and so inside the .app: the MIT
# licence asks for its notice in every copy, and a minified bundle built with
# `--legal-comments=none` carries none of its own. One file, generated from
# the installed packages themselves rather than typed by hand, so a version
# bump that changes a copyright line changes this file too.
node - "$WORK" "$DEST/THIRD-PARTY-LICENSES.txt" <<'NODE'
const fs = require('fs')
const path = require('path')
const [work, outFile] = process.argv.slice(2)
const lock = require(path.join(work, 'package-lock.json'))
const names = Object.keys(lock.packages)
  .filter((p) => p && !lock.packages[p].dev)
  .sort()
let text = 'Third-party software in this bundle (native/Scripts/build-schedule-x-web.sh).\n'
for (const p of names) {
  const dir = path.join(work, p)
  const pkg = require(path.join(dir, 'package.json'))
  const file = fs.readdirSync(dir).find((f) => /^licen[cs]e/i.test(f))
  if (!file) {
    console.error(`no licence file in ${p}`)
    process.exit(1)
  }
  text += `\n================================================================\n`
  text += `${pkg.name} ${pkg.version} (${pkg.license})\n`
  text += `================================================================\n\n`
  text += fs.readFileSync(path.join(dir, file), 'utf8').trim() + '\n'
}
fs.writeFileSync(outFile, text)
NODE

cat > "$DEST/BUILD-INFO.txt" <<INFO
Generated by native/Scripts/build-schedule-x-web.sh - do not edit by hand.
@schedule-x/calendar $VERSION
@schedule-x/drag-and-drop $DND_VERSION (the last MIT release; v4 made it paid)
esbuild $(cd "$WORK" && ./node_modules/.bin/esbuild --version)
Views: month-grid, week, day, list (Agenda). Plugins: calendar-controls,
current-time, scroll-controller, drag-and-drop. No @sx-premium package is
installed or bundled.
web/ fetches nothing: the script, the stylesheet (with the default theme's
icons inlined as data: URIs) and the page are the whole bundle.
INFO

# A SHA-256 of every shipped file. Nothing in CI rebuilds this bundle, so a
# hand edit to the committed JavaScript would ship unnoticed;
# ShiftCalendarSelfTest recomputes every digest below and fails on any
# difference, and on a file in web/ that is not listed.
{
  echo "SHA-256 of every shipped file, asserted by ShiftCalendarSelfTest:"
  (cd "$DEST" && find . -type f ! -name BUILD-INFO.txt | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
    printf 'sha256 %s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
  done)
} >> "$DEST/BUILD-INFO.txt"

if [ "$CHECK_ONLY" -eq 1 ]; then
  if diff -r "$OUT" "$DEST" >/dev/null 2>&1; then
    echo ""
    echo "✓ $OUT matches a rebuild from $SRC"
    exit 0
  fi
  echo ""
  echo "✗ $OUT does NOT match a rebuild from $SRC:" >&2
  diff -rq "$OUT" "$DEST" >&2
  echo "" >&2
  echo "  Run this script without --check and commit the result." >&2
  exit 1
fi

echo ""
echo "✓ Wrote $OUT"
du -sh "$OUT" "$OUT/task-calendar.js" "$OUT/task-calendar.css"
