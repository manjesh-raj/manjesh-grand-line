// Grand Line - native macOS app.
//
// PERF-07 of the 2026-10 end-to-end review (section 3.6): a tab left in the
// background keeps `ConsoleController.backgroundScrollbackLines` of history,
// and gets its full 10,000 back the moment it is selected.
//
// Pure logic, in the sense this repository means it: real
// `ConsoleController`s, real tabs and real SwiftTerm buffers, but never a
// window. A console that never appears never starts a tab's process
// (`ConsoleController.addTab`'s `hasAppeared` guard), so no shell is forked;
// the history is fed straight into each terminal with `feed(text:)`.
//
// What each case asserts is the buffer itself - how many lines it holds and
// what its screen shows - rather than a flag, because the regression worth
// catching is memory that is not given back, or a screen that changed.
//
// Run with:
//   swift build && FM_RUN_BACKGROUND_SCROLLBACK_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import SwiftTerm

enum BackgroundScrollbackSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("aBackgroundTabShrinksAfterItsGracePeriod", test_aBackgroundTabShrinksAfterItsGracePeriod),
            ("selectingATabRestoresItsFullScrollback", test_selectingATabRestoresItsFullScrollback),
            ("switchingWithinTheGracePeriodLosesNothing", test_switchingWithinTheGracePeriodLosesNothing),
            ("aTabScrolledBackIntoItsHistoryIsLeftAlone", test_aTabScrolledBackIntoItsHistoryIsLeftAlone),
        ]
        var failed = 0
        for (name, body) in cases {
            if let failure = autoreleasepool(invoking: body) {
                failed += 1
                SelfTestAssertions.reportFailure("\(name): \(failure)")
            } else {
                SelfTestAssertions.reportPass(name)
            }
        }
        reportThePerPaneFigure()
        print("BackgroundScrollbackSelfTest: \(failed == 0 ? "PASSED" : "FAILED") (\(cases.count - failed)/\(cases.count))")
        return failed == 0
    }

    // MARK: Fixtures

    /// A console with `count` tabs, the first selected, none of them started.
    private static func makeConsole(tabs count: Int) -> (ConsoleController, [TabModel]) {
        let console = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(),
                                        isFirstmateConsole: false)
        _ = console.view
        let launch = TabLaunch.shell(executable: "/bin/sh", args: [], cwd: NSTemporaryDirectory())
        var made: [TabModel] = []
        for index in 0..<count {
            made.append(console.addTab(launch: launch, name: "tab \(index)", select: index == 0))
        }
        return (console, made)
    }

    /// `lines` lines of history, numbered, so the screen's content is
    /// recognisable afterwards.
    private static func fill(_ tab: TabModel, lines: Int, label: String) {
        var text = ""
        text.reserveCapacity(lines * 16)
        for index in 0..<lines { text += "\(label) \(index)\r\n" }
        tab.terminal.feed(text: text)
    }

    private static func bufferLines(_ tab: TabModel) -> Int { tab.currentBufferLines().count }

    // MARK: The per-pane figure (`native/README.md`)

    /// What one pane's full scrollback costs, measured in this process rather
    /// than argued: one 200-column pane filled past its 10,000-line ceiling,
    /// and the process's physical footprint read before and after. A note,
    /// not an assertion - the number belongs to this build on this machine,
    /// and `native/README.md` records the one taken when PERF-07 landed.
    private static func reportThePerPaneFigure() {
        let before = physicalFootprint()
        autoreleasepool {
            let (_, tabs) = makeConsole(tabs: 1)
            let tab = tabs[0]
            tab.terminal.terminal?.resize(cols: 200, rows: 50)
            let row = String(repeating: "x", count: 199) + "\r\n"
            // In chunks, so the text being fed is not itself a 4 MB string
            // still alive when the footprint is read.
            for _ in 0..<200 {
                autoreleasepool { tab.terminal.feed(text: String(repeating: row, count: 100)) }
            }
            let after = physicalFootprint()
            let lines = tab.currentBufferLines().count
            let megabytes = Double(max(0, after - before)) / 1_048_576
            print(String(format: "  NOTE: one 200-column pane holding %d lines: about %.0f MB of physical footprint "
                         + "(CharData stride %d bytes, so %.1f MB of cells alone at 10,000 x 200)",
                         lines, megabytes, MemoryLayout<CharData>.stride,
                         Double(MemoryLayout<CharData>.stride * 200 * 10_000) / 1_048_576))
        }
    }

    private static func physicalFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    // MARK: Cases

    /// The point of it: a tab out of sight past its grace period gives back
    /// all but `backgroundScrollbackLines` of its history - and its screen
    /// shows exactly what it showed before.
    ///
    /// Injection: make `shrinkScrollbackForBackground` return before
    /// `changeScrollback` and the buffer keeps all 6,000 lines.
    private static func test_aBackgroundTabShrinksAfterItsGracePeriod() -> String? {
        let (console, tabs) = makeConsole(tabs: 2)
        let background = tabs[1]
        fill(background, lines: 6_000, label: "bg")
        let before = bufferLines(background)
        let screen = background.currentViewportLines()
        guard before > 5_000 else { return "the fixture should hold 6,000 lines of history, holds \(before)" }

        console.debugEndBackgroundScrollbackGrace()
        let after = bufferLines(background)
        let ceiling = ConsoleController.backgroundScrollbackLines + (background.terminal.terminal?.rows ?? 0) + 1
        guard after <= ceiling else {
            return "a background tab past its grace period still holds \(after) lines, expected at most \(ceiling)"
        }
        guard background.currentViewportLines() == screen else {
            return "shrinking the history changed what the tab's screen shows"
        }
        return nil
    }

    /// Coming back gives the tab its whole 10,000 again: the history it
    /// accumulates from then on is kept, not trimmed at the background size.
    ///
    /// Injection: drop the restore from `syncBackgroundScrollback` and the
    /// new output is cut back to 2,000.
    private static func test_selectingATabRestoresItsFullScrollback() -> String? {
        let (console, tabs) = makeConsole(tabs: 2)
        let tab = tabs[1]
        fill(tab, lines: 3_000, label: "early")
        console.debugEndBackgroundScrollbackGrace()
        guard tab.terminal.isShrunkForBackground else {
            return "the fixture's background tab was never shrunk - the restore below would prove nothing"
        }
        console.debugSelectTab(tab.id)
        guard !tab.terminal.isShrunkForBackground else { return "selecting the tab did not restore its scrollback" }
        fill(tab, lines: 6_000, label: "late")
        let held = bufferLines(tab)
        guard held > 5_000 else {
            return "after the tab came back it kept only \(held) lines of 6,000 new ones - its scrollback is still the background size"
        }
        return nil
    }

    /// Switching back and forth inside the grace period trims nothing, so
    /// the ordinary case - flipping between two tabs - costs no history.
    ///
    /// Injection: shrink at once on deselect rather than scheduling it, and
    /// the tab loses its 6,000 lines on the first switch.
    private static func test_switchingWithinTheGracePeriodLosesNothing() -> String? {
        let (console, tabs) = makeConsole(tabs: 2)
        let (first, second) = (tabs[0], tabs[1])
        fill(first, lines: 6_000, label: "first")
        let before = bufferLines(first)
        console.debugSelectTab(second.id)
        guard console.debugBackgroundScrollbackIsPending(forTabID: first.id) else {
            return "deselecting a tab did not start its grace period"
        }
        console.debugSelectTab(first.id)
        console.debugSelectTab(second.id)
        console.debugSelectTab(first.id)
        guard bufferLines(first) == before, !first.terminal.isShrunkForBackground else {
            return "switching within the grace period trimmed the tab from \(before) to \(bufferLines(first)) lines"
        }
        guard !console.debugBackgroundScrollbackIsPending(forTabID: first.id) else {
            return "the selected tab still has a pending shrink"
        }
        return nil
    }

    /// A pane the captain has scrolled back in is reading its history, so it
    /// is not trimmed under them.
    private static func test_aTabScrolledBackIntoItsHistoryIsLeftAlone() -> String? {
        let (console, tabs) = makeConsole(tabs: 2)
        let tab = tabs[1]
        fill(tab, lines: 6_000, label: "history")
        tab.terminal.scroll(toPosition: 0.25)
        guard tab.terminal.canScroll, tab.terminal.scrollPosition < 1 else {
            return "the fixture could not scroll the tab back - the check would be vacuous"
        }
        let before = bufferLines(tab)
        console.debugEndBackgroundScrollbackGrace()
        guard bufferLines(tab) == before, !tab.terminal.isShrunkForBackground else {
            return "a tab scrolled back into its history was trimmed from \(before) to \(bufferLines(tab)) lines"
        }
        return nil
    }
}

#endif
