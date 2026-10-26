#!/usr/bin/env python3
"""Per-suite pass and fail history across runs of run-all-tests.sh.

R2-PROC-06 of the second full review: flakes were root-caused one at a time
(#511, #518, #523, #524), each well written up, and nothing counted them. A
suite that failed one run in nine looked like a fresh defect every time.

`run-all-tests.sh --history=<file>` calls this once at the end of a run:

    suite_history.py record  --file F --lane L --run R --results results.tsv
    suite_history.py summary --file F --lane L

`record` appends this run to the JSON file at F (creating it), keeping the
newest MAX_RUNS runs. `results.tsv` has one line per suite:
`<name>\\t<result>\\t<milliseconds>\\t<checks or ->`, where result is one of
pass, fail, timeout, skip or flaky (failed, then passed on the runner's
re-run). `summary` prints Markdown: the flaky suites of the newest run, every
suite whose recorded results disagree with each other, and the suite count
and lane time per run, so a growing lane is visible (R2-PROC-05).

CI keeps F between runs with `actions/cache` and uploads it as an artifact,
so the history spans runs rather than one job. Locally F accumulates in
`.build/`, which git ignores.

Standard library only, and Python 3.9, which is what macOS ships.
"""

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from typing import Dict, List, Optional

# Nothing unbounded (GL-35). Fifty runs of two hundred suites is ~1MB.
MAX_RUNS = 50
RESULTS = ("pass", "fail", "timeout", "skip", "flaky")


def load(path: str) -> Dict:
    """The history at `path`, or an empty one when there is no file yet.

    A file that exists and cannot be read is an error, not an empty history
    (GL-01): starting over would silently drop every earlier run.
    """
    if not os.path.exists(path):
        return {"version": 1, "runs": []}
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or not isinstance(data.get("runs"), list):
        raise ValueError("%s is not a suite history file" % path)
    return data


def parse_results(text: str) -> Dict[str, Dict]:
    """The runner's TSV as {suite: {"result", "ms", "checks"}}."""
    suites: Dict[str, Dict] = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 4 or parts[1] not in RESULTS:
            raise ValueError("bad results line: %r" % line)
        name, result, ms, checks = parts
        suites[name] = {
            "result": result,
            "ms": int(ms),
            "checks": None if checks in ("", "-") else int(checks),
        }
    return suites


def record(history: Dict, lane: str, run: str, suites: Dict[str, Dict], now: Optional[str] = None) -> Dict:
    """`history` with this run appended and the oldest dropped past MAX_RUNS."""
    entry = {
        "at": now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lane": lane,
        "run": run,
        "suite_count": sum(1 for s in suites.values() if s["result"] != "skip"),
        "lane_ms": sum(s["ms"] for s in suites.values()),
        "suites": suites,
    }
    history["runs"] = (history.get("runs", []) + [entry])[-MAX_RUNS:]
    return history


def save(history: Dict, path: str) -> None:
    """Written whole and renamed into place, so an interrupted write never
    leaves half a file for the next run to refuse."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    handle, temp = tempfile.mkstemp(dir=directory, prefix=".suite-history-")
    with os.fdopen(handle, "w", encoding="utf-8") as out:
        json.dump(history, out, indent=1, sort_keys=True)
        out.write("\n")
    os.replace(temp, path)


def mixed_suites(runs: List[Dict]) -> Dict[str, Dict[str, int]]:
    """Every suite whose runs disagree: {suite: {result: count}}, for suites
    that both passed and failed (or were flaky) somewhere in `runs`."""
    tallies: Dict[str, Dict[str, int]] = {}
    for run in runs:
        for name, suite in run.get("suites", {}).items():
            if suite["result"] == "skip":
                continue
            tally = tallies.setdefault(name, {})
            tally[suite["result"]] = tally.get(suite["result"], 0) + 1
    mixed = {}
    for name, tally in tallies.items():
        bad = tally.get("fail", 0) + tally.get("timeout", 0) + tally.get("flaky", 0)
        if tally.get("flaky", 0) or (bad and tally.get("pass", 0)):
            mixed[name] = tally
    return mixed


def summary(history: Dict, lane: str) -> str:
    """Markdown for a job summary: this lane's newest run, then its history."""
    runs = [r for r in history.get("runs", []) if r.get("lane") == lane]
    lines = ["### Suite history (%s)" % lane, ""]
    if not runs:
        lines += ["No run of this lane is recorded yet.", ""]
        return "\n".join(lines)
    newest = runs[-1]
    flaky = sorted(n for n, s in newest["suites"].items() if s["result"] == "flaky")
    if flaky:
        lines.append("**Failed, then passed on re-run, in this run** (the run still fails; these are likely flaky):")
        lines.append("")
        lines += ["- `%s`" % name for name in flaky]
    else:
        lines.append("No suite failed and then passed on re-run in this run.")
    lines.append("")

    mixed = mixed_suites(runs)
    lines.append("**Suites with mixed results over the last %d recorded run(s) of this lane:**" % len(runs))
    lines.append("")
    if mixed:
        lines.append("| Suite | Results |")
        lines.append("| --- | --- |")
        for name in sorted(mixed, key=lambda n: (-sum(v for k, v in mixed[n].items() if k != "pass"), n)):
            tally = ", ".join("%d %s" % (count, result) for result, count in sorted(mixed[name].items()))
            lines.append("| `%s` | %s |" % (name, tally))
    else:
        lines.append("None.")
    lines.append("")

    lines.append("**Suite count and lane time per run** (newest last):")
    lines.append("")
    lines.append("| When | Run | Suites | Lane time |")
    lines.append("| --- | --- | --- | --- |")
    for run in runs[-10:]:
        lines.append("| %s | %s | %d | %.1f min |" % (run["at"], run["run"], run["suite_count"], run["lane_ms"] / 60000.0))
    lines.append("")
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("record", help="append one run to the history")
    rec.add_argument("--file", required=True)
    rec.add_argument("--lane", required=True)
    rec.add_argument("--run", required=True)
    rec.add_argument("--results", required=True, help="the runner's TSV of per-suite results")
    summ = sub.add_parser("summary", help="print a Markdown summary of one lane")
    summ.add_argument("--file", required=True)
    summ.add_argument("--lane", required=True)
    args = parser.parse_args(argv)

    try:
        history = load(args.file)
        if args.command == "record":
            with open(args.results, encoding="utf-8") as handle:
                suites = parse_results(handle.read())
            save(record(history, args.lane, args.run, suites), args.file)
        else:
            sys.stdout.write(summary(history, args.lane))
    except (OSError, ValueError) as error:
        sys.stderr.write("suite_history: %s\n" % error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
