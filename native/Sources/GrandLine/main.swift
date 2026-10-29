// Grand Line - native macOS app: the entry point.
//
// What runs before the app delegate exists, in order: the whole-launch
// signpost, the self-test dispatch (debug builds only), the legacy-name
// migration, the first-launch settings, the single-instance guard, the
// diagnostics stamp, and then `NSApplication` with an `AppDelegate`. Nothing
// else lives here.
//
// R2-ARCH-02 (review #1's T-16): this file was 4,900 lines - the composition
// root, the menu builder, the session coordinator, the host editor and the
// self-test dispatch at once - so every new suite and every new menu item
// edited the app's entry point. Each of those is a file of its own now
// (`AppComposition.swift` holds the delegate), and the launch order below is
// the order it always ran in. `LaunchPathSelfTest.mainSwiftIsOnlyTheEntryPoint`
// caps this file at 150 lines and pins that order, so it cannot grow back.

import AppKit

// R4-PERF-02: the one interval that covers the whole launch, from here to the
// first window that becomes key. `LaunchSignposts` says how to read it.
LaunchSignposts.beginLaunch()

// MARK: - Self-test dispatch (GL-27: debug builds only)
//
// R2-ARCH-02: the dispatch lives in `SelfTests/SelfTestDispatch.swift` now,
// compiled into debug builds only. It runs here, at the same point as before:
// before the legacy-name migration, `SingleInstanceGuard.acquire()` and
// `AppDelegate()` - every branch `exit()`s, so a headless suite never contends
// for the instance lock and never touches the real stores.
#if FM_SELFTESTS
SelfTestDispatch.run()
#endif

// The rename to "Grand Line" (docs/history/45-rename-to-grand-line.md).
//
// This sits after every `FM_RUN_*_TESTS` block - each of which `exit()`s, so a
// headless suite never runs it against the captain's real Keychain or real
// data folder - and *before* `SingleInstanceGuard.acquire()`, which is the
// first line in the process that touches
// `~/Library/Application Support/<folder>` at all.
//
// Both halves are idempotent, so this is a no-op on every launch after the
// first. See `LegacyNameMigration`'s header for why the folder is moved and
// the Keychain items are copied, and for the one thing it cannot do: the
// captain's Accessibility and Automation grants are keyed to the bundle
// identifier, which changed, and re-granting them is a manual System Settings
// step by design.
//
// B4: skipped entirely in a scratch-redirected process. Both halves operate on
// the captain's REAL locations by construction - the folder move renames
// `~/Library/Application Support/FirstmateCockpit`, and the Keychain copy
// writes real login-Keychain items - so neither has anything to do in a probe
// and both would be reaching past `FM_SCRATCH_ROOT` if they ran.
if !AppPaths.isScratchRedirected() {
    LegacyNameMigration.runAtLaunch()
}

// R2-UX-01: settle what a first launch decides (the app lock, and the
// sidebar's profile), before anything below writes a preference or creates
// the data folder - `SingleInstanceGuard.acquire()` is the first thing that
// does. After `LegacyNameMigration`, so a pre-rename install counts as the
// existing install it is.
AppSettings.shared.settleFirstLaunch(isExistingInstall: AppSettings.shared.isExistingInstall())

// GL-05: refuse to be a second instance. This sits *after* every
// `FM_RUN_*_TESTS` block above (each of which `exit()`s, so a headless
// self-test never contends for the lock and never blocks a real running
// instance) and *before* `AppDelegate()` is constructed - which is the line
// that builds `HostStore`/`SSHKeyStore`/`SnippetStore`/`DictationStore`/
// `ShiftStore` and therefore the first thing that touches the shared files
// two instances corrupt. See `SingleInstanceGuard`'s header for what each of
// the three layers (Info.plist, NSRunningApplication, flock) actually covers.
switch SingleInstanceGuard.acquire() {
case .acquired:
    break
case .alreadyRunning(let pid):
    let who = pid.map { " (pid \($0))" } ?? ""
    AppLog.lifecycle.error("""
        Grand Line is already running\(who, privacy: .public) - activating it and exiting. \
        Two instances share one set of JSON stores and one Shift git working tree; the second one \
        silently overwrites the first's saves. See GL-05.
        """)
    exit(0)
}

// P9: the on-disk diagnostics sink. This is the first thing after the instance
// guard so the launch line is the first line of every run, and it must be
// *after* the guard - a second instance that exits is not a launch and should
// not stamp `last-launch`, which is what
// `DiagnosticsLog.crashReportsSinceLastLaunch()` compares against.
//
// `DiagnosticsLog.shared` reads the *previous* stamp at init, so the read has
// already happened by the time this overwrites it.
DiagnosticsLog.shared.noteLaunch(
    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unbundled")

let app = NSApplication.shared
// Regular activation policy so a `swift run`-launched executable gets a real
// Dock icon, menu bar, and key window instead of a background agent.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
