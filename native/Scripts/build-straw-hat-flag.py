#!/usr/bin/env python3
"""Generate `StrawHatFlag.swift` from the captain's Jolly Roger reference image.

`fm/polish-straw-hat-overview-card-and-voice-c8d3`: the captain asked for "an
image for the new Straw Hat Pirates card" and sent a screenshot of the crew's
Jolly Roger - the black flag with the straw-hatted skull and crossed bones.

## Why a generated Swift file and not an asset catalog or an SPM resource

Identical reasoning to `build-straw-hat-portraits.py`, which is the live
precedent in this tree (read its docstring for the full version):

  * `.xcassets` needs `actool`, **absent from a Command-Line-Tools-only
    toolchain** - and this project builds with plain `swift build`, no Xcode.
  * An SPM `resources:` bundle works under `swift build`, but this app's own
    `build_native_app.sh` never copies a `*.bundle` into the assembled `.app`,
    and the generated `Bundle.module` accessor `fatalError`s when it cannot
    resolve its path. A base64 literal has no path to resolve, so it behaves
    identically under `swift run`, a debug binary, and a hand-assembled
    `.app`.

## Why this crop, and why the black stays

The reference is a photo of the flag flying: a bamboo pole down the left,
sky and clouds top-right and bottom, the emblem waving across the middle.
`CROP` below is a square box on the **emblem** - skull, straw hat with its
red band, and the inner ends of all four bones - derived the way the
portraits' `FACE_BOX` values were: crop, render at the real tile size, look
at it, adjust. Three candidates were rendered at 60px (2x of the 30pt module
tile) and compared; a wider box shrank the skull to mush and a tighter one
clipped the hat brim and the teeth.

The flag's **black is kept rather than cut out to transparency**, which is a
deliberate choice with two reasons. It is faithful - a Jolly Roger *is* a
black flag, and the black is as much of the identity as the skull. And it is
robust: the flag in the reference is shaded and folded, so separating
skull-from-flag cleanly would be a guess in the mid-greys, and any error shows
up as a fringe on a 30pt tile. The consequence, intended: this card's tile
reads as a black flag rather than as one more hue-gradient tile, which is what
makes it recognisable at a glance on a canvas of otherwise-uniform cards.

## Why 128x128

The two tiles that render it are `HelmGradientTile.Size.module` (30pt, the
canvas card) and `.drill` (34pt, the page header). 128px is ~3.8x the larger
of those - past any real Mac display's 2x - and one flat-shaded cartoon PNG at
that size costs a few tens of KB.

Usage:
    python3 native/Scripts/build-straw-hat-flag.py [--source PATH] [--check]

`--check` regenerates into a temp file and diffs, so CI or a reviewer can
confirm the committed file matches its input without rewriting it.
"""

import argparse
import base64
import io
import os
import sys
import tempfile

try:
    from PIL import Image
except ImportError:  # pragma: no cover - a clear message beats a traceback
    sys.exit("This script needs Pillow: python3 -m pip install --user Pillow")

# The captain's reference screenshot. It lives in firstmate's own `data/`
# directory, outside this repo - it is an input to the task, not an app asset,
# so only the derived payload is committed here.
DEFAULT_SOURCE = os.path.expanduser(
    "~/manjesh/firstmate/data/polish-straw-hat-overview-card-and-voice-c8d3/"
    "straw-hat-jolly-roger-reference.png"
)

# Square crop on the emblem, as fractions of the source (l, t, r, b).
# See the module docstring for how this was derived.
CROP = (0.29, 0.16, 0.75, 0.76)

SIDE = 128
# One base64 line per this many characters - a single 40KB line is unreadable
# in a diff and in review. Same value `build-straw-hat-portraits.py` uses.
CHUNK = 120


def render(path: str) -> bytes:
    """Crop the emblem square, downscale, and re-encode."""
    image = Image.open(path).convert("RGBA")
    width, height = image.size
    left, top, right, bottom = CROP
    image = image.crop(
        (int(left * width), int(top * height), int(right * width), int(bottom * height))
    )
    # The fractional box is only approximately square; trim the longer axis
    # evenly so the tile is never distorted by the resize below.
    cropped_w, cropped_h = image.size
    side = min(cropped_w, cropped_h)
    image = image.crop(
        (
            (cropped_w - side) // 2,
            (cropped_h - side) // 2,
            (cropped_w - side) // 2 + side,
            (cropped_h - side) // 2 + side,
        )
    )
    image = image.resize((SIDE, SIDE), Image.LANCZOS)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def swift_source(payload: bytes) -> str:
    encoded = base64.b64encode(payload).decode("ascii")
    chunks = [encoded[i : i + CHUNK] for i in range(0, len(encoded), CHUNK)]
    lines = [
        "// Manjesh Grand Line - native macOS app.",
        "//",
        "// GENERATED FILE - do not hand-edit. Produced by",
        "// `native/Scripts/build-straw-hat-flag.py` from the captain's own Jolly",
        "// Roger reference screenshot (`data/polish-straw-hat-overview-card-and-",
        "// voice-c8d3/straw-hat-jolly-roger-reference.png`, on the firstmate side -",
        "// an input to that task, not an app asset, so it is not committed here).",
        "// Re-run that script to change the crop or the size; see its own docstring",
        "// for why this is a base64 literal rather than an asset catalog or an SPM",
        "// resource bundle, why the flag's black is kept rather than cut out, and",
        "// how the crop was derived.",
        "//",
        f"// The payload is a {SIDE}x{SIDE} PNG - ~3.8x the largest tile that renders it",
        "// (`HelmGradientTile.Size.drill`, 34pt).",
        "",
        "import AppKit",
        "",
        "/// The Straw Hat crew's Jolly Roger, for the module card and the drill",
        "/// header of the `.strawHat` destination.",
        "///",
        "/// `NSImage(data:)` returns nil on a corrupt payload rather than trapping,",
        "/// and every call site treats nil as \"fall back to the SF Symbol\" - so a bad",
        "/// regeneration degrades to a glyph rather than to a blank tile, exactly as",
        "/// `StrawHatPortraits` does. `StrawHatSelfTest` asserts it decodes at the",
        "/// expected size, because a silently-nil image is the kind of regression a",
        "/// build cannot see.",
        "enum StrawHatFlag {",
        "",
        "    /// The pixel side of the payload below.",
        f"    static let side: CGFloat = {SIDE}",
        "",
        "    /// The decoded flag, or nil if the payload is corrupt.",
        "    ///",
        "    /// **`isTemplate` is explicitly false.** A template image is drawn as a",
        "    /// tintable mask, which would flatten the straw hat's tan and red and the",
        "    /// skull's greys into one solid colour - i.e. it would throw away the",
        "    /// entire reason this is a raster asset instead of an SF Symbol. `NSImage`",
        "    /// from PNG data already defaults to false; this states the decision so a",
        "    /// later \"make it match the other tiles\" edit has to argue with it.",
        "    static var image: NSImage? {",
        "        if let cached { return cached }",
        "        guard let data = Data(base64Encoded: base64Chunks.joined()),",
        "              let image = NSImage(data: data) else {",
        "            AppLog.ui.error(\"straw hat: the Jolly Roger payload failed to decode\")",
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=DEFAULT_SOURCE, help="path to the reference PNG")
    parser.add_argument("--check", action="store_true",
                        help="diff against the committed file instead of writing")
    args = parser.parse_args()

    if not os.path.exists(args.source):
        sys.exit(
            f"Reference image not found at {args.source}\n"
            "It lives in firstmate's data/ directory, outside this repo - pass --source."
        )

    source = swift_source(render(args.source))

    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.normpath(
        os.path.join(here, "..", "Sources", "FirstmateCockpit", "StrawHatFlag.swift")
    )

    if args.check:
        if not os.path.exists(target):
            sys.exit(f"{target} does not exist yet - run without --check first.")
        with open(target, "r", encoding="utf-8") as handle:
            committed = handle.read()
        if committed != source:
            sys.exit(f"{target} is out of date - re-run this script without --check.")
        print(f"{target} matches its input.")
        return

    with open(target, "w", encoding="utf-8") as handle:
        handle.write(source)
    print(f"Wrote {target} ({len(source.encode('utf-8'))} bytes).")


if __name__ == "__main__":
    main()
