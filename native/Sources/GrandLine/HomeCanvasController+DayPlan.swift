// Grand Line - native macOS app.
//
// F-02 of full review 4: Plan my day and Close the day on Home's hero.
//
// The hero's actions start the flows. While today's plan is open the hero
// draws the plan in place of the briefing ("Today's plan · 0 of 3 done · set
// at 9:41", "First up: ..."), with one tile per planned task. The rules are
// `DayPlanRules`; this file only reads Home's own sources and presents the
// sheets.

import AppKit

extension HomeCanvasController {

    var dayPlans: DayPlanStore { DayPlanStore.shared }

    /// Today's meetings, when the Mac's calendars are shown (F-01).
    func todaysMeetings(_ now: Date) -> [MacMeeting] {
        MacCalendarSource.shared.isShowing ? MacCalendarSource.shared.meetings(on: now) : []
    }

    /// Today's plan, while it is still open.
    func openDayPlan(_ now: Date) -> DayPlan? {
        guard let plan = dayPlans.plan(on: now), plan.closedAt == nil, !plan.items.isEmpty else { return nil }
        return plan
    }

    /// The hero's words while a plan is open: the plan in place of the
    /// briefing, and the running session as the status.
    func dayPlanHero(now: Date) -> (words: DayPlanRules.HeroWords, status: HelmHeroCard.Content.Status?, plan: DayPlan)? {
        guard !hiddenModules.contains(.tasks), let plan = openDayPlan(now) else { return nil }
        let completed = DayPlanRules.completedIDs(store: sources.shiftStore, now: now)
        let words = DayPlanRules.heroWords(plan, completed: completed, date: HomeGreeting.date(now))
        var status: HelmHeroCard.Content.Status?
        if let timer = sources.focusTimer, let session = timer.session {
            let ends = now.addingTimeInterval(TimeInterval(session.remaining(at: now)))
            status = .init(text: session.isPaused ? "Focus paused on \(session.taskTitle)"
                                                  : DayPlanRules.focusStatus(endsAt: ends),
                           tint: .accent)
        }
        return (words, status, plan)
    }

    /// The plan's actions for the hero, as (title, selector) pairs.
    func dayPlanActions(now: Date) -> [(String, Selector)] {
        guard !hiddenModules.contains(.tasks), !sources.shiftStore.isInFailedLoadState else { return [] }
        let completed = DayPlanRules.completedIDs(store: sources.shiftStore, now: now)
        let hasCandidates = sources.shiftStore.activeTasks.contains(where: DayPlanRules.isOpen)
        let actions = DayPlanRules.heroActions(plan: dayPlans.plan(on: now), hasCandidates: hasCandidates,
                                               focusing: sources.focusTimer?.isRunning == true,
                                               completed: completed, now: now)
        return actions.compactMap { action in
            let selector: Selector
            switch action {
            case .planMyDay, .changePlan: selector = #selector(heroPlanMyDay)
            case .startFocus:
                guard sources.focusTimer != nil else { return nil }
                selector = #selector(heroStartFocus)
            case .closeDay: selector = #selector(heroCloseDay)
            }
            return (DayPlanRules.title(of: action), selector)
        }
    }

    // MARK: The flows

    @objc func heroPlanMyDay() { presentPlanMyDay() }

    @objc func heroCloseDay() { presentCloseTheDay() }

    /// Start focus: the plan's next task, or with no plan the first task
    /// Plan my day would have ticked.
    @objc func heroStartFocus() {
        guard !isCustomizing, let timer = sources.focusTimer else { return }
        let now = DayRollover.now()
        let store = sources.shiftStore
        var taskID: String?
        if let plan = openDayPlan(now) {
            taskID = DayPlanRules.nextItem(plan, completed: DayPlanRules.completedIDs(store: store, now: now))?.taskID
        } else {
            let groups = DayPlanRules.candidates(tasks: store.activeTasks, carried: [], now: now)
            taskID = DayPlanRules.defaultPicks(groups).first ?? groups.first?.items.first?.task.id
        }
        guard let taskID, let task = store.activeTasks.first(where: { $0.id == taskID }) else { return }
        timer.start(task: task)
        setNeedsRender()
    }

    @discardableResult
    func presentPlanMyDay() -> PlanMyDaySheet? {
        guard !isCustomizing else { return nil }
        let now = DayRollover.now()
        let sheet = PlanMyDaySheet(store: sources.shiftStore, plans: dayPlans, meetings: todaysMeetings(now),
                                   timer: sources.focusTimer)
        sheet.onSaved = { [weak self] _ in
            Feedback.clear(id: DayPlanRules.Nudge.morning.id)
            self?.setNeedsRender()
        }
        if view.window != nil { presentAsSheet(sheet) }
        return sheet
    }

    @discardableResult
    func presentCloseTheDay() -> CloseTheDaySheet? {
        guard !isCustomizing else { return nil }
        let now = DayRollover.now()
        guard let plan = openDayPlan(now) else { return nil }
        let sheet = CloseTheDaySheet(plan: plan, store: sources.shiftStore, plans: dayPlans,
                                     meetingCount: todaysMeetings(now).filter { !$0.isAllDay }.count)
        sheet.onClosed = { [weak self] _ in
            Feedback.clear(id: DayPlanRules.Nudge.evening.id)
            self?.setNeedsRender()
        }
        if view.window != nil { presentAsSheet(sheet) }
        return sheet
    }
}
