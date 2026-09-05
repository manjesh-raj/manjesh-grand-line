// Manjesh Grand Line - native macOS app.
//
// The window-backed half of the Code Preview destination's coverage
// (`fm/grandline-monaco-code-preview`): the real `CodePreviewController` in a
// real window, loading the real vendored Monaco bundle, driven through the real
// bridge.
//
// Split from `CodePreviewSelfTest` because everything here needs a window
// server and a live web content process - so this suite sits in
// `run-all-tests.sh`'s `NEEDS_SESSION` list beside its window-backed peers,
// while the logic suite runs in CI.
//
// What it is for, in order of how much it matters:
//
//   1. **Highlighting genuinely happens.** This is the whole feature, and it
//      is the one thing no amount of Swift-side testing can see: a language id
//      that crosses the bridge proves nothing about whether Monaco tokenized
//      anything. So the page exposes `tokensAt`, which runs Monaco's *own*
//      tokenizer over a line and hands back the token types it produced - and
//      this suite asserts a Swift keyword is tokenized as a keyword and a
//      string as a string, in a real editor holding real pasted code.
//   2. **Persistence round-trips.** An edit has to reach the store, and a
//      second mount of a controller over the same folder has to find it. That
//      is the captain's own "reopening the app shows the same tabs" bar,
//      minus the relaunch.
//   3. **The gating decision.** "The hidden destination costs nothing" is a
//      claim, and E1 is what happens when nobody checks it.
//
//      **Measured limitation, stated rather than papered over.** A suite run
//      from a terminal is not a real UI app (activation policy `.accessory`,
//      `NSApp.run()` never called), so the window server never composites its
//      windows and WebKit reports the page as `hidden` *even while the view is
//      shown*. The shown-state half therefore cannot be measured here, and
//      this suite says so instead of asserting something it cannot see. What
//      it locks down is that hiding never *fails* to reach the page, which is
//      the direction a regression would break. `WhiteboardViewSelfTest`
//      records the identical limitation for the identical reason.
//
// `FM_RUN_CODE_PREVIEW_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CodePreviewViewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                ok = false
            }
        }

        // The bridge's failure paths need no page at all, so they run first
        // and cannot be skipped by an editor that fails to start.
        checkBridgeFailurePaths(check)

        guard CodePreviewAssets.isAvailable else {
            check(false, "no Monaco bundle - run native/Scripts/build-monaco-web.sh")
            return false
        }

        // A scratch folder per run: this suite writes real snippet files, and
        // must never reach the captain's real git-synced clone.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-preview-view-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = CodePreviewStore(root: scratch)
        let controller = CodePreviewController(store: store)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        // A window only becomes genuinely `.visible` to the window server for
        // a process that is a UI app - a suite run from a terminal is
        // `.prohibited` by default and its windows are never composited, which
        // for a web view means `requestAnimationFrame` never fires even when
        // shown. `WhiteboardViewSelfTest` and `TerminalDisplayGatingSelfTest`
        // both record the same requirement.
        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)
        window.displayIfNeeded()

        let webView = controller.debugWebView
        check(controller.debugOverlayVisible, "the overlay should cover the editor until it reports ready")

        guard waitFor(timeout: 30, until: { webView.isReady }) else {
            check(false, "Monaco never reported ready - the bundle loaded but did not mount")
            return false
        }
        check(!controller.debugOverlayVisible, "the overlay should be gone once the editor is ready")

        checkFirstLoadOpensSomethingToPasteInto(controller, store, check)
        checkHighlightingActuallyHappens(controller, webView, check)
        checkPersistenceRoundTrip(controller, store, scratch, check)
        checkLanguagePickerRenamesTheFile(controller, store, check)
        checkDetectionOnPasteNamesTheFile(controller, store, check)
        checkAnEmptiedNewTabIsNeverWritten(controller, store, check)
        checkEditorActions(webView, check)
        checkRenamesCannotCollide(check)
        checkLateCloneRetry(check)
        checkTabsAreIndependent(controller, webView, check)
        checkThemeSweep(controller, webView, check)
        checkGating(controller, webView, check)
        checkNoLeakedBridgeCalls(webView, check)

        window.orderOut(nil)
        print(ok ? "CodePreviewViewSelfTest: OK" : "CodePreviewViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Bridge failure paths (no page needed)

    /// A caller must always get exactly one answer, including when the page is
    /// not there to give one - otherwise a spinner stays up forever.
    private static func checkBridgeFailurePaths(_ check: (Bool, String) -> Void) {
        let view = CodePreviewWebView()
        var answers: [String] = []
        view.call("stats") { result in
            if case .failure(let error) = result { answers.append(error.message) }
        }
        check(answers.count == 1, "a call before activate() should fail immediately, exactly once")
        check(answers.first?.contains("not been opened") == true,
              "…and say why, got \(answers.first ?? "nothing")")
        check(view.debugPendingCallCount == 0, "a failed-before-send call must not stay pending")

        // The reply plumbing itself, with no page: a reply for a call id
        // nobody is waiting on must be dropped rather than crashing.
        view.debugHandle(message: ["type": "reply", "callID": 999, "ok": true])
        check(true, "an orphan reply should be ignored")

        // The two unsolicited messages this feature adds on top of the
        // Whiteboard's shape.
        var changed: (String, String)?
        var moved: CodePreviewCursor?
        view.onSnippetChanged = { key, content in changed = (key, content) }
        view.onCursorMoved = { moved = $0 }
        view.debugHandle(message: ["type": "change", "id": "k1", "content": "let x = 1"])
        view.debugHandle(message: ["type": "cursor", "line": 4, "column": 9, "selected": 12, "lines": 40])
        check(changed?.0 == "k1" && changed?.1 == "let x = 1", "a change message should reach the controller")
        check(moved == CodePreviewCursor(line: 4, column: 9, selected: 12, lines: 40),
              "a cursor message should reach the controller intact")
        // A malformed change must be dropped, not turned into an empty write
        // over the captain's snippet.
        changed = nil
        view.debugHandle(message: ["type": "change", "id": "k1"])
        check(changed == nil, "a change with no content must be dropped, not written as empty")
    }

    // MARK: First load

    private static func checkFirstLoadOpensSomethingToPasteInto(
        _ controller: CodePreviewController, _ store: CodePreviewStore, _ check: (Bool, String) -> Void
    ) {
        check(controller.debugTabNames.count == 1,
              "an empty folder should open exactly one tab to paste into, got \(controller.debugTabNames)")
        check(controller.debugCurrentName == "snippet-1.txt", "…named snippet-1.txt")
        check(controller.debugCurrentLanguage == "plaintext", "…as plain text until something is pasted")

        // The whole point of the deferred write: looking at the destination
        // must not commit an empty file to the captain's config repo.
        check(store.names().isEmpty,
              "an empty tab must not be written to disk, found \(store.names())")

        // …which is exactly why a second empty tab cannot be named off the
        // disk alone: neither of them is on it. Two tabs sharing one name
        // would mean the first one typed into takes the other's file.
        controller.debugNewSnippet()
        let untitled = controller.debugTabNames
        check(Set(untitled).count == untitled.count,
              "two empty, unsaved tabs got the same name: \(untitled)")
        check(untitled == ["snippet-1.txt", "snippet-2.txt"],
              "a second empty tab should take the next free number, got \(untitled)")
        controller.debugCloseCurrent()
        check(controller.debugTabNames == ["snippet-1.txt"], "…and closing it should leave the first")

        // The status line is real, populated chrome from the first frame -
        // this is also what keeps `DestinationMountingSelfTest`'s
        // "mounted, visible, but blank" check honest for this page.
        let status = controller.debugStatusLine
        check(status.contains("Ln 1, Col 1"), "the status bar should show a caret position, got \(status)")
        check(status.contains("Plain Text"), "…and the language, got \(status)")
        check(status.contains("UTF-8"), "…and the encoding, got \(status)")
    }

    // MARK: Highlighting - the feature itself

    /// Reads Monaco's own tokenizer output back, which is the only honest
    /// proof that a pasted snippet is genuinely being highlighted rather than
    /// merely being handed a language id.
    private static func checkHighlightingActuallyHappens(
        _ controller: CodePreviewController, _ webView: CodePreviewWebView, _ check: (Bool, String) -> Void
    ) {
        // Line 1 is a keyword + a type, line 3 is a string - three of the four
        // token roles the palette colours, on one real Swift snippet.
        let swift = """
        struct Host {
            let label: String
            var greeting = "hello"
        }
        """
        controller.debugSimulateEdit(name: "snippet-1.txt", content: swift)
        // The edit renames the file (detection), so the tab is now .swift.
        _ = waitFor(timeout: 5, until: { controller.debugCurrentLanguage == "swift" })
        check(controller.debugCurrentLanguage == "swift",
              "pasted Swift should be detected, got \(controller.debugCurrentLanguage ?? "nil")")

        // Push the real content into the real editor, then ask Monaco what it
        // made of it.
        var loaded = false
        webView.call("openSnippet", payload: [
            "id": "probe", "language": "swift", "content": swift, "select": true,
        ]) { _ in loaded = true }
        _ = waitFor(timeout: 10, until: { loaded })

        func tokens(onLine line: Int) -> [String] {
            var out: [String] = []
            var done = false
            webView.call("tokensAt", payload: ["line": line]) { result in
                if case .success(let body) = result,
                   let raw = body["tokens"] as? [[String: Any]] {
                    out = raw.compactMap { $0["type"] as? String }
                }
                done = true
            }
            _ = waitFor(timeout: 10, until: { done })
            return out
        }

        let first = tokens(onLine: 1)
        check(!first.isEmpty, "Monaco produced no tokens at all for a Swift line - highlighting is not happening")
        check(first.contains { $0.hasPrefix("keyword") },
              "`struct` should be tokenized as a keyword, got \(first)")
        check(first.contains { $0.hasPrefix("type") || $0.hasPrefix("identifier") },
              "`Host` should be tokenized as a type or identifier, got \(first)")

        let third = tokens(onLine: 3)
        check(third.contains { $0.hasPrefix("string") },
              "`\"hello\"` should be tokenized as a string, got \(third)")

        // And the hand-written JSON tokenizer, which is the one language in
        // the set this app defines itself rather than importing - so it is the
        // one that can break without any upstream change.
        var jsonLoaded = false
        webView.call("openSnippet", payload: [
            "id": "probe", "language": "json",
            "content": "{\n  \"name\": \"grand-line\",\n  \"count\": 42,\n  \"on\": true\n}",
            "select": true,
        ]) { _ in jsonLoaded = true }
        _ = waitFor(timeout: 10, until: { jsonLoaded })

        let key = tokens(onLine: 2)
        check(key.contains { $0.hasPrefix("type") },
              "a JSON key should be tokenized distinctly from a plain string, got \(key)")
        check(key.contains { $0.hasPrefix("string") },
              "…and its value as a string, got \(key)")
        let number = tokens(onLine: 3)
        check(number.contains { $0.hasPrefix("number") }, "a JSON number, got \(number)")
        let literal = tokens(onLine: 4)
        check(literal.contains { $0.hasPrefix("keyword") }, "a JSON `true`, got \(literal)")

        // Clean up the probe model so it does not count as an open tab later.
        var closed = false
        webView.call("closeSnippet", payload: ["id": "probe"]) { _ in closed = true }
        _ = waitFor(timeout: 5, until: { closed })
    }

    // MARK: Persistence

    /// The captain's own bar: what is open now is what is open next time.
    ///
    /// A second `CodePreviewController` over the same folder is the honest
    /// stand-in for a relaunch - it re-reads the store from scratch with no
    /// shared in-memory state.
    private static func checkPersistenceRoundTrip(
        _ controller: CodePreviewController, _ store: CodePreviewStore,
        _ root: URL, _ check: (Bool, String) -> Void
    ) {
        // The Swift paste from the highlighting check above should already be
        // on disk under its detected name.
        let onDisk = store.names()
        check(onDisk == ["snippet-1.swift"],
              "the pasted snippet should be on disk under its detected name, got \(onDisk)")

        controller.debugNewSnippet()
        controller.debugSimulateEdit(name: "snippet-2.txt", content: "apiVersion: v1\nkind: Service\nmetadata:\n  name: api\n")
        _ = waitFor(timeout: 5, until: { store.names().count == 2 })

        let both = store.names()
        check(both == ["snippet-1.swift", "snippet-2.yaml"],
              "both snippets should be on disk with detected extensions, got \(both)")

        // The content is the file, byte for byte - the reason this store does
        // not wrap a snippet in YAML.
        let yaml = try? String(contentsOf: root.appendingPathComponent("snippet-2.yaml"), encoding: .utf8)
        check(yaml?.hasPrefix("apiVersion: v1") == true,
              "the file should hold exactly what was typed, got \(yaml ?? "nothing")")

        // The relaunch.
        let second = CodePreviewController(store: CodePreviewStore(root: root))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = second.view
        window.orderFront(nil)
        guard waitFor(timeout: 30, until: { second.debugWebView.isReady }) else {
            check(false, "the second editor never reported ready")
            window.orderOut(nil)
            return
        }
        _ = waitFor(timeout: 5, until: { second.debugTabNames.count == 2 })
        check(second.debugTabNames == ["snippet-1.swift", "snippet-2.yaml"],
              "a fresh controller should reopen both snippets, got \(second.debugTabNames)")
        check(second.debugCurrentLanguage == "swift",
              "…with the first one's language recovered from its filename")
        window.orderOut(nil)
    }

    // MARK: Language

    private static func checkLanguagePickerRenamesTheFile(
        _ controller: CodePreviewController, _ store: CodePreviewStore, _ check: (Bool, String) -> Void
    ) {
        controller.debugSelect(name: "snippet-2.yaml")
        controller.debugPickLanguage("python")
        _ = waitFor(timeout: 5, until: { controller.debugCurrentName == "snippet-2.py" })

        check(controller.debugCurrentName == "snippet-2.py",
              "picking a language should rename the file - that is where the language lives, got \(controller.debugCurrentName ?? "nil")")
        check(controller.debugCurrentLanguage == "python", "…and the language should follow")
        check(store.names().contains("snippet-2.py"), "the rename should reach disk")
        check(!store.names().contains("snippet-2.yaml"), "…and the old filename should be gone")

        // A deliberate choice must survive further pasting - detection never
        // overrides the captain.
        controller.debugSimulateEdit(name: "snippet-2.py", content: "SELECT id FROM hosts WHERE region = 'x' ORDER BY id;")
        _ = waitFor(timeout: 3, until: { false })  // let any debounce settle
        check(controller.debugCurrentLanguage == "python",
              "a hand-picked language must not be overridden by later detection, got \(controller.debugCurrentLanguage ?? "nil")")

        // The case that actually needs the `languageOverridden` flag, and the
        // one an earlier version of this suite missed: **deliberately picking
        // Plain Text**. Every other choice moves the language off plaintext,
        // which stops detection on its own - so without the flag, a captain
        // who says "no, this really is plain text" gets overruled by the next
        // keystroke. Confirmed by injection: removing the flag from the guard
        // left every other case in this suite passing.
        controller.debugPickLanguage("plaintext")
        _ = waitFor(timeout: 3, until: { controller.debugCurrentName?.hasSuffix(".txt") == true })
        check(controller.debugCurrentLanguage == "plaintext",
              "picking Plain Text should take, got \(controller.debugCurrentLanguage ?? "nil")")
        controller.debugSimulateEdit(name: controller.debugCurrentName ?? "",
                                     content: "import Foundation\n\nstruct Host {\n    let label: String\n}\n")
        _ = waitFor(timeout: 3, until: { false })
        check(controller.debugCurrentLanguage == "plaintext",
              "a deliberate Plain Text choice must survive pasting obvious Swift, got \(controller.debugCurrentLanguage ?? "nil")")

        // And the same choice made on a snippet that is *already* plain text.
        // That reads like a no-op and is not one: it is the only way a captain
        // can say "yes, this really is plain text" about a fresh tab, and if
        // the picker treats it as nothing then the very next paste overrules
        // them. Marking the override has to happen before the
        // already-on-that-language early return.
        controller.debugNewSnippet()
        let fresh = controller.debugCurrentName ?? ""
        check(fresh.hasSuffix(".txt"), "a new tab is plain text to begin with, got \(fresh)")
        controller.debugPickLanguage("plaintext")
        controller.debugSimulateEdit(name: fresh, content: "#!/usr/bin/env python3\nprint('hi')\n")
        _ = waitFor(timeout: 3, until: { false })
        check(controller.debugCurrentLanguage == "plaintext",
              "picking Plain Text on an already-plain-text tab must still stick, got \(controller.debugCurrentLanguage ?? "nil")")
        check(controller.debugCurrentName == fresh,
              "…and the file must not be renamed out from under it, got \(controller.debugCurrentName ?? "nil")")
        controller.debugCloseCurrent()
    }

    /// A tab typed into and then emptied, before it was ever written.
    ///
    /// This is the *only* path that reaches the deferred-write guard: an
    /// untouched tab never reports a change at all, so "look at the page and
    /// check nothing was written" passes with or without the guard - confirmed
    /// by injection. What the guard is really for is the captain opening a
    /// tab, typing, and selecting-all-deleting: that must still leave nothing
    /// in their config repo.
    private static func checkAnEmptiedNewTabIsNeverWritten(
        _ controller: CodePreviewController, _ store: CodePreviewStore, _ check: (Bool, String) -> Void
    ) {
        let before = Set(store.names())
        controller.debugNewSnippet()
        guard let fresh = controller.debugCurrentName else {
            check(false, "a new tab should be selected")
            return
        }
        controller.debugSimulateEdit(name: fresh, content: "   \n\n  ")
        _ = waitFor(timeout: 2, until: { false })
        check(Set(store.names()) == before,
              "a tab holding only whitespace must not be written, found \(Set(store.names()).subtracting(before))")

        // But real content in that same tab must be written - the guard has to
        // defer the write, not skip it.
        controller.debugSimulateEdit(name: fresh, content: "echo hello\n")
        _ = waitFor(timeout: 3, until: { Set(store.names()) != before })
        check(Set(store.names()) != before, "real content in the same tab should still be written")
        controller.debugCloseCurrent()
        _ = waitFor(timeout: 3, until: { Set(store.names()) == before })
    }

    private static func checkDetectionOnPasteNamesTheFile(
        _ controller: CodePreviewController, _ store: CodePreviewStore, _ check: (Bool, String) -> Void
    ) {
        controller.debugNewSnippet()
        let fresh = controller.debugCurrentName
        check(fresh?.hasSuffix(".txt") == true, "a new tab starts as plain text, got \(fresh ?? "nil")")

        controller.debugSimulateEdit(name: fresh ?? "", content: "#!/bin/bash\nset -euo pipefail\necho hi\n")
        _ = waitFor(timeout: 5, until: { controller.debugCurrentLanguage == "shell" })
        check(controller.debugCurrentLanguage == "shell",
              "a shebang should be detected on paste, got \(controller.debugCurrentLanguage ?? "nil")")
        check(controller.debugCurrentName?.hasSuffix(".sh") == true,
              "…and the tab should be renamed to match, got \(controller.debugCurrentName ?? "nil")")
        check(store.names().contains { $0.hasSuffix(".sh") }, "…on disk too")
    }

    // MARK: Editor actions

    /// The page's own bridge calls have to actually reach something.
    ///
    /// `find` is the one that would fail most quietly: ⌘F arrives through the
    /// Edit menu and the responder chain, the bridge call succeeds, and if
    /// Monaco has renamed `actions.find` nothing at all happens - no error, no
    /// widget. `native/Vendor/Monaco/README.md`'s upgrade checklist names this
    /// action id for exactly that reason, so it is asserted rather than
    /// trusted.
    private static func checkEditorActions(_ webView: CodePreviewWebView, _ check: (Bool, String) -> Void) {
        for call in ["find", "focusEditor"] {
            var failure: String?
            var done = false
            webView.call(call) { result in
                if case .failure(let error) = result { failure = error.message }
                done = true
            }
            _ = waitFor(timeout: 10, until: { done })
            check(done, "the \(call) bridge call never answered")
            check(failure == nil, "\(call) failed: \(failure ?? "") - has Monaco renamed the action?")
        }

        // Soft wrap is an editor-level option, so it has to survive a tab
        // switch rather than being re-applied per model.
        for on in [true, false] {
            var failure: String?
            var done = false
            webView.call("setWordWrap", payload: ["on": on]) { result in
                if case .failure(let error) = result { failure = error.message }
                done = true
            }
            _ = waitFor(timeout: 10, until: { done })
            check(failure == nil, "setWordWrap(\(on)) failed: \(failure ?? "")")
        }
    }

    // MARK: Names

    /// Two tabs must never share a name, including the ones with no file yet.
    ///
    /// `CodePreviewStore` disambiguates against **disk**, which covers every
    /// written snippet - and misses exactly the tabs a captain renames before
    /// typing into. Two such tabs sharing a name is real data loss rather than
    /// a cosmetic clash: neither has a file, so nothing complains, and then
    /// whichever receives content second silently overwrites the first.
    private static func checkRenamesCannotCollide(_ check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-preview-names-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CodePreviewStore(root: root)
        let controller = CodePreviewController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        guard waitFor(timeout: 30, until: { controller.debugWebView.isReady }) else {
            check(false, "the names editor never reported ready")
            return
        }

        controller.debugNewSnippet()
        let names = controller.debugTabNames
        check(names.count == 2, "expected two empty tabs, got \(names)")

        // Rename both, unsaved, to the same thing.
        controller.debugRename(from: names[0], to: "shared.py")
        controller.debugRename(from: names[1], to: "shared.py")
        let renamed = controller.debugTabNames
        check(Set(renamed).count == 2,
              "two unsaved tabs were allowed to share a name: \(renamed)")
        check(renamed.contains("shared.py") && renamed.contains("shared-2.py"),
              "the second rename should disambiguate, got \(renamed)")

        // …and the proof that it mattered: typing into both must leave two
        // files, each with its own content.
        controller.debugSimulateEdit(name: "shared.py", content: "first\n")
        controller.debugSimulateEdit(name: "shared-2.py", content: "second\n")
        _ = waitFor(timeout: 5, until: { store.names().count == 2 })
        check(store.names() == ["shared-2.py", "shared.py"],
              "both tabs should have their own file, got \(store.names())")
        let contents = Set(store.list().map(\.content))
        check(contents == ["first\n", "second\n"],
              "each file should hold its own tab's content, got \(contents)")
    }

    // MARK: The late clone

    /// A fresh machine's git clone lands *after* the page is ready, so the
    /// first restore genuinely reads an empty folder - and without a retry the
    /// captain's snippets sit on disk with a blank panel in front of them
    /// until the app is relaunched.
    ///
    /// The retry is deliberately the narrowest one that fixes that, so both
    /// halves are checked: it fires when nothing was found and files appeared,
    /// and it does **nothing** once the captain has typed - re-reading over
    /// their work would be a far worse failure than the blank panel.
    private static func checkLateCloneRetry(_ check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-preview-late-clone-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CodePreviewStore(root: root)
        let controller = CodePreviewController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        guard waitFor(timeout: 30, until: { controller.debugWebView.isReady }) else {
            check(false, "the late-clone editor never reported ready")
            return
        }
        check(controller.debugTabNames == ["snippet-1.txt"],
              "an empty folder gives one placeholder tab, got \(controller.debugTabNames)")

        // The clone lands.
        store.create(name: "values.yaml", content: "replicas: 2\n")
        store.create(name: "main.go", content: "package main\n")
        controller.debugRetryRestoreAfterLateClone()
        _ = waitFor(timeout: 5, until: { controller.debugTabNames.count == 2 })
        check(controller.debugTabNames == ["main.go", "values.yaml"],
              "a late clone should replace the placeholder with the real snippets, got \(controller.debugTabNames)")

        // And now that there is real content, the retry must be inert - this
        // is the half that protects the captain's own work.
        store.create(name: "late.py", content: "print(1)\n")
        controller.debugRetryRestoreAfterLateClone()
        check(controller.debugTabNames == ["main.go", "values.yaml"],
              "the retry must not re-read once real snippets are open, got \(controller.debugTabNames)")

        // The case that distinguishes the "the first read found nothing"
        // guard from the "nothing is open yet" one, and the decision it
        // encodes: a captain who **closed every tab** is back to a lone empty
        // placeholder, so the open-tabs guard alone would let a later git pull
        // re-open files they deliberately closed. The retry exists to recover
        // from a read that was too early, not to keep the panel in sync with
        // the folder forever - so once a real read has happened, it is done.
        for name in controller.debugTabNames {
            controller.debugSelect(name: name)
            controller.debugCloseCurrent()
        }
        _ = waitFor(timeout: 5, until: { controller.debugTabNames.count == 1 })
        check(controller.debugTabNames.first?.hasPrefix("snippet-") == true,
              "closing every tab should leave one empty placeholder, got \(controller.debugTabNames)")
        // Stand in for a pull landing snippets from another machine.
        store.create(name: "from-elsewhere.rs", content: "fn main() {}\n")
        controller.debugRetryRestoreAfterLateClone()
        check(controller.debugTabNames.first?.hasPrefix("snippet-") == true,
              "a later arrival must not re-open tabs the captain closed, got \(controller.debugTabNames)")
    }

    // MARK: Tabs

    /// Two tabs are two independent editor models - switching between them
    /// must show each one's own text, not the last one's.
    private static func checkTabsAreIndependent(
        _ controller: CodePreviewController, _ webView: CodePreviewWebView, _ check: (Bool, String) -> Void
    ) {
        let names = controller.debugTabNames
        check(names.count >= 3, "the suite should have three tabs open by now, got \(names)")

        func stats() -> [String: Any] {
            var out: [String: Any] = [:]
            var done = false
            webView.call("stats") { result in
                if case .success(let body) = result { out = body }
                done = true
            }
            _ = waitFor(timeout: 10, until: { done })
            return out
        }

        let open = stats()["open"] as? Int
        check(open == names.count,
              "the page should hold one model per tab: \(names.count) tabs, \(open ?? -1) models")

        // Closing a tab has to dispose its model - a model kept after its tab
        // is gone holds the whole text plus its undo stack.
        let before = names.count
        controller.debugSelect(name: names[0])
        controller.debugCloseCurrent()
        _ = waitFor(timeout: 5, until: { (stats()["open"] as? Int) == before - 1 })
        check((stats()["open"] as? Int) == before - 1,
              "closing a tab should dispose its editor model")
        check(controller.debugTabNames.count == before - 1, "…and drop the chip")
        check(!controller.debugTabNames.contains(names[0]), "…for the right tab")
    }

    // MARK: Theme

    /// The palette reaches the page in both registers.
    ///
    /// Deliberately not a pixel comparison: what a rendered token colour looks
    /// like is `CodePreviewSelfTest.checkThemePalette`'s job (it measures every
    /// token's contrast against the editor background in all fourteen themes,
    /// which a screenshot cannot do). What this adds is that the push itself
    /// works against a real page, in a light theme and a dark one.
    private static func checkThemeSweep(
        _ controller: CodePreviewController, _ webView: CodePreviewWebView, _ check: (Bool, String) -> Void
    ) {
        // `ThemeManager.setTheme` writes through to the real `UserDefaults`
        // domain this process shares with the captain's app, so the current
        // selection is saved and restored - see AGENTS.md's note on the suites
        // that leaked a theme and made unrelated ones fail.
        let original = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(original) }

        for id in ["helm-dark", "daylight", "helm-light"] {
            guard let theme = HelmTheme.allThemes.first(where: { $0.id == id }) else {
                check(false, "no theme \(id)")
                continue
            }
            ThemeManager.shared.setTheme(theme)
            var reported: String?
            var done = false
            webView.call("stats") { result in
                if case .success = result { reported = "ok" }
                done = true
            }
            _ = waitFor(timeout: 10, until: { done })
            check(reported == "ok", "\(id): the page stopped answering after a theme change")
            // The controller's own chrome has to follow too - the editor card
            // is what a captain sees around the code.
            let fill = controller.debugEditorCard.layer?.backgroundColor
            check(fill != nil, "\(id): the editor card has no fill")
        }
    }

    // MARK: Gating

    private static func checkGating(
        _ controller: CodePreviewController, _ webView: CodePreviewWebView, _ check: (Bool, String) -> Void
    ) {
        func probe() -> [String: Any] {
            var out: [String: Any] = [:]
            var done = false
            webView.call("readGatingProbe") { result in
                if case .success(let body) = result { out = body }
                done = true
            }
            _ = waitFor(timeout: 10, until: { done })
            return out
        }

        var started = false
        webView.call("startGatingProbe") { _ in started = true }
        _ = waitFor(timeout: 10, until: { started })

        // Hiding the destination is what the shell does on navigate-away, and
        // it has to reach the page.
        controller.view.isHidden = true
        _ = waitFor(timeout: 5, until: { webView.isSuspended })
        check(webView.isSuspended, "hiding the destination should suspend the page")
        check((probe()["suspended"] as? Bool) == true, "…and the page should know it is suspended")

        let atSuspend = probe()["frames"] as? Int ?? -1
        _ = waitFor(timeout: 1.0, until: { false })
        let later = probe()["frames"] as? Int ?? -2
        check(later == atSuspend,
              "a suspended page kept animating: \(atSuspend) -> \(later) frames")

        controller.view.isHidden = false
        _ = waitFor(timeout: 5, until: { !webView.isSuspended })
        check(!webView.isSuspended, "showing the destination again should resume the page")
        // The shown half genuinely cannot be measured from a terminal-launched
        // process - see this file's header. Reported rather than asserted.
        print("NOTE: the *shown* half of gating is not measurable here " +
              "(no window-server compositing for an .accessory process); " +
              "visibility reads \(probe()["visibility"] as? String ?? "?")")
    }

    private static func checkNoLeakedBridgeCalls(_ webView: CodePreviewWebView, _ check: (Bool, String) -> Void) {
        _ = waitFor(timeout: 3, until: { webView.debugPendingCallCount == 0 })
        check(webView.debugPendingCallCount == 0,
              "\(webView.debugPendingCallCount) bridge call(s) never got a reply - a caller would wait forever")
    }

    // MARK: Harness

    private static func waitFor(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

#endif
