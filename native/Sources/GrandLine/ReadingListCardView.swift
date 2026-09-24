// Grand Line - native macOS app.
//
// F4's card - the thing the whole feature is for, and the thing the captain
// reviewed a mockup of before any of this existed.
//
// The mockup's own judgment call is quoted in its closing note: *"optional is
// shown as state, not as a setting: one card carries a summary, one carries a
// Summarise button, one was read and never needed either. That is the whole
// feature in one row."* This file is that sentence, made real - `render(_:)`
// branches on `ReadingLink.summaryKind` and on `isRead`, and the three states
// of the reviewed mockup are the three shapes it draws.
//
// ## Composition, not a hand-rolled card
//
// The surround is `HelmCard.applyCardSurface` (AGENTS.md's component index:
// "a hand-rolled rounded background view" is what this is instead of), the
// chrome text goes through `HelmType` roles, the spacing through
// `HelmMetrics`, and the one button is a `HelmButton` - a stock `NSButton`
// bezel is source-guarded here. The only thing drawn by hand is the accent
// strip along a summarised card's top edge and the monogram tile, both of
// which are this card's own identity rather than a component anything else
// wants.
//
// ## The two departures from the mockup, and why
//
//   - **No "6 min read".** Nothing in this feature knows how long an article
//     is: `LinkPresentation` returns metadata, not body text, and this app
//     never fetches a page's prose. GL-14 - a number nobody measured is worse
//     than no number - so that slot carries the date instead ("saved 18 Sep",
//     "read 14 Sep"), which the mockup's other two cards already show in
//     their body copy.
//   - **No "highlighted 3 passages".** Highlights are not in F4's scope and
//     the reader pane stores none, so the card does not claim any.
//
// ## Colour
//
// The tile's hue is `ReadingListHostHue` - a `HelmDomainHue`, which is
// identity - and every tinted *label* goes through
// `HelmContrast.tintedSurface` at the 4.5:1 text target rather than being
// painted in the raw hue. AGENTS.md: "a `HelmTint` hue is safe as a fill or a
// bar, and is NOT automatically safe as text", and `FM_RUN_CONTRAST_TESTS`
// sweeps every theme against it.

import AppKit

final class ReadingListCardView: HoverHighlightView {

    /// The narrowest a card may be before `HelmResponsiveGrid` drops a column.
    /// Wide enough for the summary well to hold a readable measure and for the
    /// tag row plus the Summarise button to share one line.
    static let minimumWidth: CGFloat = 300

    /// The accent strip along a summarised card's top edge - the mockup's own
    /// 4px gradient rule, which is what makes "this one has a summary"
    /// readable from across the grid rather than only on inspection.
    static let accentStripHeight: CGFloat = 4

    private(set) var link: ReadingLink

    /// Fired when the captain asks for something. The card owns no store - it
    /// reports, the page writes, which is the same "forward, never own" shape
    /// `AppShellController.makeCaptureFiler` uses and for the same reason
    /// (GL-23: one store instance).
    var onOpen: ((String) -> Void)?
    var onToggleRead: ((String) -> Void)?
    var onSummarise: ((String) -> Void)?
    var onRetryMetadata: ((String) -> Void)?
    var onEditTags: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    // MARK: Views

    private let accentStrip = NSView()
    private let iconTile = NSView()
    private let iconLetter = NSTextField(labelWithString: "")
    private let iconImage = NSImageView()
    private let hostLabel = NSTextField(labelWithString: "")
    private let statePill = NSView()
    private let statePillLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")

    private let summaryWell = NSView()
    private let summaryKicker = NSTextField(labelWithString: "")
    private let summaryBody = NSTextField(labelWithString: "")

    private let noteLabel = NSTextField(labelWithString: "")
    private let tagRow = NSStackView()
    private let dateLabel = NSTextField(labelWithString: "")
    private let summariseButton = HelmButton(title: "Summarise", variant: .quiet, size: .small, symbol: "sparkles")

    private var tagChips: [NSView] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var iconPNG: Data?
    private var isSummarising = false

    private var accentStripHeightConstraint: NSLayoutConstraint!

    // MARK: Build

    init(link: ReadingLink, iconPNG: Data?) {
        self.link = link
        self.iconPNG = iconPNG
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        cornerRadius = HelmMetrics.rCard

        // GL-16: a clickable row is a `HoverHighlightView`, which supplies the
        // role, the label, the focus ring and the keyboard press. The card is
        // the open affordance; every other action is its own control.
        accessibilityRoleOverride = .button
        onAccessibilityPress = { [weak self] in self?.openTapped() }
        let click = NSClickGestureRecognizer(target: self, action: #selector(openTapped))
        addGestureRecognizer(click)
        menu = buildContextMenu()

        buildChrome()
        render(link, iconPNG: iconPNG)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildChrome() {
        for view in [accentStrip, iconTile, hostLabel, statePill, titleLabel,
                     summaryWell, noteLabel, tagRow, dateLabel, summariseButton] as [NSView] {
            // Gotcha (11): cleared **before** the constraints go on. A plain
            // `NSView()` left at `true` also gets required constraints pinning
            // it to its frame at that moment - `.zero` - which then fight
            // every fill constraint and can cap the whole window.
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        accentStrip.wantsLayer = true

        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 5
        iconTile.layer?.masksToBounds = true
        iconLetter.translatesAutoresizingMaskIntoConstraints = false
        iconLetter.alignment = .center
        iconImage.translatesAutoresizingMaskIntoConstraints = false
        iconImage.imageScaling = .scaleProportionallyUpOrDown
        iconTile.addSubview(iconLetter)
        iconTile.addSubview(iconImage)

        hostLabel.font = HelmType.captionSmall()
        hostLabel.lineBreakMode = .byTruncatingTail
        // Gotcha (5): only the flexible text may compress. The tile and the
        // state pill beside it keep their fitting width at every card width.
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statePill.wantsLayer = true
        statePillLabel.translatesAutoresizingMaskIntoConstraints = false
        statePillLabel.font = HelmType.captionSmall()
        statePill.addSubview(statePillLabel)
        statePill.setContentCompressionResistancePriority(.required, for: .horizontal)
        statePill.setContentHuggingPriority(.required, for: .horizontal)
        // The pill is the read toggle, and it announces as one.
        let pillClick = NSClickGestureRecognizer(target: self, action: #selector(toggleReadTapped))
        statePill.addGestureRecognizer(pillClick)

        titleLabel.font = HelmType.rowTitle()
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 3
        titleLabel.cell?.usesSingleLineMode = false

        summaryWell.wantsLayer = true
        summaryWell.layer?.cornerRadius = HelmMetrics.rChip
        summaryWell.layer?.borderWidth = 1
        for label in [summaryKicker, summaryBody] {
            label.translatesAutoresizingMaskIntoConstraints = false
            summaryWell.addSubview(label)
        }
        summaryKicker.font = HelmType.kicker()
        summaryBody.font = HelmType.caption()
        summaryBody.lineBreakMode = .byWordWrapping
        summaryBody.maximumNumberOfLines = 6
        summaryBody.cell?.usesSingleLineMode = false

        noteLabel.font = HelmType.caption()
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 3
        noteLabel.cell?.usesSingleLineMode = false

        tagRow.orientation = .horizontal
        tagRow.alignment = .centerY
        tagRow.spacing = HelmMetrics.s1 + 1
        // Gotcha (10): `.gravityAreas` is the default and honours no priority,
        // so the row that must hug its chips says `.fill` out loud.
        tagRow.distribution = .fill
        // Gotcha (12): a stack has no intrinsic size, so `setHuggingPriority`
        // - the **stack**-level API - is what holds it collapsed, not
        // `setContentHuggingPriority`, which is a no-op here.
        tagRow.setHuggingPriority(.required, for: .horizontal)
        tagRow.setClippingResistancePriority(.defaultLow, for: .horizontal)

        dateLabel.font = HelmType.captionSmall()
        dateLabel.alignment = .right
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)

        summariseButton.target = self
        summariseButton.action = #selector(summariseTapped)
        summariseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        summariseButton.setContentHuggingPriority(.required, for: .horizontal)

        let pad = HelmMetrics.s3 + 1
        accentStripHeightConstraint = accentStrip.heightAnchor.constraint(equalToConstant: Self.accentStripHeight)

        NSLayoutConstraint.activate([
            accentStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentStrip.topAnchor.constraint(equalTo: topAnchor),
            accentStripHeightConstraint,

            iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            iconTile.topAnchor.constraint(equalTo: accentStrip.bottomAnchor, constant: pad),
            iconTile.widthAnchor.constraint(equalToConstant: 18),
            iconTile.heightAnchor.constraint(equalToConstant: 18),

            iconLetter.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconLetter.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            iconImage.leadingAnchor.constraint(equalTo: iconTile.leadingAnchor),
            iconImage.trailingAnchor.constraint(equalTo: iconTile.trailingAnchor),
            iconImage.topAnchor.constraint(equalTo: iconTile.topAnchor),
            iconImage.bottomAnchor.constraint(equalTo: iconTile.bottomAnchor),

            hostLabel.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: HelmMetrics.s2),
            hostLabel.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: statePill.leadingAnchor,
                                                constant: -HelmMetrics.s2),

            statePill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            statePill.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            statePillLabel.leadingAnchor.constraint(equalTo: statePill.leadingAnchor, constant: 7),
            statePillLabel.trailingAnchor.constraint(equalTo: statePill.trailingAnchor, constant: -7),
            statePillLabel.topAnchor.constraint(equalTo: statePill.topAnchor, constant: 2),
            statePillLabel.bottomAnchor.constraint(equalTo: statePill.bottomAnchor, constant: -2),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            titleLabel.topAnchor.constraint(equalTo: iconTile.bottomAnchor, constant: 7),

            summaryWell.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryWell.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            summaryWell.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: HelmMetrics.s2),

            summaryKicker.leadingAnchor.constraint(equalTo: summaryWell.leadingAnchor, constant: HelmMetrics.s2),
            summaryKicker.trailingAnchor.constraint(equalTo: summaryWell.trailingAnchor, constant: -HelmMetrics.s2),
            summaryKicker.topAnchor.constraint(equalTo: summaryWell.topAnchor, constant: 7),
            summaryBody.leadingAnchor.constraint(equalTo: summaryKicker.leadingAnchor),
            summaryBody.trailingAnchor.constraint(equalTo: summaryKicker.trailingAnchor),
            summaryBody.topAnchor.constraint(equalTo: summaryKicker.bottomAnchor, constant: 3),
            summaryBody.bottomAnchor.constraint(equalTo: summaryWell.bottomAnchor, constant: -7),

            noteLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            noteLabel.topAnchor.constraint(equalTo: summaryWell.bottomAnchor, constant: HelmMetrics.s2 - 1),

            tagRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            tagRow.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: HelmMetrics.s2 + 1),
            tagRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),

            summariseButton.leadingAnchor.constraint(greaterThanOrEqualTo: tagRow.trailingAnchor,
                                                     constant: HelmMetrics.s2),
            summariseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            summariseButton.centerYAnchor.constraint(equalTo: tagRow.centerYAnchor),

            dateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tagRow.trailingAnchor,
                                               constant: HelmMetrics.s2),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            dateLabel.centerYAnchor.constraint(equalTo: tagRow.centerYAnchor),
        ])
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open in Browser", action: #selector(openExternallyTapped),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Read", action: #selector(toggleReadTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Tags\u{2026}", action: #selector(editTagsTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Summarise", action: #selector(summariseTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Link", action: #selector(copyLinkTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove\u{2026}", action: #selector(deleteTapped), keyEquivalent: "").target = self
        return menu
    }

    // MARK: Rendering

    /// Draw one link. Called on build and again whenever the store changes the
    /// record, so the card never holds a stale copy of its own state.
    func render(_ link: ReadingLink, iconPNG: Data?) {
        self.link = link
        self.iconPNG = iconPNG

        accessibilityLabelOverride = accessibilityLine(for: link)

        iconLetter.stringValue = ReadingListURL.monogram(for: link.url)
        if let iconPNG, let image = NSImage(data: iconPNG) {
            iconImage.image = image
            iconImage.isHidden = false
            iconLetter.isHidden = true
        } else {
            iconImage.image = nil
            iconImage.isHidden = true
            iconLetter.isHidden = false
        }

        hostLabel.stringValue = link.host.isEmpty ? "unknown site" : link.host
        titleLabel.stringValue = link.displayTitle

        statePillLabel.stringValue = link.isRead ? "read" : "unread"
        statePill.toolTip = link.isRead ? "Mark as unread" : "Mark as read"
        statePill.setAccessibilityRole(.button)
        statePill.setAccessibilityLabel(statePill.toolTip)

        switch link.summaryKind {
        case .ai(let text):
            summaryWell.isHidden = false
            summaryKicker.stringValue = "SUMMARY"
            summaryBody.stringValue = text
        case .page(let text):
            summaryWell.isHidden = false
            // Labelled differently on purpose: the page's own blurb and a
            // paragraph a model wrote are different claims, and a card that
            // called both "SUMMARY" would let the Summarised tab mean two
            // things.
            summaryKicker.stringValue = "FROM THE PAGE"
            summaryBody.stringValue = text
        case .none:
            summaryWell.isHidden = true
            summaryKicker.stringValue = ""
            summaryBody.stringValue = ""
        }
        // Gotcha (11) again, from the other direction: a hidden plain `NSView`
        // still has its constraints, so a hidden well would still charge the
        // card its own height plus both gaps. Collapsing it is what makes the
        // mockup's short third card actually short.
        collapseIfHidden(summaryWell, stored: &summaryWellCollapse)

        noteLabel.stringValue = secondLine(for: link)
        noteLabel.isHidden = noteLabel.stringValue.isEmpty
        collapseIfHidden(noteLabel, stored: &noteCollapse)

        rebuildTagChips(link.tags)

        // The mockup's three cards, exactly: a summarised card shows its
        // accent strip and its date, an un-summarised one offers the button,
        // and a read one has neither to offer.
        let hasAI = !link.aiSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A **read** card offers neither, which is the mockup's third state:
        // once something has been read, asking whether to spend a `claude -p`
        // turn summarising it is a prompt for work nobody needs done.
        let offersSummary = !hasAI && !link.isRead && link.metadataState == .resolved && !isSummarising
        summariseButton.isHidden = !offersSummary
        summariseButton.isEnabled = offersSummary
        dateLabel.isHidden = offersSummary
        dateLabel.stringValue = dateLine(for: link)
        accentStripHeightConstraint.constant = hasAI ? Self.accentStripHeight : 0

        // A failed fetch is retryable from the card rather than only from the
        // menu, because it is the one state where doing nothing leaves the
        // card permanently less useful than it should be.
        summariseButton.title = isSummarising ? "Summarising\u{2026}" : "Summarise"

        alphaValue = link.isRead ? 0.82 : 1.0
        applyTheme(theme)
    }

    /// Called while a `claude -p` turn is in flight, so the button says so and
    /// a second press cannot start a second turn.
    func setSummarising(_ running: Bool) {
        isSummarising = running
        render(link, iconPNG: iconPNG)
    }

    private var summaryWellCollapse: NSLayoutConstraint?
    private var noteCollapse: NSLayoutConstraint?

    private func collapseIfHidden(_ view: NSView, stored: inout NSLayoutConstraint?) {
        if view.isHidden {
            if stored == nil {
                let c = view.heightAnchor.constraint(equalToConstant: 0)
                // Required is safe here for gotcha (13)'s reason as stated in
                // gotcha (17)'s footnote: zero is a *maximum* and can never be
                // a floor on how narrow or short the window may get.
                c.isActive = true
                stored = c
            }
        } else {
            stored?.isActive = false
            stored = nil
        }
    }

    /// The card's second line. GL-14 in one function: each of the three
    /// metadata states reads differently, and none of them is silence.
    private func secondLine(for link: ReadingLink) -> String {
        switch link.metadataState {
        case .pending:
            return "Reading the page\u{2019}s title and summary\u{2026}"
        case .failed(let why):
            return "\(why) Right-click to try again."
        case .resolved:
            // An **unread** link with no summary still says something, rather
            // than leaving the mockup's middle card blank between its title and
            // its tags - it is paired with the Summarise button on the row
            // below. A **read** one says nothing: the card has been dealt with,
            // and "No summary yet." on it reads as an outstanding job that is
            // not outstanding. The mockup's third card carries no such line
            // either.
            return !link.isRead && link.summaryKind == .none && link.aiSummary.isEmpty
                ? "No summary yet."
                : ""
        }
    }

    private func dateLine(for link: ReadingLink) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        if let readAt = link.readAt { return "read \(formatter.string(from: readAt))" }
        return "saved \(formatter.string(from: link.addedAt))"
    }

    /// GL-16: one spoken sentence carrying everything the card shows visually,
    /// so a VoiceOver user is not handed "button" and a host name.
    private func accessibilityLine(for link: ReadingLink) -> String {
        var parts = [link.displayTitle, "from \(link.host)"]
        parts.append(link.isRead ? "read" : "unread")
        if !link.tags.isEmpty { parts.append("tagged " + link.tags.joined(separator: ", ")) }
        if !link.aiSummary.isEmpty { parts.append("summarised") }
        return parts.joined(separator: ", ")
    }

    private func rebuildTagChips(_ tags: [String]) {
        for chip in tagChips {
            tagRow.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        tagChips = tags.map { chip(text: $0) }
        // The affordance the mockup implies but does not draw: a card with no
        // tags still needs somewhere to press, or tagging is menu-only.
        let add = chip(text: tags.isEmpty ? "add tags" : "+", isAction: true)
        tagChips.append(add)
        for chip in tagChips { tagRow.addArrangedSubview(chip) }
    }

    private func chip(text: String, isAction: Bool = false) -> NSView {
        let container = HoverHighlightView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.cornerRadius = HelmMetrics.rChip - 1
        container.identifier = NSUserInterfaceItemIdentifier(isAction ? "reading-list-tag-add" : "reading-list-tag")
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = HelmType.captionSmall()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        container.accessibilityRoleOverride = .button
        container.accessibilityLabelOverride = isAction ? "Edit tags" : "Tag \(text)"
        container.onAccessibilityPress = { [weak self] in self?.editTagsTapped() }
        container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(editTagsTapped)))
        container.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.setContentHuggingPriority(.required, for: .horizontal)
        return container
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        HelmCard.applyCardSurface(to: self, theme: theme)
        normalColor = HelmTheme.nsColor(theme.chromeBackgroundHex)
        hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.18)

        let hue = ReadingListHostHue.hue(for: link.url)
        let hueHex = hue.identityHex(in: theme)
        accentStrip.layer?.backgroundColor = HelmTheme.nsColor(hueHex).cgColor

        // The tile is a filled square with a letter on it, so the pair comes
        // from `legibleOn` rather than from the raw hue - AGENTS.md's rule
        // that a hue safe as a fill is not automatically safe as text.
        let tileFill = HelmTheme.nsColor(hueHex)
        iconTile.layer?.backgroundColor = tileFill.cgColor
        iconLetter.font = .systemFont(ofSize: HelmType.scaled(9), weight: .bold)
        iconLetter.textColor = HelmContrast.legibleOn(
            fill: tileFill, preferring: HelmTheme.nsColor(theme.chromeBackgroundHex))

        let muted = HelmTheme.mutedInk(theme)
        hostLabel.textColor = muted
        noteLabel.textColor = muted
        dateLabel.textColor = muted
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        // The state pill: accent while unread (it is the thing asking to be
        // dealt with), the "good" tint once read.
        let pillTint: HelmTint = link.isRead ? .good : .accent
        let pill = HelmContrast.tintedSurface(tintHex: pillTint.hex(in: theme),
                                              theme: theme,
                                              target: HelmContrast.textTarget)
        statePill.layer?.backgroundColor = pill.fill.cgColor
        statePill.layer?.cornerRadius = HelmMetrics.capsuleRadius(
            forHeight: max(statePill.bounds.height, statePill.fittingSize.height))
        statePillLabel.textColor = pill.foreground

        // The summary well takes the *card's own* hue when the paragraph is
        // the AI's, and a neutral inset when it is the page's own words - the
        // same "state, not setting" distinction the kicker already makes.
        let wellIsAI = summaryKicker.stringValue == "SUMMARY"
        let wellTintHex = wellIsAI ? hueHex : theme.chromeLineHex
        let well = HelmContrast.tintedSurface(tintHex: wellTintHex,
                                              theme: theme,
                                              target: HelmContrast.textTarget)
        summaryWell.layer?.backgroundColor = well.fill.cgColor
        summaryWell.layer?.borderColor = HelmTheme.nsColor(wellTintHex)
            .withAlphaComponent(wellIsAI ? 0.35 : 0.5).cgColor
        summaryKicker.textColor = well.foreground
        summaryBody.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        let chipSurface = HelmContrast.tintedSurface(tintHex: theme.chromeInkHex,
                                                    theme: theme,
                                                    target: HelmContrast.textTarget)
        for chip in tagChips {
            chip.wantsLayer = true
            chip.layer?.backgroundColor = chipSurface.fill.cgColor
            for case let label as NSTextField in chip.subviews { label.textColor = chipSurface.foreground }
            if let hover = chip as? HoverHighlightView {
                hover.normalColor = chipSurface.fill
                hover.hoverColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.2)
            }
        }

    }

    override func layout() {
        super.layout()
        // The pill's capsule radius is derived from its *resolved* height, and
        // that is 0 the first time a freshly built control is styled - the
        // reason `HelmSegmentedTabs.Size.daylightPillRadius` reads `bounds`
        // rather than the point size. Re-derived here, once there is a real
        // one.
        statePill.layer?.cornerRadius = HelmMetrics.capsuleRadius(forHeight: statePill.bounds.height)
        // A wrapping label inside a card whose width the grid decides has no
        // width Auto Layout is obliged to hand it until the card has one.
        let inner = max(0, bounds.width - 2 * (HelmMetrics.s3 + 1))
        titleLabel.preferredMaxLayoutWidth = inner
        noteLabel.preferredMaxLayoutWidth = inner
        summaryBody.preferredMaxLayoutWidth = max(0, inner - 2 * HelmMetrics.s2)
    }

    // MARK: Actions

    @objc private func openTapped() { onOpen?(link.id) }
    @objc private func toggleReadTapped() { onToggleRead?(link.id) }
    @objc private func editTagsTapped() { onEditTags?(link.id) }
    @objc private func deleteTapped() { onDelete?(link.id) }

    @objc private func summariseTapped() {
        guard !isSummarising else { return }
        if case .failed = link.metadataState {
            onRetryMetadata?(link.id)
            return
        }
        onSummarise?(link.id)
    }

    @objc private func openExternallyTapped() {
        guard let url = URL(string: link.url) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLinkTapped() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.url, forType: .string)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugHost: String { hostLabel.stringValue }
    var debugStatePillText: String { statePillLabel.stringValue }
    var debugSecondLine: String { noteLabel.stringValue }
    var debugSummaryKicker: String { summaryWell.isHidden ? "" : summaryKicker.stringValue }
    var debugSummaryBody: String { summaryWell.isHidden ? "" : summaryBody.stringValue }
    var debugShowsSummariseButton: Bool { !summariseButton.isHidden }
    var debugDateLine: String { dateLabel.isHidden ? "" : dateLabel.stringValue }
    var debugAccentStripHeight: CGFloat { accentStripHeightConstraint.constant }
    var debugAccessibilityLine: String { accessibilityLabelOverride ?? "" }
    var debugTagChipCount: Int { tagChips.count }
    var debugUsesFavicon: Bool { !iconImage.isHidden }
    var debugStatePillColors: (fill: NSColor?, ink: NSColor?) {
        (statePill.layer?.backgroundColor.map { NSColor(cgColor: $0) } ?? nil, statePillLabel.textColor)
    }
    var debugSummaryWellFrame: NSRect { summaryWell.frame }
    var debugSummaryKickerColor: NSColor? { summaryWell.isHidden ? nil : summaryKicker.textColor }
    var debugSummaryWellFill: NSColor? {
        summaryWell.layer?.backgroundColor.map { NSColor(cgColor: $0) } ?? nil
    }
    var debugTitleColor: NSColor? { titleLabel.textColor }
    func debugPressStatePill() { toggleReadTapped() }
    func debugPressSummarise() { summariseTapped() }
    func debugPressCard() { openTapped() }
    #endif
}
