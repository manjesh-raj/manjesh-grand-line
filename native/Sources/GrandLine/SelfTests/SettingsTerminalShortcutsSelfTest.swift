// Grand Line - native macOS app.
//
// The Settings half of PR 2 of the Termius-style plan: T4's scrollback row on
// Settings > Terminal, and (as later commits land) T5's Shortcuts page, T6's
// rebinding and T7's links.
//
// The model halves are pure logic and live beside the code they test -
// `BackgroundScrollbackSelfTest` for the depth and the trim. What this suite
// owns is the page: the real field, its real action, the real confirm, and
// what the page shows afterwards. Every case drives a control the way a click
// or a keystroke reaches it, never the commit method behind it, because a
// suite that calls the commit passes with the wiring deleted (gotcha (19)).
//
// Window-backed (and so listed in `NEEDS_SESSION`): the page is mounted in an
// `OffScreenProbe` window and laid out, and the recorder cases need a real
// first responder.
//
// Run with:
//   swift build && FM_RUN_SETTINGS_TERMINAL_SHORTCUTS_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SettingsTerminalShortcutsSelfTest {

    static func run() -> Bool {
        // A suite that changes the active theme MUST put it back - see
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme`.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        var allOK = true
        for check in [checkTheTourCanSelectASettingsPage,
                      checkTheScrollbackRowCommitsAndWarnsBeforeTrimming,
                      checkTheShortcutsPageListsSearchesAndFilters,
                      checkRecordingAClashAsksAndResetsPutItBack] {
            var ok = true
            autoreleasepool { check(&ok) }
            allOK = allOK && ok
        }
        print(allOK ? "SettingsTerminalShortcutsSelfTest: all checks passed"
                    : "SettingsTerminalShortcutsSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    static func makeSettings() -> SettingsController {
        SettingsController(hostStore: HostStore(),
                           keyStore: SSHKeyStore(),
                           snippetStore: SnippetStore(),
                           dictationStore: DictationStore())
    }

    static func mount(_ controller: SettingsController, width: CGFloat = 1200) -> NSWindow {
        let window = OffScreenProbe.window(width: width, height: 820)
        window.contentView?.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: content.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        controller.viewWillAppear()
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// Type `text` into a field and press Return - the field's own action,
    /// sent the way the field editor sends it.
    static func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        _ = field.sendAction(field.action, to: field.target)
    }

    /// The digits of a number as the page formats it. The page follows the
    /// Mac's locale (this machine groups 100,000 as "1,00,000"), so the suite
    /// compares the number rather than one locale's punctuation.
    static func digits(_ text: String) -> String { text.filter(\.isNumber) }

    // MARK: The tour verb these pages are rendered with

    /// `settings <category>` parses for every page and refuses a page that
    /// does not exist, so a tour that renders Settings > Terminal is not
    /// silently rendering whichever page happened to be showing.
    private static func checkTheTourCanSelectASettingsPage(_ ok: inout Bool) {
        print("\n-- the tour lab's settings verb --")
        for category in SettingsController.Category.allCases {
            check(ReviewTourLab.parse(line: "settings \(category.rawValue)") == .success(.settingsCategory(category.rawValue)),
                  "settings \(category.rawValue) does not parse", &ok)
        }
        check(ReviewTourLab.parse(line: "settings nowhere") == .failure(.badArgument("nowhere")),
              "an unknown Settings page was accepted", &ok)
        check(ReviewTourLab.parse(line: "settings") == .failure(.missingArgument("settings")),
              "a bare settings was accepted", &ok)
        if ok { print("  ok   every page parses, an unknown one is refused") }
    }

    // MARK: T4 - the scrollback row

    /// The scrollback row: a raise applies at once, a lowering that would
    /// trim asks first and Cancel leaves everything as it was, 0 means
    /// 100,000, the note follows the typed number before it is committed, a
    /// focus-loss commit is a real commit, and the trim toggle writes through.
    ///
    /// Injection: drop `case scrollbackField:` from `textFieldChanged` and
    /// nothing commits; drop the confirm and the cancelled lowering applies.
    private static func checkTheScrollbackRowCommitsAndWarnsBeforeTrimming(_ ok: inout Bool) {
        print("\n-- T4: Settings > Terminal's scrollback row --")
        let savedRows = TerminalScrollback.shared.rows
        let savedTrim = TerminalScrollback.shared.trimsBackgroundTabs
        defer {
            TerminalScrollback.shared.setRows(savedRows)
            TerminalScrollback.shared.setTrimsBackgroundTabs(savedTrim)
            HelmConfirm.responderForTests = nil
        }
        TerminalScrollback.shared.setRows(10_000)
        TerminalScrollback.shared.setTrimsBackgroundTabs(true)

        let settings = makeSettings()
        // Two panes hold more than 5,000 rows, none hold more than that.
        settings.scrollbackTrimCount = { $0 < 5_000 ? 2 : 0 }
        let window = mount(settings)
        defer { withExtendedLifetime(window) {} }
        settings.select(.terminal)
        let field = settings.debugScrollbackField
        guard let note = settings.debugScrollbackRow?.descriptionLabel else {
            fail("the scrollback row has no note under it", &ok)
            return
        }
        check(digits(field.stringValue) == "10000", "the field opens on the shipped 10,000, shows \(field.stringValue)", &ok)
        check(note.stringValue.contains("52 MB"), "the note states a full pane's cost: \(note.stringValue)", &ok)

        var asked: [HelmConfirm.Request] = []
        var answer: HelmConfirm.Response = .cancel
        HelmConfirm.responderForTests = { request in
            asked.append(request)
            return answer
        }

        type("25000", into: field)
        check(TerminalScrollback.shared.rows == 25_000, "raising to 25,000 applies, depth \(TerminalScrollback.shared.rows)", &ok)
        check(asked.isEmpty, "raising the depth must not ask, asked \(asked.count)", &ok)
        check(digits(field.stringValue) == "25000", "the field shows the committed 25,000, shows \(field.stringValue)", &ok)

        type("3000", into: field)
        check(asked.count == 1, "lowering under two panes' history asks once, asked \(asked.count)", &ok)
        check(asked.first?.body.contains("2 open panes") == true,
              "the warning names how many panes lose lines: \(asked.first?.body ?? "-")", &ok)
        check(TerminalScrollback.shared.rows == 25_000, "Cancel keeps the depth, now \(TerminalScrollback.shared.rows)", &ok)
        check(digits(field.stringValue) == "25000", "Cancel puts the field back, shows \(field.stringValue)", &ok)

        answer = .confirm
        type("3000", into: field)
        check(TerminalScrollback.shared.rows == 3_000, "confirming applies 3,000, depth \(TerminalScrollback.shared.rows)", &ok)
        check(digits(note.stringValue).contains("3000"), "the note follows the committed depth: \(note.stringValue)", &ok)

        asked.removeAll()
        type("0", into: field)
        check(TerminalScrollback.shared.rows == 100_000, "0 means 100,000, depth \(TerminalScrollback.shared.rows)", &ok)
        check(digits(field.stringValue) == "100000", "the field says what 0 became, shows \(field.stringValue)", &ok)

        // The live note: what the number being typed would cost, before the
        // commit. Typed through the window's real field editor, which is what
        // reaches the delegate on every keystroke.
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() else {
            fail("the scrollback field did not take an editing session", &ok)
            return
        }
        editor.selectAll(nil)
        editor.insertText("50000")
        check(digits(note.stringValue).contains("50000"), "the note follows the typing before a commit: \(note.stringValue)", &ok)
        check(TerminalScrollback.shared.rows == 100_000, "typing alone must not commit, depth \(TerminalScrollback.shared.rows)", &ok)

        // Gotcha (19): focus loss commits too.
        window.makeFirstResponder(nil)
        check(TerminalScrollback.shared.rows == 50_000,
              "leaving the field commits what was typed, depth \(TerminalScrollback.shared.rows)", &ok)

        let toggle = settings.debugTrimBackgroundSwitch
        check(toggle.isOn, "the background trim opens on", &ok)
        _ = toggle.accessibilityPerformPress()
        check(!TerminalScrollback.shared.trimsBackgroundTabs, "pressing the toggle turns the trim off", &ok)
        if ok { print("  ok   raise, warned lowering, 0, live note, focus-loss commit and the trim toggle") }
    }

    // MARK: T5 - the Shortcuts page

    /// A menu the page can read without `NSApp`.
    static let menu = AppDelegate().buildMenu(installing: false)

    static func mountShortcuts() -> (SettingsController, NSWindow) {
        let settings = makeSettings()
        settings.shortcutsMainMenu = { menu }
        let window = mount(settings)
        settings.select(.shortcuts)
        window.contentView?.layoutSubtreeIfNeeded()
        return (settings, window)
    }

    /// Press one of a segmented control's pills, the way a click does.
    static func press(_ id: String, in tabs: HelmSegmentedTabs) -> Bool {
        func find(_ view: NSView) -> HoverHighlightView? {
            if let hover = view as? HoverHighlightView, hover.identifier?.rawValue == id { return hover }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return find(tabs)?.accessibilityPerformPress() ?? false
    }

    /// Type into a search field through the window's real field editor.
    static func search(_ text: String, in field: HelmSearchField, window: NSWindow) {
        field.focusEditor()
        guard let editor = window.firstResponder as? NSTextView else { return }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// The page lists the menu, searches it as the captain types, filters
    /// it, says so when a filter leaves nothing, and draws read-only key caps
    /// in the same trailing column as the recorders.
    ///
    /// Injection: drop `onTextChanged` in `SettingsShortcutsPage.init` and
    /// typing "split" leaves every row showing.
    private static func checkTheShortcutsPageListsSearchesAndFilters(_ ok: inout Bool) {
        print("\n-- T5: Settings > Shortcuts --")
        let (settings, window) = mountShortcuts()
        defer { withExtendedLifetime(window) {} }
        let page = settings.debugShortcutsPage
        check(settings.debugMountedCategory == .shortcuts, "Shortcuts is not the mounted page", &ok)
        let all = page.debugVisibleRows
        check(all.count == page.rows.count && all.count > 50,
              "the page draws \(all.count) rows for a table of \(page.rows.count)", &ok)
        let headings = page.sections.compactMap { $0.headingLabel?.stringValue }
        check(headings.first == "Terminal" && headings.contains("Hosts") && headings.contains("Tabs and pages"),
              "the sections read \(headings)", &ok)

        // The key caps end where the recorders end, and the two control
        // columns are one width, so the page reads as one column.
        let recorderRow = all.first { $0.titleLabel.stringValue == "Split right" }
        let menuRow = all.first { $0.titleLabel.stringValue == "New Host\u{2026}" }
        if let recorderRow, let menuRow, let recorder = page.recorders[.terminal(.splitRight)],
           let pill = menuRow.control.subviews.first {
            let a = recorder.convert(recorder.bounds, to: nil)
            let b = pill.convert(pill.bounds, to: nil)
            check(abs(a.maxX - b.maxX) <= 1, "the key caps end at \(b.maxX), the recorders at \(a.maxX)", &ok)
            let columnA = recorderRow.control.convert(recorderRow.control.bounds, to: nil)
            let columnB = menuRow.control.convert(menuRow.control.bounds, to: nil)
            check(abs(columnA.maxX - columnB.maxX) <= 1 && abs(columnA.width - columnB.width) <= 1,
                  "the control columns differ: \(columnA) and \(columnB)", &ok)
            check((recorder.accessibilityLabel() ?? "").contains("Split right"),
                  "the recorder's VoiceOver label does not name its action", &ok)
        } else {
            fail("the page has no Split right recorder or New Host… row", &ok)
        }

        search("split", in: page.debugSearchField, window: window)
        let found = page.debugVisibleRows.map(\.titleLabel.stringValue)
        check(found == ["Split right", "Split left", "Split down"], "typing \"split\" shows \(found)", &ok)

        search("", in: page.debugSearchField, window: window)
        check(page.debugVisibleRows.count == all.count, "clearing the search did not bring every row back", &ok)

        check(press(ShortcutsTable.Filter.conflicts.rawValue, in: page.debugFilterTabs), "the Conflicts pill did not press", &ok)
        check(page.debugVisibleRows.isEmpty && page.debugEmptyLabelShown && page.debugEmptyText.hasPrefix("No conflicts"),
              "Conflicts on the defaults shows \(page.debugVisibleRows.count) rows and \"\(page.debugEmptyText)\"", &ok)
        check(press(ShortcutsTable.Filter.changed.rawValue, in: page.debugFilterTabs), "the Changed pill did not press", &ok)
        check(page.debugVisibleRows.isEmpty && page.debugEmptyText.hasPrefix("Every shortcut is on its default"),
              "Changed on the defaults shows \(page.debugVisibleRows.count) rows", &ok)
        _ = press(ShortcutsTable.Filter.all.rawValue, in: page.debugFilterTabs)
        check(!page.debugEmptyLabelShown && page.debugVisibleRows.count == all.count, "All did not bring every row back", &ok)
        if ok { print("  ok   \(all.count) rows, search, both filters, the empty state and one control column") }
    }

    // MARK: T6 - rebinding

    /// Press keys into a focused recorder through the window, the way a
    /// keystroke reaches it.
    static func pressKeys(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags,
                          into recorder: KeyChordRecorderView, window: NSWindow) {
        window.makeFirstResponder(recorder)
        _ = recorder.accessibilityPerformPress()
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return }
        window.sendEvent(event)
    }

    /// Recording a chord another row owns asks, naming the owner. Cancel
    /// leaves the binding and the recorder as they were; Use Anyway stores
    /// it, tells the live monitor, and the page shows the clash. The row's
    /// reset and Restore All Defaults put everything back.
    ///
    /// Injection: drop the `owners` check from `recorded(_:for:)` and the
    /// clash is stored without a question.
    private static func checkRecordingAClashAsksAndResetsPutItBack(_ ok: inout Bool) {
        print("\n-- T6: rebinding with conflict detection --")
        let savedTerminal = AppSettings.shared.terminalShortcuts
        let savedCapture = AppSettings.shared.quickCaptureShortcut
        let savedDictation = AppSettings.shared.dictationShortcut
        defer {
            AppSettings.shared.terminalShortcuts = savedTerminal
            AppSettings.shared.quickCaptureShortcut = savedCapture
            AppSettings.shared.dictationShortcut = savedDictation
            HelmConfirm.responderForTests = nil
        }
        var reset = TerminalShortcutSet.defaults
        reset.reset()
        AppSettings.shared.terminalShortcuts = reset
        AppSettings.shared.quickCaptureShortcut = .quickCaptureDefault
        AppSettings.shared.dictationShortcut = .dictationDefault

        let (settings, window) = mountShortcuts()
        defer { withExtendedLifetime(window) {} }
        var told: [TerminalShortcutSet] = []
        var toldCapture: [KeyChord] = []
        settings.onTerminalShortcutsChanged = { told.append($0) }
        settings.onQuickCaptureShortcutChanged = { toldCapture.append($0) }
        let page = settings.debugShortcutsPage
        var asked: [HelmConfirm.Request] = []
        var answer: HelmConfirm.Response = .cancel
        HelmConfirm.responderForTests = { request in
            asked.append(request)
            return answer
        }
        guard let split = page.recorders[.terminal(.splitRight)] else {
            fail("the page has no Split right recorder", &ok)
            return
        }
        let defaultChord = TerminalShortcutAction.splitRight.defaultChord
        let commandK = KeyChord(key: 40, [.command])

        pressKeys(40, "k", [.command], into: split, window: window)
        check(asked.count == 1, "recording ⌘K (Search…) asked \(asked.count) times, want once", &ok)
        check(asked.first.map { $0.body.contains("Search") && $0.confirmTitle == "Use Anyway" } == true,
              "the question does not name the owner or offer Use Anyway: \(asked.first?.body ?? "-")", &ok)
        check(AppSettings.shared.terminalShortcuts[.splitRight] == defaultChord,
              "Cancel stored the clash: \(AppSettings.shared.terminalShortcuts[.splitRight].displayString)", &ok)
        check(split.shortcut == defaultChord, "Cancel left the recorder showing \(split.shortcut.displayString)", &ok)
        check(told.isEmpty, "Cancel told the live monitor about a binding that was never stored", &ok)

        answer = .confirm
        pressKeys(40, "k", [.command], into: split, window: window)
        check(ShortcutsTable.sameKeys(AppSettings.shared.terminalShortcuts[.splitRight], commandK),
              "Use Anyway did not store ⌘K", &ok)
        check(told.last.map { ShortcutsTable.sameKeys($0[.splitRight], commandK) } == true,
              "the live monitor was not told about ⌘K", &ok)
        check(page.rows.first { $0.configurable == .terminal(.splitRight) }?.conflicts.isEmpty == false,
              "the page does not show the clash it just allowed", &ok)
        check(page.debugRestoreAllButton.isEnabled, "Restore All Defaults is disabled with a binding changed", &ok)

        // A chord nobody owns goes straight in.
        asked.removeAll()
        guard let capture = page.recorders[.quickCapture] else {
            fail("the page has no capture recorder", &ok)
            return
        }
        pressKeys(8, "c", [.control, .option, .command], into: capture, window: window)
        check(asked.isEmpty, "a free chord asked anyway", &ok)
        check(toldCapture.last.map { $0.keyCode == 8 } == true, "the capture hotkey was not told about ⌃⌥⌘C", &ok)

        // The row's own reset.
        guard let resetSplit = page.debugResetButton(for: .terminal(.splitRight)) else {
            fail("the Split right row has no reset button", &ok)
            return
        }
        check(resetSplit.isEnabled, "a changed row's reset is disabled", &ok)
        resetSplit.performClick(nil)
        check(AppSettings.shared.terminalShortcuts[.splitRight] == defaultChord,
              "the row's reset left \(AppSettings.shared.terminalShortcuts[.splitRight].displayString)", &ok)
        check(page.debugResetButton(for: .terminal(.splitRight))?.isEnabled == false,
              "the reset stays enabled on a row back on its default", &ok)

        // Restore All Defaults puts capture back too, after asking.
        asked.removeAll()
        page.debugRestoreAllButton.performClick(nil)
        check(asked.count == 1 && asked.first?.confirmTitle == "Restore Defaults", "Restore All did not ask once", &ok)
        check(AppSettings.shared.quickCaptureShortcut == .quickCaptureDefault, "Restore All left capture changed", &ok)
        check(toldCapture.last == .quickCaptureDefault, "the capture hotkey was not told about the restore", &ok)
        check(!page.debugRestoreAllButton.isEnabled, "Restore All stays enabled with nothing changed", &ok)
        if ok { print("  ok   asked with the owner, Cancel, Use Anyway, a free chord, the row reset and Restore All") }
    }
}

#endif
