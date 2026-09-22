// Manjesh Grand Line - native macOS app.
//
// F22's compact popover: the whole app in 330pt, as the reviewed mockup draws
// it - a header, four tabs, a capture line and a footer.
//
// **The four tabs are the app's existing menu-bar popovers, merged.** That is
// the mockup's own judgment call, quoted in `CompactMode.swift`'s header, and
// it is what this file is mostly about:
//
//   * **Vault** is `PoneglyphMenuBarPopoverController`, the same controller
//     F16's own status item owns, hosted here at this popover's width with
//     its header suppressed. Not a reimplementation - the countdown rings,
//     the copy flash, the vault-locked state and the per-second ticking are
//     that file's, and its `stopTicking()` is still honoured on close.
//   * **Crew** is `StrawHatMenuBarPopoverController`, the same way. Its ask
//     field, its four-state reply area and its "Open Straw Hat Pirates" are
//     unchanged.
//   * **Today** and **Notes** are new panes, and the Notes one is the third
//     popover the report says did not exist. Today is *not* a reuse of
//     `ShiftMenuBarPopoverController`, and that is deliberate rather than
//     laziness: that controller renders two stat rows ("Tasks today: 3") plus
//     the next follow-up, and the mockup's Today tab is a different surface -
//     a list of the actual due tasks, each with a checkbox that completes it,
//     colour-coded by urgency. Reusing the stat rows would have meant
//     shipping the stat rows, which is not what was reviewed.
//
// Everything either pane displays is derived by `CompactModeDigest` from an
// injected clock, so nothing here computes a date or reads `Date()`.
//
// **It owns no store.** Every number arrives through a closure and every
// write leaves through one, wired by `AppDelegate` to the same shared stores
// the main window's pages use (GL-23).

import AppKit

// MARK: - The tabs

/// The popover's four tabs, in the mockup's own order.
enum CompactModeTab: String, CaseIterable {
    case today
    case notes
    case vault
    case crew

    var title: String {
        switch self {
        case .today: return "Today"
        case .notes: return "Notes"
        case .vault: return "Vault"
        case .crew: return "Crew"
        }
    }

    /// Where the footer's capture line files what is typed while this tab is
    /// showing, or `nil` when the tab has no capture of its own.
    ///
    /// Two of the four do. Crew already owns a field - its own ask line,
    /// inside its pane - and a second field under it asking the same question
    /// differently is worse than no field. The vault deliberately has none:
    /// `PoneglyphMenuBarController`'s header is explicit that a menu-bar
    /// surface with no window and no Touch ID gate is the wrong place to hand
    /// out credential material, and that argument runs in both directions -
    /// it is also the wrong place to *type* one.
    var captureDestination: CaptureDestination? {
        switch self {
        case .today: return .task
        case .notes: return .sticky
        case .vault, .crew: return nil
        }
    }

    /// The placeholder over the capture line, which names what pressing
    /// return will actually do rather than saying "Capture something…" on a
    /// tab that files a task and on one that files a sticky note.
    var capturePlaceholder: String {
        switch self {
        case .today: return "Capture a task, press \u{23CE}\u{2026}"
        case .notes: return "Capture a note, press \u{23CE}\u{2026}"
        case .vault, .crew: return ""
        }
    }
}

// MARK: - The popover's content

final class CompactModePopoverController: NSViewController {

    /// The mockup's own 330pt. Wide enough for a task title plus its caption
    /// at `HelmType`'s row sizes, and the width both embedded panes are built
    /// at so nothing inside letterboxes.
    ///
    /// Measured against the mockup rather than read off its pixels: the
    /// mockup image is rendered at ~1.76x (its "Grand Line" title measures
    /// 115px against the real app's 65.5pt at the same 12.5pt semibold), so
    /// its 540px-wide card is ~307pt, not the ~520pt a raw pixel read
    /// suggests. 330 is the mockup's card, slightly generous.
    static let width: CGFloat = 330

    /// **The popover is one fixed size, on every tab.**
    ///
    /// It used to report `view.fittingSize.height` per tab, so the card grew
    /// and shrank as the captain moved between Today / Notes / Vault / Crew -
    /// measured on the captain's own screenshots at 286 / 246 / 211 / 279pt,
    /// four different shapes for one surface. A popover is chrome, not a
    /// document: its footer and its tab strip have to stay where the hand
    /// left them.
    ///
    /// 360 is the mockup's own proportion at this width (its card is 588px
    /// tall against 540 wide, so 1.089 x 330 = 359), and it clears the
    /// tallest natural tab with room to spare. A tab whose content is taller
    /// than the region scrolls inside it - `bodyScroll` - which is the case
    /// the old "size to the content" shape handled by growing the whole card
    /// instead.
    static let height: CGFloat = 360

    // MARK: Wiring (all of it supplied by `AppDelegate`)

    /// The Today tab's rows and chips.
    var todayProvider: (() -> CompactTodayDigest)?
    /// The Notes tab's rows.
    var notesProvider: (() -> [CompactNoteRow])?
    /// The Vault tab's rows, and whether the vault itself is unlocked.
    ///
    /// Held here rather than on `vaultPane`: that controller is the *content*
    /// F16's status item renders, and the providers belong to whoever is
    /// presenting it - `PoneglyphMenuBarController` for the standalone item,
    /// this popover for the tab. Both point at the same
    /// `AppShellController.poneglyphQuickCodes`, so there is still exactly one
    /// `CredentialVaultStore` (GL-23).
    var vaultCodesProvider: (() -> [PoneglyphQuickCode])?
    var vaultUnlockedProvider: (() -> Bool)?
    /// Complete or un-complete one task from its checkbox.
    var onSetTaskCompleted: ((String, Bool) -> Void)?
    /// Open the full window on Tasks, with nothing selected.
    var onOpenTasks: (() -> Void)?
    /// Open the full window on the Sticky Board, revealing one note.
    var onRevealNote: ((String) -> Void)?
    /// Open the full window on the Sticky Board.
    var onOpenStickyBoard: (() -> Void)?
    /// The footer's capture line. The same `CaptureFiler` ⌥Space uses, so a
    /// task typed here and a task typed there are one code path
    /// (`AppShellController.makeCaptureFiler`).
    var captureFiler: CaptureFiler = .unwired

    var onOpenFullWindow: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Close the popover - used by a pane that has just navigated the window.
    var onDismiss: (() -> Void)?
    /// Forwarded to `popover.contentSize`.
    ///
    /// It reports `Self.contentSize` - the same two numbers every time,
    /// whichever tab is showing. It used to report the active tab's own
    /// fitting height, which is what made the card change shape under the
    /// captain's hand. Kept as a callback rather than set once at
    /// construction because `NSPopover` needs telling, and a surface that
    /// stops reporting its size at all is the harder thing to notice.
    var onSizeChanged: ((NSSize) -> Void)?

    // MARK: Chrome

    private let iconTile = IconTileView(size: 22, cornerRadius: 7)
    private let titleLabel = NSTextField(labelWithString: "Grand Line")
    private let modeLabel = NSTextField(labelWithString: "compact mode")
    private let settingsButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "gearshape")
    private let tabs = HelmSegmentedTabs(
        items: CompactModeTab.allCases.map { .init(id: $0.rawValue, title: $0.title) },
        selected: CompactModeTab.today.rawValue,
        size: .compact,
        // The mockup draws four equal full-width segments, and this popover
        // pins both of the control's edges - which without `equalWidths` is
        // gotcha (10) exactly. See that parameter's own note.
        equalWidths: true)

    private let bodyContainer = NSStackView()

    private let captureField = HelmTextField(placeholder: CompactModeTab.today.capturePlaceholder)
    private let captureButton = HelmButton(title: "\u{23CE}", variant: .primary, size: .small)
    private let captureRow = NSStackView()
    private let captureNotice = NSTextField(labelWithString: "")

    private let hotkeyHint = HelmKeyHint(
        keys: HelmKeyHint.keys(for: [.control, .option], key: "G"), caption: "toggle")
    private let openWindowButton = HelmButton(title: "Open full window", variant: .quiet, size: .small)

    private let headerDivider = NSView()
    private let captureDivider = NSView()
    private let footerDivider = NSView()

    // MARK: Panes

    private let todayPane = CompactTodayPane()
    private let notesPane = CompactNotesPane()
    /// Exposed so `AppDelegate` can wire them to the same shell methods the
    /// standalone status items use - see this file's header for why these are
    /// the real controllers rather than lookalikes.
    let vaultPane = PoneglyphMenuBarPopoverController(width: CompactModePopoverController.width,
                                                      showsOwnHeader: false)
    let crewPane = StrawHatMenuBarPopoverController(width: CompactModePopoverController.width,
                                                    showsOwnHeader: false)

    private var selected: CompactModeTab = .today
    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        root.wantsLayer = true
        view = root

        // Hosted as real child view controllers, not loose views: both panes
        // are `NSViewController`s with their own lifecycle, and the vault's
        // ticker is torn down from `viewDidDisappear`-adjacent code paths
        // that only fire for a controller AppKit actually knows about.
        addChild(vaultPane)
        addChild(crewPane)

        buildHeader()
        buildBody()
        buildCaptureRow()
        buildFooter()

        // **Three pieces, not one column, and that is the whole fix.**
        //
        // The chrome above the body and the chrome below it are each pinned
        // to their own edge of a fixed-size root; the body is whatever is
        // left between them. So the header, the tab strip, the capture line
        // and the footer are at the same coordinates on all four tabs, and a
        // tab whose content wants more room gets a scroller rather than
        // dragging the popover's own frame with it.
        //
        // Doing this with one stack instead would mean handing the body the
        // stack's slack, and neither `bodyContainer` (an `NSStackView`) nor a
        // scroll view has an intrinsic size - so a hugging priority on either
        // is a no-op, which is AGENTS.md gotcha (12) exactly.
        topGroup.setViews([headerRow, headerDivider, tabsRow], in: .leading)
        bottomGroup.setViews([captureDivider, captureRow, captureNotice,
                              footerDivider, footerRow], in: .leading)
        for group in [topGroup, bottomGroup] {
            group.orientation = .vertical
            group.alignment = .leading
            // The dividers carry the vertical rhythm, so the stack's own
            // spacing is the gap either side of one - half of `s2`, which is
            // what makes a divider read as a rule between two groups rather
            // than as a third element with its own margins.
            group.spacing = HelmMetrics.s1
            group.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(group)
            for child in group.arrangedSubviews {
                child.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            }
        }

        buildBodyScroll()
        root.addSubview(bodyScroll)

        NSLayoutConstraint.activate([
            // Both fixed, both required: this view *is* the popover's content
            // size, and `renderPane` reports exactly these two numbers rather
            // than measuring anything.
            root.widthAnchor.constraint(equalToConstant: Self.width),
            root.heightAnchor.constraint(equalToConstant: Self.height),

            topGroup.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topGroup.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topGroup.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s2 + 2),

            bottomGroup.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomGroup.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomGroup.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                                constant: -HelmMetrics.s2),

            bodyScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyScroll.topAnchor.constraint(equalTo: topGroup.bottomAnchor,
                                            constant: HelmMetrics.s1),
            bodyScroll.bottomAnchor.constraint(equalTo: bottomGroup.topAnchor,
                                               constant: -HelmMetrics.s1),
        ])

        tabs.onSelect = { [weak self] id in
            guard let tab = CompactModeTab(rawValue: id) else { return }
            self?.select(tab)
        }

        applyTheme(ThemeManager.shared.theme)
        renderPane()
    }

    private let headerRow = NSStackView()
    private let tabsRow = NSView()
    private let footerRow = NSStackView()

    /// The chrome pinned to the top edge and the chrome pinned to the bottom
    /// edge. See `loadView` for why these are two stacks rather than one.
    private let topGroup = NSStackView()
    private let bottomGroup = NSStackView()

    /// The fixed region every tab's content is laid out *within*.
    ///
    /// Overflow is the case this exists for: the Today tab caps at
    /// `CompactModeDigest.maxRows` tasks, and five rows plus both chips is
    /// taller than the region at the smaller text sizes GL-32 scales up to.
    /// Before this, that case grew the popover; now it scrolls.
    private let bodyScroll = NSScrollView()

    private func buildBodyScroll() {
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.hasVerticalScroller = true
        bodyScroll.hasHorizontalScroller = false
        bodyScroll.autohidesScrollers = true
        // Pinned rather than inherited. With "Show scroll bars: Always" a
        // legacy scroller reserves a real ~15pt track that narrows the clip
        // view - and both embedded panes constrain their own root to
        // `Self.width` at required priority, so a narrowed clip view is a
        // constraint conflict rather than a cosmetic inset. An overlay
        // scroller reserves nothing.
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.verticalScrollElasticity = .allowed

        // Flipped, per gotcha (9): a plain `NSView` document view puts y=0 at
        // its *bottom*, so content shorter than the viewport - which is every
        // tab here, most of the time - would rest against the bottom of the
        // clip view with a blank gap above it.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(bodyContainer)
        bodyScroll.documentView = document

        NSLayoutConstraint.activate([
            // The *clip* view, never the scroll view - gotcha (4).
            document.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: document.topAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    /// Put the body back at the top on every tab switch.
    ///
    /// `SettingsController`'s own `scrollToTop()` pair, for the same reason:
    /// a flipped document view keeps the scroll offset it had, so arriving on
    /// a short tab after scrolling a long one would land mid-content.
    private func scrollBodyToTop() {
        bodyScroll.contentView.scroll(to: .zero)
        bodyScroll.reflectScrolledClipView(bodyScroll.contentView)
    }

    private func buildHeader() {
        iconTile.configure(symbol: "sailboat", tint: .accent, pointSize: 12)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.font = HelmType.captionSmall()
        modeLabel.translatesAutoresizingMaskIntoConstraints = false

        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = "Compact mode settings"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        // A real low-priority zero-width spacer, not a hugging priority:
        // AGENTS.md gotcha (12) measured that a bare `NSView()` has no
        // intrinsic size, so `setContentHuggingPriority` on one is a no-op and
        // the spacer happily absorbs the whole row.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true

        headerRow.setViews([iconTile, titleLabel, modeLabel, spacer, settingsButton], in: .leading)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        headerRow.spacing = HelmMetrics.s2
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: HelmMetrics.s4, bottom: 0, right: HelmMetrics.s3)
        // Only the mode caption may give up width; the title and the gear
        // never shrink. Gotcha (5)'s rule for a row mixing fixed chrome with
        // variable text, applied to a very short row.
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        modeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeLabel.lineBreakMode = .byTruncatingTail

        for divider in [headerDivider, captureDivider, footerDivider] {
            divider.wantsLayer = true
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
    }

    private func buildBody() {
        // The tab strip in its own container so it can carry the row inset
        // without the capsule itself stretching edge to edge.
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabsRow.translatesAutoresizingMaskIntoConstraints = false
        tabsRow.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: tabsRow.leadingAnchor, constant: HelmMetrics.s3),
            tabs.trailingAnchor.constraint(equalTo: tabsRow.trailingAnchor, constant: -HelmMetrics.s3),
            tabs.topAnchor.constraint(equalTo: tabsRow.topAnchor, constant: HelmMetrics.s1),
            tabs.bottomAnchor.constraint(equalTo: tabsRow.bottomAnchor, constant: -HelmMetrics.s1),
        ])

        bodyContainer.orientation = .vertical
        bodyContainer.alignment = .leading
        bodyContainer.spacing = 0
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        // All four panes are arranged subviews from the start, and exactly one
        // is unhidden. A hidden arranged subview of an `NSStackView` drops out
        // of layout entirely - gotcha (11)'s one named exception - so only the
        // showing tab contributes any height, with no constraint swapping,
        // which is what `StrawHatMenuBarPopoverController` already does for
        // its own four states.
        //
        // What that height no longer decides is the popover's own. This stack
        // is the document view of `bodyScroll`, which occupies a fixed region
        // between the top and bottom chrome - so a taller tab scrolls inside
        // the card instead of resizing it.
        todayPane.onOpenTasks = { [weak self] in
            self?.onOpenTasks?()
            self?.onDismiss?()
        }
        todayPane.onSetTaskCompleted = { [weak self] id, done in
            self?.onSetTaskCompleted?(id, done)
            // Re-derive rather than mutate the row in place: the store is the
            // truth, and completing a task can change what the *other* rows
            // say (a capped list gains the sixth task).
            self?.renderPane()
        }
        notesPane.onRevealNote = { [weak self] id in
            self?.onRevealNote?(id)
            self?.onDismiss?()
        }
        notesPane.onOpenBoard = { [weak self] in
            self?.onOpenStickyBoard?()
            self?.onDismiss?()
        }

        for pane in [todayPane, notesPane, vaultPane.view, crewPane.view] as [NSView] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            bodyContainer.addArrangedSubview(pane)
            pane.widthAnchor.constraint(equalTo: bodyContainer.widthAnchor).isActive = true
        }
    }

    private func buildCaptureRow() {
        captureField.target = self
        captureField.action = #selector(captureSubmitted)
        captureField.translatesAutoresizingMaskIntoConstraints = false
        captureButton.target = self
        captureButton.action = #selector(captureSubmitted)
        captureButton.toolTip = "File this where the active tab keeps things"
        captureButton.translatesAutoresizingMaskIntoConstraints = false

        captureRow.setViews([captureField, captureButton], in: .leading)
        captureRow.orientation = .horizontal
        captureRow.alignment = .centerY
        captureRow.distribution = .fill
        captureRow.spacing = HelmMetrics.s2
        captureRow.translatesAutoresizingMaskIntoConstraints = false
        captureRow.edgeInsets = NSEdgeInsets(top: HelmMetrics.s1, left: HelmMetrics.s4,
                                             bottom: HelmMetrics.s1, right: HelmMetrics.s3)
        // The field is the one thing that flexes; the button is a fixed
        // control. Gotcha (5) again.
        captureButton.setContentHuggingPriority(.required, for: .horizontal)
        captureButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        captureField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A capture that is refused has to say so - `CaptureFilingOutcome`
        // carries the reason precisely so nothing swallows it, and the panel
        // ⌥Space draws keeps the typed text on screen with the message. This
        // is the same posture in one line.
        captureNotice.font = HelmType.captionSmall()
        captureNotice.lineBreakMode = .byTruncatingTail
        captureNotice.translatesAutoresizingMaskIntoConstraints = false
        captureNotice.isHidden = true
    }

    private func buildFooter() {
        hotkeyHint.translatesAutoresizingMaskIntoConstraints = false
        openWindowButton.target = self
        openWindowButton.action = #selector(openWindowTapped)
        openWindowButton.toolTip = "Leave compact mode and bring the window back"
        openWindowButton.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true

        footerRow.setViews([hotkeyHint, spacer, openWindowButton], in: .leading)
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.distribution = .fill
        footerRow.spacing = HelmMetrics.s2
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.edgeInsets = NSEdgeInsets(top: 0, left: HelmMetrics.s4, bottom: 0, right: HelmMetrics.s3)
    }

    // MARK: Presentation

    /// One open: re-read everything and re-measure.
    ///
    /// Called by `CompactModeController.prepareToShow()`, never on a timer -
    /// the vault pane's own per-second tick is its business and is started by
    /// its `present(codes:vaultUnlocked:)` below.
    func prepareToShow() {
        _ = view   // force `loadView()`; `loadViewIfNeeded()` is macOS 14+
        captureField.stringValue = ""
        hideCaptureNotice()
        renderPane()
        focusCaptureField()
    }

    /// The popover closed. Forwarded to the vault pane so its 1Hz ticker
    /// stops - GL-13 applied to a timer nobody can see, and the same call
    /// `PoneglyphMenuBarController.popoverDidClose` makes.
    func popoverDidClose() {
        vaultPane.stopTicking()
    }

    func select(_ tab: CompactModeTab) {
        guard tab != selected else { return }
        selected = tab
        tabs.select(tab.rawValue)
        hideCaptureNotice()
        captureField.stringValue = ""
        renderPane()
        focusCaptureField()
    }

    /// Build whichever tab is showing, hide the other three, and report the
    /// new height.
    private func renderPane() {
        _ = view
        switch selected {
        case .today:
            todayPane.present(todayProvider?() ?? .empty, theme: theme)
        case .notes:
            notesPane.present(notesProvider?() ?? [], theme: theme)
        case .vault:
            // The real controller's real entry point. `AppDelegate` wires its
            // providers to the one `CredentialVaultController`.
            vaultPane.present(codes: vaultCodesProvider?() ?? [],
                              vaultUnlocked: vaultUnlockedProvider?() ?? false)
        case .crew:
            break   // the crew pane holds its own conversation state across opens
        }

        todayPane.isHidden = selected != .today
        notesPane.isHidden = selected != .notes
        vaultPane.view.isHidden = selected != .vault
        crewPane.view.isHidden = selected != .crew

        let hasCapture = selected.captureDestination != nil
        captureRow.isHidden = !hasCapture
        captureDivider.isHidden = !hasCapture
        if hasCapture { captureField.placeholderString = selected.capturePlaceholder }

        view.layoutSubtreeIfNeeded()
        scrollBodyToTop()
        onSizeChanged?(Self.contentSize)
    }

    /// What the popover is, on every tab. Never measured from the content -
    /// see `height`.
    static var contentSize: NSSize { NSSize(width: width, height: height) }

    private func focusCaptureField() {
        guard selected.captureDestination != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.captureRow.isHidden else { return }
            self.view.window?.makeFirstResponder(self.captureField)
        }
    }

    // MARK: Actions

    @objc private func captureSubmitted() {
        guard let destination = selected.captureDestination else { return }
        let typed = captureField.stringValue
        let draft = CaptureRouter.draft(from: typed)
        guard !draft.isEmpty else { return }
        switch captureFiler.file(destination, draft) {
        case .filed, .handedOff:
            captureField.stringValue = ""
            hideCaptureNotice()
            // The tab the capture landed on is the tab showing, so the new
            // row appears without the captain having to reopen anything.
            renderPane()
        case .refused(let why):
            // The typed text stays in the field. Losing a capture to a
            // failure is the one outcome ⌥Space's own panel refuses to allow,
            // and this is the same rule.
            showCaptureNotice(why)
        }
    }

    private func showCaptureNotice(_ text: String) {
        captureNotice.stringValue = text
        captureNotice.isHidden = false
        captureNotice.textColor = HelmContrast.legibleTintedText(
            tintHex: HelmTint.critical.hex(in: theme),
            overAnyOf: [HelmTheme.nsColor(theme.chromeBackgroundHex)],
            theme: theme)
        view.layoutSubtreeIfNeeded()
        // The notice lives in the bottom group, so showing it takes its room
        // out of the body region rather than out of the popover's frame - but
        // the size is still reported, because `NSPopover` re-reads it and a
        // caller that stops hearing about layout changes is one refactor away
        // from a stale frame.
        onSizeChanged?(Self.contentSize)
    }

    private func hideCaptureNotice() {
        guard !captureNotice.isHidden else { return }
        captureNotice.isHidden = true
        captureNotice.stringValue = ""
    }

    @objc private func settingsTapped() { onOpenSettings?() }
    @objc private func openWindowTapped() { onOpenFullWindow?() }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        _ = view
        // `ThemeManager.swift`'s checklist item 2. The popover's own
        // appearance is forced by `CompactModeController`; this is the
        // content's half - without the explicit `appearance` on this view
        // every system-semantic colour inside it (the field editor AppKit
        // lends `captureField`, the focus ring, an `NSMenu`) would resolve
        // against the OS rather than the Helm theme.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor

        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        modeLabel.textColor = HelmTheme.mutedInk(theme)
        let hairline = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.dividerAlpha)
        for divider in [headerDivider, captureDivider, footerDivider] {
            divider.layer?.backgroundColor = hairline.cgColor
        }
        iconTile.applyTheme(theme)
        tabs.applyTheme(theme)
        hotkeyHint.applyTheme(theme)
        todayPane.applyTheme(theme)
        notesPane.applyTheme(theme)
        vaultPane.applyTheme(theme)
        crewPane.applyTheme(theme)
        if !captureNotice.isHidden { showCaptureNotice(captureNotice.stringValue) }
        // `settingsButton`, `captureButton` and `openWindowButton` are
        // `HelmButton`s and theme themselves - a page must never set their
        // font, title attributes, tint or bezel (the component index's own
        // rule, source-guarded).
    }

    #if FM_SELFTESTS
    var debugSelectedTab: CompactModeTab { selected }
    var debugTabs: HelmSegmentedTabs { tabs }
    var debugTodayPane: CompactTodayPane { todayPane }
    var debugNotesPane: CompactNotesPane { notesPane }
    var debugCaptureRowIsHidden: Bool { captureRow.isHidden }
    var debugBodyScroll: NSScrollView { bodyScroll }
    /// The chrome's own frames, so a suite can assert they do not move
    /// between tabs rather than only that the outer frame matches.
    var debugChromeFrames: [String: NSRect] {
        // In the root's own coordinates: each of these sits inside a group
        // stack, so a raw `.frame` would compare two different spaces.
        func inRoot(_ v: NSView) -> NSRect { v.convert(v.bounds, to: view) }
        return ["tabs": inRoot(tabs), "footer": inRoot(footerRow),
                "header": inRoot(headerRow), "body": inRoot(bodyScroll)]
    }
    var debugCaptureNotice: String? { captureNotice.isHidden ? nil : captureNotice.stringValue }
    var debugCaptureField: HelmTextField { captureField }
    var debugOpenWindowButton: HelmButton { openWindowButton }
    var debugSettingsButton: HelmButton { settingsButton }
    var debugVisiblePaneCount: Int {
        [todayPane.isHidden, notesPane.isHidden, vaultPane.view.isHidden, crewPane.view.isHidden]
            .filter { !$0 }.count
    }
    func debugSubmitCapture() { captureSubmitted() }
    func debugRenderPane() { renderPane() }
    #endif
}

// MARK: - The Today pane

/// The mockup's Today tab: up to `CompactModeDigest.maxRows` due tasks, each
/// with a real checkbox, then the focus and follow-up chips.
final class CompactTodayPane: NSView {
    var onSetTaskCompleted: ((String, Bool) -> Void)?
    var onOpenTasks: (() -> Void)?

    private let rowsStack = NSStackView()
    private let chipsRow = NSStackView()
    private let chipsDivider = NSView()
    private let focusChip = CompactChip()
    private let followUpChip = CompactChip()
    private let emptyState = HelmEmptyState(
        symbol: "checkmark.circle",
        body: "Nothing is due. Capture something below, or open Tasks for the whole list.",
        size: .compact)
    private let openTasksButton = HelmButton(title: "Open Tasks \u{2192}", variant: .quiet, size: .small)
    private let column = NSStackView()

    private var rows: [CompactTaskRowView] = []
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        chipsDivider.wantsLayer = true
        chipsDivider.translatesAutoresizingMaskIntoConstraints = false
        chipsDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let chipSpacer = NSView()
        chipSpacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = chipSpacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        chipsRow.setViews([focusChip, followUpChip, chipSpacer], in: .leading)
        chipsRow.orientation = .horizontal
        chipsRow.alignment = .centerY
        chipsRow.distribution = .fill
        chipsRow.spacing = HelmMetrics.s1 + 2
        chipsRow.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        openTasksButton.target = self
        openTasksButton.action = #selector(openTasksTapped)
        openTasksButton.translatesAutoresizingMaskIntoConstraints = false

        column.setViews([rowsStack, emptyState, chipsDivider, chipsRow, openTasksButton], in: .leading)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s3),
            column.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s2),
        ])
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func present(_ digest: CompactTodayDigest, theme: HelmTheme) {
        self.theme = theme
        // `autoreleasepool` around a repeated AppKit construct/teardown loop
        // in a process that may have no run loop turning - AGENTS.md's own
        // mandatory rule for a headless suite, and this is the loop a suite
        // drives hardest.
        autoreleasepool {
            for row in rows {
                rowsStack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = digest.rows.map { model in
                let row = CompactTaskRowView(model: model)
                row.onToggle = { [weak self] in self?.onSetTaskCompleted?(model.id, true) }
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                return row
            }
        }

        rowsStack.isHidden = digest.isEmpty
        emptyState.isHidden = !digest.isEmpty

        focusChip.isHidden = digest.focusChip == nil
        followUpChip.isHidden = digest.followUpChip == nil
        if let focus = digest.focusChip { focusChip.configure(symbol: "clock", text: focus) }
        if let followUp = digest.followUpChip { followUpChip.configure(symbol: "bell", text: followUp) }
        // The divider belongs to the chips, so it goes when they do rather
        // than leaving a rule under nothing.
        let hasChips = digest.focusChip != nil || digest.followUpChip != nil
        chipsRow.isHidden = !hasChips
        chipsDivider.isHidden = !hasChips

        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        chipsDivider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(HelmCard.dividerAlpha).cgColor
        emptyState.applyTheme(theme)
        // The focus chip carries the accent as identity; the follow-up chip
        // deliberately does not. AGENTS.md: `HelmTint.neutral` washed as a
        // *tinted surface* resolves to `chromeInkHex` and produces a
        // near-black chip, so a no-identity chip wants `HelmField.fill` plus
        // ink text instead - which is what `CompactChip.neutral` paints.
        focusChip.applyTheme(theme, tint: .accent)
        followUpChip.applyTheme(theme, tint: nil)
        for row in rows { row.applyTheme(theme) }
    }

    @objc private func openTasksTapped() { onOpenTasks?() }

    #if FM_SELFTESTS
    var debugRowTitles: [String] { rows.map { $0.debugTitle } }
    var debugRowCheckboxColors: [NSColor] { rows.map { $0.debugCheckboxBorderColor } }
    var debugRows: [CompactTaskRowView] { rows }
    var debugEmptyStateIsHidden: Bool { emptyState.isHidden }
    var debugChipsAreHidden: Bool { chipsRow.isHidden }
    var debugChipTexts: [String] {
        [focusChip, followUpChip].filter { !$0.isHidden }.map { $0.debugText }
    }
    #endif
}

// MARK: - The Notes pane

/// The third popover the report says did not exist: the Sticky Board's newest
/// notes, each opening the board on that note.
///
/// Built to `PoneglyphMenuBarPopoverController`'s shape rather than to a new
/// one - a rows stack, a loud empty state, and one persistent "Open …"
/// affordance at the bottom - because that is the convention the two existing
/// menu-bar surfaces already established and the spec's own instruction was
/// to follow it rather than invent a third style.
final class CompactNotesPane: NSView {
    var onRevealNote: ((String) -> Void)?
    var onOpenBoard: (() -> Void)?

    private let rowsStack = NSStackView()
    private let emptyState = HelmEmptyState(
        symbol: "note.text",
        body: "The Sticky Board is empty. Capture a note below and it lands on the board.",
        size: .compact)
    private let openBoardButton = HelmButton(title: "Open Sticky Board \u{2192}", variant: .quiet, size: .small)
    private let column = NSStackView()

    private var rows: [CompactNoteRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        openBoardButton.target = self
        openBoardButton.action = #selector(openBoardTapped)
        openBoardButton.translatesAutoresizingMaskIntoConstraints = false

        column.setViews([rowsStack, emptyState, openBoardButton], in: .leading)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s3),
            column.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s2),
        ])
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func present(_ notes: [CompactNoteRow], theme: HelmTheme) {
        autoreleasepool {
            for row in rows {
                rowsStack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = notes.map { model in
                let row = CompactNoteRowView(model: model)
                row.onClick = { [weak self] in self?.onRevealNote?(model.id) }
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                return row
            }
        }
        rowsStack.isHidden = notes.isEmpty
        emptyState.isHidden = !notes.isEmpty
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        emptyState.applyTheme(theme)
        for row in rows { row.applyTheme(theme) }
    }

    @objc private func openBoardTapped() { onOpenBoard?() }

    #if FM_SELFTESTS
    var debugRowTitles: [String] { rows.map { $0.debugTitle } }
    var debugRowDetails: [String] { rows.map { $0.debugDetail } }
    var debugEmptyStateIsHidden: Bool { emptyState.isHidden }
    var debugRows: [CompactNoteRowView] { rows }
    #endif
}

// MARK: - Rows

/// One task row: a checkbox, a title and its urgency caption.
///
/// A `HoverHighlightView` because it is a clickable row, which per GL-16 is
/// what supplies the role, the label, the focus ring and the keyboard press -
/// there is no hand-rolled hover fill or tracking area here.
final class CompactTaskRowView: HoverHighlightView {
    var onToggle: (() -> Void)?

    private let checkbox = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let model: CompactTaskRow

    init(model: CompactTaskRow) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = HelmMetrics.rChip + 1
        accessibilityRoleOverride = .checkBox
        accessibilityLabelOverride = "\(model.title) - \(model.detail)"
        accessibilityValueOverride = "not done"
        onAccessibilityPress = { [weak self] in self?.onToggle?() }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))

        checkbox.wantsLayer = true
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.layer?.cornerRadius = 4
        checkbox.layer?.borderWidth = 1.6

        titleLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = model.title
        detailLabel.font = HelmType.captionSmall()
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.stringValue = model.detail

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(checkbox)
        addSubview(text)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            checkbox.widthAnchor.constraint(equalToConstant: 14),
            checkbox.heightAnchor.constraint(equalToConstant: 14),
            text.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: HelmMetrics.s2),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        // Only the text may compress. Gotcha (5): with every subview left at
        // AppKit's equal default, a long title squeezes the checkbox too.
        checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onToggle?() }

    func applyTheme(_ theme: HelmTheme) {
        normalColor = .clear
        hoverColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.06)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        // The urgency is carried by both the caption's colour and the
        // checkbox's border, never by colour alone - GL-16's own posture, and
        // the detail string already says "overdue" in words.
        let accent = urgencyColor(theme)
        detailLabel.textColor = accent
        checkbox.layer?.borderColor = checkboxBorderColor(theme).cgColor
    }

    /// A tinted *caption* is text, so it goes through `HelmContrast` rather
    /// than taking the raw hue - AGENTS.md's "a `HelmTint` hue is safe as a
    /// fill and is NOT automatically safe as text".
    private func urgencyColor(_ theme: HelmTheme) -> NSColor {
        switch model.urgency {
        case .overdue:
            return HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                                  over: HelmTheme.nsColor(theme.chromeBackgroundHex),
                                                  theme: theme)
        case .today, .later:
            return HelmTheme.mutedInk(theme)
        }
    }

    /// A 14pt square's border is a non-text UI component, so the honest floor
    /// is 3:1 rather than 4.5:1 - and it is the same resolved hue the caption
    /// uses for the overdue case, so the two cannot drift apart.
    private func checkboxBorderColor(_ theme: HelmTheme) -> NSColor {
        switch model.urgency {
        case .overdue:
            return urgencyColor(theme)
        case .today:
            return HelmContrast.legibleTintedText(tintHex: HelmTint.warn.hex(in: theme),
                                                  over: HelmTheme.nsColor(theme.chromeBackgroundHex),
                                                  theme: theme)
        case .later:
            return HelmTheme.nsColor(theme.chromeLineHex)
        }
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugUrgency: CompactTaskRow.Urgency { model.urgency }
    var debugCheckboxBorderColor: NSColor {
        guard let cg = checkbox.layer?.borderColor else { return .clear }
        return NSColor(cgColor: cg) ?? .clear
    }
    var debugDetailColor: NSColor { detailLabel.textColor ?? .clear }
    func debugClick() { clicked() }
    #endif
}

/// One sticky-note row: the note's own paper colour as a swatch, its title
/// and its detail.
final class CompactNoteRowView: HoverHighlightView {
    var onClick: (() -> Void)?

    private let swatch = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let model: CompactNoteRow

    init(model: CompactNoteRow) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = HelmMetrics.rChip + 1
        accessibilityRoleOverride = .button
        accessibilityLabelOverride = "\(model.title) - \(model.detail)"
        onAccessibilityPress = { [weak self] in self?.onClick?() }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))

        swatch.wantsLayer = true
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.layer?.cornerRadius = 3
        // The note's own paper colour, so the row carries the same identity
        // the board does - a literal hex the captain chose, which no
        // `HelmTint` case honestly describes (the distinction
        // `IconTileView.literalHex` already draws).
        swatch.layer?.backgroundColor = HelmTheme.nsColor(model.color.paperHex).cgColor

        titleLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = model.title
        detailLabel.font = HelmType.captionSmall()
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.stringValue = model.detail
        detailLabel.isHidden = model.detail.isEmpty

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(swatch)
        addSubview(text)
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            swatch.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            swatch.widthAnchor.constraint(equalToConstant: 12),
            swatch.heightAnchor.constraint(equalToConstant: 12),
            text.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: HelmMetrics.s2),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        swatch.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    func applyTheme(_ theme: HelmTheme) {
        normalColor = .clear
        hoverColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.06)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugSwatchColor: NSColor {
        guard let cg = swatch.layer?.backgroundColor else { return .clear }
        return NSColor(cgColor: cg) ?? .clear
    }
    func debugClick() { clicked() }
    #endif
}

// MARK: - The chip

/// A small, non-interactive "symbol + text" chip, for the Today tab's focus
/// and follow-up counts.
///
/// A local view rather than a reach for a shared component, and worth saying
/// why: this app has no shared chip. The two closest things are
/// `HelmCountBadge` (a bare number in a card header's action slot, no symbol,
/// no text) and `CaptureChip`/`ReadingListCardView.chip`, which are both
/// *clickable* and private to their own surfaces. Promoting one of those into
/// a shared component is a design-system change and does not belong in a
/// feature branch - so this stays deliberately small and local, and the
/// component index is not being contradicted.
final class CompactChip: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var symbolName: String = "clock"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rChip

        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = HelmType.captionSmall()
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 10),
            icon.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: label.topAnchor, constant: -3),
            bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(symbol: String, text: String) {
        symbolName = symbol
        label.stringValue = text
    }

    /// `tint: nil` is the no-identity chip: `HelmField.fill` plus ink, never
    /// a `HelmTint.neutral` wash - see `CompactTodayPane.applyTheme`.
    func applyTheme(_ theme: HelmTheme, tint: HelmTint?) {
        let fill: NSColor
        let foreground: NSColor
        if let tint {
            let resolved = HelmContrast.tintedSurface(tintHex: tint.hex(in: theme),
                                                      theme: theme,
                                                      target: HelmContrast.textTarget)
            fill = resolved.fill
            foreground = resolved.foreground
        } else {
            fill = HelmField.fill(theme)
            foreground = HelmTheme.mutedInk(theme)
        }
        layer?.backgroundColor = fill.cgColor
        label.textColor = foreground
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        icon.contentTintColor = foreground
    }

    #if FM_SELFTESTS
    var debugText: String { label.stringValue }
    var debugTextColor: NSColor { label.textColor ?? .clear }
    var debugFillColor: NSColor {
        guard let cg = layer?.backgroundColor else { return .clear }
        return NSColor(cgColor: cg) ?? .clear
    }
    #endif
}
