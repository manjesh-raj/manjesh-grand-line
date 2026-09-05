// Manjesh Grand Line - native macOS app.
//
// Audit §6.2 - incident-mode relaunch continuity.
//
// `IncidentStore` already persists a running incident as it happens, and
// `ConsoleController.activeIncident()` reads that record rather than a cached
// flag - so after a relaunch the incident is still active and everything the
// captain does on its host still attaches to it. The gap was awareness: the
// only thing that said so was a small toolbar button on a busy strip.
//
// What this suite pins is the *decision*, because that is the whole feature:
// announce a pre-existing incident exactly once per app run, never announce
// one this run started (its card was already opened by the start itself), and
// never announce anything when there is no incident.
//
// It drives the real `ConsoleController.viewDidAppear` in a real window rather
// than calling `resumeActiveIncidentIfNeeded` directly - a hook that is
// correct but unwired is exactly the regression worth catching, and only
// going through the real appearance path can see it.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum IncidentResumeSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("aPreExistingIncidentIsAnnouncedOnTheHostPagesNextOpen", test_announcedOnReopen),
            ("itIsAnnouncedOnlyOncePerRun", test_announcedOnlyOnce),
            ("nothingIsAnnouncedWhenNoIncidentIsActive", test_silentWithNoIncident),
            ("anIncidentStartedInThisRunIsNotReAnnounced", test_startedThisRunIsNotReAnnounced),
            ("theSharedConsoleNeverAnnouncesAnything", test_sharedConsoleIsSilent),
            ("viewDidAppearActuallyCallsTheResumeHook", test_resumeHookIsWired),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
            ? "IncidentResumeSelfTest: all \(cases.count) cases passed"
            : "IncidentResumeSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Harness

    private static let hostID = "33333333-3333-3333-3333-333333333333"
    private static let hostLabel = "EKS Preprod Bastion"

    /// A scratch incident root, pointed at by `FM_INCIDENTS_DIR` for as long
    /// as the body runs.
    ///
    /// Set explicitly rather than relied on: `FM_INCIDENTS_DIR` is *not* in
    /// `main.swift`'s global self-test redirect block (audit 7.2), so a bare
    /// `IncidentStore()` - which is exactly what `ConsoleController` builds -
    /// would otherwise reach the captain's real `manjesh-config` clone.
    private static func withScratchIncidents<T>(_ body: (URL) -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-resume-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["FM_INCIDENTS_DIR"]
        setenv("FM_INCIDENTS_DIR", dir.path, 1)
        defer {
            if let saved { setenv("FM_INCIDENTS_DIR", saved, 1) } else { unsetenv("FM_INCIDENTS_DIR") }
            try? FileManager.default.removeItem(at: dir)
        }
        return body(dir)
    }

    /// A real host-page console in a real off-screen window.
    ///
    /// Ordered far off-screen and never made key: this machine runs the
    /// captain's own instance, and a suite must not take focus.
    private static func makeHostConsole(identity: ConsoleHostIdentity?) -> (NSWindow, ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(),
                                           isFirstmateConsole: false)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.hostIdentity = identity
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func identity() -> ConsoleHostIdentity {
        ConsoleHostIdentity(id: hostID, label: hostLabel)
    }

    /// Write a real active incident to disk, the way a previous app run would
    /// have left one behind.
    private static func seedIncident(root: URL, title: String) -> String? {
        guard case .success(let incident) = IncidentStore(root: root)
            .start(title: title, hostID: hostID, hostLabel: hostLabel) else { return nil }
        return incident.id
    }

    // MARK: Cases

    /// The headline: an incident that outlived the app is announced when its
    /// host page opens, and the card really is showing *that* incident.
    private static func test_announcedOnReopen() -> String? {
        withScratchIncidents { root in
            guard let id = seedIncident(root: root, title: "payments-worker OOMKilled") else {
                return "could not seed an active incident"
            }
            let (window, controller) = makeHostConsole(identity: identity())
            defer { _ = window }

            guard controller.debugResumeAnnouncements.isEmpty else {
                return "something was announced before the page ever appeared"
            }
            controller.viewDidAppear()

            guard controller.debugResumeAnnouncements == [id] else {
                return "opening the host page announced \(controller.debugResumeAnnouncements), want [\(id)]"
            }
            // The announcement has to reach the card, or it is a toast that
            // tells the captain something and then offers them nothing.
            let rendered = controller.incidentCard.debugRenderedTitle
            guard rendered.contains(id) else {
                return "the incident card is not showing the resumed incident (showing \"\(rendered)\")"
            }
            return nil
        }
    }

    /// The guard that makes this liveable: navigating back to the page must
    /// not re-announce. Only a *count* can see this - the state after one
    /// appearance and after three is otherwise identical.
    private static func test_announcedOnlyOnce() -> String? {
        withScratchIncidents { root in
            guard let id = seedIncident(root: root, title: "search-api 5xx spike") else {
                return "could not seed an active incident"
            }
            let (window, controller) = makeHostConsole(identity: identity())
            defer { _ = window }

            controller.viewDidAppear()
            controller.viewDidDisappear()
            controller.viewDidAppear()
            controller.viewDidAppear()

            guard controller.debugResumeAnnouncements == [id] else {
                return "three appearances announced \(controller.debugResumeAnnouncements.count) times "
                     + "(\(controller.debugResumeAnnouncements)) - want exactly one"
            }
            return nil
        }
    }

    /// No incident, no announcement - and specifically no card popped at a
    /// captain who never started one.
    private static func test_silentWithNoIncident() -> String? {
        withScratchIncidents { _ in
            let (window, controller) = makeHostConsole(identity: identity())
            defer { _ = window }
            controller.viewDidAppear()
            guard controller.debugResumeAnnouncements.isEmpty else {
                return "announced \(controller.debugResumeAnnouncements) with no active incident"
            }
            return nil
        }
    }

    /// An incident started during this run already opened its own card. It
    /// must not open again every time the page is navigated back to - which
    /// is the difference between "resumed after a relaunch" and "nagging".
    private static func test_startedThisRunIsNotReAnnounced() -> String? {
        withScratchIncidents { root in
            let (window, controller) = makeHostConsole(identity: identity())
            defer { _ = window }
            controller.viewDidAppear()

            // Started *after* the page was already open - the shape of a
            // captain starting one from the toolbar mid-session.
            guard let id = seedIncident(root: root, title: "started mid-session") else {
                return "could not seed an active incident"
            }
            controller.debugMarkIncidentAnnounced(id)

            controller.viewDidAppear()
            guard controller.debugResumeAnnouncements.isEmpty else {
                return "an incident started in this run was re-announced: \(controller.debugResumeAnnouncements)"
            }
            return nil
        }
    }

    /// The shared Firstmate console has no single host, so it can never have
    /// an incident to resume - and must not read one belonging to a host page.
    private static func test_sharedConsoleIsSilent() -> String? {
        withScratchIncidents { root in
            _ = seedIncident(root: root, title: "belongs to a host page")
            let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(),
                                               isFirstmateConsole: true)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            defer { _ = window }

            controller.viewDidAppear()
            guard controller.debugResumeAnnouncements.isEmpty else {
                return "the shared console announced \(controller.debugResumeAnnouncements)"
            }
            return nil
        }
    }

    /// A source guard for the wiring the behavioural cases above ride on.
    ///
    /// They drive `viewDidAppear`, so they already prove it - but only for a
    /// page that reaches `viewDidAppear`. This states the requirement in one
    /// place so a future refactor that moves the call somewhere it no longer
    /// fires reads as a deliberate change rather than a silent one.
    private static func test_resumeHookIsWired() -> String? {
        guard let sources = SelfTestSources.appSourceDirectory() else { return nil }
        let path = sources.appendingPathComponent("ConsoleController.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return "could not read ConsoleController.swift for the source guard"
        }
        guard text.contains("resumeActiveIncidentIfNeeded()") else {
            return "viewDidAppear no longer calls resumeActiveIncidentIfNeeded()"
        }
        return nil
    }
}

#endif
