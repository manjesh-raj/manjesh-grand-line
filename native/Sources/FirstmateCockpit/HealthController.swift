// Manjesh Grand Line - native macOS app.
//
// The `.health` rail destination (fm/grandline-health-sidebar-move).
//
// F1 / GL-11 originally shipped the "Health" card as the last card on the
// Settings page - a diagnostic surface a captain had to scroll past
// Connection/Appearance/Terminal/Security/Backup to reach. The captain's own
// correction, the same move F11's Schedules card already got
// (`fm/grandline-schedules-sidebar-move`): a surface worth checking on
// directly should not need a scroll-within-Settings step. This gives Health
// its own rail icon, directly visible in the sidebar, with no scroll or
// flyout step.
//
// This is a presentation-layer move, not a rewrite: `HealthCardView`,
// `ServiceHealthRegistry`, and `PersistenceFailureReporter` are all
// untouched. Settings' own Connection/Appearance/Terminal/Security/Backup
// cards are unaffected and stay exactly where they were.
//
// Placement: the utility group (`RailDestination.isDailyUse == false`),
// alongside Tools/Vault/Dictation/Schedules/Docs - Health "runs itself and
// reports" (every background service reports its own outcome to it) rather
// than something a captain checks in on daily, the same criterion that
// already keeps Schedules/Vault/Docs/Tools out of the daily-use `navStack`
// group.

import AppKit

final class HealthController: NSViewController {

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!

    /// The card itself - see `HealthCardView`'s own header for why it is a
    /// self-contained view (owning rendering, deciding nothing) rather than
    /// business logic that belongs on this controller.
    private let healthCard = HealthCardView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.healthCard.refresh(theme: theme)
        }

        // D5: the page used to carry its own subtitle restating what the top
        // bar and the card header already say ("Health", "last run and last
        // error"), three times on one screen. The card is the page.
        let stack = NSStackView(views: [healthCard.card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            healthCard.card.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // AGENTS.md gotcha #4: pin the document view to the *clip* view,
            // never the outer scroll view - see `SchedulesController`'s
            // identical comment for the full reasoning.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollView = scroll

        healthCard.refresh(theme: theme)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        healthCard.refresh(theme: theme)
        scrollToTop()
    }

    /// The card's wrapping description labels wrap at a width derived from the
    /// card's own - which is only known once a layout pass has run (D6's
    /// other half: the hardcoded 360pt cap that left the right half of a wide
    /// window empty).
    override func viewDidLayout() {
        super.viewDidLayout()
        healthCard.layoutDidChange()
    }

    private func scrollToTop() {
        guard let scroll = scrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugHealthRowCount: Int { healthCard.debugRowCount }
    #endif
}
