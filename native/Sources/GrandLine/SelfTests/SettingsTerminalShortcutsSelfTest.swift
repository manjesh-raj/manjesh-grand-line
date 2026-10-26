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
                      checkTheScrollbackRowCommitsAndWarnsBeforeTrimming] {
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
}

#endif
