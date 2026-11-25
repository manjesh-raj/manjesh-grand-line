#!/usr/bin/env python3
"""A soft line budget for the app's hand-written Swift files (P-05).

P-05 of the 2026-11-25 full review found the four largest files growing by 15
to 27 percent in nine days, against GL-36's rule that a controller which has
outgrown its seams is split along its `// MARK:` boundaries. This check names
every hand-written file over the budget so the growth is visible on each pull
request. It is a warning, not a gate: it never fails the run.

A file whose first lines carry the `GENERATED FILE` marker is skipped, because
its size is its generator's business (the Whisper shader source, the icons).

Run with: python3 Scripts/line_budget.py   (from `native/`)
Under GitHub Actions each file over the budget is a `::warning` annotation.
"""

import os
import sys

BUDGET = 3000
SOURCE_DIR = os.path.join("Sources", "GrandLine")
GENERATED_MARKER = "GENERATED FILE"
HEADER_LINES = 12


def is_generated(lines):
    return any(GENERATED_MARKER in line for line in lines[:HEADER_LINES])


def over_budget(source_dir, budget=BUDGET):
    """(relative path, line count) for every hand-written file over `budget`,
    largest first. Not recursive: `SelfTests/` is test code under its own rules."""
    found = []
    for name in sorted(os.listdir(source_dir)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(source_dir, name)
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        if is_generated(lines):
            continue
        if len(lines) > budget:
            found.append((path, len(lines)))
    return sorted(found, key=lambda item: (-item[1], item[0]))


def report(found, budget=BUDGET, annotate=False):
    out = []
    for path, count in found:
        text = f"{path} is {count} lines, over the {budget}-line budget. GL-36: split it along its // MARK: seams."
        out.append(f"::warning file=native/{path}::{text}" if annotate else f"WARN {text}")
    if not found:
        out.append(f"every hand-written Swift file is within {budget} lines")
    return out


def main():
    source_dir = sys.argv[1] if len(sys.argv) > 1 else SOURCE_DIR
    found = over_budget(source_dir)
    for line in report(found, annotate=os.environ.get("GITHUB_ACTIONS") == "true"):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
