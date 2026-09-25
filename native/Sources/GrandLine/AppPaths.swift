// Grand Line - native macOS app.
//
// Where this app keeps the things that are named after the app itself.
//
// One definition of each, because the rename from "Firstmate Cockpit" /
// "Manjesh Grand Line" to plain "Grand Line" had to move all of it in one
// pass, and a second copy of the folder name is exactly how half of it would
// have been left behind. `LegacyNameMigration` is the other half - it is what
// moves a captain who is already running the old build onto these names.
//
// See docs/history/45-rename-to-grand-line.md for the full account, including
// the System Settings re-grant the bundle-identifier change costs.

import Foundation

enum AppPaths {

    /// The folder under `~/Library/Application Support/` that every
    /// file-backed store nests in.
    ///
    /// Every store honours its own `FM_*` override first (the repo-root
    /// README carries the complete index); this is only the default. It is
    /// deliberately the *module* name rather than the display name, because
    /// that is what it has always been and what
    /// `LegacyNameMigration.migrateApplicationSupportFolder` renames from.
    static let applicationSupportFolderName = "GrandLine"

    /// What that folder was called before the rename. Nothing but
    /// `LegacyNameMigration` should read this.
    static let legacyApplicationSupportFolderName = "FirstmateCockpit"

    /// The app's **display** name - what a human reads, in the menu bar and
    /// anywhere else this app names itself to the captain.
    ///
    /// **Review bug B12.** The App menu built "About / Hide / Quit" from
    /// `ProcessInfo.processInfo.processName`, which is the *executable* name.
    /// The executable is `GrandLine` and the app is "Grand Line", so the menu
    /// read "Quit GrandLine" - the one place the rename was left behind, and
    /// one that `LegacyRenameMigrationSelfTest`'s source grep could not see
    /// because the sources spell no name at all there.
    ///
    /// `CFBundleDisplayName` first (what Finder and the Dock use), then
    /// `CFBundleName`, then the literal - because an unbundled
    /// `.build/debug/GrandLine` has no `Info.plist` at all and must still say
    /// the right thing. AGENTS.md's rule is that this app has exactly one
    /// name with a single definition; this is that definition for the
    /// human-facing half, as `applicationSupportFolderName` is for the
    /// on-disk half.
    static var displayName: String {
        let bundle = Bundle.main
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String,
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return "Grand Line"
    }

    /// `~/Library/Application Support`, with the same fallback every store in
    /// this app already used before it was written down in one place.
    static func applicationSupportBase(_ fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// The one environment variable that moves **every** file-backed store in
    /// this app at once.
    ///
    /// It exists because the per-store `FM_*` overrides are a list, and a list
    /// drifts. `Scripts/build-probe-app.sh` promised its `ENV_ARGS` were
    /// "every FM_* location override, in one place, so a launch cannot reach
    /// real data through a store somebody forgot" - and by the time the
    /// 2026-09-25 review compared that list against
    /// `grep -rhoE '"FM_[A-Z0-9_]+"' Sources/GrandLine`, seven stores had been
    /// added that the script did not redirect. A probe launch therefore wrote
    /// the captain's real clipboard history, session-restore file, scratchpad
    /// and widget snapshot (review bug B4), and the clipboard write orphaned
    /// a real 200-entry history (B1).
    ///
    /// So the anti-drift mechanism is the *app*, not the script: a store that
    /// resolves its default through `dataRoot()` is redirected by one
    /// variable, whatever the script remembers to pass.
    /// `ProbeScratchRootSelfTest` is the guard - it fails the run on a
    /// production file that resolves `.applicationSupportDirectory` itself
    /// instead of coming through here.
    ///
    /// A per-store `FM_*` variable still wins over this, because a suite that
    /// points one store somewhere specific must keep working.
    static let scratchRootVariable = "FM_SCRATCH_ROOT"

    /// The folder every file-backed store nests in: `FM_SCRATCH_ROOT` when it
    /// is set, and `~/Library/Application Support/GrandLine` otherwise.
    ///
    /// Note this is the *whole* root, not the base above: a caller that used
    /// to write `base.appendingPathComponent(applicationSupportFolderName)`
    /// writes `dataRoot()` instead, and gains the redirect for free.
    static func dataRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment[scratchRootVariable], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return applicationSupportBase(fileManager)
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    /// True when this process has been pointed at a scratch root - i.e. it is
    /// a probe, a suite or a lab build rather than the captain's own instance.
    ///
    /// Stores whose real location is **not** under Application Support
    /// (`DotfilesAutoSync`'s `~/.dotfiles`, the widget App Group container)
    /// cannot simply nest under `dataRoot()`, so they ask this instead and
    /// pick a scratch path of their own. Nothing else should branch on it:
    /// a store with an Application Support default wants `dataRoot()`.
    static func isScratchRedirected(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !(environment[scratchRootVariable] ?? "").isEmpty
    }
}
