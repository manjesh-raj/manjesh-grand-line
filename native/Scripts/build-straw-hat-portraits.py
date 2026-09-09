#!/usr/bin/env python3
"""Generate `StrawHatPortraits.swift` from the crew portraits in the plan artifact.

Straw Hat Pirates phase 2, milestone M2.4 ("portrait tiles").

## Why a generated Swift file and not an asset catalog or an SPM resource

Both were ruled out for this repo before phase 1 ever shipped, and the reasons
are recorded in AGENTS.md's `CaptainIcon.swift` bullet:

  * `.xcassets` needs `actool`, which is **absent from a Command-Line-Tools-only
    toolchain** - and this project builds with plain `swift build`, no Xcode.
  * An SPM `resources:` bundle would work under `swift build`, but this app's
    own `build_native_app.sh` never copies a `*.bundle` directory into the
    assembled `.app`, and the generated `Bundle.module` accessor `fatalError`s
    (aborts the process) when it cannot resolve its path. A base64 literal has
    no path to resolve, so it behaves identically under `swift run`, a debug
    binary, and a hand-assembled `.app`.

`WhisperMetalShaderSource.swift` is the live precedent for a large generated
base64 payload in this tree (~920KB).

## Why the source images are not committed

The portraits live in firstmate's own `data/` directory, outside this repo -
they are inputs to the plan artifact, not app assets. This script reads them
from there and writes only the derived, right-sized payload into the app. If
the artifact moves, pass `--plan`.

## Why 96x96

Every render site is a tile of at most 32pt (the reply header's portrait and
the crew strip's). 96px is 3x that - sharper than any real Mac display needs -
and costs ~115KB of base64 for all four, against ~1.8MB for the originals.
The originals are full scene images (backgrounds, bodies), so each one is
**face-cropped by a hand-tuned box** before downscaling: a geometric centre
crop puts Nami's shoulders and Luffy's chin in frame and reads as colour mush
at 26pt. The boxes below were tuned against a coordinate grid rendered over
each original, then checked at the real 26pt circular size.

Usage:
    python3 native/Scripts/build-straw-hat-portraits.py [--plan PATH] [--check]

`--check` regenerates into a temp file and diffs, so CI or a reviewer can
confirm the committed file matches its inputs without rewriting it.
"""

import argparse
import base64
import io
import os
import re
import sys
import tempfile

try:
    from PIL import Image
except ImportError:  # pragma: no cover - a clear message beats a traceback
    sys.exit("This script needs Pillow: python3 -m pip install --user Pillow")

DEFAULT_PLAN = os.path.expanduser(
    "~/manjesh/firstmate/data/deepen-straw-hat-pirates-plan-explore-ja-3a/"
    "straw-hat-pirates-plan.html"
)

# The crew members the app ships. Keep in sync with `StrawHatMember` - the
# self-test asserts every member's portrait decodes, so a case added there
# without a name here fails rather than rendering the SF Symbol fallback
# forever.
CREW = ["Luffy", "Nami", "Chopper", "Robin", "Zoro", "Usopp", "Franky"]

# Hand-tuned square face crops, as fractions of each original (l, t, r, b).
# See the module docstring for how these were derived. Phase 3's three were
# derived the same way: crop, render, look at the 96px result, adjust.
FACE_BOX = {
    "Luffy": (0.15, 0.03, 0.87, 0.75),
    "Nami": (0.20, 0.10, 0.80, 0.70),
    "Robin": (0.10, 0.02, 0.90, 0.82),
    "Chopper": (0.14, 0.05, 0.94, 0.85),
    # Zoro's source is a full-body chibi on white, so his box is a real face
    # crop rather than the light trim the four close-ups need. Usopp's is
    # already a head-and-hat close-up filling the frame, so his is almost the
    # whole image - a tighter box cut the hat and the chin. Franky's source is
    # a dramatic upward-angle shot; the box is centred on the goggles-and-grin
    # region, which is what makes him recognisable at 26pt.
    "Zoro": (0.17, 0.05, 0.70, 0.58),
    "Usopp": (0.04, 0.00, 1.00, 0.96),
    "Franky": (0.28, 0.00, 0.96, 0.68),
}

SIDE = 96
# One base64 line per this many characters. Swift's parser handles a very long
# literal fine, but a 30KB single line makes the file unreadable in a diff and
# in a review - `WhisperMetalShaderSource.swift` chunks for the same reason.
CHUNK = 120


def extract(plan_html: str) -> dict:
    """Pull each crew member's first PNG data URI out of the plan artifact."""
    found = {}
    patterns = [
        r'<img[^>]*src="data:image/png;base64,([A-Za-z0-9+/=]+)"[^>]*alt="([A-Za-z]+)"',
        r'<img[^>]*alt="([A-Za-z]+)"[^>]*src="data:image/png;base64,([A-Za-z0-9+/=]+)"',
    ]
    for index, pattern in enumerate(patterns):
        for match in re.finditer(pattern, plan_html):
            b64, alt = match.groups() if index == 0 else match.groups()[::-1]
            if alt in CREW and alt not in found:
                found[alt] = b64
    missing = [name for name in CREW if name not in found]
    if missing:
        sys.exit(f"Could not find portraits for {missing} in the plan artifact.")
    return found


def render(b64: str, name: str) -> bytes:
    """Face-crop, square, downscale, and re-encode one portrait."""
    image = Image.open(io.BytesIO(base64.b64decode(b64))).convert("RGBA")
    width, height = image.size
    left, top, right, bottom = FACE_BOX[name]
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


def swift_source(payloads: dict) -> str:
    lines = [
        "// Manjesh Grand Line - native macOS app.",
        "//",
        "// GENERATED FILE - do not hand-edit. Produced by",
        "// `native/Scripts/build-straw-hat-portraits.py` from the crew portraits in",
        "// the captain-approved plan artifact (`data/deepen-straw-hat-pirates-plan-",
        "// explore-ja-3a/straw-hat-pirates-plan.html`, on the firstmate side - the",
        "// images are inputs to that plan, not app assets, so they are not committed",
        "// here). Re-run that script to change a crop or a size; see its own",
        "// docstring for why this is a base64 literal rather than an asset catalog",
        "// or an SPM resource bundle, and why each portrait is face-cropped.",
        "//",
        f"// Each payload is a {SIDE}x{SIDE} PNG - 3x the largest tile that renders it.",
        "",
        "import AppKit",
        "",
        "/// The crew portraits, decoded lazily and cached per member.",
        "///",
        "/// `NSImage(data:)` returns nil on a corrupt payload rather than trapping,",
        "/// and every call site treats a nil portrait as \"fall back to the SF Symbol\"",
        "/// - so a bad regeneration degrades to phase 1's glyph rather than to a",
        "/// blank tile. `StrawHatSelfTest` asserts all four decode at the expected",
        "/// size, because a silently-nil image is exactly the kind of regression a",
        "/// build cannot see.",
        "enum StrawHatPortraits {",
        "",
        f"    /// The pixel side of every payload below.",
        f"    static let side: CGFloat = {SIDE}",
        "",
        "    static func image(for member: StrawHatMember) -> NSImage? {",
        "        if let cached = cache[member] { return cached }",
        "        guard let base64 = base64Chunks[member]?.joined(),",
        "              let data = Data(base64Encoded: base64),",
        "              let image = NSImage(data: data) else {",
        "            AppLog.ui.error(\"straw hat: portrait for \\(member.rawValue, privacy: .public) failed to decode\")",
        "            return nil",
        "        }",
        "        cache[member] = image",
        "        return image",
        "    }",
        "",
        "    /// Decoded portraits, kept for the process's life. Four small images,",
        "    /// re-decoded on every transcript block otherwise - a reply from three",
        "    /// crew members would decode three PNGs per render pass.",
        "    private static var cache: [StrawHatMember: NSImage] = [:]",
        "",
        "    private static let base64Chunks: [StrawHatMember: [String]] = [",
    ]
    for name in CREW:
        raw = payloads[name]
        encoded = base64.b64encode(raw).decode("ascii")
        chunks = [encoded[i : i + CHUNK] for i in range(0, len(encoded), CHUNK)]
        lines.append(f"        // {name}: {len(raw)} bytes, {len(encoded)} base64 characters.")
        lines.append(f"        .{name.lower()}: [")
        for chunk in chunks:
            lines.append(f'            "{chunk}",')
        lines.append("        ],")
    lines.append("    ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", default=DEFAULT_PLAN, help="path to the plan artifact HTML")
    parser.add_argument("--check", action="store_true", help="diff against the committed file instead of writing")
    args = parser.parse_args()

    if not os.path.exists(args.plan):
        sys.exit(
            f"Plan artifact not found at {args.plan}\n"
            "It lives in firstmate's data/ directory, outside this repo - pass --plan."
        )
    with open(args.plan, "r", encoding="utf-8", errors="replace") as handle:
        plan_html = handle.read()

    payloads = {name: render(b64, name) for name, b64 in extract(plan_html).items()}
    source = swift_source(payloads)

    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(here, "..", "Sources", "FirstmateCockpit", "StrawHatPortraits.swift")
    target = os.path.normpath(target)

    if args.check:
        with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False, encoding="utf-8") as handle:
            handle.write(source)
            temp = handle.name
        existing = open(target, encoding="utf-8").read() if os.path.exists(target) else ""
        if existing == source:
            print(f"StrawHatPortraits.swift is up to date ({len(source)} bytes)")
            os.unlink(temp)
            return
        sys.exit(f"StrawHatPortraits.swift is stale - regenerated copy at {temp}")

    with open(target, "w", encoding="utf-8") as handle:
        handle.write(source)
    total = sum(len(v) for v in payloads.values())
    print(f"Wrote {target}")
    for name in CREW:
        print(f"  {name}: {len(payloads[name])} bytes")
    print(f"  total {total} bytes of PNG, {len(source)} bytes of Swift")


if __name__ == "__main__":
    main()
