// Grand Line - native macOS app.
//
// The line at the top of the sidebar layout's content column (stage 4 of the
// modular-shell migration): the showing page's live subtitle - the second
// line the floating bar's drill header carried.
//
// R2-UX-05: it drew the module's name as a large title above that line too,
// under a toolbar crumb that already said it and beside a lit sidebar row
// that said it again - three names for one place, four on Crew and Settings
// with their own heroes. The crumb owns the name now; this line carries what
// only the page knows. The name stays in the header's accessibility label,
// so VoiceOver still hears which module the line is about.
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
        // The title is kept, hidden, only as the accessibility label's source.
        titleLabel.isHidden = true
        NSLayoutConstraint.activate([
            subtitleLabel.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.pageGutter),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.pageGutter),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s1),
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
        isHidden = subtitle.isEmpty
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
    /// R2-UX-05: whether the module's name is drawn here (it never is).
    var debugDrawsTitle: Bool { !titleLabel.isHidden }
    var debugSubtitle: String { subtitleLabel.isHidden ? "" : subtitleLabel.stringValue }
    #endif
}
