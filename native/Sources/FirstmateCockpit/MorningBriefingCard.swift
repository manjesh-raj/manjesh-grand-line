// Manjesh Grand Line - native macOS app.
//
// F12's card - the briefing atop Overview. `MorningBriefingData.swift` owns
// what it says; this file owns how it looks.
//
// Built on `HelmCard`, whose structured header
// (`setHeader(symbol:tint:titleLabel:subtitleLabel:actions:)`) is already
// exactly the mockup's head: an icon tile, a title, a subtitle that the page
// rewrites as data arrives, and trailing actions at the card's own trailing
// edge. So the refresh (clock) and dismiss (X) buttons are ordinary
// `HelmPageToolbar.iconButton`-shaped `HelmButton`s in that actions slot, not
// hand-placed glyphs.
//
// ## One deviation from the mockup, deliberately
//
// The mockup titles this card "Good morning". Overview's own page header
// already renders a time-appropriate greeting ("Good morning, <captain>") a
// few points above it, and this codebase has twice been corrected for exactly
// that shape of duplication - Review's in-page hero reading "Review" under a
// top bar reading "Review" (audit §4.6), and Docs' headings restating the tab
// pill directly above them. So the card is titled "Morning briefing" and the
// mockup's subtitle is kept verbatim in structure ("Generated 6:58 AM from the
// fleet snapshot, PR queue, tasks, drift, and quota"). The greeting stays
// where it already was, once.
//
// ## The paragraph, and why it is an NSTextView
//
// `BriefingParagraphView` is the one thing here that is not a stock
// component. The mockup's body is flowing prose with individual clauses
// underlined and tappable, and `NSTextView` is the only AppKit control that
// gives inline link ranges with a click callback the app can intercept
// (`textView(_:clickedOnLink:at:)`) rather than handing the URL to
// `NSWorkspace` the way a selectable `NSTextField` does. A chip flow
// (`ChipFlowView`) was the alternative and was rejected: it turns a
// paragraph into a row of buttons, which is a different thing to read.
//
// Two mechanics that matter if this is ever edited:
//
//   - The text view is **not** vertically resizable and does not track its
//     own container width; `layout()` sets the container size from the real
//     bounds and drives an explicit height constraint from
//     `NSLayoutManager.usedRect`. The epsilon guard is what makes that
//     converge instead of looping - the same "read the resolved width back in
//     `layout()`" pattern `HelmEmptyState.layout()` already uses.
//   - `linkTextAttributes` is set to the cursor only. Left at its default,
//     `NSTextView` paints every link in the system link blue and its own
//     underline, overriding the per-clause tint the attributed string
//     carries - which would put the one colour macOS chooses on top of the
//     twelve palettes this app actually has.

import AppKit

// MARK: - The paragraph

/// The briefing body: one wrapping paragraph whose clauses are individually
/// clickable. Owns its own height, so it drops into a vertical stack.
final class BriefingParagraphView: NSView, NSTextViewDelegate {

    /// Fired when a clause is clicked. `.none`-target clauses are never
    /// rendered as links, so this only ever carries a real destination.
    var onActivate: ((BriefingTarget) -> Void)?

    private let textView = NSTextView()
    private var heightConstraint: NSLayoutConstraint!
    private var clauses: [BriefingClause] = []
    private var separator = " "
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Which surface the clause text lands on, for the contrast correction -
    /// this card's body is a `HelmCard`, so it is the chrome surface.
    private var surface: NSColor { HelmTheme.nsColor(theme.chromeBackgroundHex) }

    /// The height before `layout()` has measured anything - see the constraint
    /// it initialises.
    static let unmeasuredHeight: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        // See the file header: without this, AppKit paints its own link blue
        // and underline over the per-clause tint.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textView)
        // Required, and safe to be: this view lives inside Overview's scroll
        // view's document, whose height is free - so a vertical constraint
        // here cannot pressure the window's own size the way AGENTS.md's
        // gotcha (13) describes for a *width* constraint (that one is about a
        // proportional/equality pair above `NSLayoutPriorityWindowSizeStayPut`).
        // Leaving it optional would instead make the paragraph's height
        // ambiguous, and the failure mode there is a silently zero-height
        // paragraph - an invisible briefing, which is worse.
        // 1pt, not a plausible-looking placeholder: if the measurement in
        // `layout()` ever stops running, the paragraph collapses to something
        // obviously wrong (and `MorningBriefingSelfTest` fails) rather than to
        // a height that happens to look like one line of text.
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.unmeasuredHeight)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Content

    /// `separator` is what joins two clauses. The AI half returns whole
    /// sentences, so a space is right; the deterministic half returns
    /// fragments, so it passes `MorningBriefingLocal.statSeparator` and the
    /// rendered line is exactly `MorningBriefingLocal.statLine`.
    func render(_ clauses: [BriefingClause], separator: String, theme: HelmTheme) {
        self.clauses = clauses
        self.separator = separator
        self.theme = theme
        rebuild()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        rebuild()
    }

    private func rebuild() {
        HelmSelection.apply(to: textView, theme: theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.35

        let out = NSMutableAttributedString()
        for (index, clause) in clauses.enumerated() {
            if index > 0 {
                // Unstyled and unlinked on purpose: the separator belongs to
                // neither clause, so a click on it must do nothing.
                out.append(NSAttributedString(string: separator, attributes: [
                    .font: HelmType.body(),
                    .paragraphStyle: paragraph,
                    .foregroundColor: HelmTheme.mutedInk(theme),
                ]))
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: HelmType.body(),
                .paragraphStyle: paragraph,
                .foregroundColor: ink,
            ]
            if clause.target.isLink {
                // The hue is corrected against the surface it actually lands
                // on - a `HelmTint` is safe as a fill and is NOT automatically
                // safe as text (audit §5.7, `HelmContrast`'s own rule).
                attributes[.foregroundColor] = HelmContrast.legibleTintedText(
                    tintHex: clause.target.tint.hex(in: theme), over: surface, theme: theme)
                // The mockup's dotted underline.
                attributes[.underlineStyle] = NSUnderlineStyle([.single, .patternDot]).rawValue
                // The clause index, not a URL: this never leaves the process,
                // and `clickedOnLink` hands it straight back.
                attributes[.link] = index
            }
            out.append(NSAttributedString(string: clause.text, attributes: attributes))
        }
        textView.textStorage?.setAttributedString(out)
        needsLayout = true
    }

    // MARK: Height

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 1, let container = textView.textContainer, let manager = textView.layoutManager else { return }
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        let measured = ceil(manager.usedRect(for: container).height)
        // The epsilon guard is what makes assigning a constraint constant from
        // inside `layout()` converge rather than loop.
        if measured > 0, abs(heightConstraint.constant - measured) > 0.5 {
            heightConstraint.constant = measured
        }
    }

    // MARK: Clicks

    // MARK: Probe / self-test surface
    //
    // GL-27: compiled into debug builds only, like every other `debug*` hook
    // in this app. `MorningBriefingSelfTest` uses these to prove the
    // paragraph is not silently zero-height and that only linked clauses
    // actually carry a link range.
    #if FM_SELFTESTS
    var debugMeasuredHeight: CGFloat { heightConstraint.constant }

    /// What the paragraph actually reads as - used to pin that a degraded card
    /// renders exactly `MorningBriefingLocal.statLine`.
    var debugPlainText: String { textView.string }

    /// How many characters carry an `.link` attribute - zero for a briefing
    /// made entirely of `.none` clauses.
    var debugLinkedCharacterCount: Int {
        guard let storage = textView.textStorage else { return 0 }
        var count = 0
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { count += range.length }
        }
        return count
    }

    /// Drives what a real click does, without a real click - the delegate
    /// method is the whole of that path.
    func debugActivate(clauseIndex: Int) -> Bool {
        textView(textView, clickedOnLink: clauseIndex, at: 0)
    }
    #endif

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let index = link as? Int, clauses.indices.contains(index) else { return false }
        let target = clauses[index].target
        guard target.isLink else { return false }
        onActivate?(target)
        return true
    }
}

// MARK: - The card

final class MorningBriefingCard: NSView {

    /// The clock affordance in the mockup's header - regenerates now rather
    /// than waiting for tomorrow's first activation.
    var onRefresh: (() -> Void)?
    /// The X - hides the card for the rest of the day.
    var onDismiss: (() -> Void)?
    /// A clause was clicked.
    var onActivate: ((BriefingTarget) -> Void)?

    /// Where the Claude-usage popover should anchor when a `.quota` clause is
    /// clicked. Console's own toolbar button is not reachable from here (it
    /// only exists on a Herdr-backed mirror tab), so the popover hangs off the
    /// paragraph the captain just clicked.
    var quotaAnchor: NSView { paragraph }

    private let card = HelmCard()
    private let titleLabel = NSTextField(labelWithString: "Morning briefing")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let paragraph = BriefingParagraphView()
    private let footnote = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let busyLabel = NSTextField(labelWithString: "Composing your briefing\u{2026}")
    private let refreshButton: HelmButton
    private let dismissButton: HelmButton
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        // `target`/`action` are assigned in `build()` - `self` is not available
        // until after `super.init`.
        refreshButton = HelmPageToolbar.iconButton(symbol: "clock", tooltip: "Regenerate the briefing",
                                                  target: nil, action: nil)
        dismissButton = HelmPageToolbar.iconButton(symbol: "xmark", tooltip: "Dismiss until tomorrow",
                                                  target: nil, action: nil)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)

        card.setHeader(symbol: "sparkles", tint: .accent,
                       titleLabel: titleLabel, subtitleLabel: subtitleLabel,
                       actions: [refreshButton, dismissButton])

        paragraph.onActivate = { [weak self] target in self?.onActivate?(target) }

        footnote.font = HelmType.caption()
        footnote.translatesAutoresizingMaskIntoConstraints = false
        footnote.isHidden = true

        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        busyLabel.font = HelmType.body()
        busyLabel.translatesAutoresizingMaskIntoConstraints = false
        let busyRow = NSStackView(views: [spinner, busyLabel])
        busyRow.orientation = .horizontal
        busyRow.alignment = .centerY
        busyRow.spacing = HelmMetrics.s2
        busyRow.translatesAutoresizingMaskIntoConstraints = false
        busyRow.isHidden = true
        self.busyRow = busyRow

        let body = NSStackView(views: [busyRow, paragraph, footnote])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(body, insets: HelmCard.contentInsets)

        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The paragraph and the footnote fill the card's body column, so
            // the paragraph's own `layout()` measures against the real width
            // rather than its natural one.
            paragraph.widthAnchor.constraint(equalTo: body.widthAnchor),
            footnote.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
    }

    private var busyRow: NSStackView!

    // MARK: Rendering

    /// Shown while a generation is in flight. The previous briefing (if any)
    /// stays visible underneath, so a refresh never blanks the card.
    func setBusy(_ busy: Bool) {
        if busy, subtitleLabel.stringValue.isEmpty {
            // A first-ever generation has no subtitle yet, and an empty line
            // under the title reads as a broken card rather than a busy one.
            subtitleLabel.stringValue = "Reading the fleet snapshot, PR queue, tasks, drift and quota\u{2026}"
        }
        busyRow.isHidden = !busy
        refreshButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func render(_ record: MorningBriefingRecord, theme: HelmTheme) {
        self.theme = theme
        subtitleLabel.stringValue = MorningBriefing.subtitle(for: record)
        paragraph.render(record.clauses,
                         separator: record.isDegraded ? MorningBriefingLocal.statSeparator : " ",
                         theme: theme)
        if record.isDegraded {
            // The mockup's own footer note, made specific: it names the real
            // reason rather than only the general rule, because "claude isn't
            // installed" and "the call timed out" are different things to do
            // something about.
            let reason = record.degradedReason.map { " (\($0))" } ?? ""
            footnote.stringValue = "Plain summary - no AI call was made\(reason). Every number above came from this machine."
            footnote.isHidden = false
        } else {
            footnote.stringValue = ""
            footnote.isHidden = true
        }
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        paragraph.applyTheme(theme)
        let muted = HelmTheme.mutedInk(theme)
        footnote.textColor = muted
        busyLabel.textColor = muted
    }

    // MARK: Actions

    @objc private func refreshClicked() { onRefresh?() }
    @objc private func dismissClicked() { onDismiss?() }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugParagraph: BriefingParagraphView { paragraph }
    var debugSubtitle: String { subtitleLabel.stringValue }
    var debugFootnoteVisible: Bool { !footnote.isHidden }
    var debugFootnote: String { footnote.stringValue }
    func debugPressRefresh() { refreshClicked() }
    func debugPressDismiss() { dismissClicked() }
    #endif
}
