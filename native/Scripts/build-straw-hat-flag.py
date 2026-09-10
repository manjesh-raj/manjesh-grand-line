#!/usr/bin/env python3
"""Generate `StrawHatFlag.swift` from the crew's Jolly Roger reference image.

`fm/straw-hat-voice-order-composer-polish-8dd2`: after the first version of
this icon shipped (`fm/polish-straw-hat-overview-card-and-voice-c8d3`, a photo
of the flag flying on its pole), the captain sent a second, cleaner reference
- a flat-style Jolly Roger drawn directly on a dark rounded-square card
backdrop, with no pole, sky or fold shading to crop around - and asked for the
card icon to use it instead. This is the second source this script has
generated `StrawHatFlag.swift` from; only the `DEFAULT_SOURCE`/`CROP`
constants and this docstring's "why this crop" section changed between the
two runs, everything else (why a generated file, why 128px, the chunking) is
unchanged from the original.

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

## Why this crop (v2 reference)

The v2 reference is already the finished icon, not a photo to crop an emblem
out of: a white skull with black eye sockets, a yellow straw hat with a red
band, and white crossbones, laid flat on a solid dark charcoal background that
fills the frame edge to edge (measured - the corner and edge pixels are the
same opaque background colour as the centre, no rounded-corner transparency
baked in, so any corner rounding on screen comes from the tile view's own
`cornerRadius`/`masksToBounds`, not from this asset). So `CROP` is the whole
image rather than a fraction picked out of it; the only work `render()` still
does is trim the source's few pixels of rectangular slack (494x502) down to a
square before the resize, exactly as it always did for a crop that wasn't
perfectly square either.

The background is kept rather than cut to transparency, for the same reason
v1's flag-black was kept: the dark backdrop is part of this icon's own design,
not incidental fill around it, and removing it would leave a guess at the
skull's own edge with no source of truth for where the card's "real" boundary
is. The consequence, intended and unchanged from v1: this card still reads as
a fixed, self-contained piece of art rather than one more hue-gradient tile,
which is what makes it recognisable at a glance on a canvas of otherwise-
uniform cards.

## Why 128x128

The two tiles that render it are `HelmGradientTile.Size.module` (30pt, the
canvas card) and `.drill` (34pt, the page header). 128px is ~3.8x the larger
of those - past any real Mac display's 2x - and one flat-shaded cartoon PNG at
that size costs a few tens of KB.

Usage:
    python3 native/Scripts/build-straw-hat-flag.py [--source PATH] [--check]

`--check` regenerates in memory and diffs against the committed file, writing
nothing anywhere, so CI or a reviewer can confirm the committed file matches
its input. It leaves no temp file behind on a mismatch - a `--check` that
litters is a `--check` nobody wants to wire into CI.
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

# The captain's v2 reference image (a flat-style Jolly Roger already composed
# on a dark rounded-square card backdrop), committed **in this repo** beside
# the two icon-batch generators' own sources.
#
# It used to default to a path inside firstmate's `data/` directory, outside
# this repo, which made `--check` unrunnable anywhere but the captain's own
# machine - so a CI drift guard could only ever fail for the environment
# rather than for real drift. The newer `build-card-shortcut-icons.py` /
# `build-rail-icons-batch2.py` had already established the fix: keep a
# generator's source image under `native/Scripts/assets/<generator>/` so the
# whole regenerate-and-diff loop is reproducible from a clean clone. The v1
# photo this reference replaced (`data/polish-straw-hat-overview-card-and-
# voice-c8d3/straw-hat-jolly-roger-reference.png`) stays on the firstmate side
# as historical record; this script no longer reads it.
ASSETS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "assets", "straw-hat-flag")
DEFAULT_SOURCE = os.path.join(ASSETS_DIR, "straw-hat-card-icon-v2-reference.png")

# The whole source, as fractions (l, t, r, b) - the v2 reference is already
# the finished icon with no emblem to pick out of a larger scene. See the
# module docstring's "why this crop" section.
CROP = (0.0, 0.0, 1.0, 1.0)

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
        "// `native/Scripts/build-straw-hat-flag.py` from the captain's v2 Jolly",
        "// Roger reference image, committed in this repo at",
        "// `native/Scripts/assets/straw-hat-flag/straw-hat-card-icon-v2-",
        "// reference.png` so the regenerate-and-diff loop is reproducible from a",
        "// clean clone. That reference replaced the original flag-in-sky photo with",
        "// a flat-style icon already composed on its own card backdrop; see the",
        "// script's own docstring for why the crop is \"the whole image\" as a",
        "// result.",
        "// Re-run that script to change the crop or the size; see its own docstring",
        "// for why this is a base64 literal rather than an asset catalog or an SPM",
        "// resource bundle and why the background is kept rather than cut out.",
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
            "It is committed under native/Scripts/assets/straw-hat-flag/ - pass "
            "--source to generate from a different image."
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
