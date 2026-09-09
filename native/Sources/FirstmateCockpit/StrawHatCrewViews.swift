// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates **phase 2**: the two views the crew added to the chat
// pane - the portrait tile (milestone M2.4) and the confirm card (M2.2).
//
// Split from `StrawHatChatView` for the reason GL-36 split `ConsoleController`
// and `FleetController+Crew`: that file is already ~800 lines of transcript
// and composer. The Swift consequence is the same - `private` is file-scoped,
// so anything these reach on each other is `internal`.
//
// ## The portrait tile, and why the glow means something
//
// M2.4 asks for "portrait tiles for each speaking crew member plus a
// contributing glow while that voice is actively part of the current reply".
// Two decisions inside that:
//
// **The glow is state, so it lives where state changes.** A glow parked on
// the newest reply block forever would stop meaning anything by the second
// turn - it would just be how a reply block looks. So the reply block's own
// portrait is *static* (it is an identity - who said this), and the glow
// lives on a **crew strip** above the transcript, where a member is lit when
// they contributed to the most recent reply and dim otherwise. That changes
// every turn, which is the only way "contributing" is a fact rather than
// decoration. It also makes the roster discoverable: phase 1 could only say
// "Luffy is the only crew member aboard" in a subtitle, and four faces say
// who is aboard far better than a sentence.
//
// **It never claims a voice spoke when it did not.** The strip is driven from
// the parsed sections of the reply that actually landed, so an unattributed
// (rung-2) section lights nobody. While a turn is in flight every member is
// dim - the app genuinely does not know yet who will answer, and lighting a
// guess would be exactly the plausible-but-wrong this feature's own honesty
// rules exist to prevent.
//
// The pulse is `LockScreenController.addLoopingAnimations`' technique - a
// `CAKeyframeAnimation` on the ring layer - and is gated on
// `HelmMotion.isReduced` the way every looping animation in this app is:
// Reduce Motion gets the end state (lit, ring at full strength) instantly,
// never the same motion slower.
//
// ## The confirm card
//
// One card per validated proposal, and pressing its button is the *only*
// thing in this feature that writes. The card owns its own confirmed state
// so a second press cannot double-write: on success the button is removed
// outright rather than disabled, because a disabled button that used to say
// "Add task" reads as "this failed" rather than "this is done".
//
// The card reports the press up through a closure and renders whatever
// outcome comes back - it holds no store and cannot write on its own. Same
// seam `StrawHatChatView` documents for the transcript.

import AppKit

/// Suppresses Core Animation's implicit animation for a standalone-sublayer
/// write, **unconditionally**.
///
/// Deliberately not `HelmMotion.withoutImplicitAnimation`, which is
/// Reduce-Motion-*gated* on purpose: that helper exists for the Daylight
/// gradient layers, whose cross-fade is an established look this app has
/// shipped and screenshotted since its own Phase 1. Nothing of the sort
/// applies to a ring layer's `frame` tracking a window resize - that is the
/// defect AGENTS.md records for a standalone layer ("a window resize slid the
/// ribbon behind the card's own instant relayout"), and it has to be instant
/// whether or not Reduce Motion is on.
private func strawHatWithoutImplicitAnimation(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

/// A crew member's face, at a size the transcript and the strip both use.
///
/// Falls back to the member's SF Symbol (through the app's own
/// `IconTileView`) when the portrait cannot be decoded - so a bad
/// regeneration of `StrawHatPortraits.swift` degrades to phase 1's glyph
/// rather than to a blank hole. Exactly one of the two is ever in the view
/// tree, decided once at init, which is the "build both, show one" pattern
/// `HelmEmptyState`/`HelmAccentRow` already use for their own glyph-vs-tile
/// choice.
final class StrawHatPortraitTile: NSView {

    /// The transcript's reply-header size, and the strip's.
    static let replySize: CGFloat = 26
    static let stripSize: CGFloat = 32

    private let member: StrawHatMember
    private let side: CGFloat
    /// The ring is its own layer rather than this view's border, because the
    /// pulse animates the ring alone - animating `borderWidth` on the view
    /// that also clips the image would fight the mask.
    private let ring = CALayer()
    private var imageView: NSImageView?
    private var fallback: IconTileView?
    private var isLit = false

    init(member: StrawHatMember, side: CGFloat) {
        self.member = member
        self.side = side
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // `masksToBounds` on the *container* would clip the ring too. The
        // image view does its own clipping instead.
        layer?.masksToBounds = false

        if let portrait = StrawHatPortraits.image(for: member) {
            let view = NSImageView()
            view.image = portrait
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = side / 2
            view.layer?.masksToBounds = true
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            imageView = view
        } else {
            let tile = IconTileView(size: side, cornerRadius: side / 2)
            tile.configure(symbol: member.symbol, tint: member.tint, pointSize: side * 0.45)
            addSubview(tile)
            NSLayoutConstraint.activate([
                tile.leadingAnchor.constraint(equalTo: leadingAnchor),
                tile.trailingAnchor.constraint(equalTo: trailingAnchor),
                tile.topAnchor.constraint(equalTo: topAnchor),
                tile.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            fallback = tile
        }

        ring.borderWidth = 1.5
        ring.cornerRadius = side / 2
        layer?.addSublayer(ring)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // The ring is a plain sublayer, so it needs its frame set by hand -
        // and without an implicit-animation guard a resize slides it, which is
        // motion nobody designed (the same trap AGENTS.md records for the
        // Daylight gradient layers).
        strawHatWithoutImplicitAnimation {
            ring.frame = bounds
        }
    }

    /// `lit` is the "contributed to the most recent reply" state - see this
    /// file's header. A dim tile keeps its face at reduced opacity rather than
    /// disappearing: the strip's job is to show who is aboard as well as who
    /// just spoke.
    func setLit(_ lit: Bool, theme: HelmTheme) {
        isLit = lit
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        fallback?.applyTheme(theme)
        let tint = member.accentColor(in: theme)
        strawHatWithoutImplicitAnimation {
            ring.borderColor = tint.withAlphaComponent(isLit ? 0.95 : 0.28).cgColor
            ring.shadowColor = tint.cgColor
            ring.shadowOffset = .zero
            ring.shadowRadius = isLit ? 5 : 0
            ring.shadowOpacity = isLit ? 0.55 : 0
        }
        alphaValue = isLit ? 1.0 : 0.45
        updatePulse()
    }

    private func updatePulse() {
        // Reduce Motion gets the end state, instantly - never the same motion
        // slower. `HelmMotion` is the app's one gate for this; a direct
        // `NSWorkspace` read here would be a self-test failure.
        guard isLit, !HelmMotion.isReduced else {
            ring.removeAnimation(forKey: "contributing")
            return
        }
        guard ring.animation(forKey: "contributing") == nil else { return }
        let pulse = CAKeyframeAnimation(keyPath: "shadowOpacity")
        pulse.values = [0.25, 0.7, 0.25]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 2.2
        pulse.repeatCount = .infinity
        pulse.calculationMode = .cubic
        ring.add(pulse, forKey: "contributing")
    }

    #if FM_SELFTESTS
    var debugIsLit: Bool { isLit }
    /// Whether the pulse is actually attached - the only way to prove the
    /// Reduce Motion gate from outside, since a gate that is read and then
    /// ignored looks identical from every other angle.
    var debugIsPulsing: Bool { ring.animation(forKey: "contributing") != nil }
    var debugUsesPortrait: Bool { imageView != nil }
    #endif
}

/// The strip of every crew member aboard, above the transcript.
final class StrawHatCrewStrip: NSView {

    private var tiles: [StrawHatMember: StrawHatPortraitTile] = [:]
    private let caption = NSTextField(labelWithString: "")
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = []
        for member in StrawHatMember.allCases {
            let tile = StrawHatPortraitTile(member: member, side: StrawHatPortraitTile.stripSize)
            tile.toolTip = "\(member.displayName) \u{00B7} \(member.role)"
            tiles[member] = tile
            views.append(tile)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = HelmMetrics.s2
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        caption.font = HelmType.captionSmall()
        caption.lineBreakMode = .byTruncatingTail
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let outer = NSStackView(views: [row, caption])
        outer.orientation = .horizontal
        outer.spacing = HelmMetrics.s2 + 2
        outer.alignment = .centerY
        outer.distribution = .fill
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContributors([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Lights exactly the members who spoke in the reply that just landed.
    /// An empty set dims everyone, which is the correct state both before the
    /// first reply and while a turn is in flight.
    func setContributors(_ members: Set<StrawHatMember>) {
        for (member, tile) in tiles {
            tile.setLit(members.contains(member), theme: theme)
        }
        if members.isEmpty {
            caption.stringValue = "\(StrawHatMember.allCases.count) crew aboard"
        } else {
            let names = StrawHatMember.allCases
                .filter { members.contains($0) }
                .map(\.displayName)
                .joined(separator: ", ")
            caption.stringValue = names.count > 1 ? "\(names) replied" : "\(names) replied"
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        caption.textColor = HelmTheme.mutedInk(theme)
        tiles.values.forEach { $0.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    func debugTile(_ member: StrawHatMember) -> StrawHatPortraitTile? { tiles[member] }
    var debugLitMembers: Set<StrawHatMember> {
        Set(tiles.filter { $0.value.debugIsLit }.keys)
    }
    var debugCaption: String { caption.stringValue }
    #endif
}

/// One navigation handoff, rendered as a link row rather than a confirm card
/// (phase 3, M3.2).
///
/// ## Why this is a different view from `StrawHatConfirmCard`
///
/// A handoff writes nothing - it selects a page the captain could have
/// reached from the nav - so a card with a *confirm* button in front of it
/// would be a modal in front of a link, and would teach the captain that the
/// confirm button sometimes means "this changes nothing". Keeping the two
/// visually distinct is what keeps a confirm press meaningful: a card means
/// something is about to be written, a link means the app is about to move.
///
/// ## Why it is a `HelmButton`, and not a hand-rolled clickable row
///
/// `.quiet` is this app's own link weight, and going through the shared
/// button buys the whole accessibility contract for free - a real `.button`
/// role, a keyboard/VoiceOver press, an exterior focus ring, and theming
/// that follows every one of the fourteen palettes. GL-16's own sweep
/// exists because ~40 hand-rolled clickable rows in this app were invisible
/// to VoiceOver; this is not the place to add a forty-first.
///
/// The button sits in a plain container pinned leading-with-a-`<=`-trailing
/// rather than being width-tied, because a `HelmButton` stretched to a
/// block's full width reads as a primary action bar rather than a link -
/// and because `HelmButton.init` calls `sizeToFit()` without clearing
/// `translatesAutoresizingMaskIntoConstraints` (AGENTS.md's documented trap),
/// so it needs that cleared and `.required` hugging either way.
final class StrawHatHandoffRow: NSView {

    /// Fires on the press. Returns a message to surface, or nil when the
    /// navigation simply happened and the app has already moved - there is
    /// nothing to say about a link that worked.
    var onActivate: ((StrawHatHandoff) -> String?)?

    private let handoff: StrawHatHandoff
    private let kind: StrawHatProposalKind
    private let button: HelmButton
    /// Only ever shown when a handoff could *not* be followed - "you have no
    /// live session on that host". Hidden otherwise, because a link that
    /// worked has already taken the captain somewhere else.
    private let noteLabel = NSTextField(labelWithString: "")
    private var theme: HelmTheme

    init(handoff: StrawHatHandoff, kind: StrawHatProposalKind, theme: HelmTheme) {
        self.handoff = handoff
        self.kind = kind
        self.theme = theme
        self.button = HelmButton(title: handoff.title, variant: .quiet, size: .small, symbol: kind.symbol)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(activate)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.toolTip = "Goes to \(kind.destination). Nothing is written."

        noteLabel.font = HelmType.captionSmall()
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 2
        noteLabel.isHidden = true
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(button)
        addSubview(noteLabel)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            // `<=`, never a width tie - see this class's own note above.
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            noteLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            noteLabel.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 2),
            noteLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func activate() {
        guard let onActivate else {
            show(note: "This chat isn't connected to the rest of the app right now.")
            return
        }
        if let note = onActivate(handoff) {
            show(note: note)
        } else {
            // The app moved. Nothing to say, and the row is no longer on
            // screen anyway.
            noteLabel.isHidden = true
        }
    }

    private func show(note: String) {
        noteLabel.stringValue = note
        noteLabel.isHidden = false
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // A refusal is the only thing this label ever says, so it takes the
        // contrast-corrected warn hue rather than plain muted ink - and
        // through `legibleTintedText`, because a `HelmTint` is safe as a fill
        // and is not automatically safe as text (the section 5.7 defect this
        // codebase has fixed four times).
        noteLabel.textColor = HelmContrast.legibleTintedText(
            tintHex: HelmTint.warn.hex(in: theme),
            over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
        // `button` is a `HelmButton` and themes itself - never set its font,
        // `attributedTitle`, `contentTintColor` or `isBordered` from here.
    }

    #if FM_SELFTESTS
    var debugHandoff: StrawHatHandoff { handoff }
    var debugButton: HelmButton { button }
    var debugTitle: String { button.title }
    var debugNote: String { noteLabel.isHidden ? "" : noteLabel.stringValue }
    /// The row must never stretch its own button to full width - a link that
    /// looks like a primary action bar is the defect this class's header
    /// describes.
    var debugFrames: String { "row=\(frame.width) button=\(button.frame.width)" }
    #endif
}

/// One proposed write, rendered as a card the captain confirms.
///
/// Holds no store: the press goes up through `onConfirm`, which returns what
/// actually happened. See this file's header.
final class StrawHatConfirmCard: NSView {

    /// Called on the captain's press. Returns the outcome so the card can
    /// render it - a synchronous call because every write behind it is a
    /// synchronous store method on the main thread.
    var onConfirm: ((StrawHatProposal) -> StrawHatProposalOutcome)?

    private let proposal: StrawHatProposal
    private let icon: IconTileView
    private let kicker = NSTextField(labelWithString: "")
    private let titleLabel: NSTextField
    private let detailLabel = NSTextField(labelWithString: "")
    private let confirmButton: HelmButton
    /// Shown in the button's place once written. A separate label rather than
    /// a disabled button - see this file's header.
    private let doneLabel = NSTextField(labelWithString: "")
    private let actionColumn = NSView()
    private let textColumn = NSStackView()
    private var theme: HelmTheme
    private var isConfirmed = false
    private var didFail = false
    /// `.openedForReview` landed - a distinct third state from `isConfirmed`
    /// (nothing has been written) and `didFail` (nothing went wrong either).
    /// Styled with the accent hue rather than the "written" green, so the
    /// card never implies a write that has not happened yet - the editor's
    /// own Save is what decides that, entirely independent of this card.
    private var openedForReview = false

    init(proposal: StrawHatProposal, theme: HelmTheme, now: Date = Date()) {
        self.proposal = proposal
        self.theme = theme
        self.icon = IconTileView(size: 24, cornerRadius: 7)
        self.titleLabel = NSTextField(wrappingLabelWithString: proposal.title)
        self.confirmButton = HelmButton(title: proposal.kind.confirmTitle, variant: .primary, size: .small)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rRow
        layer?.borderWidth = 1

        icon.configure(symbol: proposal.kind.symbol, tint: .accent, pointSize: 12)

        kicker.attributedStringValue = NSAttributedString(
            string: proposal.kind.label.uppercased(),
            attributes: [.font: HelmType.kicker(), .kern: HelmType.kickerKern])
        kicker.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.isSelectable = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Without this the title is a window-width floor, gotcha (13) - one
        // long unbroken token in a proposed title would cap the whole app.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.stringValue = proposal.detail(now: now)
        detailLabel.font = HelmType.captionSmall()
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        doneLabel.font = HelmType.captionSmall()
        doneLabel.translatesAutoresizingMaskIntoConstraints = false
        doneLabel.isHidden = true
        doneLabel.lineBreakMode = .byTruncatingTail

        // AGENTS.md's documented `HelmButton` trap, and the root cause of a
        // real defect this card shipped in draft: `HelmButton.init` calls
        // `sizeToFit()` and deliberately does *not* clear this flag, because
        // everywhere else in this app it lands in an `NSStackView`, which
        // clears it for you. Here it goes into a plain `NSView`, so AppKit
        // synthesises **required** frame constraints from that fitted size and
        // they silently beat every explicit constraint - pinning the action
        // column to the button's 53pt and truncating the wider confirmed
        // label to "\u{2713} Adde\u{2026}". Measured (col=53, label needed 93.5)
        // rather than reasoned about; no `NSLayoutConstraint` warning fires.
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)
        confirmButton.toolTip = "Writes to \(proposal.kind.destination). Nothing happens until you click."
        confirmButton.setContentHuggingPriority(.required, for: .horizontal)
        confirmButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The action column is as wide as the *wider* of the two states, and
        // stays that width when they swap - so a confirmed card neither
        // truncates its own label nor reflows the cards beside it.
        //
        // An earlier version pinned the button to both of the column's edges,
        // which fixed the column at the button's width and truncated the
        // longer confirmed label to "\u{2713} Adde\u{2026}" - caught in a real
        // off-screen render, not by reading the code. Both children are
        // trailing-pinned with a `>=` leading edge, and the column is
        // explicitly at least as wide as each of them.
        actionColumn.translatesAutoresizingMaskIntoConstraints = false
        actionColumn.addSubview(confirmButton)
        actionColumn.addSubview(doneLabel)
        doneLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        doneLabel.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            confirmButton.trailingAnchor.constraint(equalTo: actionColumn.trailingAnchor),
            confirmButton.leadingAnchor.constraint(greaterThanOrEqualTo: actionColumn.leadingAnchor),
            confirmButton.centerYAnchor.constraint(equalTo: actionColumn.centerYAnchor),
            doneLabel.trailingAnchor.constraint(equalTo: actionColumn.trailingAnchor),
            doneLabel.leadingAnchor.constraint(greaterThanOrEqualTo: actionColumn.leadingAnchor),
            doneLabel.centerYAnchor.constraint(equalTo: actionColumn.centerYAnchor),
            actionColumn.widthAnchor.constraint(greaterThanOrEqualTo: confirmButton.widthAnchor),
            actionColumn.widthAnchor.constraint(greaterThanOrEqualTo: doneLabel.widthAnchor),
            actionColumn.heightAnchor.constraint(greaterThanOrEqualTo: confirmButton.heightAnchor),
        ])
        // AGENTS.md gotcha (12), in its most-repeated form: a plain `NSView`
        // has **no intrinsic content size**, so a content hugging priority on
        // it is a documented no-op - and under `.fill` the stack then picks it
        // as the stretch target. Measured on the real card: the action column
        // absorbed ~700pt of a 998pt row while the text column sat at its
        // minimum, wrapping "Ask Rahul about / the Cognito / configuration"
        // over three lines and truncating the detail to "Tasks \u{00B7} To\u{2026}"
        // with a wide empty gap beside it. `ToolRowLayout` measured the exact
        // same shape (919pt of 1056) before its own fix.
        //
        // What holds a no-intrinsic-size view at its content width is a real
        // `width == 0` constraint *below* the required `>=` ones above, so the
        // solver collapses it to the widest of its children and nothing more -
        // the same "a spacer that must stay collapsed needs a real width
        // constraint, not a hugging priority" rule. `.fill` then has only the
        // text column left to give the slack to.
        let collapseAction = actionColumn.widthAnchor.constraint(equalToConstant: 0)
        // 499, not `.defaultLow`. At 250 this *ties* with the text column's own
        // 250 hugging and the solver is free to pick either - measured, it
        // picked wrong: the action column resolved to 871pt of a 998pt card
        // while the text column sat at 67. 499 breaks the tie in the one
        // direction that is correct here, and stays below
        // `NSLayoutPriorityWindowSizeStayPut` (500) so this card can never
        // drive the window's own size (gotcha (13)). The required `>=`
        // constraints above still win, so the column never collapses below
        // whichever of its two children is showing.
        collapseAction.priority = NSLayoutConstraint.Priority(499)
        collapseAction.isActive = true

        for v in [kicker, titleLabel, detailLabel] { textColumn.addArrangedSubview(v) }
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 2
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        // A vertical `NSStackView`'s `.leading` alignment left-aligns its
        // children at their **own intrinsic width** - it does not stretch them
        // to the stack's width the way `.fill` or an explicit tie does
        // (AGENTS.md records this for `ShiftEmptyStateView` and the quota
        // popover). For a wrapping label with `.defaultLow` compression
        // resistance that means it collapses and wraps early, which a real
        // render showed as "Ask Rahul about / the Cognito / configuration"
        // over three lines with a wide empty gap beside it. Tying each child
        // to the column gives the label a definite width, so it wraps only
        // when the text genuinely does not fit.
        for child in [kicker, titleLabel, detailLabel] {
            child.widthAnchor.constraint(equalTo: textColumn.widthAnchor).isActive = true
        }
        // `setHuggingPriority`, not the content-priority API: this is an
        // `NSStackView`, which has no intrinsic content size, so the content
        // form is a documented no-op on it (gotcha (12)).
        textColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setClippingResistancePriority(.defaultLow, for: .horizontal)

        // Explicit constraints, not an `NSStackView`.
        //
        // This row is the three-column shape `ToolRowLayout` also ended up
        // laying out by hand, for the same measured reason: with `.fill`,
        // *which* view absorbs the slack is decided by hugging priorities, and
        // two of these three columns are views with no intrinsic content size
        // (a plain `NSView` and a nested stack), where those priorities are a
        // documented no-op (gotcha (12)). Two successive attempts to express
        // "the text column takes the slack" through priorities were measured
        // wrong on a real render - first the action column absorbed ~700pt of a
        // 998pt row, then a low-priority `width == 0` on it was outranked by
        // the stack's own stretch constraint - each time wrapping the title
        // over three lines and truncating the detail beside a wide empty gap.
        //
        // Pinning all three edges removes the question: the icon is fixed at
        // the leading edge, the action column is fixed at the trailing edge and
        // sized by its own children, and the text column is *whatever is left*
        // between them. Nothing has to agree about who yields.
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(textColumn)
        addSubview(actionColumn)
        let gap = HelmMetrics.s2
        let inset = HelmMetrics.s2 + 2
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            textColumn.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: gap),
            textColumn.trailingAnchor.constraint(equalTo: actionColumn.leadingAnchor, constant: -gap),
            textColumn.topAnchor.constraint(equalTo: topAnchor, constant: gap),
            textColumn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gap),

            actionColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            actionColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The card is never shorter than its own action control.
            heightAnchor.constraint(greaterThanOrEqualTo: actionColumn.heightAnchor, constant: gap * 2),
        ])
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func confirmTapped() {
        // Guarded as well as visually removed: a keyboard activation racing
        // the rebuild would otherwise be a second write.
        guard !isConfirmed, !openedForReview, let onConfirm else { return }
        switch onConfirm(proposal) {
        case .written:
            isConfirmed = true
            didFail = false
            confirmButton.isHidden = true
            doneLabel.isHidden = false
            doneLabel.stringValue = "\u{2713} \(proposal.kind.confirmedTitle)"
            // The detail line is deliberately left alone. An earlier version
            // replaced it with the toast's own message, which both duplicated
            // the toast a few points away and threw away the one thing the
            // card still usefully states - the due date it was about to write
            // ("Tasks \u{00B7} Tomorrow"). The confirmation is the done
            // label's job; the detail's job is to say what the record is.
        case .failed(let message):
            // The button stays, because a retry is the useful next action.
            didFail = true
            detailLabel.stringValue = message
        case .openedForReview(let message):
            // Not `.written`: nothing has been saved by this card, only
            // handed to a captain-facing editor. The button is hidden anyway
            // - re-opening a second copy of the same editor for one proposal
            // is not a useful retry the way it is for `.failed`.
            openedForReview = true
            didFail = false
            confirmButton.isHidden = true
            doneLabel.isHidden = false
            doneLabel.stringValue = message
        }
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        icon.applyTheme(theme)
        layer?.backgroundColor = HelmField.fill(theme).cgColor
        let accent = HelmTheme.nsColor(theme.accentHex)
        layer?.borderColor = (isConfirmed || openedForReview)
            ? HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
            : accent.withAlphaComponent(0.45).cgColor
        kicker.textColor = HelmTheme.mutedInk(theme)
        titleLabel.textColor = HelmField.ink(theme)
        // `legibleTintedText` rather than the raw hue: a `HelmTint` is safe as
        // a fill and is NOT automatically safe as text - the §5.7 defect this
        // codebase has fixed four separate times. It takes a hex, so the tint
        // is resolved against the active theme first.
        let fill = HelmField.fill(theme)
        detailLabel.textColor = didFail
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: fill, theme: theme)
            : HelmField.mutedInk(theme)
        // `.openedForReview` takes the accent hue rather than `.good`'s green
        // - green would read as "this was written", which is exactly the
        // claim this state must not make (nothing has been saved yet).
        doneLabel.textColor = openedForReview
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.accent.hex(in: theme), over: fill, theme: theme)
            : HelmContrast.legibleTintedText(tintHex: HelmTint.good.hex(in: theme), over: fill, theme: theme)
    }

    #if FM_SELFTESTS
    var debugProposal: StrawHatProposal { proposal }
    var debugIsConfirmed: Bool { isConfirmed }
    var debugOpenedForReview: Bool { openedForReview }
    var debugConfirmButton: HelmButton { confirmButton }
    var debugConfirmButtonHidden: Bool { confirmButton.isHidden }
    var debugDetailText: String { detailLabel.stringValue }
    var debugDoneText: String { doneLabel.stringValue }
    /// The label itself, so a suite can measure whether it has room for its
    /// own text - a truncated string is correct in every value assertion.
    var debugDoneLabel: NSTextField { doneLabel }
    var debugTitleLabel: NSTextField { titleLabel }
    var debugActionColumnWidth: CGFloat { actionColumn.frame.width }
    /// A compact dump of the row's three resolved columns, for a failure
    /// message. Two separate attempts to get this row's slack distribution
    /// right were diagnosed in one run each because the message carried the
    /// real numbers - AGENTS.md's own "reported the exact 33.5" standard.
    var debugFrames: String {
        "card=\(frame.width) icon=\(icon.frame) text=\(textColumn.frame) action=\(actionColumn.frame) title=\(titleLabel.frame.width)/intr=\(titleLabel.intrinsicContentSize.width) detail=\(detailLabel.frame.width)/intr=\(detailLabel.intrinsicContentSize.width)"
    }
    #endif
}
