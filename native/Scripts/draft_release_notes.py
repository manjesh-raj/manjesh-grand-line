#!/usr/bin/env python3
"""Draft release notes from the pull requests merged between two git refs.

R2-PROC-04 of the second full review: one release tag in 291 commits, so
"which build am I on" was a commit hash and nothing could be rolled back to.
GL-18 already says a release is cut by tagging. This is the half of that
procedure a script can do safely: it reads local history and prints a draft.

Usage, from anywhere in the repository:

    python3 native/Scripts/draft_release_notes.py v0.1.0            # v0.1.0..HEAD
    python3 native/Scripts/draft_release_notes.py v0.1.0 v0.2.0     # between two tags

It prints Markdown to stdout and nothing else. It never creates or pushes a
tag, never writes a file and never talks to the network. Every merge into
`main` here is a squash merge whose subject ends in `(#<number>)`, so the
first-parent history between the two refs is the list of merged pull
requests, read with plain `git log`.

The output is a draft for a person to read and edit, and it becomes the
GitHub release's notes. It is deliberately not a CHANGELOG.md generator: this
repository has no CHANGELOG file, because the release notes are the changelog
(the captain's call, recorded in the README's "Releasing" section).
"""

import argparse
import re
import subprocess
import sys
from typing import List, NamedTuple, Optional

# A squash merge's subject: the PR title, then " (#123)".
_PR_SUBJECT = re.compile(r"^(?P<title>.*\S)\s+\(#(?P<number>\d+)\)$")


class Change(NamedTuple):
    title: str
    number: Optional[int]


def parse_subject(subject: str) -> Change:
    """One first-parent commit subject as a change, with its PR number if it has one."""
    match = _PR_SUBJECT.match(subject.strip())
    if match:
        return Change(match.group("title"), int(match.group("number")))
    return Change(subject.strip(), None)


def github_pull_url(remote_url: str) -> Optional[str]:
    """The `.../pull/` prefix for a GitHub remote, or None for anything else."""
    match = re.match(r"^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
                     r"(?P<path>[^/]+/[^/]+?)(?:\.git)?/?$", remote_url.strip())
    if not match:
        return None
    return "https://github.com/%s/pull/" % match.group("path")


def render(changes: List[Change], since: str, until: str, pull_url: Optional[str]) -> str:
    """The draft, oldest change first, pull requests before direct commits."""
    pulls = [c for c in changes if c.number is not None]
    direct = [c for c in changes if c.number is None]
    lines = ["## Changes since %s" % since, ""]
    lines.append("%d pull request(s) merged between `%s` and `%s`." % (len(pulls), since, until))
    lines.append("")
    if pulls:
        lines.append("### Pull requests")
        lines.append("")
        for change in pulls:
            ref = "#%d" % change.number
            if pull_url:
                ref = "[%s](%s%d)" % (ref, pull_url, change.number)
            lines.append("- %s (%s)" % (change.title, ref))
        lines.append("")
    if direct:
        lines.append("### Commits with no pull request")
        lines.append("")
        for change in direct:
            lines.append("- %s" % change.title)
        lines.append("")
    if not pulls and not direct:
        lines.append("Nothing was merged in this range.")
        lines.append("")
    return "\n".join(lines)


def _git(args: List[str], cwd: Optional[str]) -> str:
    result = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), result.stderr.strip()))
    return result.stdout


def draft(since: str, until: str = "HEAD", cwd: Optional[str] = None) -> str:
    """Read the first-parent history `since..until` and render it."""
    for ref in (since, until):
        _git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], cwd)
    log = _git(["log", "--first-parent", "--reverse", "--format=%s", "%s..%s" % (since, until)], cwd)
    changes = [parse_subject(line) for line in log.splitlines() if line.strip()]
    try:
        pull_url = github_pull_url(_git(["remote", "get-url", "origin"], cwd))
    except RuntimeError:
        pull_url = None
    return render(changes, since, until, pull_url)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Draft release notes from merged pull request titles.")
    parser.add_argument("since", help="the previous release tag, for example v0.1.0")
    parser.add_argument("until", nargs="?", default="HEAD", help="the new tag or commit (default: HEAD)")
    args = parser.parse_args(argv)
    try:
        sys.stdout.write(draft(args.since, args.until))
    except RuntimeError as error:
        sys.stderr.write("%s\n" % error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
