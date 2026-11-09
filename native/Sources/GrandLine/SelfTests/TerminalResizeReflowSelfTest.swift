// Grand Line - native macOS app.
//
// `fm/grandline-selection-copy-corruption-1794208740`: a captain copied an AWS
// IAM policy out of a Console tab and the paste had lost the middle of nine
// long lines - `arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/state/*`
// came back as `...-data-prodt-1/state/*`, and a `"Sid": "...",` line lost its
// closing `",`. Every damaged line was missing exactly columns 54..<80.
//
// The cause was SwiftTerm's resize, and this suite guards patch 9 (see
// `native/Vendor/SwiftTerm/README.md`). A narrowing reflow skipped the line the
// cursor was on - "the program will handle fixing up wrapped lines with the
// cursor" - and `Buffer.resize` then cut every line to the new width, so the
// skipped line lost every cell past it for good. A shell redraws its prompt
// line, but a program still printing does not: with the cursor resting at the
// end of a long line, an 80 -> 54 -> 80 round trip left `...-prod`, 26 nulls and
// the wrapped tail, and a copy trims the nulls and joins the tail on. The
// replay below reproduces the captain's paste byte for byte under the old rule.
//
// Fuzzing the fix turned up a second copy defect in the same buffer, which
// patch 9 also carries: an autowrap above the bottom row marked the wrong row
// as wrapped, so after a cleared screen every long line copied as two lines
// and two unrelated history lines copied as one.
//
// Pure logic - a headless `Terminal`, one real PTY child (`/bin/sh`), and one
// source guard - so it runs in CI's blocking lane. Run with:
//
//   swift build && FM_RUN_TERMINAL_RESIZE_REFLOW_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard when editing
// a suite - `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Darwin
import Foundation
import SwiftTerm

enum TerminalResizeReflowSelfTest {

    static func run() -> Bool {
        print("TerminalResizeReflowSelfTest")
        var ok = true
        checkTheReportedCopyIsWholeAgain(&ok)
        checkOutputStillArrivingSurvivesTogglingWidths(&ok)
        checkTheCursorFollowsItsCharacter(&ok)
        checkACarriageReturnAwaitingItsLineFeedStaysAtTheLineStart(&ok)
        checkAPendingWrapSurvivesAHeightOnlyResize(&ok)
        checkAWrapAfterAClearScreenMarksItsOwnRow(&ok)
        checkAShellPromptIsStillRedrawnCleanly(&ok)
        checkRandomResizesNeverChangeTheText(&ok)
        checkTheForegroundShellClassification(&ok)
        checkTheForegroundIsReadFromARealPTY(&ok)
        checkCockpitTerminalViewInstallsThePolicy(&ok)
        print(ok ? "TerminalResizeReflowSelfTest: all checks passed"
                 : "TerminalResizeReflowSelfTest: FAILURES")
        return ok
    }

    // MARK: - Fixture

    /// The text the captain selected, verbatim from the report's
    /// `expected-copy.txt`.
    static let reportedPolicy = #"""
        {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Sid": "ReadAndWriteTheDataPrefixes",
                    "Effect": "Allow",
                    "Action": [
                        "s3:GetObject",
                        "s3:PutObject"
                    ],
                    "Resource": [
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/documents/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/subscribers/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/tokens/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/sends/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/ses-index/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/ledger/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/controls/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/indexes/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/incidents/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/incident-ids/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/published/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/monitoring/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/audit/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/locks/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/state/*"
                    ]
                },
                {
                    "Sid": "ReadOlderVersionsForHistoryScreens",
                    "Effect": "Allow",
                    "Action": "s3:GetObjectVersion",
                    "Resource": [
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/documents/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/subscribers/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/ledger/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/monitoring/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/controls/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/incidents/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/published/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/state/*"
                    ]
                },
                {
                    "Sid": "DeleteOnlyWhatTheAppRetiresItself",
                    "Effect": "Allow",
                    "Action": "s3:DeleteObject",
                    "Resource": [
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/subscribers/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/tokens/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/sends/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/ses-index/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/ledger/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/locks/*",
                        "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1/indexes/*"
                    ]
                },
                {
                    "Sid": "ListTheDataPrefixes",
                    "Effect": "Allow",
                    "Action": [
                        "s3:ListBucket",
                        "s3:ListBucketVersions"
                    ],
                    "Resource": "arn:aws:s3:::pramata-status-data-production-550090841262-us-east-1",
                    "Condition": {
                        "StringLike": {
                            "s3:prefix": [
                                "documents/*",
                                "subscribers/*",
                                "tokens/*",
                                "sends/*",
                                "ses-index/*",
                                "ledger/*",
                                "controls/*",
                                "indexes/*",
                                "incidents/*",
                                "incident-ids/*",
                                "published/*",
                                "monitoring/*",
                                "audit/*",
                                "locks/*",
                                "state/*"
                            ]
                        }
                    }
                }
            ]
        }
        """#

    /// The report's nine damaged lines, 1-based.
    static let damagedLines: Set<Int> = [26, 30, 34, 36, 38, 40, 50, 52, 54]

    // MARK: - Helpers

    final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    static func makeTerminal(cols: Int, rows: Int, scrollback: Int = 2000) -> Terminal {
        Terminal(delegate: Sink(), options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    /// Everything the buffer holds, through the same text extraction ⌘C's
    /// `getSelectedText` reaches (`getText` over the display buffer, which
    /// trims each row and joins a row marked wrapped onto the one before it).
    static func copyAll(_ terminal: Terminal) -> String {
        let end = Position(col: terminal.cols, row: terminal.buffer.yDisp + terminal.rows - 1)
        var text = terminal.getText(start: Position(col: 0, row: 0), end: end)
        // Only the end: the blank rows below the output. The start is the
        // JSON's own indentation.
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }

    /// The captain's paste, derived: each damaged line without its columns
    /// 54..<80. Measured against the report's `actual-copy.txt` while this was
    /// written - byte-identical.
    static func reportedDamage() -> String {
        reportedPolicy.components(separatedBy: "\n").enumerated().map { index, line in
            guard damagedLines.contains(index + 1) else { return line }
            let chars = Array(line)
            return String(chars[0..<54]) + String(chars[min(80, chars.count)...])
        }.joined(separator: "\n")
    }

    /// The report, replayed: the policy printed a line at a time at 80
    /// columns, and the width narrowed to 54 and came back while the cursor
    /// rested at the end of each damaged line, before its CR LF arrived.
    static func replayTheReport(shellRedrawsCursorLine: Bool) -> String {
        let terminal = makeTerminal(cols: 80, rows: 50)
        if shellRedrawsCursorLine { terminal.cursorLineRedrawnOnResize = { true } }
        for (index, line) in reportedPolicy.components(separatedBy: "\n").enumerated() {
            terminal.feed(text: line)
            if damagedLines.contains(index + 1) {
                terminal.resize(cols: 54, rows: 50)
                terminal.resize(cols: 80, rows: 50)
            }
            terminal.feed(text: "\r\n")
        }
        return copyAll(terminal)
    }

    static func firstDifference(_ got: String, _ want: String) -> String {
        let g = got.components(separatedBy: "\n"), w = want.components(separatedBy: "\n")
        for i in 0..<max(g.count, w.count) {
            let a = i < g.count ? g[i] : "<missing>", b = i < w.count ? w[i] : "<missing>"
            if a != b { return "line \(i + 1): got \"\(a)\", want \"\(b)\"" }
        }
        return "no difference"
    }

    /// A deterministic generator, so a failure names a reproducible trial.
    struct SplitMix64 {
        var state: UInt64
        mutating func next(_ range: ClosedRange<Int>) -> Int {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return range.lowerBound + Int(z % UInt64(range.count))
        }
    }

    // MARK: - The report

    private static func checkTheReportedCopyIsWholeAgain(_ ok: inout Bool) {
        // The fixture's discriminating power first: under upstream's rule (the
        // cursor line cut, as for a shell prompt) this replay is the captain's
        // paste, byte for byte. A replay that no longer damages anything would
        // make the next check pass for nothing.
        let underTheOldRule = replayTheReport(shellRedrawsCursorLine: true)
        check(underTheOldRule == reportedDamage(),
              "the replay reproduces the captain's paste under the old rule (\(firstDifference(underTheOldRule, reportedDamage())))", &ok)
        check(underTheOldRule.contains("pramata-status-data-prodt-1/state/*\""),
              "the old rule's copy has the reported `...-prodt-1/state/*`", &ok)

        let copied = replayTheReport(shellRedrawsCursorLine: false)
        check(copied == reportedPolicy,
              "the same replay now copies exactly the selected text (\(firstDifference(copied, reportedPolicy)))", &ok)
    }

    private static func checkOutputStillArrivingSurvivesTogglingWidths(_ ok: inout Bool) {
        let bytes = Array((reportedPolicy.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n").utf8)
        var failures: [String] = []
        for chunk in [16, 37, 64, 100, 256] {
            for every in [1, 2, 3, 5] {
                let terminal = makeTerminal(cols: 80, rows: 50)
                var offset = 0, reads = 0, narrow = false
                while offset < bytes.count {
                    let end = min(bytes.count, offset + chunk)
                    terminal.feed(byteArray: Array(bytes[offset..<end]))
                    offset = end
                    reads += 1
                    if reads % every == 0 {
                        narrow.toggle()
                        terminal.resize(cols: narrow ? 54 : 80, rows: 50)
                    }
                }
                terminal.resize(cols: 80, rows: 50)
                let copied = copyAll(terminal)
                if copied != reportedPolicy {
                    failures.append("\(chunk)-byte reads, width toggled every \(every): \(firstDifference(copied, reportedPolicy))")
                }
            }
        }
        check(failures.isEmpty, "output arriving in 16..256-byte reads while the width toggles 80/54 copies whole"
              + (failures.isEmpty ? "" : " - \(failures.count) of 20 did not, first: \(failures[0])"), &ok)
    }

    // MARK: - The cursor

    private static func checkTheCursorFollowsItsCharacter(_ ok: inout Bool) {
        // Line 26 is 92 characters: at 80 columns the cursor ends on its
        // wrapped row after `t-1/state/*"`, 12 cells in.
        let line = reportedPolicy.components(separatedBy: "\n")[25]
        let terminal = makeTerminal(cols: 80, rows: 30)
        terminal.feed(text: line)
        let printed = terminal.getCursorLocation()
        check(printed.x == 12 && printed.y == 1, "fixture: the cursor rests at (12, 1) after line 26 at 80 columns (got \(printed))", &ok)

        terminal.resize(cols: 54, rows: 30)
        let narrowed = terminal.getCursorLocation()
        check(narrowed.x == 38 && narrowed.y == 1,
              "narrowed to 54, the cursor is still after `/state/*\"` - (38, 1), got \(narrowed)", &ok)
        terminal.resize(cols: 80, rows: 30)
        let widened = terminal.getCursorLocation()
        check(widened.x == 12 && widened.y == 1, "widened back to 80, it is at (12, 1) again (got \(widened))", &ok)

        // And the next character lands after it, not on it.
        terminal.feed(text: ",")
        terminal.resize(cols: 54, rows: 30)
        terminal.feed(text: "!")
        terminal.resize(cols: 80, rows: 30)
        check(copyAll(terminal) == line + ",!", "characters printed between resizes join the line in order", &ok)

        // A cursor moved back into the middle of a line - a progress line, an
        // editor - with text after it. 160 characters fill two rows at 80 and
        // need three at 54, and the row the narrowing adds is below the cursor,
        // so the cursor must not move down with it.
        let long = String(repeating: "0123456789", count: 16)
        let middle = makeTerminal(cols: 80, rows: 30)
        middle.feed(text: long + "\u{1b}[1A\u{1b}[11G")
        let before = middle.getCursorLocation()
        check(before.x == 10 && before.y == 0, "fixture: the cursor is back at (10, 0) on the line's first row (got \(before))", &ok)
        middle.resize(cols: 54, rows: 30)
        let after = middle.getCursorLocation()
        check(after.x == 10 && after.y == 0, "narrowed to 54, a cursor with text after it stays on its character - (10, 0), got \(after)", &ok)
        middle.feed(text: "X")
        let overwritten = String(long.prefix(10)) + "X" + String(long.dropFirst(11))
        check(copyAll(middle) == overwritten, "the next character overwrites the one the cursor was on", &ok)

        // The same line filling the bottom two rows of a full screen, with the
        // cursor stepped up onto its first row. Its second row is below the
        // cursor and is text, not a blank row to give up: the row the
        // narrowing adds has to scroll the screen instead.
        let full = makeTerminal(cols: 80, rows: 11)
        let short = (0..<9).map { "line \($0)" }
        full.feed(text: short.joined(separator: "\r\n") + "\r\n" + long + "\u{1b}[1A\u{1b}[11G")
        let up = full.getCursorLocation()
        check(up.x == 10 && up.y == 9, "fixture: an 11-row screen, full, the cursor at (10, 9) on the long line's first row (got \(up))", &ok)
        full.resize(cols: 54, rows: 11)
        let scrolled = full.getCursorLocation()
        check(scrolled.x == 10 && scrolled.y == 8, "narrowed, the screen scrolls a row and the cursor stays on its character - (10, 8), got \(scrolled)", &ok)
        let want = (short + [long]).joined(separator: "\n")
        check(copyAll(full) == want, "no row of the line was given up (\(firstDifference(copyAll(full), want)))", &ok)
    }

    private static func checkACarriageReturnAwaitingItsLineFeedStaysAtTheLineStart(_ ok: inout Bool) {
        // A read that ends between a CR and its LF leaves the cursor at column
        // 0 of the line's last row. The LF must then start the next line below
        // the whole reflowed line, at column 0 - not on the line's own new
        // continuation row, and not part-way across.
        let lines = reportedPolicy.components(separatedBy: "\n")
        let cases: [(name: String, line: String, from: Int, to: Int)] = [
            ("a wrapped line, narrowing", lines[25], 80, 54),
            ("a wrapped line, widening", lines[25], 54, 80),
            ("a one-row line that narrowing wraps", lines[29], 80, 54),
        ]
        for c in cases {
            let terminal = makeTerminal(cols: c.from, rows: 30)
            terminal.feed(text: c.line + "\r")
            terminal.resize(cols: c.to, rows: 30)
            terminal.feed(text: "\nnext")
            let want = c.line + "\nnext"
            let copied = copyAll(terminal)
            check(copied == want, "CR before a resize, LF after - \(c.name) (\(firstDifference(copied, want)))", &ok)
        }
    }

    private static func checkAPendingWrapSurvivesAHeightOnlyResize(_ ok: inout Bool) {
        // 61 characters at 61 columns: the cursor is one past the last column,
        // a pending wrap. A resize that only changes the height used to clamp
        // it onto the last character, which the next one then overwrote.
        let text = String(lines61.prefix(61))
        let terminal = makeTerminal(cols: 61, rows: 40)
        terminal.feed(text: text)
        terminal.resize(cols: 61, rows: 13)
        terminal.feed(text: "Z")
        let copied = copyAll(terminal)
        check(copied == text + "Z", "a height-only resize keeps a pending wrap (got \"\(copied.suffix(8))\")", &ok)
    }

    private static let lines61 = String(repeating: "0123456789", count: 7)

    // MARK: - A wrap marks its own row

    private static func checkAWrapAfterAClearScreenMarksItsOwnRow(_ ok: inout Bool) {
        // Found while fuzzing the fix: an autowrap above the bottom row marked
        // scrollback row `y` as wrapped instead of the row being written. Any
        // scrollback plus a cleared screen (Ctrl-L, `clear` without its
        // scrollback erase) puts the cursor there, and then every long line
        // copied as two lines while two unrelated history lines copied as one.
        // Plain ASCII and wide characters wrap through two different paths
        // (`insertAsciiRun`, `insertCharacter`), and both had it.
        let wide = reportedPolicy.replacingOccurrences(of: "production", with: "prod日本語uction")
        for (label, text) in [("ASCII", reportedPolicy), ("wide characters", wide)] {
            let terminal = makeTerminal(cols: 80, rows: 40)
            let history = (0..<120).map { "history line \($0)" }
            terminal.feed(text: history.joined(separator: "\r\n") + "\r\n")
            terminal.feed(text: "\u{1b}[H\u{1b}[2J")
            check(terminal.buffer.yDisp > 0 && terminal.buffer.y == 0,
                  "fixture: the screen is clear, with history in the scrollback above it (yDisp \(terminal.buffer.yDisp), y \(terminal.buffer.y))", &ok)
            terminal.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")
            let copied = copyAll(terminal)
            let lines = copied.components(separatedBy: "\n")
            let joined = lines.filter { $0.hasPrefix("history line") && !history.contains($0) }
            check(joined.isEmpty, "\(label): no two history lines are joined (\(joined.first ?? "none"))", &ok)
            let policy = copied.range(of: "\n{\n").map { String(copied[copied.index(after: $0.lowerBound)...]) } ?? ""
            check(policy == text, "\(label): the policy printed after the clear copies whole (\(firstDifference(policy, text)))", &ok)
        }
    }

    // MARK: - The shell keeps upstream's redraw

    private static func checkAShellPromptIsStillRedrawnCleanly(_ ok: inout Bool) {
        // What zsh does after SIGWINCH, measured with a real zsh on a real PTY
        // while this was written: carriage return to column 0 of the row the
        // cursor is on, the prompt and the edit buffer again, then clear to
        // the end of the screen. With the cursor's line reflowed, the cursor
        // is on the line's second row and the first row is left behind as a
        // stale copy - which is why a shell at its prompt keeps upstream's cut.
        let typed = "% echo " + String(repeating: "abcdefghij", count: 7)
        func redrawAfterNarrowing(shellAtPrompt: Bool) -> String {
            let terminal = makeTerminal(cols: 80, rows: 20)
            terminal.cursorLineRedrawnOnResize = { shellAtPrompt }
            terminal.feed(text: typed)
            terminal.resize(cols: 54, rows: 20)
            terminal.feed(text: "\r" + typed + "\u{1b}[J")
            return copyAll(terminal)
        }
        let reflowed = redrawAfterNarrowing(shellAtPrompt: false)
        check(reflowed.components(separatedBy: "% echo").count - 1 == 2,
              "fixture: without the shell rule, the redraw leaves a stale prompt row (got \"\(reflowed)\")", &ok)
        let kept = redrawAfterNarrowing(shellAtPrompt: true)
        check(kept == typed, "a shell at its prompt redraws over its own line: one prompt, nothing stale (got \"\(kept)\")", &ok)
    }

    // MARK: - Nothing a resize does changes the text

    private static func checkRandomResizesNeverChangeTheText(_ ok: inout Bool) {
        // Random reads, random widths and heights, at a full scrollback and at
        // one small enough that the trim branches run. Seeded, so a failing
        // trial number reproduces. Wide characters ride along in a second pass.
        let wide = reportedPolicy
            .replacingOccurrences(of: "production", with: "prod日本語uction")
            .replacingOccurrences(of: "Allow", with: "Al🚀low")
        // The third pass also steps the cursor back into the line it is
        // printing before a resize - left along its row, or up a wrapped row -
        // and prints the same characters again after it, so the text must
        // still not change. That puts the cursor in the middle of a line, with
        // the line's own text after it and rows of it below. ASCII only, so a
        // row is exactly `cols` characters and the step back is exact.
        let passes: [(label: String, text: String, stepsBack: Bool)] = [
            ("ASCII", reportedPolicy, false),
            ("wide characters", wide, false),
            ("ASCII, cursor stepped back into the line", reportedPolicy, true),
        ]
        for (label, text, stepsBack) in passes {
            let bytes = Array((text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n").utf8)
            for scrollback in [2000, 30] {
                var rng = SplitMix64(state: 0x5EED_0000 + UInt64(scrollback) + (stepsBack ? 1 : 0))
                var failed: [Int] = []
                let trials = 300
                for trial in 0..<trials {
                    let terminal = makeTerminal(cols: rng.next(30...140), rows: rng.next(8...60), scrollback: scrollback)
                    var offset = 0
                    while offset < bytes.count {
                        let end = min(bytes.count, offset + rng.next(1...200))
                        terminal.feed(byteArray: Array(bytes[offset..<end]))
                        offset = end
                        if rng.next(0...2) == 0 {
                            let reprint = stepsBack ? stepBack(terminal, bytes: bytes, fed: offset, rng: &rng) : []
                            let rows = rng.next(0...1) == 0 ? terminal.rows : rng.next(8...60)
                            terminal.resize(cols: rng.next(30...140), rows: rows)
                            if !reprint.isEmpty { terminal.feed(byteArray: reprint) }
                        }
                    }
                    let copied = copyAll(terminal)
                    if scrollback >= 2000 {
                        if copied != text { failed.append(trial) }
                    } else {
                        // The oldest rows are gone, so what is left must be a
                        // tail of the text - apart from its first line, which
                        // may have lost its own head to the trim.
                        var kept = copied.components(separatedBy: "\n")
                        if !kept.isEmpty { kept.removeFirst() }
                        if !text.hasSuffix(kept.joined(separator: "\n")) { failed.append(trial) }
                    }
                }
                check(failed.isEmpty, "\(trials) random read/resize sequences, \(label), scrollback \(scrollback): the text is unchanged"
                      + (failed.isEmpty ? "" : " - \(failed.count) changed it, first trial \(failed[0])"), &ok)
            }
        }
    }

    /// Moves the cursor back over characters it just printed and returns them,
    /// for the caller to print again after its resize - or returns nothing and
    /// leaves the cursor alone. Never lands on column 0, which a carriage
    /// return owns (see `checkACarriageReturnAwaitingItsLineFeedStaysAtTheLineStart`).
    static func stepBack(_ terminal: Terminal, bytes: [UInt8], fed: Int, rng: inout SplitMix64) -> [UInt8] {
        // The characters of the line being printed, since its last LF.
        var start = fed
        while start > 0 && bytes[start - 1] != 10 { start -= 1 }
        let printed = fed - start
        guard printed > 0, bytes[fed - 1] != 13 else { return [] }
        let cols = terminal.cols
        // Where the cursor must be: a row is exactly `cols` characters.
        let expectedX = printed % cols == 0 ? cols : printed % cols
        guard terminal.buffer.x == expectedX else { return [] }
        if rng.next(0...1) == 0, expectedX > 1 {
            let k = rng.next(1...min(expectedX - 1, 40))
            terminal.feed(text: "\u{1b}[\(k)D")
            return Array(bytes[(fed - k)..<fed])
        }
        if printed > cols, expectedX < cols {
            terminal.feed(text: "\u{1b}[1A")
            return Array(bytes[(fed - cols)..<fed])
        }
        return []
    }

    // MARK: - The policy

    private static func checkTheForegroundShellClassification(_ ok: inout Bool) {
        for name in ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "dash"] {
            check(CockpitTerminalView.foregroundRedrawsCursorLine(processName: name), "\(name) at its prompt redraws its line", &ok)
        }
        for name in ["ssh", "Python", "python3", "cat", "claude", "herdr", "aws", "node", "zshx", "", nil] as [String?] {
            check(!CockpitTerminalView.foregroundRedrawsCursorLine(processName: name),
                  "\(name.map { "\"\($0)\"" } ?? "nil") does not, so its line is reflowed and kept", &ok)
        }
    }

    final class QuietChild: LocalProcessDelegate {
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
        func dataReceived(slice: ArraySlice<UInt8>) {}
        func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    }

    private static func checkTheForegroundIsReadFromARealPTY(_ ok: inout Bool) {
        // The answer comes from the PTY's foreground process group, which is
        // the shell itself while it sits at its prompt and the job once it runs
        // one. `exec` turns the same process into `sleep`, so one child shows
        // both states without a second launch.
        check(!CockpitTerminalView.foregroundRedrawsCursorLine(ptyDescriptor: -1), "no PTY answers no", &ok)
        let delegate = QuietChild()
        let child = LocalProcess(delegate: delegate, dispatchQueue: DispatchQueue(label: "TerminalResizeReflowSelfTest.pty"))
        child.startProcess(executable: "/bin/sh", args: ["-i"], environment: ["TERM=dumb", "PS1=$ ", "HOME=/tmp", "PATH=/usr/bin:/bin"])
        defer { child.terminate() }
        func eventually(_ want: Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if CockpitTerminalView.foregroundRedrawsCursorLine(ptyDescriptor: child.childfd) == want { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }
        check(eventually(true), "a shell at its prompt owns its PTY's foreground", &ok)
        child.send(data: Array("exec /bin/sleep 30\n".utf8)[...])
        check(eventually(false), "once the shell runs a job, the job owns it", &ok)
    }

    private static func checkCockpitTerminalViewInstallsThePolicy(_ ok: inout Bool) {
        // Every Console tab and split pane is a `CockpitTerminalView` built with
        // `init(frame:)`. A behavioural check would mount one, which this lane
        // cannot; this proves both initialisers still install the policy.
        guard let root = SelfTestSources.appSourceDirectory() else {
            fail("source root not found - this check cannot run", &ok)
            return
        }
        guard let source = try? String(contentsOf: root.appendingPathComponent("CockpitTerminalView.swift"), encoding: .utf8) else {
            fail("CockpitTerminalView.swift could not be read", &ok)
            return
        }
        let code = source.components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[..<comment.lowerBound])
            }
        let calls = code.filter { $0.contains("installResizeReflowPolicy()") && !$0.contains("func ") }.count
        check(calls == 2, "both initialisers call installResizeReflowPolicy() (found \(calls) calls)", &ok)
        check(code.contains { $0.contains("terminal?.cursorLineRedrawnOnResize =") },
              "installResizeReflowPolicy() sets the terminal's cursorLineRedrawnOnResize", &ok)
    }
}

#endif
