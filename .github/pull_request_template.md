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
- State what was not verified, in the "Not verified" section below.
  "Verified by `swift build` only", "not reproducible in this sandbox" and
  "the live half is the captain's own check" are all acceptable; implying a
  check that did not happen is not.
-->

## Renders

<!--
For anything a person can see: before-and-after renders of each page the
change touches, from the tour lab (`FM_REVIEW_TOUR`) where possible, so the
second reader below can judge them without building the branch.
Write "No visible change" when there is none.
-->

## Not verified

<!--
Everything you did not check, one item per line. The second reader reads this
list and decides whether any of it has to be checked before merge.
-->

## Second reader

<!--
R2-PROC-03 of the second full review: a second reader looks at the renders
and the "Not verified" list, not the diff. CONTRIBUTING.md says what that
job is. For an agent-written PR, a separate agent in review-only mode counts.
-->

- [ ] A second reader looked at every render above.
- [ ] A second reader read the "Not verified" list and either accepted it or asked for a check.
