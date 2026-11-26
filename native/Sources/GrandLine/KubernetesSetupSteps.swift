// Grand Line - native macOS app.
//
// UI-11 of full review 4: Kubernetes' idle state as the three steps that get
// the page to a cluster, rather than shimmering skeleton rows.
//
// Until a feed tab exists nothing is loading: the page is waiting for the
// captain. The Pods card drew four skeleton rows anyway, which say "this is
// loading", and the instructions were a paragraph of small text in the card
// above. The steps are those instructions, one line each, ticked as they
// happen, with the next one's action as its button. The skeleton is kept for
// the moment a real read is in flight (`KubeResourceTableView.showsLoading`).
//
// What the page can see decides what is ticked. A live session ticks step 1,
// and a picked feed tab ticks step 3. The login on the box with kubectl
// (step 2) happens inside the captain's own terminal and is never read, so
// it is ticked only once a feed tab is working, which is when this card
// steps aside.

import AppKit

/// The steps' words and states. A pure value, asserted headless.
struct KubeSetupSteps: Equatable {

    struct Step: Equatable {
        let number: Int
        let title: String
        let detail: String
        let isDone: Bool
        /// The first step not yet done: the one whose action is offered.
        let isNext: Bool
    }

    let steps: [Step]

    var doneCount: Int { steps.filter(\.isDone).count }
    /// "1 of 3".
    var progress: String { "\(doneCount) of \(steps.count)" }

    static func make(sessionLabel: String, connected: Bool, connectedAt: Date?, feedTabPicked: Bool,
                     now: Date = Date()) -> KubeSetupSteps {
        let connectedDetail: String
        if connected, let connectedAt {
            let elapsed = HostSession.durationText(since: connectedAt, now: now)
            connectedDetail = elapsed.first?.isNumber == true ? "Connected \(elapsed) ago." : "Connected \(elapsed)."
        } else if connected {
            connectedDetail = "Connected."
        } else {
            connectedDetail = "Open its session in \(PlaceName.of(.hosts)) first."
        }
        let done = [connected, feedTabPicked, feedTabPicked]
        let next = done.firstIndex(of: false)
        let words: [(String, String)] = [
            ("Connect to \(sessionLabel)", connectedDetail),
            ("Log in to the box that has kubectl", "This hop asks for a password, once per session."),
            ("Pick the tab this page may type into", "Your other tabs are never touched."),
        ]
        return KubeSetupSteps(steps: words.enumerated().map { index, pair in
            Step(number: index + 1, title: pair.0, detail: pair.1, isDone: done[index], isNext: index == next)
        })
    }
}

/// "Read your cluster": the steps as numbered rows in a card, the next one
/// with "Open in Console" where the step is done in a terminal.
final class KubeSetupStepsCard: NSView {
    /// Step 2's action: the scoped host's page, where its tabs are.
    var onOpenInConsole: (() -> Void)?

    private let card = HelmCard()
    private let progressPill = HelmStatusPill(style: .pill)
    private let rowsStack = NSStackView()
    private var rows: [KubeSetupStepRow] = []
    private(set) var steps = KubeSetupSteps(steps: [])
    private var theme: HelmTheme = ThemeManager.shared.theme

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        progressPill.setContentHuggingPriority(.required, for: .horizontal)
        progressPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.setHeader(symbol: "checklist", tint: .info, title: "Read your cluster", actions: [progressPill])
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(rowsStack, insets: NSEdgeInsets(top: HelmMetrics.s1, left: HelmMetrics.s4, bottom: HelmMetrics.s2,
                                                right: HelmMetrics.s4))
        setAccessibilityLabel("Read your cluster")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ steps: KubeSetupSteps, theme: HelmTheme) {
        guard steps != self.steps || theme.id != self.theme.id else { return }
        self.steps = steps
        self.theme = theme
        progressPill.configure(text: steps.progress, tint: steps.doneCount == steps.steps.count ? .good : .info,
                               theme: theme)
        progressPill.setAccessibilityLabel("\(steps.doneCount) of \(steps.steps.count) steps done")
        for row in rows {
            rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rows = steps.steps.map { step in
            let action: (() -> Void)? = step.number == 2 && step.isNext ? { [weak self] in self?.onOpenInConsole?() } : nil
            return KubeSetupStepRow(step, actionTitle: action == nil ? nil : "Open in Console", action: action)
        }
        for (index, row) in rows.enumerated() {
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            row.showsRule = index > 0
        }
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        card.applyTheme(theme)
        self.theme = theme
        progressPill.applyTheme(theme)
        for row in rows { row.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugRows: [KubeSetupStepRow] { rows }
    var debugProgress: String { progressPill.text }
    #endif
}

/// One step: its number (a tick once done), its words, and its action.
final class KubeSetupStepRow: NSView {
    let step: KubeSetupSteps.Step
    private let badge = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeGlyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let rule = NSView()
    private(set) var actionButton: HelmButton?
    private let action: (() -> Void)?
    static let badgeSide: CGFloat = 24

    var showsRule = false { didSet { rule.isHidden = !showsRule } }

    init(_ step: KubeSetupSteps.Step, actionTitle: String?, action: (() -> Void)?) {
        self.step = step
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(12), weight: .bold)
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeGlyph.image = HelmSymbol.image("checkmark", pointSize: HelmType.scaled(11), weight: .bold)
        badgeGlyph.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)
        badge.addSubview(badgeGlyph)
        badgeLabel.stringValue = "\(step.number)"
        badgeLabel.isHidden = step.isDone
        badgeGlyph.isHidden = !step.isDone
        titleLabel.stringValue = step.title
        titleLabel.font = HelmType.rowTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.stringValue = step.detail
        detailLabel.font = HelmType.caption()
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let words = NSStackView(views: [titleLabel, detailLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        words.translatesAutoresizingMaskIntoConstraints = false
        words.setHuggingPriority(.defaultLow, for: .horizontal)
        words.setClippingResistancePriority(.defaultLow, for: .horizontal)
        rule.wantsLayer = true
        rule.isHidden = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        for view in [badge, words, rule] { addSubview(view) }
        var constraints = [
            badge.leadingAnchor.constraint(equalTo: leadingAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: Self.badgeSide),
            badge.heightAnchor.constraint(equalToConstant: Self.badgeSide),
            badgeLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badgeGlyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeGlyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            words.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: HelmMetrics.s3),
            words.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2 + 2),
            words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(HelmMetrics.s2 + 2)),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ]
        if let actionTitle {
            let button = HelmButton(title: actionTitle, variant: .primary, size: .small,
                                    target: self, action: #selector(actionTapped))
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            actionButton = button
            constraints += [
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                words.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -HelmMetrics.s3),
            ]
        } else {
            constraints.append(words.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Step \(step.number)\(step.isDone ? ", done" : ""): \(step.title). \(step.detail)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Gotcha (22): the detail wraps at the row's width less the badge and
    /// the button, which this label does not decide.
    override func layout() {
        super.layout()
        let button = actionButton.map { $0.fittingSize.width + HelmMetrics.s3 } ?? 0
        let width = max(80, floor(bounds.width - Self.badgeSide - HelmMetrics.s3 - button))
        if abs(detailLabel.preferredMaxLayoutWidth - width) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = width
            detailLabel.invalidateIntrinsicContentSize()
        }
    }

    @objc private func actionTapped() { action?() }

    func applyTheme(_ theme: HelmTheme) {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        rule.layer?.backgroundColor = HelmFlatList.hairRowColor(theme).cgColor
        if step.isDone {
            let good = HelmContrast.legibleTintedText(tintHex: HelmTint.good.hex(in: theme), overAnyOf: [surface],
                                                      theme: theme)
            badge.layer?.backgroundColor = good.withAlphaComponent(0.16).cgColor
            badgeGlyph.contentTintColor = good
        } else if step.isNext {
            badge.layer?.backgroundColor = accent.cgColor
            badgeLabel.textColor = HelmTheme.nsColor(theme.selectionTextHex)
        } else {
            badge.layer?.backgroundColor = accent.withAlphaComponent(0.14).cgColor
            badgeLabel.textColor = HelmContrast.legibleTintedText(tintHex: theme.accentHex, overAnyOf: [surface],
                                                                  theme: theme)
        }
    }

    #if FM_SELFTESTS
    var debugBadgeText: String? { badgeLabel.isHidden ? nil : badgeLabel.stringValue }
    var debugIsTicked: Bool { !badgeGlyph.isHidden }
    #endif
}
