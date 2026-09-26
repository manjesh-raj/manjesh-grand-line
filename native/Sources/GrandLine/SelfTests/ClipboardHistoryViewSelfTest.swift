// Grand Line - native macOS app.
//
// The window-backed half of the clipboard history (F3 of full review #3 §8):
// the real ⌘⇧V panel, its real rows, its real ⌘1-⌘9/⌘P key equivalents, its
// three honest states, and one real off-screen render in both registers.
//
// **Why this is `NEEDS_SESSION` even though it builds no `OffScreenProbe`
// window.** `HelmBarPanel` constructs a real `NSPanel`, which is exactly what
// `E2ETestingPolicySelfTest.mountsAWindow` cannot see (its markers look for
// `OffScreenProbe.window(`/`NSWindow(contentRect` in the suite's own source).
// Hence the `# session-not-window:` marker on this suite's entry, the same
// per-entry escape hatch `FM_RUN_UNIFIED_SEARCH_LAYOUT_TESTS` carries.
//
// The panel is never shown - `HelmBarPanel.show(under:)` makes a real floating
// window key over whatever the captain is doing. Everything here drives the
// content controller and its own responder path, and the render goes through
// `cacheDisplay` into an off-screen bitmap.
//
// `FM_RUN_CLIPBOARD_HISTORY_VIEW_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ClipboardHistoryViewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        autoreleasepool {
            checkRowsRenderTheHistory(check)
            checkTheSkippedRowIsDrawnAndInert(check)
            checkDigitKeyEquivalentsPaste(check)
            checkPinChord(check)
            checkFilterNarrowsTheRows(check)
            checkEmptyAndUnavailableAreDifferent(check)
            checkTheLockGate(check)
            checkItPaintsInBothRegisters(check)
        }

        print(ok ? "ClipboardHistoryViewSelfTest: OK" : "ClipboardHistoryViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Fixture

    /// A panel over a history file that is **present but unopenable**: real
    /// bytes, a real key, and the two do not match.
    ///
    /// This is B17's exact state and the one `withPanel(key: nil)` cannot
    /// reach - that one has no key at all, so it fails `isAvailable`, which
    /// the picker has always read. `loadFailed` is the second state, and it
    /// is the one that rendered "Nothing copied yet" over a 200-entry file.
    private static func withCorruptPanel(_ body: (ClipboardHistoryPanelViewController,
                                                 ClipboardHistoryStore) -> Void) {
        autoreleasepool {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("grandline-clipboard-corrupt-\(UUID().uuidString)",
                                        isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("history.sealed")
            try? Data("this is not a sealed box".utf8).write(to: file)
            let store = ClipboardHistoryStore(fileURL: file, key: ClipboardHistoryKey.ephemeralKey())
            // The caller's first check asserts `loadFailed && isAvailable`,
            // so a store that stopped reaching that state fails loudly rather
            // than letting the assertions below pass vacuously.
            let content = ClipboardHistoryPanelViewController(store: store)
            content.loadView()
            content.reload()
            body(content, store)
        }
    }

    private static func withPanel(entries: [String],
                                  pinned: Set<String> = [],
                                  includeSkipped: Bool = false,
                                  key: CredentialVaultKey? = ClipboardHistoryKey.ephemeralKey(),
                                  _ body: (ClipboardHistoryPanelViewController, ClipboardHistoryStore) -> Void) {
        autoreleasepool {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("grandline-clipboard-view-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ClipboardHistoryStore(fileURL: root.appendingPathComponent("history.sealed"),
                                              key: key)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("grandline-clipboard-view-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            for (index, text) in entries.enumerated() {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                _ = store.record(from: pasteboard, sourceApp: "Console",
                                 now: Date(timeIntervalSinceNow: Double(index) - 600))
            }
            if includeSkipped {
                CredentialVaultClipboard.writeConcealed("hunter2", to: pasteboard)
                _ = store.record(from: pasteboard)
            }
            for text in pinned {
                if let entry = store.entries.first(where: { $0.text == text }) {
                    store.setPinned(true, id: entry.id)
                }
            }

            let content = ClipboardHistoryPanelViewController(store: store)
            content.loadView()
            content.reload()
            body(content, store)
        }
    }

    private static func commandKey(_ characters: String) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: 0)
    }

    // MARK: Rows

    private static func checkRowsRenderTheHistory(_ check: (Bool, String) -> Void) {
        withPanel(entries: ["kubectl -n raas get pods", "https://github.com/pull/425", "10.42.0.0/16"],
                  pinned: ["10.42.0.0/16"]) { content, _ in
            let rows = content.debugRows()
            check(rows.count == 3, "three rows are drawn, found \(rows.count)")
            check(content.debugEmptyStateIsHidden, "the empty state is hidden when there are rows")
            check(content.debugUnavailableStateIsHidden, "the unavailable state is hidden when the store has a key")
            check(content.shownEntries.first?.text == "10.42.0.0/16",
                  "the pinned entry sorts first, got \(String(describing: content.shownEntries.first?.text))")
            check(content.debugCountText.contains("3 items"),
                  "the header counts the entries, got \(content.debugCountText)")
            check(content.debugCountText.contains("encrypted"),
                  "the header says the history is encrypted, got \(content.debugCountText)")
        }
    }

    private static func checkTheSkippedRowIsDrawnAndInert(_ check: (Bool, String) -> Void) {
        withPanel(entries: ["ordinary"], includeSkipped: true) { content, _ in
            // The mockup draws the excluded entry rather than hiding it -
            // that is the judgment call its own note records, so it is
            // asserted rather than left to drift.
            check(content.debugRows().count == 2,
                  "the skipped marker is drawn, found \(content.debugRows().count) rows")
            guard let marker = content.shownEntries.first(where: { $0.kind == .skipped }) else {
                check(false, "no skipped marker among the shown entries")
                return
            }
            check(marker.preview.contains("Poneglyph"), "the marker explains itself")

            // And it cannot paste: clicking it, or resolving it by digit, must
            // do nothing at all.
            var pasted: [ClipboardHistoryEntry] = []
            content.onPaste = { pasted.append($0) }
            let markerIndex = (content.shownEntries.firstIndex { $0.kind == .skipped } ?? 0) + 1
            check(!content.activateRow(number: markerIndex),
                  "\u{2318}\(markerIndex) on the marker does nothing")
            check(pasted.isEmpty, "the marker pastes nothing, pasted \(pasted.count)")

            // The fixture's discriminating half: the *other* row does paste,
            // so "nothing happened" is a decision rather than a dead panel.
            let otherIndex = (content.shownEntries.firstIndex { $0.kind == .text } ?? 0) + 1
            check(content.activateRow(number: otherIndex), "an ordinary row does paste")
            check(pasted.first?.text == "ordinary", "and it is the right one")
        }
    }

    private static func checkDigitKeyEquivalentsPaste(_ check: (Bool, String) -> Void) {
        withPanel(entries: ["first", "second", "third"]) { content, _ in
            guard let root = content.debugRootView else {
                check(false, "the panel's root is not a ClipboardHistoryRootView")
                return
            }
            var pasted: [ClipboardHistoryEntry] = []
            content.onPaste = { pasted.append($0) }

            // Newest first, so ⌘1 is "third".
            guard let event = commandKey("1") else {
                check(false, "could not synthesise \u{2318}1")
                return
            }
            check(root.performKeyEquivalent(with: event), "\u{2318}1 is handled")
            check(pasted.first?.text == content.shownEntries.first?.text,
                  "\u{2318}1 pastes the top row, got \(String(describing: pasted.first?.text))")

            // A digit past the end falls through rather than being swallowed -
            // otherwise the panel would eat ⌘9 for the rest of the app.
            pasted.removeAll()
            if let nine = commandKey("9") {
                check(!root.performKeyEquivalent(with: nine), "\u{2318}9 with three rows falls through")
                check(pasted.isEmpty, "and pastes nothing")
            }
        }
    }

    private static func checkPinChord(_ check: (Bool, String) -> Void) {
        withPanel(entries: ["first", "second"]) { content, store in
            guard let root = content.debugRootView, let pin = commandKey("p") else {
                check(false, "could not drive \u{2318}P")
                return
            }
            let top = content.shownEntries.first
            check(top?.isPinned == false, "the top row starts unpinned")
            check(root.performKeyEquivalent(with: pin), "\u{2318}P is handled")
            check(store.entries.first { $0.id == top?.id }?.isPinned == true,
                  "\u{2318}P pins the top row")
            // And it toggles, rather than only ever pinning.
            check(root.performKeyEquivalent(with: pin), "\u{2318}P is handled again")
            check(store.entries.first { $0.id == top?.id }?.isPinned == false,
                  "\u{2318}P unpins it again")
        }
    }

    private static func checkFilterNarrowsTheRows(_ check: (Bool, String) -> Void) {
        withPanel(entries: ["kubectl -n raas get pods", "https://github.com/pull/425"]) { content, _ in
            check(content.debugRows().count == 2, "both rows before filtering")
            content.debugSetFilter("kubectl")
            check(content.debugRows().count == 1,
                  "the filter narrows the drawn rows, found \(content.debugRows().count)")
            content.debugSetFilter("nothing matches this")
            check(content.debugRows().isEmpty, "a filter with no matches draws no rows")
            check(!content.debugEmptyStateIsHidden, "and shows the empty state")
            content.debugSetFilter("")
            check(content.debugRows().count == 2, "clearing the filter restores both rows")
        }
    }

    /// GL-14: "nothing copied yet" and "the key could not be read" are
    /// different states and must not look alike.
    private static func checkEmptyAndUnavailableAreDifferent(_ check: (Bool, String) -> Void) {
        withPanel(entries: []) { content, _ in
            check(!content.debugEmptyStateIsHidden, "an empty history shows the empty state")
            check(content.debugUnavailableStateIsHidden, "an empty history is not 'unavailable'")
            check(content.debugCountText.contains("0 items"),
                  "an empty history counts zero, got \(content.debugCountText)")
        }
        withPanel(entries: [], key: nil) { content, _ in
            check(!content.debugUnavailableStateIsHidden, "a keyless history shows the unavailable state")
            check(content.debugEmptyStateIsHidden, "and NOT the empty state")
            check(content.debugCountText == "unavailable",
                  "and never counts zero items, got \(content.debugCountText)")
        }
        // B17: present-but-unopenable, which is neither "empty" nor "no key".
        withCorruptPanel { content, store in
            check(store.loadFailed && store.isAvailable,
                  "fixture: an unopenable file with a real key is the state B17 is about, "
                  + "got loadFailed=\(store.loadFailed) isAvailable=\(store.isAvailable)")
            check(!content.debugUnavailableStateIsHidden,
                  "a history that could not be opened says so (GL-14) - it read "
                  + "\"Nothing copied yet\" over a 200-entry file")
            check(content.debugEmptyStateIsHidden,
                  "and NOT the empty state - those are different sentences")
            check(content.debugCountText == "unavailable",
                  "and never counts zero items, got \(content.debugCountText)")
        }
    }

    /// GL-09: ⌘⇧V has its own `AppLockedSurface` case, and it is the gate the
    /// controller actually asks.
    private static func checkTheLockGate(_ check: (Bool, String) -> Void) {
        let gate = AppLockGate.shared
        check(!gate.allows(.clipboardHistory) == gate.isLocked,
              "the clipboard history consults the same gate as every other walk-up surface")
        // Its own case, not a neighbour's - a suite asserting ⌘K's gate would
        // otherwise pass with this one deleted (§5.2's own lesson).
        check(AppLockedSurface.clipboardHistory != AppLockedSurface.unifiedSearch,
              "clipboard history has its own locked-surface case")
    }

    // MARK: Painting

    private static func checkItPaintsInBothRegisters(_ check: (Bool, String) -> Void) {
        withPanel(entries: ["kubectl -n raas get pods", "10.42.0.0/16"],
                  pinned: ["10.42.0.0/16"],
                  includeSkipped: true) { content, _ in
            for id in ["dusk", "daylight"] {
                guard let palette = HelmTheme.theme(id: id) else {
                    check(false, "theme \(id) is not a real palette any more - fixture is stale")
                    continue
                }
                ThemeManager.shared.setTheme(palette)
                content.applyTheme(ThemeManager.shared.theme)
                let root = content.view
                root.layoutSubtreeIfNeeded()

                check(root.fittingSize.width == ClipboardHistoryPanelViewController.width,
                      "\(id): the panel holds its 540pt width, got \(root.fittingSize.width)")
                check(root.fittingSize.height > 160,
                      "\(id): the panel has real height, got \(root.fittingSize.height)")

                guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                    check(false, "\(id): could not build a bitmap rep")
                    continue
                }
                root.cacheDisplay(in: root.bounds, to: rep)

                // Not blank: a panel that laid out and drew nothing would pass
                // every assertion above. Sample a grid and require more than
                // one distinct colour, in `rep.colorSpace` (AGENTS.md's probe
                // rule) and in pixels rather than points.
                let scaleX = CGFloat(rep.pixelsWide) / max(root.bounds.width, 1)
                let scaleY = CGFloat(rep.pixelsHigh) / max(root.bounds.height, 1)
                var seen = Set<String>()
                for fx in stride(from: 0.1, through: 0.9, by: 0.1) {
                    for fy in stride(from: 0.1, through: 0.9, by: 0.1) {
                        let x = Int(root.bounds.width * CGFloat(fx) * scaleX)
                        let y = Int(root.bounds.height * CGFloat(fy) * scaleY)
                        guard x < rep.pixelsWide, y < rep.pixelsHigh,
                              let colour = rep.colorAt(x: x, y: y) else { continue }
                        let c = HelmContrast.components(colour)
                        seen.insert(String(format: "%.2f-%.2f-%.2f", c.0, c.1, c.2))
                    }
                }
                check(seen.count > 3,
                      "\(id): the panel really draws - \(seen.count) distinct sampled colours")
            }
        }
    }
}

#endif
