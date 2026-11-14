// Grand Line - native macOS app.
//
// The Tasks calendar's pure half: the vendored Schedule-X bundle, and every
// rule the native side applies before anything reaches the page.
//
// What it locks down, each as something a later edit could quietly break:
//
//   1. **The bundle is the one the build script made**, it is findable, and
//      `build_native_app.sh` copies it under the name the app looks for.
//   2. **It is offline**, read from the page's own CSP rather than trusted.
//   3. **It is free.** No `@sx-premium` package in the manifest or the
//      lockfile, every bundled package on the licence allow-list, and the
//      licence notices shipping inside the bundle.
//   4. **What crosses the bridge.** A projection or a finished task is never
//      movable, a timed task is a half-hour block that never crosses midnight,
//      and Schedule-X gets a locale shape it does not throw on.
//   5. **The palette is the app theme's**, every role present, every text
//      role clearing the contrast floor as the hex the page actually receives,
//      on every app theme.
//   6. **What a drop does to a task**, including the refusals.
//   7. **Every open task has a place** (the Unscheduled tray): undated tasks
//      grouped by project, overdue work pinned, the first-run empty state,
//      the caption that counts all three, and a past month's finished tasks
//      read from that month's `completed/` file only.
//
// The page itself - rendering, a real drag, the theme reaching the DOM - is
// `ShiftCalendarViewSelfTest`, which needs a window and so runs in the other
// lane.
//
// `FM_RUN_SHIFT_CALENDAR_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ShiftCalendarSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkAssets(check)
        checkOfflineByConstruction(check)
        checkFreeAndLicensed(check)
        checkBundleCarriesTheBridge(check)
        checkEventPayload(check)
        checkLocaleAndWeekStart(check)
        checkPalette(check)
        checkReschedule(check)
        checkFollowUps(check)
        checkCaption(check)
        checkScales(check)
        checkProjectColouring(check)
        checkTrayModel(check)
        checkTrayPayload(check)
        checkCompletedMonths(check)

        print(ok ? "ShiftCalendarSelfTest: OK" : "ShiftCalendarSelfTest: FAILURES")
        return ok
    }

    // MARK: 1. The bundle

    private static func checkAssets(_ check: (Bool, String) -> Void) {
        guard let dir = ShiftCalendarAssets.webDirectory() else {
            check(false, "no Schedule-X bundle found - run native/Scripts/build-schedule-x-web.sh")
            return
        }
        let fm = FileManager.default
        for file in ["index.html", "task-calendar.js", "task-calendar.css", "THIRD-PARTY-LICENSES.txt"] {
            check(fm.isReadableFile(atPath: dir.appendingPathComponent(file).path), "the bundle is missing \(file)")
        }
        // Every shipped file matches the digest its build recorded, and
        // nothing ships unrecorded - the same guard the Monaco bundle has.
        for problem in VendoredBundleDigests.problems(in: dir) {
            check(false, "Schedule-X bundle: \(problem)")
        }

        // The override wins over the source-tree walk-up, and is restored.
        let prior = ProcessInfo.processInfo.environment["FM_TASK_CALENDAR_WEB_DIR"]
        let scratch = fm.temporaryDirectory.appendingPathComponent("task-calendar-assets-\(UUID().uuidString)",
                                                                   isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: scratch)
            if let prior { setenv("FM_TASK_CALENDAR_WEB_DIR", prior, 1) } else { unsetenv("FM_TASK_CALENDAR_WEB_DIR") }
        }
        try? "<html></html>".write(to: scratch.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        setenv("FM_TASK_CALENDAR_WEB_DIR", scratch.path, 1)
        let overridden = ShiftCalendarAssets.webDirectory()?.standardizedFileURL
        unsetenv("FM_TASK_CALENDAR_WEB_DIR")
        check(overridden == scratch.standardizedFileURL,
              "FM_TASK_CALENDAR_WEB_DIR should win over the source-tree walk-up, got \(overridden?.path ?? "nil")")

        // The app bundle's copy has to land where `webDirectory()` looks first.
        guard let script = sourceFile("../../build_native_app.sh") else {
            check(false, "could not read native/build_native_app.sh")
            return
        }
        check(script.contains("cp -R \"Vendor/ScheduleX/web\" \"$APP_DIR/Contents/Resources/\(ShiftCalendarAssets.bundleDirectoryName)\""),
              "build_native_app.sh must copy Vendor/ScheduleX/web to Resources/\(ShiftCalendarAssets.bundleDirectoryName)")
    }

    // MARK: 2. Offline

    private static func checkOfflineByConstruction(_ check: (Bool, String) -> Void) {
        guard let dir = ShiftCalendarAssets.webDirectory(),
              let html = try? String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8),
              let css = try? String(contentsOf: dir.appendingPathComponent("task-calendar.css"), encoding: .utf8)
        else {
            check(false, "could not read the bundle's index.html and task-calendar.css")
            return
        }
        guard let policy = cspPolicy(in: html) else {
            check(false, "index.html has no Content-Security-Policy meta tag")
            return
        }
        check(policy.contains("default-src 'self'"), "the CSP should default to 'self'")
        check(policy.contains("connect-src 'none'"),
              "the CSP must refuse every connection - the calendar has nothing to fetch")
        check(policy.contains("script-src 'self';"), "the page may run only its own script, got: \(policy)")
        check(policy.contains("object-src 'none'") && policy.contains("frame-src 'none'"),
              "the CSP should forbid plugins and frames")
        check(!policy.contains("http") && !policy.contains("*"), "the CSP names a remote origin: \(policy)")

        let markup = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        check(!markup.contains("http://") && !markup.contains("https://"),
              "index.html references an absolute URL - the page shell must be entirely local")
        check(css.range(of: "url\\((?!data:)", options: .regularExpression) == nil,
              "the stylesheet has a url() that is not a data: URI - that is a fetch")
        check(!css.contains("@import"), "the stylesheet imports another stylesheet")
    }

    private static func cspPolicy(in html: String) -> String? {
        guard let tag = html.range(of: "http-equiv=\"Content-Security-Policy\"") else { return nil }
        let rest = html[tag.upperBound...]
        guard let key = rest.range(of: "content=\"") else { return nil }
        let after = rest[key.upperBound...]
        guard let end = after.range(of: "\"") else { return nil }
        return String(after[..<end.lowerBound])
    }

    // MARK: 3. Free and licensed

    private static func checkFreeAndLicensed(_ check: (Bool, String) -> Void) {
        guard let manifest = sourceFile("../../Vendor/ScheduleX/src/package.json"),
              let lockText = sourceFile("../../Vendor/ScheduleX/src/package-lock.json"),
              let lockData = lockText.data(using: .utf8),
              let lock = try? JSONSerialization.jsonObject(with: lockData) as? [String: Any],
              let packages = lock["packages"] as? [String: [String: Any]] else {
            check(false, "could not read Vendor/ScheduleX/src/package.json and its lockfile")
            return
        }
        check(!manifest.contains("@sx-premium") && !lockText.contains("@sx-premium"),
              "a paid @sx-premium package is in the Schedule-X manifest or lockfile")

        let allowed: Set<String> = ["MIT", "ISC", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "0BSD"]
        let shipped = packages.filter { !$0.key.isEmpty && ($0.value["dev"] as? Bool) != true }
        check(shipped.count >= 8, "the lockfile lists only \(shipped.count) runtime packages - is it the right file?")
        for (path, info) in shipped.sorted(by: { $0.key < $1.key }) {
            let license = info["license"] as? String ?? "none"
            check(allowed.contains(license), "\(path) is licensed \(license), which is not on the allow-list")
        }
        // The core is v4 and the drag plugin is the last MIT release.
        check((packages["node_modules/@schedule-x/drag-and-drop"]?["version"] as? String) == "3.7.3",
              "@schedule-x/drag-and-drop must stay at 3.7.3, its last MIT release - see Vendor/ScheduleX/README.md")

        guard let dir = ShiftCalendarAssets.webDirectory(),
              let notices = try? String(contentsOf: dir.appendingPathComponent("THIRD-PARTY-LICENSES.txt"),
                                        encoding: .utf8) else {
            check(false, "the bundle carries no THIRD-PARTY-LICENSES.txt")
            return
        }
        for path in shipped.keys {
            let name = String(path.dropFirst("node_modules/".count))
            let version = shipped[path]?["version"] as? String ?? ""
            check(notices.contains("\(name) \(version) ("), "THIRD-PARTY-LICENSES.txt has no notice for \(name) \(version)")
        }
        check(notices.contains("Permission is hereby granted"), "the notices carry no licence text")
    }

    // MARK: Bridge, in the committed bundle

    /// The app loads `web/`, never `src/`, so a source edit without a rebuild
    /// would leave the native side talking to a page that has never heard of
    /// the call.
    private static func checkBundleCarriesTheBridge(_ check: (Bool, String) -> Void) {
        guard let dir = ShiftCalendarAssets.webDirectory(),
              let js = try? String(contentsOf: dir.appendingPathComponent("task-calendar.js"), encoding: .utf8) else {
            check(false, "could not read the bundle's task-calendar.js")
            return
        }
        check(js.contains("GrandLineTaskCalendar"), "the bundle does not define window.GrandLineTaskCalendar")
        check(js.contains(ShiftCalendarWebView.messageHandlerName),
              "the bundle never posts to \(ShiftCalendarWebView.messageHandlerName)")
        for entry in ["configure", "setEvents", "setTray", "setTheme", "setView", "showDate", "suspend", "resume",
                      "state"] {
            check(js.contains("\(entry):"), "the committed bundle has no `\(entry)` bridge entry - rebuild it")
        }
        for message in ["ready", "error", "range", "open", "add", "move", "schedule", "tray", "newTask", "openList"] {
            check(js.contains("type:\"\(message)\""), "the committed bundle never posts `\(message)`")
        }
        // The captain's card: its header, weekday row and legend are this
        // bundle's, not Schedule-X's, and Agenda is the open-source list view.
        if let html = try? String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8) {
            for id in ["gl-prev", "gl-next", "gl-title", "gl-today", "gl-views", "gl-weekdays", "gl-legend",
                       "gl-tray", "gl-tray-list", "gl-tray-toggle", "gl-empty", "gl-empty-new", "gl-empty-list"] {
                check(html.contains("id=\"\(id)\""), "the page shell has no #\(id)")
            }
            for scale in ShiftCalendarScale.allCases {
                check(html.contains("data-view=\"\(scale.rawValue)\""), "the card has no \(scale.title) pill")
            }
        } else {
            check(false, "could not read the bundle's index.html")
        }
        check(js.contains("\"list\""), "the bundle does not register Schedule-X's list view (Agenda)")
        if let css = try? String(contentsOf: dir.appendingPathComponent("task-calendar.css"), encoding: .utf8) {
            // The raised cells are drawn inside each day, never as a margin
            // between days: the drag plugin finds the drop day with
            // `closest('.sx__month-grid-day')`, and a gap would be nowhere.
            check(css.contains(".sx__month-grid-day:before"), "the month grid's raised cell is not drawn inside the day")
            check(css.contains(".sx__calendar-header{display:none}"), "Schedule-X's own header still shows")
            for variable in ShiftCalendarPalette.requiredVariables where variable.hasPrefix("--gl-") {
                guard variable != "--gl-accent-ink", variable != "--gl-now-line" else { continue }
                check(css.contains("var(\(variable))"), "the stylesheet never reads \(variable)")
            }
        } else {
            check(false, "could not read the bundle's task-calendar.css")
        }
        // The 4.0.1 rename adapter: without it the core never starts a drag.
        // The core itself *calls* these hooks by name, so a bare name search
        // would pass with the adapter gone; the adapter is the one place they
        // are assigned.
        for hook in ["startMonthGridDrag", "startDateGridDrag", "startTimeGridDrag"] {
            check(js.contains(".\(hook)="), "the bundle does not adapt the drag plugin's `\(hook)` hook")
        }
    }

    // MARK: 4. What crosses the bridge

    private static func checkEventPayload(_ check: (Bool, String) -> Void) {
        func entry(day: String = "2026-10-27", time: String? = nil, projected: Bool = false,
                   completed: Bool = false, cancelled: Bool = false, project: String? = nil) -> ShiftCalendarEntry {
            ShiftCalendarEntry(taskID: "t1", title: "Renew \"wildcard\" TLS", day: day, time: time,
                               projectID: project, priority: .normal, isProjected: projected,
                               isCompleted: completed, isCancelled: cancelled)
        }

        let allDay = ShiftCalendarPayload.event(for: entry())
        check(allDay["start"] as? String == "2026-10-27" && allDay["end"] as? String == "2026-10-27",
              "an all-day task is a one-day date event, got \(allDay)")
        check(allDay["id"] as? String == "t1" && allDay["taskID"] as? String == "t1",
              "a real task's event id is the task id")
        check(allDay["movable"] as? Bool == true, "an open task is movable")
        check(allDay["title"] as? String == "Renew \"wildcard\" TLS", "the title crosses unaltered")

        let timed = ShiftCalendarPayload.event(for: entry(time: "09:30"))
        check(timed["start"] as? String == "2026-10-27 09:30" && timed["end"] as? String == "2026-10-27 10:00",
              "a timed task is a half-hour block, got \(timed["start"] ?? "-") to \(timed["end"] ?? "-")")
        let late = ShiftCalendarPayload.event(for: entry(time: "23:45"))
        check(late["end"] as? String == "2026-10-27 23:59",
              "a block near midnight must end the same day, got \(late["end"] ?? "-")")

        let projection = ShiftCalendarPayload.event(for: entry(day: "2026-10-28", projected: true))
        check(projection["id"] as? String == "t1@2026-10-28",
              "a projection's id carries its day, so many projections of one rule stay distinct")
        check(projection["taskID"] as? String == "t1", "a projection still opens its real task")
        check(projection["movable"] as? Bool == false, "a projection must never be movable")
        check(ShiftCalendarPayload.event(for: entry(completed: true))["movable"] as? Bool == false,
              "a completed task must never be movable")
        check(ShiftCalendarPayload.event(for: entry(cancelled: true))["movable"] as? Bool == false,
              "a cancelled task must never be movable")

        // A task's colour is its priority's category, a follow-up's is its
        // own, and every category has colours in the palette and a line in
        // the legend.
        let palette = ShiftCalendarPalette.calendars(for: HelmTheme.dusk)
        let expected: [(ShiftPriority, ShiftCalendarEntry.Kind, ShiftCalendarCategory)] = [
            (.high, .task, .high), (.normal, .task, .normal), (.low, .task, .low),
            (.high, .followUp, .followUp), (.low, .followUp, .followUp),
        ]
        for (priority, kind, category) in expected {
            var item = entry()
            item.priority = priority
            item.kind = kind
            let id = ShiftCalendarPayload.event(for: item)["calendarId"] as? String ?? ""
            check(id == category.rawValue, "a \(priority) \(kind) should be drawn as \(category), got \(id)")
            check(palette[id] != nil, "an event's calendar \(id) has no colours in the palette")
        }
        check(Set(palette.keys) == Set(ShiftCalendarCategory.allCases.map(\.rawValue)),
              "the palette and the categories disagree about the calendar ids")
        let legend = ShiftCalendarPalette.legend(for: HelmTheme.dusk)
        check(legend.map { $0["id"] ?? "" } == ShiftCalendarCategory.allCases.map(\.rawValue),
              "the legend names every category once, in order")
        check(legend.map { $0["label"] ?? "" } == ["High priority", "Normal priority", "Low priority", "Follow-up"],
              "the legend's words are \(legend.map { $0["label"] ?? "" })")
        // The discriminating half: four categories really are four colours.
        let edges = Set(ShiftCalendarCategory.allCases.map {
            ShiftCalendarPalette.colours(for: $0, theme: HelmTheme.dusk)["main"] ?? "" })
        check(edges.count == 4, "the four categories should be four colours on Dusk, got \(edges)")

        var followUp = entry()
        followUp.kind = .followUp
        let followUpEvent = ShiftCalendarPayload.event(for: followUp)
        check(followUpEvent["id"] as? String == "followup:t1" && followUpEvent["kind"] as? String == "followUp",
              "a follow-up's event id is prefixed and its kind crosses, got \(followUpEvent)")
        check(allDay["allDay"] as? Bool == true
              && ShiftCalendarPayload.event(for: entry(time: "09:30"))["allDay"] as? Bool == false,
              "the page is told which records have no time (the agenda hides theirs)")

        // The model's own movability, which is what the payload reads.
        var task = ShiftTask.fresh()
        task.title = "Daily"
        task.dueDate = "2026-10-27"
        task.recurrence = ShiftRecurrence(frequency: .daily)
        let start = ShiftDateFormatting.date(from: "2026-10-26") ?? Date()
        let end = ShiftDateFormatting.date(from: "2026-10-30") ?? Date()
        let entries = ShiftCalendarModel.entries(tasks: [task], from: start, through: end)
        check(entries.filter { !$0.isProjected }.count == 1 && entries.filter(\.isProjected).count >= 2,
              "a daily rule should give one real entry and its projections, got \(entries.map(\.day))")
        check(entries.filter(\.isMovable).map(\.day) == ["2026-10-27"],
              "only the real instance of a repeating task is movable")
    }

    private static func checkLocaleAndWeekStart(_ check: (Bool, String) -> Void) {
        let cases: [(String, String)] = [("en_US", "en-US"), ("de_DE", "de-DE"), ("en_IN", "en-IN"),
                                         ("en", "en-US"), ("zh-Hans_CN", "zh-CN"), ("fil_PH", "en-US")]
        for (identifier, expected) in cases {
            let got = ShiftCalendarPayload.scheduleXLocale(Locale(identifier: identifier))
            check(got == expected, "locale \(identifier) should reach Schedule-X as \(expected), got \(got)")
            check(got.range(of: "^[a-z]{2}-[A-Z]{2}$", options: .regularExpression) != nil,
                  "\(got) is not a shape Schedule-X accepts - it throws on anything but ll-RR")
        }
        var sundayFirst = Calendar(identifier: .gregorian)
        sundayFirst.firstWeekday = 1
        var mondayFirst = Calendar(identifier: .gregorian)
        mondayFirst.firstWeekday = 2
        var saturdayFirst = Calendar(identifier: .gregorian)
        saturdayFirst.firstWeekday = 7
        check(ShiftCalendarPayload.scheduleXFirstDayOfWeek(sundayFirst) == 7, "Sunday is Schedule-X's 7")
        check(ShiftCalendarPayload.scheduleXFirstDayOfWeek(mondayFirst) == 1, "Monday is Schedule-X's 1")
        check(ShiftCalendarPayload.scheduleXFirstDayOfWeek(saturdayFirst) == 6, "Saturday is Schedule-X's 6")

        let config = ShiftCalendarPayload.configuration(theme: HelmTheme.dusk, scale: .week,
                                                        timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        check(config["timeZone"] as? String == "Asia/Kolkata", "the page is told the captain's time zone")
        check(config["view"] as? String == "week", "the page opens on the requested view")
        check(config["dark"] as? Bool == true, "Dusk is a dark theme")
    }

    // MARK: 5. The palette

    private static func checkPalette(_ check: (Bool, String) -> Void) {
        check(HelmTheme.appThemes.count >= 10, "expected the app themes, got \(HelmTheme.appThemes.count)")
        // Schedule-X's own Material defaults. None of them may survive.
        let defaults: Set<String> = ["#6750A4", "#D0BCFF", "#EADDFF", "#4F378B", "#FEF7FF", "#141218"]
        // Each text role, and the surface it is read on.
        let pairs: [(String, String)] = [
            ("--sx-color-on-surface", "--sx-color-surface"),
            ("--sx-color-on-background", "--sx-color-background"),
            ("--sx-internal-color-text", "--sx-color-background"),
            ("--sx-color-on-primary", "--sx-color-primary"),
            ("--sx-color-on-primary-container", "--sx-color-primary-container"),
            ("--sx-color-on-secondary-container", "--sx-color-secondary-container"),
            ("--sx-color-neutral", "--sx-color-background"),
            ("--gl-accent-ink", "--sx-color-background"),
            // The card and its cells.
            ("--gl-ink", "--gl-card"),
            ("--gl-ink", "--gl-cell"),
            ("--gl-muted", "--gl-cell"),
        ]
        for theme in HelmTheme.appThemes {
            let vars = ShiftCalendarPalette.variables(for: theme)
            for key in ShiftCalendarPalette.requiredVariables {
                let value = vars[key] ?? ""
                check(value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
                      "\(theme.id): \(key) should be an opaque #rrggbb, got \"\(value)\"")
                check(!defaults.contains(value.uppercased()),
                      "\(theme.id): \(key) is still Schedule-X's own default \(value)")
            }
            for (text, surface) in pairs {
                guard let a = vars[text], let b = vars[surface] else { continue }
                let ratio = HelmContrast.ratio(HelmTheme.nsColor(String(a.dropFirst())),
                                               HelmTheme.nsColor(String(b.dropFirst())))
                check(ratio >= 4.5, "\(theme.id): \(text) on \(surface) measures \(String(format: "%.2f", ratio)):1")
            }
            check(vars["--sx-color-background"]?.uppercased() == "#" + theme.chromeBackgroundHex.uppercased(),
                  "\(theme.id): the calendar's ground is the theme's card surface")
            check(vars["--gl-ground"]?.uppercased() == "#" + theme.backgroundHex.uppercased(),
                  "\(theme.id): the page around the card is the native page's own ground")
            if let cell = vars["--gl-cell"], let card = vars["--gl-card"], let dim = vars["--gl-cell-dim"],
               let faint = vars["--gl-faint"] {
                let nsCell = HelmTheme.nsColor(String(cell.dropFirst()))
                let nsCard = HelmTheme.nsColor(String(card.dropFirst()))
                let nsDim = HelmTheme.nsColor(String(dim.dropFirst()))
                // A day cell is visibly its own surface on its card: the 8-bit
                // quantisation leaves ~0.01 under the 1.08 floor at most.
                let separation = HelmContrast.ratio(nsCell, nsCard)
                check(separation >= ShiftCalendarPalette.cellSeparation - 0.012,
                      "\(theme.id): a day cell measures \(String(format: "%.3f", separation)):1 on its card")
                check(dim != cell, "\(theme.id): a day outside the month is not dimmed")
                let faintRatio = HelmContrast.ratio(HelmTheme.nsColor(String(faint.dropFirst())), nsDim)
                check(faintRatio >= ShiftCalendarPalette.faintTextFloor,
                      "\(theme.id): an outside day's number measures \(String(format: "%.2f", faintRatio)):1")
                if let muted = vars["--gl-muted"] {
                    let mutedRatio = HelmContrast.ratio(HelmTheme.nsColor(String(muted.dropFirst())), nsCell)
                    check(faintRatio < mutedRatio - 0.5,
                          "\(theme.id): an outside day's number (\(String(format: "%.2f", faintRatio)):1) should read "
                          + "fainter than the month's own (\(String(format: "%.2f", mutedRatio)):1)")
                }
                let dimSeparation = HelmContrast.ratio(nsDim, nsCard)
                check(dimSeparation < separation,
                      "\(theme.id): a dimmed day should sit flatter on the card than a day of the month")
            }
            check((ShiftCalendarPalette.themePayload(for: theme)["dark"] as? Bool) == (theme.mode == .dark),
                  "\(theme.id): the page's register must follow the theme's mode")

            // Coloured by project too, so every project hue and the No
            // project chip are swept on every theme as well.
            let sweep = ShiftCalendarPalette.calendars(for: theme, colouring: .project, projects: Self.colouringProjects)
            for (id, value) in sweep {
                guard let calendar = value as? [String: Any],
                      let colours = calendar["lightColors"] as? [String: String],
                      let fill = colours["container"], let ink = colours["onContainer"] else {
                    check(false, "\(theme.id): calendar \(id) is malformed")
                    continue
                }
                let ratio = HelmContrast.ratio(HelmTheme.nsColor(String(ink.dropFirst())),
                                               HelmTheme.nsColor(String(fill.dropFirst())))
                check(ratio >= 4.5, "\(theme.id): \(id)'s event text measures \(String(format: "%.2f", ratio)):1")
                check(calendar["colorName"] as? String == id, "\(theme.id): \(id)'s colorName must match its id")
            }
        }
        // The discriminating half: two registers really produce two palettes,
        // so a palette that ignored the theme would fail rather than pass.
        let light = ShiftCalendarPalette.variables(for: HelmTheme.daylight)
        let dark = ShiftCalendarPalette.variables(for: HelmTheme.dusk)
        check(light["--sx-color-background"] != dark["--sx-color-background"]
              && light["--sx-color-on-surface"] != dark["--sx-color-on-surface"],
              "Daylight and Dusk should not resolve to the same calendar palette")
    }

    // MARK: 6. Rescheduling

    private static func checkReschedule(_ check: (Bool, String) -> Void) {
        var allDay = ShiftTask.fresh()
        allDay.title = "All day"
        allDay.dueDate = "2026-10-27"
        var timed = allDay
        timed.dueTime = "09:30"

        if case .moved(let t) = ShiftCalendarReschedule.apply(task: allDay, day: "2026-10-30", time: nil) {
            check(t.dueDate == "2026-10-30" && t.dueTime == nil, "an all-day drop moves the day only")
        } else { check(false, "an all-day task dropped on a new day should move") }

        if case .moved(let t) = ShiftCalendarReschedule.apply(task: allDay, day: "2026-10-30", time: "14:00") {
            check(t.dueTime == nil, "an all-day task must not gain a time from a drop, got \(t.dueTime ?? "-")")
        } else { check(false, "an all-day task dropped with a time should still move its day") }

        if case .moved(let t) = ShiftCalendarReschedule.apply(task: timed, day: "2026-10-29", time: "10:30") {
            check(t.dueDate == "2026-10-29" && t.dueTime == "10:30", "a timed drop moves the day and the time")
        } else { check(false, "a timed task dropped on a new slot should move") }

        if case .moved(let t) = ShiftCalendarReschedule.apply(task: timed, day: "2026-10-29", time: nil) {
            check(t.dueTime == "09:30", "a timed task dropped with no time keeps its own, got \(t.dueTime ?? "nil")")
        } else { check(false, "a timed task dropped on a new day should move") }

        check(ShiftCalendarReschedule.apply(task: timed, day: "2026-10-27", time: "09:30") == .unchanged,
              "a drop where the task already is writes nothing")

        var done = timed
        done.status = .completed
        if case .refused = ShiftCalendarReschedule.apply(task: done, day: "2026-10-29", time: nil) {} else {
            check(false, "a completed task must be refused")
        }
        if case .refused = ShiftCalendarReschedule.apply(task: timed, day: "27/10/2026", time: nil) {} else {
            check(false, "a malformed day must be refused")
        }
        if case .refused = ShiftCalendarReschedule.apply(task: timed, day: "2026-10-29", time: "25:00") {} else {
            check(false, "a malformed time must be refused")
        }
    }

    // MARK: 7. Follow-ups

    private static func checkFollowUps(_ check: (Bool, String) -> Void) {
        var pending = ShiftFollowUp.fresh()
        pending.title = "Ping the vendor"
        pending.followUpAt = "2026-10-28"
        var done = pending
        done.id = "done"
        done.status = .done
        var undated = pending
        undated.id = "undated"
        undated.followUpAt = nil
        var outside = pending
        outside.id = "outside"
        outside.followUpAt = "2026-12-01"
        let start = ShiftDateFormatting.date(from: "2026-10-26") ?? Date()
        let end = ShiftDateFormatting.date(from: "2026-11-01") ?? Date()
        let entries = ShiftCalendarModel.entries(followUps: [pending, done, undated, outside], from: start, through: end)
        check(entries.map(\.taskID) == [pending.id] && entries.first?.kind == .followUp && entries.first?.isMovable == true,
              "only a pending, dated follow-up in range is drawn, got \(entries.map(\.taskID))")

        var task = ShiftTask.fresh()
        task.title = "A task the same day"
        task.dueDate = "2026-10-28"
        task.dueTime = "08:00"
        let both = ShiftCalendarModel.entries(tasks: [task], followUps: [pending], from: start, through: end)
        check(both.map(\.kind) == [.followUp, .task],
              "an all-day follow-up sorts above a timed task on its day, got \(both.map(\.kind))")

        if case .moved(let moved) = ShiftCalendarReschedule.apply(followUp: pending, day: "2026-10-30", time: "11:00") {
            check(moved.followUpAt == "2026-10-30" && moved.followUpTime == nil,
                  "a follow-up with no time moves its day only")
        } else { check(false, "a pending follow-up dropped on a new day should move") }
        check(ShiftCalendarReschedule.apply(followUp: pending, day: "2026-10-28", time: nil) == .unchanged,
              "a follow-up dropped where it already is writes nothing")
        if case .refused = ShiftCalendarReschedule.apply(followUp: done, day: "2026-10-30", time: nil) {} else {
            check(false, "a finished follow-up must be refused")
        }
    }

    private static func checkCaption(_ check: (Bool, String) -> Void) {
        check(ShiftCalendarView.subtitle(total: 0, projected: 0) == "Nothing scheduled this month.",
              "an empty period with no open work is stated, never left blank (GL-14)")
        let mixed = ShiftCalendarView.subtitle(total: 5, projected: 3)
        check(mixed == "5 tasks this month, 3 of them repeat dates not yet created",
              "projections are counted apart from real tasks, got \"\(mixed)\"")
        let withFollowUps = ShiftCalendarView.subtitle(total: 2, projected: 0, followUps: 1, period: "this week")
        check(withFollowUps == "2 tasks and 1 follow-up this week",
              "follow-ups are counted beside tasks, in the period's own words, got \"\(withFollowUps)\"")
        check(ShiftCalendarView.subtitle(total: 0, projected: 0, followUps: 2) == "2 follow-ups this month",
              "a period with only follow-ups is not stated as empty")

        // The work the grid cannot show is counted too.
        var tray = ShiftCalendarTray()
        tray.groups = [.init(projectID: nil, title: ShiftCalendarTray.noProjectTitle, items: [
            ShiftCalendarTrayItem(id: "u1", kind: .task, title: "A", priority: .normal, projectID: nil),
            ShiftCalendarTrayItem(id: "u2", kind: .task, title: "B", priority: .normal, projectID: nil),
        ])]
        tray.overdue = [ShiftCalendarTrayItem(id: "o1", kind: .task, title: "C", priority: .high, projectID: nil,
                                              dueDay: "2026-11-10", daysOverdue: 3)]
        tray.openTasks = 3
        tray.datedRecords = 1
        let full = ShiftCalendarView.subtitle(total: 24, projected: 9, tray: tray)
        check(full == "24 tasks this month, 9 of them repeat dates not yet created · 2 unscheduled · 1 overdue",
              "the caption counts dated, unscheduled and overdue work, got \"\(full)\"")
        let quietWeek = ShiftCalendarView.subtitle(total: 0, projected: 0, tray: tray, period: "this week")
        check(quietWeek == "Nothing dated this week · 2 unscheduled · 1 overdue",
              "a period with nothing dated but open work elsewhere must not read as empty, got \"\(quietWeek)\"")

        // The captain's report: 13 open tasks, none dated.
        var undated = ShiftCalendarTray()
        undated.groups = [.init(projectID: nil, title: ShiftCalendarTray.noProjectTitle, items: (0..<13).map {
            ShiftCalendarTrayItem(id: "t\($0)", kind: .task, title: "T\($0)", priority: .normal, projectID: nil)
        })]
        undated.openTasks = 13
        let first = ShiftCalendarView.subtitle(total: 0, projected: 0, tray: undated)
        check(first == "13 open tasks · none on the calendar yet · 13 unscheduled",
              "an undated-only store states its open tasks, not \"Nothing scheduled\", got \"\(first)\"")
        check(!first.contains("Nothing scheduled"), "13 open tasks must never read as nothing scheduled")

        let today = "2026-11-13"
        check(ShiftCalendarModel.periodPhrase(scale: .month, visibleStart: "2026-10-26", today: today) == "this month"
              && ShiftCalendarModel.periodPhrase(scale: .agenda, visibleStart: nil, today: today) == "this month"
              && ShiftCalendarModel.periodPhrase(scale: .week, visibleStart: "2026-11-09", today: today) == "this week"
              && ShiftCalendarModel.periodPhrase(scale: .day, visibleStart: today, today: today) == "today"
              && ShiftCalendarModel.periodPhrase(scale: .day, visibleStart: "2026-11-20", today: today) == "on this day",
              "each view names its period in its own words")
    }

    // MARK: 9. The Unscheduled tray

    private static func checkTrayModel(_ check: (Bool, String) -> Void) {
        func task(_ id: String, _ title: String, due: String? = nil, project: String? = nil,
                  priority: ShiftPriority = .normal, status: ShiftTaskStatus = .todo) -> ShiftTask {
            var t = ShiftTask.fresh()
            t.id = id
            t.title = title
            t.dueDate = due
            t.projectID = project
            t.priority = priority
            t.status = status
            return t
        }
        var infra = ShiftProject.fresh()
        infra.id = "p-infra"
        infra.name = "Infra"
        var release = ShiftProject.fresh()
        release.id = "p-release"
        release.name = "Release"
        let tasks = [
            task("a", "Shortlist candidates", project: "p-gone"),
            task("b", "Try Renovate", priority: .low),
            task("c", "Audit IAM keys", project: "p-infra", priority: .high),
            task("d", "Clean up Terraform", project: "p-infra"),
            task("e", "Grafana dashboards", project: "p-release"),
            task("f", "Postmortem template"),
            task("g", "Renew TLS", due: "2026-11-11", project: "p-infra", priority: .high),
            task("h", "Due later", due: "2026-11-20"),
            task("i", "Due today", due: "2026-11-13"),
            task("j", "Finished undated", status: .completed),
            task("k", "Cancelled overdue", due: "2026-11-01", status: .cancelled),
            task("l", "Started, undated", status: .inProgress),
        ]
        var overdueFollowUp = ShiftFollowUp.fresh()
        overdueFollowUp.id = "fu-late"
        overdueFollowUp.title = "Ping Nithin"
        overdueFollowUp.followUpAt = "2026-11-10"
        var undatedFollowUp = overdueFollowUp
        undatedFollowUp.id = "fu-undated"
        undatedFollowUp.followUpAt = nil
        var doneFollowUp = overdueFollowUp
        doneFollowUp.id = "fu-done"
        doneFollowUp.status = .done

        let tray = ShiftCalendarModel.tray(tasks: tasks, followUps: [overdueFollowUp, undatedFollowUp, doneFollowUp],
                                           projects: [release, infra], today: "2026-11-13")
        // Project order is the store's, an unknown project id is still a
        // group (under its id), and No project is last.
        check(tray.groups.map(\.title) == ["Release", "Infra", "p-gone", ShiftCalendarTray.noProjectTitle],
              "groups follow the store's project order with No project last, got \(tray.groups.map(\.title))")
        check(tray.groups.first { $0.projectID == "p-infra" }?.items.map(\.id) == ["c", "d"],
              "a group is sorted by priority, then title")
        check(tray.groups.last?.items.map(\.id) == ["f", "l", "b"],
              "No project holds every undated open task without one, in-progress included, finished excluded, got "
              + "\(tray.groups.last?.items.map(\.id) ?? [])")
        check(tray.groups.last?.projectID == nil, "the No project group carries no project id")
        check(tray.unscheduledCount == 7, "seven open tasks have no date, counted \(tray.unscheduledCount)")
        // Overdue: oldest first, follow-ups too, nothing finished, today is
        // not overdue.
        check(tray.overdue.map(\.id) == ["fu-late", "g"],
              "overdue work is pinned oldest first, follow-ups included, got \(tray.overdue.map(\.id))")
        check(tray.overdue.first?.kind == .followUp && tray.overdue.first?.daysOverdue == 3
              && tray.overdue.last?.daysOverdue == 2 && tray.overdue.last?.dueDay == "2026-11-11",
              "an overdue row knows its day and how late it is, got \(tray.overdue)")
        check(tray.openTasks == 10 && tray.datedRecords == 4,
              "10 open tasks and 4 dated records, got \(tray.openTasks) and \(tray.datedRecords)")
        check(!tray.isUndatedOnly, "a store with dated work is not the first-run state")

        // The captain's situation: open tasks, none dated.
        let undatedOnly = ShiftCalendarModel.tray(tasks: [task("x", "One"), task("y", "Two")], followUps: [undatedFollowUp],
                                                  projects: [], today: "2026-11-13")
        check(undatedOnly.isUndatedOnly && undatedOnly.unscheduledCount == 2,
              "two undated tasks and no dated work is the first-run state")
        // The fixture's own discriminating power: one dated follow-up is
        // dated work, so the empty state must give way to the grid.
        var datedSoon = overdueFollowUp
        datedSoon.followUpAt = "2026-11-20"
        check(!ShiftCalendarModel.tray(tasks: [task("x", "One")], followUps: [datedSoon], projects: [],
                                       today: "2026-11-13").isUndatedOnly,
              "a dated follow-up is dated work, so the first-run state does not apply")
        check(!ShiftCalendarModel.tray(tasks: [], followUps: [], projects: [], today: "2026-11-13").isUndatedOnly,
              "an empty store is not \"open tasks with no date\"")
    }

    private static func checkTrayPayload(_ check: (Bool, String) -> Void) {
        var infra = ShiftProject.fresh()
        infra.id = "p-infra"
        infra.name = "Infra"
        var tray = ShiftCalendarTray()
        tray.groups = [
            .init(projectID: "p-infra", title: "Infra", items: [
                ShiftCalendarTrayItem(id: "c", kind: .task, title: "Audit \"IAM\" keys", priority: .high,
                                      projectID: "p-infra"),
            ]),
            .init(projectID: nil, title: ShiftCalendarTray.noProjectTitle, items: [
                ShiftCalendarTrayItem(id: "b", kind: .task, title: "Try Renovate", priority: .low, projectID: nil),
            ]),
        ]
        tray.overdue = [
            ShiftCalendarTrayItem(id: "fu", kind: .followUp, title: "Ping", priority: .normal, projectID: nil,
                                  dueDay: "2026-11-10", daysOverdue: 3),
            ShiftCalendarTrayItem(id: "g", kind: .task, title: "Renew TLS", priority: .high, projectID: "p-infra",
                                  dueDay: "2026-11-12", daysOverdue: 1),
        ]
        tray.openTasks = 3
        tray.datedRecords = 2
        let theme = HelmTheme.dusk
        let payload = ShiftCalendarPayload.tray(tray, projectNames: ["p-infra": "Infra"], theme: theme, collapsed: true)
        check(payload["count"] as? Int == 2, "the tray's count is its undated tasks, got \(payload["count"] ?? "nil")")
        check(payload["collapsed"] as? Bool == true, "the remembered fold crosses the bridge")
        check(payload["empty"] == nil, "a store with dated work sends no empty state")
        check(payload["overdueTitle"] as? String == "Overdue · 2", "the Overdue heading counts its rows")
        let overdue = payload["overdue"] as? [[String: Any]] ?? []
        check(overdue.map { $0["meta"] as? String ?? "" } == ["Overdue 3 days · Follow-up", "Overdue 1 day · Infra"],
              "an overdue row says how late it is and what it is, got \(overdue.map { $0["meta"] ?? "" })")
        check(overdue.first?["kind"] as? String == "followUp" && overdue.first?["overdue"] as? Bool == true,
              "a follow-up row says it is one, so Today writes the follow-up's own date")
        let groups = payload["groups"] as? [[String: Any]] ?? []
        check(groups.map { $0["title"] as? String ?? "" } == ["Infra", "No project"] && groups.first?["count"] as? Int == 1,
              "groups cross in order with their counts")
        check(groups.first?["dot"] as? String == "#" + ShiftProjectPalette.tint(forProjectID: "p-infra").hex(in: theme),
              "a project group's dot is its project's colour")
        check(groups.last?["dot"] as? String == "",
              "No project's dot is left to the page's faint ink, never page ink (the .neutral rule)")
        let firstRow = (groups.first?["items"] as? [[String: Any]])?.first ?? [:]
        check(firstRow["title"] as? String == "Audit \"IAM\" keys" && firstRow["taskID"] as? String == "c",
              "a row's title and id cross unaltered")
        check(firstRow["meta"] as? String == "High priority", "an undated row names its priority")
        check(firstRow["edge"] as? String == ShiftCalendarPalette.colours(for: .high, theme: theme)["main"],
              "a row's edge is its category's colour, the same one its chip would have")
        // The discriminating half: two categories really are two edges.
        let lowRow = (groups.last?["items"] as? [[String: Any]])?.first ?? [:]
        check(lowRow["edge"] as? String != firstRow["edge"] as? String, "a low-priority row's edge differs from a high one's")
        check(payload["nothing"] as? String == "", "a tray with rows says nothing about being empty")

        var undated = tray
        undated.overdue = []
        undated.datedRecords = 0
        undated.openTasks = 13
        let empty = ShiftCalendarPayload.tray(undated, projectNames: [:], theme: theme, collapsed: false)["empty"]
            as? [String: String]
        check(empty?["title"] == "Nothing has a date yet", "the first-run state has its title, got \(empty ?? [:])")
        check(empty?["body"]?.hasPrefix("You have 13 open tasks, and none of them is on a day.") == true,
              "the first-run state counts the open tasks, got \(empty?["body"] ?? "nil")")
        check(empty?["body"]?.contains("Unscheduled") == true, "the first-run state points at the tray")
        check(empty?["body"]?.lowercased().contains("drag") == false,
              "the first-run state must not offer a drag from the tray, which is not built yet")
        check(empty?["newTask"] == "New task" && empty?["openList"] == "Open List", "the two buttons are named")
        check(ShiftCalendarPayload.emptyState(openTasks: 1)["body"]?.hasPrefix("You have 1 open task, and it is") == true,
              "one open task is not pluralised")
        let nothing = ShiftCalendarPayload.tray(ShiftCalendarTray(), projectNames: [:], theme: theme, collapsed: false)
        check(nothing["nothing"] as? String == ShiftCalendarPayload.trayAllDated,
              "a tray with no rows says every open task has a date, rather than drawing a blank card")
    }

    private static func checkCompletedMonths(_ check: (Bool, String) -> Void) {
        let start = ShiftDateFormatting.date(from: "2026-09-28") ?? Date()
        let end = ShiftDateFormatting.date(from: "2026-11-08") ?? Date()
        check(ShiftCalendarModel.completedMonths(from: start, through: end)
              == ["2026-08", "2026-09", "2026-10", "2026-11", "2026-12"],
              "the October grid reads the months it touches and one either side, got "
              + "\(ShiftCalendarModel.completedMonths(from: start, through: end))")
        let jan = ShiftDateFormatting.date(from: "2027-01-05") ?? Date()
        check(ShiftCalendarModel.completedMonths(from: jan, through: jan) == ["2026-12", "2027-01", "2027-02"],
              "a range crosses a year boundary cleanly")
        for bad in ["2026-13", "2026-1", "../x", "2026-10.yaml", "２０２６-10"] {
            check(!ShiftStore.isMonthKey(bad), "\(bad) must not be accepted as a month file name")
        }
        check(ShiftStore.isMonthKey("2026-10"), "2026-10 is a month")

        // A real store, real month files: a past month reads only its own.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-calendar-months-\(UUID().uuidString)", isDirectory: true)
        let prior = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            if let prior { setenv("FM_SHIFT_DIR", prior, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        let store = ShiftStore()
        var october = ShiftTask.fresh()
        october.title = "Finished in October"
        october.dueDate = "2026-10-14"
        store.addTask(october)
        var november = ShiftTask.fresh()
        november.title = "Finished in November"
        november.dueDate = "2026-11-03"
        store.addTask(november)
        let calendar = Calendar.current
        let octNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0,
                                    of: ShiftDateFormatting.date(from: "2026-10-15") ?? Date()) ?? Date()
        let novNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0,
                                    of: ShiftDateFormatting.date(from: "2026-11-04") ?? Date()) ?? Date()
        store.setTaskCompleted(id: october.id, completed: true, now: octNoon)
        store.setTaskCompleted(id: november.id, completed: true, now: novNoon)
        check(store.completedTasks(inMonths: ["2026-10"]).map(\.id) == [october.id],
              "October's file holds October's finished task only")
        check(Set(store.completedTasks(inMonths: ["2026-10", "2026-11", "2026-10"]).map(\.id)) == [october.id, november.id]
              && store.completedTasks(inMonths: ["2026-10", "2026-11", "2026-10"]).count == 2,
              "two months read both files once each")
        check(store.completedTasks(inMonths: ["2025-01", "../tasks"]).isEmpty,
              "a month with no file, or a key that is not a month, reads nothing")
        // The memo is invalidated by a write: un-completing October's task
        // takes it out of the month the calendar reads.
        _ = store.completedTasks(inMonths: ["2026-10"])
        store.setTaskCompleted(id: october.id, completed: false)
        check(store.completedTasks(inMonths: ["2026-10"]).isEmpty,
              "a task put back to active must leave its month's memo, not linger on the calendar")
    }

    // MARK: 8. The four views

    private static func checkScales(_ check: (Bool, String) -> Void) {
        check(ShiftCalendarScale.agenda.rawValue == "list", "Agenda is Schedule-X's open-source list view")
        // The four views are the card's own pills (tasks-calendar plan PR 4):
        // the toolbar draws Tasks' views, the Calendar among them, and the
        // Calendar row draws no tabs of its own.
        check(WorkspaceModule.calendar.children.isEmpty && WorkspaceModule.tasks.children.contains("Calendar"),
              "the calendar's views should be the card's, got Calendar \(WorkspaceModule.calendar.children) "
              + "and Tasks \(WorkspaceModule.tasks.children)")
        for scale in ShiftCalendarScale.allCases {
            check(ShiftCalendarScale(title: scale.title) == scale, "\(scale.title) does not round-trip")
        }
        let agenda = ShiftCalendarModel.range(for: ShiftDateFormatting.date(from: "2026-10-15") ?? Date(), scale: .agenda)
        let month = ShiftCalendarModel.range(for: ShiftDateFormatting.date(from: "2026-10-15") ?? Date(), scale: .month)
        check(agenda.start == month.start && agenda.days == month.days,
              "the agenda covers the month the month grid does")
    }

    // MARK: 9. Colour by project

    static let colouringProjects: [ShiftProject] = {
        var infra = ShiftProject.fresh()
        infra.id = "Infra_Hardening/2026"
        infra.name = "Infra hardening"
        var release = ShiftProject.fresh()
        release.id = "release-4-20"
        release.name = ""
        return [infra, release]
    }()

    private static func checkProjectColouring(_ check: (Bool, String) -> Void) {
        let theme = HelmTheme.daylight
        let projects = colouringProjects
        let infra = projects[0]
        func entry(project: String?, kind: ShiftCalendarEntry.Kind = .task) -> ShiftCalendarEntry {
            ShiftCalendarEntry(taskID: "t", title: "Task", day: "2026-11-13", time: nil, projectID: project,
                               priority: .high, isProjected: false, isCompleted: false, kind: kind)
        }

        // A safe id: Schedule-X builds CSS custom properties from it.
        check(ShiftCalendarPalette.projectCalendarID(infra.id) == "project-infra-hardening-2026",
              "a project's calendar id is \(ShiftCalendarPalette.projectCalendarID(infra.id))")
        check(ShiftCalendarPalette.projectCalendarID(nil) == "project-none"
                && ShiftCalendarPalette.projectCalendarID("") == "project-none",
              "no project has its own calendar id")

        // Which calendar a chip is drawn in.
        check(ShiftCalendarPalette.calendarID(for: entry(project: infra.id), colouring: .priority)
                == ShiftCalendarCategory.high.rawValue,
              "by priority, a high task is drawn in the high category")
        check(ShiftCalendarPalette.calendarID(for: entry(project: infra.id), colouring: .project)
                == ShiftCalendarPalette.projectCalendarID(infra.id),
              "by project, a task is drawn in its project's calendar")
        check(ShiftCalendarPalette.calendarID(for: entry(project: nil), colouring: .project) == "project-none",
              "by project, a task with no project is drawn in the No project calendar")
        check(ShiftCalendarPalette.calendarID(for: entry(project: infra.id, kind: .followUp), colouring: .project)
                == ShiftCalendarCategory.followUp.rawValue,
              "a follow-up stays amber when chips are coloured by project")
        check(ShiftCalendarPayload.event(for: entry(project: infra.id), colouring: .project)["calendarId"] as? String
                == ShiftCalendarPalette.projectCalendarID(infra.id),
              "the event payload names the project's calendar")

        // The calendars and the legend the page gets.
        let byPriority = ShiftCalendarPalette.calendars(for: theme, colouring: .priority, projects: projects)
        let byProject = ShiftCalendarPalette.calendars(for: theme, colouring: .project, projects: projects)
        check(Set(byPriority.keys) == Set(ShiftCalendarCategory.allCases.map(\.rawValue)),
              "by priority the page gets the four categories, got \(byPriority.keys.sorted())")
        let projectIDs = projects.map { ShiftCalendarPalette.projectCalendarID($0.id) } + ["project-none"]
        check(Set(byProject.keys) == Set(ShiftCalendarCategory.allCases.map(\.rawValue) + projectIDs),
              "by project the page gets every project, No project and the categories, got \(byProject.keys.sorted())")
        let legend = ShiftCalendarPalette.legend(for: theme, colouring: .project, projects: projects)
        check(legend.map { $0["id"] ?? "" } == projectIDs + [ShiftCalendarCategory.followUp.rawValue],
              "by project the legend is the projects, No project and Follow-up, got \(legend.map { $0["id"] ?? "" })")
        check(legend.map { $0["label"] ?? "" } == ["Infra hardening", "Untitled project", "No project", "Follow-up"],
              "the legend's words are \(legend.map { $0["label"] ?? "" })")
        check(ShiftCalendarPalette.themePayload(for: theme, colouring: .project, projects: projects)["legend"]
                as? [[String: String]] == legend,
              "the theme payload carries the project legend")

        // A project's chip is its board hue; no project is the neutral well,
        // never a wash of page ink (AGENTS.md's `.neutral` rule).
        let infraColours = ShiftCalendarPalette.projectColours(infra.id, theme: theme)
        check(infraColours["main"]?.uppercased()
                == "#" + ShiftProjectPalette.tint(forProjectID: infra.id).hex(in: theme).uppercased(),
              "a project's chip edge is its board hue, got \(infraColours["main"] ?? "nil")")
        for palette in HelmTheme.appThemes {
            let none = ShiftCalendarPalette.projectColours(nil, theme: palette)
            let inkWash = ShiftCalendarPalette.colours(tintHex: palette.chromeInkHex, theme: palette)
            check(none["container"] != inkWash["container"],
                  "\(palette.id): a task with no project is drawn as a wash of page ink")
            if let fill = none["container"] {
                let card = HelmTheme.nsColor(palette.chromeBackgroundHex)
                let ratio = HelmContrast.ratio(HelmTheme.nsColor(String(fill.dropFirst())), card)
                check(ratio < 1.6, "\(palette.id): the No project chip measures \(String(format: "%.2f", ratio)):1 "
                      + "on its card - heavier than the neutral well")
            }
        }

        // The tray's row edges follow the colouring too.
        var tray = ShiftCalendarTray()
        tray.groups = [.init(projectID: infra.id, title: infra.name,
                             items: [ShiftCalendarTrayItem(id: "u", kind: .task, title: "Undated", priority: .high,
                                                           projectID: infra.id)])]
        let payload = ShiftCalendarPayload.tray(tray, projectNames: [infra.id: infra.name], theme: theme,
                                                collapsed: false, colouring: .project)
        let edge = ((payload["groups"] as? [[String: Any]])?.first?["items"] as? [[String: Any]])?.first?["edge"] as? String
        check(edge == infraColours["main"], "by project a tray row's edge is its project's hue, got \(edge ?? "nil")")

        // The choice is remembered, and priority is the default.
        let defaults = AppDefaults.store
        let saved = defaults.object(forKey: ShiftCalendarColouring.defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: ShiftCalendarColouring.defaultsKey) }
            else { defaults.removeObject(forKey: ShiftCalendarColouring.defaultsKey) }
        }
        defaults.removeObject(forKey: ShiftCalendarColouring.defaultsKey)
        check(ShiftCalendarColouring.saved == .priority, "an unset colouring reads as priority")
        defaults.set("project", forKey: ShiftCalendarColouring.defaultsKey)
        check(ShiftCalendarColouring.saved == .project, "a saved project colouring reads back")
        defaults.set("rainbow", forKey: ShiftCalendarColouring.defaultsKey)
        check(ShiftCalendarColouring.saved == .priority, "an unknown colouring falls back to priority")
    }

    // MARK: Helpers

    /// A file in `native/`, relative to the app's own sources.
    private static func sourceFile(_ relative: String) -> String? {
        guard let root = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relative).standardizedFileURL, encoding: .utf8)
    }
}

#endif
