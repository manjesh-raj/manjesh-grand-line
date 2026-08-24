// Manjesh Grand Line - native macOS app.
//
// `HelmDrillHeader` - the back affordance every drill page gets (Daylight
// migration §5.2's last bullet, §6.4).
//
// **Where it lives, and why that is the whole point.** This is a *shell*
// header, owned by `AppShellController` and sitting between the floating bar
// and the body container - not a header each destination builds for itself.
// One view therefore gives all fifteen destinations a working back button, a
// domain-hued tile and a live title, without editing a single destination
// controller. That matters for two reasons:
//
//   1. §5.1's survives list is explicit that `DestinationRegistry`'s
//      permanent-mount model does not change. A drill page is still exactly
//      the mounted destination view it was; this only pins it
//      `HelmDrillHeader.height` further down.
//   2. Restyling each page's own header chrome (its in-page hero titles, its
//      action clusters) is **Phase 4**, in §7's table order. Doing it here
//      would mean touching every destination in the shell phase, which is how
//      a structural migration turns into an unreviewable diff.
//
// Phase 2 shipped §6.4's row minus the action cluster (back button, tile,
// title, subtitle). **Phase 4 slice 1 filled that slot** (`setActions`), and
// it is filled per destination as each one is migrated: a page that has not
// been reached yet hands over nothing, `actions` hides itself, and the header
// renders exactly as it did before. `DaylightDrillActions` is the seam - see
// `AppShellController.applyDrillHeader`.
//
// **The canvas has no drill header**, by definition - it is the hub, not a
// spoke. `AppShellController` collapses this to zero height there, and
// collapsing means `isHidden` *and* a zero height constraint: an ordinary
// hidden `NSView`'s constraints still participate fully in Auto Layout
// (AGENTS.md gotcha (11)), so hiding alone would leave a 56pt gap above the
// canvas.

import AppKit

final class HelmDrillHeader: NSView {

    /// §6.4's row height: a 36pt back button plus breathing room above and
    /// below, matching §2.7's 20pt top margin under the bar region.
    static let height: CGFloat = 56
    /// §6.4's back button: 36pt, radius 14, card fill, hair border.
    static let backButtonSide: CGFloat = 36

    /// The back action - `AppShellController` wires it to `show(.homeCanvas)`,
    /// which is what preserves the canvas's last-selected space (the canvas
    /// owns that state and is never rebuilt).
    var onBack: (() -> Void)?

    private let backButton = HoverHighlightView()
    private let backGlyph = NSImageView()
    private let tile = HelmGradientTile(size: .drill)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// §6.4's right-aligned action cluster - "that page's primary + quiet
    /// actions". Phase 2 left the room; Phase 4 fills it, one destination per
    /// slice, and a destination that has not been migrated simply hands over
    /// nothing and renders exactly as it did before.
    private let actions = NSStackView()
    /// The title/subtitle column - a plain `NSView`, deliberately **not** an
    /// `NSStackView` (see `reassertTitleWidthTie()`'s doc comment for why).
    /// Stored (not a local `init` variable) so a self-test can inspect its
    /// own resolved frame - see `AppShellDrillHeaderTitleSelfTest.swift`.
    private let textColumn = NSView()
    /// The one non-fixed constraint in the row (`textColumn.trailingAnchor <=
    /// actions.leadingAnchor - s3`) - stored so it can be deactivated and
    /// reactivated on every `configure`/`setActions` call. See
    /// `reassertTitleWidthTie()`'s own doc comment for why that is required,
    /// not cosmetic.
    private var titleWidthTie: NSLayoutConstraint!
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        backGlyph.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        backGlyph.translatesAutoresizingMaskIntoConstraints = false

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.cornerRadius = HelmMetrics.dWell
        backButton.wantsLayer = true
        backButton.layer?.borderWidth = 1
        backButton.addSubview(backGlyph)
        backButton.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(backClicked)))
        backButton.accessibilityLabelOverride = "Back to home"
        backButton.toolTip = "Back to home"
        backButton.setContentHuggingPriority(.required, for: .horizontal)
        backButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = HelmType.drillTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (13): a title's own >500 compression resistance is a
        // window-width floor, and this header sits above every destination.
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.addSubview(titleLabel)
        textColumn.addSubview(subtitleLabel)

        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = HelmMetrics.s2
        actions.distribution = .fill
        actions.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12): the *stack*-level APIs are the ones that bite
        // on a view with no intrinsic content size. Without these the action
        // cluster is what a `.fill` parent stretches, and the title column -
        // the one thing that should flex - stays at its natural width.
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setClippingResistancePriority(.required, for: .horizontal)

        addSubview(backButton)
        addSubview(tile)
        addSubview(textColumn)
        addSubview(actions)

        // The title yields to the actions rather than running under them.
        titleWidthTie = textColumn.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor,
                                                              constant: -HelmMetrics.s3)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.pageGutter),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: Self.backButtonSide),
            backButton.heightAnchor.constraint(equalToConstant: Self.backButtonSide),
            backGlyph.centerXAnchor.constraint(equalTo: backButton.centerXAnchor),
            backGlyph.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            tile.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: HelmMetrics.s3),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            textColumn.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s3),
            textColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleWidthTie,

            // `titleLabel`/`subtitleLabel` are plain subviews of `textColumn`,
            // not an `NSStackView`'s arranged subviews - see
            // `reassertTitleWidthTie()`'s doc comment for why the stack view
            // this replaced could not be trusted to re-derive its own width.
            titleLabel.topAnchor.constraint(equalTo: textColumn.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: textColumn.bottomAnchor),
            // `textColumn`'s own width is exactly "as wide as its widest
            // child" - a required `>=` from each child, never an `NSStackView`
            // computing it internally.
            textColumn.trailingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor),
            textColumn.trailingAnchor.constraint(greaterThanOrEqualTo: subtitleLabel.trailingAnchor),

            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.pageGutter),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// Point the header at a destination. `subtitle` is optional live detail
    /// the shell already knows (a host page's label, for instance).
    func configure(title: String, subtitle: String, symbol: String, hue: HelmDomainHue) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        tile.configure(symbol: symbol, hue: hue)
        reassertTitleWidthTie()
    }

    /// Hand the header this destination's own actions, or `[]` to clear them.
    ///
    /// The views are **caller-owned**: a page keeps its own Refresh button, its
    /// own sync pill, and the state on them (enabled, spinner showing) that it
    /// already manages - which is the same "a view slot, not a
    /// `(title, closure)` pair" call `HelmEmptyState.accessory` made, for the
    /// same reason.
    func setActions(_ views: [NSView]) {
        actions.arrangedSubviews.forEach {
            actions.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for view in views {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            actions.addArrangedSubview(view)
        }
        actions.isHidden = views.isEmpty
        reassertTitleWidthTie()
    }

    /// Deactivates and reactivates `titleWidthTie` (`textColumn.trailingAnchor
    /// <= actions.leadingAnchor - s3`) - part of the fix for the intermittent
    /// truncated-title bug (a screenshot showing "Con…" instead of "Console").
    ///
    /// **The root cause, found by reproduction.** Once this row's title has
    /// genuinely been squeezed below its natural width - because an *earlier*
    /// destination's own wide `actions` cluster (or a narrow window) forced
    /// it down - Auto Layout's `<=` inequality does not revisit that resolved
    /// value on a later pass just because the ceiling has since moved further
    /// away: an inequality only forces a change when the *old* value becomes
    /// infeasible (the ceiling tightens); loosening it creates no pressure to
    /// grow back, so a stale, too-narrow frame can survive indefinitely -
    /// confirmed live, with a real, disposable `HelmDrillHeader` instance, to
    /// need `textColumn`'s own arranged-subview column to be a **plain
    /// `NSView`**, never an `NSStackView`: an `NSStackView` used for this
    /// column reproduced a squeeze that stayed frozen at its narrowest-ever
    /// resolved width **permanently** - through repeated `layoutSubtreeIfNeeded()`
    /// calls, `invalidateIntrinsicContentSize()` on both labels,
    /// `needsLayout`/`needsUpdateConstraints`, removing and re-adding both
    /// labels as arranged subviews, deactivating/reactivating (and replacing
    /// outright) the external `<=` tie, and even round-trip *window* resizes
    /// to a much larger size - none of it ever let the stack's own reported
    /// cross-axis width grow back. Whatever internal state an `NSStackView`
    /// keeps for a `.leading`-aligned arranged subview's width appears to be
    /// a one-way ratchet once squeezed, not a value AppKit re-derives on
    /// every layout pass. `textColumn` (a plain `NSView`, with `>= child`
    /// constraints owning its own width - see `init`) does not have this
    /// problem: a plain `NSView`'s geometry is nothing but its own active
    /// constraints, re-solved fresh on every layout pass like everything else
    /// in this header. `reassertTitleWidthTie()` remains as defence in depth
    /// for the one non-fixed constraint in the row - deactivating and
    /// replacing it on every `configure`/`setActions` call costs nothing and
    /// removes any doubt that a *stale constraint object* (as opposed to
    /// `NSStackView`'s own internals) could ever be the culprit again.
    ///
    /// This is why the bug was intermittent rather than permanent: a fresh
    /// window (nothing has ever squeezed the row) never exhibited it, and the
    /// exact "sometimes" trigger was switching to a destination whose title
    /// should render in full *after* an earlier destination's own action
    /// cluster (or a narrow window) genuinely squeezed the row at some point
    /// in the session - the "Con…" screenshot's own title/action content had
    /// nothing to do with the truncation; whatever was shown immediately
    /// before it did.
    private func reassertTitleWidthTie() {
        titleWidthTie.isActive = false
        titleWidthTie = textColumn.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor,
                                                              constant: -HelmMetrics.s3)
        titleWidthTie.isActive = true
    }

    @objc private func backClicked() { onBack?() }

    private func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        backButton.normalColor = surface
        backButton.hoverColor = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : line.withAlphaComponent(0.5)
        backButton.layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor
        backGlyph.contentTintColor = ink
        // §6.4's resting shadow. `HoverHighlightView` does not clip its own
        // layer, so the shadow reads; cleared outright off Daylight so a
        // captain switching palettes is not left with a stale one.
        if theme.isDaylight {
            let shadow = HelmCard.elevation(for: theme, level: .resting)
            backButton.layer?.masksToBounds = false
            backButton.layer?.shadowColor = shadow.shadowColor?.withAlphaComponent(1).cgColor
            backButton.layer?.shadowOpacity = Float(shadow.shadowColor?.alphaComponent ?? 0)
            backButton.layer?.shadowRadius = shadow.shadowBlurRadius
            backButton.layer?.shadowOffset = CGSize(width: 0, height: shadow.shadowOffset.height)
        } else {
            backButton.layer?.shadowOpacity = 0
        }

        titleLabel.font = HelmType.drillTitle()
        titleLabel.textColor = ink
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.textColor = muted
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var titleForTests: String { titleLabel.stringValue }
    var actionsForTests: [NSView] { actions.arrangedSubviews }
    var subtitleForTests: String { subtitleLabel.stringValue }
    /// The real title label, for a test that needs to compare its rendered
    /// frame against its own freshly-computed intrinsic size (the shape of
    /// check that catches a stale, too-narrow frame surviving a correct
    /// `stringValue` - see `AppShellDrillHeaderTitleSelfTest.swift`).
    var titleLabelForTests: NSTextField { titleLabel }
    var textColumnForTests: NSView { textColumn }
    var actionsStackForTests: NSStackView { actions }

    /// Fires the real back path a click or a VoiceOver press would.
    @discardableResult
    func debugActivateBack() -> Bool { backButton.performPrimaryAction() }
    #endif
}
