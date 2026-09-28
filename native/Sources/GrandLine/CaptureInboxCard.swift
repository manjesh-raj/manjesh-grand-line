// Grand Line - native macOS app.
//
// **UX issue X6 of the 2026-09-27 review.** The list half of the capture
// log - see `CaptureInbox.swift` for what is recorded and why it is a log
// rather than a staging store.
//
// One card, on the Today page, under the daily review: everything captured
// today, newest first, each row saying where it went and opening that page
// when clicked. The review's own sentence for what was missing is "a single
// place showing everything captured today in one place to triage", and the
// page named Today is where that belongs - the daily review is already the
// captain's own day, and X3 has just finished making it the only page that
// means that.
//
// Rows are dismissed, never deleted: forgetting a row says "I have dealt
// with that", and the task or note it points at is untouched. A log that
// deleted the thing it describes would be a second, quieter delete path for
// five stores.

import AppKit

/// Composes `HelmCard` rather than subclassing it - the component index's
/// one card surface is `final`, and wrapping it is what every other
/// card-shaped view in this app does.
final class CaptureInboxCard: NSView {

    /// Fired with the destination a row landed in.
    var onOpenDestination: ((RailDestination) -> Void)?

    private let card = HelmCard()
    private let store: CaptureInboxStore
    private let rowsStack = NSStackView()
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var rowViews: [(view: HoverHighlightView, label: NSTextField, detail: NSTextField)] = []
    private var emptyLabel: NSTextField?

    /// GL-35's other half: the card is a summary, not an archive. Everything
    /// captured today is still in the log; what a card shows is bounded.
    static let maxRows = 8

    init(store: CaptureInboxStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = HelmMetrics.s1
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(rowsStack, insets: HelmCard.contentInsets)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Render

    /// - Parameter now: injected so a suite drives a stated day rather than
    ///   whatever today happens to be, and so the card and the log agree
    ///   about which day that is (AGENTS.md's one-clock rule).
    func render(now: Date = Date(), theme: HelmTheme) {
        self.theme = theme
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews.removeAll()
        emptyLabel = nil

        let entries = store.entries(on: now)
        _ = card.setHeader(symbol: "tray.and.arrow.down",
                           tint: .info,
                           title: "Captured today",
                           subtitle: headerSubtitle(entries.count))

        if store.loadFailed {
            // GL-14: "the log would not parse" and "you captured nothing"
            // are different sentences, and a capture log that quietly
            // reported an empty day would be the worst possible failure for
            // a feature whose whole job is not losing track of things.
            append(muted: "The capture log could not be read - what you captured is still in its "
                        + "own page, but this list cannot show it.")
        } else if entries.isEmpty {
            append(muted: "Nothing captured today. \u{2325}Space files a line straight into Tasks, "
                        + "the board, the notebook, a snippet or the reading list.")
        } else {
            for entry in entries.prefix(Self.maxRows) { append(entry) }
            if entries.count > Self.maxRows {
                append(muted: "+\(entries.count - Self.maxRows) more captured today.")
            }
        }
        applyTheme(theme)
    }

    private func headerSubtitle(_ count: Int) -> String {
        guard !store.loadFailed else { return "log unreadable" }
        return count == 1 ? "1 capture" : "\(count) captures"
    }

    private func append(muted text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = HelmType.caption()
        label.preferredMaxLayoutWidth = 520
        label.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel = label
        rowsStack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func append(_ entry: CaptureInboxEntry) {
        // GL-16: a clickable row is a `HoverHighlightView`, which supplies
        // the role, the label, the focus ring and the keyboard press.
        let row = HoverHighlightView()
        row.wantsLayer = true
        row.cornerRadius = HelmMetrics.rChip
        row.translatesAutoresizingMaskIntoConstraints = false
        row.accessibilityRoleOverride = .button

        let title = NSTextField(labelWithString: entry.title)
        title.font = HelmType.rowTitle()
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        let destination = entry.captureDestination
        let detailText = destination.map { "\(ShiftDateFormatting.clockTime(entry.at)) \u{00B7} \($0.railDestination.title)" }
            ?? ShiftDateFormatting.clockTime(entry.at)
        let detail = NSTextField(labelWithString: detailText)
        detail.font = HelmType.caption()
        // Gotcha (5): only the text may compress. The trailing detail keeps
        // its width, or a long capture title squeezes the one thing that
        // says where it went.
        detail.setContentHuggingPriority(NSLayoutConstraint.Priority.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(NSLayoutConstraint.Priority.required, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        // Gotcha (10): `.gravityAreas` honours no hugging priority at all.
        stack.distribution = .fill
        stack.spacing = HelmMetrics.s3
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: HelmMetrics.s2),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -HelmMetrics.s2),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -5),
        ])

        row.accessibilityLabelOverride = "\(entry.title), \(detailText)"
        if let destination {
            let open: () -> Void = { [weak self] in self?.onOpenDestination?(destination.railDestination) }
            row.onAccessibilityPress = open
            // `HelmGestureArbitration` is applied for us by
            // `HoverHighlightView` for any recognizer with no delegate
            // (gotcha (20)).
            row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:))))
            row.identifier = NSUserInterfaceItemIdentifier(destination.rawValue)
        }
        row.menu = forgetMenu(for: entry)

        rowViews.append((row, title, detail))
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func forgetMenu(for entry: CaptureInboxEntry) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Remove from Captured today", action: #selector(forgetTapped(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = entry.id
        menu.addItem(item)
        return menu
    }

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue,
              let destination = CaptureDestination(rawValue: id) else { return }
        onOpenDestination?(destination.railDestination)
    }

    @objc private func forgetTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.forget(id: id)
        render(theme: theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        card.applyTheme(theme)
        self.theme = theme
        let muted = HelmTheme.mutedInk(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        emptyLabel?.textColor = muted
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        for row in rowViews {
            row.label.textColor = ink
            row.detail.textColor = muted
            row.view.normalColor = .clear
            row.view.hoverColor = surface.blended(withFraction: HelmAccentRow.selectionWash / 2.5,
                                                  of: accent) ?? surface
        }
    }

    #if FM_SELFTESTS
    /// X6: what the card is actually showing, in order.
    var debugRowTitles: [String] { rowViews.map { $0.label.stringValue } }
    var debugRowDetails: [String] { rowViews.map { $0.detail.stringValue } }
    var debugEmptyText: String? { emptyLabel?.stringValue }
    /// Drives a real row's own click handler through its recognizer's target.
    func debugClickRow(_ index: Int) {
        guard rowViews.indices.contains(index),
              let recognizer = rowViews[index].view.gestureRecognizers
                  .compactMap({ $0 as? NSClickGestureRecognizer }).first else { return }
        rowClicked(recognizer)
    }
    #endif
}
