// Grand Line - native macOS app.
//
// Settings > Terminal's keyword highlighting cards: the master switch, one
// row per built-in class with its own switch and colour, and a live preview
// (T2 of the Termius-style plan), and the captain's own rules (T3), edited in
// place in their card rather than in a pop-up.
//
// Its own file rather than more of `SettingsController`, for the reason that
// controller's own header gives for `SettingsForm.swift`: the page assembles
// sections, and a self-contained group of rows that owns its own state is
// easier to read, test and theme as one object. `SettingsController` builds
// these sections into the Terminal page and forwards theme and refresh calls.
//
// Colours are offered as the theme's own ANSI colours first ("Red", "Bright
// cyan"), because those resolve per palette and so hold in all 26 themes. A
// custom colour is one fixed RGB value, and the row says so when
// `HelmContrast` had to adjust it to stay readable on this theme's terminal
// background.

import AppKit

final class TerminalHighlightSettingsSections: NSObject {

    /// Where settings are read and written. `AppSettings.shared` in the app;
    /// a suite passes its own.
    private let store: AppSettings
    /// What the live terminals use. Updated on every change, so an open tab
    /// repaints without a relaunch.
    private let highlighter: TerminalKeywordHighlighter
    private var theme: HelmTheme

    private let masterSwitch = HelmToggle()
    private var masterRow: SettingsRow?
    private var classRows: [KeywordHighlightClass: SettingsRow] = [:]
    private var classSwitches: [KeywordHighlightClass: HelmToggle] = [:]
    private var colorPopUps: [KeywordHighlightClass: HelmPopUpButton] = [:]
    private var swatches: [KeywordHighlightClass: NSView] = [:]
    private var restoreButton: HelmButton?
    private let preview = TerminalHighlightPreview()

    /// What the system colour panel is choosing a colour for.
    private enum ColorTarget: Equatable {
        case highlightClass(KeywordHighlightClass)
        case ruleDraft
    }
    private var colorPanelTarget: ColorTarget?

    init(store: AppSettings = .shared,
         highlighter: TerminalKeywordHighlighter = .shared,
         theme: HelmTheme = ThemeManager.shared.theme) {
        self.store = store
        self.highlighter = highlighter
        self.theme = theme
        super.init()
    }

    // MARK: Colour choices

    /// The popup's choices, in order: the class default, then the theme's
    /// twelve non-grey ANSI colours, then Custom.
    enum Choice: Equatable {
        case classDefault
        case ansi(Int)
        case custom
    }

    static let ansiNames: [(index: Int, name: String)] = [
        (1, "Red"), (2, "Green"), (3, "Yellow"), (4, "Blue"), (5, "Magenta"), (6, "Cyan"),
        (9, "Bright red"), (10, "Bright green"), (11, "Bright yellow"), (12, "Bright blue"),
        (13, "Bright magenta"), (14, "Bright cyan"),
    ]

    static func defaultTitle(for cls: KeywordHighlightClass) -> String {
        let name = ansiNames.first { $0.index == cls.defaultANSIIndex }?.name ?? "Theme"
        return "Theme \(name.lowercased())"
    }

    static func choices(for cls: KeywordHighlightClass) -> [(title: String, choice: Choice)] {
        [(defaultTitle(for: cls), .classDefault)]
            + ansiNames.filter { $0.index != cls.defaultANSIIndex }.map { ($0.name, .ansi($0.index)) }
            + [("Custom\u{2026}", .custom)]
    }

    static func choice(for setting: KeywordHighlightClassSetting, of cls: KeywordHighlightClass) -> Choice {
        guard let color = setting.color else { return .classDefault }
        if color.isCustom { return .custom }
        if let index = color.ansiIndex, index != cls.defaultANSIIndex,
           ansiNames.contains(where: { $0.index == index }) {
            return .ansi(index)
        }
        return .classDefault
    }

    // MARK: Building

    func sections() -> [SettingsSection] {
        masterSwitch.onToggle = { [weak self] in self?.masterToggled() }
        masterSwitch.setAccessibilityLabel("Highlight keywords")
        let master = SettingsRow(
            title: "Highlight keywords",
            description: "Colours errors, warnings and addresses in terminal output as it is drawn. "
                + "A program\u{2019}s own colours, full-screen apps like vim, copied text and saved logs are never changed.",
            control: masterSwitch)
        masterRow = master

        var rows = [master]
        for cls in KeywordHighlightClass.allCases {
            let toggle = HelmToggle()
            toggle.setAccessibilityLabel("Highlight \(cls.title)")
            toggle.onToggle = { [weak self] in self?.classToggled(cls) }
            classSwitches[cls] = toggle

            let popUp = HelmPopUpButton()
            for item in Self.choices(for: cls) { popUp.addItem(withTitle: item.title) }
            popUp.target = self
            popUp.action = #selector(colorPicked(_:))
            popUp.tag = KeywordHighlightClass.allCases.firstIndex(of: cls) ?? 0
            popUp.setAccessibilityLabel("\(cls.title) colour")
            // One width for all six, so the swatches and switches form a
            // column rather than following each title's length.
            popUp.widthAnchor.constraint(equalToConstant: HelmType.scaled(150)).isActive = true
            colorPopUps[cls] = popUp

            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 4
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 14),
                swatch.heightAnchor.constraint(equalToConstant: 14),
            ])
            swatch.setAccessibilityElement(false)
            swatches[cls] = swatch

            let controls = NSStackView(views: [swatch, popUp, toggle])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = HelmMetrics.s2
            let row = SettingsRow(title: cls.title, description: cls.sample, control: controls, isSubRow: true)
            classRows[cls] = row
            rows.append(row)
        }

        let restore = HelmButton(title: "Restore Defaults", variant: .secondary,
                                 target: self, action: #selector(restoreDefaults))
        restoreButton = restore

        preview.translatesAutoresizingMaskIntoConstraints = false
        let sections = [
            SettingsSection(heading: "Keyword highlighting", aside: restore, group: SettingsGroup(rows: rows),
                            foot: "Colours default to this theme\u{2019}s own terminal colours, so they follow you between themes. "
                                + "Every colour is checked for contrast against the terminal background and adjusted if it is too faint to read."),
            buildRulesSection(),
            SettingsSection(heading: "Preview", group: SettingsGroup(custom: preview)),
        ]
        refresh()
        return sections
    }

    // MARK: State

    /// Pushes the stored settings into every control.
    func refresh() {
        let settings = store.terminalHighlighting
        masterSwitch.isOn = settings.enabled
        for cls in KeywordHighlightClass.allCases {
            let setting = settings[cls]
            classSwitches[cls]?.isOn = setting.enabled
            let choice = Self.choice(for: setting, of: cls)
            if let index = Self.choices(for: cls).firstIndex(where: { $0.choice == choice }) {
                colorPopUps[cls]?.selectItem(at: index)
            }
            classRows[cls]?.isRowEnabled = settings.enabled
            // A class switched off keeps its colour control, dimmed, so the
            // row still says what it would paint.
            colorPopUps[cls]?.isEnabled = settings.enabled && setting.enabled
            classRows[cls]?.descriptionLabel?.stringValue = description(for: cls, settings: settings)
        }
        restoreButton?.isEnabled = !settings.classesAreDefault
        rebuildRules()
        repaintColors(settings)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        masterSwitch.applyTheme(theme)
        for toggle in classSwitches.values { toggle.applyTheme(theme) }
        let settings = store.terminalHighlighting
        for cls in KeywordHighlightClass.allCases {
            classRows[cls]?.descriptionLabel?.stringValue = description(for: cls, settings: settings)
        }
        repaintColors(settings)
        themeRules()
    }

    private func repaintColors(_ settings: KeywordHighlightSettings) {
        for cls in KeywordHighlightClass.allCases {
            let color = TerminalKeywordHighlighter.resolvedColor(for: cls, settings: settings, theme: theme)
            swatches[cls]?.layer?.backgroundColor = color.cgColor
            swatches[cls]?.layer?.borderWidth = 1
            swatches[cls]?.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        }
        preview.render(settings: settings, theme: theme)
    }

    /// The row's sample words, plus what happened to a custom colour.
    private func description(for cls: KeywordHighlightClass, settings: KeywordHighlightSettings) -> String {
        guard let color = settings[cls].color, let hex = color.hex,
              TerminalKeywordHighlighter.isValidHex(hex) else {
            return cls.sample
        }
        let raw = HelmTheme.nsColor(hex)
        let background = TerminalKeywordHighlighter.terminalBackground(theme)
        let ratio = HelmContrast.ratio(raw, background)
        if ratio >= HelmContrast.textTarget {
            return "\(cls.sample). Custom colour, \(String(format: "%.1f", ratio)):1 on this theme\u{2019}s terminal."
        }
        return "\(cls.sample). Custom colour is only \(String(format: "%.1f", ratio)):1 on this theme\u{2019}s "
            + "terminal, so it is shown lightened or darkened to stay readable."
    }

    private func write(_ change: (inout KeywordHighlightSettings) -> Void) {
        var settings = store.terminalHighlighting
        change(&settings)
        store.terminalHighlighting = settings
        highlighter.update(settings: settings)
        refresh()
    }

    // MARK: Actions

    private func masterToggled() {
        let on = masterSwitch.isOn
        write { $0.enabled = on }
    }

    private func classToggled(_ cls: KeywordHighlightClass) {
        let on = classSwitches[cls]?.isOn ?? true
        write { $0[cls].enabled = on }
    }

    @objc private func colorPicked(_ sender: HelmPopUpButton) {
        let all = KeywordHighlightClass.allCases
        guard all.indices.contains(sender.tag) else { return }
        let cls = all[sender.tag]
        let choices = Self.choices(for: cls)
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        switch choices[sender.indexOfSelectedItem].choice {
        case .classDefault:
            write { $0[cls].color = nil }
        case .ansi(let index):
            write { $0[cls].color = .ansi(index) }
        case .custom:
            openColorPanel(target: .highlightClass(cls),
                           starting: TerminalKeywordHighlighter.resolvedColor(
                               for: cls, settings: store.terminalHighlighting, theme: theme))
        }
    }

    private func openColorPanel(target: ColorTarget, starting color: NSColor) {
        colorPanelTarget = target
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    /// The colour panel's action. Typed loosely because an `NSColorWell`
    /// carries a colour the same way, which is what lets a suite drive this
    /// exact entry point without putting the shared panel on screen.
    @objc private func colorPanelChanged(_ sender: AnyObject) {
        let picked = (sender as? NSColorPanel)?.color ?? (sender as? NSColorWell)?.color
        guard let target = colorPanelTarget, let picked, let hex = Self.hex(of: picked) else { return }
        switch target {
        case .highlightClass(let cls):
            write { $0[cls].color = .custom(hex) }
        case .ruleDraft:
            // The draft only: a rule's colour is saved with the rule.
            draft?.rule.color = .custom(hex)
            themeRules()
        }
    }

    @objc private func restoreDefaults() {
        // The master switch and the six classes. Custom rules are the
        // captain's own content and are kept.
        write { settings in
            settings.enabled = KeywordHighlightSettings.defaults.enabled
            for cls in KeywordHighlightClass.allCases { settings[cls] = KeywordHighlightClassSetting() }
        }
    }

    // MARK: Custom rules (T3)

    /// The rule being added or edited: its index in `rules` (`nil` for a new
    /// one) and the unsaved copy the editor changes.
    private struct RuleDraft {
        var index: Int?
        var rule: KeywordHighlightRule
    }

    private let rulesStack = NSStackView()
    private var addRuleButton: HelmButton?
    private var ruleRows: [SettingsRow] = []
    private var ruleHairlines: [NSView] = []
    private var ruleSwatches: [(view: NSView, color: KeywordHighlightColor)] = []
    private var ruleButtons: [HelmButton] = []
    private var draft: RuleDraft?
    private var editorKindTabs: HelmSegmentedTabs?
    private var editorField: HelmTextField?
    private var editorCaseSwitch: HelmToggle?
    private var editorColorPopUp: HelmPopUpButton?
    private var editorSwatch: NSView?
    private var editorError: NSTextField?

    /// How a delete is confirmed. GL-06's one irreversible-delete prompt in
    /// the app; a suite substitutes its own answer.
    var confirmRuleDeletion: (KeywordHighlightRule) -> Bool = { rule in
        DestructiveConfirm.confirm(
            message: "Delete this highlighting rule?",
            detail: "\u{201C}\(TerminalHighlightSettingsSections.title(of: rule))\u{201D} will no longer be coloured in any terminal. This cannot be undone.")
    }

    static func title(of rule: KeywordHighlightRule) -> String {
        rule.kind == .words ? rule.words.joined(separator: ", ") : rule.text
    }

    static func detail(of rule: KeywordHighlightRule) -> String {
        "\(rule.kind == .words ? "Words" : "Pattern") \u{00B7} "
            + (rule.caseSensitive ? "case-sensitive" : "not case-sensitive")
    }

    /// A rule's colour choices: the theme's twelve ANSI colours, then Custom.
    static let ruleChoices: [(title: String, choice: Choice)] =
        ansiNames.map { ($0.name, .ansi($0.index)) } + [("Custom\u{2026}", .custom)]

    private func buildRulesSection() -> SettingsSection {
        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 0
        rulesStack.translatesAutoresizingMaskIntoConstraints = false
        let add = HelmButton(title: "Add Rule", variant: .secondary, target: self, action: #selector(addRule))
        addRuleButton = add
        return SettingsSection(
            heading: "Custom rules", aside: add,
            group: SettingsGroup(custom: rulesStack, insets: NSEdgeInsets()),
            foot: "Up to \(KeywordHighlightRule.maximumCount) rules. Your rules are checked before the classes above, "
                + "so where both match the same text the rule\u{2019}s colour wins.")
    }

    /// Rebuilds the rule list and, while one is open, the editor below it.
    private func rebuildRules() {
        captureEditorText()
        editorField = nil
        editorSwatch = nil
        editorError = nil
        for view in rulesStack.arrangedSubviews {
            rulesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        ruleRows = []
        ruleHairlines = []
        ruleSwatches = []
        ruleButtons = []
        let rules = store.terminalHighlighting.rules
        var rows: [SettingsRow] = []
        for (index, rule) in rules.enumerated() {
            let swatch = makeSwatch()
            ruleSwatches.append((swatch, rule.color))
            let title = Self.title(of: rule)
            let edit = HelmButton(symbol: "pencil", target: self, action: #selector(editRule(_:)))
            edit.tag = index
            edit.setAccessibilityLabel("Edit rule \(title)")
            let delete = HelmButton(symbol: "trash", target: self, action: #selector(deleteRule(_:)))
            delete.tag = index
            delete.setAccessibilityLabel("Delete rule \(title)")
            ruleButtons += [edit, delete]
            let controls = NSStackView(views: [swatch, edit, delete])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = HelmMetrics.s2
            let row = SettingsRow(title: title, description: Self.detail(of: rule), control: controls)
            row.titleLabel.font = HelmType.code()
            rows.append(row)
        }
        if rows.isEmpty && draft == nil {
            rows.append(SettingsRow(
                title: "No rules yet",
                description: "Add words like deploy or OOM, or a pattern like \\bE\\d{4}\\b, to colour them in every terminal.",
                control: NSView()))
        }
        if draft != nil { rows += buildEditorRows() }

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = hairline(inset: row.separatorInset)
                rulesStack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: rulesStack.widthAnchor).isActive = true
            }
            rulesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rulesStack.widthAnchor).isActive = true
        }
        ruleRows = rows
        addRuleButton?.isEnabled = draft == nil && rules.count < KeywordHighlightRule.maximumCount
        themeRules()
    }

    private func buildEditorRows() -> [SettingsRow] {
        guard let draft else { return [] }
        let rule = draft.rule

        let tabs = HelmSegmentedTabs(items: [.init(id: KeywordHighlightRule.Kind.words.rawValue, title: "Words"),
                                             .init(id: KeywordHighlightRule.Kind.pattern.rawValue, title: "Pattern")],
                                     selected: rule.kind.rawValue)
        tabs.setAccessibilityLabel("Match words or a pattern")
        tabs.onSelect = { [weak self] id in
            guard let self, let kind = KeywordHighlightRule.Kind(rawValue: id) else { return }
            self.captureEditorText()
            self.draft?.rule.kind = kind
            self.rebuildRules()
        }
        editorKindTabs = tabs

        let field = HelmTextField(placeholder: rule.kind == .words ? "deploy, OOM, connection reset" : #"\bE\d{4}\b"#)
        field.stringValue = rule.text
        field.target = self
        field.action = #selector(saveRule)
        field.delegate = self
        field.setAccessibilityLabel(rule.kind == .words ? "Words to highlight" : "Pattern to highlight")
        field.widthAnchor.constraint(equalToConstant: HelmType.scaled(260)).isActive = true
        editorField = field

        let caseSwitch = HelmToggle()
        caseSwitch.isOn = rule.caseSensitive
        caseSwitch.setAccessibilityLabel("Case-sensitive")
        caseSwitch.onToggle = { [weak self, weak caseSwitch] in self?.draft?.rule.caseSensitive = caseSwitch?.isOn ?? false }
        editorCaseSwitch = caseSwitch

        let popUp = HelmPopUpButton()
        for item in Self.ruleChoices { popUp.addItem(withTitle: item.title) }
        let current: Choice = rule.color.isCustom ? .custom : .ansi(rule.color.ansiIndex ?? 5)
        popUp.selectItem(at: Self.ruleChoices.firstIndex { $0.choice == current } ?? 0)
        popUp.target = self
        popUp.action = #selector(ruleColorPicked(_:))
        popUp.setAccessibilityLabel("Rule colour")
        popUp.widthAnchor.constraint(equalToConstant: HelmType.scaled(150)).isActive = true
        editorColorPopUp = popUp
        let swatch = makeSwatch()
        editorSwatch = swatch
        let colorControls = NSStackView(views: [swatch, popUp])
        colorControls.orientation = .horizontal
        colorControls.alignment = .centerY
        colorControls.spacing = HelmMetrics.s2

        let cancel = HelmButton(title: "Cancel", variant: .secondary, target: self, action: #selector(cancelRule))
        let save = HelmButton(title: draft.index == nil ? "Add Rule" : "Save Rule", variant: .primary,
                              target: self, action: #selector(saveRule))
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = HelmMetrics.s2

        // The last row's own description doubles as the place a refused
        // save explains itself, so the reason sits beside Save.
        let footRow = SettingsRow(title: draft.index == nil ? "New rule" : "Edit rule",
                                  description: Self.editorHint, control: buttons)
        editorError = footRow.descriptionLabel

        return [
            SettingsRow(title: "Match", control: tabs, isSubRow: true),
            SettingsRow(title: rule.kind == .words ? "Words" : "Pattern",
                        description: rule.kind == .words
                            ? "Separate words with commas. Each is matched as a whole word."
                            : "A regular expression, checked when you save.",
                        control: field, isSubRow: true),
            SettingsRow(title: "Case-sensitive", control: caseSwitch, isSubRow: true),
            SettingsRow(title: "Colour", control: colorControls, isSubRow: true),
            footRow,
        ]
    }

    private func makeSwatch() -> NSView {
        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.layer?.borderWidth = 1
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 14),
            swatch.heightAnchor.constraint(equalToConstant: 14),
        ])
        return swatch
    }

    private func hairline(inset: CGFloat) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(line)
        NSLayoutConstraint.activate([
            host.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
            line.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            line.topAnchor.constraint(equalTo: host.topAnchor),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        ruleHairlines.append(line)
        return host
    }

    private func themeRules() {
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        for row in ruleRows { row.applyTheme(theme) }
        let hair = theme.isDaylight ? HelmTheme.nsColor(theme.daylightTokens.hairRow) : line.withAlphaComponent(0.5)
        for view in ruleHairlines { view.layer?.backgroundColor = hair.cgColor }
        for (view, color) in ruleSwatches {
            view.layer?.backgroundColor = TerminalKeywordHighlighter.resolvedColor(color, fallbackANSIIndex: 5, theme: theme).cgColor
            view.layer?.borderColor = line.cgColor
        }
        if let editorSwatch, let draft {
            editorSwatch.layer?.backgroundColor = TerminalKeywordHighlighter.resolvedColor(
                draft.rule.color, fallbackANSIIndex: 5, theme: theme).cgColor
            editorSwatch.layer?.borderColor = line.cgColor
        }
        editorKindTabs?.applyTheme(theme)
        editorField?.applyTheme(theme)
        editorCaseSwitch?.applyTheme(theme)
        if let editorError, editorError.stringValue != Self.editorHint {
            editorError.textColor = errorInk()
        }
    }

    static let editorHint = "Return saves, Esc cancels."

    /// The theme's red, made legible on the card it sits on.
    private func errorInk() -> NSColor {
        HelmContrast.legible(HelmTheme.nsColor(theme.ansiHex[1]), over: HelmTheme.nsColor(theme.chromeBackgroundHex))
    }

    /// The field's text into the draft, before anything rebuilds the editor.
    private func captureEditorText() {
        if let field = editorField { draft?.rule.text = field.stringValue }
    }

    @objc private func addRule() {
        guard store.terminalHighlighting.rules.count < KeywordHighlightRule.maximumCount else { return }
        draft = RuleDraft(index: nil, rule: KeywordHighlightRule())
        rebuildRules()
        editorField?.window?.makeFirstResponder(editorField)
    }

    @objc private func editRule(_ sender: HelmButton) {
        let rules = store.terminalHighlighting.rules
        guard rules.indices.contains(sender.tag) else { return }
        draft = RuleDraft(index: sender.tag, rule: rules[sender.tag])
        rebuildRules()
    }

    @objc private func deleteRule(_ sender: HelmButton) {
        let rules = store.terminalHighlighting.rules
        guard rules.indices.contains(sender.tag), confirmRuleDeletion(rules[sender.tag]) else { return }
        let id = rules[sender.tag].id
        // An editor open on another rule keeps pointing at it.
        if let open = draft?.index {
            draft?.index = open == sender.tag ? nil : (open > sender.tag ? open - 1 : open)
            if open == sender.tag { draft = nil }
        }
        write { $0.rules.removeAll { $0.id == id } }
    }

    /// Validates and saves the open rule. A rule that is not valid is
    /// refused here, with the reason shown in the editor, and nothing is
    /// written.
    @objc private func saveRule() {
        captureEditorText()
        guard let draft else { return }
        var rule = draft.rule
        rule.text = rule.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = rule.validationError {
            showEditorError(problem)
            return
        }
        let count = store.terminalHighlighting.rules.count
        if draft.index == nil && count >= KeywordHighlightRule.maximumCount {
            showEditorError("You already have \(KeywordHighlightRule.maximumCount) rules. Delete one to add another.")
            return
        }
        self.draft = nil
        write { settings in
            if let index = draft.index, settings.rules.indices.contains(index) {
                settings.rules[index] = rule
            } else {
                settings.rules.append(rule)
            }
        }
    }

    @objc private func cancelRule() {
        draft = nil
        rebuildRules()
    }

    private func showEditorError(_ message: String) {
        guard let editorError else { return }
        editorError.stringValue = message
        editorError.textColor = errorInk()
        NSAccessibility.post(element: editorError, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func ruleColorPicked(_ sender: HelmPopUpButton) {
        guard Self.ruleChoices.indices.contains(sender.indexOfSelectedItem) else { return }
        switch Self.ruleChoices[sender.indexOfSelectedItem].choice {
        case .ansi(let index):
            draft?.rule.color = .ansi(index)
            themeRules()
        case .custom:
            captureEditorText()
            openColorPanel(target: .ruleDraft, starting: TerminalKeywordHighlighter.resolvedColor(
                draft?.rule.color ?? .ansi(5), fallbackANSIIndex: 5, theme: theme))
        case .classDefault:
            break
        }
    }

    /// `rrggbb` in sRGB, or `nil` for a colour with no RGB form.
    static func hex(of color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02x%02x%02x", byte(srgb.redComponent), byte(srgb.greenComponent),
                      byte(srgb.blueComponent))
    }

    // MARK: Self-test hooks (GL-27)

    #if FM_SELFTESTS
    var debugMasterSwitch: HelmToggle { masterSwitch }
    var debugMasterRow: SettingsRow? { masterRow }
    func debugClassSwitch(_ cls: KeywordHighlightClass) -> HelmToggle? { classSwitches[cls] }
    func debugClassRow(_ cls: KeywordHighlightClass) -> SettingsRow? { classRows[cls] }
    func debugColorPopUp(_ cls: KeywordHighlightClass) -> HelmPopUpButton? { colorPopUps[cls] }
    func debugSwatchColor(_ cls: KeywordHighlightClass) -> NSColor? {
        swatches[cls]?.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }
    var debugRestoreButton: HelmButton? { restoreButton }
    var debugPreview: TerminalHighlightPreview { preview }
    /// Where the colour panel's own action enters, so a suite drives the same
    /// path a real pick does without showing the panel.
    func debugPickCustomColor(_ hex: String, for cls: KeywordHighlightClass) {
        colorPanelTarget = .highlightClass(cls)
        let well = NSColorWell()
        well.color = HelmTheme.nsColor(hex)
        colorPanelChanged(well)
    }
    var debugAddRuleButton: HelmButton? { addRuleButton }
    var debugRuleRows: [SettingsRow] { ruleRows }
    var debugRuleButtons: [HelmButton] { ruleButtons }
    var debugEditorField: HelmTextField? { editorField }
    var debugEditorKindTabs: HelmSegmentedTabs? { editorKindTabs }
    var debugEditorCaseSwitch: HelmToggle? { editorCaseSwitch }
    var debugEditorColorPopUp: HelmPopUpButton? { editorColorPopUp }
    var debugEditorMessage: String? { editorError?.stringValue }
    var debugEditorIsOpen: Bool { draft != nil }
    /// The custom colour pick for an open rule editor, through the same
    /// panel action a real pick reaches.
    func debugPickCustomRuleColor(_ hex: String) {
        colorPanelTarget = .ruleDraft
        let well = NSColorWell()
        well.color = HelmTheme.nsColor(hex)
        colorPanelChanged(well)
    }
    #endif
}

// MARK: - The rule editor's field

extension TerminalHighlightSettingsSections: NSTextFieldDelegate {
    /// Esc in the rule field cancels the edit. Return is the field's action
    /// (`saveRule`), which is the legitimate Return-only case gotcha (19)
    /// describes: this field submits a form, it is not a persisted value.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === editorField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelRule()
        return true
    }
}

// MARK: - Preview

/// A few lines of log, coloured by the same highlighter the terminals use,
/// on the terminal's own background and in its own ink.
///
/// Built from `TerminalKeywordHighlighter.highlights(forRow:)` rather than a
/// second colouring routine, so what the preview shows is what a terminal
/// draws. It is not a terminal: there is no program here to colour anything,
/// which is why every line is plain text.
final class TerminalHighlightPreview: NSView {

    static let sampleLines = [
        "10:15:03 ERROR [worker-3] job failed: connection refused",
        "10:15:04 WARN  [cache] retrying shard 12 after timeout",
        "10:15:05 INFO  [net] 10.0.12.7 up, mac 3c:22:fb:91:0a:7e",
        "10:15:05 DEBUG [db] query took 41ms, rows=118",
        "deploy OK, migrations done, all checks passed",
    ]

    /// One label per sample line, each clipping rather than wrapping, so a
    /// narrow page cuts a line short instead of wrapping it into the next
    /// one (and pushing the last line out of the box).
    private let lines = NSStackView()
    private var lineLabels: [NSTextField] = []
    private(set) var renderedText = NSAttributedString()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rControl
        layer?.masksToBounds = true
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.translatesAutoresizingMaskIntoConstraints = false
        for _ in Self.sampleLines {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byClipping
            label.isSelectable = false
            // Gotcha (13): the preview must never become a floor on the
            // window's width, so a narrow page clips it rather than widening.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lines.addArrangedSubview(label)
            lineLabels.append(label)
        }
        lines.setAccessibilityLabel("Keyword highlighting preview")
        addSubview(lines)
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s4),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func render(settings: KeywordHighlightSettings, theme: HelmTheme) {
        let background = TerminalKeywordHighlighter.terminalBackground(theme)
        let ink = HelmTheme.nsColor(theme.terminalCard?.inkHex ?? theme.foregroundHex)
        layer?.backgroundColor = background.cgColor
        // A preview-only highlighter: the same matching and colours as the
        // shared one, for exactly the settings and theme being shown.
        let highlighter = TerminalKeywordHighlighter(settings: settings, theme: theme)
        let text = NSMutableAttributedString()
        for (index, line) in Self.sampleLines.enumerated() {
            let piece = NSMutableAttributedString(string: line, attributes: [
                .font: HelmType.code(),
                .foregroundColor: ink,
            ])
            if highlighter.highlightsEnabled {
                for run in highlighter.highlights(forRow: Array(line.utf16)) {
                    piece.addAttribute(.foregroundColor, value: run.color,
                                       range: NSRange(location: run.range.lowerBound, length: run.range.count))
                }
            }
            if lineLabels.indices.contains(index) { lineLabels[index].attributedStringValue = piece }
            text.append(piece)
            if index < Self.sampleLines.count - 1 { text.append(NSAttributedString(string: "\n")) }
        }
        renderedText = text
    }
}
