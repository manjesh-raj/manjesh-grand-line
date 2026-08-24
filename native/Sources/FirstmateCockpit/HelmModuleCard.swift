// Manjesh Grand Line - native macOS app.
//
// `HelmModuleCard` - the home canvas widget (Daylight migration §6.1), plus
// the two gauges §6.8 gives it (`HelmRingGauge`, `HelmProgressBar`).
//
// **What this is, and what it is deliberately not.** A module is a *summary*
// surface: one number, one ring, two or three peek rows, or a paragraph.
// Never a table. §1's third rule ("low density with progressive disclosure")
// is the whole reason the canvas is worth having - the detail already exists
// one drill-in down, on a page that is better at showing it. If a module
// ever needs a fourth row, that is a signal it should be showing less, not
// that this component needs a scroll view.
//
// **Anatomy** (§6.1, top to bottom):
//   1. a 6pt gradient ribbon, h1->h2 left to right;
//   2. a header row: 30pt gradient tile, title + subtitle, trailing chip;
//   3. a body, one of five kinds (§6.1's four plus `.note`, the one-line
//      form three of the table's own modules ask for).
//
// **Two layers, not one, and that is load-bearing.** A layer with a shadow
// must not clip, and a card with a rounded fill must - so the outer view
// carries the shadow with `masksToBounds = false` and an explicit
// `shadowPath`, and the inner `HoverHighlightView` carries the fill, the
// border and the clip. This is the arrangement `HelmComposerCard` already
// proved in this codebase; see §2.5.
//
// **Why the inner view is a `HoverHighlightView`.** §6.1 asks for the whole
// card to be one click target announcing as a button. That component already
// derives a VoiceOver label from its own descendant labels, answers
// `.button`, draws a real focus ring and replays its own recognizer on a
// keyboard press (GL-16) - so putting the recognizer there gives the module
// every one of those for free rather than four overrides here.
//
// **Themes itself**, like `HelmCard`, `HelmButton` and `HelmGradientTile`: it
// owns its `ThemeManager` observation and unregisters in `deinit`. A page
// must not set its fonts, fills or borders - the next theme change
// overwrites them (this codebase's most-repeated bug class).

import AppKit

// MARK: - Chips

/// A module's trailing status chip (§6.7).
///
/// The four kinds are *states*, never identities: a chip says "this is fine"
/// / "this wants a look" / "this is wrong" / "here is a fact", and never
/// carries a domain hue. A hue on a chip would compete with the ribbon and
/// the tile, which are the two things that say *which area* this card is.
struct HelmModuleChip: Equatable {
    enum Kind: Equatable {
        case ok, warn, bad, mute

        /// The hex this kind resolves through `HelmContrast.tintedSurface`.
        /// Semantic theme slots, not Daylight literals, so the eleven
        /// fallback palettes render their own greens and ambers (§2.8).
        func hex(in theme: HelmTheme) -> String {
            switch self {
            case .ok: return theme.ansiHex[2]
            case .warn: return theme.ansiHex[3]
            case .bad: return theme.ansiHex[1]
            case .mute: return theme.chromeInkHex
            }
        }
    }

    let text: String
    let kind: Kind

    static func ok(_ text: String) -> HelmModuleChip { .init(text: text, kind: .ok) }
    static func warn(_ text: String) -> HelmModuleChip { .init(text: text, kind: .warn) }
    static func bad(_ text: String) -> HelmModuleChip { .init(text: text, kind: .bad) }
    static func mute(_ text: String) -> HelmModuleChip { .init(text: text, kind: .mute) }
}

/// One peek row's state dot (§6.1's "8pt filled circle").
enum HelmModuleRowState {
    case ok, warn, bad, idle

    func color(in theme: HelmTheme) -> NSColor {
        switch self {
        case .ok: return HelmTheme.nsColor(theme.ansiHex[2])
        case .warn: return HelmTheme.nsColor(theme.ansiHex[3])
        case .bad: return HelmTheme.nsColor(theme.ansiHex[1])
        case .idle: return HelmTheme.mutedInk(theme).withAlphaComponent(0.55)
        }
    }
}

/// One row of a `.peekRows` body: a state dot, a truncating line of text, and
/// a right-aligned mono value.
struct HelmModulePeekRow: Equatable {
    let state: HelmModuleRowState
    let text: String
    let value: String

    static func == (lhs: HelmModulePeekRow, rhs: HelmModulePeekRow) -> Bool {
        lhs.text == rhs.text && lhs.value == rhs.value
    }
}

// MARK: - The card

final class HelmModuleCard: NSView {

    /// §6.1's body kinds. `.note` is the one-line form (the table asks for it
    /// by name on Log Analyzer, Tools and Settings) and `.paragraph` is the
    /// wide briefing variant's linked copy.
    enum Body {
        /// A big rounded numeral, an optional unit beside it, an optional
        /// one-line note under it.
        case metric(value: String, unit: String?, note: String?)
        /// Two or three summary rows. More than three is a table, and a
        /// table belongs on the drill page - `maxPeekRows` enforces it.
        case peekRows([HelmModulePeekRow])
        /// A 66pt ring beside a short title and note.
        case ring(value: Int, total: Int, title: String, note: String)
        /// A big numeral over a capsule progress bar.
        case progress(value: Int, total: Int, note: String)
        /// One wrapping line of copy.
        ///
        /// `maxLines` is 2 for every canvas module - a hub widget summarises
        /// rather than explains. Phase 4 slice 6's Tools landing grid is the
        /// one caller that needs more: its plates carry each tool's real
        /// one-sentence description, and two lines truncated most of them.
        /// The card's own `standardHeight` still bounds it (§6.1's body area
        /// is ~100pt, i.e. six caption lines), so this cannot silently
        /// overflow - `DaylightDrillPageSlice6SelfTest` measures the real
        /// need against the real area.
        case note(String, maxLines: Int = 2)
        /// The briefing's linked paragraph. Each clause carries its own
        /// navigation target; a clause with `.none` renders as plain text
        /// rather than as a link that goes nowhere.
        case paragraph([BriefingClause])
    }

    /// §6.1's "2-3 rows". A module that hands over more is showing a table on
    /// the canvas, which is exactly what the design forbids - the extras are
    /// dropped rather than rendered, and the count is what the card's
    /// accessibility label reports.
    static let maxPeekRows = 3

    /// The briefing paragraph's own cap, for the same reason `maxPeekRows`
    /// exists and enforced the same way (the caller truncates; the overflow is
    /// *reported*, never silently dropped - see `HomeCanvasController.
    /// fillBriefing`).
    ///
    /// **Why a cap survives the return of §6.1's wide card, and why the number
    /// went up.** PR #259 introduced this cap for a reason that no longer
    /// applies - the briefing had been narrowed to one column, where an
    /// unbounded paragraph would make its whole grid row as tall as the
    /// longest briefing of the day. The captain has since restored the wide
    /// (span-2) card, so that reason is gone; a *different* one replaces it.
    /// Every card now resolves to `standardHeight`, so a paragraph taller than
    /// the body area would be clipped by the card's own `masksToBounds` with
    /// nothing said about it. The cap is what keeps that from happening, and
    /// `DaylightModuleSelfTest.checkUniformCardHeight` measures a full-cap
    /// paragraph at a real span-2 width to prove the number fits.
    ///
    /// Five rather than three because double width fits roughly twice the copy
    /// per line - measured, not assumed, by that same case.
    ///
    /// Pairs with `maxNarrowBriefingClauses`: `packRows` degrades a span-2 card
    /// to one column in a single-column grid, and the cap has to follow it
    /// down or the paragraph overflows a card that is now half as wide.
    ///
    /// Clauses stay clauses rather than becoming peek rows because each one
    /// carries a real `BriefingTarget` - turning them into rows would throw
    /// the deep links away, which is the one thing on this card that does
    /// something.
    static let maxBriefingClauses = 5

    /// The same cap for a briefing card that `HelmResponsiveGrid.packRows` has
    /// degraded to a single column - a window narrow enough to fit only one
    /// module across.
    ///
    /// Two, not PR #259's three: that number was measured against a card whose
    /// height grew with its content, and this one's does not. Measured rather
    /// than reasoned - the self-test below caught three overflowing a
    /// one-column card by 16pt at GL-32's "Larger" scale, remembering that the
    /// caller appends an overflow line of its own on top of the cap.
    /// `HomeCanvasController.briefingClauseCap(forCardWidth:)` picks between
    /// the two from the width the grid actually built the card for, and
    /// `DaylightModuleSelfTest.checkUniformCardHeight` measures both at every
    /// text scale.
    static let maxNarrowBriefingClauses = 2

    struct Content {
        var title: String
        var subtitle: String
        var symbol: String
        var hue: HelmDomainHue
        var chip: HelmModuleChip?
        var body: Body
    }

    // Geometry (§2.7, §2.6).
    static let ribbonHeight: CGFloat = 6
    static let headerInsetTop: CGFloat = 13
    static let horizontalInset: CGFloat = 16
    static let bodyInsetTop: CGFloat = 10
    static let bodyInsetBottom: CGFloat = 15
    /// §6.1's hover translate. Skipped under Reduce Motion - the shadow swap
    /// alone is acceptable motion, per that section's own note.
    static let hoverLift: CGFloat = 3
    static let hoverDuration: TimeInterval = 0.14

    /// **Every module card is exactly this tall, on every space.**
    ///
    /// The captain's own words on the number were "you can choose the best
    /// size", so here is the reasoning rather than just the value. Left to
    /// their natural heights the six body kinds resolve to visibly different
    /// cards - a `.note` is two lines and a `.progress` is a 34pt numeral over
    /// a bar over a note - which makes each grid row a different height and
    /// the hub read as ragged. One fixed height is what makes the canvas look
    /// like a grid.
    ///
    /// The number is the tallest realistic body plus the card's own chrome,
    /// with a little slack. `.progress` (numeral, bar, two-line note) is the
    /// body that sets the floor; `.peekRows` at its own `maxPeekRows` cap is
    /// close behind. Nothing is *sized* to this constant - each body keeps its
    /// natural height and is top-aligned, so a short one simply leaves room
    /// below it (see `rebuildBody`). `DaylightModuleSelfTest.
    /// checkUniformCardHeight` measures every body kind against the real body
    /// area and fails if any of them stops fitting.
    ///
    /// Safe to be a required constraint, unlike a *width*: this card lives
    /// inside the canvas's scroll view, whose document height is free, so a
    /// vertical constraint here cannot pressure the window's own size the way
    /// AGENTS.md gotcha (13) describes.
    ///
    /// Run through `HelmType.scaled` rather than left a literal, because every
    /// font inside the card is: at GL-32's "Larger" (x1.3) the tallest body
    /// grows past a fixed 176 and would be clipped. A card carries the scale
    /// it was *built* at - `applyTheme` re-themes a card but does not rebuild
    /// its body - which is GL-32's own documented remaining half, and is
    /// consistent either way: an existing card keeps both its old fonts and
    /// its old height, a card built after the change gets both new.
    static var standardHeight: CGFloat { HelmType.scaled(baseStandardHeight) }

    /// `standardHeight` before the chrome text scale, i.e. the measured
    /// number. Kept separate so the self-test can name what it measured.
    static let baseStandardHeight: CGFloat = 176

    /// Fired on click (and on a VoiceOver/keyboard press, via
    /// `HoverHighlightView`'s own press replay).
    var onOpen: (() -> Void)?
    /// Fired when a link inside a `.paragraph` body is clicked, with that
    /// clause's own target.
    var onFollowLink: ((BriefingTarget) -> Void)?

    private let card = HoverHighlightView()
    private let ribbon = CAGradientLayer()
    private let tile = HelmGradientTile(size: .module)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chipView = NSView()
    private let chipLabel = NSTextField(labelWithString: "")
    private let bodyContainer = NSView()

    private var content: Content?
    private var themeToken: ThemeObservation?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var reduceMotionObserver: NSObjectProtocol?

    /// Rebuilt per `configure` - the body is the one part of the card whose
    /// *shape* changes with its content, so it is torn down rather than
    /// mutated. Every other subview is built once here and only re-themed.
    private var bodyViews: [NSView] = []
    private var paragraphView: BriefingParagraphView?
    private var ringGauge: HelmRingGauge?
    private var progressBar: HelmProgressBar?
    private var peekDots: [(dot: NSView, state: HelmModuleRowState)] = []
    private var peekSeparators: [NSView] = []
    private var peekTextLabels: [NSTextField] = []
    private var peekValueLabels: [NSTextField] = []
    private var noteLabels: [NSTextField] = []
    private var metricLabels: [NSTextField] = []
    private var unitLabels: [NSTextField] = []

    #if FM_SELFTESTS
    /// `fm/grandline-daylight-shell-regressions`: a live-instance counter
    /// (incremented in `init`, decremented in `deinit`), independent of
    /// `ThemeManager.observerCountForTests` - direct evidence of whether
    /// cards from *every* rebuild cycle over a long, repeated session
    /// actually deallocate, rather than inferring it from one proxy signal.
    static var debugLiveInstanceCount = 0
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildChrome()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // GL-16: toggling Reduce Motion takes effect immediately rather than
        // at the next hover.
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyHoverState(animated: false) }
        #if FM_SELFTESTS
        Self.debugLiveInstanceCount += 1
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
        }
        #if FM_SELFTESTS
        Self.debugLiveInstanceCount -= 1
        #endif
    }

    // MARK: Build

    private func buildChrome() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The shadow host must not clip, or it casts nothing (§2.5).
        layer?.masksToBounds = false

        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = HelmMetrics.dModule
        card.wantsLayer = true
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(cardClicked)))
        addSubview(card)

        card.layer?.addSublayer(ribbon)
        ribbon.startPoint = HelmDomainHue.ribbonStart
        ribbon.endPoint = HelmDomainHue.ribbonEnd

        titleLabel.font = HelmType.moduleTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = HelmType.captionSmall()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (13)/(14): a label's own >500 compression
        // resistance is a real width floor on every ancestor up to the
        // window. The text column is the one thing in this card that must
        // yield first.
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12): the *stack*-level priority APIs, not the
        // content ones, which are no-ops on a view with no intrinsic size.
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        chipLabel.font = HelmType.chip()
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chipView.wantsLayer = true
        chipView.translatesAutoresizingMaskIntoConstraints = false
        chipView.addSubview(chipLabel)
        chipView.setContentHuggingPriority(.required, for: .horizontal)
        chipView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [tile, textStack, chipView])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = HelmMetrics.s3
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (12)+(13), and the reason this is not merely tidiness: an
        // `NSStackView` resists clipping below its arranged subviews' own
        // minimums at `.defaultHigh` (750) by default, which is above
        // `NSLayoutPriorityWindowSizeStayPut` (500) - so a stack inside a
        // module card is a *window* floor unless it is told to yield. The
        // labels inside already yield; the stack holding them did not.
        // See `compressibleStack` for the rest of them.
        headerRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        headerRow.setHuggingPriority(.defaultLow, for: .horizontal)

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(headerRow)
        card.addSubview(bodyContainer)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The one thing that makes the grid uniform vertically. See
            // `standardHeight` for the number, and why a required *height*
            // is safe here where a required width would not be.
            heightAnchor.constraint(equalToConstant: Self.standardHeight),

            chipLabel.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: 10),
            chipLabel.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -10),
            chipLabel.topAnchor.constraint(equalTo: chipView.topAnchor, constant: 3),
            chipLabel.bottomAnchor.constraint(equalTo: chipView.bottomAnchor, constant: -3),

            headerRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.horizontalInset),
            headerRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.horizontalInset),
            headerRow.topAnchor.constraint(equalTo: card.topAnchor,
                                           constant: Self.ribbonHeight + Self.headerInsetTop),

            bodyContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.horizontalInset),
            bodyContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.horizontalInset),
            bodyContainer.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: Self.bodyInsetTop),
            bodyContainer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.bodyInsetBottom),
        ])
    }

    // MARK: Configure

    func configure(_ content: Content) {
        self.content = content
        tile.configure(symbol: content.symbol, hue: content.hue)
        titleLabel.stringValue = content.title
        subtitleLabel.stringValue = content.subtitle

        if let chip = content.chip {
            chipView.isHidden = false
            chipLabel.stringValue = chip.text
        } else {
            chipView.isHidden = true
            chipLabel.stringValue = ""
        }

        rebuildBody(content.body)

        // GL-16: §6.1's own label spec - "<title>, <subtitle>, <chip text>".
        // Set explicitly rather than left to `HoverHighlightView`'s
        // descendant-label derivation, because a body full of numerals would
        // otherwise be read out before the title.
        var spoken = [content.title, content.subtitle]
        if let chip = content.chip { spoken.append(chip.text) }
        card.accessibilityLabelOverride = spoken.filter { !$0.isEmpty }.joined(separator: ", ")

        applyTheme(ThemeManager.shared.theme)
    }

    private func rebuildBody(_ body: Body) {
        for view in bodyViews { view.removeFromSuperview() }
        bodyViews.removeAll()
        paragraphView = nil
        ringGauge = nil
        progressBar = nil
        peekDots.removeAll()
        peekSeparators.removeAll()
        peekTextLabels.removeAll()
        peekValueLabels.removeAll()
        noteLabels.removeAll()
        metricLabels.removeAll()
        unitLabels.removeAll()

        let content: NSView
        switch body {
        case let .metric(value, unit, note):
            content = buildMetric(value: value, unit: unit, note: note)
        case let .peekRows(rows):
            content = buildPeekRows(Array(rows.prefix(Self.maxPeekRows)))
        case let .ring(value, total, title, note):
            content = buildRing(value: value, total: total, title: title, note: note)
        case let .progress(value, total, note):
            content = buildProgress(value: value, total: total, note: note)
        case let .note(text, maxLines):
            content = buildNote(text, maxLines: maxLines)
        case let .paragraph(clauses):
            content = buildParagraph(clauses)
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(content)
        bodyViews.append(content)
        let bodyBottom = content.bottomAnchor.constraint(lessThanOrEqualTo: bodyContainer.bottomAnchor)
        bodyBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            // `<=`, not `==`, and that is what makes one fixed card height
            // work across six body kinds of different natural sizes: the body
            // keeps its own height, sits at the top of the area, and a short
            // one leaves the slack below it rather than being stretched to
            // fill it (`.fill` on a vertical stack would otherwise pull a
            // two-line note apart). `.defaultHigh` rather than required so
            // that if a body ever *did* outgrow the area, this is the
            // constraint AppKit breaks - not `standardHeight`, and not a
            // label's own height - which keeps the failure to one card
            // instead of deforming the row. Nothing should reach that state:
            // every body kind is capped at the content layer (`maxPeekRows`,
            // `maxBriefingClauses`, `noteLabel`'s two lines) and
            // `DaylightModuleSelfTest.checkUniformCardHeight` measures all of
            // them against the real area.
            bodyBottom,
        ])
    }

    private func metricLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.moduleMetric()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metricLabels.append(label)
        return label
    }

    private func noteLabel(_ text: String, maxLines: Int = 2) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = HelmType.caption()
        label.isSelectable = false
        label.maximumNumberOfLines = max(1, maxLines)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabels.append(label)
        return label
    }

    private func buildMetric(value: String, unit: String?, note: String?) -> NSView {
        let number = metricLabel(value)
        var row: [NSView] = [number]
        if let unit, !unit.isEmpty {
            let unitLabel = NSTextField(labelWithString: unit)
            unitLabel.font = HelmType.metricUnit()
            unitLabel.translatesAutoresizingMaskIntoConstraints = false
            unitLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            unitLabels.append(unitLabel)
            row.append(unitLabel)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.append(spacer)

        let metricRow = compressibleStack(NSStackView(views: row))
        metricRow.orientation = .horizontal
        metricRow.alignment = .lastBaseline
        metricRow.spacing = HelmMetrics.s1 + 2
        metricRow.distribution = .fill
        metricRow.translatesAutoresizingMaskIntoConstraints = false

        var stacked: [NSView] = [metricRow]
        if let note, !note.isEmpty { stacked.append(noteLabel(note)) }
        return verticalStack(stacked, spacing: HelmMetrics.s1 + 2)
    }

    private func buildPeekRows(_ rows: [HelmModulePeekRow]) -> NSView {
        var stacked: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSView()
                separator.wantsLayer = true
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                peekSeparators.append(separator)
                stacked.append(separator)
            }

            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.setContentHuggingPriority(.required, for: .horizontal)
            dot.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            peekDots.append((dot, row.state))

            let text = NSTextField(labelWithString: row.text)
            text.font = HelmType.caption()
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            peekTextLabels.append(text)

            let value = NSTextField(labelWithString: row.value)
            value.font = HelmType.code()
            value.alignment = .right
            value.translatesAutoresizingMaskIntoConstraints = false
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.setContentHuggingPriority(.required, for: .horizontal)
            peekValueLabels.append(value)

            let peek = compressibleStack(NSStackView(views: [dot, text, value]))
            peek.orientation = .horizontal
            peek.alignment = .centerY
            peek.spacing = HelmMetrics.s2
            peek.distribution = .fill
            peek.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
            peek.translatesAutoresizingMaskIntoConstraints = false
            stacked.append(peek)
        }
        if stacked.isEmpty { stacked = [noteLabel("Nothing to show yet.")] }
        return verticalStack(stacked, spacing: 0)
    }

    private func buildRing(value: Int, total: Int, title: String, note: String) -> NSView {
        let ring = HelmRingGauge()
        ring.configure(value: value, total: total)
        ringGauge = ring

        let titleField = NSTextField(labelWithString: title)
        titleField.font = HelmType.rowTitle()
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metricLabels.append(titleField)

        let text = verticalStack([titleField, noteLabel(note)], spacing: 2)
        text.alignment = .leading

        let row = compressibleStack(NSStackView(views: [ring, text]))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func buildProgress(value: Int, total: Int, note: String) -> NSView {
        let number = metricLabel(total > 0 ? "\(value)/\(total)" : "\(value)")
        let bar = HelmProgressBar()
        bar.configure(fraction: total > 0 ? Double(value) / Double(total) : 0)
        progressBar = bar
        return verticalStack([number, bar, noteLabel(note)], spacing: HelmMetrics.s2)
    }

    private func buildNote(_ text: String, maxLines: Int = 2) -> NSView {
        verticalStack([noteLabel(text, maxLines: maxLines)], spacing: 0)
    }

    private func buildParagraph(_ clauses: [BriefingClause]) -> NSView {
        let paragraph = BriefingParagraphView()
        paragraph.onActivate = { [weak self] target in self?.onFollowLink?(target) }
        // `MorningBriefingLocal.statSeparator` is what the deterministic
        // half's fragments join with; the AI half returns whole sentences, so
        // a space is right there. Reusing `MorningBriefingCard`'s own view
        // means the briefing reads identically on the canvas and on Overview.
        paragraph.render(clauses, separator: " ", theme: ThemeManager.shared.theme)
        paragraphView = paragraph
        return verticalStack([paragraph], spacing: 0)
    }

    /// Every horizontal stack inside a card must yield rather than act as a
    /// width floor.
    ///
    /// A card is laid out into whatever column the grid hands it, and the grid
    /// row is `.fillEqually` - so one card refusing to compress does not cap
    /// the window by its own width, it caps it by *column count times* its own
    /// width. That is how a single card with a long note produced a 1135.5pt
    /// floor on every destination at once (`.homeCanvas` is eagerly mounted,
    /// so its constraints are live whichever page is showing - gotcha (11)),
    /// caught by `AppShellBodyWidthSelfTest`.
    ///
    /// Note this is the *stack*-level API: `setContentCompressionResistance-
    /// Priority` is a no-op on a view with no intrinsic content size, which an
    /// `NSStackView` does not have (gotcha (12)).
    private func compressibleStack(_ stack: NSStackView) -> NSStackView {
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for view in views {
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            let trailing = view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            // 499, never required: this chain runs all the way up to the
            // window through the canvas's grid, and a required tie here would
            // let a card's own content set a window-width floor (gotcha #13).
            trailing.priority = HelmDaylightPriority.contentTie
            trailing.isActive = true
        }
        return stack
    }

    // MARK: Hover (§6.1)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyHoverState(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyHoverState(animated: true)
    }

    private func applyHoverState(animated: Bool) {
        let theme = ThemeManager.shared.theme
        applyShadow(theme, raised: isHovering)
        // §6.1: the shadow swap always happens; the 3pt translate is skipped
        // under Reduce Motion, which that section explicitly allows.
        let allowMotion = !HelmMotion.isReduced
        // AppKit's y grows upward in an unflipped view, so lifting a card is a
        // *positive* translate.
        let lift: CGFloat = (isHovering && allowMotion) ? Self.hoverLift : 0
        let transform = CATransform3DMakeTranslation(0, lift, 0)
        guard animated, allowMotion else {
            card.layer?.transform = transform
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hoverDuration
            card.layer?.transform = transform
        }
    }

    #if FM_SELFTESTS
    /// Drives the real hover path (`applyHoverState`) so a self-test can
    /// measure the resulting transform in both Reduce Motion states.
    func debugSetHovering(_ hovering: Bool, animated: Bool = false) {
        isHovering = hovering
        applyHoverState(animated: animated)
    }

    /// The hover transform actually applied to the card's own layer.
    var debugCardTransform: CATransform3D { card.layer?.transform ?? CATransform3DIdentity }

    /// The card's inner activatable view, so the accessibility suite can
    /// assert the role/label/press contract on the thing that carries it.
    var debugCardHitView: HoverHighlightView { card }
    #endif

    // MARK: Layout and theme

    #if FM_SELFTESTS
    /// How many times `layout()` has actually run for this card instance -
    /// `AppShellBodyWidthSelfTest.test_moduleCardLayoutRunsOnceForOneRequest`'s
    /// evidence that a single logical layout request settles rather than
    /// re-triggering itself (a real, if not-yet-observed, mechanism for
    /// sustained CPU - see that test's own doc comment).
    var debugLayoutCallCount = 0
    #endif

    override func layout() {
        super.layout()
        #if FM_SELFTESTS
        debugLayoutCallCount += 1
        #endif
        // A standalone sublayer's `frame` change animates implicitly, so a
        // window resize would slide the ribbon into place behind the card's
        // own instant relayout - see `HelmMotion`'s header, finding 2.
        HelmMotion.withoutImplicitAnimation {
            ribbon.frame = CGRect(x: 0, y: card.bounds.height - Self.ribbonHeight,
                                  width: card.bounds.width, height: Self.ribbonHeight)
        }
        for label in noteLabels { label.preferredMaxLayoutWidth = bodyContainer.bounds.width }
        applyShadow(ThemeManager.shared.theme, raised: isHovering)
    }

    private func applyShadow(_ theme: HelmTheme, raised: Bool) {
        guard let layer else { return }
        let shadow = HelmCard.elevation(for: theme, level: raised ? .raised : .resting)
        layer.shadowColor = (shadow.shadowColor ?? .black).cgColor
        layer.shadowOpacity = Float(shadow.shadowColor?.alphaComponent ?? 0.1)
        layer.shadowRadius = shadow.shadowBlurRadius
        layer.shadowOffset = CGSize(width: shadow.shadowOffset.width, height: shadow.shadowOffset.height)
        layer.shadowPath = CGPath(roundedRect: bounds,
                                  cornerWidth: HelmMetrics.dModule,
                                  cornerHeight: HelmMetrics.dModule,
                                  transform: nil)
    }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        card.normalColor = surface
        card.hoverColor = surface
        card.layer?.backgroundColor = surface.cgColor
        card.layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor

        let pair = (content?.hue ?? .blue).pair(in: theme)
        HelmMotion.withoutImplicitAnimation {
            ribbon.colors = [pair.h1.cgColor, pair.h2.cgColor]
        }

        titleLabel.font = HelmType.moduleTitle()
        titleLabel.textColor = ink
        subtitleLabel.font = HelmType.captionSmall()
        subtitleLabel.textColor = muted

        if let chip = content?.chip {
            ToolRowLayout.pill(text: chip.text, colorHex: chip.kind.hex(in: theme),
                               into: chipView, label: chipLabel, theme: theme)
            chipLabel.font = HelmType.chip()
        }

        for label in metricLabels { label.textColor = ink }
        for label in unitLabels { label.textColor = muted }
        for label in noteLabels { label.textColor = muted }
        for label in peekTextLabels { label.textColor = ink }
        for label in peekValueLabels { label.textColor = muted }
        for separator in peekSeparators {
            separator.layer?.backgroundColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.5).cgColor
        }
        for (dot, state) in peekDots { dot.layer?.backgroundColor = state.color(in: theme).cgColor }

        ringGauge?.applyTheme(theme, hue: content?.hue ?? .green)
        progressBar?.applyTheme(theme, hue: content?.hue ?? .amber)
        paragraphView?.applyTheme(theme)
        applyShadow(theme, raised: isHovering)
    }

    @objc private func cardClicked() { onOpen?() }

    // MARK: Probe / self-test surface

    struct Anatomy {
        let hasRibbon: Bool
        let ribbonHeight: CGFloat
        let ribbonStopCount: Int
        let cornerRadius: CGFloat
        let cardClipsToBounds: Bool
        let shadowHostClipsToBounds: Bool
        let borderWidth: CGFloat
        let hasTile: Bool
        let title: String
        let subtitle: String
        let chipText: String?
        let isCardActivatable: Bool
        let accessibilityLabel: String?
        let peekRowCount: Int
        /// Every `note`-styled line the body rendered, in order. Enough to
        /// tell a loading state from real content without exposing the body
        /// enum itself.
        let noteTexts: [String]
        /// Every big-number / metric-styled line the body rendered.
        let metricTexts: [String]
        /// The height the card actually resolved to - `standardHeight` in
        /// every case, which is the whole point of the constant.
        let cardHeight: CGFloat
        /// The body area this card gives its content, after the ribbon,
        /// header and both body insets.
        let bodyAreaHeight: CGFloat
        /// What the body actually needs. Greater than `bodyAreaHeight` means
        /// this body kind has outgrown `standardHeight` and would be clipped.
        let bodyContentHeight: CGFloat
    }

    var anatomyForTests: Anatomy {
        Anatomy(hasRibbon: ribbon.superlayer != nil,
                ribbonHeight: Self.ribbonHeight,
                ribbonStopCount: ribbon.colors?.count ?? 0,
                cornerRadius: card.layer?.cornerRadius ?? 0,
                cardClipsToBounds: card.layer?.masksToBounds ?? false,
                shadowHostClipsToBounds: layer?.masksToBounds ?? true,
                borderWidth: card.layer?.borderWidth ?? 0,
                hasTile: tile.geometryForTests.hasImage,
                title: titleLabel.stringValue,
                subtitle: subtitleLabel.stringValue,
                chipText: chipView.isHidden ? nil : chipLabel.stringValue,
                isCardActivatable: card.isActivatable,
                accessibilityLabel: card.accessibilityLabelOverride,
                peekRowCount: peekTextLabels.count,
                noteTexts: noteLabels.map(\.stringValue),
                metricTexts: metricLabels.map(\.stringValue),
                cardHeight: frame.height,
                bodyAreaHeight: bodyContainer.frame.height,
                bodyContentHeight: bodyViews.first?.fittingSize.height ?? 0)
    }

    /// Fires the card's real click path, exactly as a mouse click or a
    /// VoiceOver press would.
    @discardableResult
    func debugActivate() -> Bool { card.performPrimaryAction() }
}

// MARK: - Priorities

/// The one place this migration's constraint priorities are named.
///
/// AGENTS.md gotcha (13), restated because Phase 2 introduces a *lot* of new
/// content chained up to `bodyContainer`: a window only holds its own size at
/// `NSLayoutPriorityWindowSizeStayPut` (500), so **any** content constraint
/// above 500 is a potential window-size cap. Everything the bar and the
/// canvas add that could otherwise set a width floor uses `contentTie`.
enum HelmDaylightPriority {
    /// Just under 500. High enough to beat a stack's own defaults, low enough
    /// that the window's own size always wins.
    static let contentTie = NSLayoutConstraint.Priority(499)
}

// MARK: - Gauges (§6.8)

/// A 66pt ring: an `inset` track and a hue-coloured value arc, starting at 12
/// o'clock and running clockwise, with a rounded-numeral centre label.
///
/// `CAShapeLayer` arcs rather than a conic gradient - §6.8 says so explicitly,
/// and a stroked path is both cheaper and exactly what the design shows.
final class HelmRingGauge: NSView {
    static let side: CGFloat = 66
    static let lineWidth: CGFloat = 7

    private let track = CAShapeLayer()
    private let value = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var fraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        for shape in [track, value] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        label.font = HelmType.rounded(HelmType.scaled(15), .heavy)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(value current: Int, total: Int) {
        fraction = total > 0 ? min(1, max(0, Double(current) / Double(total))) : 0
        label.stringValue = total > 0 ? "\(current)/\(total)" : "\u{2014}"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = Self.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(rect.width, rect.height) / 2
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let full = CGMutablePath()
        full.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        track.path = full
        track.frame = bounds

        // 12 o'clock is +pi/2 in AppKit's unflipped space; clockwise on screen
        // means decreasing angle, which is `clockwise: true` here.
        let start = CGFloat.pi / 2
        let arc = CGMutablePath()
        if fraction > 0 {
            arc.addArc(center: centre, radius: radius,
                       startAngle: start,
                       endAngle: start - CGFloat(fraction) * .pi * 2,
                       clockwise: true)
        }
        value.path = arc
        value.frame = bounds
    }

    func applyTheme(_ theme: HelmTheme, hue: HelmDomainHue) {
        let trackColor = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6)
        track.strokeColor = trackColor.cgColor
        value.strokeColor = hue.baseColor(in: theme).cgColor
        label.font = HelmType.rounded(HelmType.scaled(15), .heavy)
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
    }

    // MARK: Probe / self-test surface

    var fractionForTests: Double { fraction }
    var centreLabelForTests: String { label.stringValue }
}

/// §6.8's capsule progress bar: an `inset` track with a hue-gradient fill.
final class HelmProgressBar: NSView {
    static let height: CGFloat = 8

    private let fill = CAGradientLayer()
    private var fraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        fill.startPoint = HelmDomainHue.ribbonStart
        fill.endPoint = HelmDomainHue.ribbonEnd
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(fraction: Double) {
        self.fraction = min(1, max(0, fraction))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // `HelmMetrics.dCapsule` is a sentinel, never a real corner - clamp to
        // half the shorter side, which is what makes a capsule a capsule.
        layer?.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: bounds.height)
    }

    func applyTheme(_ theme: HelmTheme, hue: HelmDomainHue) {
        layer?.backgroundColor = (theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6)).cgColor
        let pair = hue.pair(in: theme)
        HelmMotion.withoutImplicitAnimation {
            fill.colors = [pair.h1.cgColor, pair.h2.cgColor]
        }
    }

    var fractionForTests: Double { fraction }
}
