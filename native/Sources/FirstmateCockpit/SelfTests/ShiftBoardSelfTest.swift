// Manjesh Grand Line - native macOS app.
//
// The Kanban board's pure logic (`fm/grandline-tasks-kanban-devops-split`):
// the column/status mapping and the per-project colour.
//
// Deliberately split from `ShiftBoardViewSelfTest`, per this app's own
// convention: the window-driving half needs a real session and sits in
// `run-all-tests.sh`'s `NEEDS_SESSION` list, while everything here is plain
// values and runs in CI. Both halves matter and they fail for different
// reasons - a column mapped to the wrong status is invisible in a render,
// and a card that never starts a drag is invisible in a value check.
//
// Run with `FM_RUN_SHIFT_BOARD_TESTS=1 .build/debug/FirstmateCockpit`.

#if FM_SELFTESTS

import AppKit

enum ShiftBoardSelfTest {

    static func run() -> Bool {
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        // MARK: The column table
        //
        // Typed out as literals rather than derived from the enum: a check
        // that reads the table it is checking asserts nothing, which is the
        // same reason `DaylightModuleSelfTest.checkSpaceTable` restates its
        // own space membership by hand.

        check(ShiftBoardColumn.allCases.map(\.rawValue) == ["backlog", "inProgress", "done"],
              "the board's columns should be Backlog, In Progress, Done in that order, got "
              + "\(ShiftBoardColumn.allCases.map(\.rawValue))")

        check(ShiftBoardColumn.backlog.status == .todo, "Backlog should map to .todo")
        check(ShiftBoardColumn.inProgress.status == .inProgress, "In Progress should map to .inProgress")
        check(ShiftBoardColumn.done.status == .completed, "Done should map to .completed")

        check(ShiftBoardColumn.column(for: .todo) == .backlog, "a .todo task belongs in Backlog")
        check(ShiftBoardColumn.column(for: .inProgress) == .inProgress, "an .inProgress task belongs in In Progress")
        check(ShiftBoardColumn.column(for: .completed) == .done, "a .completed task belongs in Done")

        // The load-bearing one: a cancelled task is deliberately NOT on the
        // board. Giving it a column would put abandoned work back in front of
        // the captain on the one surface that is meant to show what is live.
        check(ShiftBoardColumn.column(for: .cancelled) == nil,
              "a cancelled task must have no column - it is filtered off the board entirely")

        // Every status is accounted for: a fifth `ShiftTaskStatus` added later
        // would fail to compile against `column(for:)`'s exhaustive switch,
        // but a status quietly *re-pointed* at an existing column would not,
        // so the three positive mappings above are asserted individually.
        let mapped = ShiftTaskStatus.allCases.compactMap(ShiftBoardColumn.column(for:))
        check(Set(mapped) == Set(ShiftBoardColumn.allCases),
              "every board column should be the target of exactly one status, got \(Set(mapped))")

        // MARK: Per-project colour

        // Determinism across calls is the easy half.
        let id = UUID().uuidString
        check(ShiftProjectPalette.tint(forProjectID: id) == ShiftProjectPalette.tint(forProjectID: id),
              "the same project id should always resolve to the same tint")

        // The half that actually matters: the hash must not be Swift's own,
        // which is randomly seeded per process - a project would change
        // colour on every launch and differ between the captain's machines.
        // These are literal expected values, computed from FNV-1a's published
        // definition, so a swap to `hashValue` fails here rather than passing
        // a "same answer twice in one process" check.
        let knownVectors: [(String, UInt64)] = [
            ("", 0xcbf2_9ce4_8422_2325),
            ("a", 0xaf63_dc4c_8601_ec8c),
            ("foobar", 0x85944171f73967e8),
        ]
        for (input, expected) in knownVectors {
            let actual = ShiftProjectPalette.fnv1a(input)
            check(actual == expected,
                  "FNV-1a(\"\(input)\") should be \(String(expected, radix: 16)), "
                  + "got \(String(actual, radix: 16)) - the hash must be the published, "
                  + "process-stable one, never String.hashValue")
        }

        // A task with no project gets the ink tone, never one of the six
        // identity hues - that is what keeps "no project" visually distinct
        // from "some project".
        check(ShiftProjectPalette.tint(forProjectID: nil) == .neutral,
              "a task with no project should take .neutral")
        check(ShiftProjectPalette.tint(forProjectID: "") == .neutral,
              "an empty project id should take .neutral, not hash to a colour")
        check(!ShiftProjectPalette.tints.contains(.neutral),
              ".neutral must stay out of the identity rotation, or a real project "
              + "could be coloured identically to a task with no project at all")

        // Every hue in the rotation is genuinely reachable, so the palette is
        // six colours rather than six declarations and two colours in
        // practice.
        var seen = Set<Int>()
        for n in 0..<400 {
            let tint = ShiftProjectPalette.tint(forProjectID: "project-\(n)")
            if let index = ShiftProjectPalette.tints.firstIndex(where: { $0 == tint }) { seen.insert(index) }
        }
        check(seen.count == ShiftProjectPalette.tints.count,
              "all \(ShiftProjectPalette.tints.count) project tints should be reachable, only \(seen.count) were")

        // MARK: The drag payload
        //
        // A private pasteboard type, not `.string`: a text drag from anywhere
        // else in the app - or from another app entirely - must never be
        // readable as a task id and dropped into a column.

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shift-board-selftest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([ShiftBoardPasteboard.item(taskID: "task-42")])
        check(ShiftBoardPasteboard.taskID(from: pasteboard) == "task-42",
              "a card's pasteboard item should round-trip its task id")

        pasteboard.clearContents()
        pasteboard.setString("task-42", forType: .string)
        check(ShiftBoardPasteboard.taskID(from: pasteboard) == nil,
              "a plain string drag must not be readable as a task id")

        return report(failures)
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[ShiftBoardSelfTest] all checks passed")
            return true
        }
        print("[ShiftBoardSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}

#endif
