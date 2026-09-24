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
