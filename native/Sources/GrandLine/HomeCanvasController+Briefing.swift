// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: the briefing hero, the greeting, the daily tip and the Morning briefing card's content.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    // MARK: The feel pass

    /// The summary line's size: the prototype's 14 under a 30pt title.
    static let greetingSummarySize: CGFloat = 14

    func buildFeelPass() {
        greetingTitle.lineBreakMode = .byTruncatingTail
        greetingSummary.lineBreakMode = .byTruncatingTail
        for label in [greetingTitle, greetingSummary] {
            label.translatesAutoresizingMaskIntoConstraints = false
            // Gotcha (13): the largest type on the page is never a width floor.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        greetingTitle.setAccessibilityRole(.staticText)
        greetingHeader.setViews([greetingTitle, greetingSummary], in: .top)
        greetingHeader.orientation = .vertical
        greetingHeader.alignment = .leading
        greetingHeader.spacing = HelmMetrics.s1 + 2
        greetingHeader.translatesAutoresizingMaskIntoConstraints = false
        greetingHeader.setHuggingPriority(.defaultLow, for: .horizontal)
        greetingHeader.setClippingResistancePriority(.defaultLow, for: .horizontal)
        greetingHeader.isHidden = true
        briefingHero.isHidden = true
    }

    /// The greeting and the hero.
    ///
    /// Hg-2 (the five-screen redesign board): while the briefing is drawn as
    /// the hero, the greeting is the hero's own title and the day's verdict
    /// its pill, so the page-ground header is not drawn. Without the hero -
    /// the briefing hidden by the captain's layout, or nothing to say, or
    /// Customize drawing it as a card - the greeting keeps its own row.
    func renderFeelPass(now: Date = DayRollover.now()) {
        let greetingOnGround = !briefingIsHero
        greetingHeader.isHidden = !greetingOnGround
        briefingHero.isHidden = !briefingIsHero
        stackTop?.constant = Self.contentTopMargin - (greetingOnGround ? Self.greetingInkInset : 0)

        let counts = HomeTaskCounts(store: sources.shiftStore, now: now)
        var prsReady: Int?
        if case let .value(count) = prReading { prsReady = count }
        let crewShown = !hiddenModules.contains(.crew)
        let healthShown = !hiddenModules.contains(.health)
        let fleetAnswer = crewShown ? overviewAnswer() : nil
        let fleetTint = fleetAnswer.flatMap { $0.tint == .good ? nil : $0.tint }
        let fleetNeedsCaptain = HomeBriefingHero.offersNeedsYou(crewShown: crewShown,
                                                                tasks: fleetSnapshot?.tasks ?? [])
        // F-01: the first meeting still to come today, from the Mac's own
        // calendars when they are shown.
        let firstMeeting = MacCalendarSource.shared.isShowing
            ? MacCalendarRules.firstMeeting(after: now, meetings: MacCalendarSource.shared.meetings(on: now))
                .map { MacCalendarRules.firstMeetingSentence($0, now: now) }
            : nil
        let facts = HomeGreeting.Facts(
            dueToday: hiddenModules.contains(.tasks) ? nil : counts?.due,
            overdue: counts?.overdue,
            fleetNeedsYou: fleetAnswer.flatMap { $0.tint == .good ? nil : $0.title },
            prsReady: crewShown ? prsReady : nil,
            servicesFailing: healthShown && healthSummary.total > 0 ? healthSummary.failing : nil,
            firstMeeting: firstMeeting)
        greetingTitle.stringValue = HomeGreeting.title(
            captain: HomeGreeting.captainName(fleetCaptain: fleetSnapshot?.captain), now: now)
        greetingSummary.stringValue = HomeGreeting.summary(facts, now: now)
        greetingHeader.setAccessibilityElement(true)
        greetingHeader.setAccessibilityRole(.group)
        greetingHeader.setAccessibilityLabel("\(greetingTitle.stringValue). \(greetingSummary.stringValue)")

        if briefingIsHero {
            let verdict = HomeGreeting.verdict(facts, fleetTint: fleetTint)
            renderBriefingHero(fleetNeedsYou: fleetNeedsCaptain, healthShown: healthShown,
                               greeting: greetingTitle.stringValue,
                               status: .init(text: verdict.text, tint: verdict.tint), now: now)
        }
    }

    func renderBriefingHero(fleetNeedsYou: Bool, healthShown: Bool, greeting: String,
                                    status: HelmHeroCard.Content.Status, now: Date) {
        let record = AppSettings.shared.morningBriefingRecord
        let words = HomeBriefingHero.words(record: record, enabled: AppSettings.shared.morningBriefingEnabled,
                                           settingsName: PlaceName.of(.settings))
        // Hg-2: the date the page-ground summary used to open with leads the
        // kicker, since the greeting it sat under is this card's title now.
        var kicker = "\(HomeGreeting.date(now)) \u{00B7} Morning briefing"
        if let record, !record.clauses.isEmpty {
            kicker += " \u{00B7} generated \(Self.briefingTimeFormatter.string(from: record.generatedAt))"
            kicker += " \u{00B7} \(record.sources.count) source\(record.sources.count == 1 ? "" : "s")"
            if record.isDegraded { kicker += " \u{00B7} offline" }
        }
        // The feasibility audit's ring: the services figure Home's Health
        // card already draws, as the last tile. None when the profile hides
        // Health, and none before anything has reported - an empty ring
        // would read as zero healthy (GL-14).
        var ring: HelmHeroCard.Content.Ring?
        if healthShown, healthSummary.total > 0 {
            ring = .init(value: healthSummary.healthy, total: healthSummary.total,
                         label: PlaceName.short(.health), caption: "services healthy", isLink: true)
        }
        var tiles = words.facts.map { HomeBriefingHero.tile($0, pageName: PlaceName.short) }
        if let note = words.note { tiles.append(.init(label: nil, text: note, tint: nil, isLink: false)) }
        briefingHero.configure(.init(kicker: kicker, title: words.title, tiles: tiles, ring: ring,
                                     greeting: greeting, status: status))
        let facts = words.facts
        briefingHero.onActivateTile = { [weak self] index in
            guard let self, !self.isCustomizing, facts.indices.contains(index) else { return }
            self.follow(facts[index].target)
        }
        briefingHero.onActivateRing = { [weak self] in
            guard let self, !self.isCustomizing else { return }
            self.heroOpenHealth()
        }

        // The prototype's two actions, each only when it has somewhere real
        // to go: the crew's decisions when one is waiting, Health when a
        // service is failing.
        var actions: [(String, Selector)] = []
        if fleetNeedsYou { actions.append(("Open Needs you", #selector(heroOpenDecisions))) }
        if healthShown, healthSummary.failing > 0 { actions.append(("See Health", #selector(heroOpenHealth))) }
        if heroActionTitles != actions.map(\.0) {
            heroActionTitles = actions.map(\.0)
            briefingHero.setActions(actions.map { HelmButton(title: $0.0, variant: .secondary, target: self, action: $0.1) })
        }
    }


    @objc func heroOpenDecisions() {
        if let onOpenCrewDecisions { onOpenCrewDecisions() } else { onOpenDestination?(.overview) }
    }
    @objc func heroOpenHealth() { onOpenDestination?(.health) }

    #if FM_SELFTESTS
    var debugGreetingTitle: String { greetingHeader.isHidden ? "" : greetingTitle.stringValue }
    var debugGreetingSummary: String { greetingHeader.isHidden ? "" : greetingSummary.stringValue }
    /// Hg-2: whether the greeting is drawn on the page ground rather than as
    /// the briefing hero's title.
    var debugGreetingOnGround: Bool { !greetingHeader.isHidden }
    var debugBriefingHero: HelmHeroCard? { briefingHero.isHidden ? nil : briefingHero }
    #endif

    // MARK: R5-UX-03 - Things you can do


    func renderTip(now: Date = Date()) {
        let settings = AppSettings.shared
        guard let first = settings.homeTipsFirstShown,
              let tip = HomeTips.tip(firstShown: first, now: now, dismissed: settings.homeTipsDismissed,
                                     tips: HomeTips.all()) else {
            shownTip = nil
            tipRow.isHidden = true
            return
        }
        shownTip = tip
        shownTipDay = (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: first),
                                                       to: Calendar.current.startOfDay(for: now)).day ?? 0) + 1
        tipRow.isHidden = false
        paintTip(ThemeManager.shared.theme)
    }

    func paintTip(_ theme: HelmTheme) {
        guard let tip = shownTip else { return }
        tipRow.configure(HelmNotice.Content(
            tint: .info,
            symbol: tip.symbol,
            kicker: "Things you can do \u{00B7} day \(shownTipDay) of \(HomeTips.days)",
            title: tip.title,
            body: tip.body), theme: theme)
    }

    #if FM_SELFTESTS
    var debugTipTitle: String? { tipRow.isHidden ? nil : shownTip?.title }
    func debugDismissTips() { tipRow.debugDismiss() }
    var debugTipNotice: HelmNotice { tipRow }
    #endif

    func dismissTips() {
        AppSettings.shared.homeTipsDismissed = true
        renderTip()
        Toast.show(in: view, message: "Tips hidden. \u{2318}/ lists the shortcuts for any page.")
    }

    /// `FleetGreeting`'s verdict over the snapshot this page was handed, or
    /// `nil` before the first one arrives.
    ///
    /// One definition, read by the greeting's summary, the hero's status
    /// pill and its "Open Needs you" - so they cannot disagree about the
    /// fleet.
    func overviewAnswer() -> FleetGreeting.Answer? {
        fleetSnapshot.map {
            FleetGreeting.answer(tasks: $0.tasks, prs: prReading, homeOk: $0.homeOk)
        }
    }

    /// REL-04: the PR half of the verdict, read the way `fillMergeQueue`
    /// already reads it. Every Fleet refresh pushes its fast snapshot with no
    /// PR list and no failure, and this used to turn that into "0 PRs ready
    /// to merge" in the good tint for the length of every scan - while the
    /// Merge queue card directly below kept the last good list. A scan in
    /// flight now keeps the last good count, and with none yet it says it
    /// is still checking. A failed scan still says so rather than quoting
    /// the old count as current.
    var prReading: FleetDataSource.PRReadyReading {
        if let prFetchFailure { return .failed(prFetchFailure) }
        if let prs = mergedPRs ?? lastGoodPRs { return .value(FleetDataSource.readyToMergeCount(prs)) }
        return .scanning
    }

    // MARK: Module content (§6.1's table)

    /// `width` is the width the grid built this card at. The briefing reads
    /// it to pick its narrow form, and the hero cards to pick their layout.
    func content(for module: DaylightModule, width: CGFloat) -> HelmModuleCard.Content {
        var content = HelmModuleCard.Content(
            title: module.title,
            subtitle: "",
            symbol: module.symbol,
            hue: module.hue,
            chip: nil,
            body: .note(""))

        switch module {
        case .briefing: fillBriefing(&content, width: width)
        case .claudeStatus: fillClaudeStatus(&content, width: width)
        case .fleet: fillFleetHero(&content, width: width)
        case .strawHat: fillStrawHat(&content)
        case .tasks: fillTasks(&content)
        case .mergeQueue: fillMergeQueue(&content)
        case .console: fillConsole(&content)
        case .health: fillHealth(&content, width: width)
        case .hosts: fillHosts(&content, width: width)
        case .updates: fillUpdates(&content)
        case .bootstrap: fillBootstrap(&content)
        case .automation: fillAutomation(&content)
        case .githubSync: fillGitHubSync(&content)
        case .schedules: fillSchedules(&content)
        case .logAnalyzer: fillLogAnalyzer(&content)
        case .kubernetes: fillKubernetes(&content)
        case .vault: fillVault(&content)
        case .poneglyph: fillPoneglyph(&content)
        case .docs: fillDocs(&content)
        case .notebook: fillNotebook(&content)
        case .readingList: fillReadingList(&content)
        case .runbooks: fillRunbooks(&content)
        case .postmortems: fillPostmortems(&content)
        case .dictation: fillDictation(&content)
        case .tools: fillTools(&content)
        case .whiteboard: fillWhiteboard(&content)
        case .stickyBoard: fillStickyBoard(&content)
        case .codePreview: fillCodePreview(&content)
        case .commandLibrary: fillCommandLibrary(&content)
        case .calendar: fillCalendar(&content)
        case .focusTimer: fillFocusCard(&content)
        case .settings: fillSettings(&content)
        }
        return content
    }

    /// F12's record, read straight out of `AppSettings` - already generated,
    /// never regenerated here. A canvas that could trigger a `claude -p` call
    /// would be a new cost on every visit.
    // GL-P3: built once. `DateFormatter` construction is measurably
    // expensive and this carries no per-call state - the same treatment
    // `FleetLogFeed`/`HealthCardView` already give theirs.
    static let briefingTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    func fillBriefing(_ content: inout HelmModuleCard.Content, width: CGFloat) {
        guard let record = AppSettings.shared.morningBriefingRecord, !record.clauses.isEmpty else {
            content.subtitle = AppSettings.shared.morningBriefingEnabled
                ? "not generated yet today"
                : "off in \(PlaceName.of(.settings))"
            content.body = .note(AppSettings.shared.morningBriefingEnabled
                ? "Your first briefing of the day appears here."
                : "Turn on Morning briefing in \(PlaceName.of(.settings)) to get one short summary each morning.")
            return
        }
        // UI-8's rule on this card: the source count is a fact about the
        // reading, so it joins the subtitle; the header keeps a pill only for
        // the state that is not the default (an offline briefing).
        content.subtitle = "generated \(Self.briefingTimeFormatter.string(from: record.generatedAt))"
            + " \u{00B7} \(record.sources.count) source\(record.sources.count == 1 ? "" : "s")"
        content.chip = record.isDegraded ? .warn("offline") : nil

        // Two columns wide again, and still bounded - see
        // `HelmModuleCard.maxBriefingClauses` for why the cap survives the
        // extra width (the card's height is fixed now) and why the number went
        // from three to five. An overflow is stated rather than dropped in
        // silence - a card that quietly showed five of eight clauses would
        // read as "that is the whole briefing", which is exactly the "no
        // silent caps" failure. The trailing line is a plain `.none`-target
        // clause, so it renders as text inside the same paragraph and needs no
        // new mechanism.
        var clauses = Array(record.clauses.prefix(Self.briefingClauseCap(forCardWidth: width)))
        let hidden = record.clauses.count - clauses.count
        if hidden > 0 {
            clauses.append(BriefingClause(text: "+\(hidden) more in \(PlaceName.of(.overview)).", target: .none))
        }
        content.body = .paragraph(clauses)
    }

    /// How many clauses the briefing's paragraph may carry on a card of this
    /// width.
    ///
    /// A span-2 card is at least two minimum columns plus the gap between
    /// them, so anything narrower than that is a briefing `packRows` degraded
    /// to one column in a single-column grid - and its paragraph has to shrink
    /// with it or it overflows the fixed card height and is clipped.
    static func briefingClauseCap(forCardWidth width: CGFloat) -> Int {
        isNarrowerThanTwoColumns(width) ? HelmModuleCard.maxNarrowBriefingClauses : HelmModuleCard.maxBriefingClauses
    }
}
