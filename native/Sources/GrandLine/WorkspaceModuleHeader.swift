// Grand Line - native macOS app.
//
// The large title at the top of the sidebar layout's content column (stage 4
// of the modular-shell migration): the module's name, and under it the
// showing page's live subtitle - the second line the floating bar's drill
// header carried.
//
// The prototype draws it on every module but two: the captain dropped it on
// Connections and Console, where the toolbar's crumb names the module and the
// page itself starts at once (`WorkspaceModule.showsHeader`). Home and every
// other module keep their subtitle, as the captain decided.

import AppKit

final class WorkspaceModuleHeader: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = HelmType.pageTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityRole(.staticText)
        subtitleLabel.font = HelmType.body()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, subtitleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            // Gotcha (5): the labels give way, never the column.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.pageGutter),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.pageGutter),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: HelmMetrics.s1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.pageGutter),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s2),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    func configure(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }

    private func applyTheme(_ theme: HelmTheme) {
        titleLabel.font = HelmType.pageTitle()
        subtitleLabel.font = HelmType.body()
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugSubtitle: String { subtitleLabel.isHidden ? "" : subtitleLabel.stringValue }
    #endif
}
