// Grand Line - native macOS app.
//
// Where the Tasks page's calendar bundle lives, and how it is found.
//
// The bundle itself (`native/Vendor/ScheduleX/web/`) is a committed, vendored
// build of the open-source Schedule-X packages - see that directory's README
// for provenance, licensing and how to regenerate it. Nothing here builds,
// downloads or updates it: this file only answers "where is it on this
// machine", and answers `nil` rather than crashing when it is missing.
//
// This is `CodePreviewAssets.swift` with its strings changed, deliberately:
// the two features have the identical problem (a real directory this app ships
// that has to be findable both from an assembled `.app` and from the `swift
// build` dev flow), so they get the identical three-step answer.
//
//   1. `Bundle.main.resourceURL` - the assembled `.app`, where
//      `build_native_app.sh` copies the directory into `Contents/Resources`.
//   2. `FM_TASK_CALENDAR_WEB_DIR` - an explicit override, for a self-test or
//      for pointing a running app at a freshly rebuilt bundle.
//   3. A walk up from the current working directory looking for
//      `native/Vendor/ScheduleX/web` - the dev flow.
//
// Deliberately not `Bundle.module`, for the reason `CodePreviewAssets` gives:
// its generated accessor `fatalError`s when the bundle is missing, and a
// missing calendar has to degrade to a legible empty state, never a crash on
// a tab the captain merely clicked.

import Foundation

enum ShiftCalendarAssets {

    /// The directory holding `index.html`, `task-calendar.js` and
    /// `task-calendar.css`. `nil` when no candidate has a readable
    /// `index.html`.
    static func webDirectory() -> URL? {
        let fm = FileManager.default

        func isUsable(_ dir: URL) -> Bool {
            fm.isReadableFile(atPath: dir.appendingPathComponent(indexFileName).path)
        }

        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent(bundleDirectoryName, isDirectory: true)
            if isUsable(candidate) { return candidate }
        }
        if let override = ProcessInfo.processInfo.environment["FM_TASK_CALENDAR_WEB_DIR"] {
            let candidate = URL(fileURLWithPath: override, isDirectory: true)
            if isUsable(candidate) { return candidate }
        }
        var dir = fm.currentDirectoryPath
        for _ in 0..<6 {
            let candidate = URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent("native/Vendor/ScheduleX/web", isDirectory: true)
            if isUsable(candidate) { return candidate }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// The page to load. `nil` propagates "no bundle on this machine".
    static func indexURL() -> URL? {
        webDirectory()?.appendingPathComponent(indexFileName)
    }

    /// What the empty state says when the bundle is missing. Names the real
    /// script rather than telling the captain to reinstall.
    static let missingBundleMessage =
        "The calendar bundle isn't on this machine. Run native/Scripts/build-schedule-x-web.sh " +
        "to regenerate native/Vendor/ScheduleX/web, or set FM_TASK_CALENDAR_WEB_DIR to point at it."

    /// The name `build_native_app.sh` copies the directory to inside
    /// `Contents/Resources`. Shared with that script by convention, not by
    /// mechanism - `ShiftCalendarSelfTest` reads the script to keep the two
    /// in step.
    static let bundleDirectoryName = "ScheduleXWeb"

    static let indexFileName = "index.html"
}
