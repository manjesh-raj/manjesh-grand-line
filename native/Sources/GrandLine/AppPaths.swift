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

    /// `~/Library/Application Support`, with the same fallback every store in
    /// this app already used before it was written down in one place.
    static func applicationSupportBase(_ fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }
}
