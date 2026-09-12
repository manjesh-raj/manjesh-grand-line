// Manjesh Grand Line - native macOS app.
//
// The Straw Hat Pirates menu-bar item (`fm/straw-hat-menubar-quick-chat-
// popover`): a status-bar icon opening a lightweight quick-chat popover,
// mirroring `ShiftMenuBarController`'s shape (`ShiftMenuBar.swift`) - an
// `NSStatusItem` + a `.transient` `NSPopover`, the same lock-gating and live
// `ThemeManager` observation, the same "content is a plain `NSViewController`,
// not a shared destination controller" call.
//
// ## The captain's own framing, and why this is deliberately small
//
// He compared this to the existing Shift menu-bar popover (today's tasks,
// the next follow-up, a one-line quick-add) and asked whether the crew could
// have something similar. Firstmate's own recommendation - which he
// accepted - was explicit that a full multi-turn thread with confirm cards
// needs more room than a small popover affords, so this mirrors the Tasks
// popover's *shape* (icon -> popover -> one field -> one result) rather than
// shrinking the real Straw Hat Pirates page down to fit here. A proposal
// never renders as a confirm card in this popover - see
// `StrawHatMenuBarPopoverController`'s own header for what it shows instead
// and why.
//
// ## The ask is never a second, disconnected conversation
//
// `onAsk` is wired by `AppDelegate` to `AppShellController.askCrewFromMenuBar`,
// which forwards straight into `StrawHatController.send(_:completion:)` -
// the SAME runner and the SAME real transcript the crew page's own composer
// uses. So a question typed here lands in the one conversation the app has
// with the crew: if it carries a proposal, opening the real page afterward
// shows a genuine, working confirm card for it, not a re-asked question. See
// `StrawHatController.send(_:completion:)`'s own doc comment for the full
// reasoning, and `StrawHatRunner.ask`'s `AppLockedSurface.strawHatChat` gate
// for why the ask itself is already locked-app-safe with no extra wiring
// here - this file only needs its own case (`.strawHatMenuBarPopover`) for
// whether the popover may *open* at all, since a reopened popover can still
// show a previous reply from before the lock engaged.
//
// ## The Jolly Roger, resized without touching the shared cache
//
// `StrawHatFlag.image` is a cached singleton also handed to the Overview
// card's tile and the shell's drill header (`RailDestination.
// drillHeaderArtwork`) at its full 128px size - mutating its `.size`
// in place to fit a status-item glyph would silently rescale it everywhere
// else that reads it. `Self.statusItemIcon()` draws a fresh, independent
// copy at menu-bar size instead.

import AppKit

final class StrawHatMenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let content = StrawHatMenuBarPopoverController()
    private var themeObservation: ThemeObservation?

    /// The captain's trimmed message, plus a completion the popover calls
    /// once with the outcome. Set by `AppDelegate` to
    /// `AppShellController.askCrewFromMenuBar(_:completion:)`.
    var onAsk: ((String, @escaping (Result<[StrawHatSection], StrawHatError>) -> Void) -> Void)?
    /// "Open Straw Hat Pirates \u{2192}" - set by `AppDelegate` to
    /// `AppShellController.show(.strawHat)`.
    var onOpenFullChat: (() -> Void)?

    override init() {
        super.init()
        // Audit 2 §2.7/§6.2, and `LockGateCoverageSelfTest`'s own structural
        // guard: a popover is its own window, layered above the lock
        // overlay, so anything open when the lock fires would stay readable
        // and interactive over the lock screen. Weak, because there is no
        // unregister.
        AppLockGate.shared.registerLockDismissiblePopover { [weak self] in self?.popover }

        if let button = statusItem.button {
            button.image = Self.statusItemIcon()
            button.toolTip = "Ask the crew"
            button.target = self
            button.action = #selector(iconClicked)
        }

        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onAsk = { [weak self] text, completion in self?.onAsk?(text, completion) }
        content.onOpenFullChat = { [weak self] in
            self?.onOpenFullChat?()
            self?.popover.performClose(nil)
        }
        content.onSizeChanged = { [weak self] size in self?.popover.contentSize = size }

        // GL-09: mirrors `ShiftMenuBarController`'s own lock observer - close
        // the popover immediately on every lock transition, belt to
        // `registerLockDismissiblePopover`'s brace.
        AppLockGate.shared.observe { [weak self] _ in
            self?.popover.performClose(nil)
        }

        // `ThemeManager.observe` fires synchronously at registration, which
        // is safe here: `popover` and `content` are both stored `let`s
        // initialised inline, so they exist by the time `init` runs this
        // line of its own body.
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
    }

    @objc private func iconClicked() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // GL-09: locked means the popover does not open at all - an empty
        // popover invites a second click, and a re-shown one could still
        // carry a previous reply from before the lock engaged.
        guard AppLockGate.shared.allows(.strawHatMenuBarPopover) else {
            AppLog.lifecycle.info("straw hat menu-bar popover refused - app is locked (GL-09)")
            NSSound.beep()
            return
        }
        prepareToShow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Everything an open does before the popover is actually put on
    /// screen - split out, like `ShiftMenuBarController.prepareToShow()`, so
    /// a self-test can drive the real path without a live `statusItem.button`
    /// and without actually showing a popover.
    private func prepareToShow() {
        // `ThemeManager.swift`'s checklist item 2, applied to a popover - the
        // theme can change between two opens, and `NSPopover` reads its
        // appearance when it is shown.
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        content.applyTheme(ThemeManager.shared.theme)
        content.prepareForOpen()
    }

    /// A fresh, independent copy of the Jolly Roger sized for the status
    /// item - never a mutation of `StrawHatFlag.image`'s own `.size`, which
    /// would rescale it everywhere else that reads the shared cache (see
    /// this file's header). Falls back to `RailDestination.strawHat.symbol`
    /// (`"person.3.fill"`) when the payload cannot be decoded, exactly as
    /// every other reader of `StrawHatFlag.image` already does.
    private static func statusItemIcon() -> NSImage? {
        guard let source = StrawHatFlag.image else {
            return NSImage(systemSymbolName: RailDestination.strawHat.symbol, accessibilityDescription: "Ask the crew")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        }
        let side: CGFloat = 18
        guard let copy = source.copy() as? NSImage else { return source }
        copy.size = NSSize(width: side, height: side)
        copy.isTemplate = false
        return copy
    }

    #if FM_SELFTESTS
    var debugPopover: NSPopover { popover }
    var debugContent: StrawHatMenuBarPopoverController { content }
    func debugPrepareToShow() { prepareToShow() }
    /// Drives the real click-to-open path, including the lock check -
    /// `debugPrepareToShow()` alone skips it.
    ///
    /// **Only safe to call while the app is locked.** `iconClicked()`'s
    /// unlocked branch reaches `popover.show(relativeTo:of:preferredEdge:)`,
    /// which raises `NSInvalidArgumentException` ("view has no window") when
    /// its anchor has none - `StrawHatHandoffSelfTest`'s own documented
    /// finding for the identical AppKit call, one popover over. A headless
    /// self-test process never runs `NSApp.run()`, so `statusItem.button`'s
    /// window cannot be trusted to exist - see `debugHasStatusButton`.
    func debugIconClicked() { iconClicked() }
    /// Whether this process's status item resolved a real, addressable
    /// button at all - a headless self-test binary may or may not get one,
    /// depending on the environment it runs in. A suite reads this before
    /// treating a `debugIconClicked()` result as proof of anything: without
    /// a button, `iconClicked()`'s own first `guard` returns before ever
    /// reaching the lock check, so "the popover did not open" would be true
    /// for a reason that has nothing to do with `AppLockGate`.
    var debugHasStatusButton: Bool { statusItem.button != nil }
    #endif
}

/// The popover's content: a header, a compact reply area, a one-line field +
/// Ask button, and a persistent "Open Straw Hat Pirates" link.
///
/// ## What this deliberately does not do
///
/// It never renders a `StrawHatConfirmCard` or a `StrawHatHandoffRow` - the
/// task's own scope is explicit that a full scrolling thread with proposals
/// and confirm cards crammed into popover-sized real estate is the wrong
/// shape here, and "every write is yours to confirm" still applies: a
/// proposal is summarised (kind + title, no button) with a note pointing at
/// the real page, never auto-confirmed and never actionable from inside
/// this popover. A navigation handoff is treated the same way for the same
/// reason, even though following one writes nothing - staying uniform here
/// is simpler than teaching a captain two different meanings for a note in
/// this one small surface.
///
/// Only the reply that just landed is shown, capped at one section (the
/// first one with a speaker) plus a small "+N more from the crew" note when
/// the reply carried others - a second surface for browsing the whole
/// transcript is exactly what the real page already is.
///
/// Deliberately internal, not `private` - `RecentDestinationsPanelViewController`'s
/// own precedent (`RecentDestinationsPopover.swift`), since a `debug*`
/// property on `StrawHatMenuBarController` that returns this type has to be
/// reachable from a separate self-test file to be worth anything.
final class StrawHatMenuBarPopoverController: NSViewController {

    static let width: CGFloat = 320

    private let iconTile = IconTileView(size: 26, cornerRadius: 7)
    private let titleLabel = NSTextField(labelWithString: "Straw Hat Pirates")

    // Reply/status area - exactly one of these four is ever showing.
    private let hintLabel = NSTextField(wrappingLabelWithString:
        "Ask a quick question - the crew doesn't know what's on your screen, but knows your tasks, docs and health.")
    private let thinkingRow = NSStackView()
    private let thinkingSpinner = HelmProgressBar.inlineActivity(hue: RailDestination.strawHat.domainHue)
    private let thinkingLabel = NSTextField(labelWithString: "The crew is thinking\u{2026}")
    private let replyStack = NSStackView()
    private let replyPortraitSlot = NSView()
    private var replyPortrait: NSView?
    private let replyNameLabel = NSTextField(labelWithString: "")
    private let replyTextLabel = NSTextField(wrappingLabelWithString: "")
    private let replyMoreLabel = NSTextField(labelWithString: "")
    private let replyProposalNote = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    private let divider = NSView()

    private let field = HelmTextField(placeholder: "Message the crew\u{2026}")
    private let askButton = HelmButton(title: "Ask", variant: .primary, size: .small, symbol: "arrow.up")
    private let openFullChatButton = HelmButton(title: "Open Straw Hat Pirates", variant: .quiet, size: .small,
                                                symbol: "arrow.up.forward.square")

    private var theme = ThemeManager.shared.theme
    private var state: State = .idle

    private enum State {
        case idle
        case thinking
        case reply(sections: [StrawHatSection])
        case failed(String)
    }

    var onAsk: ((String, @escaping (Result<[StrawHatSection], StrawHatError>) -> Void) -> Void)?
    var onOpenFullChat: (() -> Void)?
    /// Forwarded straight to `popover.contentSize` - see
    /// `RecentDestinationsPopover`'s own "compute then set" convention,
    /// which this content genuinely needs: the reply area's height varies a
    /// lot between the idle hint, a thinking spinner and a multi-line reply.
    var onSizeChanged: ((NSSize) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 220))
        root.wantsLayer = true
        view = root

        iconTile.configure(symbol: StrawHatCrew.speaker.symbol, tint: StrawHatCrew.speaker.tint)
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [iconTile, titleLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        buildStateViews()

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        buildInputRow()

        openFullChatButton.translatesAutoresizingMaskIntoConstraints = false
        openFullChatButton.target = self
        openFullChatButton.action = #selector(openFullChatTapped)
        openFullChatButton.toolTip = "Everything asked here is one conversation - see the whole thread"

        // The four state views (`hintLabel`/`thinkingRow`/`replyStack`/
        // `errorLabel`) are arranged subviews of `outer` itself, not wrapped
        // in a plain-`NSView` container - AGENTS.md gotcha (11): an ordinary
        // hidden `NSView` still fully participates in Auto Layout's sizing
        // math, so a container pinned to (say) the short idle hint's own
        // height would stay that short even while a much taller reply is the
        // one actually showing. A hidden *arranged subview of an
        // `NSStackView`* is the one case that gotcha names as the exception -
        // it drops out of the stack's layout entirely - which is exactly
        // "size to whichever one is currently visible" with no extra
        // constraint math needed.
        let outer = NSStackView(views: [headerRow, hintLabel, thinkingRow, replyStack, errorLabel,
                                        divider, inputRow, openFullChatButton])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = HelmMetrics.s2 + 2
        outer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outer)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            outer.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            headerRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            hintLabel.widthAnchor.constraint(equalTo: outer.widthAnchor),
            thinkingRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            replyStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: outer.widthAnchor),
            divider.widthAnchor.constraint(equalTo: outer.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            openFullChatButton.widthAnchor.constraint(lessThanOrEqualTo: outer.widthAnchor),
        ])

        applyTheme(theme)
        renderState()
    }

    // MARK: State views

    /// Builds the content of each of the four mutually-exclusive state
    /// views - see `loadView()`'s own note on why they are arranged
    /// subviews of `outer` rather than wrapped in a container.
    /// `renderState()` never adds/removes a subview, only toggles
    /// `isHidden`, so a fast open/ask/open cycle cannot leave two states
    /// overlapping mid-layout.
    private func buildStateViews() {
        hintLabel.font = HelmType.caption()
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        thinkingSpinner.setContentHuggingPriority(.required, for: .horizontal)
        thinkingLabel.font = HelmType.caption()
        thinkingLabel.translatesAutoresizingMaskIntoConstraints = false
        thinkingRow.orientation = .horizontal
        thinkingRow.alignment = .centerY
        thinkingRow.spacing = 8
        thinkingRow.translatesAutoresizingMaskIntoConstraints = false
        for v in [thinkingSpinner, thinkingLabel] { thinkingRow.addArrangedSubview(v) }

        buildReplyStack()

        errorLabel.font = HelmType.caption()
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        for v in [hintLabel, thinkingRow, replyStack, errorLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
    }

    /// The reply area: a portrait/name header (`StrawHatChatView.
    /// attributionHeader`'s own shape, reusing `StrawHatPortraits.image(for:)`
    /// - the same portrait asset, not new art), the reply text, and two
    /// optional notes (more sections; proposals pending).
    private func buildReplyStack() {
        replyPortraitSlot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            replyPortraitSlot.widthAnchor.constraint(equalToConstant: 22),
            replyPortraitSlot.heightAnchor.constraint(equalToConstant: 22),
        ])
        replyNameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        replyNameLabel.translatesAutoresizingMaskIntoConstraints = false
        replyNameLabel.setContentHuggingPriority(.required, for: .horizontal)

        let attributionRow = NSStackView(views: [replyPortraitSlot, replyNameLabel])
        attributionRow.orientation = .horizontal
        attributionRow.alignment = .centerY
        attributionRow.spacing = 7
        attributionRow.translatesAutoresizingMaskIntoConstraints = false

        replyTextLabel.font = HelmType.body()
        replyTextLabel.lineBreakMode = .byWordWrapping
        replyTextLabel.maximumNumberOfLines = 6
        replyTextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        replyTextLabel.translatesAutoresizingMaskIntoConstraints = false

        replyMoreLabel.font = HelmType.captionSmall()
        replyMoreLabel.isHidden = true
        replyMoreLabel.translatesAutoresizingMaskIntoConstraints = false

        replyProposalNote.font = HelmType.captionSmall()
        replyProposalNote.lineBreakMode = .byWordWrapping
        replyProposalNote.isHidden = true
        replyProposalNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        replyProposalNote.translatesAutoresizingMaskIntoConstraints = false

        replyStack.orientation = .vertical
        replyStack.alignment = .leading
        replyStack.spacing = 6
        replyStack.translatesAutoresizingMaskIntoConstraints = false
        for v in [attributionRow, replyTextLabel, replyMoreLabel, replyProposalNote] {
            replyStack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: replyStack.widthAnchor).isActive = true
        }
    }

    private lazy var inputRow: NSView = {
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        askButton.target = self
        askButton.action = #selector(submit)
        askButton.isEnabled = false
        // AGENTS.md's documented `HelmButton` trap: `init` calls `sizeToFit()`
        // and does not clear this, and this button lands in a plain `NSView`
        // row below rather than an `NSStackView`.
        askButton.translatesAutoresizingMaskIntoConstraints = false
        askButton.setContentHuggingPriority(.required, for: .horizontal)
        askButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Explicit constraints, not an `NSStackView` - `StrawHatQuickAskCard`'s
        // own reasoning: with `.fill`, which view absorbs the row's slack is
        // decided by hugging priorities, and pinning the field between the
        // row's leading edge and the button removes the question entirely.
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(field)
        row.addSubview(askButton)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            field.topAnchor.constraint(equalTo: row.topAnchor),
            field.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            field.trailingAnchor.constraint(equalTo: askButton.leadingAnchor, constant: -HelmMetrics.s2),
            askButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            askButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualTo: askButton.heightAnchor),
        ])
        return row
    }()

    private func buildInputRow() {
        _ = inputRow // force the lazy build now, in `loadView`'s own order
    }

    // MARK: Open/reset

    /// Called on every open - `StrawHatMenuBarController.prepareToShow()`.
    /// Clears the field (mirroring `ShiftMenuBarController.focusQuickAdd()`)
    /// but deliberately leaves whatever reply is currently showing alone: a
    /// captain reopening the popover without asking anything new should
    /// still see the last thing the crew said, not a blank box.
    func prepareForOpen() {
        field.stringValue = ""
        updateAskEnabled()
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.field)
        }
    }

    // MARK: Submit

    @objc private func submit() {
        // A turn already in flight (from this popover, or from the real
        // page's own composer - they share one runner) disables both the
        // field and the button below via `updateAskEnabled()`, so this is
        // only reachable once that clears. Guarded here too, since a plain
        // Return can still reach `NSControl.action` on a disabled field in
        // some AppKit versions.
        guard !isThinking else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ask(text)
    }

    private var isThinking: Bool {
        if case .thinking = state { return true }
        return false
    }

    private func ask(_ text: String) {
        field.stringValue = ""
        setState(.thinking)
        guard let onAsk else {
            setState(.failed("This popover isn't connected to the crew right now."))
            return
        }
        onAsk(text) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sections):
                self.setState(.reply(sections: sections))
            case .failure(let error):
                self.setState(.failed(error.message))
            }
        }
    }

    @objc private func openFullChatTapped() {
        onOpenFullChat?()
    }

    // MARK: Rendering

    private func setState(_ newState: State) {
        state = newState
        renderState()
    }

    private func renderState() {
        hintLabel.isHidden = true
        thinkingRow.isHidden = true
        replyStack.isHidden = true
        errorLabel.isHidden = true
        field.isEnabled = !isThinking
        updateAskEnabled()
        if isThinking { thinkingSpinner.startAnimation() } else { thinkingSpinner.stopAnimation() }

        switch state {
        case .idle:
            hintLabel.isHidden = false
        case .thinking:
            thinkingRow.isHidden = false
        case .reply(let sections):
            replyStack.isHidden = false
            renderReply(sections)
        case .failed(let message):
            errorLabel.isHidden = false
            errorLabel.stringValue = message
        }

        applyStateColors()
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(view.fittingSize)
    }

    /// Only the first section carrying a speaker, plus a compact note for
    /// everything else the reply held - see this class's own header for why
    /// the whole reply is never rendered here.
    private func renderReply(_ sections: [StrawHatSection]) {
        let primary = sections.first(where: { $0.speaker != nil }) ?? sections.first
        guard let primary else {
            replyNameLabel.stringValue = ""
            replyTextLabel.stringValue = "The crew answered with nothing to show."
            replyPortrait?.removeFromSuperview()
            replyPortrait = nil
            replyMoreLabel.isHidden = true
            replyProposalNote.isHidden = true
            return
        }

        replyPortrait?.removeFromSuperview()
        replyPortrait = nil
        if let member = primary.speaker {
            replyNameLabel.stringValue = member.displayName
            let portrait = Self.portraitView(for: member, side: 22)
            replyPortraitSlot.addSubview(portrait)
            NSLayoutConstraint.activate([
                portrait.leadingAnchor.constraint(equalTo: replyPortraitSlot.leadingAnchor),
                portrait.trailingAnchor.constraint(equalTo: replyPortraitSlot.trailingAnchor),
                portrait.topAnchor.constraint(equalTo: replyPortraitSlot.topAnchor),
                portrait.bottomAnchor.constraint(equalTo: replyPortraitSlot.bottomAnchor),
            ])
            replyPortrait = portrait
        } else {
            // Rung 2 - the model named a voice that is not aboard. Same rule
            // as the real transcript: the text still shows, credited to
            // nobody, rather than crediting a member who did not say it.
            replyNameLabel.stringValue = "The crew"
        }
        replyTextLabel.stringValue = primary.text.isEmpty
            ? "(no reply text)"
            : Self.cleanedForCompactDisplay(primary.text)

        let extra = sections.count - 1
        replyMoreLabel.isHidden = extra <= 0
        if extra > 0 {
            replyMoreLabel.stringValue = extra == 1 ? "+1 more from the crew" : "+\(extra) more from the crew"
        }

        // Every proposal in the whole reply, not just the primary section -
        // a captain should never lose track of one because it landed on a
        // section this popover did not choose to show.
        let proposalCount = sections.reduce(0) { $0 + $1.proposals.count }
        replyProposalNote.isHidden = proposalCount == 0
        if proposalCount > 0 {
            let noun = proposalCount == 1 ? "1 draft" : "\(proposalCount) drafts"
            replyProposalNote.stringValue = "\u{2192} \(noun) ready to review - confirm on the full page. Nothing is written yet."
        }
    }

    /// A crew member's face at popover scale - the same asset
    /// `StrawHatPortraitTile` uses (`StrawHatPortraits.image(for:)`), with a
    /// plain SF Symbol fallback and no "contributing" ring/pulse: this is a
    /// static attribution, not a live indicator, so `StrawHatPortraitTile`'s
    /// lit/dim states (and their animation) do not fit here.
    private static func portraitView(for member: StrawHatMember, side: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = side / 2
        container.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: side),
            container.heightAnchor.constraint(equalToConstant: side),
        ])
        if let portrait = StrawHatPortraits.image(for: member) {
            let imageView = NSImageView()
            imageView.image = portrait
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        } else {
            let tile = IconTileView(size: side, cornerRadius: side / 2)
            tile.configure(symbol: member.symbol, tint: member.tint, pointSize: side * 0.45)
            container.addSubview(tile)
            NSLayoutConstraint.activate([
                tile.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                tile.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                tile.topAnchor.constraint(equalTo: container.topAnchor),
                tile.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    /// A light markdown clean-up for this popover's multi-line reply text -
    /// not a parser (`SRELeadMarkdown`/`StrawHatChatView`'s own rendering is
    /// the real thing, on the real page): strips backticks and bold markers
    /// and the leading marker off a bullet/heading line, per line, the same
    /// stripping `StrawHatController.previewLine(of:)` already does for the
    /// Overview card's one-line preview - just kept multi-line here instead
    /// of collapsed to the first line, since this area has room for more
    /// than one.
    private static func cleanedForCompactDisplay(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "-*#>".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "`", with: "")
            line = line.replacingOccurrences(of: "**", with: "")
            lines.append(line)
        }
        // Collapse runs of blank lines a fenced code block leaves behind -
        // a wall of empty lines reads as broken in a compact area.
        var cleaned: [String] = []
        for line in lines {
            if line.isEmpty, cleaned.last?.isEmpty == true { continue }
            cleaned.append(line)
        }
        while cleaned.first?.isEmpty == true { cleaned.removeFirst() }
        while cleaned.last?.isEmpty == true { cleaned.removeLast() }
        return cleaned.joined(separator: "\n")
    }

    // MARK: Field delegate

    private func updateAskEnabled() {
        let hasText = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        askButton.isEnabled = hasText && !isThinking
    }

    // MARK: Theming

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        iconTile.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        applyStateColors()
        // `field`/`askButton`/`openFullChatButton` are Helm components and
        // theme themselves - never set a `HelmButton`'s font/`attributedTitle`
        // /`contentTintColor` or a `HelmTextField`'s colours from here.
    }

    private func applyStateColors() {
        hintLabel.textColor = HelmTheme.mutedInk(theme)
        thinkingLabel.textColor = HelmTheme.mutedInk(theme)
        replyNameLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        replyTextLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        replyMoreLabel.textColor = HelmTheme.mutedInk(theme)
        // A hue is never safe as text on its own (`HelmContrast`'s own rule,
        // audit §5.7) - correct both tinted notes against the surface they
        // sit on rather than painting the raw hex.
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        replyProposalNote.textColor = HelmContrast.legibleTintedText(
            tintHex: HelmTint.accent.hex(in: theme), over: surface, theme: theme)
        errorLabel.textColor = HelmContrast.legibleTintedText(
            tintHex: HelmTint.critical.hex(in: theme), over: surface, theme: theme)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugField: HelmTextField { field }
    var debugAskButton: HelmButton { askButton }
    var debugOpenFullChatButton: HelmButton { openFullChatButton }
    var debugAskEnabled: Bool { askButton.isEnabled }
    /// Types into the real field through the same delegate callback a
    /// keystroke reaches.
    func debugType(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    func debugPressAsk() { askButton.performClick(nil as Any?) }
    var debugStateDescription: String {
        switch state {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .reply: return "reply"
        case .failed: return "failed"
        }
    }
    var debugHintVisible: Bool { !hintLabel.isHidden }
    var debugThinkingVisible: Bool { !thinkingRow.isHidden }
    var debugReplyVisible: Bool { !replyStack.isHidden }
    var debugErrorVisible: Bool { !errorLabel.isHidden }
    var debugReplyName: String { replyNameLabel.stringValue }
    var debugReplyText: String { replyTextLabel.stringValue }
    var debugReplyMoreVisible: Bool { !replyMoreLabel.isHidden }
    var debugReplyMoreText: String { replyMoreLabel.stringValue }
    var debugProposalNoteVisible: Bool { !replyProposalNote.isHidden }
    var debugProposalNoteText: String { replyProposalNote.stringValue }
    var debugErrorText: String { errorLabel.stringValue }
    var debugReplyPortraitVisible: Bool { replyPortrait != nil }
    /// Forces a state directly, for a suite that wants to check rendering
    /// without driving a real (fake-`claude`-backed) turn.
    func debugSetState(reply sections: [StrawHatSection]) { setState(.reply(sections: sections)) }
    func debugSetState(failed message: String) { setState(.failed(message)) }
    func debugSetThinking() { setState(.thinking) }
    #endif
}

extension StrawHatMenuBarPopoverController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateAskEnabled()
    }
}
