// Grand Line - native macOS app.
//
// The Code page's sidebar-layout presentation: the captain's reviewed
// concept ("Workbench > Code"), drawn in this app's own cards and tokens.
//
//     ┌ Snippets ───┐ ┌ toolbar card ─────────────────────────────────────┐
//     │ filter      │ └───────────────────────────────────────────────────┘
//     │ rows        │ ┌ editor card ─────────────────────┐ ┌ Run config ┐
//     │ sync line   │ │ tabs                              │ │            │
//     └─────────────┘ │ file name  folder        ⤢  •••  │ ├ Checks ────┤
//     ┌ Quick ──────┐ │ code                              │ │            │
//     │ New snippet │ │                                   │ ├ Editor ────┤
//     │ Import file │ │ Run results dock                  │ │            │
//     └─────────────┘ └───────────────────────────────────┘ └────────────┘
//     Ln 4, Col 14   Shell   UTF-8   Spaces: 2                 sync state
//
// ## Why a separate view, and why only here
//
// The page builds this presentation as part of loading
// (`buildSidebarPresentation`). The controller
// keeps every piece of state and every action - which snippet is open, what a
// run printed, what Run means - and hands this view the existing editor
// surface, snippet list, tab strip and status bar to place. So the two
// layouts share one implementation of everything except geometry.
//
// ## The window is never this page's to resize
//
// Every constraint that says "fit the content" here sits below
// `NSLayoutPriorityWindowSizeStayPut` (gotcha (13)): the column widths at
// `contentTie`, and the toolbar and dock rows' trailing edges as inequalities
// at the same band. A narrow window clips a row's tail rather than growing.

import AppKit

/// The concept's measurements, in one place so the suite can assert them.
enum CodePreviewWorkbenchMetrics {
    /// The gap between cards and around the page: the concept's 12px.
    static let gap: CGFloat = HelmMetrics.s3
    /// The snippet column, and its narrower form under the inspector breakpoint.
    static let snippetColumnWidth: CGFloat = 226
    static let narrowSnippetColumnWidth: CGFloat = 200
    static let inspectorWidth: CGFloat = 240
    /// The page width below which the right column hides and the snippet
    /// column narrows - the concept's `@media (max-width: 1100px)`, measured
    /// on the page rather than the window, since the app's own sidebar takes
    /// part of the window.
    static let inspectorBreakpoint: CGFloat = 1040
    static let toolbarHeight: CGFloat = 50
    static let tabRowHeight: CGFloat = 40
    static let titleRowHeight: CGFloat = 44
    static let statusBarHeight: CGFloat = 26
    /// Room above the first line of code, and the current-line bar's width.
    static let codeTopPadding: CGFloat = 12

    /// Whether the right column shows at `pageWidth`.
    static func showsInspector(pageWidth: CGFloat) -> Bool { pageWidth >= inspectorBreakpoint }

    static func snippetColumnWidth(pageWidth: CGFloat) -> CGFloat {
        showsInspector(pageWidth: pageWidth) ? snippetColumnWidth : narrowSnippetColumnWidth
    }
}

/// A thin vertical rule between toolbar groups.
final class CodePreviewToolbarSeparator: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
    }
}

/// The toolbar card's status line: a dot and a short sentence ("Ready to
/// run", "Running…", the last result).
final class CodePreviewRunStatus: NSView {
    private let dot = HelmSignalDot()
    private let label = NSTextField(labelWithString: "")
    private var tint: HelmTint = .neutral

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        // The one thing in the toolbar allowed to shrink.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(dot)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: HelmMetrics.s1 + 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: HelmPageToolbar.iconButtonSide),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// At a narrow window the sentence is what gives way to the tools, and a
    /// dot with no words beside it says nothing - so below a readable width
    /// both go, and the dock's own chip carries the run's state.
    static let minimumReadableWidth: CGFloat = 64

    override func layout() {
        super.layout()
        let readable = bounds.width >= Self.minimumReadableWidth
        dot.isHidden = !readable
        label.isHidden = !readable
    }

    func set(_ status: CodePreviewWorkbenchStatus.Line, theme: HelmTheme) {
        tint = status.tint
        label.stringValue = status.text
        toolTip = status.text
        setAccessibilityLabel("Run status: \(status.text)")
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        dot.configure(tint: tint, theme: theme)
        label.font = HelmType.captionSmall()
        label.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugText: String { label.stringValue }
    var debugTint: HelmTint { tint }
    #endif
}

/// The toolbar card's status sentence, as a pure function of what the page
/// knows - so every wording is asserted without a window.
enum CodePreviewWorkbenchStatus {
    struct Line: Equatable {
        let text: String
        let tint: HelmTint
    }

    static func line(pane: CodeRunPaneState,
                     runnerKnown: Bool,
                     hasRunner: Bool,
                     runnable: Bool,
                     hasContent: Bool,
                     sandboxAvailable: Bool,
                     languageName: String) -> Line {
        switch pane {
        case .running:
            return Line(text: "Running\u{2026}", tint: .info)
        case .finished(let outcome):
            let elapsed = CodeRunOutputPane.seconds(outcome.duration)
            switch outcome.kind {
            case .ok: return Line(text: "Last run passed \u{00B7} \(elapsed)", tint: .good)
            case .failed: return Line(text: "Last run failed \u{00B7} exit \(outcome.status)", tint: .critical)
            case .timedOut: return Line(text: "Last run timed out", tint: .warn)
            case .cancelled: return Line(text: "Last run stopped", tint: .neutral)
            case .launchFailed: return Line(text: "Last run did not start", tint: .warn)
            case .sandboxUnavailable: return Line(text: "Runs are refused here", tint: .critical)
            }
        case .idle:
            break
        }
        if !sandboxAvailable { return Line(text: "Runs are refused here", tint: .critical) }
        if !runnable { return Line(text: "\(languageName) does not run", tint: .neutral) }
        if !runnerKnown { return Line(text: "Looking for an interpreter\u{2026}", tint: .neutral) }
        if !hasRunner { return Line(text: "No interpreter installed", tint: .warn) }
        if !hasContent { return Line(text: "Nothing to run yet", tint: .neutral) }
        return Line(text: "Ready to run", tint: .good)
    }
}

/// The editor card's title row: the snippet's file name, the folder it lives
/// in, and the expand and more buttons.
final class CodePreviewEditorTitleRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let actions = NSStackView()

    init(trailing: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.lineBreakMode = .byTruncatingHead
        nameLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(260), for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.orientation = .horizontal
        actions.spacing = HelmMetrics.s1
        actions.alignment = .centerY
        for view in trailing { actions.addArrangedSubview(view) }
        for view in [nameLabel, pathLabel, actions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        nameLabel.setAccessibilityLabel("Snippet")
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: HelmMetrics.s2),
            pathLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: HelmMetrics.s2),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s3),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: CodePreviewWorkbenchMetrics.titleRowHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func set(name: String, folder: String) {
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        pathLabel.stringValue = folder
        pathLabel.toolTip = folder
    }

    func applyTheme(_ theme: HelmTheme) {
        nameLabel.font = HelmType.rowTitle()
        nameLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        pathLabel.font = HelmType.captionSmall()
        pathLabel.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugName: String { nameLabel.stringValue }
    var debugFolder: String { pathLabel.stringValue }
    #endif
}

/// A full-width Quick actions row: glyph, title and, when the action has
/// one, its shortcut at the trailing edge - a bordered list entry, the way
/// the reviewed concept draws them.
///
/// A `HoverHighlightView` rather than a `HelmButton`: a button centres its
/// title and glyph as one group, and this is a leading-aligned row with a
/// trailing hint. The row still announces as a button, takes keyboard focus
/// and draws its focus ring (GL-16), all from `HoverHighlightView`.
final class CodePreviewQuickActionButton: HoverHighlightView {
    static let height: CGFloat = 32

    let title: String
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let action: () -> Void

    init(title: String, symbol: String, shortcut: String?, tooltip: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = HelmMetrics.rControl + 2
        toolTip = tooltip
        glyph.image = HelmSymbol.image(symbol, pointSize: 12, weight: .semibold)
        glyph.imageScaling = .scaleProportionallyDown
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutLabel.stringValue = shortcut ?? ""
        shortcutLabel.isHidden = shortcut == nil
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [glyph, titleLabel, shortcutLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: HelmMetrics.s2 + 2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: HelmMetrics.s2),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s3),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        accessibilityRoleOverride = .button
        accessibilityLabelOverride = shortcut.map { "\(title), \($0)" } ?? title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { action() }

    func applyTheme(_ theme: HelmTheme) {
        let fill = HelmField.fill(theme)
        normalColor = fill
        hoverColor = HelmFlatList.rowHoverColor(theme, over: fill)
        layer?.borderWidth = 1
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        let ink = HelmContrast.legibleOn(fill: fill, preferring: HelmTheme.nsColor(theme.chromeInkHex))
        titleLabel.font = HelmType.caption()
        titleLabel.textColor = ink
        glyph.contentTintColor = ink
        shortcutLabel.font = HelmType.captionSmall()
        shortcutLabel.textColor = HelmContrast.legibleOn(fill: fill, preferring: HelmTheme.mutedInk(theme))
    }

    #if FM_SELFTESTS
    var debugShortcut: String { shortcutLabel.stringValue }
    #endif
}

/// The snippet card's foot: a dot and the sync sentence.
final class CodePreviewSyncFooter: NSView {
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dot = HelmSignalDot()
    private var tint: HelmTint = .good

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glyph.image = HelmSymbol.image("icloud", pointSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [glyph, label, dot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: HelmMetrics.s2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: HelmMetrics.s2),
            dot.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func set(text: String, synced: Bool, failed: Bool, onThisMachine: Bool, theme: HelmTheme) {
        label.stringValue = text.prefix(1).uppercased() + text.dropFirst()
        label.toolTip = label.stringValue
        tint = failed ? .critical : (synced ? .good : .warn)
        glyph.image = HelmSymbol.image(onThisMachine ? "internaldrive" : "icloud", pointSize: 11, weight: .medium)
        setAccessibilityLabel(label.stringValue)
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        label.font = HelmType.captionSmall()
        label.textColor = HelmTheme.mutedInk(theme)
        glyph.contentTintColor = HelmTheme.mutedInk(theme)
        dot.configure(tint: tint, theme: theme)
    }

    #if FM_SELFTESTS
    var debugText: String { label.stringValue }
    #endif
}

/// The whole presentation's geometry. It owns the cards and their
/// constraints, and the views it is handed (the snippet list, the tab strip,
/// the editor surface, the status bar) keep belonging to the controller.
final class CodePreviewWorkbenchView: NSView {

    struct Parts {
        let snippetList: NSView
        let syncFooter: CodePreviewSyncFooter
        let quickActions: [CodePreviewQuickActionButton]
        let toolbarLeading: [NSView]
        let runStatus: CodePreviewRunStatus
        let runButton: NSView
        /// UX-21: a chip before the run status (the sandbox shield), or none.
        var trailingChip: NSView? = nil
        let tabStrip: NSView
        let titleRow: CodePreviewEditorTitleRow
        let codeArea: NSView
        let dock: CodeRunResultsDock
        let inspectorCards: [CodePreviewInspectorCard]
        let statusBar: NSView
    }

    let parts: Parts
    /// S04 of the 2026-11-17 UI/UX proposals: the snippet list, its sync line
    /// and the two quick actions in one band - `HelmPageSidebar.Band`, the
    /// page-sidebar surface every page with a column now wears - where they
    /// were two stacked cards ("Snippets", "Quick actions"). The band runs
    /// from the page's leading edge down to the status bar; the actions are
    /// its footer.
    let snippetBand = HelmPageSidebar.Band()
    /// The band's column: `snippetColumnWidth` wide, a gap in from either
    /// edge of the band.
    let snippetColumn = NSLayoutGuide()
    let toolbarCard = CodePreviewCardSurface()
    let editorFrame = CodePreviewCardSurface()
    let inspectorScroll = NSScrollView()
    private let tabRow = NSView()
    private let tabRowSeparator = NSView()
    private let titleRowSeparator = NSView()
    private let toolbarSeparators: [CodePreviewToolbarSeparator]
    private let leadingTools = NSStackView()
    private let trailingTools = NSStackView()
    private let inspectorStack = NSStackView()
    private let inspectorDocument = CodePreviewFlippedView()

    private var snippetWidth: NSLayoutConstraint!
    private var mainBesideSnippets: NSLayoutConstraint!
    private var mainAtPageEdge: NSLayoutConstraint!
    private var editorBesideInspector: NSLayoutConstraint!
    private var editorAtColumnEdge: NSLayoutConstraint!
    private var codeAboveDock: NSLayoutConstraint!
    private var codeToCardFoot: NSLayoutConstraint!
    private var dockHeight: NSLayoutConstraint!

    private(set) var snippetColumnShown = true
    private(set) var inspectorShown = true
    /// The captain's own choices, which the width rules are applied on top of.
    private var snippetColumnWanted = true
    private var expanded = false

    init(parts: Parts, separators: Int = 3) {
        self.parts = parts
        toolbarSeparators = (0..<separators).map { _ in CodePreviewToolbarSeparator() }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Build

    private func build() {
        let gap = CodePreviewWorkbenchMetrics.gap
        addSubview(snippetBand)
        for card in [toolbarCard, editorFrame] { addSubview(card) }
        addSubview(inspectorScroll)
        addSubview(parts.statusBar)
        editorFrame.layer?.masksToBounds = true
        toolbarCard.layer?.masksToBounds = true

        // The band: the list, the sync line under it, and the quick actions
        // as its footer.
        snippetBand.addLayoutGuide(snippetColumn)
        for view in [parts.snippetList, parts.syncFooter] { snippetBand.addSubview(view) }
        snippetBand.setAccessibilityElement(true)
        snippetBand.setAccessibilityRole(.group)
        snippetBand.setAccessibilityLabel("Snippets")
        var footerTop: NSView?
        var previous: NSView?
        for action in parts.quickActions {
            snippetBand.addSubview(action)
            NSLayoutConstraint.activate([
                action.leadingAnchor.constraint(equalTo: snippetColumn.leadingAnchor),
                action.trailingAnchor.constraint(equalTo: snippetColumn.trailingAnchor),
            ])
            if let previous {
                action.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: HelmMetrics.s2).isActive = true
            } else {
                footerTop = action
            }
            previous = action
        }

        // The toolbar card: tools on the leading side, the run status and Run
        // on the trailing side.
        for stack in [leadingTools, trailingTools] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = HelmMetrics.s1 + 2
            stack.translatesAutoresizingMaskIntoConstraints = false
            toolbarCard.addSubview(stack)
        }
        var separatorIndex = 0
        for view in parts.toolbarLeading {
            if view is CodePreviewToolbarSeparatorSlot, separatorIndex < toolbarSeparators.count {
                leadingTools.addArrangedSubview(toolbarSeparators[separatorIndex])
                separatorIndex += 1
            } else if !(view is CodePreviewToolbarSeparatorSlot) {
                leadingTools.addArrangedSubview(view)
            }
        }
        if let chip = parts.trailingChip { trailingTools.addArrangedSubview(chip) }
        trailingTools.addArrangedSubview(parts.runStatus)
        trailingTools.addArrangedSubview(parts.runButton)
        trailingTools.setCustomSpacing(HelmMetrics.s3, after: parts.runStatus)
        toolbarCard.setAccessibilityElement(true)
        toolbarCard.setAccessibilityRole(.toolbar)
        toolbarCard.setAccessibilityLabel("Snippet tools")

        // The editor card: tabs, title row, the code, the dock.
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        tabRow.wantsLayer = true
        editorFrame.addSubview(tabRow)
        tabRow.addSubview(parts.tabStrip)
        for view in [tabRowSeparator, titleRowSeparator] {
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            editorFrame.addSubview(view)
        }
        for view in [parts.titleRow, parts.codeArea, parts.dock] { editorFrame.addSubview(view) }

        // The inspector: three cards in a scroll view whose document is
        // flipped (gotcha (9)) and pinned to the clip view's width (gotcha (4)).
        inspectorStack.orientation = .vertical
        inspectorStack.alignment = .leading
        inspectorStack.spacing = HelmMetrics.s2 + 2
        inspectorStack.translatesAutoresizingMaskIntoConstraints = false
        for card in parts.inspectorCards {
            inspectorStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: inspectorStack.widthAnchor).isActive = true
        }
        inspectorDocument.translatesAutoresizingMaskIntoConstraints = false
        inspectorDocument.addSubview(inspectorStack)
        inspectorScroll.translatesAutoresizingMaskIntoConstraints = false
        inspectorScroll.drawsBackground = false
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.autohidesScrollers = true
        inspectorScroll.scrollerStyle = .overlay
        inspectorScroll.documentView = inspectorDocument
        inspectorScroll.setAccessibilityLabel("Run configuration, script checks and editor preferences")

        let initialWidth = CodePreviewWorkbenchMetrics.snippetColumnWidth
        snippetWidth = snippetColumn.widthAnchor.constraint(equalToConstant: initialWidth)
        snippetWidth.priority = HelmDaylightPriority.contentTie
        let inspectorWidth = inspectorScroll.widthAnchor.constraint(equalToConstant: CodePreviewWorkbenchMetrics.inspectorWidth)
        inspectorWidth.priority = HelmDaylightPriority.contentTie
        mainBesideSnippets = toolbarCard.leadingAnchor.constraint(equalTo: snippetBand.trailingAnchor, constant: gap)
        mainAtPageEdge = toolbarCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gap)
        editorBesideInspector = editorFrame.trailingAnchor.constraint(equalTo: inspectorScroll.leadingAnchor, constant: -gap)
        editorAtColumnEdge = editorFrame.trailingAnchor.constraint(equalTo: toolbarCard.trailingAnchor)
        codeAboveDock = parts.codeArea.bottomAnchor.constraint(equalTo: parts.dock.topAnchor)
        codeToCardFoot = parts.codeArea.bottomAnchor.constraint(equalTo: editorFrame.bottomAnchor)
        dockHeight = parts.dock.heightAnchor.constraint(equalToConstant: CodeRunResultsDock.preferredHeight)
        // Below `NSLayoutPriorityWindowSizeStayPut`, for gotcha (13)'s reason:
        // the page is mounted for the process's life.
        dockHeight.priority = HelmDaylightPriority.contentTie

        // Each toolbar side's "fit" edge is an inequality in the 251-499
        // band, so a narrow window clips a row rather than growing.
        let leadingFits = leadingTools.trailingAnchor.constraint(lessThanOrEqualTo: trailingTools.leadingAnchor,
                                                                 constant: -HelmMetrics.s3)
        leadingFits.priority = HelmDaylightPriority.contentTie

        let statusHeight = parts.statusBar.heightAnchor.constraint(equalToConstant: CodePreviewWorkbenchMetrics.statusBarHeight)
        NSLayoutConstraint.activate([
            // The status bar runs the page's whole width at its foot.
            parts.statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            parts.statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            parts.statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusHeight,

            // The band: flush with the page's leading edge and top, down to
            // the status bar, its column a gap in from either side. The list
            // takes the height the footer leaves and scrolls past it.
            snippetBand.leadingAnchor.constraint(equalTo: leadingAnchor),
            snippetBand.topAnchor.constraint(equalTo: topAnchor),
            snippetBand.bottomAnchor.constraint(equalTo: parts.statusBar.topAnchor),
            snippetColumn.leadingAnchor.constraint(equalTo: snippetBand.leadingAnchor, constant: gap),
            snippetBand.trailingAnchor.constraint(equalTo: snippetColumn.trailingAnchor, constant: gap),
            snippetWidth,

            parts.snippetList.leadingAnchor.constraint(equalTo: snippetColumn.leadingAnchor),
            parts.snippetList.trailingAnchor.constraint(equalTo: snippetColumn.trailingAnchor),
            parts.snippetList.topAnchor.constraint(equalTo: snippetBand.topAnchor, constant: gap),
            parts.syncFooter.topAnchor.constraint(equalTo: parts.snippetList.bottomAnchor, constant: HelmMetrics.s2),
            parts.syncFooter.leadingAnchor.constraint(equalTo: snippetColumn.leadingAnchor, constant: HelmMetrics.s1),
            parts.syncFooter.trailingAnchor.constraint(equalTo: snippetColumn.trailingAnchor),
            (footerTop ?? parts.syncFooter).topAnchor.constraint(greaterThanOrEqualTo: parts.syncFooter.bottomAnchor,
                                                                  constant: HelmMetrics.s4),
            (previous ?? parts.syncFooter).bottomAnchor.constraint(equalTo: snippetBand.bottomAnchor, constant: -gap),

            // The toolbar card.
            toolbarCard.topAnchor.constraint(equalTo: topAnchor, constant: gap),
            toolbarCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gap),
            toolbarCard.heightAnchor.constraint(equalToConstant: CodePreviewWorkbenchMetrics.toolbarHeight),
            leadingTools.leadingAnchor.constraint(equalTo: toolbarCard.leadingAnchor, constant: HelmMetrics.s3),
            leadingTools.centerYAnchor.constraint(equalTo: toolbarCard.centerYAnchor),
            trailingTools.trailingAnchor.constraint(equalTo: toolbarCard.trailingAnchor, constant: -HelmMetrics.s2),
            trailingTools.centerYAnchor.constraint(equalTo: toolbarCard.centerYAnchor),
            leadingFits,

            // The editor card.
            editorFrame.leadingAnchor.constraint(equalTo: toolbarCard.leadingAnchor),
            editorFrame.topAnchor.constraint(equalTo: toolbarCard.bottomAnchor, constant: HelmMetrics.s2 + 2),
            editorFrame.bottomAnchor.constraint(equalTo: parts.statusBar.topAnchor, constant: -gap),

            tabRow.leadingAnchor.constraint(equalTo: editorFrame.leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: editorFrame.trailingAnchor),
            tabRow.topAnchor.constraint(equalTo: editorFrame.topAnchor),
            tabRow.heightAnchor.constraint(equalToConstant: CodePreviewWorkbenchMetrics.tabRowHeight),
            parts.tabStrip.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor, constant: HelmMetrics.s2),
            parts.tabStrip.trailingAnchor.constraint(lessThanOrEqualTo: tabRow.trailingAnchor, constant: -HelmMetrics.s2),
            parts.tabStrip.centerYAnchor.constraint(equalTo: tabRow.centerYAnchor),
            tabRowSeparator.leadingAnchor.constraint(equalTo: editorFrame.leadingAnchor),
            tabRowSeparator.trailingAnchor.constraint(equalTo: editorFrame.trailingAnchor),
            tabRowSeparator.topAnchor.constraint(equalTo: tabRow.bottomAnchor),
            tabRowSeparator.heightAnchor.constraint(equalToConstant: 1),

            parts.titleRow.leadingAnchor.constraint(equalTo: editorFrame.leadingAnchor),
            parts.titleRow.trailingAnchor.constraint(equalTo: editorFrame.trailingAnchor),
            parts.titleRow.topAnchor.constraint(equalTo: tabRowSeparator.bottomAnchor),
            titleRowSeparator.leadingAnchor.constraint(equalTo: editorFrame.leadingAnchor),
            titleRowSeparator.trailingAnchor.constraint(equalTo: editorFrame.trailingAnchor),
            titleRowSeparator.topAnchor.constraint(equalTo: parts.titleRow.bottomAnchor),
            titleRowSeparator.heightAnchor.constraint(equalToConstant: 1),

            parts.codeArea.leadingAnchor.constraint(equalTo: editorFrame.leadingAnchor),
            parts.codeArea.trailingAnchor.constraint(equalTo: editorFrame.trailingAnchor),
            parts.codeArea.topAnchor.constraint(equalTo: titleRowSeparator.bottomAnchor),

            parts.dock.leadingAnchor.constraint(equalTo: editorFrame.leadingAnchor),
            parts.dock.trailingAnchor.constraint(equalTo: editorFrame.trailingAnchor),
            parts.dock.bottomAnchor.constraint(equalTo: editorFrame.bottomAnchor),
            dockHeight,

            // The inspector column.
            inspectorScroll.trailingAnchor.constraint(equalTo: toolbarCard.trailingAnchor),
            inspectorScroll.topAnchor.constraint(equalTo: editorFrame.topAnchor),
            inspectorScroll.bottomAnchor.constraint(equalTo: editorFrame.bottomAnchor),
            inspectorWidth,
            inspectorDocument.widthAnchor.constraint(equalTo: inspectorScroll.contentView.widthAnchor),
            inspectorDocument.topAnchor.constraint(equalTo: inspectorScroll.contentView.topAnchor),
            inspectorStack.leadingAnchor.constraint(equalTo: inspectorDocument.leadingAnchor),
            inspectorStack.trailingAnchor.constraint(equalTo: inspectorDocument.trailingAnchor),
            inspectorStack.topAnchor.constraint(equalTo: inspectorDocument.topAnchor),
            inspectorStack.bottomAnchor.constraint(equalTo: inspectorDocument.bottomAnchor),
        ])
        // The list hugs its content below everything else that decides a
        // height, so the footer stays at the band's foot and the list scrolls
        // once its rows outgrow the room above it.
        if let hug = (parts.snippetList as? CodePreviewFileSidebar)?.contentHeightPreference() {
            hug.priority = NSLayoutConstraint.Priority(240)
            hug.isActive = true
        }
        mainBesideSnippets.isActive = true
        editorBesideInspector.isActive = true
        codeToCardFoot.isActive = true
        parts.dock.isHidden = true
        applyColumns()
    }

    // MARK: Columns

    /// The captain's ⌘B choice for the snippet list.
    func setSnippetColumnWanted(_ wanted: Bool) {
        snippetColumnWanted = wanted
        applyColumns()
    }

    /// Expand: both side columns out of the way, the editor the full width.
    func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        applyColumns()
    }

    var isExpanded: Bool { expanded }

    /// The breakpoint is a function of this view's own width, which no
    /// column change can alter - so re-deriving it cannot loop. It is
    /// applied as the width changes and again at the top of a layout pass,
    /// **before** the pass resolves: a constraint swapped after `super.layout()`
    /// leaves that pass's frames stale (measured: the editor card kept the
    /// inspector's gap at a narrow width).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyColumnsIfWidthChanged()
    }

    override func layout() {
        applyColumnsIfWidthChanged()
        super.layout()
    }

    private func applyColumnsIfWidthChanged() {
        guard bounds.width > 0 else { return }
        let wantsInspector = !expanded && !parts.inspectorCards.isEmpty
            && CodePreviewWorkbenchMetrics.showsInspector(pageWidth: bounds.width)
        let width = CodePreviewWorkbenchMetrics.snippetColumnWidth(pageWidth: bounds.width)
        if wantsInspector != inspectorShown || snippetWidth.constant != width {
            applyColumns()
        }
    }

    private func applyColumns() {
        let pageWidth = bounds.width > 0 ? bounds.width : 1512
        let showSnippets = snippetColumnWanted && !expanded
        // UX-21: a workbench handed no cards draws no right column.
        let showInspector = !expanded && !parts.inspectorCards.isEmpty
            && CodePreviewWorkbenchMetrics.showsInspector(pageWidth: pageWidth)
        snippetWidth.constant = CodePreviewWorkbenchMetrics.snippetColumnWidth(pageWidth: pageWidth)
        snippetBand.isHidden = !showSnippets
        inspectorScroll.isHidden = !showInspector
        // Deactivate before activating: two active ties on one edge are a
        // required conflict AppKit resolves by resizing something.
        if showSnippets {
            mainAtPageEdge.isActive = false
            mainBesideSnippets.isActive = true
        } else {
            mainBesideSnippets.isActive = false
            mainAtPageEdge.isActive = true
        }
        if showInspector {
            editorAtColumnEdge.isActive = false
            editorBesideInspector.isActive = true
        } else {
            editorBesideInspector.isActive = false
            editorAtColumnEdge.isActive = true
        }
        snippetColumnShown = showSnippets
        inspectorShown = showInspector
        needsLayout = true
    }

    /// The dock: showing pins the code above it, hiding gives the code the
    /// card's foot. Swapped rather than collapsed, for the floating pane's
    /// measured reason - a header row with required constraints does not
    /// collapse to zero at a priority below 500.
    func setDockVisible(_ visible: Bool) {
        parts.dock.isHidden = !visible
        if visible {
            codeToCardFoot.isActive = false
            codeAboveDock.isActive = true
        } else {
            codeAboveDock.isActive = false
            codeToCardFoot.isActive = true
        }
        // Gotcha (14): a swapped tie is re-derived only when something asks.
        layoutSubtreeIfNeeded()
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        snippetBand.applyTheme(theme)
        for card in [toolbarCard, editorFrame] { card.applyTheme(theme) }
        for card in parts.inspectorCards { card.applyTheme(theme) }
        for separator in toolbarSeparators { separator.applyTheme(theme) }
        let line = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.dividerAlpha)
        tabRowSeparator.layer?.backgroundColor = line.cgColor
        titleRowSeparator.layer?.backgroundColor = line.cgColor
        // The tab row is the card's sunken well, the way a file-tab strip
        // sits under its tabs; the selected tab takes the card fill above it.
        tabRow.layer?.backgroundColor = HelmField.fill(theme).cgColor
        parts.titleRow.applyTheme(theme)
        parts.runStatus.applyTheme(theme)
        parts.syncFooter.applyTheme(theme)
        parts.dock.applyTheme(theme)
        for action in parts.quickActions { action.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugDockHeightConstant: CGFloat { dockHeight.constant }
    var debugCodeAboveDock: Bool { codeAboveDock.isActive }
    var debugToolbarLeadingViews: [NSView] { leadingTools.arrangedSubviews }
    var debugToolbarTrailingViews: [NSView] { trailingTools.arrangedSubviews }
    var debugTabRow: NSView { tabRow }
    /// S04: the band's column, in this view's coordinates.
    var debugSnippetColumnFrame: NSRect { snippetColumn.frame }
    #endif
}

/// A marker the controller puts in the toolbar's leading list where a
/// separator rule belongs; the workbench swaps in a themed rule.
final class CodePreviewToolbarSeparatorSlot: NSView {}

/// A flipped plain document view, so a short inspector rests at the top of
/// its scroll view rather than at its bottom (gotcha (9)).
final class CodePreviewFlippedView: NSView {
    override var isFlipped: Bool { true }
}
