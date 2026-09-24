# Universal capture and clipboard history (F2, F3)

`fm/grandline-feature-f2-f3-capture-clipboard`.

The captain picked F2 and F3 from `data/grandline-full-review-3/report.md` §8 as
the next two future-feature recommendations to build, right after F1 (the
Notebook, PR #426), and had already reviewed a mockup of each in the published
"Grand Line Futures" artifact.
Both mockups were read before anything was designed, and the arrangement here is
theirs.

They are two distinct features shipped in one PR, not one blended feature.
They share one file between them - the concealed-pasteboard rule - and nothing
else.

---

## F2 - Universal capture

### What it was

⌥Space had shipped in phase 5 of `cockpit-shift-power-features` as a
one-destination capture: an accent-bordered field, a hint line, Return, and a
Shift task.
The report's own finding is that the panel, `ShiftDateParser` and all five
destination stores already existed, so the only missing piece was the routing.

### What it is now

Type once, then pick a destination with a number key: ⌘1 task, ⌘2 sticky, ⌘3
note, ⌘4 credential, ⌘5 code snippet.
Five equal tiles with the chord printed under each, which is the mockup's own
layout and its own stated reason - the chord is learnable by sight, so after a
week the panel is invisible and it is just ⌥Space, type, ⌘1.

### The decisions worth recording

**Return is ⌘1, not a sixth code path.**
The report left the default open.
Return still files a task, exactly as it has since phase 5, because that is the
muscle memory the panel has already taught - a captain who never learns a chord
loses nothing.
⌘1 is its equivalent rather than its replacement: both call the same
`file(to:)`, so the two can never disagree about what the default means.

**The panel owns no store.**
Every write goes through a `CaptureFiler` the shell installs
(`AppShellController.makeCaptureFiler`).
GL-23 is the reason: `CredentialVaultStore` and `StickyBoardStore` cache, so a
second instance is a second source of truth and a second writer to one file, and
the shell is the one place all five destinations are already in scope.
Same "forward, never own" shape `RecentDestinationsController.configure` uses.

**⌘4 hands off rather than writing, and that is deliberate.**
A captured line is a *secret* with no title, category or location, and the vault
can be locked when ⌥Space fires (a locked `CredentialVaultStore.add` refuses
outright).
So ⌘4 navigates to Poneglyph and opens its own Add sheet with the secret field
already filled, and the panel dismisses so it is not floating over the sheet.
`CredentialVaultEditorController` grew a `capturedSecret` parameter for this,
deliberately separate from `editing:` - `existing != nil` is what makes that
sheet say "Edit credential", offer Delete and route its save through
`store.update`, and a captured secret is a new record.

**The pasteboard is a chip, not pre-filled text.**
The brief asked for "pre-fill from the current pasteboard, same as today"; today
had no pre-fill at all, and the mockup the captain reviewed draws the clipboard
as a chip under the field rather than as text already in it.
The mockup won.
A 4KB paste dropped into a 600pt field on every ⌥Space would be hostile, and a
chip is one click away from the same result while staying legible.

**The chip is suppressed for anything Poneglyph copied.**
See the shared rule below.
A capture panel opened twenty seconds after a vault copy never quotes the secret
back at the captain.

**"Ask the crew to file it" is a `ClaudeOneShot` classification.**
`CaptureRouter.classificationPrompt` is shaped the way
`DictationCleanup.prompt(for:vocabulary:)` is - one instruction, an explicit
output contract, no room for prose - because the reply is parsed, not read.
`parseClassification` is tolerant about the shapes a model actually produces (a
wrapping quote pair, a trailing full stop, a different case) and intolerant
about everything else: a prose reply that merely *mentions* a destination
returns nil, because a substring match would file "this is not a task, it is a
note" as a task.
A nil answer files nothing and says so - GL-14's shape applied to a classifier.

**Key handling lives on the root view.**
⌘1-⌘5 arrive while the field editor has focus, and a field editor's
`doCommandBy` never sees a command-modified digit.
`CaptureRootView` overrides `performKeyEquivalent`, which AppKit dispatches down
the content view's own subtree before the responder chain gets a `keyDown` - so
the chords work while typing, which is the only time they are ever pressed.
`ClipboardHistoryRootView` does the same thing for the same reason.

### What was verified

- `FM_RUN_CAPTURE_ROUTER_TESTS` (pure logic, CI's blocking lane): the chord map
  asserted against the report's literal mapping rather than re-derived from
  `allCases`, the shared draft parse against a pinned clock, the derived store
  names including the fallback `CodePreviewStore.sanitize` would otherwise
  swallow, the classifier's prompt and reply parsing, and the concealed
  pasteboard refusal in both directions.
- `FM_RUN_CAPTURE_ROUTER_VIEW_TESTS` (window-backed, `NEEDS_SESSION` with a
  `session-not-window:` marker - the controller builds its own `NSPanel`, which
  `mountsAWindow` cannot see): the five real tiles, real ⌘1-⌘5 key equivalents
  through the real root view, real tile presses, a refusal leaving the typed
  text intact, the crew path in both outcomes, and one real off-screen render
  proving the selected tile's wash reaches the bitmap.
- Injection: removing the chord dispatch fails "⌘1 is handled by the panel" and
  every chord case by name; turning `parseClassification` into a substring match
  fails `"Here you go: task" is not a destination`.

**The render probe's own lesson, measured rather than reasoned.**
`bitmapImageRepForCachingDisplay` returns a rep in *pixels*, not points, and on
a retina machine that is a factor of two - so sampling point coordinates lands
in the top-left quadrant of the panel, which is chrome rather than either tile.
The first version of the "the default tile's wash really paints" check failed
with `delta 0.0000` for exactly that reason, reporting two identical background
pixels and reading like a real colour bug.
Scale by `rep.pixelsWide / bounds.width` before sampling.
This is the same class of trap as AGENTS.md's existing `rep.colorSpace` rule and
sits beside it.

---

## F3 - Clipboard history

### What it is

A local, encrypted, 200-item clipboard history with a ⌘⇧V picker, pinned items
that survive the rolling eviction, and automatic exclusion of anything Poneglyph
copied.

### The decisions worth recording

**The exclusion is the feature.**
A clipboard history is, by construction, a plaintext-shaped archive of
everything the captain has copied - which on this machine includes the contents
of a credential vault.
So the rule that matters most is the one that *refuses* to record, and it is
deliberately not written twice: `CredentialVaultClipboard.isConcealed(_:)` is
the app's one definition of "this is a secret", and both this store and F2's
capture panel ask it.
`record(from:)` checks it before it has read the string at all, which is what
makes "a vault secret never reaches this store" a property of the control flow
rather than of a later filter somebody could reorder.

**Any one marker is enough, not all three.**
`CredentialVaultClipboard` writes `org.nspasteboard.ConcealedType`,
`org.nspasteboard.TransientType` and `com.apple.is-sensitive` together, but the
point of honouring the nspasteboard.org convention is to honour it for *other*
apps' writes too - a password manager that writes only `ConcealedType` is saying
the same thing, and a history that demanded all three would record its secrets.

**The refusal is recorded, not hidden.**
The mockup draws the skipped entry as a visible row ("not recorded - copied from
Poneglyph"), and its note says why: a history that silently omits vault copies
looks broken the first time you go looking for one.
So a refusal appends a `skipped` marker carrying **no text at all** - only the
time and the reason - which is the whole point, since there is nothing in the
file to leak.
Consecutive refusals collapse into one marker rather than stacking, because a
vault copy plus its own auto-clear moves the change count more than once.

**Keychain, not the vault key.**
The report offered either.
The vault key exists only while Poneglyph is unlocked, so a history sealed with
it could not be recorded to, or read back, at any other time - and ⌘⇧V has to
work whether or not the captain has typed their master password today.
What this does *not* do is invent a second crypto: the key is 32 random bytes in
the Keychain (`ThisDeviceOnly`, never iCloud-synced, no biometry), rebuilt into
a `CredentialVaultKey` and sealed through the same `CredentialVaultCrypto.seal`/
`open` AES-GCM-256 pair the vault itself uses, under its own HKDF purpose.
No Touch ID, unlike `CredentialVaultKeyStore`: a biometric prompt on every ⌘⇧V
and on every recorded copy would make the feature unusable, and what the
encryption buys is that the file on disk, in a backup or in a synced folder is
not a plaintext transcript.

**One pasteboard watcher, not a second one.**
`CredentialVaultClipboard` already owned the only `changeCount` logic in this
app (its auto-clear guard).
Rather than adding a second timer reading the same counter, that class now
exposes `observeChanges(_:)` and runs one shared tick both the auto-clear
countdown and this store feed off.
A pasteboard change carries no notification of any kind on macOS - polling is
the only mechanism there is, which is why every clipboard manager on this
platform does it.

**GL-13, honestly.**
The watch is *gated*, never stopped: a clipboard history whose whole value is
catching what you copied in another app cannot stop when this app is not
frontmost - that is precisely when the interesting copies happen.
0.75s while the app is in use, 3s once `AppActivityState` says it has been
parked for five minutes.
`changeCount` is monotonic, so a longer gap delays a capture rather than missing
one.
The cadence is re-checked on the tick rather than through an observer, so it
cannot get stuck in the paused state a cancelled timer could - `ShiftGitSync`'s
own reasoning.

**`startCapturing()` is called explicitly from `main.swift`, never at init.**
A dozen self-test suites construct a real `DaylightBarController`, and a
controller that armed a pasteboard watch in its own initialiser would have every
one of them quietly recording the captain's real clipboard for the length of a
run.

**The picker is `HelmBarPanel`'s third consumer**, beside Recents and the bell,
with `HelmAccentRow` rows - the entry's preview as the title, its time and
source as the meta line, and the ⌘-digit as the chip.
The report asks for that chrome by name, and it brings the window-owned shadow,
the outside-click monitor pair and the lock registration with it.

**Three states, drawn differently** (GL-14): *empty* (nothing copied yet),
*unavailable* (the Keychain would not give up the key - never rendered as "0
items"), and the *skipped* row.
GL-01's pair is honoured too: a file that exists but will not open is backed up
before the next write and reported as a failure, not read as an empty history.

**⌘⇧V was checked free**, not assumed: the Edit menu's Paste is ⌘V and nothing
claimed ⇧⌘V.
`NavigationCoherenceSelfTest` enforces that for every chord in this app, because
AppKit resolves a chord to the first *enabled* match in menu order and a
duplicate silently makes one of the two items permanently dead.

**⌘⇧V has its own `AppLockedSurface` case.**
Not `.unifiedSearch`'s, per `AppLockGate`'s own header rule and for the concrete
reason audit §5.2 records: a suite asserting the palette is gated would pass
just as happily with this panel's gate deleted.
Recording is gated too, not only opening - otherwise walking away from a locked
Mac and copying on it would still fill the history.

### What was verified

- `FM_RUN_CLIPBOARD_HISTORY_TESTS` (pure logic, CI's blocking lane): the
  Poneglyph exclusion proved in both directions and per-marker, the marker's
  emptiness and its collapse, dedup-by-promotion, the size cap at its exact
  boundary, the 200-item eviction, pins surviving it *and* an unpin returning an
  entry to the window, the sealed round trip with a plaintext grep of the bytes
  on disk, GL-01's unreadable-file state and its backup, GL-14's no-key state,
  the filter's refusal to surface a skipped marker, and the shared watch's
  registration and fan-out.
- `FM_RUN_CLIPBOARD_HISTORY_VIEW_TESTS` (window-backed, `NEEDS_SESSION` with a
  `session-not-window:` marker - `HelmBarPanel` builds the `NSPanel`): the real
  rows and their order, the skipped row drawn and inert (with the ordinary row
  next to it proving the fixture can paste at all), ⌘1-⌘9 including a digit past
  the end falling through, ⌘P toggling, the filter, the empty/unavailable split,
  the lock gate, and a real off-screen render in both registers.
- Injection: deleting the concealment check fails eleven cases by name, starting
  with "a Poneglyph copy is refused"; making `prune` ignore pins fails "a pinned
  entry survives 250 newer copies"; making the skipped row clickable fails "the
  marker pastes nothing".
- Full suite before and after: 170 passed, 0 failed, 1 skipped.

### What was not done

- **The history is not searchable from ⌘K.** It is a transient convenience
  cache, and putting everything the captain has ever copied into the unified
  search index is a disclosure decision the report did not ask for.
- **⌘⇧V is an in-app chord, not a global hotkey.** ⌥Space is global because
  capture is explicitly a "from anywhere" verb; pasting is something you do in
  the app you are typing in, and a global picker would need the Accessibility
  permission plus a synthetic ⌘V into another app's text field, which is a
  larger and much less reversible piece of work than the report's M scope.
- **No "paste as plain text" variant.** The mockup's footer names ⌘↩ for it;
  every entry this store holds *is* plain text, so the two would do the same
  thing and the second chord would be a lie.

---

## The capture chord: global for real, and the captain's to choose

`fm/grandline-capture-global-hotkey-configurable`.

The captain reported that ⌥Space opened the capture panel only while Grand Line
itself was frontmost.
It did nothing from Chrome, which is the one case a global hotkey exists for.
He asked for two things: make it work from anywhere, the way Dictation's
hold-to-record shortcut already does, and make the chord configurable with
⌥Space as the default rather than the definition.

The configurable half follows Dictation's own evolution exactly - phase 1 a
fixed combo, phase 2 a real recorder over `KeyChord` - and
[`16-dictation.md`](16-dictation.md) is where that precedent is written down.
Nothing about it is restated here.

### What was measured before anything was changed

Three candidate causes, checked in the order the brief set them, against the
captain's own running instance rather than against a fresh build.

- **Accessibility trust is granted.** A read-only `lldb` attach to the running
  packaged app (the technique `fm/grandline-live-gap-rootcause-scout`
  established, and the same read-only shape) evaluated `AXIsProcessTrusted()`
  and got `true`.
  So the global monitor was not silently unarmed for want of the grant, and the
  trust story - the first thing everyone suspects - was eliminated rather than
  assumed.
  Worth recording for the next investigation: the packaged app is re-signed on
  every build with a local dev certificate, and the grant survived that.
  `TCC.db`'s own mtime was five and a half hours *older* than the running
  binary's signing time, so nobody had re-granted it after the rebuild either.
- **Nothing else on the machine claims ⌥Space.** No
  `com.apple.symbolichotkeys` entry binds keycode 49 with the Option flag alone
  (the two nearby entries are ⌃Space and ⌃⌥Space, the input-source switches),
  no launcher utility is installed, and Secure Event Input was off - which
  matters because secure input blocks global key events while leaving
  `.flagsChanged` alone, and would have produced exactly this asymmetry.
- **That left the predicate, and it was genuinely divergent.**
  `ShiftGlobalHotkey.matches` was the one hotkey in the app that never adopted
  `KeyChord.relevantModifierMask`:

      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.option]

  `.deviceIndependentFlagsMask` is `0xFFFF0000`.
  It carries Caps Lock, Fn, the numeric-pad flag and the help flag alongside
  ⌘⌥⌃⇧, and the comparison is an exact equality - so **any** ambient flag
  riding along on the event makes it false and the chord stops matching, with
  nothing logged and nothing to see.
  `KeyChord`'s own header already writes down why that mask is the wrong one,
  in as many words, and `DictationHotkey` - the one global hotkey here that
  demonstrably fires from any app - has always masked with
  `relevantModifierMask` instead.

### Why "it works when Grand Line is frontmost" proved nothing

The Shift menu carries a ⌥Space key equivalent of its own, added deliberately
as the fallback for a captain who has not granted Accessibility.
So the frontmost case has two independent implementations, and a predicate
defect that kills both monitors still leaves the panel opening from the menu
bar - which is precisely the shape the report described.
Any future "the hotkey half-works" report should establish *which* of the two
paths fired before concluding anything about the other.

### What was not verified, plainly

Nobody reproduced a real global ⌥Space keystroke being delivered to, or
withheld from, this process.
That needs a live keypress while a different app is frontmost, and this repo's
agent shell has no Accessibility permission of its own.
The only way to get one would have been to inject an event source into the
captain's own running app, which is well beyond the read-only attach the
convention sanctions and was declined.
The predicate defect is proven from the code and from `KeyChord`'s own
documented rule; that it is the *whole* of what the captain saw is inference,
and is recorded as inference.
The last-mile check - press the chord from Chrome, watch the panel open - is
the captain's.

### What changed

- **`ShiftGlobalHotkey` now matches through `KeyChord`.** One definition of
  "does this event mean this chord", shared with Dictation and the terminal
  bindings, instead of three hand-written predicates drifting apart.
- **It handles both event shapes**, following `DictationHotkey`'s established
  design rather than inventing a second one: a modifier-only chord on
  `.flagsChanged`, a regular key on `.keyDown`, and only the pair the current
  chord needs installed. A capture trigger is a press rather than a hold, so a
  modifier-only chord fires on the down edge only.
- **`start()` is idempotent and `updateShortcut(_:)` exists.** The shipped
  version installed a second monitor pair over the first, so a second `start()`
  leaked the originals and the panel would have opened twice per press.
- **`reassertIfTrustChanged()`, called on app activation.** Launch requests
  Accessibility and installs the monitors in the same breath, so a captain
  granting it in the System Settings pane that prompt opens is granting it
  *after* the global monitor exists - and macOS does not arm an
  already-registered global monitor retroactively. The cure used to be
  relaunching, and nothing said so. The check is one `AXIsProcessTrusted()`
  read and declines unless the answer actually changed.
- **Settings > Capture**, a new page under Personalize: the recorder (at
  `KeyChordRecorderView.Mode.command`, so a bare `Space` or a bare modifier is
  refused while recording rather than after - either would fire constantly in
  every app on the machine), and a row stating whether Accessibility is
  granted. That second row exists because diagnosing this needed a debugger to
  answer a question the app should have been able to answer out loud.
- **The Shift menu's Capture item follows the recorded chord**, so a page can
  never advertise a shortcut the app no longer listens for. A modifier-only
  chord has no menu representation, so the item keeps its title and drops its
  accelerator rather than printing something wrong.
- **`CompactModeHotkey` had inherited the same defect** - it was shaped on
  `ShiftGlobalHotkey` and copied the mask - so ⌃⌥G was equally dead under an
  ambient flag. Fixed in the same pass, with its own Caps Lock case.

### Verified

- `ShiftGlobalHotkeySelfTest` (`FM_RUN_QUICK_CAPTURE_HOTKEY_TESTS=1`), pure
  logic, so it guards the blocking CI lane. Ten cases over the predicate, the
  two event shapes, the monitor-installation structure and the menu mapping.
  Each fixture asserts its own discriminating power first - a bare `Space` must
  be *refused* before "⌥Space matches" means anything.
- Injection 1, the reported bug: restoring the `.deviceIndependentFlagsMask`
  predicate fails exactly the three ambient-flag cases by name ("Caps Lock
  being on must not stop ⌥Space matching", Fn, numeric-pad) and nothing else,
  which is also the honest measure of how narrow the fix is.
- Injection 2, the structural half: deleting the
  `NSEvent.addGlobalMonitorForEvents` registration fails "start() must install
  a GLOBAL keyDown monitor" plus two more. Every predicate case stays green
  through it, which is the whole reason those structural checks exist - the
  same gap `DictationHotkeySelfTest`'s own tests 10-12 closed for Dictation.
