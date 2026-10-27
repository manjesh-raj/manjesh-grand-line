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
        for entry in ["configure", "setEvents", "setTheme", "setView", "showDate", "suspend", "resume", "state"] {
            check(js.contains("\(entry):"), "the committed bundle has no `\(entry)` bridge entry - rebuild it")
        }
        for message in ["ready", "error", "range", "open", "add", "move"] {
            check(js.contains("type:\"\(message)\""), "the committed bundle never posts `\(message)`")
        }
        // The captain's card: its header, weekday row and legend are this
        // bundle's, not Schedule-X's, and Agenda is the open-source list view.
        if let html = try? String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8) {
            for id in ["gl-prev", "gl-next", "gl-title", "gl-today", "gl-views", "gl-weekdays", "gl-legend"] {
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

            for (id, value) in ShiftCalendarPalette.calendars(for: theme) {
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
        check(ShiftCalendarView.subtitle(total: 0, projected: 0) == "Nothing scheduled in this period.",
              "an empty period is stated, never left blank (GL-14)")
        let mixed = ShiftCalendarView.subtitle(total: 5, projected: 3)
        check(mixed.hasPrefix("2 tasks, 3 projected from a repeat rule"),
              "projections are counted apart from real tasks, got \"\(mixed)\"")
        let withFollowUps = ShiftCalendarView.subtitle(total: 2, projected: 0, followUps: 1)
        check(withFollowUps.hasPrefix("2 tasks and 1 follow-up in this period"),
              "follow-ups are counted beside tasks, got \"\(withFollowUps)\"")
        check(ShiftCalendarView.subtitle(total: 0, projected: 0, followUps: 2).hasPrefix("2 follow-ups in this period"),
              "a period with only follow-ups is not stated as empty")
    }

    // MARK: 8. The four views

    private static func checkScales(_ check: (Bool, String) -> Void) {
        check(ShiftCalendarScale.agenda.rawValue == "list", "Agenda is Schedule-X's open-source list view")
        check(WorkspaceModule.calendar.children == ShiftCalendarScale.allCases.map(\.title),
              "the Calendar module's tabs are its four views, got \(WorkspaceModule.calendar.children)")
        for scale in ShiftCalendarScale.allCases {
            check(ShiftCalendarScale(title: scale.title) == scale, "\(scale.title) does not round-trip")
        }
        let agenda = ShiftCalendarModel.range(for: ShiftDateFormatting.date(from: "2026-10-15") ?? Date(), scale: .agenda)
        let month = ShiftCalendarModel.range(for: ShiftDateFormatting.date(from: "2026-10-15") ?? Date(), scale: .month)
        check(agenda.start == month.start && agenda.days == month.days,
              "the agenda covers the month the month grid does")
    }

    // MARK: Helpers

    /// A file in `native/`, relative to the app's own sources.
    private static func sourceFile(_ relative: String) -> String? {
        guard let root = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relative).standardizedFileURL, encoding: .utf8)
    }
}

#endif
