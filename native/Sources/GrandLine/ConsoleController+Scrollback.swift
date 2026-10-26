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
//
// **T4 made both halves settings** (`TerminalScrollback.swift`). The depth a
// selected tab keeps is the captain's choice now, applied to every open pane
// the moment it changes, and the background trim is a toggle. A trim target
// is never deeper than the interactive depth: a captain who chose 1,000 rows
// is not handed 2,000 by a tab going to the background.

import AppKit

extension ConsoleController {

    /// Scrollback a background tab keeps once its grace period is over -
    /// four times SwiftTerm's own default of 500, a fifth of the interactive
    /// 10,000.
    static let backgroundScrollbackLines = 2_000

    /// How long a tab must be out of sight before its scrollback shrinks.
    static let defaultBackgroundScrollbackGrace: TimeInterval = 300

    /// Every console that is alive, so Settings can ask how much history a
    /// lower depth would cost before it applies one. Weak, and a console
    /// leaves it in `shutdown()` too, because a host page can be torn down
    /// mid-session.
    static let liveConsoles = NSHashTable<ConsoleController>.weakObjects()

    /// How many open panes, across every console, hold more history than
    /// `rows` - what lowering the depth to `rows` would trim. A pane showing
    /// a full-screen program counts whenever it is allowed more than `rows`,
    /// because its history sits in a buffer this cannot measure while the
    /// alternate one is up, and a warning that undercounts is worse than one
    /// that says "may".
    static func panesThatWouldLoseHistory(below rows: Int) -> Int {
        liveConsoles.allObjects.reduce(0) { total, console in
            total + console.tabs.flatMap(console.scrollbackTerminals(of:)).filter {
                $0.wouldLoseHistory(below: rows)
            }.count
        }
    }

    /// The depth a background tab is trimmed to: PERF-07's 2,000, or the
    /// captain's own depth when that is already smaller.
    var backgroundScrollbackTarget: Int { min(Self.backgroundScrollbackLines, scrollbackLines) }

    /// Every terminal a tab holds - its split panes and its primary.
    func scrollbackTerminals(of tab: TabModel) -> [CockpitTerminalView] {
        var terminals = tab.splits.panes.map(\.terminal)
        if !terminals.contains(where: { $0 === tab.terminal }) { terminals.append(tab.terminal) }
        return terminals
    }

    /// T4: Settings changed the depth or the background toggle. Every pane
    /// of every tab takes the new depth now (a background-trimmed pane takes
    /// the new trim target), and the schedule is redone, so turning the trim
    /// off gives every trimmed tab its full depth back at once.
    func applyScrollbackSetting() {
        let interactive = scrollbackLines
        let background = backgroundScrollbackTarget
        for tab in tabs {
            for terminal in scrollbackTerminals(of: tab) {
                terminal.applyScrollbackDepth(interactive: interactive, background: background)
            }
        }
        syncBackgroundScrollback()
    }

    /// Bring every tab's scrollback in line with whether it is the one on
    /// screen: the current tab gets its full history back at once, and every
    /// other tab is scheduled to shrink once its grace period passes. Called
    /// on every tab selection and whenever a tab is added.
    ///
    /// With the background trim turned off (T4) every tab is treated as the
    /// current one: nothing is scheduled, and anything already trimmed gets
    /// its full depth back.
    func syncBackgroundScrollback() {
        let trims = TerminalScrollback.shared.trimsBackgroundTabs
        for tab in tabs {
            if tab === currentTab || !trims {
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
        guard TerminalScrollback.shared.trimsBackgroundTabs,
              tab !== currentTab, !tab.isClosing, tabs.contains(where: { $0 === tab }) else { return }
        for terminal in scrollbackTerminals(of: tab) {
            terminal.shrinkScrollbackForBackground(to: backgroundScrollbackTarget)
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
        // A captain who chose a depth at or under the trim target has nothing
        // to give back.
        guard let current = terminal?.options.scrollback, lines < current else { return false }
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

    /// T4: take a new depth from Settings. A background-trimmed pane takes
    /// the trim target instead, and stays trimmed. A no-op when nothing
    /// moved, because `changeScrollback` reallocates the buffer.
    func applyScrollbackDepth(interactive: Int, background: Int) {
        guard !usesMachineReadableGeometry, let terminal else { return }
        let target = isShrunkForBackground ? background : interactive
        guard terminal.options.scrollback != target else { return }
        terminal.changeScrollback(target)
    }

    /// Rows of history above the screen in the normal buffer, or `nil` while
    /// a full-screen program has the alternate buffer up and the normal one
    /// cannot be read through SwiftTerm's public surface.
    ///
    /// `getScrollInvariantLine` answers for any row the buffer still holds,
    /// so a binary search over it finds the buffer's length in about
    /// seventeen reads at 100,000 rows, with no copy of the text.
    var historyRowCount: Int? {
        guard let terminal, !terminal.isCurrentBufferAlternate else { return nil }
        let top = terminal.buffer.totalLinesTrimmed
        guard terminal.getScrollInvariantLine(row: top) != nil else { return 0 }
        var low = 0
        var high = max(terminal.options.scrollback, 0) + terminal.rows
        while low < high {
            let mid = (low + high + 1) / 2
            if terminal.getScrollInvariantLine(row: top + mid) != nil { low = mid } else { high = mid - 1 }
        }
        return max(0, low + 1 - terminal.rows)
    }

    /// Whether a depth of `rows` would trim anything from this pane.
    func wouldLoseHistory(below rows: Int) -> Bool {
        guard !usesMachineReadableGeometry, let terminal else { return false }
        guard let held = historyRowCount else { return terminal.options.scrollback > rows }
        return held > rows
    }
}
