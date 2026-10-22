// Grand Line - native macOS app.
//
// `WorkspaceDetailView` - one record's details, as the sidebar shell's
// inspector shows them: the prototype's inspector shape.
//
// A tile, a kicker, the record's name and a line about it; then a label and
// value grid; then any section a record has more than one line of (a host's
// port forwards, a snippet's command); then the record's actions, every one
// of them, as buttons. It is the inspector body for Hosts' three tables, so
// it is one view rather than three.
//
// It shows only what the record really holds. A field with nothing to say is
// left out, never drawn as an empty value, and every action runs the same
// closure the table row's own action runs.

import AppKit

struct WorkspaceDetail {
    struct Field {
        let label: String
        let value: String
        let isCode: Bool

        init(_ label: String, _ value: String, isCode: Bool = false) {
            self.label = label
            self.value = value
            self.isCode = isCode
        }
    }

    struct Section {
        let title: String
        let lines: [String]
        let isCode: Bool

        init(_ title: String, _ lines: [String], isCode: Bool = false) {
            self.title = title
            self.lines = lines
            self.isCode = isCode
        }
    }

    struct Action {
        enum Role { case primary, secondary, destructive }
        let title: String
        let symbol: String?
        let role: Role
        let run: () -> Void

        init(_ title: String, symbol: String? = nil, role: Role = .secondary, run: @escaping () -> Void) {
            self.title = title
            self.symbol = symbol
            self.role = role
            self.run = run
        }
    }

    var symbol: String
    var tint: HelmTint = .accent
    /// A colour the captain chose (a saved host's own accent).
    var tintHex: String?
    var kicker: String
    var title: String
    var subtitle: String
    var fields: [Field] = []
    var sections: [Section] = []
    var actions: [Action] = []
}

final class WorkspaceDetailView: NSView {

    /// The inspector's fixed width, less its insets: what a wrapping value
    /// may use. Derived from widths this view does not decide, never from its
    /// own resolved frame (gotcha (22)).
    static let labelColumnWidth: CGFloat = 92
    static var contentWidth: CGFloat { WorkspaceInspectorController.width - 2 * HelmMetrics.s4 - 1 }
    static var valueWidth: CGFloat { contentWidth - labelColumnWidth - HelmMetrics.s3 }

    private let stack = NSStackView()
    private let tile = IconTileView(size: 34, cornerRadius: HelmMetrics.rRow)
    private let kicker = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    /// The label and value rows. A stack of rows rather than an `NSGridView`:
    /// removing a grid row leaves its views in the grid (measured - a new
    /// selection drew over the last one), and a removed arranged subview goes
    /// for real.
    private let fieldsStack = NSStackView()
    private let sectionsStack = NSStackView()
    private let actionsStack = NSStackView()
    private var detail: WorkspaceDetail?
    private var actionRuns: [() -> Void] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: WorkspaceInspectorController.width, height: 400))
        build()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    private func build() {
        for label in [titleLabel, subtitleLabel] {
            label.preferredMaxLayoutWidth = Self.contentWidth - 34 - HelmMetrics.s3
            label.maximumNumberOfLines = 0
        }
        kicker.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [kicker, titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s0
        tile.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [tile, text])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = HelmMetrics.s3

        fieldsStack.orientation = .vertical
        fieldsStack.alignment = .leading
        fieldsStack.spacing = HelmMetrics.s2
        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = HelmMetrics.s4
        actionsStack.orientation = .vertical
        actionsStack.alignment = .leading
        actionsStack.spacing = HelmMetrics.s2

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.edgeInsets = NSEdgeInsets(top: HelmMetrics.s4, left: HelmMetrics.s4,
                                        bottom: HelmMetrics.s5, right: HelmMetrics.s4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, fieldsStack, sectionsStack, actionsStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionsStack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            header.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            fieldsStack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
    }

    func show(_ detail: WorkspaceDetail) {
        self.detail = detail
        tile.configure(symbol: detail.symbol, tint: detail.tint, pointSize: HelmType.scaled(15))
        if let hex = detail.tintHex { tile.overrideFill(hex: hex) }
        kicker.isHidden = detail.kicker.isEmpty
        titleLabel.stringValue = detail.title
        subtitleLabel.stringValue = detail.subtitle
        subtitleLabel.isHidden = detail.subtitle.isEmpty

        fieldsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for field in detail.fields {
            let label = NSTextField(labelWithString: field.label)
            let value = NSTextField(wrappingLabelWithString: field.value)
            value.preferredMaxLayoutWidth = Self.valueWidth
            value.isSelectable = true
            label.identifier = NSUserInterfaceItemIdentifier("detail.label")
            value.identifier = NSUserInterfaceItemIdentifier(field.isCode ? "detail.code" : "detail.value")
            let row = NSStackView(views: [label, value])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = HelmMetrics.s3
            // The label column keeps its width and the value wraps beside it -
            // gotcha (2)'s rule, for rows.
            label.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fieldsStack.addArrangedSubview(row)
        }
        fieldsStack.isHidden = detail.fields.isEmpty

        sectionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for section in detail.sections where !section.lines.isEmpty {
            let title = NSTextField(labelWithString: section.title)
            title.identifier = NSUserInterfaceItemIdentifier("detail.sectionTitle")
            let lines = NSStackView()
            lines.orientation = .vertical
            lines.alignment = .leading
            lines.spacing = HelmMetrics.s1
            for line in section.lines {
                let label = NSTextField(wrappingLabelWithString: line)
                label.preferredMaxLayoutWidth = Self.contentWidth
                label.isSelectable = true
                label.identifier = NSUserInterfaceItemIdentifier(section.isCode ? "detail.code" : "detail.value")
                lines.addArrangedSubview(label)
            }
            let block = NSStackView(views: [title, lines])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = HelmMetrics.s1
            sectionsStack.addArrangedSubview(block)
        }
        sectionsStack.isHidden = sectionsStack.arrangedSubviews.isEmpty

        actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionRuns = detail.actions.map(\.run)
        for (index, action) in detail.actions.enumerated() {
            let variant: HelmButton.Variant
            switch action.role {
            case .primary: variant = .primary
            case .secondary: variant = .secondary
            case .destructive: variant = .destructive
            }
            let button = HelmButton(title: action.title, variant: variant, size: .small, symbol: action.symbol,
                                    target: self, action: #selector(actionClicked(_:)))
            button.tag = index
            actionsStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: actionsStack.widthAnchor).isActive = true
        }
        actionsStack.isHidden = detail.actions.isEmpty
        applyTheme(theme)
        setAccessibilityElement(false)
        needsLayout = true
    }

    @objc private func actionClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < actionRuns.count else { return }
        actionRuns[sender.tag]()
    }

    private func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        tile.applyTheme(theme)
        if let detail {
            kicker.attributedStringValue = NSAttributedString(
                string: detail.kicker.uppercased(), attributes: HelmType.kickerAttributes(color: muted))
        }
        titleLabel.font = HelmType.cardTitle()
        titleLabel.textColor = ink
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.textColor = muted
        func paint(_ view: NSView) {
            if let label = view as? NSTextField {
                switch label.identifier?.rawValue {
                case "detail.label":
                    label.font = HelmType.caption()
                    label.textColor = muted
                case "detail.code":
                    label.font = HelmType.code()
                    label.textColor = ink
                case "detail.value":
                    label.font = HelmType.caption()
                    label.textColor = ink
                case "detail.sectionTitle":
                    label.font = .systemFont(ofSize: HelmType.scaled(11.5), weight: .semibold)
                    label.textColor = muted
                default:
                    break
                }
            }
            view.subviews.forEach(paint)
        }
        paint(fieldsStack)
        paint(sectionsStack)
    }

    #if FM_SELFTESTS
    var debugDetail: WorkspaceDetail? { detail }
    var debugActionButtons: [HelmButton] { actionsStack.arrangedSubviews.compactMap { $0 as? HelmButton } }
    var debugFieldLabels: [String] {
        fieldsStack.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.first as? NSTextField }
            .map(\.stringValue)
    }
    #endif
}
