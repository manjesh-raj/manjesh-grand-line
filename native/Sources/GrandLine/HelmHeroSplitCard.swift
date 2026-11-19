// Grand Line - native macOS app.
//
// `HelmHeroSplitCard` - the page-redesign board's split card as a kit piece
// (Helm 7.1.0): a gradient panel beside a page's own content, on one card.
//
// Automic Vault's S-1 card drew this first, as page code in
// `VaultHeroSplit.swift`, and Dictation's Dic-1 is the second page to want
// it. A second hand-written copy of the frame is the commonest finding in
// this repository's audits, so the frame lives here and both pages fill it.
//
// One card, two halves:
//
//   - **The panel** is a `HelmHeroColumn`. It is `.panel` by default - the
//     words with their pills on the left, the hero ring with its caption under
//     it on the right - and a page may set `.band` instead (Automic Vault
//     does, so its card is unchanged by the move).
//   - **The detail** is a plain view on the card's own surface. The page puts
//     whatever it wants in it - launcher rows, settings rows - and the card
//     decides nothing about its contents. Its height is its content's.
//
// Side by side, the panel is `panelWidth` wide at the leading edge and the
// card is as tall as the taller half. Below `stackedBelow` the panel goes
// across the top and the detail sits under it, so a narrow window never
// squeezes either half. The panel's width is held at `contentTie`, under 500,
// so it is never a floor on the window (gotcha (13)).
//
// The gradient takes no clicks; the only controls are the ones a page put on
// either half.

import AppKit

final class HelmHeroSplitCard: NSView {

    /// The panel's width beside the detail: the Claude split card's wide one.
    static let defaultPanelWidth: CGFloat = 470
    /// Below this card width the panel goes across the top.
    static let defaultStackedBelow: CGFloat = 900
    static let cornerRadius: CGFloat = 14

    let panel = HelmHeroColumn()
    /// The card's own surface beside the panel, or under it when stacked.
    /// The page fills it and pins its content to its edges.
    let detail = NSView()
    let panelWidth: CGFloat
    let stackedBelow: CGFloat
    private(set) var isStacked = false
    /// Called after the card switches between side by side and stacked, for
    /// a page whose detail lays out differently in the two.
    var onStackedChange: ((Bool) -> Void)?

    private var sideBySide: [NSLayoutConstraint] = []
    private var stacked: [NSLayoutConstraint] = []
    private var themeToken: ThemeObservation?

    init(arrangement: HelmHeroColumn.Layout = .panel, panelWidth: CGFloat = HelmHeroSplitCard.defaultPanelWidth,
         stackedBelow: CGFloat = HelmHeroSplitCard.defaultStackedBelow) {
        self.panelWidth = panelWidth
        self.stackedBelow = stackedBelow
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The panel's own rounding is the card's here, which clips it.
        panel.layer?.cornerRadius = 0
        panel.setArrangement(arrangement)
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        addSubview(detail)

        let width = panel.widthAnchor.constraint(equalToConstant: panelWidth)
        width.priority = HelmDaylightPriority.contentTie
        sideBySide = [
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,
            detail.leadingAnchor.constraint(equalTo: panel.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: topAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: panel.heightAnchor),
        ]
        stacked = [
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: panel.bottomAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(sideBySide)
        // The detail's own content decides its height, under the stack
        // defaults so a page's content wins.
        let hug = detail.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = NSLayoutConstraint.Priority(240)
        hug.isActive = true
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// The card's surface. The panel paints itself; the page themes what it
    /// put in the detail.
    func applyTheme(_ theme: HelmTheme) {
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: Self.cornerRadius,
                                  daylightRadius: Self.cornerRadius)
        layer?.masksToBounds = true
    }

    override func layout() {
        super.layout()
        let stack = bounds.width > 0 && bounds.width < stackedBelow
        guard stack != isStacked else { return }
        isStacked = stack
        NSLayoutConstraint.deactivate(stack ? sideBySide : stacked)
        NSLayoutConstraint.activate(stack ? stacked : sideBySide)
        needsLayout = true
        onStackedChange?(stack)
    }
}
