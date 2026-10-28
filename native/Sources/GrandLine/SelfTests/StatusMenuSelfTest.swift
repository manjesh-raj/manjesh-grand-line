// Grand Line - native macOS app.
//
// P6 of the Grand Line vs Automic Vault polish report: the compact-mode
// status item's right-click menu (the captain's decision: a left-click keeps
// the four-tab popover).
//
// What is asserted: which click opens which surface, what the menu lists and
// what each item does when picked through its real target and action, and
// that a locked app's menu carries none of the captain's data (GL-09). The
// menu is built, never opened - opening one is a modal tracking loop, which
// no suite here runs.
//
// Run with:
//   swift build && FM_RUN_STATUS_MENU_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: no window. It guards CI's blocking lane.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum StatusMenuSelfTest {

    static func run() -> Bool {
        var ok = true
        let wasLocked = AppLockGate.shared.isLocked
        defer {
            AppLockGate.shared.setLocked(wasLocked)
            GrandLineNotificationCenter.shared.debugReset()
        }
        for each in [checkTheClickRoute, checkTheMenuListsAndActs, checkALockedMenuCarriesNoData, checkTheControllerFeedsIt] {
            var caseOK = true
            each(&caseOK)
            ok = ok && caseOK
        }
        print(ok ? "StatusMenuSelfTest: all checks passed" : "StatusMenuSelfTest: FAILED")
        return ok
    }

    // MARK: Fixtures

    private static func task(_ id: String, _ title: String, _ urgency: CompactTaskRow.Urgency = .today) -> CompactTaskRow {
        CompactTaskRow(id: id, title: title, detail: "due today", urgency: urgency)
    }

    private final class Log { var calls: [String] = [] }

    private static func inputs(_ log: Log, unlocked: Bool = true, tasks: Int = 2, alerts: Int = 1) -> CompactModeStatusMenu.Inputs {
        CompactModeStatusMenu.Inputs(
            isUnlocked: unlocked,
            needsYou: (0..<alerts).map { n in ("Alert \(n)", { log.calls.append("alert \(n)") }) },
            dueToday: (0..<tasks).map { task("t\($0)", "Task \($0)", $0 == 0 ? .overdue : .today) },
            onCompleteTask: { log.calls.append("done \($0)") },
            onOpenTasks: { log.calls.append("tasks") },
            onAskCrew: { log.calls.append("crew") },
            onShowPopover: { log.calls.append("popover") },
            onOpenFullWindow: { log.calls.append("window") },
            onOpenSettings: { log.calls.append("settings") })
    }

    private static func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    // MARK: Cases

    private static func checkTheClickRoute(_ ok: inout Bool) {
        print("\n-- P6: a left-click is the popover, a right- or control-click the menu --")
        check(CompactModeClickRoute.route(for: .leftMouseUp, modifiers: []) == .popover, "a left-click did not open the popover", &ok)
        check(CompactModeClickRoute.route(for: .rightMouseUp, modifiers: []) == .menu, "a right-click did not open the menu", &ok)
        check(CompactModeClickRoute.route(for: .leftMouseUp, modifiers: [.control]) == .menu, "a control-click did not open the menu", &ok)
        check(CompactModeClickRoute.route(for: .leftMouseUp, modifiers: [.command]) == .popover, "a command-click opened the menu", &ok)
        // ⌃⌥G toggles with no mouse event at all.
        check(CompactModeClickRoute.route(for: nil, modifiers: []) == .popover, "a click with no event did not open the popover", &ok)
        if ok { print("  OK   left and command-click: popover; right and control-click: menu") }
    }

    private static func checkTheMenuListsAndActs(_ ok: inout Bool) {
        print("\n-- P6: the menu lists what needs the captain and acts on it --")
        let log = Log()
        let menu = CompactModeStatusMenu.build(inputs(log, tasks: 7, alerts: 2))
        let titles = menu.items.map(\.title)
        for expected in ["Needs you \u{00B7} 2", "Due today \u{00B7} 7", "Crew", "Show Popover", "Open Grand Line", "Settings\u{2026}"] {
            check(titles.contains(expected), "the menu has no \u{201C}\(expected)\u{201D} (it has \(titles))", &ok)
        }
        let tasksShown = titles.filter { $0.hasPrefix("Task ") }
        check(tasksShown.count == CompactModeStatusMenu.rowLimit, "the menu lists \(tasksShown.count) tasks, the budget is \(CompactModeStatusMenu.rowLimit)", &ok)
        check(titles.contains("View all 7 in Tasks"), "a long day does not say how many it left out", &ok)

        guard let first = item(menu, "Task 0"), let submenu = first.submenu,
              let done = submenu.items.first(where: { $0.title == "Mark Done" }),
              let open = submenu.items.first(where: { $0.title == "Open in Tasks" }) else {
            return fail("a due task has no Mark Done / Open in Tasks submenu", &ok)
        }
        HelmMenuAction.debugPerform(done)
        HelmMenuAction.debugPerform(open)
        for title in ["Alert 1", "Ask the Crew\u{2026}", "Show Popover", "Open Grand Line", "Settings\u{2026}"] {
            guard let picked = item(menu, title) else { fail("no \u{201C}\(title)\u{201D} item", &ok); continue }
            HelmMenuAction.debugPerform(picked)
        }
        check(log.calls == ["done t0", "tasks", "alert 1", "crew", "popover", "window", "settings"],
              "picking the items ran \(log.calls)", &ok)

        let empty = CompactModeStatusMenu.build(inputs(Log(), tasks: 0, alerts: 0))
        check(item(empty, "Nothing needs you") != nil && item(empty, "Nothing due") != nil,
              "an empty day does not say so", &ok)
        if ok { print("  OK   sections with counts, a 5-row budget with View all, submenus, every item through its target") }
    }

    private static func checkALockedMenuCarriesNoData(_ ok: inout Bool) {
        print("\n-- P6: GL-09, a locked menu shows only the ways back in --")
        let log = Log()
        let menu = CompactModeStatusMenu.build(inputs(log, unlocked: false, tasks: 3, alerts: 2))
        let titles = menu.items.map(\.title)
        check(!titles.contains { $0.hasPrefix("Task ") || $0.hasPrefix("Alert ") || $0.hasPrefix("Needs you") || $0.hasPrefix("Due today") },
              "a locked menu lists the captain's data: \(titles)", &ok)
        guard let unlock = item(menu, "Unlock\u{2026}") else { return fail("a locked menu has no way to unlock", &ok) }
        HelmMenuAction.debugPerform(unlock)
        check(log.calls == ["popover"], "Unlock ran \(log.calls), expected the popover's own unlock form", &ok)
        if ok { print("  OK   locked: \(titles.filter { !$0.isEmpty })") }
    }

    /// The controller's own builder, so the providers and the gate are the
    /// real wiring rather than this suite's inputs.
    private static func checkTheControllerFeedsIt(_ ok: inout Bool) {
        print("\n-- P6: the controller builds the menu from the popover's own data --")
        let center = GrandLineNotificationCenter.shared
        center.debugReset()
        center.set(AppNotification(id: "p6", title: "Rotate the deploy key", subtext: "", kind: .actionNeeded,
                                   tint: .warn, navigate: {}), id: "p6")
        center.set(AppNotification(id: "p6-info", title: "Tools have updates", subtext: "", kind: .informational,
                                   tint: .info, navigate: {}), id: "p6-info")
        let content = CompactModePopoverController()
        content.todayProvider = {
            CompactTodayDigest(rows: [task("a", "Renew the cert", .overdue)], overdueCount: 1, focusChip: nil, followUpChip: nil)
        }
        let controller = CompactModeController(content: content)

        AppLockGate.shared.setLocked(false)
        let titles = controller.buildStatusMenu().items.map(\.title)
        check(titles.contains("Rotate the deploy key"), "the menu does not list the action-needed entry", &ok)
        check(!titles.contains("Tools have updates"), "the menu lists an informational entry under Needs you", &ok)
        check(titles.contains("Renew the cert"), "the menu does not list the Today tab's task", &ok)

        AppLockGate.shared.setLocked(true)
        let locked = controller.buildStatusMenu().items.map(\.title)
        check(!locked.contains("Rotate the deploy key") && !locked.contains("Renew the cert"),
              "locked, the controller's menu still lists the captain's data: \(locked)", &ok)
        AppLockGate.shared.setLocked(false)
        withExtendedLifetime(controller) {}
        if ok { print("  OK   needs-you from the notification center, due today from the Today digest, gated by the lock") }
    }
}

#endif
