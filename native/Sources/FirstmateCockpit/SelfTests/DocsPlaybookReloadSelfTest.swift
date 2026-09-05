// Manjesh Grand Line - native macOS app.
//
// Regression coverage for `fm/grandline-docs-webview-cache-fix`, which shipped
// with none - the full-app audit's §7 named it directly.
//
// **The bug.** `DocsController.loadDocsIfAvailable()` used to call
// `webView.loadFileURL(...)` every time, including when re-invoked after a
// sync brought new content down. `WKWebView` caches a `file://` page's
// *subresources* in memory once loaded, and re-calling `loadFileURL` on the
// same URL does not refetch them - the main `index.html` document refreshes
// and `script.js` does not. The DevOps Playbook builds its entire shelf/library
// UI at runtime from that script, so freshly-synced content stayed invisible
// until the whole app was quit and relaunched.
//
// Confirmed at the time NOT to work: cache-busting the URL's query string,
// `URLRequest` cache-policy overrides, and a non-persistent
// `WKWebsiteDataStore`. The fix is `webView.reload()` for every load after the
// first, which does force a fresh subresource fetch.
//
// **Why this suite drives a real page rather than reading the source.** The
// property under test is WebKit's, not this app's: "does a second load pick up
// a changed `script.js`". A source guard asserting `reload()` appears in
// `loadDocsIfAvailable` would pass for any of the three fixes above that were
// measured NOT to work. So this seeds a real scratch Playbook, loads it,
// changes the script on disk, drives the real Reload button, and reads back
// through `evaluateJavaScript` which version of the script actually ran.
//
// Window-backed (`NEEDS_SESSION`): a `WKWebView` needs a real window and a
// live web content process, exactly like its `FM_RUN_WHITEBOARD_VIEW_TESTS` /
// `FM_RUN_CODE_PREVIEW_VIEW_TESTS` peers.
//
// Run with:
//   swift build && FM_RUN_DOCS_PLAYBOOK_RELOAD_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import WebKit

enum DocsPlaybookReloadSelfTest {

    /// Set before anything can touch `DocsStore.folderURL`, which is a
    /// `static let` and therefore resolves its override exactly once per
    /// process. A suite that seeds it later would silently test the real
    /// synced Playbook directory instead of its own scratch one.
    private static let scratch: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docs-playbook-reload-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_DOCS_DIR", dir.path, 1)
        return dir
    }()

    static func run() -> Bool {
        _ = scratch
        // `NSApplication.shared`, not `NSApp`: the latter is an implicitly
        // unwrapped optional that stays nil until the former has been touched
        // at least once, and this suite reaches it before building any window
        // (AGENTS.md records the same trap for a suite whose first AppKit call
        // is not a window). A window is only composited - and a web view only
        // given a live content process - for a process that is a UI app, so
        // the policy has to be set before the first `orderFront`.
        NSApplication.shared.setActivationPolicy(.accessory)

        var ok = true
        checkASecondLoadPicksUpAChangedSubresource(&ok)
        checkTheSyncNotificationPathReloadsToo(&ok)
        print(ok ? "DocsPlaybookReloadSelfTest: all checks passed"
                 : "DocsPlaybookReloadSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL: \(message)")
        ok = false
    }

    // MARK: A real scratch Playbook

    /// `index.html` plus the separate `script.js` that carries the version
    /// marker. The split is the whole point: the document is what
    /// `loadFileURL` refreshes and the script is the subresource it does not.
    private static func seedPlaybook(scriptVersion: String) {
        let index = """
        <!doctype html><html><head><meta charset="utf-8"><title>Playbook</title></head>
        <body><div id="shelf">placeholder</div><script src="script.js"></script></body></html>
        """
        let script = """
        window.__playbookVersion = "\(scriptVersion)";
        document.getElementById("shelf").textContent = "built by \(scriptVersion)";
        """
        try? index.write(to: scratch.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try? script.write(to: scratch.appendingPathComponent("script.js"), atomically: true, encoding: .utf8)
        // `DocsStore.isSynced` only requires index.html, but the sidecar is
        // what a real sync leaves behind - seed it so this fixture is honest.
        try? "0000000000000000000000000000000000000000"
            .write(to: scratch.appendingPathComponent(".synced-commit"), atomically: true, encoding: .utf8)
    }

    private static func mount(_ controller: NSViewController) -> NSWindow {
        // Ordered front so WebKit gives the page a live content process, but
        // positioned far off-screen: this machine may be running the captain's
        // own instance, and a suite must never put a window on their display.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// `window.__playbookVersion` from the live page, or `nil` while the page
    /// has not finished loading a script that sets it.
    private static func loadedVersion(_ webView: WKWebView) -> String? {
        var result: String?
        var done = false
        webView.evaluateJavaScript("window.__playbookVersion || null") { value, _ in
            result = value as? String
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return result
    }

    /// Polls until the page reports `expected`, or gives up. Returns whatever
    /// it last saw, so a failure can report the real value rather than only
    /// "timed out".
    @discardableResult
    private static func waitForVersion(_ webView: WKWebView, expected: String, timeout: TimeInterval = 15) -> String? {
        var last: String?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            last = loadedVersion(webView)
            if last == expected { return last }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return last
    }

    // MARK: Checks

    /// The regression itself: seed v1, load, rewrite the script to v2 on disk,
    /// press the real Reload button, and require the page to report v2.
    ///
    /// Confirmed to catch the real bug: reverting `loadDocsIfAvailable` to an
    /// unconditional `loadFileURL` leaves this reporting v1 after the reload.
    private static func checkASecondLoadPicksUpAChangedSubresource(_ ok: inout Bool) {
        seedPlaybook(scriptVersion: "v1")
        let docs = DocsController()
        let window = mount(docs)
        defer { window.orderOut(nil) }

        guard let first = waitForVersion(docs.debugPlaybookWebView, expected: "v1"), first == "v1" else {
            fail("the scratch Playbook never loaded at all (page reported \(String(describing: loadedVersion(docs.debugPlaybookWebView)))) "
                 + "- the fixture or FM_DOCS_DIR override is wrong, so the rest of this check would be vacuous", &ok)
            return
        }

        // The state a real sync leaves behind: same URL, different bytes.
        seedPlaybook(scriptVersion: "v2")

        // Drive the real toolbar control, not the handler - a Reload button
        // wired to nothing would otherwise pass this suite.
        docs.debugReloadButton.performClick(nil)

        let after = waitForVersion(docs.debugPlaybookWebView, expected: "v2")
        if after != "v2" {
            fail("after a reload the page still reports \(after ?? "nil"), not v2 - a second load is not "
                 + "refetching script.js. This is the WKWebView subresource-cache bug: `loadDocsIfAvailable` "
                 + "must call `webView.reload()` for every load after the first, never `loadFileURL` again.", &ok)
        }
    }

    /// The path the bug was actually reported through: a completed sync fires
    /// `DocsSyncCenter`, whose observer calls the same loader. Worth its own
    /// case because that observer is registered in `loadView` and is easy to
    /// drop while refactoring, and losing it means synced content stays
    /// invisible until the page is navigated away from and back.
    private static func checkTheSyncNotificationPathReloadsToo(_ ok: inout Bool) {
        seedPlaybook(scriptVersion: "s1")
        let docs = DocsController()
        let window = mount(docs)
        defer { window.orderOut(nil) }

        guard waitForVersion(docs.debugPlaybookWebView, expected: "s1") == "s1" else {
            fail("the scratch Playbook never loaded for the sync-path case", &ok)
            return
        }

        seedPlaybook(scriptVersion: "s2")
        DocsSyncCenter.notifySynced()

        let after = waitForVersion(docs.debugPlaybookWebView, expected: "s2")
        if after != "s2" {
            fail("a DocsSyncCenter notification left the page reporting \(after ?? "nil"), not s2 - "
                 + "freshly-synced Playbook content would stay invisible until relaunch", &ok)
        }
    }
}

#endif
