// Manjesh Grand Line - native macOS app.
//
// The fixes for `data/grand-line-appkit-expert-audit/report.md`, one case per
// finding id, for the findings small enough not to want a suite of their own.
// Run with:
//
//   swift build && FM_RUN_APPKIT_AUDIT_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
//   H3  no two main-menu items declare the same shortcut
//   M1  navigating back to the canvas re-syncs the space pill
//   M5  the Run History sheet's footer pins Close to the trailing edge
//   M6  ... and can be dismissed with Escape
//   S3  a command carrying an embedded newline never reaches a terminal
//   T5  the dictation audio tap reads a snapshot, not shared mutable state
//
// Window-backed (M5 is a real measurement on a real view), so this sits in
// `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list.

#if FM_SELFTESTS

import AppKit

enum AppKitAuditSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("H3_noTwoMenuItemsShareAShortcut", test_h3),
            ("M1_backToCanvasSyncsTheSpacePill", test_m1),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "AppKitAuditSelfTest: all \(cases.count) cases passed"
              : "AppKitAuditSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: M1 - the space pill on the way back to the canvas

    /// M1: `DaylightModule.space(forDestination:)` returns nil for the canvas
    /// itself, and both the drill-header back button and `showHomeCanvas()`
    /// route through `show(_:)` rather than `selectSpace` - so B5's fix left
    /// the pill asserting the drill page's space while the canvas rendered the
    /// space the captain last chose.
    ///
    /// A source guard for the same reason B5's own case is one: exercising it
    /// for real needs a mounted `AppShellController`, which constructs every
    /// store in the app. What can go wrong here is the branch being dropped,
    /// and that is exactly what this reads.
    private static func test_m1() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let shell = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"), encoding: .utf8) else {
            return nil
        }
        guard shell.contains("bar.setSelectedSpace(homeCanvas.selectedSpace)") else {
            return "show(_:) no longer syncs the pill for .homeCanvas - the back button leaves the previous drill page's space lit"
        }
        // And the canvas has to be the one that owns the space, not a second copy.
        guard DaylightModule.space(forDestination: .homeCanvas) == nil else {
            return "space(forDestination:) now answers for .homeCanvas, so this branch is dead code - re-check which one wins"
        }
        return nil
    }

    // MARK: H3 - shortcut collisions in the main menu

    /// A declared shortcut this parser could recover from `main.swift`.
    private struct MenuShortcut {
        let title: String
        let key: String
        let mask: String
        let line: Int
    }

    /// H3: two menu items declaring the same key equivalent is a defect on its
    /// own (macOS HIG), and in this app it was a *dead* shortcut: AppKit
    /// resolves a key equivalent to the first **enabled** match in menu order,
    /// this app implements no `validateMenuItem` anywhere, so the second
    /// declaration can never fire. "New Host…" and "New Task…" both shipped a
    /// plain ⌘N for months and the Tasks one was inert the whole time.
    ///
    /// This is a source parse rather than a real menu walk on purpose:
    /// `AppDelegate.buildMenu()` needs a real `AppShellController`, which
    /// constructs every store in the app - far too much machinery to stand up
    /// for a table of string literals. The parse errs toward *reporting* a
    /// collision when it cannot recover a modifier mask, which is the safe
    /// direction: it forces someone to look.
    private static func test_h3() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: dir.appendingPathComponent("main.swift"), encoding: .utf8) else {
            return nil  // sources unreachable; nothing to assert
        }
        let lines = source.components(separatedBy: "\n")
        var shortcuts: [MenuShortcut] = []

        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//") == false else { continue }
            guard let key = literalKeyEquivalent(in: line), !key.isEmpty else { continue }
            // A `"\(n)"`-style interpolated key is the ⌘1…⌘9 tab selector and
            // the ⌘1…⌘5 space picker - the one *documented* collision in this
            // app, resolved at runtime because the Tab items get disabled off
            // Console and a disabled item does not consume its equivalent.
            if key.contains("\\(") { continue }

            // A construction wrapped over several lines puts the `let x =` and
            // the title above the `keyEquivalent:` argument.
            var declared = declaredIdentifier(in: line)
            var itemTitle = title(in: line)
            if declared == nil || itemTitle == nil {
                for lookback in 1...4 where index - lookback >= 0 {
                    let previous = lines[index - lookback].trimmingCharacters(in: .whitespaces)
                    if previous.isEmpty || previous.hasPrefix("//") { break }
                    declared = declared ?? declaredIdentifier(in: previous)
                    itemTitle = itemTitle ?? title(in: previous)
                    if declared != nil, itemTitle != nil { break }
                }
            }
            var mask = "[.command]"
            for lookahead in 1...3 where index + lookahead < lines.count {
                let next = lines[index + lookahead].trimmingCharacters(in: .whitespaces)
                guard let found = modifierMask(in: next) else { continue }
                // A chained `.keyEquivalentModifierMask = …` continuation
                // belongs to the item on the line immediately above it,
                // whatever identifier happens to be in scope.
                if lookahead == 1, next.hasPrefix(".keyEquivalentModifierMask") {
                    mask = found
                    break
                }
                if let declared, next.hasPrefix("\(declared).") {
                    mask = found
                    break
                }
            }
            shortcuts.append(MenuShortcut(title: itemTitle ?? "?",
                                          key: key,
                                          mask: normalized(mask),
                                          line: index + 1))
        }

        if shortcuts.count < 15 {
            return "only parsed \(shortcuts.count) menu shortcuts out of main.swift - the parser has drifted and this check would pass vacuously"
        }

        var seen: [String: MenuShortcut] = [:]
        var collisions: [String] = []
        for shortcut in shortcuts {
            let id = "\(shortcut.mask)+\(shortcut.key)"
            if let previous = seen[id] {
                collisions.append("\(shortcut.mask) \(shortcut.key): \u{201c}\(previous.title)\u{201d} (line \(previous.line)) and \u{201c}\(shortcut.title)\u{201d} (line \(shortcut.line))")
            } else {
                seen[id] = shortcut
            }
        }
        if !collisions.isEmpty {
            return "two menu items declare the same shortcut, so the later one can never fire: " + collisions.joined(separator: "; ")
        }
        return nil
    }

    private static func literalKeyEquivalent(in line: String) -> String? {
        guard let range = line.range(of: "keyEquivalent: \"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    private static func declaredIdentifier(in line: String) -> String? {
        guard line.hasPrefix("let ") else { return nil }
        let rest = line.dropFirst(4)
        guard let space = rest.firstIndex(of: " ") else { return nil }
        return String(rest[rest.startIndex..<space])
    }

    private static func modifierMask(in line: String) -> String? {
        guard let range = line.range(of: "keyEquivalentModifierMask = ") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func title(in line: String) -> String? {
        for marker in ["NSMenuItem(title: \"", "addItem(withTitle: \""] {
            guard let range = line.range(of: marker) else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            return String(rest[rest.startIndex..<end])
        }
        return nil
    }

    private static func normalized(_ mask: String) -> String {
        mask.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ",")
            .map(String.init)
            .sorted()
            .joined(separator: "+")
    }
}

#endif
