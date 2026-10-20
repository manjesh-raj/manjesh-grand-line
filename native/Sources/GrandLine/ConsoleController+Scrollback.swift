// Grand Line - native macOS app.
//
// PERF-07 of the 2026-10 end-to-end review (section 3.6): a background tab
// keeps a smaller scrollback.
//
// **What it fixes.** Every terminal keeps `interactiveScrollbackLines`
// (10,000) of history, against SwiftTerm's default of 500, and nothing
// bounded the total: terminal memory scaled as tabs x panes x 10,000 rows,
// the one terminal term with no limit at any level, in an app whose common
// case is a long-lived session with many tabs. `native/README.md` records the
// per-pane figure next to the constant.
//
// **What it does.** A tab that has been out of sight for
// `backgroundScrollbackGrace` has each of its panes' scrollback shrunk to
// `backgroundScrollbackLines` through SwiftTerm's own `changeScrollback`; the
// tab gets its full 10,000 back the moment it is selected again. Not a cap on
// tabs - the review ruled that out - and not an app-wide budget.
//
// **The trade, stated rather than implied.** Shrinking a SwiftTerm buffer
// *trims its oldest lines*; growing it again only raises the ceiling. So a
// tab left in the background past the grace period keeps its most recent
// `backgroundScrollbackLines` of history, not all 10,000, and that is the
// memory being given back. Three rules keep the cost where it is cheapest:
//
//   - **A grace period, not an immediate shrink.** Switching between two
//     tabs, even repeatedly, loses nothing; only a tab left alone for
//     minutes is trimmed.
//   - **A pane the captain has scrolled back in is left alone.** Being
//     scrolled into history is the clearest signal that history is wanted,
//     and trimming under it would move what they were reading.
//   - **The Kubernetes feed tab is left alone.** It already runs at its own
//     shallow, wide geometry (`CockpitTerminalView.applyMachineReadableGeometry`).
//
// The screen itself is never touched: `changeScrollback` trims only rows
// above the visible screen, and only on the normal buffer (a full-screen
// program's alternate buffer has no scrollback at all), so a tab looks the
// same when the captain comes back to it.

import AppKit

extension ConsoleController {

    /// Scrollback a background tab keeps once its grace period is over -
    /// four times SwiftTerm's own default of 500, a fifth of the interactive
    /// 10,000.
    static let backgroundScrollbackLines = 2_000

    /// How long a tab must be out of sight before its scrollback shrinks.
    static let defaultBackgroundScrollbackGrace: TimeInterval = 300

    /// Bring every tab's scrollback in line with whether it is the one on
    /// screen: the current tab gets its full history back at once, and every
    /// other tab is scheduled to shrink once its grace period passes. Called
    /// on every tab selection and whenever a tab is added.
    func syncBackgroundScrollback() {
        for tab in tabs {
            if tab === currentTab {
                tab.backgroundScrollbackWork?.cancel()
                tab.backgroundScrollbackWork = nil
                for pane in tab.splits.panes { pane.terminal.restoreInteractiveScrollback(scrollbackLines) }
                tab.terminal.restoreInteractiveScrollback(scrollbackLines)
            } else if tab.backgroundScrollbackWork == nil {
                let work = DispatchWorkItem { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    tab.backgroundScrollbackWork = nil
                    self.shrinkScrollbackIfStillInBackground(tab)
                }
                tab.backgroundScrollbackWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + backgroundScrollbackGrace, execute: work)
            }
        }
    }

    /// The grace period's end for one tab.
    func shrinkScrollbackIfStillInBackground(_ tab: TabModel) {
        guard tab !== currentTab, !tab.isClosing, tabs.contains(where: { $0 === tab }) else { return }
        var terminals = tab.splits.panes.map(\.terminal)
        if !terminals.contains(where: { $0 === tab.terminal }) { terminals.append(tab.terminal) }
        for terminal in terminals {
            terminal.shrinkScrollbackForBackground(to: Self.backgroundScrollbackLines)
        }
    }

    #if FM_SELFTESTS
    /// End every pending grace period now, as if `backgroundScrollbackGrace`
    /// had passed - PERF-07's suite steps through the schedule with this
    /// rather than waiting five minutes.
    func debugEndBackgroundScrollbackGrace() {
        for tab in tabs {
            guard let work = tab.backgroundScrollbackWork else { continue }
            work.cancel()
            tab.backgroundScrollbackWork = nil
            shrinkScrollbackIfStillInBackground(tab)
        }
    }

    func debugBackgroundScrollbackIsPending(forTabID id: UUID) -> Bool {
        tabs.first { $0.id == id }?.backgroundScrollbackWork != nil
    }
    #endif
}

extension CockpitTerminalView {

    /// Shrink this pane's scrollback for a background tab - unless it is the
    /// Kubernetes feed (its own geometry), already shrunk, or scrolled back
    /// into its history (the captain is reading it). Returns whether it shrank.
    @discardableResult
    func shrinkScrollbackForBackground(to lines: Int) -> Bool {
        guard !usesMachineReadableGeometry, !isShrunkForBackground else { return false }
        if canScroll, scrollPosition < 1 { return false }
        terminal?.changeScrollback(lines)
        isShrunkForBackground = true
        return true
    }

    /// Give a shrunk pane its full scrollback back. A no-op for a pane that
    /// was never shrunk, so selecting a tab costs nothing in the common case.
    func restoreInteractiveScrollback(_ lines: Int) {
        guard isShrunkForBackground else { return }
        isShrunkForBackground = false
        guard !usesMachineReadableGeometry else { return }
        terminal?.changeScrollback(lines)
    }
}
