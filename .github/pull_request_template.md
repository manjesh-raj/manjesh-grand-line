<!--
Process issue P3. `~/.claude/CLAUDE.md` has required a Summary and a Reason in
every PR description for a long time and nothing carried the reminder into the
repository, so the two headings below are the template's whole job. Delete any
section that genuinely does not apply rather than leaving it empty.
-->

## Summary

<!-- What changed. -->

## Reason

<!-- Why the change was needed. -->

## Verification

<!--
This repository's own house rule (AGENTS.md, "Verification conventions"): say
what you actually ran, and say what you did not.

- A fix gets the revert-and-watch-fail treatment: name the injection, the case
  that failed, and that restoring it made the case pass again.
- Say which suites you ran. A cross-cutting change owes a full local
  `./Scripts/run-all-tests.sh`; a narrow one may name the suites it ran and why
  that was the whole relevant set.
- State what was not verified. "Verified by `swift build` only", "not
  reproducible in this sandbox" and "the live half is the captain's own check"
  are all acceptable; implying a check that did not happen is not.
-->
