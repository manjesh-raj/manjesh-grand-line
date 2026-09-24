# The rename to "Grand Line"

`fm/grandline-rename-firstmate-cockpit-to-grand-line`.

The app had three names at once.
The Swift module and the shipped executable were `FirstmateCockpit`, the bundle identifier was `com.firstmate.cockpit.native`, the local signing identity was "Firstmate Cockpit Local Dev", and the display name - the one the captain actually reads, in the menu bar, in the window title and in System Settings - was "Manjesh Grand Line".
None of that was deliberate.
The display name was rebranded once (`cockpit-rebrand-grand-line`) and every identifier was left alone on purpose, because changing one of them invalidates the captain's saved Keychain items.
[`09-setup-updates-bootstrap.md`](09-setup-updates-bootstrap.md) still records that decision and the reasoning behind it; this file is what supersedes it.

The captain asked for one name, everywhere, in one pass: plain **"Grand Line"**, not "Manjesh Grand Line".

## What changed

| Was | Is |
|---|---|
| Display name "Manjesh Grand Line" | "Grand Line" |
| Swift module / executable `FirstmateCockpit` | `GrandLine` |
| `native/Sources/FirstmateCockpit/` | `native/Sources/GrandLine/` |
| `.build/debug/FirstmateCockpit` | `.build/debug/GrandLine` |
| `dist/Manjesh Grand Line.app` | `dist/Grand Line.app` |
| Bundle id `com.firstmate.cockpit.native` | `com.manjesh.grandline.native` |
| App Group `group.com.firstmate.cockpit.native` | `group.com.manjesh.grandline.native` |
| Signing identity "Firstmate Cockpit Local Dev" | "Grand Line Local Dev" |
| `~/Library/Application Support/FirstmateCockpit/` | `~/Library/Application Support/GrandLine/` |
| Unbundled `UserDefaults` domain `FirstmateCockpit` | `GrandLine` |
| `os.Logger` subsystem `com.firstmate.cockpit.native` | `com.manjesh.grandline.native` |

Everything derived from the old identifier moved with it, by prefix: the five Keychain service names, the dispatch-queue labels, the two private pasteboard types, the widget notification category identifiers.
Under `native/Vendor/` only the files this project wrote itself changed - the four vendoring READMEs, the three web-side entry points we author for Excalidraw and Monaco, and the locally-added `SwiftTerm/Dimming.swift`, whose header comment names the product. No upstream file was touched, and `FM_RUN_VENDORED_PATCHES_TESTS` matches on code symbols rather than on those comments, so the six-patch check is unaffected.

### Why `com.manjesh.grandline.native`

The old string was `com.<vendor>.<product>.<surface>`.
The new one keeps that shape rather than inventing a second one, so every identifier derived from it - `.sshkey`, `.native.credential-vault`, `.widgets`, `.subprocess.stdin` - is a prefix swap and nothing else.
`grandline` is one lowercase word for the same reason every other segment is: a dotted reverse-DNS identifier with a hyphen in the middle of a segment reads as a mistake.

## The four things macOS attaches real state to

A bundle identifier is not just a string this app chooses.
Four separate pieces of the captain's own state are keyed to it or to the module name, and each needed its own answer.
Three of them could be migrated; the fourth cannot be, by design.

### 1. The Keychain - migrated, copying rather than moving

Five stores keep a secret as a generic password scoped to a service name built from the old identifier:

| Store | Service (new) | What it holds |
|---|---|---|
| `KeychainKeyStore` | `com.manjesh.grandline.sshkey` | the saved SSH private keys and their passphrases |
| `ClipboardHistoryStore` | `com.manjesh.grandline.clipboard-history` | the key the encrypted clipboard history is sealed with |
| `CredentialVaultKeyStore` | `com.manjesh.grandline.native.credential-vault` | Poneglyph's master key wrap |
| `GoogleAccount` | `com.manjesh.grandline.native.google-oauth` | both Google slots' refresh tokens and metadata |
| `GoogleOAuth` | `com.manjesh.grandline.native.google-oauth-client` | the captain's OAuth client id and secret |

Change the string and none of those items is deleted - they simply stop being visible to the app, orphaned under a service name nothing reads any more.
`LegacyNameMigration.migrateKeychain()` runs once at launch and **copies** each item from the old service name to the new one, skipping any account that is already there.
It deliberately leaves the original in place: a copy is reversible and a delete is not, and the captain can clear the old service names by hand once the new ones are confirmed working.

Every item this app writes is a plain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` generic password with no `SecAccessControl` ACL (`KeychainKeyStore`'s header says why this build cannot hold one), which is what makes the copy possible without a Touch ID prompt of its own.

The service list lives in one place, in `LegacyNameMigration.keychainServices`, and `LegacyRenameMigrationSelfTest.checkEveryKeychainServiceIsListed` greps the app's own sources for `static let service = "com.manjesh.grandline…"` literals and fails the run when a sixth store appears without joining it.
Three of the five hold their service name `private`, so the grep is the only thing that can see this.

### 2. The Application Support folder - migrated, moving rather than copying

Roughly twenty-five file-backed stores nest under `~/Library/Application Support/<folder>`, and that folder is named after the Swift module.
`LegacyNameMigration.migrateApplicationSupportFolder` renames it, once, before `SingleInstanceGuard.acquire()` - which is the first line in the process that touches the folder at all.

This half is a **move**, which is the opposite decision from the Keychain half, and for a concrete reason: the folder holds the Whisper models, which run from hundreds of megabytes to several gigabytes.
A copy on the launch path is exactly GL-12's pre-window beachball.
A rename on the same volume is atomic and instant, and the captain can undo it with a single `mv`.

Nothing is ever merged.
When both folders exist - which is what a captain who has already launched the new build once and then run an older build would see - the new one wins, the old one is left exactly as it is, and the run says so through `AppLog.store`.

`AppPaths.applicationSupportFolderName` is now the one definition of that folder name; every store reads it rather than repeating the literal.

### 3. The preference domain - migrated, copying key by key

A bundled app's `UserDefaults` domain is its bundle identifier, so the captain's theme, their text scale, their saved window frame and every toggle in Settings were all sitting under `com.firstmate.cockpit.native`.
Nothing is lost when that changes, but the app comes up in a theme they did not pick, at a window size they did not choose, and reads as a fresh install rather than as their own app.
It is the half a captain *sees* first.

`LegacyNameMigration.migrateDefaults` copies every key the new domain has no value of its own for, then writes `fm.renamedFromFirstmateCockpit` so it never runs again.
That marker is the point: without it, a captain who deliberately clears a setting after the rename gets it handed straight back on the next launch.

The unbundled `swift build` binary has no bundle identifier, so its domain is the executable name - `FirstmateCockpit` before, `GrandLine` now.
`legacyDefaultsDomain()` resolves both cases, which is also why AGENTS.md's long-standing warning about reading the wrong domain still applies, with both names moved on.

### 4. Accessibility and Automation consent - **not** migrated, and cannot be

macOS keys privacy grants to the bundle identifier.
Changing it means the rebuilt app is a brand-new app as far as TCC is concerned, and every grant the captain gave the old one is orphaned.

**This is a manual step and there is no way around it.**
Granting Accessibility or Automation is a user consent action by design: it is not scriptable, `TCC.db` is SIP-protected even to root, and nothing in this change tries to touch it.

After the first rebuild and relaunch, the captain has to:

1. Open **System Settings › Privacy & Security › Accessibility**.
2. Remove the stale "Firstmate Cockpit" / "Manjesh Grand Line" entry if one is still listed.
3. Re-grant to the new **Grand Line** entry.
4. Repeat under **Automation**, and under **Screen Recording** / **Microphone** / **Speech Recognition** / **Calendars** for whichever of those the app has been granted before.

Until Accessibility is re-granted, the three global hotkeys (⌥Space capture, ⌃⌥G compact mode, dictation) have no global monitor.
`ShiftGlobalHotkey.reassertIfTrustChanged()` picks the grant up on the next app activation rather than needing a relaunch - gotcha (21)'s second bullet is why that exists.

### The signing identity, and the one graceful fallback

`build_native_app.sh` and `build-widget-extension.sh` now look for a local self-signed identity named **"Grand Line Local Dev"**, and fall back to the old **"Firstmate Cockpit Local Dev"** when only that one exists, rather than silently dropping to an unsigned build.
An unsigned build gets a new ad-hoc code identity on every rebuild, which is how Keychain ACL trust is lost - the exact failure this rename is otherwise careful to avoid.
`native/README.md`'s "Local signing setup" section has the one-time command to create the new cert; doing that and deleting the old one is the clean end state.

## Verification

- `swift build` warning-clean, and `swift build -c release`, after the module rename.
- `Scripts/build-widget-extension.sh --check` - the extension's bundle id and App Group are derived from the app's own `APP_BUNDLE_ID`, and that derivation was re-checked rather than assumed.
- `Scripts/run-all-tests.sh` in full before the rename and again after, same result.
- `LegacyRenameMigrationSelfTest` (`FM_RUN_LEGACY_RENAME_MIGRATION_TESTS`), pure logic, in CI's blocking lane. It seeds a real Keychain item under a scratch "legacy" service name and proves it is found and copied to the scratch "current" one, asserts the item is genuinely absent beforehand, proves a second run copies nothing, proves an existing item is never overwritten, does the same three ways for the folder move, and drives the preference copy across two scratch `UserDefaults` suites. A machine with no writable login keychain is reported as a loud SKIP rather than a silent pass.
- **Six fault injections, each confirmed to fail the suite by name and then restored**: the Keychain `SecItemAdd` neutered (2 cases fail), the folder move short-circuited to `nothingToMigrate` (4), a pre-rename name reintroduced into `DocsData.swift` (1), a service dropped from `keychainServices` (1), the preference copy skipped (2), and the once-only marker never written (2).
- The same suite carries the standing guard that no app source still spells `com.firstmate.cockpit`, "Firstmate Cockpit" or "Manjesh Grand Line" - which is what stops the rename coming undone one file at a time.

**Not verified**: nothing was launched. This app has no OS-level process isolation between builds, and the bundle identity is precisely what this change moves, so a copy launched from a worktree is the one thing that could genuinely disturb the captain's running instance mid-rename. The first real launch - and the System Settings re-grant above - is the captain's own check.

## Follow-up: the Keychain migration re-prompted on every launch

`fm/grandline-keychain-migration-repeat-prompt-loop`.

After rebuilding and relaunching, the captain hit the macOS "wants to access your confidential information stored in Keychain" dialog repeatedly - clicked "Always Allow" roughly ten times, and it kept coming back.

### Triage, before touching any code

`codesign -dvvv` on both the new `Grand Line.app` and the still-installed pre-rename `Manjesh Grand Line.app` showed the same signing authority, "Firstmate Cockpit Local Dev" - the captain has not yet created the "Grand Line Local Dev" certificate this file's own "Local signing setup" section describes, so `build_native_app.sh` is correctly on its documented fallback. Signing-identity churn across rebuilds (the failure mode the fallback exists to avoid, see above) was ruled out: the identity was stable across both builds.

That pointed at `LegacyNameMigration.runAtLaunch()` instead. `migrateApplicationSupportFolder` is naturally idempotent and `migrateDefaults` is gated behind `defaultsMigratedKey` - but `migrateKeychain()` had **no persisted "already attempted" gate at all**. It re-queried every account under all five legacy services on every single launch, and per `migrateKeychainService`'s own header, each account is read through its own single-item `SecItemCopyMatching(..., kSecReturnData: true)` query - a read of confidential data, which is exactly what macOS asks per-item consent for. A captain with several saved SSH keys (a `.key` and often a `.pass` account each) plus the clipboard-history key, the vault key, and two Google OAuth slots is a real multi-item read pass, ten items being an entirely plausible count for one real profile - but a pass that repeats in full on *every* launch, forever, turns one relaunch into another full barrage instead of zero.

### Confirming it, live

The self-test suite's existing `checkKeychainItemIsCopied` already proved a second call to `migrateKeychainService` copies nothing and counts the item as `alreadyPresent` - but that only proves the *outcome* was already correct, not that the *read* was skipped. What actually causes a dialog is the `kSecReturnData` query itself, issued unconditionally before the "already present" check runs. Two new checks in `LegacyRenameMigrationSelfTest` isolate exactly that: `checkKeychainMigrationGateSkipsOnceComplete` seeds a real (scratch-service-named) legacy item, runs the gated entry point once, then seeds a *second* legacy item and runs it again - before the fix, the second run would have swept the new item up too, proving it genuinely re-queried; `checkKeychainMigrationGateRetriesAFailure` does the same for the failure path with an injected `migrate` closure. Both were confirmed to catch the regression by reverting `migrateKeychainIfNeeded`'s early-return gate and re-running: 4 checks failed by name, restoring the gate made them pass again, `swift build` warning-clean throughout.

### The fix, and the trade-off named explicitly

`LegacyNameMigration.migrateKeychainIfNeeded()` adds a persisted `fm.keychainMigratedFromFirstmateCockpit` flag - but unlike `defaultsMigratedKey`, it is set **only when a pass finishes with zero failures**. A captain who denies one prompt, or hits a transient `SecItemAdd` error, must not have that item silently abandoned forever because the pass was marked "done" regardless of per-item outcome; not latching the flag means the *next* launch retries the whole pass (including a redundant re-read of already-migrated items, which is accepted as the cost of not needing a second, separate per-item completion ledger) until it genuinely finishes clean. Once it does, every later launch skips the Keychain entirely - no query, no dialog, ever again for that install.

### Getting the captain unblocked

Nothing about his prior "Always Allow" clicks is undone by this fix - if those grants took, the items were already migrated and this only stops the needless re-asking; if a click didn't register (or he stopped clicking through), `migrateKeychainIfNeeded` will retry exactly those items on the very next launch after this ships, using the same fixed number of dialogs (at most once per outstanding item, never again after). **He needs one more relaunch** of the rebuilt app; no manual Keychain cleanup is required.

### Verification

- `LegacyRenameMigrationSelfTest` (`FM_RUN_LEGACY_RENAME_MIGRATION_TESTS`), including the two new gate checks, confirmed to fail by name against an injected revert and pass again restored.
- `./Scripts/run-all-tests.sh --ci` and `--session-only`, full suite, before and after: same pass count, no regressions.
- **Not verified**: no real GUI Keychain dialog was driven end to end - this agent's shell has no interactive session to click through, and the fix is provable at the query level (whether `kSecReturnData` is even issued) without needing the dialog itself to fire. The captain's next relaunch is the live confirmation that the dialog stops recurring.

## Follow-up round 2: the same loop, still happening, for a different reason

`fm/grandline-keychain-migration-loop-round2`.

The captain rebuilt with the fix above in (`build_native_app.sh` reported `0.1.0-235-g42a1cbf`, at or after the merge), reinstalled, and hit the exact same dialog - naming the legacy service `com.firstmate.cockpit.sshkey` - repeatedly.
His words: "even after I give correct password and select always allow it keeps happening."
This is a real second root cause, not a restatement of the first one.

### What round 1 actually shipped, read again

The trade-off section above says it plainly, and it is the bug: `keychainMigrationCompleteKey` is set only when a pass finishes with **zero failures across every item in every one of the five services**.
The fix's own verification section even names the cost out loud - "a redundant re-read of already-migrated items... accepted as the cost of not needing a second, separate per-item completion ledger" - and called it acceptable because the working assumption was a one-off captain misclick, not an item that fails in the same way forever.

A captain with even one legacy item that can never succeed - which `com.firstmate.cockpit.sshkey` turns out to be, see below - never gets a clean pass.
`outcome.failures` is never empty, so the flag never latches, so `runAtLaunch()` calls `migrateKeychainService` again on every single launch, which (before this round's fix) unconditionally issued the `kSecReturnData` read for **every** account under **every** legacy service before checking whether the new service already had it.
That includes accounts that had already succeeded and had "Always Allow" already granted for them.
So the captain's repeated grants were not being ignored by macOS - each one really did work, for that one account, on that one launch.
The dialog kept coming back because the *next* launch re-asked regardless, for that account and every other one, because the pass-wide flag had no way to remember that some items were already done.

### Why `com.firstmate.cockpit.sshkey` specifically never clears

Two things line up to make this service, and not the other four, the one the captain actually sees:

1. It is almost certainly the only one of the five services that has any items in it at all for a captain who has not used the clipboard history, the credential vault or a connected Google account - so it is the only service with anything to prompt about in the first place.
2. `native/README.md`'s own "Local signing setup" section already documents the mechanism: a Keychain item's default ACL trusts only the code identity that created it, and an item saved under a build that predates today's stable "Grand Line Local Dev" / "Firstmate Cockpit Local Dev" signing identity - including any build from before that identity existed at all - can carry an ACL trust reference this app's current signing identity was never added to correctly, or that macOS cannot resolve to a match it is willing to honor via a plain "Always Allow" grant on the read.

`migrateKeychainService`'s read failure was previously flattened to a single fixed string, `"the item carried no data"`, regardless of the real reason - so this could not have been distinguished from a captain's outright "Don't Allow" by reading the log.
That is fixed in this round: `data(service:account:)` now returns the real `OSStatus` alongside the blob, and a failed read's message is `describe(status)` (the same `SecCopyErrorMessageString` helper the write path already used) rather than the old fixed string, unless the status genuinely is `errSecSuccess` with an empty payload.

**Not verified**: this agent has no access to the captain's real Keychain or his real legacy items, and no interactive session to drive the actual macOS confidential-data dialog end to end (same limitation round 1 named).
The ACL/signing-identity explanation above is the strongest candidate this investigation could build from the codebase's own documented mechanism (`native/README.md`) and the process-of-elimination shape of the captain's report, not a live-captured `OSStatus` from his machine.
What this round *can* and does guarantee, independent of which exact reason his read fails for: once this fix ships, his next few launches will surface the real status code in `AppLog.keychain`'s error line (previously always the same fixed string), and whatever the reason turns out to be, it will no longer force every other already-granted item to be re-asked about on every subsequent launch.

### The fix: per-item gating, not just a fixed status string

Point 3 of this round's brief asks the question round 1's trade-off note ducked: is "any single failure blocks the whole gate forever" the right shape at all?
It is not, once a failure can be permanent rather than a one-off misclick - the captain is now being asked to grant the same five services' worth of prompts on every single launch, indefinitely, which is materially worse than the isolated-misclick case round 1's design comment anticipated.

`LegacyNameMigration` now tracks **which specific `service/account` items have already succeeded**, in a new `fm.keychainMigratedItems` array, alongside the existing whole-pass `fm.keychainMigratedFromFirstmateCockpit` flag:

- `migrateKeychainIfNeeded` reads that persisted set and passes it into `migrate` as a `skipping` parameter.
- `migrateKeychainService` checks `skipping` for each enumerated account **before** doing anything else - before the existence check on the new service, and before reading the legacy secret - so an item already known to have succeeded is never touched again, not enumerated past, not read, not prompted for.
- Every item that succeeds this pass (copied, or found already present) is folded into the persisted set regardless of whether the *pass as a whole* finished clean, so a permanently-failing item can never again hold the other services - or this service's other accounts - hostage.
- The whole-pass flag is kept as a fast path: once every item across every service has succeeded, the very next pass finds nothing outstanding, reports zero failures, and the flag latches - skipping the Keychain (no enumeration, no query at all) on every launch after that.

The reordering inside `migrateKeychainService` is a second, independent half of the same fix: checking `contains(service:account:)` (a plain existence query, no `kSecReturnData`, never prompts) **before** reading the legacy secret means an item that is already present under the new service name is never read from the legacy one at all, on any pass, with or without the persisted skip set warmed up.
The original code read the legacy secret first and checked `contains` second, discarding the read result - which is harmless for a query that never prompts, but is exactly backwards for one that can.

What this round's fix does **not** claim to do: make the one persistently-failing item stop asking.
If `com.firstmate.cockpit.sshkey`'s specific account genuinely cannot be granted (a stale ACL trust reference, per the signing-identity mechanism above), it will keep being retried, and keep being able to prompt, on every launch - that is the deliberate, load-bearing half of round 1's design that this round does not touch (an item denied or unreadable must stay retryable rather than being silently abandoned).
What changes is that this is now the *only* item asking, with a real status code in the log explaining why, rather than that one item dragging four other services' worth of already-granted items back into the barrage every single time.

### Verification

- `swift build`, clean, both before this round's Package.swift/build-script changes and after.
- `LegacyRenameMigrationSelfTest` (`FM_RUN_LEGACY_RENAME_MIGRATION_TESTS`), including the new `checkKeychainMigrationGatePerItemSurvivesOtherFailures` check, against a real (scratch-service-named) Keychain.
- **Confirmed to catch the exact round-2 regression**: the per-item skip set was neutered to always be empty (`let alreadyMigrated: Set<String> = []`), simulating the pre-this-round single-flag gate exactly.
  `checkKeychainMigrationGatePerItemSurvivesOtherFailures` failed by name - `"A is never re-queried once it has succeeded (got 2 call(s))"` and the equivalent third-launch check - proving the new test discriminates the two shapes.
  Restoring the fix made the suite pass again, byte-identical file confirmed via `diff` against the pre-injection copy.
- `./Scripts/run-all-tests.sh` in full, before this round's changes and after: same pass count, no regressions (see the PR for the exact run).
- `native/build_native_app.sh` run in full (release build): the `line 280: DailyReviewCalendar.swift: command not found` line is gone, `Info.plist` byte-inspected as unaffected (the fix only removed a pair of backticks from an XML comment, no other change), and the signing-identity fallback still correctly reports "signing with the pre-rename identity" on this machine, which has only the old certificate - confirming that fallback (documented above) is untouched by this round.
- The vendored `whisper.cpp` `-Wambiguous-macro` noise (8 warnings, `ggml-quants.c` / `arch/arm/quants.c`, `static_assert` colliding with the macOS 26.5 SDK's own definition) is suppressed via `.unsafeFlags(["-Wno-ambiguous-macro"])` scoped to the `CWhisper` target's `cSettings` only - a clean `swift build` from scratch now reports **zero** warnings, confirming no other real warning was hiding behind the vendor noise.
