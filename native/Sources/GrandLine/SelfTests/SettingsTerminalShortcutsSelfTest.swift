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
                      checkTheShortcutsPageListsSearchesAndFilters] {
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

        // The key-cap column and the recorder column end at one x.
        let recorderRow = all.first { $0.titleLabel.stringValue == "Split right" }
        let menuRow = all.first { $0.titleLabel.stringValue == "New Host\u{2026}" }
        if let recorderRow, let menuRow {
            let a = recorderRow.control.convert(recorderRow.control.bounds, to: nil)
            let b = menuRow.control.convert(menuRow.control.bounds, to: nil)
            check(abs(a.maxX - b.maxX) <= 1 && abs(a.width - b.width) <= 1,
                  "the key caps end at \(b.maxX) (width \(b.width)), the recorders at \(a.maxX) (width \(a.width))", &ok)
            check(recorderRow.control is KeyChordRecorderView, "a configurable row has no recorder", &ok)
            check((recorderRow.control.accessibilityLabel() ?? "").contains("Split right"),
                  "the recorder's VoiceOver label does not name its action", &ok)
        } else {
            fail("the page has no Split right or New Host… row", &ok)
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
}

#endif
