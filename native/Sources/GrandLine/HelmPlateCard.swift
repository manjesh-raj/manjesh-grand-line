// Grand Line - native macOS app.
//
// Daylight §6.1 / §7's "module-style plates": the grid tile a *drill page*
// uses for a browsable record.
//
// **Why this is not `HelmModuleCard`.** That class is the canvas widget, and
// two of its contracts are wrong here by design: the whole card is one
// activatable target that navigates to a destination (`onOpen` with no visible
// affordance), and every instance resolves to one fixed
// `HelmModuleCard.standardHeight` so the hub reads as a uniform grid. §7 asks
// Docs' runbook grid for the module's *look* with neither of those - it calls
// it the "non-navigating version with Open buttons". Rather than bolt an
// actions slot and a second height mode onto the canvas component (two
// disjoint halves in one type, the shape §6.3 keeps `HelmAccentRow` and
// `ToolRowLayout` apart to avoid), this is the small sibling: same ribbon,
// same gradient tile, same card chrome, an explicit action row instead of a
// whole-card navigation contract.
//
// **Tools' landing grid is deliberately NOT a caller** - this file's first
// draft (slice 5) guessed that it would be, written a slice before that grid
// was migrated. Slice 6 measured it against the real page and both rejected
// contracts turn out to be the ones Tools *wants*: clicking anywhere on a tool
// card has opened that tool in a new tab since the page shipped (so removing
// whole-card activation in favour of an Open button would be a behaviour
// change, which Phase 4 forbids), and a nine-item picker is exactly the case
// uniform height was introduced for. `Content` here also has no body slot,
// and a tool plate's whole point is carrying that tool's description - which
// a one-line truncating subtitle would cut. See `ToolsController.toolPlate`.
//
// Anatomy, top to bottom (§6.1's, minus the four body kinds):
//   1. a header row - 30pt `HelmGradientTile` + title/subtitle text stack,
//   2. an action row - the primary "Open" leading, an optional destructive
//      glyph pinned to the trailing edge.
//
// **S07 (1.1.0): `.onAim`, the card is the control.** UI-10 removed a "View
// all" button beside a clickable card from the Merge queue; Runbooks and
// Postmortems kept the same duplicate - an Open button on a card that already
// opens on click, plus a trash glyph at rest, so two runbooks drew four
// controls for two actions. `Content.actionReveal = .onAim` drops the action
// row: the whole card opens (click, Return, Space, VoiceOver press), the
// subtitle is the record's meta line, and the secondary actions (duplicate,
// delete) sit in the top-trailing corner as 28pt glyph buttons that show only
// while the card is aimed at - hovered, or focused, or one of them focused -
// the same rule `HelmAccentRow.actionReveal` has. ⌫ deletes and ⌘D
// duplicates while the card has focus. `.always` (the default) is the plate as
// it was, so a caller that does not opt in is unchanged.
//
// Chrome comes from the shared helpers (`HelmCard.applyCardSurface`,
// `HelmCard.elevation`), which already branch Daylight vs. the other twelve
// palettes internally - so this file states no colour of its own, and the
// plate converges onto the app's one card recipe rather than carrying the
// bespoke transparent-card-with-a-hairline that predated the design system.
//
// Two AppKit lessons from AGENTS.md are baked in and must not be "simplified":
//
//   - **Two layers, not one.** A layer shadow is not cast by a clipping layer,
//     and a rounded fill needs clipping - so this outer view carries the
//     shadow with `masksToBounds = false` and an explicit `shadowPath`, while
//     an inner `HoverHighlightView` carries the fill, border and clip. The
//     same arrangement `HelmComposerCard`/`HelmModuleCard` already use.
//   - **The action row is positioned with constraints, not a stack.** A
//     trailing control inside a horizontal `NSStackView` drifts with the
//     leading content's own width (gotcha (10)), and a bare spacer cannot be
//     held collapsed with a hugging priority (gotcha (12)). The delete glyph
//     is pinned to the card's own trailing edge, which is exactly the fix
//     `fm/grandline-docs-runbook-delete-icon-corner` landed for the card this
//     replaces.

import AppKit

final class HelmPlateCard: NSView {

    struct Content {
        var title: String
        /// One line, truncating. Real metadata, not filler - see
        /// `DocsRunbookMetadata`.
        var subtitle: String
        var symbol: String
        var hue: HelmDomainHue
        /// Hover text for the whole plate, carrying what the one-line subtitle
        /// and the two-line title no longer have room for.
        var tooltip: String? = nil
        var actionTitle: String = "Open"
        var onOpen: () -> Void
        /// A destructive glyph in the action row's trailing corner. Absent
        /// when the record cannot be deleted from here.
        var onDelete: (() -> Void)? = nil
        var deleteTooltip: String = "Delete"
        /// S07: where the secondary actions live. `.always` draws the action
        /// row; `.onAim` makes the card the control (see the file header).
        var actionReveal: ActionReveal = .always
        /// S07: a "duplicate" glyph beside delete, `.onAim` only.
        var onDuplicate: (() -> Void)? = nil
        var duplicateTooltip: String = "Duplicate"
    }

    /// The same two cases `HelmAccentRow.ActionReveal` has.
    enum ActionReveal {
        /// The action row: Open leading, delete trailing, at rest.
        case always
        /// No action row. The card opens; duplicate and delete show on aim.
        case onAim
    }

    // MARK: Geometry

    // No ribbon (the UI/UX revamp's UI-6 and UI-58): a plate's identity is
    // its tile, the same rule as `HelmModuleCard`'s. The 6pt the ribbon took
    // came off `baseHeight` with it.
    static let horizontalInset: CGFloat = 14
    static let verticalInset: CGFloat = 12
    static let headerToActionsGap: CGFloat = 10
    /// The trailing glyph's visible box - a toolbar icon square, deliberately
    /// not a `HelmButton`'s intrinsic width, which carries a regular button's
    /// horizontal padding even with an empty title (measured 87pt on a 265pt
    /// card by the card this replaces).
    static let deleteButtonSide: CGFloat = 24
    /// S07: an `.onAim` corner glyph's hit area - the macOS pointer-target
    /// minimum, and the inspector close's size.
    static let aimButtonSide: CGFloat = 28

    /// **Every plate in a grid is exactly this tall.**
    ///
    /// Fixed rather than content-sized for the reason the card this replaces
    /// already documented: a grid whose tiles each take their own natural
    /// height reads as ragged, and a short title should leave space below it
    /// rather than shrink its row. The number is the ribbon, both insets, a
    /// two-line title over its subtitle (the tallest realistic header), the
    /// gap, and the action row.
    ///
    /// Run through `HelmType.scaled` because every font inside is: at GL-32's
    /// "Larger" a fixed literal clips. Safe as a required constraint unlike a
    /// *width* (AGENTS.md gotcha (13)) - a plate lives in a scroll view whose
    /// document height is free, so it cannot pressure the window.
    static var height: CGFloat { HelmType.scaled(baseHeight) }
    static let baseHeight: CGFloat = 112

    static let maximumTitleLines = 2

    // MARK: Views

    /// Fired on click of the plate body as well as the Open button. The plate
    /// keeps the whole-surface click the card it replaces always had - the
    /// Open button is the *affordance* §7 asks for, not a removal of a working
    /// interaction - and `HoverHighlightView` is what gives both a `.button`
    /// role and a keyboard/VoiceOver press for free.
    private let card = HoverHighlightView()
    private let tile = HelmGradientTile(size: .module)
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let openButton = HelmButton(title: "Open", variant: .secondary, size: .small)
    private let deleteButton = HelmButton(symbol: "trash", variant: .quiet, size: .small)
    /// S07's corner actions, shown on aim.
    private let aimDuplicateButton = HelmButton(symbol: "plus.square.on.square", variant: .quiet, size: .small)
    private let aimDeleteButton = HelmButton(symbol: "trash", variant: .quiet, size: .small)
    private let aimActions = NSStackView()
    private var aimFocusRegistration: HelmFocusRegistration?
    private var aimHoldsFocus = false
    /// The constraints only one of the two reveals uses.
    private var alwaysConstraints: [NSLayoutConstraint] = []
    private var onAimConstraints: [NSLayoutConstraint] = []
    private let headerRow: NSStackView
    private let textStack: NSStackView

    private var content: Content?
    private var themeToken: ThemeObservation?
    private var lastTheme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        textStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerRow = NSStackView(views: [tile, textStack])
        super.init(frame: frameRect)
        buildChrome()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let aimFocusRegistration { HelmFocusSensing.shared.unregister(aimFocusRegistration) }
    }

    private func buildChrome() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The shadow host must not clip, or the shadow it casts is clipped
        // away with it.
        layer?.masksToBounds = false

        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.masksToBounds = true
        addSubview(card)

        titleLabel.font = HelmType.moduleTitle()
        titleLabel.maximumNumberOfLines = Self.maximumTitleLines
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = HelmType.captionSmall()
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = HelmMetrics.s0
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // Stack-level, never the content-priority calls - those are no-ops on
        // a view with no intrinsic content size (gotcha (12)). This is what
        // makes the text column, rather than the tile, absorb the plate's
        // leftover width.
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = HelmMetrics.s3
        // `.fill`, explicitly: at the default `.gravityAreas` the text stack is
        // laid out at its own natural width and a long title clips instead of
        // wrapping (gotcha (10)).
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(headerRow)

        openButton.target = self
        openButton.action = #selector(openClicked)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        openButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.addSubview(openButton)

        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        // Hidden until a `configure` that actually supplies `onDelete`. An
        // unconfigured plate showing a live-looking trash glyph is what this
        // slice's own suite caught: the visibility was only ever decided in
        // `configure`, so a plate built and laid out before its content (or
        // reused in a grid rebuild) rendered a delete affordance for a record
        // that has no delete action.
        deleteButton.isHidden = true
        card.addSubview(deleteButton)

        // S07's corner pair, built for every plate and shown by `.onAim` only.
        for (button, action) in [(aimDuplicateButton, #selector(duplicateClicked)),
                                 (aimDeleteButton, #selector(deleteClicked))] {
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            let insets = button.alignmentRectInsets
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.aimButtonSide - insets.left - insets.right),
                button.heightAnchor.constraint(equalToConstant: Self.aimButtonSide - insets.top - insets.bottom),
            ])
        }
        aimActions.setViews([aimDuplicateButton, aimDeleteButton], in: .leading)
        aimActions.orientation = .horizontal
        aimActions.spacing = HelmMetrics.s0
        aimActions.translatesAutoresizingMaskIntoConstraints = false
        aimActions.isHidden = true
        card.addSubview(aimActions)
        card.onHoverChange = { [weak self] _ in self?.applyAimReveal(animated: true) }
        card.onKeyDown = { [weak self] event in self?.handleAimKey(event) ?? false }

        let deleteInsets = deleteButton.alignmentRectInsets
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            headerRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.horizontalInset),
            headerRow.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.verticalInset),
        ])
        // `.onAim`: the header stops short of the corner pair, and the card is
        // as tall as its header (the grid decides whether a row matches).
        onAimConstraints = [
            aimActions.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -HelmMetrics.s2),
            aimActions.topAnchor.constraint(equalTo: card.topAnchor, constant: HelmMetrics.s2),
            headerRow.trailingAnchor.constraint(equalTo: aimActions.leadingAnchor, constant: -HelmMetrics.s1),
            card.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: Self.verticalInset),
        ]
        alwaysConstraints = [
            heightAnchor.constraint(equalToConstant: Self.height),
            headerRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.horizontalInset),
            openButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.horizontalInset),
            openButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.verticalInset),
            openButton.topAnchor.constraint(greaterThanOrEqualTo: headerRow.bottomAnchor,
                                            constant: Self.headerToActionsGap),

            // Pinned to the card's own corner rather than laid out after the
            // Open button, so it cannot drift with the title's length or wrap.
            deleteButton.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                                   constant: -Self.horizontalInset),
            deleteButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            deleteButton.widthAnchor.constraint(
                equalToConstant: Self.deleteButtonSide - deleteInsets.left - deleteInsets.right),
            deleteButton.heightAnchor.constraint(
                equalToConstant: Self.deleteButtonSide - deleteInsets.top - deleteInsets.bottom),
        ]
        NSLayoutConstraint.activate(alwaysConstraints)

        let click = NSClickGestureRecognizer(target: self, action: #selector(openClicked))
        card.addGestureRecognizer(click)
    }

    // MARK: Content

    func configure(_ content: Content) {
        self.content = content
        titleLabel.stringValue = content.title
        subtitleLabel.stringValue = content.subtitle
        subtitleLabel.isHidden = content.subtitle.isEmpty
        tile.configure(symbol: content.symbol, hue: content.hue)
        openButton.title = content.actionTitle
        let onAim = content.actionReveal == .onAim
        openButton.isHidden = onAim
        deleteButton.isHidden = onAim || content.onDelete == nil
        deleteButton.toolTip = content.deleteTooltip
        aimActions.isHidden = !onAim || (content.onDelete == nil && content.onDuplicate == nil)
        aimDeleteButton.isHidden = content.onDelete == nil
        aimDuplicateButton.isHidden = content.onDuplicate == nil
        for (button, tooltip) in [(aimDeleteButton, content.deleteTooltip),
                                  (aimDuplicateButton, content.duplicateTooltip)] {
            button.toolTip = tooltip
            button.setAccessibilityLabel("\(tooltip) \(content.title)")
        }
        NSLayoutConstraint.deactivate(onAim ? alwaysConstraints : onAimConstraints)
        NSLayoutConstraint.activate(onAim ? onAimConstraints : alwaysConstraints)
        if onAim, aimFocusRegistration == nil {
            aimFocusRegistration = HelmFocusSensing.shared.register(card, includesDescendants: true) {
                [weak self] focused in
                self?.aimHoldsFocus = focused
                self?.applyAimReveal(animated: true)
            }
        }
        card.toolTip = content.tooltip
        toolTip = content.tooltip
        // `.onAim`: the card is a button named for the record (the meta line
        // is its value), since nothing else on it says "open".
        card.setAccessibilityLabel(onAim
            ? content.title
            : [content.title, content.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        card.accessibilityValueOverride = onAim && !content.subtitle.isEmpty ? content.subtitle : nil
        applyAimReveal(animated: false)
        applyTheme(lastTheme)
    }

    @objc private func openClicked() { content?.onOpen() }
    @objc private func deleteClicked() { content?.onDelete?() }
    @objc private func duplicateClicked() { content?.onDuplicate?() }

    /// S07: the corner pair fades in while the card is aimed at. `alphaValue`,
    /// not `isHidden`, for `HelmAccentRow.applyActionReveal`'s reasons: the
    /// buttons stay in VoiceOver and the title does not re-flow on hover.
    private func applyAimReveal(animated: Bool) {
        guard content?.actionReveal == .onAim else { return }
        let revealed = card.isHovering || aimHoldsFocus
        HelmMotion.fade(aimActions, to: revealed ? 1 : 0, duration: HelmMotion.stateDuration, animated: animated)
    }

    /// S07: ⌫ deletes (through the caller's own confirm) and ⌘D duplicates,
    /// while the card has keyboard focus. Return and Space stay the card's
    /// press.
    private func handleAimKey(_ event: NSEvent) -> Bool {
        guard let content, content.actionReveal == .onAim else { return false }
        let flags = event.modifierFlags.intersection(KeyChord.relevantModifierMask)
        // 51 = Delete (⌫), 117 = Forward Delete.
        if (event.keyCode == 51 || event.keyCode == 117), flags.isEmpty, let onDelete = content.onDelete {
            onDelete()
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "d", flags == .command,
           let onDuplicate = content.onDuplicate {
            onDuplicate()
            return true
        }
        return false
    }

    // MARK: Layout / theme

    override func layout() {
        super.layout()
        // A wrapping label's intrinsic width comes from its own
        // `preferredMaxLayoutWidth`, which no distribution or hugging fix
        // touches - it has to be handed the column's *real* resolved width on
        // every pass. An over-estimate is the dangerous direction: AppKit
        // sizes the label for one line and the second line then draws outside
        // its own bounds with no ellipsis. Same read-back pattern
        // `HelmEmptyState.layout()` established.
        let available = textStack.bounds.width
        if available > 0, titleLabel.preferredMaxLayoutWidth != available {
            titleLabel.preferredMaxLayoutWidth = available
            titleLabel.invalidateIntrinsicContentSize()
        }
        applyShadow(lastTheme)
    }

    private func applyShadow(_ theme: HelmTheme) {
        guard let layer else { return }
        HelmCard.applyElevation(.resting, to: layer, theme: theme,
                                path: CGPath(roundedRect: bounds,
                                             cornerWidth: Self.cornerRadius(for: theme),
                                             cornerHeight: Self.cornerRadius(for: theme),
                                             transform: nil))
    }

    /// §6.1's radius under Daylight; the shared card radius on the other
    /// twelve palettes, so a plate rounds like every other card there.
    static func cornerRadius(for theme: HelmTheme) -> CGFloat {
        theme.isDaylight ? HelmMetrics.dModule : HelmMetrics.rCard
    }

    func applyTheme(_ theme: HelmTheme) {
        lastTheme = theme
        HelmCard.applyCardSurface(to: card, theme: theme, cornerRadius: HelmMetrics.rCard)
        card.normalColor = HelmTheme.nsColor(theme.chromeBackgroundHex)
        card.hoverColor = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.rowHover)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.18)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        // The tile owns its own theme observation - never paint it from here.
        needsLayout = true
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// The plate's title as drawn.
    var debugTitle: String { titleLabel.stringValue }

    struct Anatomy {
        let hasRibbon: Bool
        let ribbonHeight: CGFloat
        let ribbonStopCount: Int
        let cornerRadius: CGFloat
        let shadowOpacity: Float
        let openButtonTitle: String
        let deleteVisible: Bool
        let titleMaxLines: Int
        let resolvedHeight: CGFloat
        let openButtonFrame: NSRect
        let deleteButtonFrame: NSRect
        let cardFill: NSColor?
    }

    var anatomyForTests: Anatomy {
        Anatomy(hasRibbon: card.layer?.sublayers?.contains { $0 is CAGradientLayer } ?? false,
                ribbonHeight: 0,
                ribbonStopCount: 0,
                cornerRadius: card.layer?.cornerRadius ?? 0,
                shadowOpacity: layer?.shadowOpacity ?? 0,
                openButtonTitle: openButton.title,
                deleteVisible: !deleteButton.isHidden,
                titleMaxLines: titleLabel.maximumNumberOfLines,
                resolvedHeight: frame.height,
                openButtonFrame: openButton.frame,
                deleteButtonFrame: deleteButton.frame,
                cardFill: (card.layer?.backgroundColor).map { NSColor(cgColor: $0) ?? .clear })
    }

    @discardableResult
    func debugActivateOpen() -> Bool {
        guard content != nil else { return false }
        openClicked()
        return true
    }

    /// S07: the `.onAim` corner pair - its alpha (the reveal), which buttons
    /// it carries, and whether the action row is gone.
    var debugAim: (alpha: CGFloat, delete: Bool, duplicate: Bool, openRowHidden: Bool) {
        (aimActions.isHidden ? 0 : aimActions.alphaValue, !aimDeleteButton.isHidden,
         !aimDuplicateButton.isHidden, openButton.isHidden && deleteButton.isHidden)
    }
    var debugCardHit: HoverHighlightView { card }
    var debugAimButtons: (duplicate: HelmButton, delete: HelmButton) { (aimDuplicateButton, aimDeleteButton) }

    @discardableResult
    func debugActivateDelete() -> Bool {
        guard content?.onDelete != nil else { return false }
        deleteClicked()
        return true
    }
    #endif
}
