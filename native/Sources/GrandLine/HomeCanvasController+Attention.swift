// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: the Needs Attention card and its rows, and how the arranged cards are measured.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    // MARK: Needs Attention (the captain's move of Today's Due Today)

    /// Build the card's rows from `DailyReviewComposer`'s digest.
    ///
    /// The composer is the one definition of "due", "overdue", the ordering
    /// and the caps - which is the whole point of routing this through a
    /// digest instead of filtering `activeTasks` here.
    func renderAttention() {
        // Only the hub itself. The other spaces are filters over the module
        // grid and have no day of their own to report on. Home's arranged
        // cards (the sidebar layout) do not draw it either: the captain
        // removed the band between the briefing hero and the cards.
        guard space == .overview, !showsArrangedCards else {
            attentionCard.isHidden = true
            return
        }
        attentionCard.isHidden = false
        #if FM_SELFTESTS
        // The tour lab's and the fit suite's fabricated rows - see
        // `debugAttentionOverride`.
        if let override = debugAttentionOverride {
            // What the card shows is no longer what was last composed.
            lastAttention = nil
            attentionCard.sublineProvider = nil
            attentionCard.render(override, subline: debugAttentionSubline, theme: ThemeManager.shared.theme)
            return
        }
        #endif

        var inputs = DailyReviewInputs()
        inputs.now = Date()
        if sources.shiftStore.isInFailedLoadState {
            // GL-14/GL-01: "the store failed to parse" is not "nothing is
            // due", and the card renders it as a stated gap rather than as an
            // all-clear.
            let reason = "your tasks could not be read - a file in the Tasks store failed to parse"
            inputs.tasks = .unavailable(reason)
            inputs.followUps = .unavailable(reason)
        } else {
            inputs.tasks = .available(sources.shiftStore.activeTasks)
            inputs.followUps = .available(sources.shiftStore.followUps)
            var names: [String: String] = [:]
            for project in sources.shiftStore.projects { names[project.id] = project.name }
            inputs.projectNames = names
        }

        // R2-PERF-06: a service-health tick (every 30 and 60 seconds, from
        // two pollers) re-rendered this card, re-running the composer over
        // every active task and follow-up. When nothing it reads has moved
        // and the clock has not reached the digest's next change, the card
        // only takes its freshness line - GL-20's cheap check before the
        // expensive half.
        let extra = signalAttentionItems()
        let clear = clearNotes()
        var unclocked = inputs
        unclocked.now = .distantPast
        if let last = lastAttention, last.inputs == unclocked, last.extra == extra, last.clear == clear,
           inputs.now < last.validUntil {
            let header = hubHeader(hasItems: last.hasItems)
            if header.title == last.headerTitle {
                attentionCard.setSubline(header.detail)
                return
            }
        }

        #if FM_SELFTESTS
        debugDigestCount += 1
        #endif
        let digest = DailyReviewComposer.digest(from: inputs)
        // Whether the card will draw a list, which is what decides both of
        // the header's strings - see `hubHeader`. Derived from the digest
        // rather than from the built summary so the header can be handed to
        // the composer in the same call that builds it.
        let hasItems = !digest.dueTasks.isEmpty || !digest.followUps.isEmpty || !extra.isEmpty
        let header = hubHeader(hasItems: hasItems)
        lastAttention = AttentionComposed(inputs: unclocked, extra: extra, clear: clear, hasItems: hasItems,
                                          headerTitle: header.title,
                                          validUntil: DailyReviewComposer.nextChange(for: inputs))
        // UI-13: the card re-reads the freshness phrase once a minute while it
        // is on screen, so "Fleet read 4 min ago" stays true. The card owns
        // that tick; this controller keeps its no-timer refresh model.
        attentionCard.sublineProvider = { [weak self] in
            self?.hubHeader(hasItems: hasItems).detail ?? ""
        }
        attentionCard.render(NeedsAttentionComposer.summary(from: digest,
                                                            extra: extra,
                                                            clear: clear,
                                                            allClearHeadline: header.title),
                             // The **fleet freshness** line now, not the
                             // digest's own "as of".
                             //
                             // Before the merge this card sat under a hero
                             // band that carried the freshness line, and its
                             // own subline said when the digest was composed
                             // - a defensible answer for a card about tasks,
                             // and a useless one for a card that is now the
                             // page's whole verdict: the digest is re-derived
                             // on every render, so that line could only ever
                             // say "a moment ago". The fleet is the one
                             // source here whose age the captain cannot
                             // otherwise tell, which is the same argument
                             // review #3's UX5 made for putting it in the
                             // hero in the first place.
                             subline: header.detail,
                             theme: ThemeManager.shared.theme)
    }


    // MARK: The three non-to-do attention rows

    /// The reference's other attention sources, in its own order.
    ///
    /// **Rule 1 of this file holds.** Not one of these reads a store, starts
    /// a poll or shells out: the fleet snapshot, the quota reading and
    /// `BackgroundSignalsPoller.lastCounts` are all state that was pushed
    /// into this page for cards it already draws. What is new is that the
    /// card at the top of the page now says so in words as well.
    func signalAttentionItems() -> [NeedsAttentionItem] {
        // R2-UX-01 (c): the fleet and Claude's usage are the crew's, and the
        // session checks are Setup's.
        let crew = !hiddenModules.contains(.crew)
        let setup = !hiddenModules.contains(.setup)
        return [crew ? fleetAttentionItem() : nil, crew ? claudeAttentionItem() : nil,
                setup ? sessionChecksAttentionItem() : nil]
            .compactMap { $0 }
    }

    /// The fleet, when it needs the captain.
    ///
    /// This is the row that keeps the hero band's strongest verdict alive
    /// through the merge.
    ///
    /// **The test is the answer's own tint, and `metaRestatesCards` is the
    /// wrong one.** That flag means "this answer's `meta` repeats the cards
    /// below it", which is a statement about the *detail line* and not about
    /// whether anything is wrong - and it is `true` on the partly-unknown
    /// branch, where the PR scan failed. Using it dropped that branch's row
    /// entirely, so a hub that could not reach the forge fell back to
    /// "All clear" over a reading it had not taken. That is GL-14's exact
    /// rule, and `DaylightModuleSelfTest` caught it.
    ///
    /// `tint == .good` is the one branch `FleetGreeting` paints green, and
    /// it is the only one that is genuinely an all-clear. The other three -
    /// crew parked on a decision, a PR scan that failed, a firstmate home
    /// that could not be found - are each a thing the captain should see.
    func fleetAttentionItem() -> NeedsAttentionItem? {
        guard let answer = overviewAnswer(), answer.tint != .good else { return nil }
        return NeedsAttentionItem(
            id: "signal.fleet",
            kind: .signal(.fleet),
            source: answer.isSetupPrompt ? "Setup" : "Fleet",
            text: answer.title,
            meta: answer.meta,
            chipText: answer.kicker,
            // `.warn` rather than `.critical`: the crew is *holding*, which
            // is a state that wants the captain today and is not the same as
            // a task that is already five days late. The reference reserves
            // its red for what is genuinely overdue.
            tone: .risk,
            actionTitle: "Open",
            headlineClause: answer.title.prefix(1).lowercased() + answer.title.dropFirst())
    }

    /// Claude's extra usage, when it is at or near the spend cap.
    ///
    /// The threshold is `claudeSpendStatus`', not a second one: the card
    /// below already decides what "near cap" means, and a top-of-page row
    /// that disagreed with the card it points at would be worse than no row.
    func claudeAttentionItem() -> NeedsAttentionItem? {
        guard let snapshot = quotaSnapshot,
              let status = Self.claudeSpendStatus(for: snapshot),
              status.state != .ok else { return nil }
        let fraction = Self.claudeSpendFraction(for: snapshot)
        let atCap = (fraction ?? 0) >= 1
        return NeedsAttentionItem(
            id: "signal.claude",
            kind: .signal(.claudeUsage),
            source: "Claude usage",
            text: atCap ? "Extra usage hit the spend cap" : "Extra usage is near the spend cap",
            meta: Self.claudeSubtitle(for: snapshot),
            // `claudeSpendFraction` is 0...1 and `percentText` takes a
            // *percentage*, which is the one unit mismatch on this path -
            // measured in an off-screen render, where a 94% cap reported
            // "1%" on the row beside a card correctly reading "94%".
            chipText: fraction.map { Self.percentText($0 * 100) } ?? status.text,
            tone: .risk,
            actionTitle: "View usage",
            headlineClause: atCap ? "Claude has hit its spend cap" : "Claude is near its spend cap")
    }

    /// The background checks that have not run yet this session.
    ///
    /// The three counts named are the three the Setup cards render, and the
    /// sentence is built from whichever of them is still `nil` rather than
    /// from a fixed list - so a pass that produced two of three says two,
    /// which is the honest reading and the one GL-14 asks for.
    func sessionChecksAttentionItem() -> NeedsAttentionItem? {
        // **Not while the poller is warming up.** Its first pass lands about
        // ten seconds after launch, and this page is the launch landing - so
        // without this guard the hub would open on "Needs attention \u{00B7} 1: one
        // check is waiting" every single time, for ten seconds, about
        // nothing. That is a false alarm on the one card whose whole job is
        // to be believed.
        //
        // It is the same distinction `applyPendingSetupSignal` already draws
        // for the four Setup cards, which render a skeleton while a pass is
        // in flight and say so in words only once one has finished and
        // produced nothing: ordinary startup is not a fault, and a pass that
        // completed without a number is.
        guard !Self.pollerIsStillWarmingUp else { return nil }
        let counts = BackgroundSignalsPoller.shared.lastCounts
        var pending: [String] = []
        if counts.forkDrift == nil { pending.append("forks behind upstream") }
        if counts.toolUpdates == nil { pending.append("tool updates") }
        if counts.setupDrift == nil { pending.append("setup drift") }
        guard !pending.isEmpty else { return nil }
        return NeedsAttentionItem(
            id: "signal.checks",
            kind: .signal(.sessionChecks),
            source: "Session checks",
            text: Self.sentenceList(pending).prefix(1).uppercased()
                + Self.sentenceList(pending).dropFirst()
                + " haven\u{2019}t been checked yet this session",
            chipText: "\(pending.count) \(pending.count == 1 ? "check" : "checks") not run",
            tone: .info,
            actionTitle: "Open \(PlaceName.of(.bootstrap))")
    }

    /// "a", "a and b", "a, b, and c" - the reference's own joining.
    ///
    /// `static` and pure so the three-clause case can be asserted without a
    /// poller: it is the only one with a serial comma, and the only one a
    /// hand-rolled `joined(separator:)` gets wrong.
    static func sentenceList(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + (parts.last ?? "")
        }
    }

    /// The reference's closing strip: one phrase per source that was read and
    /// is fine.
    ///
    /// **A source that has not reported contributes nothing**, which is the
    /// whole discipline of this list: "Fleet idle" over a fleet that has
    /// never been read is a cheerful lie of exactly the kind GL-14 forbids,
    /// so every entry below is behind a `guard let` on the reading itself
    /// rather than behind a count being zero.
    func clearNotes() -> [String] {
        var notes: [String] = []
        // R2-UX-01 (c): a note speaks for a module in the sidebar only.
        let crew = !hiddenModules.contains(.crew)
        if crew, let snapshot = fleetSnapshot,
           snapshot.tasks.allSatisfy({ $0.status != "working" }),
           snapshot.tasks.allSatisfy({ $0.status != "needs_decision" && $0.status != "blocked" }) {
            notes.append("Fleet idle")
        }
        if !hiddenModules.contains(.health), let health = healthSummary.allHealthyNote {
            notes.append(health)
        }
        if crew, let snapshot = quotaSnapshot,
           let plan = Self.claudePlanLimitsStatus(for: snapshot), plan.state == .ok {
            notes.append("Claude plan limits comfortable")
        }
        return notes
    }

    /// The row checkbox. Writes through the **shared** store this page was
    /// given (GL-23) - a second `ShiftStore` would diverge from the Tasks
    /// page's within the session and race its writes.
    func markAttentionItemDone(_ item: NeedsAttentionItem) {
        switch item.kind {
        case .task: sources.shiftStore.setTaskCompleted(id: item.id, completed: true)
        case .followUp: sources.shiftStore.setFollowUpStatus(id: item.id, done: true)
        // A signal row draws no checkbox at all (see `NeedsAttentionItem.
        // Kind.signal`), so nothing can reach this - and it is deliberately
        // a no-op rather than a `fatalError`: the honest behaviour for
        // "complete something that is not a to-do" is to do nothing, not to
        // crash the hub.
        case .signal: return
        }
        // The row has just left the list, so the card has to be re-derived
        // rather than left showing what it was handed.
        render()
    }

    /// The row's trailing "Start" / "Open". A task opens itself; a follow-up
    /// has no deep link of its own, so it opens the page that owns it; a
    /// signal opens the page that owns the thing it is reporting.
    func openAttentionItem(_ item: NeedsAttentionItem) {
        switch item.kind {
        case .task: onOpenShiftTask?(item.id)
        case .followUp: onOpenDestination?(.shift)
        case .signal(let signal):
            switch signal {
            case .fleet:
                if let open = onOpenCrewDecisions { open() } else { onOpenDestination?(.overview) }
            // The same destination `follow(.quota)` already resolves to, and
            // the same one `DaylightModule.claudeStatus.opens` names: the
            // Claude-usage control lives on Console. Two callers, one answer.
            case .claudeUsage: onOpenDestination?(.console)
            case .sessionChecks: onOpenDestination?(.bootstrap)
            }
        }
    }

    /// The hero's detail line on **the hub**, which is the one surface that
    /// draws cards under it - review #3's UX5.
    ///
    /// The all-clear `meta` enumerates exactly the two cards immediately
    /// below the hero ("N crew working" is the Fleet card's subtitle, the PR
    /// clause is the Merge queue card, "nobody is parked" is the absence of
    /// the Fleet card's warn chip), so on this page it is the third statement
    /// of one fact. It is replaced with the one thing none of those cards can
    /// say: **how fresh the all-clear is**. "Nothing needs you" read four
    /// seconds ago and "nothing needs you" read forty minutes ago are
    /// genuinely different claims, and until now the hub gave a captain no way
    /// to tell them apart - the same shape of gap GL-14 is about.
    ///
    /// Every other branch keeps `meta` verbatim, and `FleetController`'s own
    /// banner is untouched - see `Answer.metaRestatesCards`.
    func heroDetail(for answer: FleetGreeting.Answer) -> String {
        guard answer.metaRestatesCards else { return answer.meta }
        return "Fleet read \(Self.freshnessPhrase(since: fleetReadAt))."
    }

    /// "just now" / "4 minutes ago" / "at 09:14" - deliberately coarse.
    ///
    /// A ticking seconds counter on a hub a captain leaves open all day would
    /// be motion for its own sake (and `HelmMotion`'s whole point is that this
    /// app does not do that); this line is re-derived when the fleet is read
    /// and when the canvas re-renders, which is exactly when the answer
    /// changes in a way worth reading.
    /// UI-13: the one relative-time phrase, so the attention card's "Fleet
    /// read 4 min ago" and the Claude card's "updated 4 min ago" agree.
    static func freshnessPhrase(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "just now" }
        return HelmRelativeTime.phrase(since: date, now: now)
    }

    /// What the hub says to a captain who has not put anything in yet -
    /// review #3's UX13. `nil` once they have, which is the overwhelmingly
    /// common case and the reason this is a guard rather than a mode.
    ///
    /// **Three stores, all empty**, deliberately - not one. A captain with
    /// tasks but no hosts is not new, they just do not use hosts; showing
    /// them "add your first host" would be the app misreading its own user.
    /// The condition is "this app has never been used", and the honest test
    /// for that is that nothing at all has been put into it.
    ///
    /// Pure and `static` so `DaylightModuleSelfTest` can assert both
    /// directions without a canvas - and the second direction is the one that
    /// matters, since a first-run banner that outstayed its welcome would be
    /// a permanent fixture on a working captain's hub.
    ///
    /// A `nil` tint at the call site is load-bearing: this is an invitation,
    /// not a verdict, and `setHero` drops the surface and the kicker for a
    /// `nil` tint precisely so a hero that has measured nothing cannot look
    /// like one reporting good news.
    static func firstRunHeroCopy(hosts: Int, tasks: Int, notes: Int) -> (title: String, detail: String)? {
        guard hosts == 0, tasks == 0, notes == 0 else { return nil }
        return (title: "Welcome aboard",
                detail: "Nothing is saved here yet. Add your first host (\u{2318}\u{2303}N) to keep a "
                    + "connection, or your first task (\u{2318}N) to keep a to-do. "
                    + "\u{2318}\u{21E7}D shows every page this app has.")
    }

    /// The hero's four strings and its badge, from one place.
    ///
    /// A `nil` tint means "this is an identity, not a verdict": the badge
    /// takes the space's own domain hue and the kicker is dropped, so a space
    /// that has measured nothing cannot look like it is reporting good news.
    func setHero(tint: HelmTint?,
                         symbol: String,
                         kicker: String,
                         title: String,
                         detail: String) {
        // `.neutral` is the one slot that claims nothing - deliberately not
        // a domain hue's `fallbackTint`, which resolves rose to `.critical`
        // and would paint an alert bar on a space that has reported nothing.
        heroTint = tint ?? .neutral
        heroBadge.configure(symbol: symbol, tint: heroTint, pointSize: 17)
        kickerLabel.stringValue = kicker.uppercased()
        kickerLabel.isHidden = kicker.isEmpty
        greetingLabel.stringValue = title
        subtitleLabel.stringValue = detail
        heroBadge.applyTheme(ThemeManager.shared.theme)
    }

    func visibleModules() -> [DaylightModule] {
        if showsArrangedCards, let shownLayout { return shownLayout.shown }
        return DaylightModule.canvasOrder.filter {
            $0.isVisible(in: space) && ($0 != .briefing || Self.briefingHasSomethingToSay)
        }
    }

    /// R5-UI-08 (full review #5): whether the Morning briefing card has
    /// anything of its own to show. Off, with no briefing on record, it took
    /// the largest slot on Home in both layouts to say "Turn on Morning
    /// briefing in Settings". It is left off Home until the briefing is on
    /// (Settings > General, which is also where that card pointed), and it
    /// is still in Customize, so the captain can place it.
    static var briefingHasSomethingToSay: Bool {
        AppSettings.shared.morningBriefingEnabled
            || !(AppSettings.shared.morningBriefingRecord?.clauses.isEmpty ?? true)
    }

    /// The arranged cards as drawn: the captain's layout, less a briefing
    /// card with nothing to say (R5-UI-08) - except while customizing, where
    /// every card the captain placed is drawn so it can be moved, sized or
    /// hidden, and where the drag and resize maths index `cardLayout` itself.
    var shownLayout: HomeCardLayout? {
        guard var layout = cardLayout else { return nil }
        // Out of the grid either way outside Customize: with nothing to say
        // (R5-UI-08), or because the feel pass draws it as the hero above
        // the grid (`briefingIsHero`). Customize keeps it a card, so it can
        // still be moved, sized or hidden like every other one.
        if !isCustomizing, layout.shown.contains(.briefing) {
            layout.hide(.briefing)
        }
        return layout
    }

    /// Whether the briefing is drawn as the feel pass's hero: Home's
    /// arranged cards include it, it has something to say, and Customize is
    /// not drawing it as a card.
    var briefingIsHero: Bool {
        showsArrangedCards && !isCustomizing && Self.briefingHasSomethingToSay
            && (cardLayout?.shown.contains(.briefing) ?? false)
    }

    /// Whether Home's own space is showing the captain's arranged cards.
    var showsArrangedCards: Bool { space == .overview && cardLayout != nil }

    /// A card's grid span: its own, or - on Home's arranged cards, which
    /// are laid out in `HomeCardGrid.columns` - the width the captain gave
    /// it, as its row draws it at this width (`HomeCardGrid.rows`).
    func cardSpan(_ module: DaylightModule) -> Int {
        guard showsArrangedCards, let shownLayout else { return module.gridSpan }
        return arrangedSpans(of: shownLayout, available: gridContainerWidth())[module]
            ?? shownLayout.size(of: module).columns
    }

    /// Home's arranged cards in rows at this width, each placement's `index`
    /// into `layout.shown` - the captain's rows, with room made in a row for
    /// a card the window has made too narrow to read.
    ///
    /// R5-UI-08: when `shownLayout` has left the briefing off, its slot is
    /// not left as a hole. If the captain's whole arrangement filled every
    /// row, the rows without it fill the width too; an arrangement that
    /// already had a short row keeps its shape.
    func arrangedRows(of layout: HomeCardLayout, available: CGFloat) -> [[HelmResponsiveGrid.SpanPlacement]] {
        let minimum = arrangedMinimumColumns(available: available)
        func spans(_ layout: HomeCardLayout) -> [Int] { layout.shown.map { layout.size(of: $0).columns } }
        var filling = false
        if let full = cardLayout, full.shown.count > layout.shown.count {
            filling = !HomeCardGrid.rows(spans: spans(full), minimum: minimum).contains { row in
                row.reduce(0) { $0 + $1.span } < HomeCardGrid.columns
            }
        }
        return HomeCardGrid.rows(spans: spans(layout), minimum: minimum, fillingShortRows: filling)
    }

    /// Each arranged card's columns at this width, as its row draws it.
    func arrangedSpans(of layout: HomeCardLayout, available: CGFloat) -> [DaylightModule: Int] {
        let shown = layout.shown
        var spans: [DaylightModule: Int] = [:]
        for placement in arrangedRows(of: layout, available: available).joined() where shown.indices.contains(placement.index) {
            spans[shown[placement.index]] = placement.span
        }
        return spans
    }

    /// How many cards each row of Home's arranged grid holds at this width -
    /// nothing off Home's arranged cards, whose rows only the spans decide.
    func arrangedRowLengths(available: CGFloat) -> [Int] {
        guard showsArrangedCards, let shownLayout else { return [] }
        return arrangedRows(of: shownLayout, available: available).map(\.count)
    }

    /// `module`'s row stored at the widths it is drawn at
    /// (`HomeCardGrid.drawnSpans`) - what sizing that card starts from, so
    /// the captain sizes what they see.
    func keepDrawnRow(of module: DaylightModule, in layout: inout HomeCardLayout, available: CGFloat) {
        let shown = layout.shown
        guard let index = shown.firstIndex(of: module) else { return }
        let spans = shown.map { layout.size(of: $0).columns }
        let kept = HomeCardGrid.drawnSpans(spans, minimum: arrangedMinimumColumns(available: available), rowOf: index)
        for (index, other) in shown.enumerated() where kept[index] != spans[index] {
            var size = layout.size(of: other)
            size.columns = kept[index]
            layout.setSize(size, for: other)
        }
    }

    /// The fewest of `HomeCardGrid.columns` a card may take at this width:
    /// the canvas's own minimum card width (§6.1's 255).
    func arrangedMinimumColumns(available: CGFloat) -> Int {
        HomeCardGrid.minimumColumns(containerWidth: available, minWidth: Self.minModuleWidth, spacing: Self.gridSpacing)
    }

    /// The height a card on Home's arranged grid is drawn at, `width` wide:
    /// the captain's, but never less than its content needs - or nil for a
    /// card that takes its row's height. Measured the way the shelf measures
    /// an exempt card's floor, after a real layout pass (gotcha (22)).
    func arrangedHeight(of module: DaylightModule, width: CGFloat) -> CGFloat? {
        guard showsArrangedCards, let height = cardLayout?.size(of: module).height else { return nil }
        return max(min(height, HomeCardGrid.maximumHeight), naturalHeight(of: module, width: width))
    }

    /// How tall a card's content needs it to be at `width`.
    func naturalHeight(of module: DaylightModule, width: CGFloat) -> CGFloat {
        let probe = Self.probeCard(content(for: module, placement: .shelf(width: width)))
        return max(Self.fittingHeight(of: probe, width: width), HelmModuleCard.minimumHeight)
    }
}
