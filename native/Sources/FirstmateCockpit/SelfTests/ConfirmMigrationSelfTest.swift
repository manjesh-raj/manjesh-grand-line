// Manjesh Grand Line - native macOS app.
//
// G3 of the UI modernization audit: the 30 `NSAlert` sites.
//
// This is the one safety-sensitive slice of that section, and the brief for it
// is explicit - "the migration must not weaken any confirm semantics". So what
// this suite asserts is not "does the new dialog look right" (that is one
// check) but the three things that would make the migration *wrong*:
//
//   1. **The effect is still gated on the answer.** `HelmConfirm.confirm` is
//      `@discardableResult`, so a call whose result nobody reads compiles
//      perfectly and turns a confirmation into a formality that always
//      proceeds. That is the single worst outcome available here, it is
//      invisible in a diff of 22 files, and no behavioural check at one site
//      can see it at another - so every call site is swept as source.
//   2. **Which key does what has not moved.** The survey behind G3 found two
//      competing conventions among the 30: `DestructiveConfirm` and the risk
//      gates put Cancel first so Return cancels, while ten sites put the
//      action first so Return performs it. That inconsistency is real and is
//      raised separately - fixing it *here* would be changing a safety gate's
//      behaviour inside a restyle. Each migrated site therefore keeps its own
//      answer, and this pins the ones that can be reached.
//   3. **The deliberately-kept `NSAlert`s are still there, and are exactly
//      the eight named.** A ninth appearing means a new site chose system
//      chrome without the decision being made; one disappearing means a
//      safety gate was migrated without being argued for.
//
// Behavioural coverage is split honestly. `responderForTests` lets every
// reachable site be driven, and **returning `.cancel` is always safe** - so
// every site this suite can invoke is driven at least that far, which is what
// proves "nothing fires on cancel". The `.confirm` direction is driven only
// where the effect is safe to actually perform in a headless process: a
// scratch-backed store delete, or a closure. It is deliberately NOT driven for
// the sites whose effect is a real `git push`, a real PR merge, a ~547MB
// model deletion or a store overwrite - a self-test that performed those to
// prove a button works would be a worse bug than the one it was guarding.
//
// Window-backed (it mounts real controllers), so it is in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Run with:
//   swift build && FM_RUN_CONFIRM_MIGRATION_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ConfirmMigrationSelfTest {

    /// The eight sites that deliberately keep the system alert, with the
    /// reason each one does. See `HelmConfirm`'s header for the rule.
    ///
    /// A literal list, not derived from a grep: deriving it would make the
    /// check pass for any set of sites in any file, which is precisely the
    /// decision it exists to pin.
    private static let keepsSystemAlert: [(file: String, why: String)] = [
        ("CommandLibraryViews.swift", "the four CommandRiskConfirmation gates - a real shell command is about to run"),
        ("ConsoleController+Herdr.swift", "terminates live panes in another program"),
        ("UpdatesController+AppRow.swift", "replaces the running binary and terminates"),
        ("ConsoleController+Incident.swift", "already a sheet, not a centre-screen alert"),
        ("ConsoleController+SRELead.swift", "already a sheet, not a centre-screen alert"),
    ]

    static func run() -> Bool {
        let restoreTheme = ThemeManager.shared.theme
        defer {
            ThemeManager.shared.setTheme(restoreTheme)
            HelmConfirm.responderForTests = nil
        }
        scratchStores()
        var allOK = true
        for check in [checkEveryCallSiteGatesItsEffect,
                      checkKeptSystemAlertsAreExactlyTheEightNamed,
                      checkComponentContract,
                      checkDestructiveConfirmSemantics,
                      checkScheduleDelete,
                      checkRunbookDelete,
                      checkLogout,
                      checkDangerousSitesCancelCleanly,
                      checkThePanelIsSizedForItsRealWrapWidth] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ConfirmMigrationSelfTest: all checks passed"
                    : "ConfirmMigrationSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static var scratchDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("confirm-migration-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func scratchStores() {
        setenv("FM_HOSTS_FILE", scratchDir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", scratchDir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", scratchDir.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_SHIFT_DIR", scratchDir.appendingPathComponent("shift").path, 1)
        setenv("FM_DOCS_RUNBOOKS_DIR", scratchDir.appendingPathComponent("runbooks").path, 1)
        setenv("FM_SCHEDULES_FILE", scratchDir.appendingPathComponent("schedules.json").path, 1)
    }

    private static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    private static func appSources() -> [URL] {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "swift" }
    }

    /// Answer the next dialog with `response`, recording the request it was
    /// asked. Restores the seam afterwards.
    @discardableResult
    private static func answering(_ response: HelmConfirm.Response,
                                  _ body: () -> Void) -> [HelmConfirm.Request] {
        var seen: [HelmConfirm.Request] = []
        HelmConfirm.responderForTests = { request in
            seen.append(request)
            return response
        }
        defer { HelmConfirm.responderForTests = nil }
        body()
        return seen
    }

    private static func makeWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: 1. Every call site still gates its effect

    private static func checkEveryCallSiteGatesItsEffect(_ ok: inout Bool) {
        print("\n-- G3: every confirm's result is read --")
        let files = appSources()
        guard !files.isEmpty else {
            print("  SKIP sources not present next to this binary")
            return
        }
        var checked = 0
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "HelmConfirm.swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (n, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                guard trimmed.contains("HelmConfirm.confirm(") else { continue }
                checked += 1
                // The result has to be consumed. `confirm` is
                // `@discardableResult` (so `DestructiveConfirm`'s own
                // `@discardableResult` wrapper still compiles), which means a
                // bare call statement - a confirmation that always proceeds -
                // is a *compiling* regression.
                // `_ = …` is the *discard* form, not a consuming one - and it
                // is the exact shape a regression takes, because it is what
                // the compiler suggests when `@discardableResult` is removed.
                // An injected `_ = HelmConfirm.confirm(…)` passed an earlier
                // version of this check that treated any " = " as consumption.
                func consumes(_ t: String) -> Bool {
                    if t.hasPrefix("_ =") || t.hasPrefix("_=") { return false }
                    return t.hasPrefix("guard ") || t.hasPrefix("if ")
                        || t.hasPrefix("return ") || t.hasPrefix("switch ")
                        || t.contains(" = ")
                }
                // A multi-line call: the consuming keyword is on an earlier
                // line, so walk back to the nearest statement start.
                let consumed = consumes(trimmed)
                    || lines[max(0, n - 4)...n].contains {
                        consumes($0.trimmingCharacters(in: .whitespaces))
                    }
                if !consumed {
                    offenders.append("\(file.lastPathComponent):\(n + 1)")
                }
            }
        }
        if checked == 0 {
            print("  FAIL no HelmConfirm.confirm call sites found at all - re-point this check")
            ok = false
            return
        }
        if offenders.isEmpty {
            print("  OK   \(checked) call site(s), every one gating on the answer")
        } else {
            for o in offenders { print("  FAIL \(o) calls HelmConfirm.confirm and ignores the answer") }
            ok = false
        }
    }

    // MARK: 2. The eight deliberately-kept system alerts

    private static func checkKeptSystemAlertsAreExactlyTheEightNamed(_ ok: inout Bool) {
        print("\n-- G3: NSAlert survives only where the decision says it should --")
        let files = appSources()
        guard !files.isEmpty else {
            print("  SKIP sources not present next to this binary")
            return
        }
        var found: [String: Int] = [:]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains("NSAlert()") {
                    found[file.lastPathComponent, default: 0] += 1
                }
            }
        }
        let expected = Set(keepsSystemAlert.map(\.file))
        var problems: [String] = []
        for file in found.keys where !expected.contains(file) {
            problems.append("\(file) uses NSAlert but is not one of the eight kept sites")
        }
        for entry in keepsSystemAlert where found[entry.file] == nil {
            problems.append("\(entry.file) no longer uses NSAlert - it was kept because \(entry.why)")
        }
        // The four command gates are one file; the total is what pins that a
        // fifth did not quietly join them.
        let total = found.values.reduce(0, +)
        if total != 8 {
            problems.append("\(total) NSAlert sites, want exactly 8")
        }
        if problems.isEmpty {
            print("  OK   8 kept, in the 5 files the decision names")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 3. The component's own contract

    /// The panel must be sized at the width its body really wraps at.
    ///
    /// **The captain-reported "the Updates sync UI is not clean".** `runModal`
    /// read `content.fittingSize` before the view had any width, so the two
    /// places that derive `preferredMaxLayoutWidth` both fell back to their
    /// 200pt floor - the panel was sized for a body wrapped at 200pt, mounted
    /// at 380, and `layout()` then re-wrapped it several lines shorter with the
    /// frame already fixed. Measured on the Updates page's firstmate sync
    /// dialog: 308pt of panel for 244pt of content, so a quarter of the dialog
    /// was empty space below the buttons.
    ///
    /// This asserts the property rather than a number: mount the panel at the
    /// size the real code path measured, lay it out, and require it to need
    /// exactly that. A tolerance of one point absorbs AppKit's own rounding;
    /// anything more is slack a captain would see. It sweeps a real long body,
    /// a short one, an empty one and a wide accessory (which sets the dialog's
    /// width itself, so the width has to be settled before the height is
    /// measured), because only the long one reproduced the shipped defect.
    private static func checkThePanelIsSizedForItsRealWrapWidth(_ ok: inout Bool) {
        func check(_ condition: Bool, _ message: String) {
            if !condition { ok = false; print("FAIL: \(message)") }
        }

        // **A source guard as well as the behaviour, because they catch
        // different failures.** Every assertion below calls `measuredSize()`
        // itself, so it proves that method is right and says nothing about
        // `runModal` still calling it - and reverting that one line is exactly
        // how the defect shipped. Confirmed: with only the behavioural half,
        // putting `let size = content.fittingSize` back passed the whole suite.
        let source = source("HelmConfirm.swift") ?? ""
        check(!source.isEmpty, "could not read HelmConfirm.swift")
        check(source.contains("content.measuredSize()"),
              "HelmConfirm.runModal no longer sizes the panel with measuredSize()")
        check(!source.contains("let size = content.fittingSize"),
              "HelmConfirm.runModal is back to measuring with a bare fittingSize")

        // The real copy the Updates page builds, verbatim - the worst case in
        // the app and the one the captain reported.
        let syncDetail = "main carries 56 commit(s) of its own and is 1 behind upstream/main; "
            + "run without --check to merge upstream into main, then push to origin"
        var sync = HelmConfirm.Request(
            title: "Sync firstmate with upstream?",
            body: "\(syncDetail)\n\nThis fast-forwards the local default branch to "
                + "kunchenguid/firstmate's upstream, then pushes the result to origin (your fork). "
                + "Never forced, never a merge commit.")
        sync.confirmTitle = "Sync and Push"
        sync.symbol = "arrow.triangle.branch"
        sync.hue = RailDestination.updates.domainHue

        var short = HelmConfirm.Request(title: "Log out?",
                                        body: "You will need your Grand Line password to get back in.")
        short.confirmTitle = "Log Out"

        var empty = HelmConfirm.Request(title: "Delete this schedule?", body: "")
        empty.confirmTitle = "Delete"

        let accessory = NSView()
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.widthAnchor.constraint(equalToConstant: 520).isActive = true
        accessory.heightAnchor.constraint(equalToConstant: 120).isActive = true
        var wide = HelmConfirm.Request(title: "Draft preview", body: "Review it before saving.")
        wide.accessory = accessory

        // Every theme, because the tile the body's wrap width is measured
        // against is a different size on the Daylight family.
        for theme in [HelmTheme.allThemes.first(where: { $0.id == "dusk" }),
                      HelmTheme.allThemes.first(where: { $0.id == "helm-dark" }),
                      HelmTheme.allThemes.first(where: { $0.id == "daylight" })].compactMap({ $0 }) {
            for (name, request) in [("firstmate sync", sync), ("short", short),
                                    ("empty body", empty), ("wide accessory", wide)] {
                let content = HelmConfirm.makeContent(request)
                content.applyTheme(theme)
                let measured = content.measuredSize()
                check(measured.width >= HelmConfirmView.width,
                      "\(theme.id)/\(name): measured width \(measured.width) is under the minimum")

                let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0,
                                                          width: measured.width, height: measured.height),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = content
                window.layoutIfNeeded()
                content.layoutSubtreeIfNeeded()
                let needed = content.fittingSize
                let slack = measured.height - needed.height
                check(slack <= 1,
                      "\(theme.id)/\(name): the panel is \(slack)pt taller than its content needs")
                check(slack >= -1,
                      "\(theme.id)/\(name): the panel is \(-slack)pt shorter than its content needs")
                window.orderOut(nil)
            }
        }
    }

    private static func checkComponentContract(_ ok: inout Bool) {
        print("\n-- G3: the component answers the way an NSAlert did --")
        var problems: [String] = []

        // A real dialog view, built but not run - the copy, the buttons and
        // the key mapping read off the thing the captain would see.
        var request = HelmConfirm.Request(title: "Delete this?", body: "It cannot be undone.")
        request.confirmTitle = "Delete"
        request.destructive = true
        request.confirmIsDefault = false
        let view = HelmConfirm.makeContent(request)
        _ = makeWindow(view)
        if view.debugTitle != "Delete this?" { problems.append("title not rendered") }
        if view.debugBody != "It cannot be undone." { problems.append("body not rendered") }
        if view.debugButtonTitles != ["Cancel", "Delete"] {
            problems.append("buttons are \(view.debugButtonTitles), want [Cancel, Delete]")
        }
        // `confirmIsDefault: false` is what `DestructiveConfirm` relies on:
        // both safe keys do the safe thing.
        if view.debugDefaultButtonTitle != "Cancel" {
            problems.append("Return activates \(view.debugDefaultButtonTitle ?? "nothing"), want Cancel")
        }
        // The one that caught a real defect: an `NSButton` holds exactly one
        // `keyEquivalent`, so giving Cancel the Return key on a
        // `confirmIsDefault: false` dialog silently took Escape away from it.
        if !view.debugEscapeCancels {
            problems.append("Escape does not cancel when Return is also on Cancel")
        }
        if view.debugConfirmVariant != .destructive {
            problems.append("a destructive confirm is not styled destructive")
        }

        // And the other direction.
        var normal = HelmConfirm.Request(title: "Merge?", body: "")
        normal.confirmTitle = "Merge"
        let normalView = HelmConfirm.makeContent(normal)
        _ = makeWindow(normalView)
        if normalView.debugDefaultButtonTitle != "Merge" {
            problems.append("confirmIsDefault: true does not put Return on the confirm button")
        }
        if !normalView.debugEscapeCancels {
            problems.append("Escape does not cancel on a non-destructive confirm")
        }

        // A real click on each button produces the matching answer.
        var answers: [HelmConfirm.Response] = []
        let clickView = HelmConfirm.makeContent(normal)
        _ = makeWindow(clickView)
        clickView.onAnswer = { answers.append($0) }
        clickView.debugClickConfirm()
        clickView.debugClickCancel()
        clickView.debugPressEscape()
        if answers != [.confirm, .cancel, .cancel] {
            problems.append("clicks produced \(answers), want [confirm, cancel, cancel]")
        }

        if problems.isEmpty {
            print("  OK   copy, buttons, Return/Escape mapping and click answers")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 4. DestructiveConfirm - the shared helper, 7 call sites

    private static func checkDestructiveConfirmSemantics(_ ok: inout Bool) {
        print("\n-- G3: DestructiveConfirm (7 call sites) is unchanged in every way that matters --")
        var problems: [String] = []

        let confirmed = answering(.confirm) {
            if !DestructiveConfirm.confirm(message: "Delete X?", detail: "Gone for good.") {
                problems.append("choosing Delete returned false")
            }
        }
        let cancelled = answering(.cancel) {
            if DestructiveConfirm.confirm(message: "Delete X?", detail: "Gone for good.") {
                problems.append("choosing Cancel returned true")
            }
        }
        guard let request = confirmed.first, cancelled.count == 1 else {
            print("  FAIL the helper did not reach HelmConfirm (\(confirmed.count)/\(cancelled.count) dialogs)")
            ok = false
            return
        }
        // The three properties its own doc comment promises.
        if request.confirmIsDefault {
            problems.append("Return no longer means Cancel - the helper's whole ordering rule")
        }
        if !request.destructive { problems.append("not styled as destructive") }
        if request.confirmTitle != "Delete" { problems.append("confirm title is \(request.confirmTitle)") }
        if request.title != "Delete X?" || request.body != "Gone for good." {
            problems.append("the caller's copy was not carried through")
        }

        if problems.isEmpty {
            print("  OK   true on confirm, false on cancel, Return still means Cancel")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 5/6/7. Real sites, both directions - where the effect is safe

    private static func checkScheduleDelete(_ ok: inout Bool) {
        print("\n-- G3: a schedule delete fires on confirm, not on cancel --")
        let store = ScheduleStore()
        let schedule = AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 3, minute: 0))
        store.add(schedule)
        let controller = SchedulesController(scheduleStore: store)
        _ = makeWindow(controller.view)

        var problems: [String] = []
        let cancelRequests = answering(.cancel) {
            controller.debugConfirmDeleteSchedule(schedule)
        }
        if store.schedules.contains(where: { $0.id == schedule.id }) == false {
            problems.append("Cancel deleted the schedule anyway")
        }
        if cancelRequests.count != 1 { problems.append("no dialog was shown") }
        // This site put the action first, so Return deletes - preserved.
        if let r = cancelRequests.first, !r.confirmIsDefault {
            problems.append("Return no longer completes the delete, as it did before")
        }

        answering(.confirm) { controller.debugConfirmDeleteSchedule(schedule) }
        if store.schedules.contains(where: { $0.id == schedule.id }) {
            problems.append("Confirm did not delete the schedule")
        }

        if problems.isEmpty {
            print("  OK   kept on cancel, deleted on confirm, Return still deletes")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    private static func checkRunbookDelete(_ ok: inout Bool) {
        print("\n-- G3: a runbook delete fires on confirm, not on cancel --")
        // The controller owns its own store (a `DocsRunbookStore` resolves
        // through `FM_DOCS_RUNBOOKS_DIR`, which `scratchStores` points at a
        // temp directory), so this drives the same one it does.
        let store = DocsRunbookStore()
        let created = store.createRunbook(title: "Probe runbook", content: "# Probe runbook\n")
        let controller = RunbooksController()
        _ = makeWindow(controller.view)

        var problems: [String] = []
        answering(.cancel) {
            controller.debugConfirmDeleteRunbook(id: created.id, title: created.title)
        }
        if !store.listRunbooks().contains(where: { $0.id == created.id }) {
            problems.append("Cancel deleted the runbook anyway")
        }
        answering(.confirm) {
            controller.debugConfirmDeleteRunbook(id: created.id, title: created.title)
        }
        if store.listRunbooks().contains(where: { $0.id == created.id }) {
            problems.append("Confirm did not delete the runbook")
        }
        if problems.isEmpty {
            print("  OK   kept on cancel, deleted on confirm")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    private static func checkLogout(_ ok: inout Bool) {
        print("\n-- G3: logout fires on confirm, not on cancel --")
        let bar = DaylightBarController()
        _ = makeWindow(bar.view)
        var loggedOut = 0
        bar.onLogoutRequested = { loggedOut += 1 }

        var problems: [String] = []
        let cancelRequests = answering(.cancel) { bar.debugLogoutClicked() }
        if loggedOut != 0 { problems.append("Cancel logged out anyway") }
        if cancelRequests.count != 1 { problems.append("no dialog was shown") }
        if let r = cancelRequests.first, !r.confirmIsDefault {
            problems.append("Return no longer completes the logout, as it did before")
        }
        answering(.confirm) { bar.debugLogoutClicked() }
        if loggedOut != 1 { problems.append("Confirm logged out \(loggedOut) times, want 1") }

        if problems.isEmpty {
            print("  OK   nothing on cancel, exactly one logout on confirm")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }

    // MARK: 8. The sites whose effect must not be performed here

    private static func checkDangerousSitesCancelCleanly(_ ok: inout Bool) {
        print("\n-- G3: the sites whose effect is unsafe to drive still cancel cleanly --")
        // `.cancel` is always safe to answer, so these are driven that far and
        // no further: proving "nothing fires on cancel" is the half that can
        // be proven without performing a real `git push`, a real PR merge or a
        // ~547MB deletion. The `.confirm` half is covered structurally by
        // check 1 - the effect sits behind the answer at every one of them.
        var problems: [String] = []

        // Dictation's model delete: the effect is a real file removal.
        let dictation = DictationController(store: DictationStore())
        _ = makeWindow(dictation.view)
        let before = WhisperModelManager.shared.downloadedByteCount
        let requests = answering(.cancel) { dictation.debugModelDeleteTapped() }
        if requests.count != 1 { problems.append("the model delete showed \(requests.count) dialogs, want 1") }
        if WhisperModelManager.shared.downloadedByteCount != before {
            problems.append("Cancel changed the model on disk")
        }
        if let r = requests.first {
            if !r.destructive { problems.append("the model delete is not styled destructive") }
            // This site put Delete first, so Return deletes - preserved.
            if !r.confirmIsDefault { problems.append("Return no longer completes the model delete") }
        }

        if problems.isEmpty {
            print("  OK   cancel changes nothing, and the key mapping is unchanged")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }
}

#endif
