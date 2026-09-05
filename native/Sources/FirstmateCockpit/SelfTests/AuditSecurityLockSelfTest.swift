// Manjesh Grand Line - native macOS app.
//
// The window-backed half of the full-app audit's §5.1
// (`data/grandline-full-app-audit/report.md`), fixed in
// `fm/grandline-audit-security-fixes`. Run with:
//
//   swift build && FM_RUN_AUDIT_SECURITY_LOCK_TESTS=1 .build/debug/FirstmateCockpit
//
// Separate from `AuditSecurityFixesSelfTest` because this one builds the two
// *real* palettes, and a real `NSPanel` plus `HelmSearchField` is what puts a
// suite in `run-all-tests.sh`'s `NEEDS_SESSION` list (`FM_RUN_UNIFIED_SEARCH_
// LAYOUT_TESTS` is there for the same reason). The pure-logic §5 checks stay
// in CI rather than being dragged out of it by this - the same split
// `FM_RUN_WHITEBOARD_TESTS` / `FM_RUN_WHITEBOARD_VIEW_TESTS` already uses.
//
// What this pins that a source guard cannot: that the registration a call site
// *makes* actually lands on the gate, resolving to that palette's own window.
// A `registerSecondaryWindow { nil }`, a closure capturing the wrong window,
// or a second controller instance registering instead of the shared one all
// read as correct in the source and all leave the palette on screen over the
// lock screen.
//
// Deliberately never orders a panel front: this app shares one bundle identity
// with the captain's real running instance, so a suite must not put a window
// on their screen. Registration is read back from the gate instead, and the
// order-out behaviour itself is pre-existing and already covered by
// `AppLockGate`'s own logic.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum AuditSecurityLockSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        // `.shared`, never `NSApp`: `NSApp` is an implicitly-unwrapped
        // `NSApplication!` that stays nil until something has touched
        // `NSApplication.shared`, and this suite's first AppKit call is this
        // one - see AGENTS.md's note on the same trap.
        NSApplication.shared.setActivationPolicy(.accessory)

        print("== full-app audit §5.1: always-open palettes register with the lock gate ==")

        let gate = AppLockGate.shared
        let wasLocked = gate.isLocked
        // Unlocked while the controllers are built: `registerSecondaryWindow`
        // orders a window out immediately when it registers into a *locked*
        // gate, and a locked gate is not the state a palette is created in.
        gate.setLocked(false)
        defer { gate.setLocked(wasLocked) }

        let before = Set(gate.debugRegisteredWindows.map(ObjectIdentifier.init))

        // ⌘K. A bare index with no providers is enough - this is about the
        // panel reaching the gate, not about what the palette can find.
        let search = UnifiedSearchController(index: UnifiedSearchIndex())
        guard let searchPanel = search.window else {
            check(false, "the ⌘K palette built no window at all")
            return report(failures)
        }

        // ⌥Space. Its store is pointed at a scratch directory: `ShiftStore()`
        // with no override resolves to `ShiftGitSync.shared`, i.e. a real
        // clone of the captain's own config repo.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-security-lock-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }

        let capture = ShiftQuickCaptureController(store: ShiftStore())
        guard let capturePanel = capture.window else {
            check(false, "⌥Space quick capture built no window at all")
            return report(failures)
        }

        let after = gate.debugRegisteredWindows
        let added = after.filter { !before.contains(ObjectIdentifier($0)) }

        check(added.contains { $0 === searchPanel },
              "the ⌘K palette's own panel is registered with the lock gate (§5.1)")
        check(added.contains { $0 === capturePanel },
              "⌥Space quick capture's own panel is registered with the lock gate (§5.1)")

        // Both are `.floating`, which is *why* they need registering: the lock
        // overlay is a subview of the main window, so it cannot cover them.
        check(searchPanel.level == .floating && capturePanel.level == .floating,
              "both panels are still `.floating` - the premise of the finding")

        // Each palette refuses to open while locked, through its own gate case
        // (§5.2). Driven through the real `present()`, so a call site that
        // stopped consulting the gate fails here rather than only in a grep.
        gate.setLocked(true)
        search.present()
        capture.present()
        check(!searchPanel.isVisible, "a locked app does not open the ⌘K palette")
        check(!capturePanel.isVisible, "a locked app does not open ⌥Space quick capture")

        // ...and the refusal is genuinely each palette's own case, not one
        // borrowed from the other. Allowing `.quickCapture` alone must not
        // let the search palette through.
        check(!gate.allows(.unifiedSearch) && !gate.allows(.quickCapture),
              "both cases are refused while locked")

        gate.setLocked(false)

        return report(failures)
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[AuditSecurityLockSelfTest] PASS")
            return true
        }
        for f in failures { print("[AuditSecurityLockSelfTest] FAIL: \(f)") }
        return false
    }
}

#endif
