// Grand Line - native macOS app.
//
// The window half of `fm/grandline-console-fixes`: the Console page's top
// edge and its band (B2), and the caret in both composers (C1), measured from
// real views after a real layout pass in a real off-screen window. Run from
// `PageRedesignsSelfTest`, which already owns an off-screen split shell, so
// this adds no window-backed suite (`NEEDS_SESSION` is at its ceiling).

#if FM_SELFTESTS

import AppKit

enum ConsoleFixesWindowChecks {

    static func checkConsole(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL, _ ok: inout Bool) {
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        checkTheTopEdge(shell, window, &ok)
        checkTheCaretShowsOnFocus(window, &ok)
    }

    // MARK: Item 1 - the dead space

    /// The captain's "unwanted empty space between the top toolbar and the
    /// banner": Console gives up S03's empty 32pt header slot, so its band
    /// sits `bandTop` under the toolbar, and the tab strip starts right
    /// under the band. Every other page keeps the slot.
    private static func checkTheTopEdge(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        print("\n-- item 1: Console's band sits right under the toolbar --")
        shell.workspace.navigator.show(.console)
        settle(shell)
        let console = shell.workspace.console
        let band = console.sessionBand
        guard let reading = PageScaffoldProbe.measure(shell) else { return fail("Console could not be measured", &ok) }
        let header = shell.debugContentPaneHeader
        check(header.isHiddenOrHasHiddenAncestor, "Console still keeps the empty header line (\(header.frame))", &ok)
        let bandTop = window.frame.height - band.convert(NSPoint(x: 0, y: band.isFlipped ? 0 : band.bounds.height), to: nil).y
        let gap = bandTop - reading.toolbarBottom
        print("   toolbar bottom \(reading.toolbarBottom), band top \(bandTop), gap \(gap), band \(band.frame.height)pt")
        check(abs(gap - ConsoleController.bandTop) < 1,
              "the band starts \(gap)pt under the toolbar, want \(ConsoleController.bandTop) (it was 44)", &ok)
        check(band.frame.height == ConsoleSessionBand.height && ConsoleSessionBand.height <= 40,
              "the band is \(band.frame.height)pt tall, want B2's one line", &ok)
        let bandFrame = band.convert(band.bounds, to: console.view)
        let tabFrame = console.tabBar.convert(console.tabBar.bounds, to: console.view)
        let between = console.view.isFlipped ? tabFrame.minY - bandFrame.maxY : bandFrame.minY - tabFrame.maxY
        check(abs(between) < 0.5, "the tab strip starts \(between)pt under the band, want 0", &ok)
        // The fixture can fail: another page still keeps the slot.
        shell.workspace.navigator.show(.health)
        settle(shell)
        check(!header.isHiddenOrHasHiddenAncestor && abs(header.frame.height - HelmMetrics.pageHeaderLine) < 0.5,
              "Health lost its header line (\(header.frame)) - only Console gives it up", &ok)
        shell.workspace.navigator.show(.console)
        settle(shell)
    }

    private static func settle(_ shell: WorkspaceShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    // MARK: Item 3 - the caret

    /// The captain's "clicking into the field never shows the cursor until
    /// the first character is typed". A focused, empty composer has to show
    /// its caret inside the visible text area, in both composers.
    private static func checkTheCaretShowsOnFocus(_ window: NSWindow, _ ok: inout Bool) {
        print("\n-- the composers show a caret as soon as they are focused --")
        guard let host = window.contentView else { return fail("the probe window has no content view", &ok) }
        let composer = ConsoleComposerController()
        defer { composer.shutdown() }
        let pane = SRELeadChatView()
        let compose = composer.debugContentView
        compose.translatesAutoresizingMaskIntoConstraints = true
        pane.translatesAutoresizingMaskIntoConstraints = true
        compose.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
        pane.frame = NSRect(x: 440, y: 0, width: 380, height: 420)
        host.addSubview(compose)
        host.addSubview(pane)
        defer {
            compose.removeFromSuperview()
            pane.removeFromSuperview()
        }
        composer.debugShow(intent: "", phase: .idle, target: "Shell")
        window.makeKey()
        for (name, well) in [("Compose", composer.debugWell), ("SRE Lead", pane.debugWell)] {
            let textView = well.textView
            host.layoutSubtreeIfNeeded()
            let cursor = well.debugCursorView
            check(cursor.isHidden, "\(name): the cursor shows before the field has focus", &ok)
            check(window.makeFirstResponder(textView), "\(name): the field would not take focus", &ok)
            host.layoutSubtreeIfNeeded()
            let visible = textView.visibleRect
            print("   \(name): cursor \(cursor.frame) hidden=\(cursor.isHidden), visible text \(visible), key=\(window.isKeyWindow)")
            check(!cursor.isHidden && cursor.frame.width > 4 && cursor.frame.height > 8,
                  "\(name): a focused, empty field shows no cursor (\(cursor.frame), hidden \(cursor.isHidden))", &ok)
            check(visible.contains(cursor.frame), "\(name): the cursor \(cursor.frame) is outside the visible text \(visible)", &ok)
            check(textView.subviews.last === cursor, "\(name): something draws over the cursor", &ok)
            check(!well.debugPlaceholderLabel.frame.intersects(cursor.frame),
                  "\(name): the placeholder \(well.debugPlaceholderLabel.frame) sits under the cursor \(cursor.frame)", &ok)
            // Typing moves it one cell along, and taking focus away hides it.
            let start = cursor.frame.minX
            textView.insertText("k", replacementRange: textView.selectedRange())
            host.layoutSubtreeIfNeeded()
            check(cursor.frame.minX > start + 4, "\(name): the cursor did not move after a keystroke (\(start) to \(cursor.frame.minX))", &ok)
            window.makeFirstResponder(nil)
            check(cursor.isHidden, "\(name): the cursor stays after focus left", &ok)
            textView.string = ""
        }
    }
}

#endif
