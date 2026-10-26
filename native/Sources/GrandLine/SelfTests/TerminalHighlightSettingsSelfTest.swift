// Grand Line - native macOS app.
//
// Settings > Terminal's keyword highlighting cards (T2 and T3). Run with:
//
//   swift build && FM_RUN_TERMINAL_HIGHLIGHT_SETTINGS_TESTS=1 .build/debug/GrandLine; echo $?
//
// Headless: the card is built standalone, exactly as `SettingsController`
// builds it, and every control is driven through the entry point a real
// interaction reaches - a switch through `accessibilityPerformPress` (which is
// `setOnFromUser`, the path a click and VoiceOver both take), a colour pop-up
// through its own target/action, and a custom colour through the colour
// panel's action. What is asserted is the stored value, the live
// highlighter, and the preview's painted text.
//
//   1. The master switch turns highlighting off everywhere and dims the six
//      class rows; turning it back on restores them.
//   2. A class switch removes exactly that class from the preview.
//   3. A theme colour choice is stored as an ANSI index and painted.
//   4. A custom colour too faint for the terminal background is stored as
//      picked, painted readable, and the row says it was adjusted.
//   5. In every palette, the swatches and the preview's colours clear the
//      text floor on the terminal background.
//   6. Restore Defaults puts back the shipped settings.
//   7. Every control carries a VoiceOver label.
//   8. A source guard: `SettingsController` builds, refreshes and themes it.
//   9. T3's custom rules: a bad pattern is refused at save and says why, a
//      fixed one is saved and coloured live, edit and Esc and delete (behind
//      its confirm) work, Restore Defaults keeps rules, and the 33rd rule is
//      refused.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum TerminalHighlightSettingsSelfTest {

    static func run() -> Bool {
        print("TerminalHighlightSettingsSelfTest")
        var ok = true
        let store = AppSettings.shared
        let saved = store.terminalHighlighting
        defer { store.terminalHighlighting = saved }

        store.terminalHighlighting = .defaults
        let highlighter = TerminalKeywordHighlighter(settings: .defaults, theme: .dusk)
        let card = TerminalHighlightSettingsSections(store: store, highlighter: highlighter, theme: .dusk)
        let sections = card.sections()
        check(sections.count >= 2, "the card built \(sections.count) sections; expected the class group and the preview", &ok)
        card.applyTheme(.dusk)

        checkMasterSwitch(card, store, highlighter, &ok)
        checkClassSwitch(card, store, &ok)
        checkThemeColourChoice(card, store, &ok)
        checkCustomColour(card, store, &ok)
        checkEveryPalette(card, &ok)
        checkRestoreDefaults(card, store, &ok)
        checkAccessibilityLabels(card, &ok)
        checkCustomRules(card, store, highlighter, &ok)
        checkSettingsControllerWiresTheCard(&ok)

        print(ok ? "TerminalHighlightSettingsSelfTest: all checks passed"
                 : "TerminalHighlightSettingsSelfTest: FAILURES")
        return ok
    }

    // MARK: Cases

    private static func checkMasterSwitch(_ card: TerminalHighlightSettingsSections, _ store: AppSettings,
                                          _ highlighter: TerminalKeywordHighlighter, _ ok: inout Bool) {
        let before = highlighter.highlightVersion
        check(colouredWords(card).contains("ERROR"),
              "with the shipped defaults the preview does not colour ERROR; the cases below would prove nothing", &ok)
        _ = card.debugMasterSwitch.accessibilityPerformPress()
        check(store.terminalHighlighting.enabled == false, "pressing the master switch did not store \"off\"", &ok)
        check(!highlighter.highlightsEnabled, "the live highlighter is still on after the master switch went off", &ok)
        check(highlighter.highlightVersion != before, "the live highlighter's version did not move, so open terminals would not repaint", &ok)
        check(colouredWords(card).isEmpty, "the preview still colours \(colouredWords(card)) with highlighting off", &ok)
        let dimmed = KeywordHighlightClass.allCases.filter { card.debugClassRow($0)?.isRowEnabled == false }
        check(dimmed.count == KeywordHighlightClass.allCases.count,
              "only \(dimmed.count) of the six class rows were dimmed with highlighting off", &ok)

        _ = card.debugMasterSwitch.accessibilityPerformPress()
        check(store.terminalHighlighting.enabled && highlighter.highlightsEnabled,
              "pressing the master switch again did not turn highlighting back on", &ok)
        check(card.debugClassRow(.error)?.isRowEnabled == true, "the class rows stayed dimmed after switching back on", &ok)
    }

    private static func checkClassSwitch(_ card: TerminalHighlightSettingsSections, _ store: AppSettings,
                                         _ ok: inout Bool) {
        guard let toggle = card.debugClassSwitch(.warning) else {
            fail("the Warning row has no switch", &ok)
            return
        }
        _ = toggle.accessibilityPerformPress()
        check(store.terminalHighlighting[.warning].enabled == false, "the Warning switch did not store \"off\"", &ok)
        let words = colouredWords(card)
        check(!words.contains("WARN") && !words.contains("retrying"),
              "with Warning off the preview still colours \(words)", &ok)
        check(words.contains("ERROR"), "switching Warning off also stopped Error: \(words)", &ok)
        _ = toggle.accessibilityPerformPress()
        check(store.terminalHighlighting[.warning].enabled, "the Warning switch did not turn back on", &ok)
    }

    private static func checkThemeColourChoice(_ card: TerminalHighlightSettingsSections, _ store: AppSettings,
                                               _ ok: inout Bool) {
        guard let popUp = card.debugColorPopUp(.error),
              let index = TerminalHighlightSettingsSections.choices(for: .error)
                .firstIndex(where: { $0.choice == .ansi(13) }) else {
            fail("the Error row has no colour pop-up offering Bright magenta", &ok)
            return
        }
        popUp.selectItem(at: index)
        _ = (popUp.target as? NSObject)?.perform(popUp.action, with: popUp)
        check(store.terminalHighlighting[.error].color == .ansi(13),
              "choosing Bright magenta stored \(String(describing: store.terminalHighlighting[.error].color))", &ok)
        let expected = TerminalKeywordHighlighter.resolvedColor(for: .error, settings: store.terminalHighlighting, theme: .dusk)
        check(same(color(of: "ERROR", in: card), expected), "the preview does not paint ERROR in the chosen colour", &ok)
        check(same(card.debugSwatchColor(.error), expected), "the Error swatch does not show the chosen colour", &ok)
    }

    private static func checkCustomColour(_ card: TerminalHighlightSettingsSections, _ store: AppSettings,
                                          _ ok: inout Bool) {
        let dusk = HelmTheme.dusk
        let faint = dusk.terminalCard?.backgroundHex ?? dusk.backgroundHex
        card.debugPickCustomColor(faint, for: .info)
        let stored = store.terminalHighlighting[.info].color?.hex?.lowercased()
        check(stored == faint.lowercased().replacingOccurrences(of: "#", with: ""),
              "a custom pick stored \(stored ?? "nil") rather than the colour picked (\(faint))", &ok)
        let painted = color(of: "INFO", in: card)
        let background = TerminalKeywordHighlighter.terminalBackground(dusk)
        check(painted.map { HelmContrast.ratio($0, background) >= HelmContrast.textTarget - 0.01 } == true,
              "a custom colour equal to the terminal background was painted unreadable", &ok)
        let note = card.debugClassRow(.info)?.descriptionLabel?.stringValue ?? ""
        check(note.contains("lightened or darkened"), "the Info row does not say its custom colour was adjusted: \"\(note)\"", &ok)
    }

    private static func checkEveryPalette(_ card: TerminalHighlightSettingsSections, _ ok: inout Bool) {
        var measured = 0
        for theme in HelmTheme.allThemes {
            card.applyTheme(theme)
            let background = TerminalKeywordHighlighter.terminalBackground(theme)
            for cls in KeywordHighlightClass.allCases {
                guard let swatch = card.debugSwatchColor(cls) else {
                    fail("\(theme.id): the \(cls.rawValue) swatch has no colour", &ok)
                    continue
                }
                measured += 1
                check(HelmContrast.ratio(swatch, background) >= HelmContrast.textTarget - 0.01,
                      "\(theme.id): the \(cls.rawValue) swatch measures "
                      + String(format: "%.2f", HelmContrast.ratio(swatch, background)) + ":1 on the terminal background", &ok)
            }
            card.debugPreview.layoutSubtreeIfNeeded()
            if let fill = card.debugPreview.layer?.backgroundColor.flatMap({ NSColor(cgColor: $0) }) {
                check(same(fill, background), "\(theme.id): the preview is not on the terminal's own background", &ok)
            }
        }
        check(measured == HelmTheme.allThemes.count * KeywordHighlightClass.allCases.count,
              "measured \(measured) swatches; the sweep did not cover every palette and class", &ok)
        card.applyTheme(.dusk)
    }

    private static func checkRestoreDefaults(_ card: TerminalHighlightSettingsSections, _ store: AppSettings,
                                             _ ok: inout Bool) {
        guard let restore = card.debugRestoreButton else {
            fail("the card has no Restore Defaults button", &ok)
            return
        }
        check(restore.isEnabled, "Restore Defaults is disabled with two colours changed", &ok)
        _ = (restore.target as? NSObject)?.perform(restore.action, with: restore)
        check(store.terminalHighlighting == .defaults, "Restore Defaults did not restore the shipped settings", &ok)
        check(!restore.isEnabled, "Restore Defaults stays enabled once everything is default", &ok)
        check(card.debugColorPopUp(.error)?.indexOfSelectedItem == 0, "the Error pop-up did not return to the theme default", &ok)
    }

    private static func checkAccessibilityLabels(_ card: TerminalHighlightSettingsSections, _ ok: inout Bool) {
        var controls: [NSView] = [card.debugMasterSwitch]
        for cls in KeywordHighlightClass.allCases {
            if let toggle = card.debugClassSwitch(cls) { controls.append(toggle) }
            if let popUp = card.debugColorPopUp(cls) { controls.append(popUp) }
        }
        check(controls.count == 13, "found \(controls.count) controls; expected the master switch plus a switch and a pop-up per class", &ok)
        for control in controls where (control.accessibilityLabel() ?? "").isEmpty {
            fail("a \(type(of: control)) on the card has no VoiceOver label", &ok)
        }
    }

    /// The page wiring has no headless half - mounting `SettingsController`
    /// needs a window - so it is a source guard: the Terminal page builds the
    /// card, and both refresh paths reach it.
    private static func checkSettingsControllerWiresTheCard(_ ok: inout Bool) {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: dir.appendingPathComponent("SettingsController.swift"), encoding: .utf8) else {
            print("  SKIP the SettingsController source is not next to this binary")
            return
        }
        for marker in ["keywordHighlighting.sections()", "keywordHighlighting.refresh()",
                       "keywordHighlighting.applyTheme(theme)"] {
            check(source.contains(marker), "SettingsController.swift no longer calls \(marker)", &ok)
        }
    }

    // MARK: Custom rules (T3)

    private static func press(_ button: NSControl?) {
        guard let button else { return }
        _ = (button.target as? NSObject)?.perform(button.action, with: button)
    }

    private static func checkCustomRules(_ card: TerminalHighlightSettingsSections, _ store: AppSettings,
                                         _ highlighter: TerminalKeywordHighlighter, _ ok: inout Bool) {
        store.terminalHighlighting = .defaults
        highlighter.update(settings: .defaults)
        card.refresh()
        check(card.debugRuleRows.first?.titleLabel.stringValue == "No rules yet",
              "with no rules the card does not show its empty state", &ok)
        check(card.debugAddRuleButton?.isEnabled == true, "Add Rule is disabled with no rules", &ok)

        // Add a pattern rule that does not compile: refused at save.
        press(card.debugAddRuleButton)
        check(card.debugEditorIsOpen, "Add Rule did not open the editor in the card", &ok)
        card.debugEditorKindTabs?.debugClickTab(id: KeywordHighlightRule.Kind.pattern.rawValue)
        card.debugEditorField?.stringValue = "(E[0-9"
        press(card.debugEditorField)   // Return: the field's own action
        check(store.terminalHighlighting.rules.isEmpty, "a pattern that does not compile was saved", &ok)
        check(card.debugEditorMessage?.contains("does not compile") == true,
              "the refusal does not say why (\(card.debugEditorMessage ?? "nil"))", &ok)
        check(card.debugEditorIsOpen, "a refused save closed the editor and lost what was typed", &ok)

        // Fix it and save.
        card.debugEditorField?.stringValue = #"\bE\d{4}\b"#
        press(card.debugEditorField)
        let saved = store.terminalHighlighting.rules
        check(saved.count == 1 && saved.first?.kind == .pattern && saved.first?.text == #"\bE\d{4}\b"#,
              "the corrected pattern was not saved as a pattern rule: \(saved.map(\.text))", &ok)
        check(!card.debugEditorIsOpen, "saving did not close the editor", &ok)
        let units = Array("raised E1234 twice".utf16)
        let runs = highlighter.highlights(forRow: units)
        check(runs.count == 1 && runs.first?.range == 7..<12,
              "the live highlighter does not colour the new rule's match: \(runs.map(\.range))", &ok)

        // Edit: case-sensitive, a theme colour, then a custom one.
        guard let edit = card.debugRuleButtons.first(where: { $0.accessibilityLabel()?.hasPrefix("Edit") == true }) else {
            fail("the rule row has no Edit button", &ok)
            return
        }
        press(edit)
        check(card.debugEditorField?.stringValue == #"\bE\d{4}\b"#, "Edit did not load the rule into the editor", &ok)
        _ = card.debugEditorCaseSwitch?.accessibilityPerformPress()
        if let popUp = card.debugEditorColorPopUp,
           let index = TerminalHighlightSettingsSections.ruleChoices.firstIndex(where: { $0.choice == .ansi(14) }) {
            popUp.selectItem(at: index)
            press(popUp)
        }
        check(store.terminalHighlighting.rules.first?.color == .ansi(5),
              "a colour choice was saved before Save was pressed", &ok)
        press(card.debugEditorField)
        var rule = store.terminalHighlighting.rules.first
        check(rule?.caseSensitive == true && rule?.color == .ansi(14),
              "editing did not save case sensitivity and the colour: \(String(describing: rule))", &ok)

        press(card.debugRuleButtons.first { $0.accessibilityLabel()?.hasPrefix("Edit") == true })
        card.debugPickCustomRuleColor("336699")
        press(card.debugEditorField)
        rule = store.terminalHighlighting.rules.first
        check(rule?.color == .custom("336699"), "a custom rule colour was not saved: \(String(describing: rule?.color))", &ok)

        // Esc discards an edit.
        press(card.debugRuleButtons.first { $0.accessibilityLabel()?.hasPrefix("Edit") == true })
        card.debugEditorField?.stringValue = "something else"
        if let field = card.debugEditorField {
            _ = card.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        check(!card.debugEditorIsOpen && store.terminalHighlighting.rules.first?.text == #"\bE\d{4}\b"#,
              "Esc did not discard the edit", &ok)

        // Restore Defaults keeps the captain's rules.
        store.terminalHighlighting.enabled = false
        card.refresh()
        press(card.debugRestoreButton)
        check(store.terminalHighlighting.enabled && store.terminalHighlighting.rules.count == 1,
              "Restore Defaults did not keep the custom rules", &ok)

        // Delete asks first, and a No keeps the rule.
        card.confirmRuleDeletion = { _ in false }
        press(card.debugRuleButtons.first { $0.accessibilityLabel()?.hasPrefix("Delete") == true })
        check(store.terminalHighlighting.rules.count == 1, "a declined delete removed the rule", &ok)
        var asked = false
        card.confirmRuleDeletion = { _ in asked = true; return true }
        press(card.debugRuleButtons.first { $0.accessibilityLabel()?.hasPrefix("Delete") == true })
        check(asked && store.terminalHighlighting.rules.isEmpty, "a confirmed delete did not remove the rule", &ok)

        // The cap: 32 rules, and a save that would make 33 is refused.
        var settings = store.terminalHighlighting
        settings.rules = (0..<31).map { KeywordHighlightRule(kind: .words, text: "word\($0)") }
        store.terminalHighlighting = settings
        card.refresh()
        press(card.debugAddRuleButton)
        settings.rules.append(KeywordHighlightRule(kind: .words, text: "late"))
        store.terminalHighlighting = settings
        card.debugEditorField?.stringValue = "one more"
        press(card.debugEditorField)
        check(store.terminalHighlighting.rules.count == KeywordHighlightRule.maximumCount,
              "a 33rd rule was saved", &ok)
        check(card.debugEditorMessage?.contains("already have 32") == true,
              "the 33rd rule's refusal does not say why (\(card.debugEditorMessage ?? "nil"))", &ok)
        if let field = card.debugEditorField {
            _ = card.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        check(card.debugAddRuleButton?.isEnabled == false, "Add Rule stays enabled at 32 rules", &ok)

        // VoiceOver: every rule button and editor control has a label.
        press(card.debugRuleButtons.first { $0.accessibilityLabel()?.hasPrefix("Edit") == true })
        let editorControls: [NSView?] = [card.debugEditorField, card.debugEditorKindTabs, card.debugEditorCaseSwitch,
                                         card.debugEditorColorPopUp]
        for control in editorControls + card.debugRuleButtons.map({ $0 as NSView? }) {
            if (control?.accessibilityLabel() ?? "").isEmpty {
                fail("a rule control (\(control.map { "\(type(of: $0))" } ?? "missing")) has no VoiceOver label", &ok)
            }
        }
        if let field = card.debugEditorField {
            _ = card.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        store.terminalHighlighting = .defaults
        card.refresh()
    }

    // MARK: Helpers

    /// Words in the preview drawn in anything other than the terminal's ink.
    private static func colouredWords(_ card: TerminalHighlightSettingsSections) -> [String] {
        let text = card.debugPreview.renderedText
        guard text.length > 0, let ink = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor else {
            return []
        }
        var words: [String] = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let color = value as? NSColor, !same(color, ink) else { return }
            words.append((text.string as NSString).substring(with: range))
        }
        return words
    }

    private static func color(of word: String, in card: TerminalHighlightSettingsSections) -> NSColor? {
        let text = card.debugPreview.renderedText
        let range = (text.string as NSString).range(of: word)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    private static func same(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.002 && abs(x.1 - y.1) < 0.002 && abs(x.2 - y.2) < 0.002
    }
}

#endif
