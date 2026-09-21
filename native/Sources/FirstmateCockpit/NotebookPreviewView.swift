// Manjesh Grand Line - native macOS app.
//
// The Notebook's live preview pane: `NotebookMarkdown`'s block model, drawn as
// real AppKit views in this app's own type and colour tokens.
//
// ## Why AppKit and not a second `WKWebView`
//
// The editor beside this pane is already a web view (Monaco), so rendering the
// preview as HTML would have been the obvious cheap answer. It was rejected
// for three measured reasons, in order of weight:
//
//   1. **Two web content processes for one page.** Code Preview's whole gating
//      story (`CodePreviewWebView`'s header) is about one page costing nothing
//      while hidden; a second one on the same destination doubles the floor for
//      a pane that shows no interaction at all.
//   2. **`cacheDisplay` does not capture `WKWebView` content.** AGENTS.md's
//      probe rules say so plainly, and this project's whole verification
//      convention for UI is an off-screen render probe. A native preview can
//      be asserted pixel-for-pixel by the same probe every other page uses; an
//      HTML one would need `takeSnapshot`, i.e. a second, weaker mechanism for
//      the half of the page most likely to drift.
//   3. **It would be a second visual language.** A themed HTML document has to
//      restate every type ramp and every colour token this app already owns,
//      in CSS, and then keep them in step by hand. `CodePreviewController`'s
//      header makes exactly this call for Monaco's missing tab bar and status
//      bar, for exactly this reason.
//
// ## Links
//
// Inline links need a *click target inside a paragraph*, which an
// `NSTextField` cannot give: its `.link` attribute is handled by AppKit
// itself and goes straight to `NSWorkspace`, with no seam to route a
// `[[wiki-link]]` back into the app. So prose is an `NSTextView`
// (non-editable, selectable, auto-sizing) whose delegate intercepts the click
// - the standard AppKit answer, and the same control `RunbooksController`
// already uses for a body of markdown.
//
// A wiki-link's URL is a private scheme this app never navigates to
// (`grandline-notebook:`). It is a *token*, decoded here and dispatched
// through a closure; nothing hands it to `NSWorkspace`. An ordinary
// `[text](https://…)` link goes to the browser, and only when
// `WebNavigationPolicy.opensExternally` agrees it is a real web URL - the same
// gate the two web islands already use, applied here so a markdown file
// arriving over git sync cannot make the app open a `file:` or custom-scheme
// URL.

import AppKit

final class NotebookPreviewView: NSView {

    // MARK: Actions (caller-owned, never performed here)

    /// A resolved `[[wiki-link]]` was clicked. The page id.
    var onOpenPage: ((String) -> Void)?
    /// An unresolved `[[wiki-link]]` was clicked. The raw target text, so the
    /// caller can offer to create it.
    var onCreateMissingPage: ((String) -> Void)?

    /// The URL scheme wiki-links travel under. Never registered with the
    /// system and never navigated to - see the file header.
    static let linkScheme = "grandline-notebook"

    // MARK: State

    private let stack = NSStackView()
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var proseViews: [NotebookProseView] = []

    /// The empty state for a page with no content yet, built only when it is
    /// needed rather than kept as a permanently-mounted hidden view.
    private var emptyState: HelmEmptyState?

    // MARK: Build

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.blockSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    enum Metrics {
        static let blockSpacing: CGFloat = HelmMetrics.s2
        /// The extra air above a heading, so a section reads as a section
        /// rather than as one more paragraph. Applied as a spacer view rather
        /// than as `stack.setCustomSpacing`, because the latter is keyed to
        /// the view *before* it and a rebuild reorders those.
        static let headingLead: CGFloat = 10
        static let listIndent: CGFloat = 16
        static let checkboxSide: CGFloat = 13
        static let codeInset: CGFloat = 10
        static let quoteBarWidth: CGFloat = 3
    }

    // MARK: Rendering

    /// Draws `content`, resolving its wiki-links against `resolver`.
    ///
    /// Rebuilds the whole subtree. That is deliberate and measured against the
    /// alternative: a diffing renderer for a pane that is re-drawn on a
    /// debounce (never per keystroke) would be real complexity buying nothing,
    /// and every block view here is a handful of labels.
    func render(_ content: String, resolver: NotebookLinkResolver?, sourcePageID: String?, theme: HelmTheme) {
        self.theme = theme
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        proseViews.removeAll()
        emptyState = nil

        let blocks = NotebookMarkdown.parse(content)
        guard !blocks.isEmpty else {
            showEmptyState()
            return
        }

        var previous: NotebookBlock?
        for block in blocks {
            if case .heading = block, previous != nil {
                add(spacer(Metrics.headingLead))
            }
            add(view(for: block, resolver: resolver, sourcePageID: sourcePageID))
            previous = block
        }
    }

    /// Re-colours what is already drawn. A theme observer repaints, it never
    /// re-reads (GL-24) - so this takes no content and asks for none.
    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        emptyState?.applyTheme(theme)
        for prose in proseViews { prose.applyTheme(theme) }
        for view in stack.arrangedSubviews {
            (view as? NotebookThemedBlock)?.applyBlockTheme(theme)
        }
    }

    private func showEmptyState() {
        let state = HelmEmptyState(
            symbol: "text.alignleft",
            title: "Nothing on this page yet",
            body: "Type in the editor - the preview follows along. "
                + "Link another page with [[its name]].",
            size: .compact,
            hue: RailDestination.notebook.domainHue)
        state.applyTheme(theme)
        emptyState = state
        add(state)
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func view(for block: NotebookBlock,
                      resolver: NotebookLinkResolver?,
                      sourcePageID: String?) -> NSView {
        switch block {
        case .heading(let level, let runs):
            return prose(runs, role: .heading(level), resolver: resolver, sourcePageID: sourcePageID)
        case .paragraph(let runs):
            return prose(runs, role: .body, resolver: resolver, sourcePageID: sourcePageID)
        case .rule:
            return ruleView()
        case .quote(let runs):
            return quoteView(runs, resolver: resolver, sourcePageID: sourcePageID)
        case .code(let language, let text):
            return codeView(language: language, text: text)
        case .bullet(let indent, let checked, let runs):
            return listRow(indent: indent, checked: checked, marker: nil, runs: runs,
                           resolver: resolver, sourcePageID: sourcePageID)
        case .ordered(let indent, let number, let runs):
            return listRow(indent: indent, checked: nil, marker: "\(number).", runs: runs,
                           resolver: resolver, sourcePageID: sourcePageID)
        }
    }

    // MARK: Block builders

    private func prose(_ runs: [NotebookInline],
                       role: NotebookProseView.Role,
                       resolver: NotebookLinkResolver?,
                       sourcePageID: String?) -> NotebookProseView {
        let view = NotebookProseView(role: role)
        view.onOpenPage = { [weak self] id in self?.onOpenPage?(id) }
        view.onCreateMissingPage = { [weak self] target in self?.onCreateMissingPage?(target) }
        view.setRuns(runs, resolver: resolver, sourcePageID: sourcePageID, theme: theme)
        proseViews.append(view)
        return view
    }

    private func ruleView() -> NSView {
        let rule = NotebookHairlineBlock()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rule.applyBlockTheme(theme)
        return rule
    }

    private func quoteView(_ runs: [NotebookInline],
                           resolver: NotebookLinkResolver?,
                           sourcePageID: String?) -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.widthAnchor.constraint(equalToConstant: Metrics.quoteBarWidth).isActive = true
        bar.setContentHuggingPriority(.required, for: .horizontal)
        bar.setContentCompressionResistancePriority(.required, for: .horizontal)

        let body = prose(runs, role: .quote, resolver: resolver, sourcePageID: sourcePageID)

        let row = NSStackView(views: [bar, body])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = HelmMetrics.s2
        // Gotcha (10): a horizontal stack left at `.gravityAreas` honours no
        // priority at all, so the bar would drift with the text's length.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true

        let quote = NotebookQuoteBlock(bar: bar)
        quote.translatesAutoresizingMaskIntoConstraints = false
        quote.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: quote.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: quote.trailingAnchor),
            row.topAnchor.constraint(equalTo: quote.topAnchor),
            row.bottomAnchor.constraint(equalTo: quote.bottomAnchor),
        ])
        quote.applyBlockTheme(theme)
        return quote
    }

    private func codeView(language: String?, text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = HelmType.code()
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = []
        var languageLabel: NSTextField?
        if let language, !language.isEmpty {
            let tag = NSTextField(labelWithString: language.uppercased())
            tag.font = HelmType.kicker()
            tag.translatesAutoresizingMaskIntoConstraints = false
            languageLabel = tag
            views.append(tag)
        }
        views.append(label)

        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s1
        column.translatesAutoresizingMaskIntoConstraints = false

        let panel = NotebookCodeBlock(body: label, languageLabel: languageLabel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.cornerRadius = HelmMetrics.rControl
        panel.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: Metrics.codeInset),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -Metrics.codeInset),
            column.topAnchor.constraint(equalTo: panel.topAnchor, constant: HelmMetrics.s2),
            column.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -HelmMetrics.s2),
        ])
        panel.applyBlockTheme(theme)
        return panel
    }

    private func listRow(indent: Int,
                         checked: Bool?,
                         marker: String?,
                         runs: [NotebookInline],
                         resolver: NotebookLinkResolver?,
                         sourcePageID: String?) -> NSView {
        let leading: NSView
        var checkbox: NotebookCheckboxView?
        var markerLabel: NSTextField?
        if let checked {
            let box = NotebookCheckboxView(checked: checked)
            checkbox = box
            leading = box
        } else if let marker {
            let label = NSTextField(labelWithString: marker)
            label.font = HelmType.body()
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
            markerLabel = label
            leading = label
        } else {
            let dot = NotebookBulletDot()
            leading = dot
        }
        leading.setContentHuggingPriority(.required, for: .horizontal)
        leading.setContentCompressionResistancePriority(.required, for: .horizontal)

        // A ticked item reads as done: struck through and muted, which is what
        // the mockup draws and what makes a checklist scannable.
        let role: NotebookProseView.Role = checked == true ? .completedItem : .body
        let body = prose(runs, role: role, resolver: resolver, sourcePageID: sourcePageID)

        let row = NSStackView(views: [leading, body])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        // A checkbox has no baseline of its own, so aligning it to one leaves
        // it floating; pin its top to the text's instead.
        if let checkbox {
            row.alignment = .top
            checkbox.topAnchor.constraint(equalTo: body.topAnchor, constant: 2).isActive = true
        }

        let container = NotebookListRowBlock(checkbox: checkbox, marker: markerLabel)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                         constant: CGFloat(indent) * Metrics.listIndent),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.applyBlockTheme(theme)
        return container
    }

    // MARK: Probe surface

    #if FM_SELFTESTS
    /// The rendered block views, so a suite can assert the *painted* shape
    /// rather than re-deriving it from the parser it is testing (AGENTS.md's
    /// "assert what is painted, not what was computed").
    var debugBlockViews: [NSView] { stack.arrangedSubviews }
    var debugProseViews: [NotebookProseView] { proseViews }
    var debugShowsEmptyState: Bool { emptyState != nil }
    #endif
}

// MARK: - Themed block protocol

/// A block view that owns some theme-derived paint of its own.
///
/// A protocol rather than a `switch` in `applyTheme`, for the reason
/// `DaylightDrillActions` gives: the repaint should be the block's own
/// business, so adding a block type is one file's edit rather than two.
protocol NotebookThemedBlock: NSView {
    func applyBlockTheme(_ theme: HelmTheme)
}

final class NotebookHairlineBlock: NSView, NotebookThemedBlock {
    func applyBlockTheme(_ theme: HelmTheme) {
        wantsLayer = true
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
    }
}

final class NotebookQuoteBlock: NSView, NotebookThemedBlock {
    private let bar: NSView
    init(bar: NSView) {
        self.bar = bar
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyBlockTheme(_ theme: HelmTheme) {
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.55).cgColor
    }
}

final class NotebookCodeBlock: NSView, NotebookThemedBlock {
    private let body: NSTextField
    private let languageLabel: NSTextField?
    init(body: NSTextField, languageLabel: NSTextField?) {
        self.body = body
        self.languageLabel = languageLabel
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyBlockTheme(_ theme: HelmTheme) {
        wantsLayer = true
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        layer?.backgroundColor = line.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = line.withAlphaComponent(0.4).cgColor
        body.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        languageLabel?.textColor = HelmTheme.mutedInk(theme)
    }
}

final class NotebookListRowBlock: NSView, NotebookThemedBlock {
    private let checkbox: NotebookCheckboxView?
    private let marker: NSTextField?
    init(checkbox: NotebookCheckboxView?, marker: NSTextField?) {
        self.checkbox = checkbox
        self.marker = marker
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyBlockTheme(_ theme: HelmTheme) {
        checkbox?.applyTheme(theme)
        marker?.textColor = HelmTheme.mutedInk(theme)
    }
}

/// The small accent dot an unordered item is led by - `SRELeadChatView`'s own
/// bullet treatment, which is this app's one existing answer for the same
/// question.
final class NotebookBulletDot: NSView, NotebookThemedBlock {
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        addSubview(dot)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 12),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Sits on the first line's optical centre, not the row's - a
            // wrapped item's dot must stay beside its first line.
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            bottomAnchor.constraint(greaterThanOrEqualTo: dot.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyBlockTheme(_ theme: HelmTheme) {
        dot.layer?.cornerRadius = 2.5
        dot.layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.85).cgColor
    }
}

/// A task item's box: a filled, ticked square when done, a hairline outline
/// when not. Drawn rather than an `NSButton`, because it is **not**
/// interactive - the source of truth is the markdown in the editor, and a
/// checkbox that looked clickable but was not would be worse than a glyph.
final class NotebookCheckboxView: NSView {
    private let checked: Bool
    private let tick = NSImageView()

    init(checked: Bool) {
        self.checked = checked
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.borderWidth = 1.5
        tick.translatesAutoresizingMaskIntoConstraints = false
        tick.imageScaling = .scaleProportionallyUpOrDown
        tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        tick.isHidden = !checked
        addSubview(tick)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: NotebookPreviewView.Metrics.checkboxSide),
            heightAnchor.constraint(equalToConstant: NotebookPreviewView.Metrics.checkboxSide),
            tick.centerXAnchor.constraint(equalTo: centerXAnchor),
            tick.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // GL-16: the state has to be readable, not only visible.
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(checked ? "Done" : "Not done")
        setAccessibilityValue(checked ? 1 : 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: HelmTheme) {
        let fill = HelmTheme.nsColor(theme.isDaylight ? theme.daylightTokens.okText : theme.ansiHex[2])
        if checked {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = fill.cgColor
            // The tick sits on the fill, so its own legibility is measured
            // against that fill rather than against the page.
            tick.contentTintColor = HelmContrast.legibleOn(fill: fill,
                                                           preferring: HelmTheme.nsColor(theme.selectionTextHex))
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        }
    }
}

// MARK: - Prose

/// One run of wrapping, selectable, link-clickable text.
///
/// An `NSTextView` rather than an `NSTextField` because inline links need a
/// delegate seam - see the file header. Auto-sizing vertically against a
/// caller-driven width, which is what lets it sit in an `NSStackView` beside
/// ordinary views.
final class NotebookProseView: NSTextView {

    enum Role: Equatable {
        case heading(Int)
        case body
        case quote
        /// A ticked task item: muted and struck through.
        case completedItem
    }

    var onOpenPage: ((String) -> Void)?
    var onCreateMissingPage: ((String) -> Void)?

    private let role: Role
    private var runs: [NotebookInline] = []
    private var resolved: [Int: String?] = [:]

    /// **Held strongly on purpose.** `NSTextStorage.addLayoutManager` makes
    /// the *storage* retain the manager, and the manager's own back-reference
    /// to its storage is `unowned(unsafe)` - so a hand-built text system whose
    /// storage is only a local variable leaves the layout manager pointing at
    /// freed memory the moment the initialiser returns. Measured, not
    /// reasoned: this crashed with `EXC_BAD_ACCESS` inside
    /// `objc_autoreleasePoolPop` on the suite's very first mounted page.
    private let storage: NSTextStorage

    init(role: Role) {
        self.role = role
        // The text system is built by hand rather than letting
        // `NSTextView(frame:)` synthesise one. That convenience initialiser
        // funnels into `init(frame:textContainer:)`, which `NSTextView`
        // declares but this subclass does not override - and AppKit then
        // traps with "Use of unimplemented initializer" the moment the view
        // is constructed. Measured, not guessed: the first mount of this page
        // crashed there.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        self.storage = storage
        super.init(frame: .zero, textContainer: container)
        translatesAutoresizingMaskIntoConstraints = false
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = false
        // Nothing here should ever "improve" the captain's own notes.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        delegate = self
        // **`NSTextView` paints its own styling over every `.link` range**,
        // and its default is the system blue plus an underline - which
        // silently overrode the per-run colours this view computes. Measured
        // in a real off-screen render: a resolved link and an unresolved one
        // came out the *same* blue in both registers, while the attributed
        // string this view had installed correctly carried two different
        // colours. Handing over a dictionary with no `.foregroundColor` and
        // no `.underlineStyle` leaves each run's own attributes alone; the
        // cursor is kept, because a link that does not change the pointer
        // does not read as clickable.
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Sizing

    /// The height this text needs at its current width.
    ///
    /// **An `NSTextView` has no useful intrinsic size of its own** - it is
    /// built to live in a scroll view that gives it one - so a stack view
    /// would resolve it to zero and the pane would render blank. Deriving it
    /// from the layout manager is the standard answer, and the `glyphRange`
    /// call before it is not optional: `usedRect` is only valid once layout
    /// for that container has actually run.
    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else { return super.intrinsicContentSize }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func layout() {
        super.layout()
        // A width change re-wraps the text, which changes the height nothing
        // else will re-ask for.
        if abs(bounds.width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = bounds.width
            textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
            invalidateIntrinsicContentSize()
        }
    }

    private var lastLaidOutWidth: CGFloat = -1

    // MARK: Content

    func setRuns(_ runs: [NotebookInline],
                 resolver: NotebookLinkResolver?,
                 sourcePageID: String?,
                 theme: HelmTheme) {
        self.runs = runs
        resolved = [:]
        for (index, run) in runs.enumerated() {
            if case .wikiLink(let target) = run.kind {
                resolved[index] = resolver?.resolve(target, from: sourcePageID)
            }
        }
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        storage.setAttributedString(attributed(theme))
        invalidateIntrinsicContentSize()
    }

    private func attributed(_ theme: HelmTheme) -> NSAttributedString {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        // A tinted hue is safe as a fill and is NOT automatically safe as text
        // (AGENTS.md's colour rule), so every coloured run here goes through
        // `HelmContrast` against the surface it is actually drawn on.
        let linkColor = HelmContrast.legibleOn(fill: surface, preferring: HelmTheme.nsColor(theme.accentHex))
        let missingColor = HelmContrast.legibleOn(
            fill: surface,
            preferring: HelmTheme.nsColor(theme.isDaylight ? theme.daylightTokens.warnText : theme.ansiHex[3]))
        let codeBackground = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.14)

        let baseSize = role.pointSize
        let baseColor: NSColor = {
            switch role {
            case .heading: return ink
            case .body: return ink
            case .quote, .completedItem: return muted
            }
        }()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = role.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString()
        for (index, run) in runs.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: baseColor,
                .paragraphStyle: paragraph,
            ]
            switch run.kind {
            case .plain:
                attributes[.font] = role.font(bold: run.bold, italic: run.italic)
            case .code:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .medium)
                attributes[.backgroundColor] = codeBackground
            case .wikiLink(let target):
                let pageID = resolved[index] ?? nil
                attributes[.font] = role.font(bold: run.bold, italic: run.italic)
                attributes[.foregroundColor] = pageID == nil ? missingColor : linkColor
                attributes[.underlineStyle] = pageID == nil
                    ? NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue
                    : NSUnderlineStyle.single.rawValue
                attributes[.link] = Self.wikiURL(pageID: pageID, target: target)
                attributes[.toolTip] = pageID == nil
                    ? "\(target) - this page does not exist yet. Click to create it."
                    : "Open \(pageID ?? target)"
            case .link(let url):
                attributes[.font] = role.font(bold: run.bold, italic: run.italic)
                attributes[.foregroundColor] = linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let parsed = URL(string: url) { attributes[.link] = parsed }
                attributes[.toolTip] = url
            }
            if role == .completedItem {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        // Selection has to stay legible in both registers, and AppKit's own
        // default is a system blue that ignores the theme entirely.
        selectedTextAttributes = [
            .backgroundColor: HelmTheme.nsColor(theme.selectionHex).withAlphaComponent(0.35),
            .foregroundColor: ink,
        ]
        return result
    }

    /// The private token a wiki-link travels as. Percent-encoded, so a page
    /// name with a space or a slash survives the round trip.
    static func wikiURL(pageID: String?, target: String) -> URL? {
        let host = pageID == nil ? "new" : "page"
        let payload = pageID ?? target
        let encoded = payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "\(NotebookPreviewView.linkScheme)://\(host)/\(encoded)")
    }

    /// Decodes one back. `nil` for anything that is not this app's own token.
    static func decodeWikiURL(_ url: URL) -> (isExisting: Bool, payload: String)? {
        guard url.scheme == NotebookPreviewView.linkScheme else { return nil }
        guard let host = url.host, host == "page" || host == "new" else { return nil }
        let raw = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty else { return nil }
        return (host == "page", decoded)
    }

    #if FM_SELFTESTS
    var debugPlainText: String { string }
    var debugAttributedText: NSAttributedString { attributedString() }
    #endif
}

extension NotebookProseView.Role {
    var pointSize: CGFloat {
        switch self {
        case .heading(let level):
            switch level {
            case 1: return HelmType.scaled(19)
            case 2: return HelmType.scaled(15.5)
            case 3: return HelmType.scaled(13.5)
            default: return HelmType.scaled(13)
            }
        case .body, .quote, .completedItem: return HelmType.scaled(13)
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .heading: return 1
        case .body, .quote, .completedItem: return 2.5
        }
    }

    func font(bold: Bool, italic: Bool) -> NSFont {
        let size = pointSize
        var font: NSFont
        switch self {
        case .heading(let level):
            // The page's own h1 takes the app's display voice, the way every
            // other hero title here does; deeper headings stay in the body
            // sans so a section header does not compete with the page name.
            font = level == 1 ? HelmType.rounded(size, .heavy) : .systemFont(ofSize: size, weight: .semibold)
        case .body, .quote, .completedItem:
            font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        }
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }
}

extension NotebookProseView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let direct = link as? URL {
            url = direct
        } else if let text = link as? String {
            url = URL(string: text)
        } else {
            url = nil
        }
        guard let url else { return false }
        if let token = Self.decodeWikiURL(url) {
            if token.isExisting {
                onOpenPage?(token.payload)
            } else {
                onCreateMissingPage?(token.payload)
            }
            return true
        }
        // An ordinary markdown link. The same gate the two web islands apply
        // to a refused navigation: only a real web URL is handed to the
        // system, so a `file:`/custom-scheme link arriving in a page over git
        // sync opens nothing.
        if WebNavigationPolicy.opensExternally(url) {
            NSWorkspace.shared.open(url)
            return true
        }
        AppLog.lifecycle.info("notebook: refused a non-web link (\(url.scheme ?? "?", privacy: .public))")
        return true
    }
}
