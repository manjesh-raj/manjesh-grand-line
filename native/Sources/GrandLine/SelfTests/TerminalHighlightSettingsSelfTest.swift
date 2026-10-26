// Grand Line - native macOS app.
//
// Settings > Terminal's keyword highlighting card (T2). Run with:
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
