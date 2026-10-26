// Grand Line - native macOS app.
//
// The sidebar layout's right column on the Code page: Run configuration,
// Script checks and Editor preferences.
//
// ## Nothing here is a claim the code does not back
//
// The captain's concept drew these cards with sample values ("Isolated
// process", "Network Disabled", "SF Mono · 14 pt"). Every value here is read
// from the thing it describes instead:
//
//   - Run configuration restates `CodeRunner` and `CodeSandbox` - the
//     interpreter the run would use (from the tool inventory), the
//     `sandbox-exec` confinement, the `(deny network*)` rule, the scratch
//     directory that is deleted after the run, and the wall clock. Each is
//     asserted against those types by `CodePreviewWorkbenchSelfTest`, so a
//     change to the runner that makes a sentence false fails a test.
//   - Script checks runs a real parse-only check through the same sandbox
//     (`CodeRunner.checkSyntax`) and counts the snippet's own lines. A
//     language with no parse-only mode says so rather than passing.
//   - Editor preferences reads the font Monaco actually resolved, its line
//     numbers and the page's own word-wrap and autosave behaviour.
//
// The model is pure, so all of that is asserted without a window; the cards
// only draw it.

import AppKit

// MARK: - The model (pure)

/// What the Script checks card counts in a snippet.
struct CodePreviewScriptStats: Equatable {
    var codeLines = 0
    var blankLines = 0
    var commentLines = 0

    /// The line comment a language starts a whole-line comment with, if it
    /// has one this card can count honestly. A language with none (Markdown,
    /// XML, plain text) counts no comments rather than guessing.
    static func lineCommentPrefixes(for languageID: String) -> [String] {
        switch languageID {
        case "shell", "python", "yaml", "dockerfile": return ["#"]
        case "ini": return ["#", ";"]
        case "hcl": return ["#", "//"]
        case "javascript", "typescript", "swift", "go", "rust", "json": return ["//"]
        case "sql": return ["--"]
        default: return []
        }
    }

    /// Counts lines the way an editor numbers them: a trailing newline ends
    /// the last line rather than starting a new one.
    static func compute(_ content: String, languageID: String) -> CodePreviewScriptStats {
        var stats = CodePreviewScriptStats()
        guard !content.isEmpty else { return stats }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if content.hasSuffix("\n") { lines.removeLast() }
        let prefixes = lineCommentPrefixes(for: languageID)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                stats.blankLines += 1
            } else if prefixes.contains(where: { trimmed.hasPrefix($0) }) {
                stats.commentLines += 1
            } else {
                stats.codeLines += 1
            }
        }
        return stats
    }

    var summary: String {
        var parts = [Self.plural(codeLines, "code line")]
        parts.append(Self.plural(blankLines, "blank line"))
        if commentLines > 0 { parts.append(Self.plural(commentLines, "comment")) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

enum CodePreviewInspectorModel {

    struct Row: Equatable {
        let label: String
        let value: String
    }

    enum CheckState: Equatable {
        case passed, failed, info, pending
    }

    struct Check: Equatable {
        let state: CheckState
        let text: String
    }

    /// Everything the three cards need, gathered by the controller from live
    /// state. A value type, so a suite can build one by hand.
    struct Input {
        var language: CodePreviewLanguage
        var content: String
        /// `nil` until the tool inventory has been probed (GL-14: not yet
        /// known is not "not installed").
        var runnerKnown: Bool
        var runner: CodeToolPresence?
        var sandboxAvailable: Bool
        /// `nil` while a check is in flight or has not run yet.
        var syntax: CodeSyntaxCheck?
        var lineNumbers: Bool?
        var wordWrap: Bool
        var fontFamily: String?
        var fontSize: CGFloat
    }

    static func runnerDescription(_ presence: CodeToolPresence) -> String {
        presence.version.map { "\(presence.tool.displayName) \($0)" } ?? presence.tool.displayName
    }

    // MARK: Run configuration

    static func runConfiguration(_ input: Input) -> [Row] {
        let runnable = CodeRunCatalog.runRecipe(for: input.language.id) != nil
        let interpreter: String
        if !runnable {
            interpreter = "\(input.language.displayName) \u{00B7} not runnable"
        } else if !input.runnerKnown {
            interpreter = "\(input.language.displayName) \u{00B7} checking\u{2026}"
        } else if let runner = input.runner {
            interpreter = "\(input.language.displayName) \u{00B7} \(runner.tool.displayName)"
        } else {
            interpreter = "\(input.language.displayName) \u{00B7} no interpreter"
        }
        return [
            Row(label: "Language", value: interpreter),
            Row(label: "Execution", value: input.sandboxAvailable ? "Sandboxed process" : "Refused - no sandbox"),
            Row(label: "Network", value: "Blocked"),
            Row(label: "Working directory", value: "Temporary"),
            Row(label: "Time limit", value: "\(Int(CodeRunner.wallClock)) s"),
        ]
    }

    /// The note under Run configuration, in the order `CodeSandbox.profile`
    /// states the rules.
    static func safetyNote(sandboxAvailable: Bool) -> (title: String, body: String) {
        guard sandboxAvailable else {
            return ("Runs are refused",
                    "\(CodeSandbox.sandboxExecPath) is not on this Mac, so nothing is run unconfined.")
        }
        return ("Sandboxed run",
                "Runs under sandbox-exec in a new temporary folder that is deleted afterwards. "
                + "The network, writes outside that folder, your home folder and the clipboard are blocked.")
    }

    // MARK: Script checks

    static func checks(_ input: Input) -> [Check] {
        var checks: [Check] = []
        let runnable = CodeRunCatalog.runRecipe(for: input.language.id) != nil
        if !runnable {
            checks.append(Check(state: .info, text: "\(input.language.displayName) is not a language this page runs"))
        } else if !input.runnerKnown {
            checks.append(Check(state: .pending, text: "Looking for an interpreter\u{2026}"))
        } else if let runner = input.runner {
            checks.append(Check(state: .passed, text: "Interpreter detected: \(runnerDescription(runner))"))
        } else {
            checks.append(Check(state: .failed, text: CodeRunner.noRunnerMessage(for: input.language.id)))
        }

        if runnable, input.runner != nil, !input.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch input.syntax {
            case .none:
                checks.append(Check(state: .pending, text: "Checking syntax\u{2026}"))
            case .passed(let checker)?:
                checks.append(Check(state: .passed, text: "No syntax errors (\(checker))"))
            case .failed(_, let message)?:
                checks.append(Check(state: .failed, text: "Syntax error: \(message)"))
            case .unavailable(let reason)?:
                checks.append(Check(state: .info, text: reason))
            case .couldNotCheck(let reason)?:
                checks.append(Check(state: .info, text: reason))
            }
        }

        let stats = CodePreviewScriptStats.compute(input.content, languageID: input.language.id)
        checks.append(Check(state: .info, text: stats.summary))
        return checks
    }

    /// "2/2": the checks that can pass or fail, and how many passed. An info
    /// row is neither, so it counts toward nothing.
    static func checkTally(_ checks: [Check]) -> String {
        let decided = checks.filter { $0.state == .passed || $0.state == .failed }
        guard !decided.isEmpty else { return "" }
        return "\(decided.filter { $0.state == .passed }.count)/\(decided.count)"
    }

    // MARK: Editor preferences

    /// The first family in Monaco's resolved font stack, which is the one the
    /// editor draws with on a Mac (every one has Menlo).
    static func primaryFont(_ family: String?) -> String? {
        guard let family else { return nil }
        let first = family.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return (first?.isEmpty ?? true) ? nil : first
    }

    static func editorPreferences(_ input: Input) -> [Row] {
        let size = input.fontSize.rounded() == input.fontSize
            ? "\(Int(input.fontSize)) pt" : String(format: "%.1f pt", input.fontSize)
        let font = primaryFont(input.fontFamily).map { "\($0) \u{00B7} \(size)" } ?? size
        return [
            Row(label: "Line numbers", value: input.lineNumbers.map { $0 ? "On" : "Off" } ?? "\u{2026}"),
            Row(label: "Word wrap", value: input.wordWrap ? "On" : "Off"),
            Row(label: "Font", value: font),
            Row(label: "Autosave", value: "On \u{00B7} 0.5 s"),
        ]
    }
}

// MARK: - The cards

/// The page's one card surface in the sidebar layout - `HelmCard`'s own
/// recipe through `applyCardSurface`, on a plain view the page lays out by
/// hand. Every card on the Code page is one of these.
class CodePreviewCardSurface: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) {
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: HelmMetrics.rCard,
                                  daylightRadius: HelmMetrics.dSurface)
    }
}

/// A titled inspector card: a title, an optional trailing tally, and a body
/// of rows.
final class CodePreviewInspectorCard: CodePreviewCardSurface {

    /// The card's inner width, known up front: the column is a fixed width,
    /// so a wrapping row's `preferredMaxLayoutWidth` is measured from that
    /// rather than from its own resolved width (gotcha (22)).
    static let innerWidth: CGFloat = CodePreviewWorkbenchMetrics.inspectorWidth - 2 * HelmMetrics.s3

    private let titleLabel = NSTextField(labelWithString: "")
    private let tallyLabel = NSTextField(labelWithString: "")
    let body = NSStackView()
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var rows: [CodePreviewInspectorModel.Row] = []
    private var checks: [CodePreviewInspectorModel.Check] = []
    private var note: (title: String, body: String)?

    init(title: String) {
        super.init()
        titleLabel.stringValue = title
        titleLabel.font = HelmType.rowTitle()
        tallyLabel.font = HelmType.captionSmall()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        for label in [titleLabel, tallyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        let inset = HelmMetrics.s3
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            tallyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            tallyLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            tallyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: HelmMetrics.s2),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: HelmMetrics.s2),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setRows(_ rows: [CodePreviewInspectorModel.Row], note: (title: String, body: String)? = nil) {
        guard rows != self.rows || note?.body != self.note?.body || note?.title != self.note?.title else { return }
        self.rows = rows
        self.note = note
        rebuild()
    }

    func setChecks(_ checks: [CodePreviewInspectorModel.Check]) {
        guard checks != self.checks else { return }
        self.checks = checks
        tallyLabel.stringValue = CodePreviewInspectorModel.checkTally(checks)
        rebuild()
    }

    private func rebuild() {
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            let view = CodePreviewInspectorRow(row: row, separated: index < rows.count - 1)
            body.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        if let note {
            let box = CodePreviewInspectorNote(title: note.title, body: note.body)
            body.setCustomSpacing(HelmMetrics.s2, after: body.arrangedSubviews.last ?? box)
            body.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        for check in checks {
            let view = CodePreviewInspectorCheckRow(check: check)
            body.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        applyTheme(theme)
    }

    override func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        super.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        tallyLabel.textColor = HelmTheme.mutedInk(theme)
        for view in body.arrangedSubviews {
            (view as? CodePreviewInspectorRow)?.applyTheme(theme)
            (view as? CodePreviewInspectorCheckRow)?.applyTheme(theme)
            (view as? CodePreviewInspectorNote)?.applyTheme(theme)
        }
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugTally: String { tallyLabel.stringValue }
    var debugRowTexts: [String] {
        body.arrangedSubviews.compactMap { view in
            if let row = view as? CodePreviewInspectorRow { return row.debugText }
            if let check = view as? CodePreviewInspectorCheckRow { return check.debugText }
            if let note = view as? CodePreviewInspectorNote { return note.debugText }
            return nil
        }
    }
    #endif
}

/// "Label ............ Value", with a hairline under it.
final class CodePreviewInspectorRow: NSView {
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let separator = NSView()

    init(row: CodePreviewInspectorModel.Row, separated: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = row.label
        value.stringValue = row.value
        value.alignment = .right
        value.lineBreakMode = .byTruncatingMiddle
        value.toolTip = row.value
        label.lineBreakMode = .byTruncatingTail
        for view in [label, value, separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        separator.wantsLayer = true
        separator.isHidden = !separated
        // Gotcha (5): the label keeps its words, the value is what gives.
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(row.label): \(row.value)")
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: HelmMetrics.s2),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) {
        label.font = HelmType.captionSmall()
        value.font = .systemFont(ofSize: HelmType.captionSmall().pointSize, weight: .semibold)
        label.textColor = HelmTheme.mutedInk(theme)
        value.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        separator.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(HelmCard.dividerAlpha).cgColor
    }

    #if FM_SELFTESTS
    var debugText: String { "\(label.stringValue): \(value.stringValue)" }
    #endif
}

/// One Script checks line: a state glyph and a sentence that wraps.
final class CodePreviewInspectorCheckRow: NSView {
    private let glyph = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    let check: CodePreviewInspectorModel.Check

    init(check: CodePreviewInspectorModel.Check) {
        self.check = check
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        text.stringValue = check.text
        text.maximumNumberOfLines = 3
        text.lineBreakMode = .byWordWrapping
        // Gotcha (22): the column is a fixed width, so the wrap width is that
        // known width less the glyph column, never this label's own.
        text.preferredMaxLayoutWidth = CodePreviewInspectorCard.innerWidth - 22
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.image = HelmSymbol.image(Self.symbol(check.state), pointSize: 11, weight: .bold)
        glyph.imageScaling = .scaleProportionallyDown
        for view in [glyph, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(Self.spoken(check.state)): \(check.text)")
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            glyph.heightAnchor.constraint(equalToConstant: 14),
            glyph.topAnchor.constraint(equalTo: text.topAnchor, constant: 1),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: HelmMetrics.s2),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func symbol(_ state: CodePreviewInspectorModel.CheckState) -> String {
        switch state {
        case .passed: return "checkmark"
        case .failed: return "xmark"
        case .info: return "info.circle"
        case .pending: return "clock"
        }
    }

    static func spoken(_ state: CodePreviewInspectorModel.CheckState) -> String {
        switch state {
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .info: return "Note"
        case .pending: return "Checking"
        }
    }

    static func tint(_ state: CodePreviewInspectorModel.CheckState) -> HelmTint {
        switch state {
        case .passed: return .good
        case .failed: return .critical
        case .info: return .info
        case .pending: return .neutral
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        text.font = HelmType.captionSmall()
        let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
        text.textColor = HelmContrast.legibleOn(fill: card, preferring: HelmTheme.mutedInk(theme))
        // A glyph is a non-text mark, but it carries the verdict on its own,
        // so it gets the text treatment rather than the raw hue.
        glyph.contentTintColor = HelmContrast.legibleTintedText(
            tintHex: Self.tint(check.state).hex(in: theme), over: card, theme: theme)
    }

    #if FM_SELFTESTS
    var debugText: String { "\(Self.spoken(check.state)): \(text.stringValue)" }
    var debugGlyphTint: NSColor? { glyph.contentTintColor }
    #endif
}

/// The boxed note under Run configuration.
final class CodePreviewInspectorNote: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let glyph = NSImageView()

    init(title: String, body: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        bodyLabel.preferredMaxLayoutWidth = CodePreviewInspectorCard.innerWidth - 2 * HelmMetrics.s3
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.image = HelmSymbol.image("checkmark.shield", pointSize: 11, weight: .semibold)
        for view in [glyph, titleLabel, bodyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(title). \(body)")
        let inset = HelmMetrics.s3
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyph.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: HelmMetrics.s1 + 2),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset - 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: HelmMetrics.s1),
            bodyLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) {
        let well = HelmField.fill(theme)
        layer?.backgroundColor = well.cgColor
        layer?.cornerRadius = HelmMetrics.rControl + 2
        layer?.borderWidth = 1
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.dividerAlpha).cgColor
        titleLabel.font = .systemFont(ofSize: HelmType.caption().pointSize, weight: .semibold)
        titleLabel.textColor = HelmContrast.legibleOn(fill: well, preferring: HelmTheme.nsColor(theme.chromeInkHex))
        bodyLabel.font = HelmType.captionSmall()
        bodyLabel.textColor = HelmContrast.legibleOn(fill: well, preferring: HelmTheme.mutedInk(theme))
        glyph.contentTintColor = HelmContrast.legibleTintedText(
            tintHex: HelmTint.good.hex(in: theme), over: well, theme: theme)
    }

    #if FM_SELFTESTS
    var debugText: String { "\(titleLabel.stringValue): \(bodyLabel.stringValue)" }
    #endif
}
