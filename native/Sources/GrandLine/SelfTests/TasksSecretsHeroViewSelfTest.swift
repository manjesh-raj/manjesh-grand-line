// Grand Line - native macOS app.
//
// Tasks (T-4) and Secrets (S-3, and S-1's split card on Automic Vault) on the
// page-redesign board, mounted in a real off-screen sidebar shell with the
// tour lab's demo tasks, vault and Automic Vault read, and driven through the
// pages' own controls.
//
// Window-backed, because what it asserts is real layout and real dispatch:
//
//   - T-4: the slim band sits over the filter row and the board starts under
//     it, each lane wears a toned band with its count and detail, the band's
//     "+" adds to its own lane, and Weekly review drops the band.
//   - B-01: the page turns over at midnight - its kicker, a "Due today"
//     card and the Overdue figure - with no store change.
//   - S-3: the hero column is the split's sidebar in place of the plain one,
//     its rows filter the table and the selected one is a pill in the ink,
//     the auto-lock ring counts down in place, and Lock now locks.
//   - S-1 on Automic Vault: the split card carries the launcher verdict, amber
//     while one needs attention, with View Fix on the gradient and on its row.
//   - Every word on the gradients is in the hero's ink.
//
// The words themselves and the palette sweeps are asserted headless in
// `TasksSecretsHeroSelfTest`.
//
// With `FM_TASKS_SECRETS_RENDER_DIR` set it also writes one PNG per page,
// state, width and theme into that folder (the PR's renders). Nothing is
// written otherwise.
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_TASKS_SECRETS_HERO_VIEW_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TasksSecretsHeroViewSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-secrets-hero-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let callerStores = SelfTestScratchStores.fingerprints()
        let checksOK = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var allOK = true
            ThemeManager.shared.setTheme(daylight)
            let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            ReviewTourLab.seedDemoTasks(shell.workspace.shiftStore)
            _ = ReviewTourLab.seedDemoVault(shell.debugPoneglyphStore)
            settle(shell)
            let checks: [(MainSplitShellController, NSWindow, inout Bool) -> Void] = [
                checkTasksBand, checkTasksLanes, checkTasksLaneAdd, checkTasksBandLeavesWeeklyReview,
                checkTasksTurnOverAtMidnight,
                checkSecretsColumn, checkSecretsRows, checkSecretsRing, checkVaultSplit,
                writeRenders, checkSecretsLockNow,
            ]
            for check in checks {
                var ok = true
                autoreleasepool { check(shell, window, &ok) }
                allOK = allOK && ok
            }
            return allOK
        }
        var storesOK = true
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &storesOK)
        let allOK = checksOK && storesOK
        print(allOK ? "TasksSecretsHeroViewSelfTest: all checks passed" : "TasksSecretsHeroViewSelfTest: FAILED")
        return allOK
    }

    // MARK: Harness

    static var daylight: HelmTheme { HelmTheme.appThemes.first { $0.id == "daylight" } ?? ThemeManager.shared.theme }
    static var dusk: HelmTheme { HelmTheme.appThemes.first { $0.id == "dusk" } ?? ThemeManager.shared.theme }

    static func settle(_ shell: WorkspaceShellController) {
        for _ in 0..<3 {
            shell.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        shell.view.layoutSubtreeIfNeeded()
    }

    static func resize(_ window: NSWindow, width: CGFloat, _ shell: WorkspaceShellController) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        settle(shell)
    }

    @discardableResult
    static func showTasks(_ shell: MainSplitShellController, tab: String = "Board") -> ShiftController {
        shell.workspace.navigator.show(.shift)
        let shift = shell.workspace.shift
        shift.selectModuleTab(named: tab)
        shell.setInspectorShown(false)
        settle(shell)
        return shift
    }

    static func frame(of view: NSView, in page: NSView) -> NSRect {
        view.convert(view.bounds, to: page)
    }

    /// Whether `color` is `ink` (components and alpha), not merely as bright.
    static func isInk(_ color: NSColor?, _ ink: NSColor, alpha: CGFloat = 1) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB), let ink = ink.usingColorSpace(.sRGB) else { return false }
        return abs(color.redComponent - ink.redComponent) < 0.02 && abs(color.greenComponent - ink.greenComponent) < 0.02
            && abs(color.blueComponent - ink.blueComponent) < 0.02 && abs(color.alphaComponent - alpha) < 0.03
    }

    // MARK: T-4

    private static func checkTasksBand(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let shift = showTasks(shell)
        guard let band = shift.debugHeroBand else {
            fail("T-4: Board draws no slim band", &ok)
            return
        }
        let page = shift.view
        let bandFrame = frame(of: band, in: page)
        check(bandFrame.height <= 170 && bandFrame.height >= 100,
              "Tf-2: the band is \(bandFrame.height)pt tall, want the band and its filter pills, about 140", &ok)
        // Tf-2: the band is the filters. No filter row, and no grey count
        // line on the header above it.
        check(!containsFilterBar(page), "Tf-2: the page still draws a filter row", &ok)
        check(shell.debugHeader == nil, "Tf-2: the header line still says \(shell.debugHeader?.subtitle ?? "")", &ok)
        check(band.debugHeadline.hasSuffix("today.") || band.debugHeadline.hasPrefix("Nothing")
                || band.debugHeadline.hasPrefix("Only"),
              "T-4: the band says \"\(band.debugHeadline)\"", &ok)
        check(band.debugKicker.hasPrefix("TASKS \u{00B7} "), "T-4: the kicker is \"\(band.debugKicker)\"", &ok)
        check(band.debugFigureCaptions == ["All open", "Due today", "Overdue", "Follow-ups"],
              "Tf-2: the figures are \(band.debugFigureCaptions)", &ok)
        check(band.debugSelectedFigure == "All open", "Tf-2: \(band.debugSelectedFigure ?? "nothing") is on at first", &ok)
        check(band.debugRing != nil, "T-4: the band draws no ring", &ok)
        if let palette = band.debugPalette {
            let ink = HelmContrast.color(palette.ink)
            check(isInk(band.debugHeadlineColor, ink), "T-4: the headline is not in the ink", &ok)
            // The figure that is on is drawn solid in the ink.
            if let all = band.debugFigureButtons.first {
                check(isInk(all.debugFillColor, ink), "Tf-2: the figure that is on is not drawn solid", &ok)
            }
        }

        // A figure is the scope: a click on Due today shows today's, through
        // the figure's own click, and All open goes back.
        band.debugFigureButtons[1].performPrimaryAction()
        settle(shell)
        check(shift.debugTaskScope == "due_today", "Tf-2: Due today picked \(shift.debugTaskScope)", &ok)
        check(band.debugSelectedFigure == "Due today", "Tf-2: \(band.debugSelectedFigure ?? "nothing") is drawn on", &ok)
        band.debugFigureButtons[0].performPrimaryAction()
        settle(shell)
        check(shift.debugTaskScope == "all", "Tf-2: All open picked \(shift.debugTaskScope)", &ok)

        // A Smart view is a pill that turns solid while it is on, and a
        // second click goes back to every task.
        let pills = band.debugPills
        pills.priorities.performClick(nil)
        settle(shell)
        check(shift.debugTaskScope == "my_priorities", "Tf-2: My priorities picked \(shift.debugTaskScope)", &ok)
        check(pills.priorities.heroSelection != nil, "Tf-2: My priorities is on but drawn as a ghost pill", &ok)
        check(band.debugSelectedFigure == nil, "Tf-2: a figure stays on beside a Smart view", &ok)
        pills.priorities.performClick(nil)
        settle(shell)
        check(shift.debugTaskScope == "all", "Tf-2: a second click left \(shift.debugTaskScope) on", &ok)
        check(pills.project.title == "All projects", "Tf-2: the project pill says \(pills.project.title)", &ok)
        check(!pills.sort.isHidden, "Tf-2: the band draws no sort", &ok)

        // R4-UI-09: Follow-ups is a lane on a wide board, so its figure goes
        // nowhere; on List it jumps to the Follow-ups card.
        let followUps = band.debugFigureButtons[3]
        check(!followUps.debugIsActivatable, "Tf-2: Follow-ups jumps away from a board that shows them", &ok)
        showTasks(shell, tab: "List")
        check(shift.debugHeroBand?.debugFigureButtons[3].debugIsActivatable == true,
              "Tf-2: on List the Follow-ups figure does not jump to the card", &ok)
        showTasks(shell)

        // A narrow page keeps every filter: the ring steps out and the
        // figures drop under the words rather than leaving the band.
        resize(window, width: 1000, shell)
        if let band = shift.debugHeroBand {
            let bounds = band.bounds
            for figure in band.debugFigureButtons {
                let f = figure.convert(figure.bounds, to: band)
                check(!figure.isHiddenOrHasHiddenAncestor && bounds.contains(f.insetBy(dx: 1, dy: 1)),
                      "Tf-2: at \(bounds.width)pt \(figure.caption) is \(f) in a \(bounds.size) band", &ok)
            }
            for pill in [band.debugPills.priorities, band.debugPills.recent, band.debugPills.project] {
                let f = pill.convert(pill.bounds, to: band)
                check(bounds.contains(f.insetBy(dx: 1, dy: 1)),
                      "Tf-2: at \(bounds.width)pt the \(pill.title) pill is \(f), outside the band", &ok)
            }
        }
        resize(window, width: 1512, shell)
    }

    /// Full review 2026-11-25, B-01: a Tasks page left open over midnight
    /// turns over with no store change. Before the fix the page rendered only
    /// on a store change or a visit, so its kicker kept yesterday's date, a
    /// task due yesterday still said "Due today" and nothing moved to Overdue.
    ///
    /// The page's clock is pinned to one minute before midnight, then moved
    /// two minutes on, and the system's own day-change notification is
    /// posted: the path the captain's Mac takes at midnight. The day is in
    /// 2031 so every seeded task is already overdue on both sides of it, and
    /// only the probe's state changes.
    private static func checkTasksTurnOverAtMidnight(_ shell: MainSplitShellController, _ window: NSWindow,
                                                     _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let calendar = Calendar.current
        guard let day = calendar.date(from: DateComponents(year: 2031, month: 3, day: 14, hour: 12)),
              let beforeMidnight = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day),
              let afterMidnight = calendar.date(byAdding: .minute, value: 2, to: beforeMidnight) else {
            return fail("B-01 fixture: the calendar could not build the fixture's instants", &ok)
        }
        DayRollover.nowOverrideForTests = beforeMidnight
        let store = shell.workspace.shiftStore
        var probe = ShiftTask.fresh()
        probe.title = "Midnight rollover probe"
        probe.dueDate = ShiftDateFormatting.components(from: beforeMidnight).dateStr
        store.addTask(probe)
        defer {
            DayRollover.nowOverrideForTests = nil
            _ = store.deleteTask(id: probe.id)
            settle(shell)
        }
        let shift = showTasks(shell)

        func probeDue() -> String? {
            shift.debugBoardColumns.flatMap(\.debugCardViews)
                .first { $0.taskID == probe.id }?.debugDue
        }
        func kickerNames(_ date: Date) -> Bool {
            let named = ShiftHeroWords.kickerFormatter.string(from: date).uppercased()
            return shift.debugHeroBand?.debugKicker.uppercased().contains(named) == true
        }
        let dueFigure = { shift.debugHeroBand?.debugFigureButtons[1].debugCount }
        let overdueFigure = { shift.debugHeroBand?.debugFigureButtons[2].debugCount }
        /// Waits on what the checks read, never on a fixed pump: the store's
        /// render after `addTask` is coalesced onto a later turn.
        func waitUntil(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                shell.view.layoutSubtreeIfNeeded()
            }
        }
        waitUntil { probeDue() != nil && dueFigure() == "1" }

        // The fixture's discriminating power: the two instants name two days.
        check(ShiftHeroWords.kickerFormatter.string(from: beforeMidnight)
                != ShiftHeroWords.kickerFormatter.string(from: afterMidnight),
              "B-01 fixture: the two instants name the same day", &ok)
        check(kickerNames(beforeMidnight), "B-01 fixture: the kicker reads \(shift.debugHeroBand?.debugKicker ?? "-")", &ok)
        check(probeDue()?.hasPrefix("Due today") == true,
              "B-01 fixture: the probe's card reads \(probeDue() ?? "no card")", &ok)
        check(dueFigure() == "1", "B-01 fixture: Due today counts \(dueFigure() ?? "-") before midnight", &ok)
        guard let overdueBefore = overdueFigure().flatMap({ Int($0) }) else {
            return fail("B-01 fixture: the band shows no overdue figure", &ok)
        }

        DayRollover.nowOverrideForTests = afterMidnight
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        waitUntil { kickerNames(afterMidnight) && probeDue()?.hasPrefix("Overdue") == true && dueFigure() == "0" }

        check(kickerNames(afterMidnight),
              "B-01: after midnight the kicker still reads \(shift.debugHeroBand?.debugKicker ?? "-")", &ok)
        check(probeDue()?.hasPrefix("Overdue 1 day") == true,
              "B-01: after midnight yesterday's task reads \(probeDue() ?? "no card")", &ok)
        check(dueFigure() == "0", "B-01: after midnight Due today still counts \(dueFigure() ?? "-")", &ok)
        check(overdueFigure() == "\(overdueBefore + 1)",
              "B-01: after midnight Overdue counts \(overdueFigure() ?? "-"), want \(overdueBefore + 1)", &ok)
    }

    /// Whether a `HelmFilterBar` is anywhere under `view`.
    static func containsFilterBar(_ view: NSView) -> Bool {
        view is HelmFilterBar || view.subviews.contains { !$0.isHidden && containsFilterBar($0) }
    }

    private static func checkTasksLanes(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let shift = showTasks(shell)
        let columns = shift.debugBoardColumns
        check(columns.count == 3, "T-4: the board has \(columns.count) status lanes", &ok)
        let tones: [ShiftLaneTone] = [.accent, .slate, .green]
        for (column, tone) in zip(columns, tones) {
            guard let band = column.debugLaneBand else {
                fail("T-4: \(column.column.title) has no band", &ok)
                continue
            }
            check(band.tone == tone, "T-4: \(column.column.title) is \(band.tone), want \(tone)", &ok)
            check(band.debugCount == "\(column.debugCardViews.count)",
                  "T-4: \(column.column.title)'s band counts \(band.debugCount) over \(column.debugCardViews.count) cards", &ok)
            check(!band.debugDetail.isEmpty, "T-4: \(column.column.title)'s band has no detail line", &ok)
            check(column.debugHeader.isHidden, "T-4: \(column.column.title) still draws its plain header", &ok)
            if let palette = band.debugPalette {
                let ink = HelmContrast.color(palette.ink)
                check(band.debugInkLabels.first.map { isInk($0.textColor, ink) } ?? false,
                      "T-4: \(column.column.title)'s count is not in the ink", &ok)
            }
            // The first card sits under the band, inside the lane.
            if let card = column.debugCardViews.first {
                let cardFrame = frame(of: card, in: column)
                let bandFrame = frame(of: band, in: column)
                check(column.isFlipped ? cardFrame.minY >= bandFrame.maxY : cardFrame.maxY <= bandFrame.minY,
                      "T-4: \(column.column.title)'s first card \(cardFrame) is under its band \(bandFrame)", &ok)
            }
        }
        check(columns.last?.debugLaneBand?.addButton == nil, "T-4: the Done lane's band offers a +", &ok)
    }

    /// A band's "+" is its lane's own Add: it opens the new-task sheet for
    /// that lane, through the lane's `onAddTask`.
    private static func checkTasksLaneAdd(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let shift = showTasks(shell)
        guard let column = shift.debugBoardColumns.first(where: { $0.column == .inProgress }),
              let plus = column.debugLaneBand?.addButton else {
            fail("T-4: In Progress has no + on its band", &ok)
            return
        }
        let previous = column.onAddTask
        var added: ShiftBoardColumn?
        column.onAddTask = { added = $0 }
        plus.performClick(nil)
        column.onAddTask = previous
        check(added == .inProgress, "T-4: In Progress's + added to \(String(describing: added))", &ok)
    }

    private static func checkTasksBandLeavesWeeklyReview(_ shell: MainSplitShellController, _ window: NSWindow,
                                                         _ ok: inout Bool) {
        let shift = showTasks(shell, tab: "Weekly review")
        check(shift.debugHeroBand == nil, "T-4: Weekly review still draws the band", &ok)
        showTasks(shell, tab: "Calendar")
        check(shift.debugHeroBand == nil, "T-4: Calendar gives the band its height", &ok)
        showTasks(shell, tab: "List")
        check(shift.debugHeroBand != nil, "T-4: List draws no band", &ok)
        showTasks(shell, tab: "Board")
    }

    // MARK: S-3

    @discardableResult
    static func showSecrets(_ shell: MainSplitShellController) -> CredentialVaultController {
        shell.workspace.navigator.show(.poneglyph)
        let page = shell.workspace.poneglyph
        shell.setInspectorShown(false)
        settle(shell)
        return page
    }

    private static func checkSecretsColumn(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let page = showSecrets(shell)
        guard page.store.isUnlocked else {
            fail("fixture: the demo vault is locked", &ok)
            return
        }
        guard let column = page.heroColumn, let split = page.splitPage else {
            fail("S-3: Secrets has no hero column", &ok)
            return
        }
        check(column.isDescendant(of: split.sidebarPane), "S-3: the column is not the split's sidebar", &ok)
        let columnFrame = frame(of: column, in: page.view)
        let table = frame(of: page.debugCredentialTable.card, in: page.view)
        check(abs(columnFrame.width - HelmHeroColumn.width) < 1.5,
              "S-3: the column is \(columnFrame.width)pt, want \(HelmHeroColumn.width)", &ok)
        check(columnFrame.maxX <= table.minX, "S-3: the column \(columnFrame) runs into the table \(table)", &ok)
        check(column.debugHeadline.hasSuffix("with live 2FA.") || column.debugHeadline.hasSuffix("credentials."),
              "S-3: the column says \"\(column.debugHeadline)\"", &ok)
        check(column.debugSectionTitles == ["Kinds", "Collections"],
              "S-3: the sections are \(column.debugSectionTitles)", &ok)
        check(column.debugKicker == "Secrets \u{00B7} Unlocked", "S-3: the kicker is \(column.debugKicker)", &ok)
        if let palette = column.debugPalette {
            let ink = HelmContrast.color(palette.ink)
            check(isInk(column.debugHeadlineLabel.textColor, ink), "S-3: the headline is not in the ink", &ok)
            for row in page.debugHeroRows where !row.isSelected {
                check(isInk(row.debugTitleColor, ink), "S-3: \(row.debugTitle) is not in the ink", &ok)
            }
        }
    }

    /// A row filters the table, and the selected row is the pill.
    private static func checkSecretsRows(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let page = showSecrets(shell)
        let rows = page.debugHeroRows
        check(rows.map(\.debugTitle) == ["All credentials", "Logins", "2FA codes", "Secure notes", "Email",
                                         "Cloud & AWS", "API keys", "Other"],
              "S-3: the rows are \(rows.map(\.debugTitle))", &ok)
        check(rows.first?.isSelected == true && rows.dropFirst().allSatisfy { !$0.isSelected },
              "S-3: All credentials is not the one selected row", &ok)
        check(rows.first?.debugCount == "\(page.store.credentials.count)",
              "S-3: All counts \(rows.first?.debugCount ?? "nothing") of \(page.store.credentials.count)", &ok)
        guard let twoFactor = rows.first(where: { $0.debugTitle == "2FA codes" }) else { return }
        twoFactor.performPrimaryAction()
        settle(shell)
        check(page.debugCollectionFilter == .twoFactor, "S-3: 2FA codes filtered by \(page.debugCollectionFilter)", &ok)
        check(twoFactor.isSelected && rows.first?.isSelected == false, "S-3: the pill did not move to 2FA codes", &ok)
        let shown = page.filteredCredentials()
        check(!shown.isEmpty && shown.allSatisfy { $0.totp != nil }, "S-3: the table shows \(shown.map(\.title))", &ok)
        if let palette = page.heroColumn?.debugPalette {
            let ink = HelmContrast.color(palette.ink)
            check(isInk(twoFactor.debugFill, ink), "S-3: the selected row is not a pill in the ink", &ok)
            let words = HelmContrast.components(twoFactor.debugTitleColor ?? .clear)
            check(HelmContrast.ratio(words, palette.ink) >= HelmContrast.textTarget,
                  "S-3: the pill's words do not clear the text floor on it", &ok)
        }
        rows.first?.performPrimaryAction()
        settle(shell)
    }

    /// The ring counts down from the page's own idle clock, in place.
    private static func checkSecretsRing(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let page = showSecrets(shell)
        let total = page.store.settings.autoLockSeconds
        guard total > 60, let column = page.heroColumn else {
            fail("fixture: auto-lock is \(total)s, or no column", &ok)
            return
        }
        page.debugSetLastInteraction(Date().addingTimeInterval(-60))
        column.setRing(page.heroAutoLockRing())
        let left = total - 60
        let want = String(format: "%d:%02d", left / 60, left % 60)
        let label = column.debugRing?.debugLabel ?? ""
        check(label == want || label == String(format: "%d:%02d", (left + 1) / 60, (left + 1) % 60),
              "S-3: the ring reads \(label), want about \(want)", &ok)
        page.debugSetLastInteraction(Date())
    }

    /// Lock now, at the column's foot, locks the vault.
    private static func checkSecretsLockNow(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        let page = showSecrets(shell)
        page.debugHeroLockButton.performClick(nil)
        settle(shell)
        check(!page.store.isUnlocked, "S-3: Lock now left the vault unlocked", &ok)
    }

    // MARK: S-1 on Automic Vault

    static let demoTools: [VaultTool] = [
        VaultTool(name: "claude", commands: ["claude"], status: .hardened),
        VaultTool(name: "node", commands: ["npm"], status: .needsAttention(issueCount: 1), issues: [
            VaultToolIssue(kind: "stub_wrong_type",
                           message: "hardened launcher /usr/local/bin/npm is a symbolic link; expected a regular file",
                           remediation: "Remove /usr/local/bin/npm, then run `av harden node`.",
                           stubPath: "/usr/local/bin/npm", targetPath: "/opt/homebrew/bin/npm")]),
    ]
    static let demoSecrets = [VaultSecret(name: "GITHUB_TOKEN"), VaultSecret(name: "PAGERDUTY_API_KEY"),
                              VaultSecret(name: "STAGING_DB_PASSWORD")]

    /// The Automic Vault tab with `tools`, after the page's own read (which
    /// a suite refuses) has landed, so the fixture is what shows.
    @discardableResult
    static func showVault(_ shell: MainSplitShellController, tools: [VaultTool]) -> VaultController {
        shell.workspace.navigator.show(.vault)
        let vault = shell.workspace.vault
        shell.setInspectorShown(false)
        let deadline = Date().addingTimeInterval(10)
        while vault.debugIsReading && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        vault.debugRender(secrets: demoSecrets, tools: tools)
        settle(shell)
        return vault
    }

    private static func checkVaultSplit(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let vault = showVault(shell, tools: demoTools)
        guard let split = vault.debugHeroSplit else {
            fail("S-1: Automic Vault has no split card", &ok)
            return
        }
        check(split.panel.debugHeadline == "node needs attention.", "S-1: the card says \"\(split.panel.debugHeadline)\"", &ok)
        check(split.panel.debugRing?.debugLabel == "1/2", "S-1: the ring reads \(split.panel.debugRing?.debugLabel ?? "nothing")", &ok)
        check(split.debugRows.map(\.tool.name) == ["claude", "node"], "S-1: the rows are \(split.debugRows.map(\.tool.name))", &ok)
        check(split.debugRows.first?.fixButton == nil && split.debugRows.last?.fixButton != nil,
              "S-1: View Fix is not on node's row alone", &ok)
        check(split.debugFootButtons.map(\.title) == ["View Fix\u{2026}"], "S-1: the gradient's pills are \(split.debugFootButtons.map(\.title))", &ok)
        check(!split.isStacked, "S-1: a 1512pt page stacks the card", &ok)
        let amber = HelmHeroColumn.palette(for: VaultHeroWords.make(secrets: demoSecrets, tools: demoTools,
                                                                   hasLoadedOnce: true, notInstalled: false,
                                                                   refusedHere: false).heroTone(in: daylight), in: daylight)
        check(split.panel.debugPalette == amber, "S-1: a launcher needing attention does not tone the card amber", &ok)
        // All hardened: the accent, and no View Fix.
        let clear = [VaultTool(name: "claude", commands: ["claude"], status: .hardened),
                     VaultTool(name: "node", commands: ["npm"], status: .hardened)]
        showVault(shell, tools: clear)
        check(split.panel.debugHeadline == "Every launcher is hardened.", "S-1: all clear says \"\(split.panel.debugHeadline)\"", &ok)
        check(split.debugFootButtons.isEmpty, "S-1: all clear still offers View Fix", &ok)
        let accent = HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: daylight)
        check(split.panel.debugPalette == accent, "S-1: all clear is not the accent", &ok)
        // A narrow page puts the gradient across the top.
        resize(window, width: 1100, shell)
        check(split.isStacked == (split.bounds.width < VaultHeroSplitView.stackedBelow),
              "S-1: a \(split.bounds.width)pt card is \(split.isStacked ? "" : "not ")stacked", &ok)
        resize(window, width: 1512, shell)
    }

    // MARK: Renders

    private static func writeRenders(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        guard let dir = ProcessInfo.processInfo.environment["FM_TASKS_SECRETS_RENDER_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Home: the briefing hero, then the cards - the band between them is
        // gone - with the Hosts hero card in the arrangement.
        let savedBriefing = AppSettings.shared.morningBriefingRecord
        let savedLayout = AppSettings.shared.homeCardLayout
        defer {
            AppSettings.shared.morningBriefingRecord = savedBriefing
            AppSettings.shared.homeCardLayout = savedLayout
        }
        ReviewTourLab.seedDemoBriefing()
        ReviewTourLab.seedDemoHosts(shell.workspace)
        if let bastion = shell.workspace.hostStore.hosts.first(where: { $0.label == "bastion-stg" }) {
            shell.workspace.hostStore.recordConnection(id: bastion.id)
        }
        let homeLayout = HomeCardLayout(shown: [.briefing, .claudeStatus, .fleet, .hosts, .health, .mergeQueue],
                                        sizes: [.claudeStatus: .large, .fleet: .large, .hosts: .large])
        for theme in [daylight, dusk] {
            ThemeManager.shared.setTheme(theme)
            for width in [1512, 1100] as [CGFloat] {
                resize(window, width: width, shell)
                shell.workspace.navigator.show(.homeCanvas)
                let canvas = shell.debugHomeCanvas
                AppSettings.shared.homeCardLayout = homeLayout
                canvas.cardLayout = homeLayout
                ReviewTourLab.seedDemoHome(canvas)
                canvas.debugRenderNow()
                settle(shell)
                write(canvas.view, to: folder.appendingPathComponent("home-\(theme.id)-\(Int(width)).png"))
            }
        }
        for theme in [daylight, dusk] {
            ThemeManager.shared.setTheme(theme)
            for width in [1512, 1100] as [CGFloat] {
                resize(window, width: width, shell)
                for tab in ["Board", "List"] {
                    let shift = showTasks(shell, tab: tab)
                    write(shift.view, to: folder.appendingPathComponent("tasks-\(tab.lowercased())-\(theme.id)-\(Int(width)).png"))
                }
                let secrets = showSecrets(shell)
                write(secrets.view, to: folder.appendingPathComponent("secrets-\(theme.id)-\(Int(width)).png"))
                let vault = showVault(shell, tools: demoTools)
                write(vault.view, to: folder.appendingPathComponent("automic-attention-\(theme.id)-\(Int(width)).png"))
                showVault(shell, tools: demoTools.map { VaultTool(name: $0.name, commands: $0.commands, status: .hardened) })
                write(vault.view, to: folder.appendingPathComponent("automic-clear-\(theme.id)-\(Int(width)).png"))
            }
        }
        ThemeManager.shared.setTheme(daylight)
        resize(window, width: 1512, shell)
        print("TasksSecretsHeroViewSelfTest: renders written to \(dir)")
    }

    static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

#endif
