# Contributing

`AGENTS.md` holds the standing rules for changing this code, and `native/README.md` is the front door for building and testing it.
This file covers what those two do not: what a second reader of a pull request is for.

## The second reader

Every pull request gets a second reader before it merges.
The author's own PR body is not that reader, however thorough it is.
Review #2 found three defects that shipped through green CI and a careful PR body (R2-BUG-02, R2-BUG-03 and R2-BUG-05), and a second reader looking at the renders would have caught two of them.

The reader's job is narrow on purpose:

- **Look at the renders.** For a change anyone can see, open each before-and-after render in the PR and judge it as the captain would see it, not as the code says it should look. Things to check are a truncated label, two readings of one number, a pane at the wrong width, and a toast that says something false.
- **Read the "Not verified" list.** Decide whether anything on it is risky enough to verify before merging. If it is, say so on the PR.
- **Do not review the diff line by line.** CI, the source guards and the revert proofs cover that. The reader is there for what those cannot see.

The tour lab makes this a ten-minute task.
A tour (`FM_REVIEW_TOUR`, documented in the README's environment table) mounts the real shell on scratch stores, walks the pages the PR touched and writes one PNG per `render`.
A reader can re-run the PR's own tour against its branch rather than trusting the attached images.

Who counts as a reader:

- the captain;
- for an agent-written PR, a separate agent run in review-only mode, given the PR body and the renders but not the author's conversation.

Record the outcome on the PR, either as a review or as a comment that says what was looked at.
The pull request template's "Second reader" checklist is the place to tick it.
