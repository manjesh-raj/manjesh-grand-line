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
        for check in [checkTheTourCanSelectASettingsPage] {
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
}

#endif
