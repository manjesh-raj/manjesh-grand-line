// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates **phase 3**, milestone M3.3: "Ask your crew" - a
// quick-capture card on Overview's own dashboard tab.
//
// ## The friction this removes, and where it therefore lives
//
// The full chat surface has been on Overview's **Crew** tab since phase 1.
// This is the other half of that placement: a captain looking at the
// dashboard who thinks of something has to click across to Crew, wait for
// the pane, and then start typing. M3.3's whole scope is one field on the
// page they are already on - type, press Return, and the app switches to the
// Crew tab with a **new** conversation already under way.
//
// So this card sits in `FleetController`'s `overviewContainer`, beside the
// morning briefing and the stat tiles, rather than on the Daylight canvas.
// The brief points at `HomeCanvasController.swift` for "the existing Overview
// card patterns", and that pointer was worth checking rather than following:
//
//  - Phase 1 never touched that file (the Crew tab is `FleetController`'s),
//    and the friction M3.3 names is "navigate to the Crew tab" - which is
//    friction felt from *this* page, one tab away, not from the canvas.
//  - A canvas module is a `HelmModuleCard`, whose whole surface is a single
//    activatable `.button` with one of six fixed body kinds and one fixed
//    `standardHeight`. A live text field inside a button-role card would
//    fight both, and "quick capture" without a field is only navigation
//    wearing its name.
//
// A canvas card that merely *opened* this one would be a reasonable later
// addition; it is not what the milestone asks for and is not built here.
//
// ## Why a new conversation rather than the current one
//
// M3.3 says "quick capture into a new conversation", and that is the honest
// behaviour for a field with no transcript above it: the captain cannot see
// what was said before, so a message appended to a three-turn-old thread
// would be answered in a context they are not looking at. `sendFromQuickAsk`
// resets the runner first, exactly as the Crew tab's own "New conversation"
// button does.
//
// ## What this view is not
//
// It holds no runner, no store and no session. It reports the captain's
// trimmed text through `onSubmit` and nothing else - the same seam
// `StrawHatChatView` documents for itself, so both entry points converge on
// one turn cycle in `FleetController+Crew` rather than each owning a copy.

import AppKit

/// Overview's own one-field way into a crew conversation.
final class StrawHatQuickAskCard: NSView {

    /// Fires with the captain's trimmed, non-empty message.
    var onSubmit: ((String) -> Void)?

    private let card = HelmCard()
    private let field = HelmTextField(placeholder: "Ask the crew, or say what you need doing\u{2026}",
                                      style: .prominent)
    private let askButton = HelmButton(title: "Ask", variant: .primary, size: .small, symbol: "arrow.up")
    private let hint = NSTextField(labelWithString: "Starts a new conversation on the Crew tab")
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        card.translatesAutoresizingMaskIntoConstraints = false
        card.setHeader(symbol: StrawHatCrew.speaker.symbol,
                       tint: StrawHatCrew.speaker.tint,
                       title: "Ask your crew",
                       subtitle: "Every write they propose is still a card you confirm.")

        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        // §6.9's own focus hue for this page, so the well's glow matches the
        // destination it lives on rather than defaulting to the app accent.
        field.domainHue = RailDestination.overview.domainHue
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        askButton.target = self
        askButton.action = #selector(submit)
        askButton.isEnabled = false
        // AGENTS.md's documented `HelmButton` trap: `init` calls `sizeToFit()`
        // and deliberately does not clear this flag, because everywhere else
        // in this app a `HelmButton` lands in an `NSStackView` (which clears
        // it). This one is in a plain `NSView` row, so AppKit would otherwise
        // synthesise required frame constraints from that fitted size and
        // silently beat every explicit constraint below.
        askButton.translatesAutoresizingMaskIntoConstraints = false
        askButton.setContentHuggingPriority(NSLayoutConstraint.Priority.required,
                                            for: NSLayoutConstraint.Orientation.horizontal)
        askButton.setContentCompressionResistancePriority(NSLayoutConstraint.Priority.required,
                                                          for: NSLayoutConstraint.Orientation.horizontal)

        hint.font = HelmType.captionSmall()
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Explicit constraints rather than a horizontal `NSStackView`, for the
        // reason `ToolRowLayout` and `StrawHatConfirmCard` both ended up here:
        // with `.fill`, which view absorbs the row's slack is decided by
        // hugging priorities, and a priority on a view with no intrinsic
        // content size is a documented no-op (gotcha (12)). Pinning the field
        // between the row's leading edge and the button's removes the question
        // - the button is fixed at the trailing edge and sized by its own
        // title, and the field is whatever is left.
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

        let column = NSStackView(views: [row, hint])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        hint.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        card.setBody(column, insets: HelmCard.contentInsets)

        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called by both the field's own Return action and the Ask button.
    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Cleared before the handler runs, not after: the handler switches
        // tabs, and a field still holding the message the captain has now
        // watched appear in the transcript reads as an unsent draft.
        field.stringValue = ""
        updateEnabled()
        onSubmit?(text)
    }

    private func updateEnabled() {
        askButton.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        hint.textColor = HelmTheme.mutedInk(theme)
        // `field` and `askButton` are Helm components and theme themselves -
        // never set a `HelmButton`'s font/`attributedTitle`/`contentTintColor`
        // from here, `restyle()` owns all of them.
    }

    #if FM_SELFTESTS
    var debugField: HelmTextField { field }
    var debugAskButton: HelmButton { askButton }
    var debugAskEnabled: Bool { askButton.isEnabled }
    var debugText: String { field.stringValue }
    /// Types into the real field through the same delegate callback a
    /// keystroke reaches, so the button's enabled state is exercised by the
    /// production path rather than set directly.
    func debugType(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    func debugPressAsk() { askButton.performClick(nil as Any?) }
    /// The row's resolved geometry, for the "the field takes the slack, the
    /// button keeps its own width" assertion - two views with no intrinsic
    /// size in one row is the exact shape this codebase has measured wrong
    /// three times.
    var debugFrames: String {
        "card=\(card.frame.width) field=\(field.frame.width) button=\(askButton.frame.width)"
    }
    #endif
}

extension StrawHatQuickAskCard: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateEnabled()
    }
}
