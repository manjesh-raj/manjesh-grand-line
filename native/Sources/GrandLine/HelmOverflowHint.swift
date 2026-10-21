// Grand Line - native macOS app.
//
// UXP-18 of the 2026-10 full review: a list that scrolls inside its own card
// says how much is below the fold.
//
// The Tasks board's lanes and the List view's two panels each show a fixed
// number of rows and scroll the rest inside the card. On the board the fifth
// card showed as an 8pt strip under the fourth with "Add task" abutting it,
// which read as a clipped card; the My Tasks panel showed four of its seven
// rows with nothing to say there were three more. A count is what a captain
// reads at a glance - "3 more below" - and it follows the scroll, so it is
// never a number about rows that are already in view.
//
// One component rather than a label per page, because the rule is the same
// everywhere: count the rows whose frames end below the visible rect, in the
// document's own coordinates, and re-count when the clip view scrolls.

import AppKit

final class HelmOverflowHint: NSView {

    private let label = NSTextField(labelWithString: "")
    private weak var scroll: NSScrollView?
    private var rowFrames: () -> [NSRect] = { [] }
    private var observers: [NSObjectProtocol] = []
    private(set) var countBelow = 0
    /// Fired when the count changes, so a caller that keeps two panels level
    /// can decide whether either needs the row.
    var onCountChanged: ((Int) -> Void)?

    /// `leadingInset` lines the words up with the rows above them, and
    /// `bottomInset` keeps them off the edge of a card they end.
    init(leadingInset: CGFloat = HelmMetrics.s1, bottomInset: CGFloat = 0) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = HelmType.captionSmall()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Watches `scroll`, counting the rows `rowFrames` returns (in the
    /// document view's coordinates) that end below what is visible.
    func watch(_ scroll: NSScrollView, rowFrames: @escaping () -> [NSRect]) {
        self.scroll = scroll
        self.rowFrames = rowFrames
        observers.forEach(NotificationCenter.default.removeObserver)
        // A scroll moves the clip view's bounds; a resize of the list (a
        // panel re-deriving its height) moves its frame. Either changes what
        // is below the fold.
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        observers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                self?.recount()
            }
        }
    }

    /// Re-counts after the rows changed or were laid out.
    func recount() {
        guard let scroll else { return }
        let visibleBottom = scroll.contentView.bounds.maxY
        let below = rowFrames().filter { $0.height > 0 && $0.maxY > visibleBottom + 0.5 }.count
        let count = below
        guard count != countBelow || label.stringValue.isEmpty != (count == 0) else { return }
        countBelow = count
        label.stringValue = Self.text(for: count)
        onCountChanged?(count)
    }

    /// "3 more below", or empty for none.
    static func text(for count: Int) -> String {
        count > 0 ? "\(count) more below" : ""
    }

    func applyTheme(_ theme: HelmTheme) {
        label.font = HelmType.captionSmall()
        label.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugText: String { isHidden ? "" : label.stringValue }
    #endif
}
