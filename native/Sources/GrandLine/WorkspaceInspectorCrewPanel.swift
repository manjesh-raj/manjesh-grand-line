// Grand Line - native macOS app.
//
// S27 of the 2026-11-17 UI/UX proposals: the inspector on a page with no
// selection details becomes a place.
//
// The inspector is a first-class pane (its own toolbar button, ⌥⌘I), and on
// 17 of 20 modules it opened to "No details for this page". Meanwhile the crew
// already answers questions about tasks, docs, health, commands and
// automations, through a composer built to be hosted narrow.
//
// The captain's calls, which this file implements as written:
//
//   - **Operator-only.** The crew panel shows for the Operator profile. A
//     Personal install, which has no crew, gets the page's shortcuts and the
//     tip of the day instead, so the pane is never empty.
//   - **The page's summary line is the context, and it says so.** The panel
//     reads the line the page already shows under its title (the same text,
//     never a fresh read) and a visible chip names exactly that, so nothing
//     leaves the Mac that the captain cannot see first. The question goes out
//     as "About the <page> page (<summary>): <question>".
//   - **The existing crew, not a new chat.** The composer and the reply are
//     `StrawHatMenuBarPopoverController` at the inspector's width - the same
//     controller the menu-bar popover and compact mode host - and its ask is
//     the shell's `askCrewFromMenuBar`, so it lands in the one conversation
//     the app has with the crew (`StrawHatController.send`, `ClaudeOneShot`'s
//     tool policy and the `AppLockGate` gate unchanged). A write the crew
//     proposes is confirmed on the Crew page, which "Continue in Crew" opens.
//   - **Details win.** A page with a selection (Connections, Secrets, Setup)
//     keeps showing it; this panel is the default for the rest.

import AppKit

final class WorkspaceInspectorCrewPanel: NSViewController {

    /// The inspector's width, less the panel's own insets.
    static let contentWidth: CGFloat = WorkspaceInspectorController.width - 2 * HelmMetrics.s3

    struct PageContext: Equatable {
        let module: WorkspaceModule
        /// The page's own summary line, as its header shows it.
        let summary: String
    }

    /// Wired by the shell to `Workspace.askCrewFromMenuBar`.
    var onAsk: ((String, @escaping (Result<[StrawHatSection], StrawHatError>) -> Void) -> Void)?
    /// "Continue in Crew": the shell opens the Crew page.
    var onContinueInCrew: (() -> Void)?

    private(set) var context = PageContext(module: .home, summary: "")
    private let crew = StrawHatMenuBarPopoverController(width: WorkspaceInspectorCrewPanel.contentWidth,
                                                        showsOwnHeader: false)
    private let stack = NSStackView()
    private let contextChip = NSTextField(labelWithString: "")
    private let asksStack = NSStackView()
    private let trustLine = NSTextField(wrappingLabelWithString:
        "Written by Claude \u{00B7} what you type and the page's summary leave this Mac")
    private let personalStack = NSStackView()
    private var themeToken: ThemeObservation?

    /// The panel's title line in the inspector.
    var paneTitle: String { Self.crewAvailable ? "Ask the crew" : "On \(context.module.title)" }

    /// The captain's call: Operator-only.
    static var crewAvailable: Bool {
        WorkspaceProfile.matching(AppSettings.shared.hiddenModules) == .operator
    }

    // MARK: The context

    /// What the chip shows, and the one place the sent context is spelled.
    static func contextLine(_ context: PageContext) -> String {
        context.summary.isEmpty ? "About \(context.module.title)" : "About \(context.module.title) \u{00B7} \(context.summary)"
    }

    /// The question as sent: the page and its summary, then the question.
    static func question(_ text: String, context: PageContext) -> String {
        let page = context.summary.isEmpty
            ? "the \(context.module.title) page" : "the \(context.module.title) page (\(context.summary))"
        return "About \(page): \(text)"
    }

    /// Three suggested asks per module, from a small table. A module with no
    /// row shows the composer only.
    static func suggestedAsks(for module: WorkspaceModule) -> [String] {
        switch module {
        case .home: return ["What needs me first today?", "Summarise what changed since yesterday",
                            "Which of these can wait until tomorrow?"]
        case .tasks: return ["What's overdue and why?", "Plan my week from the board",
                             "Which task should I do next?"]
        case .calendar: return ["What's on this week?", "Where do I have room for deep work?",
                                "What slipped from last week?"]
        case .health: return ["Why is a service failing?", "What should I check first?",
                              "Has this happened before?"]
        case .logs: return ["What is the likely cause?", "Which line matters most?",
                            "What would you run next to confirm it?"]
        case .schedules: return ["Which schedule failed last?", "What runs overnight?",
                                 "Is anything scheduled twice?"]
        case .kubernetes: return ["Which pods need a look?", "What changed in this namespace?",
                                  "What would you check before restarting a pod?"]
        case .runbooks: return ["Which runbook fits this incident?", "What's missing from this runbook?",
                                "Turn the last incident into a runbook outline"]
        case .knowledge: return ["Summarise this page", "What links here?", "What should this page say next?"]
        default: return []
        }
    }

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: WorkspaceInspectorController.width, height: 600))
        view = root
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        // The composer inside holds a required width of its own. Tied to the
        // pane at 490, under the window's 500, it can never be a width floor
        // on the window or the split view when the pane collapses (gotcha
        // (13)); measured, a required tie collapsed the sidebar at Home's
        // narrowest width on a 1x CI runner.
        let trailing = stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s3)
        trailing.priority = NSLayoutConstraint.Priority(490)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s3),
            trailing,
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -HelmMetrics.s3),
        ])

        contextChip.font = HelmType.caption()
        contextChip.lineBreakMode = .byTruncatingTail
        contextChip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contextChip.toolTip = "Sent with every question asked here: the page's summary line, and nothing else from the page."
        asksStack.orientation = .vertical
        asksStack.alignment = .leading
        asksStack.spacing = HelmMetrics.s1
        trustLine.font = HelmType.captionSmall()

        addChild(crew)
        crew.onAsk = { [weak self] text, completion in
            guard let self, let onAsk = self.onAsk else {
                completion(.failure(StrawHatError(message: "The crew isn't connected here right now.")))
                return
            }
            onAsk(Self.question(text, context: self.context), completion)
        }
        crew.onOpenFullChat = { [weak self] in self?.onContinueInCrew?() }
        crew.openFullChatTitle = "Continue in Crew"
        crew.idleHint = "Ask about this page - the crew sees the line above, and knows your tasks, docs and health."

        personalStack.orientation = .vertical
        personalStack.alignment = .leading
        personalStack.spacing = HelmMetrics.s2

        for view in [contextChip, asksStack, crew.view, trustLine, personalStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        render()
    }

    deinit { if let themeToken { ThemeManager.shared.unobserve(themeToken) } }

    /// The profile the panel last drew for, so a profile change re-renders
    /// even on the same page.
    private var renderedForCrew: Bool?

    func setContext(_ context: PageContext) {
        guard context != self.context || renderedForCrew != Self.crewAvailable else { return }
        self.context = context
        if isViewLoaded { render() }
    }

    private func render() {
        let crewShown = Self.crewAvailable
        renderedForCrew = crewShown
        for view in [contextChip, asksStack, crew.view, trustLine] as [NSView] { view.isHidden = !crewShown }
        personalStack.isHidden = crewShown
        contextChip.stringValue = Self.contextLine(context)
        contextChip.toolTip = "Sent with every question asked here, and nothing else from the page:\n"
            + Self.contextLine(context)
        contextChip.setAccessibilityLabel("Context sent with your question: \(Self.contextLine(context))")
        for view in asksStack.arrangedSubviews {
            asksStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for ask in Self.suggestedAsks(for: context.module) {
            let button = HelmButton(title: ask, variant: .quiet, size: .small, symbol: "sparkles")
            button.target = self
            button.action = #selector(suggestedAskTapped(_:))
            asksStack.addArrangedSubview(button)
        }
        asksStack.isHidden = !crewShown || asksStack.arrangedSubviews.isEmpty
        if !crewShown { renderPersonal() }
        applyTheme(ThemeManager.shared.theme)
    }

    @objc private func suggestedAskTapped(_ sender: HelmButton) {
        crew.askQuestion(sender.title)
    }

    /// Personal: the page's shortcuts and the tip of the day.
    private func renderPersonal() {
        for view in personalStack.arrangedSubviews {
            personalStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let sections = PageShortcuts.sections(module: context.module, route: context.module.primaryRoute,
                                              layout: PlaceName.layout, settings: .shared)
        for entry in (sections.first?.entries ?? []) + (sections.dropFirst().first?.entries.prefix(3) ?? []) {
            let title = NSTextField(labelWithString: entry.title)
            title.font = HelmType.body()
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let keys = NSTextField(labelWithString: entry.keys.joined(separator: " "))
            keys.font = HelmType.metric(11, weight: .medium)
            keys.setContentHuggingPriority(.required, for: .horizontal)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [title, spacer, keys])
            row.orientation = .horizontal
            row.distribution = .fill
            personalStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: personalStack.widthAnchor).isActive = true
        }
        let settings = AppSettings.shared
        if let first = settings.homeTipsFirstShown,
           let tip = HomeTips.tip(firstShown: first, now: Date(), dismissed: settings.homeTipsDismissed,
                                  tips: HomeTips.all()) {
            let notice = HelmNotice()
            notice.configure(.init(tint: .info, symbol: tip.symbol, kicker: "Tip", title: tip.title, body: tip.body),
                             theme: ThemeManager.shared.theme)
            personalStack.addArrangedSubview(notice)
            notice.widthAnchor.constraint(equalTo: personalStack.widthAnchor).isActive = true
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        // The composer is themed by whoever hosts it (its status item, or
        // compact mode); here that is this panel.
        crew.applyTheme(theme)
        contextChip.textColor = HelmTheme.mutedInk(theme)
        trustLine.textColor = HelmTheme.mutedInk(theme)
        for case let row as NSStackView in personalStack.arrangedSubviews {
            for case let label as NSTextField in row.arrangedSubviews {
                label.textColor = label.font == HelmType.body() ? HelmTheme.nsColor(theme.chromeInkHex) : HelmTheme.mutedInk(theme)
            }
        }
        for case let notice as HelmNotice in personalStack.arrangedSubviews { notice.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugContextChip: String { contextChip.isHidden ? "" : contextChip.stringValue }
    var debugAskTitles: [String] { asksStack.isHidden ? [] : asksStack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    var debugCrewShown: Bool { !crew.view.isHidden }
    var debugPersonalRowCount: Int { personalStack.isHidden ? 0 : personalStack.arrangedSubviews.count }
    var debugCrew: StrawHatMenuBarPopoverController { crew }
    func debugTapAsk(_ index: Int) {
        (asksStack.arrangedSubviews[index] as? NSButton)?.performClick(nil)
    }
    #endif
}
