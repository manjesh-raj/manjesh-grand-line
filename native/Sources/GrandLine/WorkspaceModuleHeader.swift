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
//
// S03 (2.0.0): this is `HelmPageScaffold`'s header-line slot, and the slot
// keeps its height on every module. It used to hide when a page had no
// subtitle and on Connections and Console, so those pages started 32pt
// higher than the rest and switching pages made the content jump. Now the
// line is `HelmMetrics.pageHeaderLine` tall whether it says anything or not,
// and every page's first content starts at the same height under it. An
// empty line draws nothing and is not an accessibility element.
//
// One exception, the captain's (`fm/grandline-console-fixes`): Console never
// says anything on this line, and the empty slot read as dead space above its
// session band. A page that adopts `WorkspaceHeaderLineCollapsing` gives up an
// empty slot (`collapsesWhenEmpty`), so Console's band starts just under the
// toolbar. The slot comes back the moment the line has words or a control.

import AppKit

final class WorkspaceModuleHeader: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// R5-UI-01: a page control on the subtitle's line, at its trailing end
    /// (`WorkspaceHeaderAccessoryProviding`). Never more than one view.
    private let accessoryHost = NSStackView()
    private(set) var accessory: NSView?
    private var themeToken: ThemeObservation?
    private lazy var slotHeight = heightAnchor.constraint(equalToConstant: HelmMetrics.pageHeaderLine)

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
        accessoryHost.orientation = .horizontal
        accessoryHost.translatesAutoresizingMaskIntoConstraints = false
        accessoryHost.setHuggingPriority(.required, for: .horizontal)
        addSubview(accessoryHost)
        // The slot's own height, kept when the line is empty, and required:
        // nothing a page asks of its own height may grow the line. With the
        // exact height preferred at 490, and then at 750, a page's own
        // height ties grew it to 590pt on Notebook and 319pt on Settings
        // (measured), with the page body pushed down under it. The line
        // sizes itself instead (`resizeSlot`): 32pt, or what its text or
        // control needs at a larger text scale, never less.
        NSLayoutConstraint.activate([
            slotHeight,
            subtitleLabel.topAnchor.constraint(equalTo: topAnchor, constant: HelmPageScaffold.headerLineTextTop),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.pageGutter),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessoryHost.leadingAnchor, constant: -HelmMetrics.s3),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -HelmMetrics.s1),
            // On the subtitle's line, and never taller than the header: a
            // control taller than the line grows the header rather than
            // spilling over the page under it.
            accessoryHost.centerYAnchor.constraint(equalTo: subtitleLabel.centerYAnchor),
            accessoryHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.pageGutter),
            accessoryHost.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: HelmMetrics.s1),
            accessoryHost.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// Whether the subtitle's line has any text.
    var hasSubtitle: Bool { !subtitleLabel.isHidden }

    /// Whether an empty line gives up its slot (`WorkspaceHeaderLineCollapsing`)
    /// rather than keeping S03's height. Off for every page but Console.
    var collapsesWhenEmpty = false {
        didSet { refreshCollapse() }
    }

    private func refreshCollapse() {
        isHidden = collapsesWhenEmpty && subtitleLabel.isHidden && accessory == nil
    }

    /// Show `view` at the trailing end of the subtitle's line, or nothing.
    func setAccessory(_ view: NSView?) {
        guard view !== accessory else { return }
        accessory?.removeFromSuperview()
        accessory = view
        if let view {
            // Moved here from wherever it last sat (the toolbar draws the
            // same control in the floating bar's layout), so it carries
            // nothing over from that parent's layout.
            view.removeFromSuperview()
            accessoryHost.addArrangedSubview(view)
        }
        resizeSlot()
        refreshCollapse()
    }

    /// The module's name (kept for VoiceOver only) and the page's subtitle.
    /// A `nil` title is a module that draws no header line (Connections,
    /// Console): the slot stays, empty. Either way the line never hides.
    func configure(title: String?, subtitle: String) {
        let subtitle = title == nil ? "" : subtitle
        titleLabel.stringValue = title ?? ""
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        let says = !subtitle.isEmpty || accessory != nil
        setAccessibilityElement(says)
        setAccessibilityRole(.group)
        setAccessibilityLabel(says ? (subtitle.isEmpty ? title : "\(title ?? ""), \(subtitle)") : nil)
        resizeSlot()
        refreshCollapse()
    }

    /// `pageHeaderLine`, or taller when the line's text or control needs
    /// it. Measured from what the line holds, never from its own frame.
    private func resizeSlot() {
        let line = ceil(subtitleLabel.intrinsicContentSize.height)
        let text = HelmPageScaffold.headerLineTextTop + line + HelmMetrics.s1
        // A control is centred on the text's line, so it needs half its
        // height below that line's centre.
        let control = accessory.map { ceil(HelmPageScaffold.headerLineTextTop + line / 2 + $0.fittingSize.height / 2) } ?? 0
        let height = max(HelmMetrics.pageHeaderLine, text, control)
        if slotHeight.constant != height { slotHeight.constant = height }
    }

    private func applyTheme(_ theme: HelmTheme) {
        titleLabel.font = HelmType.pageTitle()
        subtitleLabel.font = HelmType.body()
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        resizeSlot()
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    /// R2-UX-05: whether the module's name is drawn here (it never is).
    var debugDrawsTitle: Bool { !titleLabel.isHidden }
    var debugSubtitle: String { subtitleLabel.isHidden ? "" : subtitleLabel.stringValue }
    /// S03: whether the line says anything - a subtitle or a control.
    var debugIsEmpty: Bool { subtitleLabel.isHidden && accessory == nil }
    #endif
}
