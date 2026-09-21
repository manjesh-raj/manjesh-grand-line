# Snippet expander (F12)

Built by `fm/grandline-feature-f12-snippet-expander` - one of four of full
review #3 §8's recommendations the captain picked to build in parallel (F15,
and F16+F17 together, were the others, each in its own worktree).

The report's own entry:

> **F12 - Snippet expander.** Text snippets with `;abbrev` triggers expanded
> system-wide via the same Accessibility-trusted paste path Dictation uses; the
> Snippets store already exists for shell text - generalise it. *Scope:* M.

The captain reviewed a mockup before it existed, in the published "Grand Line
Futures" artifact (F12's section): the Snippets page with a trigger chip per
row, a `system-wide` / `Console only` chip in the trailing column, a right-hand
detail card naming the expansion, its placeholders and where it fires, an
Accessibility-access card below it, and a floating Mail window showing `;sig`
being replaced in place. The shipped feature is that mockup, with the
departures stated below.

---

## What shipped

**The store was generalised, not duplicated.** `Snippet` gained three fields -
`trigger`, `scope`, `excludedApps` - and everything else about it is unchanged.
There is still one `snippets.json`, one editor sheet and one list. The report
asked for exactly this; the alternative would have been two lists of saved text
with two editors and a captain having to remember which one a given string
lives in.

- **`SnippetExpansion.swift`** is the whole decision layer, and imports nothing
  but Foundation: the trigger grammar, the typed-run buffer, the trigger table,
  the placeholders and the scope/exclusion policy.
- **`SnippetExpander.swift`** is the AppKit half: the monitors, the context it
  gathers at the moment of a keystroke, and the injection.
- **`SnippetExpansionPanel.swift`** is the mockup's Accessibility card, shown
  on the Snippets tab only.
- The **editor sheet** gained a Trigger section (the abbreviation, a Where
  popup, a "Never in" chip well) and a caption naming the four placeholders.
  The trigger is optional, so the fast save-and-run loop the sheet was built
  for is still two fields and Return.

### The trigger grammar

A trigger is `;` + letters/digits/`-`/`_`, at most 24 characters. It fires when
all four of these hold, and the four are stated in `SnippetExpansion.swift`'s
header as well because they are the feature:

1. the `;` sits at a word boundary - start of the run, or after a non-word
   character. `foo;sig` does not expand; `(;sig` does. This is the rule the
   task brief asks for by name;
2. the abbreviation matches a saved trigger **in full**. `;ab` never fires
   inside `;abcdef`, because the candidate word is only read once it has ended;
3. the word is ended by a *printable* terminator - a space or punctuation;
4. the `;` is not itself preceded by another `;`. `;;sig` types it literally.

Matching is case-insensitive, and uniqueness is enforced on the same key at
save time, so two snippets can never answer to one trigger.

**Return and Tab deliberately do not expand.** A global `NSEvent` monitor is
passive - it observes a keystroke, it cannot swallow it - so by the time this
code sees a Return, the app already has it. In a send-on-Return app the message
is gone before an expansion could land, and the expansion would then be typed
into the *next* message. This is the one grammar decision that is about the
mechanism rather than about taste.

The terminator is **re-typed** after the expansion: the captain typed `;sig `
meaning "signature, then a space", and swallowing the space would make every
expansion cost one more keystroke than the trigger it replaced.

### Placeholders

`{{date}}`, `{{time}}`, `{{clipboard}}` and `{{cursor}}`, resolved at expansion
time against an injectable clock. An unrecognised `{{token}}` is left
**verbatim** - a snippet that is itself a template (a Helm values file, a
Mustache fragment) has to survive being expanded. `{{cursor}}` is implemented
as a count of synthetic left-arrows after the paste, so it is real rather than
advisory.

`{{clipboard}}` makes this the app's **fourth** reader of the pasteboard, and
it asks `CredentialVaultClipboard.isConcealed` *before* reading the string, per
AGENTS.md's rule for those - a concealed pasteboard resolves to nothing rather
than putting a vault secret into a snippet. `SnippetExpander.clipboardText`
takes the pasteboard as a parameter purely so the suite can prove that against
a really-marked pasteboard instead of describing it.

### Where a snippet may fire

A per-snippet **Where** field, not one global switch - the mockup's own
judgment call, and it holds up: a `kubectl drain` one-liner should expand in
the Console and nowhere else, and an email signature is the opposite.

- `.consoleOnly` is the **default**, and is what every snippet written before
  this build decodes as. The store predates the feature by a year of shell
  one-liners, and a migration that silently armed `kubectl drain ...` to fire
  into Mail would be the wrong answer to "generalise the store".
- `.systemWide` fires anywhere except the snippet's own exclusions, matched
  case-insensitively against both the frontmost app's bundle identifier and the
  name in the Dock - because the captain types what they see and the system
  knows a reverse-DNS string.

### Permission, the lock, and the master switch

- **One Accessibility grant, not a second integration.** The monitors are the
  same local+global `NSEvent` pair `ShiftGlobalHotkey` and `DictationHotkey`
  use, and the injection calls `DictationEngine.pasteAtCursor` verbatim. There
  is one "Grand Line" entry in System Settings and this feature adds nothing to
  it.
- **Off by default**, and the toggle tears the monitors *down* rather than
  leaving them installed and ignored. Unlike the Dictation toggles the reason
  is not a download - it is that this one watches every keystroke on the
  machine while it is on.
- **GL-09**: `.snippetExpansion` is its own `AppLockedSurface` case. Dictation
  types what the captain is saying now; this types what they saved earlier, and
  against a walk-up threat model that difference is the point - a passer-by who
  types `;sig` gets the captain's data with nothing to say at the microphone.

### Keystroke privacy, stated rather than implied

The monitor sees every key pressed while it is installed; that is what a
system-wide expander is. What the app does with them is bounded: characters go
into a rolling window of at most 32, cleared on every terminator, click, app
switch and non-typing key. Nothing is written to disk, nothing is logged (the
log lines name the *trigger* that fired, never the run that produced it), and
the buffer is dropped entirely when the feature is off. The card on the page
says the honest version of this rather than the marketing one.

---

## Departures from the mockup

1. **The mockup's row count ("28 snippets · 12 expand system-wide") is a real
   derivation now.** The page's subtitle counts snippets that genuinely will
   fire elsewhere - a trigger plus `.systemWide` - rather than counting
   triggers. A Console-only snippet's chip is `.neutral`, not `.good`: GL-14's
   rule applied to a capability rather than to a number.
2. **The mockup's "Exclude: Terminal, 1Password" chip became a real chip well
   in the editor**, matched against the live frontmost app. It is per snippet,
   as drawn.
3. **The clipboard is restored after an expansion**, which the mockup says
   nothing about - a text expander that eats the clipboard on every trigger is
   the kind of thing that gets turned off. The exception is a *concealed*
   pasteboard: re-writing a vault secret as a plain string would strip the
   markers `isConcealed` exists to find and hand it to the clipboard history
   this app also ships, so that one is not restored.

---

## Verification

- `FM_RUN_SNIPPET_EXPANSION_TESTS` - the grammar (a 16-case boundary matrix
  including the brief's own `foo;sig`), the buffer's housekeeping and its
  bound, the table and its case-insensitivity, the placeholders including
  `{{cursor}}` and an unknown token, the concealed-pasteboard refusal against a
  really-marked pasteboard, the policy matrix, GL-01's legacy decode, the key
  event classification, and the whole keystroke -> `SnippetInjection` path
  driven end to end through a real `SnippetExpander` over a real scratch store.
  Pure logic, so it guards CI's **blocking** lane.
- `FM_RUN_SNIPPET_EXPANDER_VIEW_TESTS` - the real Hosts page on its Snippets
  tab in a real `NSWindow`: the card's presence and its *column height*
  (measuring the card's own frame would not do - `NSStackView` leaves a hidden
  arranged subview's last frame on it, so the claim is the stack getting
  shorter), the three status states, the row kickers and scope chips, the
  detail panel's fields, both theme registers, and the editor sheet presented
  the way the app presents it (gotcha (6): `dismiss(_:)` on a controller that
  was only assigned as a window's `contentViewController` throws). In
  `NEEDS_SESSION`.

**Confirmed to catch a regression, not merely to pass.** Three injections, each
reverted afterwards by restoring a copy of the file taken beforehand:

| Injection | What failed |
|---|---|
| Rule 1 removed from `completedTrigger` | 3 boundary cases by name (`foo;sig `, `;;sig `, `a;b;sig `) plus the end-to-end `foo;sig` case |
| `if context.appIsLocked` removed from the policy | 4 cases, including the end-to-end one that drives the real expander rather than the policy function |
| `refreshExpansionPanel` always showing the card | both halves of the visibility case - the `isHidden` claim and the column-height claim |

### What was NOT verified

**The last inch of the injection.** Whether the synthetic backspaces and the
synthetic ⌘V actually land in another application needs a real Accessibility
grant, a real frontmost app and a real HID event tap. This repo's agent shell
has no Accessibility permission and cannot be granted one non-interactively
(AGENTS.md's "Verifying native UI bugs" section), and a CI runner has none
either. The suites assert the *decision* and the exact `SnippetInjection` that
decision produces - every inch of the path up to `CGEvent.post` - and nothing
here fakes the rest.

Two specific things the captain's own use is the only check for:

1. **The 20ms hop between the backspaces and the paste** is a pragmatic
   ordering guard, not a measured constant. The two are separate synthetic
   events into one HID tap and the receiving app drains them on its own run
   loop. If an expansion ever lands with a stray `;sig` fragment in front of
   it, that delay is the dial.
2. **The clipboard restore's own 80ms** has the same status.

Recommended manual check: turn the toggle on, grant access when prompted, save
a `;sig` snippet scoped to Every app, and type `;sig ` in Mail and in a
terminal. Then check the two boundary cases by hand - `foo;sig ` must do
nothing, and `;;sig ` must leave the text alone.
