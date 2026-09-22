# App Intents, and a `.glbackup` that carries everything

F21 and F24 of full review #3 §8, built together on
`fm/grandline-feature-f21-f24-intents-import-export` because they share one
surface - the Settings page - and, as it turned out, one missing mechanism.

- **F21 (Scope M).** Expose New Task, New Note, Start Timer, Copy Credential
  and Ask Crew as App Intents so Siri, Shortcuts, Spotlight and Raycast can
  drive the app without it being frontmost.
- **F24 (Scope S).** The bundle covers hosts, snippets, keys and dictation.
  Extend it to tasks, notes, stickies, code snippets and the vault
  (encrypted), so moving to a new Mac is one file.

Both shipped in one PR. The scoping note the brief allowed for ("ship F24
first if the combined PR gets too large") was not needed: the two features
turned out to want the same registry, and splitting them would have meant
building it twice or landing it half-wired.

---

## The mechanism they share: `GrandLineServices`

Neither feature could reach the stores it needed, for opposite reasons.

An App Intent's `perform()` runs with no view controller, no window, and no
injected dependencies - the system may have launched the app for it. It still
has to write into the *same* `ShiftStore` the Tasks page is showing, because
that store caches its active tasks: a second instance would write a task the
open page never sees, and lose it on that page's next save. GL-23, exactly.

Settings' Backup card has the inverse problem. `SettingsController` is built in
`main.swift` with four stores; the five new F24 sections live under roots owned
by `AppShellController`. Passing four more stores down that constructor would
wire a page to stores it has no other reason to know, and re-deriving the roots
in the backup code would have grown a second copy of the `FM_*`-override
resolution every store already owns - the `CommandLibraryStore` mistake AGENTS.md
records, repeated on purpose.

So `GrandLineServices` is a **registry, not a factory**. `AppShellController.init`
hands it the instances it has just built; callers that ask before that get `nil`
and degrade honestly (an intent fired at a half-launched app says "Grand Line is
still starting up"). Every reference is `weak`, so the registry can never be the
reason a store outlives the shell.

**The one thing it does create is the vault**, and that was a real change rather
than a convenience. `CredentialVaultStore` used to be constructed inside
`CredentialVaultController`, which means unlock state lived on a destination
that mounts lazily (GL-37) and did not exist until the captain first opened
Poneglyph. Copy Credential needs *that* store - the unlocked one - so the store
moved to the registry and the controller now asks for it. Still exactly one
instance, still created on first use rather than at launch (GL-12).

---

## F21: what was built, and what was deliberately not

### The split

`GrandLineIntentActions.swift` holds five plain functions over injected stores.
`GrandLineAppIntents.swift` holds five `AppIntent` types that are each a
parameter list plus one call into the first file.

The split is not tidiness. An `AppIntent`'s `perform()` is a method on a type
the system instantiates with parameters the system filled in - which is exactly
the shape nothing in this project can drive from a self-test, since there is no
XCTest here and no App Intents runtime in a headless process. Everything worth
asserting lives in the first file, takes its dependencies as arguments, and is
covered without a Shortcuts installation or a fingerprint.

### Copy Credential is guarded, and that is a narrowing of the report

The report said "looks up a Poneglyph vault credential by name and copies it to
the clipboard". The mockup drew it **guarded** and said why; this implementation
follows the mockup.

**The intent returns nothing.** Not a `ReturnsValue<String>`, not an
`IntentFile` - only a dialog saying which credential was copied. An intent that
handed a vault value back as a shortcut variable would make every shortcut on
the machine a vault exfiltration tool: one *Get Credential* plus one *Send
Message*, with the captain's own Touch ID prompt as the only speed bump, once.
Putting the value on the pasteboard through `CredentialVaultClipboard` keeps it
inside the mechanisms that already exist to protect it - the
`org.nspasteboard.ConcealedType` markers, the clipboard-history exclusion that
reads them, and the automatic clear.

**Three gates, in this order, and the order is load-bearing:**

1. `AppLockGate.shared.allows(.appIntentCopyCredential)`.
2. The vault's own lock. A locked vault is unlocked through
   `unlockWithTouchID` - the same call the unlock screen makes, with the same
   throttle and the same Keychain-held key - or refused. When the captain has
   turned Touch ID unlock off, it is refused outright and **no unlock is even
   attempted**: an Intent has nowhere to type a master password, and putting a
   credential prompt up on behalf of something that is not the captain is not a
   door this app opens.
3. The credential's own `requiresTouchIDToReveal`.

The credential is only *looked up* after step 2 passes. That is the part worth
stating: a lookup-then-unlock ordering would let a locked vault be probed for
which titles exist, through the difference between "not found" and "vault
locked". `AppIntentActionsSelfTest` asserts a real name and an invented one
produce the same answer while locked.

**One deliberate divergence from the vault page.** With no biometry on the Mac,
`CredentialVaultController.gateForReveal` proceeds with a toast - reasonably,
since the master password has already been typed and the item would otherwise
be unreachable. The Intent refuses instead. An Intent may be running with nobody
at the keyboard, which is the exact circumstance the per-item gate exists for,
and there is no window to put a toast in.

### The other four

- **New Task.** Title required; notes, due date, priority and project optional.
  The due date goes through `ShiftDateParser`, so "friday 3pm" works from Siri
  exactly as it does from ⌥Space. An unparsed phrase leaves the due date unset
  rather than failing the call - a task with no due date is recoverable in two
  seconds, a task that was never created is not. The same reasoning applies to
  an unmatched project name.
- **New Note.** Appends to a Notebook page; with no page named it lands on
  today's daily note. It **appends, never replaces**, because a voice command
  that can overwrite a page of the captain's own writing is one that eventually
  does. It re-reads the page before appending rather than trusting the listing
  it matched against, or an editor save landing in between would be dropped.
- **Start Focus Timer.** Matches a task exact-first, then unique prefix, then
  unique substring; an ambiguous query asks rather than picking, because
  starting a timer on the wrong task silently logs twenty-five minutes against
  work nobody did. With no query it takes the task due soonest. Minutes are
  clamped to 1–240 rather than refused.
- **Ask the Crew.** One prompt, a fresh `StrawHatRunner`, the reply as text. A
  fresh runner deliberately: an intent is a question from outside the app, not a
  turn in the conversation the captain has open, and threading it in would put
  words in a transcript they are reading.

### Five `AppLockedSurface` cases, not one

`appIntentNewTask`, `appIntentNewNote`, `appIntentStartTimer`,
`appIntentCopyCredential`, `appIntentAskCrew`. This is the most pointed
application of that file's own header rule so far: these are the app's first
entry points that need no window at all, they differ enormously in what they
expose, and a shared case would let Copy Credential lose its gate while a test
asserting New Task is gated carried on passing.

`appIntentAskCrew` is a second gate over `StrawHatRunner.ask`'s own
`.strawHatChat` check, on purpose - without it the shared case would be the only
thing between a locked machine and a shortcut shipping the captain's context to
a subprocess.

### Registration, and the Xcode question

This is the part of F21 that is not code, and it was the real risk.

The five types compile into the binary with a plain `swift build`, but Shortcuts
discovers them from a `Metadata.appintents` bundle produced by Xcode's
`appintentsmetadataprocessor`. SwiftPM never runs it. AGENTS.md's "Build, run,
test" is explicit that this project builds with Command Line Tools and never
Xcode.

Both stay true, because this is a **packaging** step and not a build one.
`native/build_native_app.sh` looks for the processor; when it is there, the
release build gains two swiftc flags (`-emit-const-values` plus a
`-const-gather-protocols-file` naming the App Intents protocols - Xcode ships no
such file, so it is written into a temp dir) and the processor runs against the
resulting `.swiftconstvalues`. When it is not there, the build command is
byte-for-byte what it always was and the script says out loud what is missing.

Two things cost time here and are worth recording:

- **`-Xfrontend` forwards exactly one following argument.** The flag and its
  value each need their own `-Xswiftc -Xfrontend` pair. Getting it wrong makes
  SwiftPM treat the JSON as an input source file, with an `unexpected input
  file` error that names the JSON and explains nothing.
- **Without const values the processor succeeds and produces nothing**, logging
  "Extracted no relevant App Intents symbols, skipping writing output" and
  exiting 0. A packaging step that trusted the exit code would have shipped an
  app with no actions and reported success.

Verified on this machine: all five intents and their spoken phrases appear in
the generated `extract.actionsdata`.

**The Settings card says which of the two states the running copy is in** - it
reads `Contents/Resources/Metadata.appintents` and reports honestly, rather than
listing five actions a given build may not publish. GL-14, applied to the app's
own packaging.

### Why the Settings card has no toggles

The mockup drew five switches, all on. There is nothing to toggle: an App Intent
is published by the bundle's metadata, so a per-intent switch would either do
nothing or - worse - read as a security boundary while the real ones (the app
lock, the vault's lock, the per-credential gate) sit elsewhere. The card lists
what each action takes, chips Copy Credential as **guarded**, and states the
registration status. That is the information the mockup's toggles were standing
in for.

---

## F24: what goes in the bundle

### File trees, not models

The four original sections re-serialise decoded models. Every store added since
is a directory of text files with a `root: URL` and an `init(root:)` seam, and
re-serialising those through their models walks straight into the GL-01 failure
with no symptom that AGENTS.md describes: a whole-file rewrite built from
decoded values can only write the fields *this* build knows, so a record
carrying one extra key from a newer build loses it on the very next write -
across a restore whose entire purpose is two machines on two builds.

Carrying bytes verbatim cannot do that, and it is also the only shape that
round-trips a task's PNG attachment, a sticky's passthrough keys and Code
Preview's tab-order file without the backup code knowing any of them exist. The
price is a per-file diff rather than a per-record one.

### The vault is sealed, not exported

`vault.enc.json` is already the encrypted form, so the vault section is those
bytes, copied. Never decrypted, never re-wrapped, never re-encrypted under an
export password of its own - which would mean holding plaintext secrets in
memory for the length of an export, for no gain over the encryption the file
already carries. The credential *count* comes out of the envelope, which is
plaintext; the payloads are not.

Two consequences, both stated in the UI rather than left to be discovered:

- The restored vault needs the **master password it had on the old machine**.
  Touch ID does not travel - `CredentialVaultKeyStore` holds that key
  `ThisDeviceOnly` in this Mac's Keychain, deliberately, and a backup that
  carried it would be the backdoor GL-25 exists to prevent.
- **A restore never merges two vaults.** Merging encrypted records needs both
  keys, and a backup import is not a place to ask for two master passwords. An
  import onto a machine that already has a *different* vault is refused by
  default and needs its own `DestructiveConfirm` - separate from the import
  confirm, because that one is a preview of an additive merge and this one is
  the only action in the file that destroys something irreplaceable.

An undecodable vault file still travels (it is still the captain's vault, and a
"full move" that left the one irreplaceable store behind would be worse), with
its credential count carried as `-1` and rendered as "an unknown number"
rather than a confident zero.

### A merge, never an overwrite

New and changed files are written, unchanged ones skipped, and a file that
exists only on the target Mac is listed in the preview and left exactly where it
is. Nothing in the apply path deletes anything. GL-21's other half is
`BackupFileArchive.unreadable`: a root that does not exist yet is genuinely
empty (a captain who never opened the Notebook has no notebook directory), and a
root that refuses to enumerate is unknown - and an unknown section applies
nothing rather than being read as "the captain had nothing here".

### Path validation runs on both sides

On export it stops a stray absolute path or symlink from smuggling something out
of the store root. On import it is the load-bearing half: a `.glbackup` arrives
from another machine, which is GL-08's whole lesson, and a section entry
claiming `../../../.ssh/authorized_keys` would otherwise be written there.

### The format version went 1 → 2

A deliberate exception to `BackupData.swift`'s own "an optional field needs no
bump" rule. That rule is about a new build reading an old bundle, which still
works and is asserted. The bump is about the other direction: an older build
handed a v2 bundle would decode it happily, ignore five sections it has never
heard of, and report a successful import of a file carrying the captain's entire
task history and vault. A silent partial restore is GL-14 wearing a different
hat, and "update the app and try again" is the honest answer.

### Caps

Per section: 5000 files, 48MB. Per file: 8MB. A file over the per-file cap is
skipped and the section is flagged `truncated`, which reaches the export summary
and the import preview in words (GL-35 plus GL-14 - nothing unbounded, and
nothing silently trimmed).

### The Settings card

Rewritten from one counts line into the mockup's inventory: a row per store with
what travels with it and a real measured size, the vault chipped **sealed**, and
- the row that matters most, per the mockup's own closing note - terminal
scrollback and session state as a *visible excluded row* rather than an
omission. A one-file move is only trustworthy if you can see what it left
behind.

The measurement walks four directories, so it runs off the main thread
(`BackupFileArchiveBuilder.measure`, metadata only - no read, no base64). Until
it lands, rows read "Measuring…" rather than zero.

**The excluded row's trailing control is a muted label, not a chip.** Every pill
on that page goes through `HelmContrast.tintedSurface`, and AGENTS.md's colour
rules are explicit that washing a no-identity hue that way produces a near-black
chip - which would make the heaviest thing on the card the one row that is *not*
in the bundle.

---

## Verification

Three suites, each confirmed to catch a real regression rather than merely to
pass. Injections were made by copying the file aside and editing it - never
`git stash`, never `git checkout -- <file>` on a branch with no commits yet.

**`FM_RUN_APP_INTENT_ACTIONS_TESTS`** (pure logic). Parameter handling for all
five actions, both matchers, and the Copy Credential ladder driven through
injected seams - vault locked, Touch ID disabled, Touch ID failed, throttled,
unreadable, stale key, no vault, per-item gate declined, no biometry at all.
Every locked case asserts that **nothing was copied**, which is a different
claim from "an error was returned".

- Injection 1: route a locked vault straight to the copy path and drop the
  re-check inside it. **9 named cases failed**, including "a locked vault
  answers identically for a real and an invented name - the lock is not an
  oracle".
- Injection 2: remove the `AppLockGate` call from `copyCredential`. Both halves
  fired - the source guard ("the action for .appIntentCopyCredential consults
  the lock gate through its own case", "exactly five lock-gate calls") and the
  behavioural one ("Copy Credential refuses while the app is locked, even with
  an unlocked vault" / "and copies nothing"). Each catches what the other
  cannot, which is why both are there.

**`FM_RUN_BACKUP_STORES_TESTS`** (pure logic). Archive, diff, apply, the sealed
vault's full round trip - including building a *real* encrypted vault, exporting
it, restoring it into a fresh root and unlocking it with the original master
password to read the same secret back.

- Injection 3: drop path validation from the import diff and apply. Three cases
  failed, including "nothing was written outside the store root".
- Injection 4: make an unlistable root return an empty archive. "a root that
  cannot be listed is flagged unreadable, not empty" and "the two states are
  genuinely distinguishable - the whole point of GL-21".
- Injection 5: make `applyVault` ignore `allowReplace`. "a replacing vault is
  refused without an explicit confirm" and "and the existing vault is still
  byte-for-byte on disk afterwards".

**`FM_RUN_INTENTS_BACKUP_VIEW_TESTS`** (window-backed, in `NEEDS_SESSION`).
Mounts a real `SettingsController` and reads both cards out of the live
hierarchy; resizes the window to 1512 and back to 820 against gotcha (13).

- Injection 6: drop `alignsTrailingToEdge` from the intent rows. "every row's
  trailing control shares one right edge - **spread 175.5pt**", which is gotcha
  (10) rendered as a number.

Two things found while building that suite, both real:

- The first version of the trailing-column walker matched any two-subview
  horizontal stack, which caught the *card header* and reported a 12pt spread
  that had nothing to do with the rows. Scoped to `HoverHighlightView`, the real
  spread is 2.0pt - the four `NSTextField` trailings land exactly on the row
  edge and the one layer-backed pill sits 2pt inside it, because its width comes
  from its label's intrinsic size plus fixed padding. The tolerance is 4pt, which
  accepts that and nothing structural.
- The vault row's assertion was originally written against text that only
  appears when a vault exists. In a suite that mounts Settings alone,
  `GrandLineServices` has no registered stores, so the row correctly reads "Not
  available until the app has finished starting up" - which is the GL-14 state,
  and is now what the suite asserts.

**Full suite**: 186 passed / 0 failed before the branch; 189 passed / 0 failed
after (the three new suites), on a tree with `fm.themeID` at `dusk` and no
sibling run in flight.

## What was not verified

- **No real Siri or Shortcuts invocation.** The metadata bundle was generated
  and inspected - all five intents and their phrases are in
  `extract.actionsdata` - but nothing here drove an intent from the Shortcuts
  app, and this sandbox cannot. The captain's own check is to build the app on
  this machine and look for "Manjesh Grand Line" in Shortcuts.
- **No real Touch ID.** Every biometric path is driven through
  `IntentBiometricChallenge`'s injected seam. `LAContextFactory` is the
  production value and is the same one `CredentialVaultController` already uses.
- **No screenshot.** The two cards were verified by reading strings and frames
  out of a real mounted hierarchy in a real off-screen window, per AGENTS.md's
  "Verifying native UI bugs without a real screenshot". That is evidence from
  AppKit's own layout engine, not a visual check.
- **Nothing was exported or restored against the captain's real data.** Every
  suite runs against scratch roots.
