#!/usr/bin/env python3
"""Generate the fifteen card/shortcut icon Swift files from the captain's own
reference images (grandline-rail-icons-batch2).

A second, sibling batch to `build-card-shortcut-icons.py` (which shipped the
first four - `.poneglyph`, `.shift`, `.codePreview`, `.stickyBoard` - plus
`build-straw-hat-flag.py` for `.strawHat`). This one covers the remaining
fifteen destinations that still fell back to `drillHeaderArtwork`'s trailing
`return nil` / a plain SF Symbol:

  console.png     -> `.console`      ("Console")
  health.png      -> `.health`       ("Health")
  schedules.png   -> `.schedules`    ("Schedules")
  hosts.png       -> `.hosts`        ("Hosts")
  logAnalyzer.png -> `.logAnalyzer`  ("Log Analyzer")
  kubernetes.png  -> `.kubernetes`   ("Kubernetes")
  docs.png        -> `.docs`        ("Docs")
  runbooks.png    -> `.runbooks`     ("Runbooks")
  postmortems.png -> `.postmortems` ("Postmortems")
  tools.png       -> `.tools`        ("Tools")
  whiteboard.png  -> `.whiteboard`   ("Whiteboard")
  updates.png     -> `.updates`      ("Updates")
  automation.png  -> `.automation`   ("Automation")
  githubSync.png  -> `.githubSync`   ("GitHub Sync")
  settings.png    -> `.settings`     ("Settings")

## Why a second script rather than extending the first

`build-card-shortcut-icons.py`'s own `ICONS` list, `ASSETS_DIR` and behaviour
for its original four icons are left byte-for-byte unchanged - this script is
a plain sibling reading a separate assets directory
(`native/Scripts/assets/grandline-rail-icons-batch2/`) so re-running either
script never touches the other's committed files, and `--check` on the first
script still only verifies its original four.

## Why generated Swift files and not an asset catalog or an SPM resource

Identical reasoning to `build-card-shortcut-icons.py`/`build-straw-hat-flag.py`
(read either docstring for the full version): `.xcassets` needs `actool`,
absent from a Command-Line-Tools-only toolchain this project's plain
`swift build` relies on; an SPM `resources:` bundle's generated
`Bundle.module` accessor `fatalError`s when it cannot resolve its path under
this app's hand-assembled `.app`, and this repo's own `build_native_app.sh`
never copies a `*.bundle` into it. A base64 literal has no path to resolve, so
it behaves identically under `swift run`, a debug binary, and the assembled
`.app`.

## Why the source images are committed here

Same deliberate deviation `build-card-shortcut-icons.py` already made: the
fifteen PNGs are committed under this directory rather than read from
firstmate's `data/` directory outside the repo, so the generator (and the
repo as a whole) is self-contained and reproducible with no dependency on a
path that only exists on one captain's machine.

## Why square-crop with the background kept

Every source image is already a fully opaque, roughly-centred macOS-style
app-icon square with its own background - none carries a transparent border
to crop by - so, exactly like the first batch, the crop is simply "trim the
longer axis evenly to a square", keeping the background rather than guessing
at a "real" edge with no source of truth for where it is.

## Why 128x128

Same reasoning as the first batch: the two tiles that render these are
`HelmGradientTile.Size.module` (30pt, the canvas card) and `.drill` (34pt, the
page header / floating-bar shortcut). 128px is well past any real Mac
display's 2x for either.

Usage:
    python3 native/Scripts/build-rail-icons-batch2.py [--check]

`--check` regenerates into memory and diffs against the committed files, so CI
or a reviewer can confirm every committed file matches its input without
rewriting anything.
"""

import argparse
import base64
import io
import os
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover - a clear message beats a traceback
    sys.exit("This script needs Pillow: python3 -m pip install --user Pillow")

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(HERE, "assets", "grandline-rail-icons-batch2")
SOURCES_DIR = os.path.normpath(os.path.join(HERE, "..", "Sources", "FirstmateCockpit"))

SIDE = 128
# One base64 line per this many characters - a single 40KB line is unreadable
# in a diff and in review. Same value the first batch and `build-straw-hat-
# flag.py` use.
CHUNK = 120


class IconSpec:
    def __init__(self, *, source_name, enum_name, file_name, feature_note, doc_note):
        self.source_name = source_name
        self.enum_name = enum_name
        self.file_name = file_name
        self.feature_note = feature_note
        self.doc_note = doc_note

    @property
    def source_path(self):
        return os.path.join(ASSETS_DIR, self.source_name)

    @property
    def target_path(self):
        return os.path.join(SOURCES_DIR, self.file_name)


ICONS = [
    IconSpec(
        source_name="console.png",
        enum_name="ConsoleIcon",
        file_name="ConsoleIcon.swift",
        feature_note="`.console`",
        doc_note="a terminal-style app icon",
    ),
    IconSpec(
        source_name="health.png",
        enum_name="HealthIcon",
        file_name="HealthIcon.swift",
        feature_note="`.health`",
        doc_note="a health/heartbeat-style app icon",
    ),
    IconSpec(
        source_name="schedules.png",
        enum_name="SchedulesIcon",
        file_name="SchedulesIcon.swift",
        feature_note="`.schedules`",
        doc_note="a calendar/schedule-style app icon",
    ),
    IconSpec(
        source_name="hosts.png",
        enum_name="HostsIcon",
        file_name="HostsIcon.swift",
        feature_note="`.hosts`",
        doc_note="a server/host-style app icon",
    ),
    IconSpec(
        source_name="logAnalyzer.png",
        enum_name="LogAnalyzerIcon",
        file_name="LogAnalyzerIcon.swift",
        feature_note='`.logAnalyzer` (titled "Log Analyzer")',
        doc_note="a log/magnifying-glass-style app icon",
    ),
    IconSpec(
        source_name="kubernetes.png",
        enum_name="KubernetesIcon",
        file_name="KubernetesIcon.swift",
        feature_note="`.kubernetes`",
        doc_note="a Kubernetes-style app icon",
    ),
    IconSpec(
        source_name="docs.png",
        enum_name="DocsAppIcon",
        file_name="DocsAppIcon.swift",
        feature_note="`.docs`",
        doc_note="a documentation/book-style app icon",
    ),
    IconSpec(
        source_name="runbooks.png",
        enum_name="RunbooksIcon",
        file_name="RunbooksIcon.swift",
        feature_note="`.runbooks`",
        doc_note="a runbook/checklist-style app icon",
    ),
    IconSpec(
        source_name="postmortems.png",
        enum_name="PostmortemsIcon",
        file_name="PostmortemsIcon.swift",
        feature_note="`.postmortems`",
        doc_note="a postmortem/incident-write-up-style app icon",
    ),
    IconSpec(
        source_name="tools.png",
        enum_name="ToolsAppIcon",
        file_name="ToolsAppIcon.swift",
        feature_note="`.tools`",
        doc_note="a toolbox-style app icon",
    ),
    IconSpec(
        source_name="whiteboard.png",
        enum_name="WhiteboardAppIcon",
        file_name="WhiteboardAppIcon.swift",
        feature_note="`.whiteboard`",
        doc_note="a whiteboard/sketch-style app icon",
    ),
    IconSpec(
        source_name="updates.png",
        enum_name="UpdatesIcon",
        file_name="UpdatesIcon.swift",
        feature_note="`.updates`",
        doc_note="an updates/steering-wheel-style app icon",
    ),
    IconSpec(
        source_name="automation.png",
        enum_name="AutomationIcon",
        file_name="AutomationIcon.swift",
        feature_note="`.automation`",
        doc_note="an automation/bolt-style app icon",
    ),
    IconSpec(
        source_name="githubSync.png",
        enum_name="GithubSyncIcon",
        file_name="GithubSyncIcon.swift",
        feature_note='`.githubSync` (titled "GitHub Sync")',
        doc_note="a GitHub-sync-style app icon",
    ),
    IconSpec(
        source_name="settings.png",
        enum_name="SettingsAppIcon",
        file_name="SettingsAppIcon.swift",
        feature_note="`.settings`",
        doc_note="a settings/gear-style app icon",
    ),
]


def render(path):
    """Square-crop (trim the longer axis evenly) and downscale."""
    image = Image.open(path).convert("RGBA")
    width, height = image.size
    side = min(width, height)
    image = image.crop((
        (width - side) // 2,
        (height - side) // 2,
        (width - side) // 2 + side,
        (height - side) // 2 + side,
    ))
    image = image.resize((SIDE, SIDE), Image.LANCZOS)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def swift_source(spec, payload):
    encoded = base64.b64encode(payload).decode("ascii")
    chunks = [encoded[i:i + CHUNK] for i in range(0, len(encoded), CHUNK)]
    lines = [
        "// Manjesh Grand Line - native macOS app.",
        "//",
        "// GENERATED FILE - do not hand-edit. Produced by",
        "// `native/Scripts/build-rail-icons-batch2.py` from the captain's own",
        f"// reference image (`{spec.source_name}`, committed under",
        "// `native/Scripts/assets/grandline-rail-icons-batch2/` - see that",
        "// script's own docstring for why the source lives in this repo rather",
        "// than firstmate's `data/` directory). Re-run that script to change",
        "// the crop or the size; see its own docstring for why this is a",
        "// base64 literal rather than an asset catalog or an SPM resource",
        "// bundle.",
        "//",
        f"// {spec.doc_note}.",
        "//",
        f"// The payload is a {SIDE}x{SIDE} PNG - well past any real Mac display's",
        "// 2x for the tiles that render it",
        "// (`HelmGradientTile.Size.module`/`.drill`, 30pt/34pt).",
        "",
        "import AppKit",
        "",
        f"/// The card icon and floating-bar shortcut artwork for {spec.feature_note}.",
        "///",
        "/// `NSImage(data:)` returns nil on a corrupt payload rather than trapping,",
        "/// and every call site treats nil as \"fall back to the SF Symbol\" - so a",
        "/// bad regeneration degrades to a glyph rather than to a blank tile,",
        "/// exactly as `StrawHatFlag`/`PoneglyphIcon` do.",
        f"enum {spec.enum_name} {{",
        "",
        "    /// The pixel side of the payload below.",
        f"    static let side: CGFloat = {SIDE}",
        "",
        "    /// The decoded icon, or nil if the payload is corrupt.",
        "    ///",
        "    /// **`isTemplate` is explicitly false.** A template image is drawn as a",
        "    /// tintable mask, which would flatten this artwork's own colours into",
        "    /// one solid colour - i.e. it would throw away the entire reason this",
        "    /// is a raster asset instead of an SF Symbol. `NSImage` from PNG data",
        "    /// already defaults to false; this states the decision so a later",
        "    /// \"make it match the other tiles\" edit has to argue with it.",
        "    static var image: NSImage? {",
        "        if let cached { return cached }",
        "        guard let data = Data(base64Encoded: base64Chunks.joined()),",
        "              let image = NSImage(data: data) else {",
        f"            AppLog.ui.error(\"{spec.enum_name}: the icon payload failed to decode\")",
        "            return nil",
        "        }",
        "        image.isTemplate = false",
        "        cached = image",
        "        return image",
        "    }",
        "",
        "    /// Decoded once and kept for the process's life - the canvas rebuilds its",
        "    /// grid on every window resize, and re-decoding a PNG per pass would be",
        "    /// real work for a static asset.",
        "    private static var cached: NSImage?",
        "",
        f"    // {len(payload)} bytes, {len(encoded)} base64 characters.",
        "    private static let base64Chunks: [String] = [",
    ]
    for chunk in chunks:
        lines.append(f'        "{chunk}",')
    lines.append("    ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="diff against the committed files instead of writing")
    args = parser.parse_args()

    any_mismatch = False
    for spec in ICONS:
        if not os.path.exists(spec.source_path):
            sys.exit(f"Reference image not found at {spec.source_path}")

        source = swift_source(spec, render(spec.source_path))

        if args.check:
            if not os.path.exists(spec.target_path):
                sys.exit(f"{spec.target_path} does not exist yet - run without --check first.")
            with open(spec.target_path, "r", encoding="utf-8") as handle:
                committed = handle.read()
            if committed != source:
                print(f"{spec.target_path} is out of date.")
                any_mismatch = True
            else:
                print(f"{spec.target_path} matches its input.")
            continue

        with open(spec.target_path, "w", encoding="utf-8") as handle:
            handle.write(source)
        print(f"Wrote {spec.target_path} ({len(source.encode('utf-8'))} bytes).")

    if args.check and any_mismatch:
        sys.exit(1)


if __name__ == "__main__":
    main()
