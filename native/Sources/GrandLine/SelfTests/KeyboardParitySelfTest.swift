// Grand Line - native macOS app.
//
// P5 of the Grand Line vs Automic Vault polish report: keyboard parity for
// the lists, panels and sheets this app builds by hand.
//
// Every case sends a real key event through the window's own dispatch -
// `NSWindow.sendEvent` for a key-down, `performKeyEquivalent` for a key
// equivalent, which is the path `NSApplication` takes - and asserts where
// the keyboard went or what ran. Nothing calls a handler directly.
//
// Run with:
//   swift build && FM_RUN_KEYBOARD_PARITY_TESTS=1 .build/debug/GrandLine; echo $?
//
// Window-backed: real windows, real first responders. Listed in
// `run-all-tests.sh`'s `NEEDS_SESSION`.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum KeyboardParitySelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var ok = true
        // Each case keeps its own result, so one failure does not hide the
        // next case's OK line.
        for each in [checkArrowsMoveThroughAFlatList, checkArrowsMoveThroughHomesRows,
                     checkEscapeClosesABarPanel, checkReturnAndEscapeReachASheetsButtons,
                     checkEverySheetHasTheFooterKeys] {
            var caseOK = true
            each(&caseOK)
            ok = ok && caseOK
        }
        print(ok ? "KeyboardParitySelfTest: all checks passed" : "KeyboardParitySelfTest: FAILED")
        return ok
    }

    // MARK: Key events

    private static func key(_ code: UInt16, _ characters: String, in window: NSWindow,
                            modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }
    private static func down(_ window: NSWindow) -> NSEvent {
        // The arrows carry the function and numeric-pad flags on real
        // hardware; the handler must not read those as modifiers (gotcha (21)).
        key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), in: window, modifiers: [.function, .numericPad])
    }
    private static func up(_ window: NSWindow) -> NSEvent {
        key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), in: window, modifiers: [.function, .numericPad])
    }

    // MARK: HelmFlatList

    private static func checkArrowsMoveThroughAFlatList(_ ok: inout Bool) {
        print("\n-- P5: Up and Down move through a HelmFlatList's rows --")
        let window = OffScreenProbe.window(width: 400, height: 400, styleMask: [.titled])
        defer { window.orderOut(nil) }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = root
        var pressed: [Int] = []
        func focusableRow(_ n: Int) -> HoverHighlightView {
            let row = HoverHighlightView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
            row.onAccessibilityPress = { pressed.append(n) }
            return row
        }
        // Row 2 is not focusable itself but carries a focusable control, the
        // way an attention row carries its own button.
        let nestedTarget = focusableRow(2)
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(nestedTarget)
        NSLayoutConstraint.activate([
            nestedTarget.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            nestedTarget.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            nestedTarget.topAnchor.constraint(equalTo: wrapper.topAnchor),
            nestedTarget.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        let rows: [NSView] = [focusableRow(0), focusableRow(1), wrapper]
        let list = HelmFlatList()
        list.setRows(rows)
        root.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        window.orderFront(nil)
        root.layoutSubtreeIfNeeded()

        check(window.makeFirstResponder(rows[0]), "the first row does not take the keyboard", &ok)
        window.sendEvent(down(window))
        check(window.firstResponder === rows[1], "Down did not move to the second row", &ok)
        window.sendEvent(down(window))
        check(window.firstResponder === nestedTarget, "Down did not reach the third row's own focusable control", &ok)
        window.sendEvent(down(window))
        check(window.firstResponder === nestedTarget, "Down past the last row moved the keyboard somewhere", &ok)
        window.sendEvent(up(window))
        check(window.firstResponder === rows[1], "Up did not move back to the second row", &ok)
        window.sendEvent(key(36, "\r", in: window))
        window.sendEvent(key(49, " ", in: window))
        check(pressed == [1, 1], "Return and Space on the focused row pressed \(pressed), expected [1, 1]", &ok)
        // A modified arrow is someone else's shortcut.
        window.sendEvent(key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), in: window,
                             modifiers: [.command, .function, .numericPad]))
        check(window.firstResponder === rows[1], "Command-Down moved through the list", &ok)
        if ok { print("  OK   Down, Down (into a nested control), clamp at the end, Up, Return and Space") }
    }

    // MARK: Home

    private static func checkArrowsMoveThroughHomesRows(_ ok: inout Bool) {
        print("\n-- P5: Up and Down move through Home's attention and Merge queue rows --")
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        shell.show(.homeCanvas)
        let canvas = shell.debugHomeCanvas
        // The tour's own realistic Tasks data, which is what fills the
        // attention list.
        ReviewTourLab.seedDemoTasks(shell.shiftStore)
        ReviewTourLab.seedDemoHome(canvas)
        canvas.debugRenderNow()
        shell.view.layoutSubtreeIfNeeded()

        let attention = canvas.debugAttentionRows.compactMap(HelmListNavigation.focusTarget(in:))
        check(attention.count >= 2, "Home's attention list has \(attention.count) focusable rows, expected at least 2", &ok)
        if attention.count >= 2 {
            check(window.makeFirstResponder(attention[0]), "the first attention row does not take the keyboard", &ok)
            window.sendEvent(down(window))
            check(window.firstResponder === attention[1], "Down did not move to the second attention row", &ok)
            window.sendEvent(up(window))
            check(window.firstResponder === attention[0], "Up did not move back to the first attention row", &ok)
        }

        let merge = canvas.moduleCardsForTests.map(\.debugPeekRows).max { $0.count < $1.count } ?? []
        check(merge.count >= 2, "no module card has two focusable peek rows (found \(merge.count))", &ok)
        if merge.count >= 2 {
            check(window.makeFirstResponder(merge[0]), "the first peek row does not take the keyboard", &ok)
            window.sendEvent(down(window))
            check(window.firstResponder === merge[1], "Down did not move to the second peek row", &ok)
        }
        if ok { print("  OK   \(attention.count) attention rows and \(merge.count) peek rows, both directions") }
    }

    // MARK: HelmBarPanel

    private static func checkEscapeClosesABarPanel(_ ok: inout Bool) {
        print("\n-- P5: Escape closes a bar panel --")
        let host = OffScreenProbe.window(width: 400, height: 300, styleMask: [.titled])
        defer { host.orderOut(nil) }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.contentView = root
        let anchor = NSView(frame: NSRect(x: 20, y: 250, width: 30, height: 30))
        root.addSubview(anchor)
        host.orderFront(nil)

        let content = NSViewController()
        let field = HelmTextField()
        field.frame = NSRect(x: 10, y: 10, width: 160, height: 24)
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        body.addSubview(field)
        content.view = body
        let panel = HelmBarPanel(content: content)

        for focusField in [false, true] {
            panel.show(under: anchor)
            check(panel.isShown, "the panel did not open", &ok)
            guard let window = content.view.window else { return fail("the panel has no window", &ok) }
            if focusField { window.makeFirstResponder(field) }
            window.sendEvent(key(53, "\u{1b}", in: window))
            check(!panel.isShown, "Escape did not close the panel\(focusField ? " with a field focused" : "")", &ok)
        }
        if ok { print("  OK   Escape closes it, with and without a field focused") }
    }

    // MARK: HelmFormSheet

    private final class Recorder: NSObject {
        var calls: [String] = []
        @objc func save(_ sender: Any?) { calls.append("save") }
        @objc func cancel(_ sender: Any?) { calls.append("cancel") }
    }

    private static func checkReturnAndEscapeReachASheetsButtons(_ ok: inout Bool) {
        print("\n-- P5: Return and Escape reach a form sheet's Save and Cancel --")
        let recorder = Recorder()
        for modifiers in [NSEvent.ModifierFlags(), [.command]] {
            let sheet = HelmFormSheet(title: "Keys")
            _ = sheet.setFooter(target: recorder, confirmTitle: "Save",
                                confirm: #selector(Recorder.save(_:)), cancel: #selector(Recorder.cancel(_:)),
                                confirmModifiers: modifiers)
            let window = OffScreenProbe.window(width: HelmFormSheet.width, height: 400, styleMask: [.titled])
            window.contentView = sheet
            window.orderFront(nil)
            recorder.calls.removeAll()
            // The key-equivalent pass, which is how NSApplication delivers
            // these regardless of which field has the keyboard.
            _ = window.performKeyEquivalent(with: key(36, "\r", in: window, modifiers: modifiers))
            _ = window.performKeyEquivalent(with: key(53, "\u{1b}", in: window))
            let label = modifiers.isEmpty ? "Return" : "Command-Return"
            check(recorder.calls == ["save", "cancel"],
                  "\(label) then Escape ran \(recorder.calls), expected save then cancel", &ok)
            window.orderOut(nil)
        }
        if ok { print("  OK   Return (and Command-Return where the sheet asks for it) saves, Escape cancels") }
    }

    /// The keys come from `setFooter`, so a sheet that built its own footer
    /// would silently lose both.
    private static func checkEverySheetHasTheFooterKeys(_ ok: inout Bool) {
        print("\n-- P5: every form sheet takes its footer, and so its keys, from setFooter --")
        guard let root = SelfTestSources.appSourceDirectory() else {
            print("  SKIP could not find the app's sources")
            return
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix(".swift") }
        var sheets = 0
        var missing: [String] = []
        for name in files {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
                  text.contains("HelmFormSheet(") else { continue }
            if name == "HelmForm.swift" { continue }
            sheets += 1
            if !text.contains(".setFooter(") { missing.append(name) }
        }
        check(sheets >= 10, "found only \(sheets) form sheets - the guard would be vacuous", &ok)
        check(missing.isEmpty, "form sheets with no setFooter, so no Return or Escape: \(missing)", &ok)
        if missing.isEmpty && sheets >= 10 { print("  OK   \(sheets) sheets, all through setFooter") }
    }
}

#endif
