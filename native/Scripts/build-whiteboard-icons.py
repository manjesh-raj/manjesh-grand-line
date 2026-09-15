#!/usr/bin/env python3
"""Regenerate Sources/FirstmateCockpit/WhiteboardIcons.swift.

The Whiteboard's component palette draws a real icon for every one of its
components. This script turns the committed source glyphs in
`Scripts/assets/whiteboard-icons/` into one generated Swift file holding a
`data:` URL per component, which `WhiteboardIconLibrary` hands to the canvas
as an Excalidraw image file.

Run by hand after changing the mapping below or refreshing a source glyph. It
is NOT part of `swift build` and never runs at app launch - the output is
committed, exactly like `build-card-shortcut-icons.py` and
`build-straw-hat-flag.py`.

    python3 Scripts/build-whiteboard-icons.py            # regenerate
    python3 Scripts/build-whiteboard-icons.py --check    # diff, exit 1 on drift
    python3 Scripts/build-whiteboard-icons.py --fetch    # re-download the sources

## Where the glyphs come from, and why these and not the obvious ones

**Material Symbols, Apache-2.0.** Google's own README grants exactly what
bundling needs - "We have made these icons available for you to incorporate
into your products under the Apache License Version 2.0" - so redistributing
them inside this app is licensed rather than assumed. The licence text ships
beside the sources in `assets/whiteboard-icons/LICENSE-material-symbols.txt`.

**Not the AWS Architecture Icons**, even though they are what an AWS diagram
"should" look like and what this task was pointed at. The asset package ships
no licence file of any kind, the icons page grants only permission to *create
diagrams* with them, and the AWS Trademark Guidelines say the opposite of what
bundling needs: "you will not transfer, assign or sublicense your license to
use the AWS Marks or Program Content" (s3(d)) and "AWS does not provide
licenses or other authorization for use of AWS content in third party
publications, including screenshots, diagrams, code, documentation, or other
copyrightable materials" (s15). Redistributing the files inside an app binary
is a right AWS never grants, so the app does not take it. Service *names* are
still used as labels, which is ordinary nominative use - the trade dress is
the licensed part, not the word "S3".

**Not the official Kubernetes icons either**, which *are* safely licensed
(Apache-2.0 or CC-BY-4.0, stated in `kubernetes/community`'s own
`icons/README.md`) and were verified as such. They are full-colour badges in
their own visual language, and mixing them with the chips below would put two
icon styles side by side in one diagram - an EKS cluster next to an S3 bucket -
which reads worse than one consistent set. Left as a follow-up the captain can
ask for deliberately, not dropped for licence reasons.

## The chip, and why it is drawn this way

Each icon is a white rounded chip carrying the glyph in its component's own
role hue. That shape is chosen for a measured reason rather than taste:
**Excalidraw 0.18.1 applies `invert(93%) hue-rotate(180deg)` to every image on
a dark canvas**, SVG included (its own guard for SVGs compares against a map
with no `svg` key, so it never fires). That filter flips lightness and keeps
hue, so a white chip becomes a near-black chip and the role-coloured glyph
stays the same hue a shade lighter - which is what a dark-theme diagram should
look like. A solid role-coloured tile with a white glyph - the AWS look - was
rendered side by side with this and looks better in light mode and visibly
inverted in dark, which is the register this app defaults to.
"""

import argparse
import base64
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets", "whiteboard-icons")
OUT = os.path.join(HERE, "..", "Sources", "FirstmateCockpit", "WhiteboardIcons.swift")

SOURCE_URL = ("https://raw.githubusercontent.com/google/material-design-icons/master/"
              "symbols/web/{name}/materialsymbolsoutlined/{name}_fill1_24px.svg")

# Role -> the glyph hue, matching `DiagramComponentRole.strokeColor` exactly.
# Duplicated here rather than imported because this script has no Swift runtime;
# `WhiteboardIconsSelfTest` asserts the two agree, so they cannot drift.
ROLE_HEX = {
    "compute": "#1971c2",
    "container": "#0c8599",
    "data": "#2f9e44",
    "messaging": "#f08c00",
    "routing": "#9c36b5",
    "security": "#e03131",
    "observability": "#0ca678",
    "delivery": "#c2255c",
    "edge": "#343a40",
    "person": "#1e1e1e",
}

# component keyword -> (Material Symbol name, role).
#
# One line per component, in the enum's own order. A symbol is picked for what
# the component *is*, never for its vendor: a queue reads as a queue whether it
# is SQS or RabbitMQ, which is the same reasoning `DiagramComponentRole` gives
# for colouring by role.
COMPONENTS = [
    ("server", "dns", "compute"),
    ("k8s", "deployed_code", "container"),
    ("db", "database", "data"),
    ("queue", "list_alt", "messaging"),
    ("lb", "device_hub", "routing"),
    ("secrets", "lock", "security"),
    ("actor", "person", "person"),
    ("ec2", "computer", "compute"),
    ("lambda", "bolt", "compute"),
    ("ecs", "grid_view", "container"),
    ("eks", "hub", "container"),
    ("alb", "alt_route", "routing"),
    ("apigw", "login", "routing"),
    ("cloudfront", "public", "routing"),
    ("route53", "travel_explore", "routing"),
    ("s3", "inventory_2", "data"),
    ("rds", "storage", "data"),
    ("dynamodb", "table_chart", "data"),
    ("elasticache", "speed", "data"),
    ("sqs", "forum", "messaging"),
    ("sns", "campaign", "messaging"),
    ("eventbridge", "shuffle", "messaging"),
    ("kinesis", "waves", "messaging"),
    ("stepfunctions", "account_tree", "messaging"),
    ("iam", "badge", "security"),
    ("secretsmanager", "key", "security"),
    ("cloudwatch", "visibility", "observability"),
    ("vpc", "account_balance", "edge"),
    ("deploy", "rocket_launch", "container"),
    ("k8ssvc", "share", "routing"),
    ("ingress", "route", "routing"),
    ("configmap", "description", "data"),
    ("namespace", "folder_managed", "edge"),
    ("statefulset", "layers", "container"),
    ("cronjob", "schedule", "container"),
    ("node", "developer_board", "compute"),
    ("cdn", "cell_tower", "routing"),
    ("dns", "language", "routing"),
    ("firewall", "security", "security"),
    ("proxy", "swap_calls", "routing"),
    ("vpn", "vpn_lock", "security"),
    ("internet", "cloud", "edge"),
    ("subnet", "map", "edge"),
    ("cache", "memory", "data"),
    ("blob", "folder", "data"),
    ("warehouse", "warehouse", "data"),
    ("search", "search", "data"),
    ("stream", "sync_alt", "messaging"),
    ("metrics", "monitoring", "observability"),
    ("logs", "receipt_long", "observability"),
    ("traces", "timeline", "observability"),
    ("dashboard", "dashboard", "observability"),
    ("alert", "warning", "observability"),
    ("oncall", "call", "observability"),
    ("repo", "book", "delivery"),
    ("pipeline", "build", "delivery"),
    ("registry", "apps", "delivery"),
    ("container", "archive", "container"),
    ("terraform", "architecture", "delivery"),
    ("cert", "policy", "security"),
    ("auth", "verified_user", "security"),
    ("waf", "shield", "security"),
]

# The chip. 56pt square so a Material glyph has room to read at diagram scale
# without the node box having to grow.
SIZE = 56
CHIP_RADIUS = 12
GLYPH_BOX = 34          # the glyph's own square, centred in the chip
CHIP_INSET = 1.0        # keeps the hairline stroke inside the viewBox


def glyph_path(name):
    """The `d` attribute out of a Material Symbols source SVG.

    Deliberately strict: Material Symbols files are a single `<path>` in a
    `0 -960 960 960` viewBox, and anything else is a file this script does not
    understand rather than one to guess at.
    """
    with open(os.path.join(ASSETS, name + ".svg"), encoding="utf-8") as handle:
        svg = handle.read()
    if 'viewBox="0 -960 960 960"' not in svg:
        raise SystemExit("%s: not the expected Material Symbols viewBox" % name)
    paths = re.findall(r'<path d="([^"]+)"', svg)
    if len(paths) != 1:
        raise SystemExit("%s: expected exactly one path, found %d" % (name, len(paths)))
    return paths[0]


def chip_svg(symbol, role):
    """One component's artwork: a white chip, a hairline in the role hue, and
    the glyph filled in that same hue."""
    hue = ROLE_HEX[role]
    d = glyph_path(symbol)
    offset = (SIZE - GLYPH_BOX) / 2.0
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="{s}" height="{s}" '
        'viewBox="0 0 {s} {s}">'
        '<rect x="{i}" y="{i}" width="{w}" height="{w}" rx="{r}" '
        'fill="#ffffff" stroke="{hue}" stroke-width="2"/>'
        '<svg x="{o}" y="{o}" width="{g}" height="{g}" viewBox="0 -960 960 960">'
        '<path d="{d}" fill="{hue}"/></svg>'
        "</svg>"
    ).format(s=SIZE, i=CHIP_INSET, w=SIZE - 2 * CHIP_INSET, r=CHIP_RADIUS,
             hue=hue, o=offset, g=GLYPH_BOX, d=d)


def data_url(svg):
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode("utf-8")).decode("ascii")


def chunked(text, width=100):
    return [text[i:i + width] for i in range(0, len(text), width)]


def render_swift():
    lines = [
        "// Manjesh Grand Line - native macOS app.",
        "//",
        "// GENERATED by native/Scripts/build-whiteboard-icons.py - do not edit by hand.",
        "// Run that script with --check to confirm this file matches its sources.",
        "//",
        "// One `data:` URL per Whiteboard component: a white chip carrying the",
        "// component's glyph in its role hue. See the generator's own docstring for",
        "// where the glyphs come from, which icon sets were rejected and why, and why",
        "// the chip is drawn this way rather than as a solid AWS-style tile.",
        "//",
        "// Glyphs: Material Symbols, Apache License 2.0 (Google). The licence text",
        "// ships at native/Scripts/assets/whiteboard-icons/LICENSE-material-symbols.txt.",
        "",
        "enum WhiteboardIcons {",
        "",
        "    /// Keyed by `DiagramComponent.keyword`, which is the stable identifier a",
        "    /// saved board and the DSL both already use.",
        "    static let dataURLs: [String: String] = [",
    ]
    for keyword, symbol, role in COMPONENTS:
        url = data_url(chip_svg(symbol, role))
        parts = chunked(url)
        lines.append('        // %s -> Material Symbols "%s"' % (keyword, symbol))
        lines.append('        "%s":' % keyword)
        for i, part in enumerate(parts):
            suffix = "," if i == len(parts) - 1 else " +"
            lines.append('            "%s"%s' % (part, suffix))
    lines += [
        "    ]",
        "",
        "    /// The Material Symbol behind each component, so a self-test can assert the",
        "    /// mapping is complete and one-to-one without re-deriving it from base64.",
        "    static let symbolNames: [String: String] = [",
    ]
    for keyword, symbol, _ in COMPONENTS:
        lines.append('        "%s": "%s",' % (keyword, symbol))
    lines += [
        "    ]",
        "",
        "    /// The glyph hue each component is drawn in, mirroring",
        "    /// `DiagramComponentRole.strokeColor`. Asserted equal in the self-test.",
        "    static let glyphHexes: [String: String] = [",
    ]
    for keyword, _, role in COMPONENTS:
        lines.append('        "%s": "%s",' % (keyword, ROLE_HEX[role]))
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def fetch():
    os.makedirs(ASSETS, exist_ok=True)
    for _, symbol, _ in COMPONENTS:
        dest = os.path.join(ASSETS, symbol + ".svg")
        subprocess.run(["curl", "-sfS", "--max-time", "20", "-o", dest,
                        SOURCE_URL.format(name=symbol)], check=True)
        print("fetched", symbol)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--fetch", action="store_true")
    args = parser.parse_args()

    if args.fetch:
        fetch()
        return

    rendered = render_swift()
    if args.check:
        try:
            with open(OUT, encoding="utf-8") as handle:
                current = handle.read()
        except FileNotFoundError:
            print("MISSING:", OUT)
            sys.exit(1)
        if current != rendered:
            print("DRIFT:", os.path.relpath(OUT))
            sys.exit(1)
        print("OK:", os.path.relpath(OUT))
        return

    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write(rendered)
    print("wrote %s (%d components)" % (os.path.relpath(OUT), len(COMPONENTS)))


if __name__ == "__main__":
    main()
