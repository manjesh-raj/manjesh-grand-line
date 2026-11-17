// Grand Line - native macOS app.
//
// R5-UX-02 of review #5: one vocabulary for state.
//
// R5-BUG-02, R5-BUG-04 and R5-UI-04 were one problem: each surface computed
// its own number and picked its own word. The numbers are one summary per
// registry and store now - `ServiceHealthSummary` for the background
// services, `ShiftStore.Summary` for tasks, `UpdatesSummary` for the tool
// catalog, `SetupPipelineProgress` for Setup's steps. This file is the other
// half: the words. A state has one name, and every surface that names it
// reads it from `StateWord`, so the Health page, Home and the sidebar cannot
// drift apart again, and Setup's software step and the Updates page call the
// same tool the same thing.
//
// `StateVocabulary.retired` lists the words that used to name one of these
// states somewhere. `ReviewFiveUXSelfTest` fails the run if one comes back in
// a string the app shows.

import Foundation

/// One state, as every surface names it.
enum StateWord: CaseIterable {
    // A background service (`ServiceHealthSummary.Bucket`).
    case healthy
    case recentFailure
    case failing
    case notRunYet
    case checking
    // A tool on Updates and in Setup's software step (`DependencyStatus`).
    case notChecked
    case upToDate
    case updateAvailable
    case notInstalled
    case checkFailed
    case updating
    case updateFailed
    // A Setup step.
    case verified
    case notSetUp
    // A task (`ShiftStore.Summary`).
    case overdue
    case dueToday

    /// The state's name, capitalised for a chip, a pill or a caption.
    var label: String { StateVocabulary.table[self]?.label ?? "" }

    /// The same word inside a sentence ("2 healthy, 1 failing").
    var phrase: String { label.prefix(1).lowercased() + label.dropFirst() }

    /// The state's colour when a surface leads with it (S01's StateVocabulary
    /// 1.1.0, from S11 of the 2026-11-17 UI/UX proposals): the hue a headline,
    /// a ring or a tile takes for this state. `nil` is a state that is not a
    /// verdict yet (not run, checking, not checked, updating), which stays in
    /// ink, never in a colour it has not earned (GL-14).
    ///
    /// The values are the ones the pages already paint these words in
    /// (`HealthCardView.healthVisuals`, `UpdatesController`'s and Setup's
    /// status pills), written down once.
    var tint: HelmTint? {
        switch self {
        case .healthy, .upToDate, .verified: return .good
        case .recentFailure, .updateAvailable, .notInstalled, .notSetUp, .dueToday: return .warn
        case .failing, .checkFailed, .updateFailed, .overdue: return .critical
        case .notRunYet, .checking, .notChecked, .updating: return nil
        }
    }

    /// The word with a count in front, as a summary line says it: "3 up to
    /// date", "1 update available", "2 checks failed".
    func counted(_ count: Int) -> String {
        guard let entry = StateVocabulary.table[self] else { return "\(count)" }
        return "\(count) \(count == 1 ? entry.one : entry.many)"
    }
}

enum StateVocabulary {

    struct Entry {
        /// The state on its own.
        let label: String
        /// After a count of one, and after any other count.
        let one: String
        let many: String
    }

    /// The table. One row per state; a new state is a row here and a case
    /// above, never a literal at a call site.
    static let table: [StateWord: Entry] = [
        .healthy: Entry(label: "Healthy", one: "healthy", many: "healthy"),
        .recentFailure: Entry(label: "Recent failure", one: "recent failure", many: "recent failures"),
        .failing: Entry(label: "Failing", one: "failing", many: "failing"),
        .notRunYet: Entry(label: "Not run yet", one: "not run yet", many: "not run yet"),
        .checking: Entry(label: "Checking\u{2026}", one: "checking", many: "checking"),
        .notChecked: Entry(label: "Not checked", one: "not checked", many: "not checked"),
        .upToDate: Entry(label: "Up to date", one: "up to date", many: "up to date"),
        .updateAvailable: Entry(label: "Update available", one: "update available", many: "updates available"),
        .notInstalled: Entry(label: "Not installed", one: "not installed", many: "not installed"),
        .checkFailed: Entry(label: "Check failed", one: "check failed", many: "checks failed"),
        .updating: Entry(label: "Updating\u{2026}", one: "updating", many: "updating"),
        .updateFailed: Entry(label: "Update failed", one: "update failed", many: "updates failed"),
        .verified: Entry(label: "Verified", one: "verified", many: "verified"),
        .notSetUp: Entry(label: "Not set up", one: "not set up", many: "not set up"),
        .overdue: Entry(label: "Overdue", one: "overdue", many: "overdue"),
        .dueToday: Entry(label: "Due today", one: "due today", many: "due today"),
    ]

    /// Words that once named one of the states above on some surface, and
    /// the state each one meant. None of them may come back in a string the
    /// app shows (`ReviewFiveUXSelfTest.checkOneWordPerState`).
    ///
    /// "Not read" is not here: it is also the generic caption for a figure
    /// nobody has read yet (`HelmKPIStrip.unknownCaption`, GL-14), which is
    /// a different thing from a service that has not run. Nor is
    /// "Installing…", which is Setup's Install button's own progress verb.
    static let retired: [String: StateWord] = [
        "\"Degraded\"": .recentFailure,
        "\"Warnings\"": .recentFailure,
        "\"Install failed\"": .updateFailed,
        "could not be checked\")": .checkFailed,
    ]
}

extension DependencyStatus {
    /// The tool's state, in the one word Updates and Setup's software step
    /// both show.
    var stateWord: StateWord {
        switch self {
        case .unknown: return .notChecked
        case .checking: return .checking
        case .upToDate: return .upToDate
        case .updateAvailable: return .updateAvailable
        case .notInstalled: return .notInstalled
        case .checkFailed: return .checkFailed
        case .updating: return .updating
        case .updateFailed: return .updateFailed
        }
    }
}
