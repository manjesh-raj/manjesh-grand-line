// Manjesh Grand Line - native macOS app.
//
// `HelmDrillHeader` - the back affordance every drill page gets (Daylight
// migration §5.2's last bullet, §6.4).
//
// **Where it lives, and why that is the whole point.** This is a *shell*
// header, owned by `AppShellController` - not a header each destination
// builds for itself. One view therefore gives every destination a working
// back button, a domain-hued tile and a live title, without editing a single
// destination controller.
//
// **It is now the floating bar's own leading cluster, not a strip below it**
// (UI modernization audit A2, `data/grandline-ui-modernization-audit/
// report.md` §3A). It used to be a full-width 56pt row pinned across the top
// of `bodyContainer`, between the bar and the page. The audit measured the
// resulting stack at "~200pt of chrome before the first line of content" and
// asked for the back-chevron, the icon and the title to "slide into the
// bar's leading area (where the wordmark sits), the way Finder/Settings/App
// Store put navigation in the toolbar itself", with the action cluster
// joining the bar's trailing side. So:
//
//   - This view is the **leading cluster only**: back button + tile +
//     title/subtitle column. It sizes itself to its content and is swapped
//     for `DaylightBarController`'s logo+wordmark on a drill page.
//   - The **action cluster moved out** of this class entirely. It is the
//     bar's own trailing-anchored stack now (`DaylightBarController
//     .setDrillActions`), because the bar's leading and trailing areas are
//     two independently-anchored constraint chains with one compressible
//     joint between them - a single view spanning both would re-create the
//     window-width floor that joint exists to prevent.
//   - There is no `height` constant any more: the row is the bar's 50pt.
//
// What deliberately did **not** change: `DestinationRegistry`'s
// permanent-mount model, and the title-truncation fix below
// (`reassertTitleWidthTie`, and `textColumn` being a plain `NSView` rather
// than an `NSStackView`) - that was a real, reproduced bug and its cause is
// unaffected by which parent the cluster hangs from.
//
// **The canvas has no drill header**, by definition - it is the hub, not a
// spoke. The bar hides this cluster and shows its wordmark there instead;
// because both are arranged subviews of one stack, the hidden one leaves
// layout entirely and no zero-height constraint is needed (AGENTS.md gotcha
// (11)'s own stated exemption for an `NSStackView`'s arranged subviews).

import AppKit

final class HelmDrillHeader: NSView {

    /// The back button, matching the bar's own icon-button side so the
    /// leading cluster reads in one language with the trailing one.
    static let backButtonSide: CGFloat = DaylightBarIconButton.side

    /// The back action - `AppShellController` wires it to `show(.homeCanvas)`,
    /// which is what preserves the canvas's last-selected space (the canvas
    /// owns that state and is never rebuilt).
    var onBack: (() -> Void)?

    private let backButton = HoverHighlightView()
    private let backGlyph = NSImageView()
    /// `.module` (30pt), not the 34pt `.drill` this used to carry: the audit
    /// asks for a "small icon" in the bar's leading area, and 30 balances the
    /// two-line title/subtitle column inside a 50pt row with 10pt of margin.
    private let tile = HelmGradientTile(size: .module)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// The title/subtitle column - a plain `NSView`, deliberately **not** an
    /// `NSStackView` (see `reassertTitleWidthTie()`'s doc comment for why).
    /// Stored (not a local `init` variable) so a self-test can inspect its
    /// own resolved frame - see `AppShellDrillHeaderTitleSelfTest.swift`.
    private let textColumn = NSView()
    /// The cluster's own width: exactly as wide as its content
    /// (`textColumn.trailingAnchor == trailingAnchor`) - stored so it can be
    /// deactivated and reactivated on every `configure` call. See
    /// `reassertTitleWidthTie()`'s own doc comment for why that is defence in
    /// depth rather than cosmetic.
    private var titleWidthTie: NSLayoutConstraint!
    /// Which of the two vertical chains the text column uses - see
    /// `applySubtitleVisibility`. A hidden subtitle is a plain hidden
    /// `NSView`, so it keeps its constraints (AGENTS.md gotcha (11)) and the
    /// title would stay parked above an empty line without this.
    private var titleOnlyBottom: NSLayoutConstraint!
    private var subtitleBottom: NSLayoutConstraint!
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
        // Shrink-wrap, but truncate: **high** hugging so the cluster is
        // exactly as wide as its text, and **low** compression resistance so
        // the text is what yields when the bar runs out of room.
        //
        // Hugging was `.defaultLow` while this was a full-width strip, where
        // the column had a whole row to spread into. It is the bar's leading
        // area now and its own width *is* its content (`titleWidthTie`), so
        // low hugging leaves that width genuinely ambiguous - measured: the
        // cluster resolved to a zero frame.
        //
        // Raising hugging is safe for AGENTS.md gotcha (13): hugging resists
        // being made *larger*, and a window floor comes from resisting being
        // made smaller. Compression resistance - the half that could cap the
        // window, and the half that makes the title truncate first, exactly
        // as the wordmark it replaces already did - stays `.defaultLow`.
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }

        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.addSubview(titleLabel)
        textColumn.addSubview(subtitleLabel)

        addSubview(backButton)
        addSubview(tile)
        addSubview(textColumn)

        // The cluster is exactly as wide as its content; the bar's own
        // leading/trailing chain is what squeezes it (and therefore the
        // `.defaultLow` title) when the window is narrow.
        titleWidthTie = textColumn.trailingAnchor.constraint(equalTo: trailingAnchor)

        titleOnlyBottom = titleLabel.bottomAnchor.constraint(equalTo: textColumn.bottomAnchor)
        subtitleBottom = subtitleLabel.bottomAnchor.constraint(equalTo: textColumn.bottomAnchor)

        // **Shrink-wrap.** This cluster's own size *is* its content now (it
        // used to be a full-width strip with an external height constraint,
        // where neither axis was its own business). Every constraint above
        // bounds it from the inside with `>=`/`<=`, which sets a floor and
        // leaves the actual value free - measured, the result was a 539x0
        // frame: stretched sideways by the bar's own chain and flat.
        //
        // A near-zero `==` at the lowest possible priority is the standard
        // way to say "and take the smallest value that satisfies all of
        // that". Priority 1 is deliberately below *everything*, including
        // the labels' `.defaultLow` (250) compression resistance - so this
        // hugs the cluster onto its text and never squeezes the text itself.
        let shrinkWrap: [NSLayoutConstraint] = [
            widthAnchor.constraint(equalToConstant: 0),
            heightAnchor.constraint(equalToConstant: 0),
            textColumn.widthAnchor.constraint(equalToConstant: 0),
        ].map { $0.priority = NSLayoutConstraint.Priority(1); return $0 }

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: Self.backButtonSide),
            backButton.heightAnchor.constraint(equalToConstant: Self.backButtonSide),
            backGlyph.centerXAnchor.constraint(equalTo: backButton.centerXAnchor),
            backGlyph.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            tile.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: HelmMetrics.s2),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            textColumn.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HelmMetrics.s2),
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
            subtitleBottom,
            // `textColumn`'s own width is exactly "as wide as its widest
            // child" - a required `>=` from each child, never an `NSStackView`
            // computing it internally.
            textColumn.trailingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor),
            textColumn.trailingAnchor.constraint(greaterThanOrEqualTo: subtitleLabel.trailingAnchor),

            // Vertical: every child is centred, so nothing above would give
            // the cluster a height on its own. These bound it from the
            // inside, and `shrinkWrap` below pulls it down onto them.
            backButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            backButton.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            tile.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            tile.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            textColumn.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            textColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ] + shrinkWrap)

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// Point the cluster at a destination. `subtitle` is optional live detail
    /// the shell already knows (a host page's label, for instance).
    ///
    /// `artwork` is `RailDestination.drillHeaderArtwork` - `nil` for every
    /// destination but the ones that carry a raster payload. Routed through
    /// `HelmGradientTile.configure(artwork:symbol:hue:)` rather than the
    /// plain glyph path, mirroring how `HelmModuleCard` already renders those
    /// destinations' Overview card tiles.
    func configure(title: String, subtitle: String, symbol: String, hue: HelmDomainHue, artwork: NSImage? = nil) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        applySubtitleVisibility(hidden: subtitle.isEmpty)
        if let artwork {
            tile.configure(artwork: artwork, symbol: symbol, hue: hue)
        } else {
            tile.configure(symbol: symbol, hue: hue)
        }
        reassertTitleWidthTie()
    }

    /// A hidden subtitle is a plain hidden `NSView`, which keeps every one of
    /// its constraints (AGENTS.md gotcha (11) - the `NSStackView` exemption
    /// does not apply, and `textColumn` is deliberately not one). Swapping
    /// which view owns the column's bottom edge is what actually collapses
    /// the empty line, so a title-only page centres its title in the bar
    /// rather than parking it above blank space.
    private func applySubtitleVisibility(hidden: Bool) {
        subtitleLabel.isHidden = hidden
        subtitleBottom.isActive = !hidden
        titleOnlyBottom.isActive = hidden
    }

    /// Deactivates and reactivates `titleWidthTie` (`textColumn.trailingAnchor
    /// == trailingAnchor`) - part of the fix for the intermittent truncated-
    /// title bug (a screenshot showing "Con…" instead of "Console").
    ///
    /// **The root cause, found by reproduction.** Once this row's title has
    /// genuinely been squeezed below its natural width - because an *earlier*
    /// destination's own wide action cluster (or a narrow window) forced it
    /// down - Auto Layout does not revisit that resolved value on a later
    /// pass just because the pressure has since gone away. Confirmed live,
    /// with a real, disposable `HelmDrillHeader` instance, to need
    /// `textColumn` to be a **plain `NSView`**, never an `NSStackView`: an
    /// `NSStackView` used for this column reproduced a squeeze that stayed
    /// frozen at its narrowest-ever resolved width **permanently** - through
    /// repeated `layoutSubtreeIfNeeded()` calls,
    /// `invalidateIntrinsicContentSize()` on both labels,
    /// `needsLayout`/`needsUpdateConstraints`, removing and re-adding both
    /// labels as arranged subviews, deactivating/reactivating (and replacing
    /// outright) the external tie, and even round-trip *window* resizes to a
    /// much larger size - none of it ever let the stack's own reported
    /// cross-axis width grow back. Whatever internal state an `NSStackView`
    /// keeps for a `.leading`-aligned arranged subview's width appears to be
    /// a one-way ratchet once squeezed, not a value AppKit re-derives on
    /// every layout pass. `textColumn` (a plain `NSView`, with `>= child`
    /// constraints owning its own width - see `init`) does not have this
    /// problem: a plain `NSView`'s geometry is nothing but its own active
    /// constraints, re-solved fresh on every layout pass like everything else
    /// in this cluster. `reassertTitleWidthTie()` remains as defence in depth
    /// - replacing the one width-bearing constraint on every `configure` call
    /// costs nothing and removes any doubt that a *stale constraint object*
    /// (as opposed to `NSStackView`'s own internals) could ever be the
    /// culprit again.
    ///
    /// This is why the bug was intermittent rather than permanent: a fresh
    /// window (nothing has ever squeezed the row) never exhibited it, and the
    /// exact "sometimes" trigger was switching to a destination whose title
    /// should render in full *after* an earlier destination's own action
    /// cluster (or a narrow window) genuinely squeezed the row at some point
    /// in the session.
    private func reassertTitleWidthTie() {
        titleWidthTie.isActive = false
        titleWidthTie = textColumn.trailingAnchor.constraint(equalTo: trailingAnchor)
        titleWidthTie.isActive = true
    }

    /// The back control, for `DaylightBarController.keyViewChain` - the bar
    /// states its own key order explicitly (see `AppShellController
    /// .updateKeyViewLoop`), and on a drill page the way out should be the
    /// first thing the keyboard reaches.
    var backButtonForKeyLoop: NSView { backButton }

    @objc private func backClicked() { onBack?() }

    private func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        // No background of its own any more: this sits *on* the bar, and a
        // page-ground fill here would paint a rectangle across it.
        layer?.backgroundColor = NSColor.clear.cgColor
        backButton.normalColor = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeBackgroundHex)
        backButton.hoverColor = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.hairRow)
            : line.withAlphaComponent(0.5)
        backButton.layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor
        backGlyph.contentTintColor = muted
        // The bar already casts its own shadow; a second one inside it would
        // read as a floating chip on a floating bar.
        backButton.layer?.shadowOpacity = 0

        titleLabel.font = HelmType.drillTitle()
        titleLabel.textColor = ink
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.textColor = muted
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var titleForTests: String { titleLabel.stringValue }
    var subtitleForTests: String { subtitleLabel.stringValue }
    var subtitleIsHiddenForTests: Bool { subtitleLabel.isHidden }
    /// The real title label, for a test that needs to compare its rendered
    /// frame against its own freshly-computed intrinsic size (the shape of
    /// check that catches a stale, too-narrow frame surviving a correct
    /// `stringValue` - see `AppShellDrillHeaderTitleSelfTest.swift`).
    var titleLabelForTests: NSTextField { titleLabel }
    var textColumnForTests: NSView { textColumn }

    /// Fires the real back path a click or a VoiceOver press would.
    @discardableResult
    func debugActivateBack() -> Bool { backButton.performPrimaryAction() }
    #endif
}
