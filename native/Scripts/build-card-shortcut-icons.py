#!/usr/bin/env python3
"""Generate the four card/shortcut icon Swift files from the captain's own
reference images (grandline-card-shortcut-icons).

The captain supplied four custom images and asked for each to replace the SF
Symbol placeholder currently used for that feature's home/dashboard card icon
and its floating-bar quick-access ("shortcut") icon:

  - poneglyph.png    -> `.poneglyph` (the personal credential vault - NOT
                        Docs; confirmed by grepping the Swift sources, see
                        `RailDestination.swift`'s own header history)
  - tasks.png        -> `.shift` (titled "Tasks" in this app's UI)
  - code-preview.png -> `.codePreview`
  - sticky-notes.png -> `.stickyBoard`

## Why generated Swift files and not an asset catalog or an SPM resource

Identical reasoning to `build-straw-hat-flag.py`/`build-straw-hat-portraits.py`,
the live precedent in this tree (read either docstring for the full version):

  * `.xcassets` needs `actool`, **absent from a Command-Line-Tools-only
    toolchain** - and this project builds with plain `swift build`, no Xcode.
  * An SPM `resources:` bundle works under `swift build`, but this app's own
    `build_native_app.sh` never copies a `*.bundle` into the assembled `.app`,
    and the generated `Bundle.module` accessor `fatalError`s when it cannot
    resolve its path. A base64 literal has no path to resolve, so it behaves
    identically under `swift run`, a debug binary, and a hand-assembled `.app`.

## Why the source images are committed here (a deliberate deviation)

`StrawHatFlag`/`StrawHatPortraits`' own generators read their source image from
firstmate's `data/` directory, outside this repo, and only commit the derived
payload. This task's own brief asked for something narrower and safer instead:
copy the source images into the worktree first, and never have shipped code
(including this generator script) read from the firstmate home path. So the
four PNGs are committed under this directory - self-contained, reproducible by
anyone who clones the repo, with no dependency on a path that only exists on
one captain's machine.

## Why square-crop with the background kept

Every source image is a fully opaque, roughly-centred rounded-square (three of
the four are literal macOS-style app icons with a small light background
margin; the poneglyph tablet is a landscape photo-style card). None carries a
transparent border to crop by, so - exactly like `build-straw-hat-flag.py`'s
own v2 source - the crop is simply "trim the longer axis evenly to a square",
keeping the background rather than guessing at a "real" edge with no source of
truth for where it is.

## Why 128x128

Same reasoning as `build-straw-hat-flag.py`: the two tiles that render these are
`HelmGradientTile.Size.module` (30pt, the canvas card) and `.drill` (34pt, the
page header / floating-bar shortcut). 128px is well past any real Mac
display's 2x for either.

Usage:
    python3 native/Scripts/build-card-shortcut-icons.py [--check]

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
ASSETS_DIR = os.path.join(HERE, "assets", "grandline-card-shortcut-icons")
SOURCES_DIR = os.path.normpath(os.path.join(HERE, "..", "Sources", "FirstmateCockpit"))

SIDE = 128
# One base64 line per this many characters - a single 40KB line is unreadable
# in a diff and in review. Same value `build-straw-hat-flag.py` uses.
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
        source_name="poneglyph.png",
        enum_name="PoneglyphIcon",
        file_name="PoneglyphIcon.swift",
        feature_note="`.poneglyph` (the personal credential vault)",
        doc_note="a weathered stone poneglyph tablet, carved with glyphs",
    ),
    IconSpec(
        source_name="tasks.png",
        enum_name="TasksIcon",
        file_name="TasksIcon.swift",
        feature_note='`.shift` (titled "Tasks" in this app\'s UI)',
        doc_note="a blue-to-orange gradient app icon with a white checklist card",
    ),
    IconSpec(
        source_name="code-preview.png",
        enum_name="CodePreviewIcon",
        file_name="CodePreviewIcon.swift",
        feature_note="`.codePreview`",
        doc_note="a blue-to-purple gradient app icon with a `</>` document and a pencil",
    ),
    IconSpec(
        source_name="sticky-notes.png",
        enum_name="StickyNotesIcon",
        file_name="StickyNotesIcon.swift",
        feature_note="`.stickyBoard`",
        doc_note="a blue app icon with a yellow sticky note pinned by a red pushpin",
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
        "// `native/Scripts/build-card-shortcut-icons.py` from the captain's own",
        f"// reference image (`{spec.source_name}`, committed under",
        "// `native/Scripts/assets/grandline-card-shortcut-icons/` - see that",
        "// script's own docstring for why the source lives in this repo rather",
        "// than firstmate's `data/` directory, unlike `StrawHatFlag`/",
        "// `StrawHatPortraits`). Re-run that script to change the crop or the",
        "// size; see its own docstring for why this is a base64 literal rather",
        "// than an asset catalog or an SPM resource bundle.",
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
        "/// exactly as `StrawHatFlag`/`StrawHatPortraits` do.",
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
