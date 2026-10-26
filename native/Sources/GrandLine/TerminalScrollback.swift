// Grand Line - native macOS app.
//
// T4 of the Termius-style plan: how many rows of history a terminal keeps is
// a setting now, not a constant.
//
// ## What was there
//
// `ConsoleController.interactiveScrollbackLines` was a fixed 10,000, and
// PERF-07's background trim (`ConsoleController+Scrollback.swift`) shrank a
// tab left out of sight for five minutes to 2,000 with no way to turn it off.
// Both were reasonable defaults and neither could be changed without a build.
//
// ## The rules this file owns
//
//   - **The default stays 10,000.** A captain who never opens Settings gets
//     exactly what they had before.
//   - **The range is 1,000 to 100,000, and 0 means 100,000.** There is no
//     "unlimited": the value applies to every pane of every tab, and terminal
//     memory already scales as tabs x panes x rows. 0 is accepted because it
//     is what "as much as you have" means in most terminals' settings, and
//     the field says what it turned into rather than refusing it.
//   - **Applied live.** Every open pane takes the new depth through
//     SwiftTerm's own `changeScrollback`. Lowering it trims the oldest lines
//     of any pane that holds more, which is why Settings asks first.
//   - **The background trim is a visible toggle**, on by default because that
//     is what PERF-07 shipped.
//
// The memory note is derived from PERF-07's measurement rather than restated:
// `native/README.md` records about 52 MB for one full 10,000-row pane at 200
// columns, so 5.2 MB per 1,000 rows. It is a ceiling for a pane that has
// filled its history, not what every pane costs.
//
// Shaped like `FontSizeManager` - one shared value, persisted through
// `AppSettings`, with observers - because every `ConsoleController` (the
// shared Console and each host page's own) has to follow it, and none of them
// is reachable from Settings.

import Foundation

/// An opaque handle to a live `TerminalScrollback.observe` registration,
/// mirroring `FontSizeObservation`. A per-host console keeps its token and
/// unobserves in `shutdown()`, because that page can be torn down mid-session.
final class TerminalScrollbackObservation {}

final class TerminalScrollback {
    static let shared = TerminalScrollback()

    static let defaultRows = 10_000
    static let minimumRows = 1_000
    static let maximumRows = 100_000

    /// PERF-07's measurement, per 1,000 rows of a full 200-column pane. See
    /// this file's header.
    static let megabytesPerThousandRows = 5.2

    /// The depth a typed value means: 0 is the maximum, anything else is
    /// clamped into the range.
    static func normalised(_ requested: Int) -> Int {
        if requested == 0 { return maximumRows }
        return min(maximumRows, max(minimumRows, requested))
    }

    /// What one full pane costs at `rows`, for the Settings row's note.
    static func megabytesPerPane(rows: Int) -> Int {
        Int((Double(rows) / 1_000 * megabytesPerThousandRows).rounded())
    }

    /// The sentence under the Settings row. Live: it is recomputed as the
    /// captain types, so the number they are about to commit is the one
    /// whose cost they are reading.
    static func memoryNote(rows: Int) -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: rows), number: .decimal)
        return "Each pane keeps up to \(formatted) rows. A full pane at 200 columns uses about "
            + "\(megabytesPerPane(rows: rows)) MB, and every pane of every open tab can fill up. "
            + "1,000 to 100,000, and 0 means 100,000."
    }

    private let settings: AppSettings
    private var observers: [(token: TerminalScrollbackObservation, fn: (TerminalScrollback) -> Void)] = []

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    /// The depth every interactive pane keeps.
    var rows: Int { settings.terminalScrollbackRows }

    /// Whether a tab left out of sight is trimmed to
    /// `ConsoleController.backgroundScrollbackLines` (PERF-07).
    var trimsBackgroundTabs: Bool { settings.terminalTrimsBackgroundScrollback }

    /// Persist a new depth (normalised) and tell every console.
    func setRows(_ requested: Int) {
        let value = Self.normalised(requested)
        guard value != rows else { return }
        settings.terminalScrollbackRows = value
        notify()
    }

    func setTrimsBackgroundTabs(_ enabled: Bool) {
        guard enabled != trimsBackgroundTabs else { return }
        settings.terminalTrimsBackgroundScrollback = enabled
        notify()
    }

    /// Register for changes; `fn` is called immediately, then on every change.
    @discardableResult
    func observe(_ fn: @escaping (TerminalScrollback) -> Void) -> TerminalScrollbackObservation {
        let token = TerminalScrollbackObservation()
        observers.append((token, fn))
        fn(self)
        return token
    }

    func unobserve(_ token: TerminalScrollbackObservation) {
        observers.removeAll { $0.token === token }
    }

    private func notify() {
        observers.forEach { $0.fn(self) }
    }
}
