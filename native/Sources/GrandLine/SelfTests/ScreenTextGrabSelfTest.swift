// Grand Line - native macOS app.
//
// F-06 of full review 4: grab text from the screen.
// Run with `FM_RUN_SCREEN_TEXT_GRAB_TESTS=1 .build/debug/GrandLine`.
//
// Headless. The crosshair (`screencapture -i`) is never run: the capture
// step is replaced by one that hands back an image drawn here. The Vision
// read is the real one, on that drawn image, so the recogniser's settings
// (no language correction, top-to-bottom order) are tested against the
// framework rather than against a stub.
//
// What it pins:
//
//  - **A command is read exactly**, flags and all, and lines come back top
//    to bottom.
//  - **The flow**: the text replaces the clipboard (a private pasteboard
//    here, never the general one), nothing found leaves the clipboard alone,
//    a cancelled crosshair shows nothing, and a locked app refuses before the
//    crosshair (GL-09).
//  - **Keeping it** files through the capture filer: a task's title is the
//    first line.
//  - **⌘7 on the capture panel's root view starts a grab**, through the
//    real `performKeyEquivalent`, and ⌘1 still files.

#if FM_SELFTESTS

import AppKit

enum ScreenTextGrabSelfTest {

    static func run() -> Bool {
        var ok = true
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        let cases: [(String, () -> String?)] = [
            ("Vision reads a command exactly, top to bottom", test_visionReadsCommand),
            ("line order", test_order),
            ("fused dashes in a command are put back", test_dashes),
            ("copied replaces the clipboard", test_copied),
            ("nothing found leaves the clipboard", test_nothingFound),
            ("cancelled shows nothing", test_cancelled),
            ("locked refuses before the crosshair", test_locked),
            ("keep as a task or a note", test_keep),
            ("result card states", test_card),
            ("cmd-7 on the capture panel starts a grab", test_panelChord),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[grab-text] \(name): \(failure)", &ok) } else { print("[grab-text] PASS \(name)") }
        }
        print(ok ? "[grab-text] ALL PASS" : "[grab-text] FAILED")
        return ok
    }

    static let commands = [
        "kubectl -n prod rollout restart deploy/checkout-worker",
        "kubectl -n prod rollout status deploy/checkout-worker --timeout=120s",
    ]

    /// Black monospaced text on white, at 2x, the way a slide or a paused
    /// video looks to the crosshair.
    static func drawnImage(_ lines: [String]) -> NSImage {
        let size = NSSize(width: 1200, height: 40 + 44 * lines.count)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 20, y: size.height - 50 - CGFloat(i) * 44), withAttributes: attrs)
        }
        image.unlockFocus()
        return image
    }

    final class Recorder {
        var filed: [(CaptureDestination, CaptureDraft)] = []
        var states: [ScreenTextGrab.State] = []
        var captures = 0
    }

    static func makeGrab(_ recorder: Recorder, pasteboard: NSPasteboard,
                         outcome: ScreenRegionCapture.Outcome, lines: [String]) -> ScreenTextGrab {
        let grab = ScreenTextGrab(filer: CaptureFiler { destination, draft in
            recorder.filed.append((destination, draft))
            return .filed(destination)
        })
        grab.pasteboard = pasteboard
        grab.present = { recorder.states.append($0) }
        grab.capture = { done in
            recorder.captures += 1
            done(ScreenRegionCapture.Result(outcome: outcome, image: outcome == .captured ? drawnImage(lines) : nil))
        }
        grab.recognize = { _ in (lines, nil) }
        return grab
    }

    static func pump(until: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !until(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func withPasteboard<T>(_ body: (NSPasteboard) -> T) -> T {
        let board = NSPasteboard(name: NSPasteboard.Name("fm.selftest.grabtext.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        return body(board)
    }

    // MARK: Cases

    static func test_visionReadsCommand() -> String? {
        let (lines, error) = ScreenTextRecognizer.recognize(drawnImage(commands))
        if let error { return error }
        guard lines == commands else { return "read \(lines)" }
        return nil
    }

    static func test_order() -> String? {
        let items: [(text: String, box: CGRect)] = [
            ("second", CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.1)),
            ("right", CGRect(x: 0.6, y: 0.71, width: 0.2, height: 0.1)),
            ("first", CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.1)),
        ]
        let ordered = ScreenTextRecognizer.order(items)
        return ordered == ["first", "right", "second"] ? nil : "ordered \(ordered)"
    }

    static func test_dashes() -> String? {
        let cases: [(String, String)] = [
            ("kubectl rollout status deploy/x \u{2014}-timeout=120s", "kubectl rollout status deploy/x --timeout=120s"),
            ("kubectl get pods \u{2014}watch -n prod", "kubectl get pods --watch -n prod"),
            ("Keep-alive was off \u{2014} nobody remembered why", "Keep-alive was off \u{2014} nobody remembered why"),
        ]
        for (input, expected) in cases where ScreenTextRecognizer.normaliseDashes(input) != expected {
            return "\(input) -> \(ScreenTextRecognizer.normaliseDashes(input))"
        }
        return nil
    }

    static func test_copied() -> String? {
        AppLockGate.shared.setLocked(false)
        return withPasteboard { board in
            board.clearContents()
            board.setString("before", forType: .string)
            let recorder = Recorder()
            let grab = makeGrab(recorder, pasteboard: board, outcome: .captured, lines: commands)
            grab.start()
            pump { !recorder.states.isEmpty }
            guard recorder.states == [.copied(commands)] else { return "states \(recorder.states)" }
            guard board.string(forType: .string) == commands.joined(separator: "\n") else {
                return "the clipboard holds \(board.string(forType: .string) ?? "nil")"
            }
            return grab.isRunning ? "still running after the result" : nil
        }
    }

    static func test_nothingFound() -> String? {
        AppLockGate.shared.setLocked(false)
        return withPasteboard { board in
            board.clearContents()
            board.setString("before", forType: .string)
            let recorder = Recorder()
            makeGrab(recorder, pasteboard: board, outcome: .captured, lines: []).start()
            pump { !recorder.states.isEmpty }
            guard recorder.states == [.nothingFound] else { return "states \(recorder.states)" }
            return board.string(forType: .string) == "before" ? nil : "the clipboard was changed with nothing found"
        }
    }

    static func test_cancelled() -> String? {
        AppLockGate.shared.setLocked(false)
        return withPasteboard { board in
            let recorder = Recorder()
            let grab = makeGrab(recorder, pasteboard: board, outcome: .cancelled, lines: commands)
            grab.start()
            pump { recorder.captures > 0 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            return recorder.states.isEmpty && !grab.isRunning ? nil : "a cancelled crosshair showed \(recorder.states)"
        }
    }

    static func test_locked() -> String? {
        AppLockGate.shared.setLocked(true)
        defer { AppLockGate.shared.setLocked(false) }
        return withPasteboard { board in
            let recorder = Recorder()
            makeGrab(recorder, pasteboard: board, outcome: .captured, lines: commands).start()
            guard recorder.captures == 0 else { return "the crosshair ran while locked" }
            return recorder.states == [.locked] ? nil : "states \(recorder.states)"
        }
    }

    static func test_keep() -> String? {
        withPasteboard { board in
            let recorder = Recorder()
            let grab = makeGrab(recorder, pasteboard: board, outcome: .captured, lines: commands)
            grab.keep(commands, as: .task)
            grab.keep(commands, as: .note)
            guard recorder.filed.count == 2 else { return "filed \(recorder.filed.count)" }
            let (taskDestination, task) = recorder.filed[0]
            guard taskDestination == .task, task.title == commands[0], task.body == commands[1] else {
                return "the task draft is \(task)"
            }
            let (noteDestination, note) = recorder.filed[1]
            return noteDestination == .note && note.text == commands.joined(separator: "\n") ? nil : "the note draft is \(note)"
        }
    }

    static func test_card() -> String? {
        let view = ScreenTextResultView()
        view.render(.copied(commands), theme: ThemeManager.shared.theme)
        guard view.debugTitle == "Copied 2 lines", view.debugText == commands.joined(separator: "\n") else {
            return "copied card: \(view.debugTitle) / \(view.debugText)"
        }
        guard view.debugButtons.map(\.title) == ["New note", "New task", "Save as snippet"] else {
            return "copied buttons \(view.debugButtons.map(\.title))"
        }
        var kept: CaptureDestination?
        view.onKeep = { _, destination in kept = destination }
        view.debugButtons[1].performClick(nil)
        guard kept == .task else { return "New task kept \(String(describing: kept))" }
        view.render(.locked, theme: ThemeManager.shared.theme)
        guard view.debugTitle == "Grand Line is locked", view.debugButtons.map(\.title) == ["Unlock"] else {
            return "locked card: \(view.debugTitle) \(view.debugButtons.map(\.title))"
        }
        view.render(.nothingFound, theme: ThemeManager.shared.theme)
        return view.debugTitle == "No text found in that area" ? nil : "nothing card: \(view.debugTitle)"
    }

    static func test_panelChord() -> String? {
        let root = CaptureRootView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var grabs = 0
        var filed: [CaptureDestination] = []
        root.onGrabTextChord = { grabs += 1; return true }
        root.onDestinationChord = { filed.append($0); return true }
        func key(_ c: String) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                             context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)
        }
        guard let seven = key("7"), let one = key("1") else { return "could not build key events" }
        _ = root.performKeyEquivalent(with: seven)
        _ = root.performKeyEquivalent(with: one)
        guard grabs == 1 else { return "cmd-7 started \(grabs) grabs" }
        guard filed == [.task] else { return "cmd-1 filed \(filed)" }
        let tile = CaptureDestinationTile.grabText()
        return tile.destination == nil ? nil : "the Grab text tile claims a filing destination"
    }
}

#endif
