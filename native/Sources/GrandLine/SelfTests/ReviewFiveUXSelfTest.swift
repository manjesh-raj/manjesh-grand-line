// Grand Line - native macOS app.
//
// Review #5's UX findings (R5-UX-01 to R5-UX-11): the pure half - models,
// tables, menus and source guards. Each check names the finding it guards.
//
// Pure logic, no window: every case drives a model, reads a table or greps
// the app's own sources, so it runs in CI's blocking headless lane.

#if FM_SELFTESTS

import AppKit

enum ReviewFiveUXSelfTest {

    static func run() -> Bool {
        var ok = true
        checkPersonalLeavesOutTheFirstmateSteps(&ok)
        checkTheLaunchLandingFollowsTheProfileInBothLayouts(&ok)
        print(ok ? "ReviewFiveUXSelfTest: PASS" : "ReviewFiveUXSelfTest: FAIL")
        return ok
    }

    // MARK: Shared

    static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Runs `body` with the profile and hidden set it sets, and puts this
    /// process's own values back after.
    static func withProfile(_ profile: WorkspaceProfile?, _ body: () -> Void) {
        let defaults = AppDefaults.store
        let savedProfile = defaults.object(forKey: "fm.workspaceProfile")
        let savedHidden = defaults.object(forKey: "fm.hiddenModules")
        defer {
            defaults.set(savedProfile, forKey: "fm.workspaceProfile")
            defaults.set(savedHidden, forKey: "fm.hiddenModules")
        }
        if let profile {
            AppSettings.shared.setProfile(profile)
        } else {
            defaults.removeObject(forKey: "fm.workspaceProfile")
            defaults.removeObject(forKey: "fm.hiddenModules")
        }
        body()
    }

    // MARK: R5-UX-01 - profile-first onboarding

    /// A Personal install has no firstmate home and needs none, so Setup's
    /// steps about the fleet and the dotfiles are neither listed nor counted.
    /// An Operator, and a process with no profile, keep all five.
    private static func checkPersonalLeavesOutTheFirstmateSteps(_ ok: inout Bool) {
        let personal = SetupStepKind.shown(for: .personal)
        check(personal == [.software, .restoreConfig],
              "R5-UX-01: Personal's Setup steps are \(personal)", &ok)
        check(SetupStepKind.shown(for: .operator) == SetupStepKind.allCases && SetupStepKind.shown(for: nil) == SetupStepKind.allCases,
              "R5-UX-01: an Operator or an unsettled install no longer sees every Setup step", &ok)
        // The fixture's own power: Personal really leaves something out.
        check(personal.count < SetupStepKind.allCases.count, "R5-UX-01: the Personal fixture leaves nothing out", &ok)

        withProfile(.personal) {
            // Every step unanswered but Software, which drifted: a count over
            // the steps Personal shows answers, and the firstmate steps that
            // would read "not done" forever are not in it.
            let verdicts: [SetupStepKind: Bool?] = [.software: false, .restoreConfig: true]
            check(BackgroundSignalsPoller.setupDriftCount(from: verdicts) == 1,
                  "R5-UX-01: Personal's drift count waits on a step it does not show", &ok)
            let progress = SetupPipelineProgress.of(verdicts)
            check(progress.total == 2 && progress.done == 1,
                  "R5-UX-01: Personal's Setup progress reads \(progress.done) of \(progress.total)", &ok)
            // Custom built from Personal keeps the profile's Setup steps.
            var hidden = AppSettings.shared.hiddenModules
            hidden.remove(.setup)
            AppSettings.shared.hiddenModules = hidden
            check(SetupStepKind.shown == personal, "R5-UX-01: showing Setup to a Personal install brought the firstmate steps back", &ok)
        }
        withProfile(.operator) {
            let verdicts: [SetupStepKind: Bool?] = [.software: false, .restoreConfig: true]
            check(BackgroundSignalsPoller.setupDriftCount(from: verdicts) == nil,
                  "R5-UX-01: an Operator's drift count published with three steps unanswered", &ok)
        }
    }

    /// GL-31 lands a machine with no firstmate home on Setup. A profile that
    /// hides Setup has nothing there to fix, in either layout.
    private static func checkTheLaunchLandingFollowsTheProfileInBothLayouts(_ ok: inout Bool) {
        guard let workspace = source("Workspace.swift") else {
            fail("R5-UX-01: Workspace.swift is not readable", &ok)
            return
        }
        check(workspace.contains("if FirstmateHome.homeOk() || AppSettings.shared.hiddenModules.contains(.setup) {"),
              "R5-UX-01: the launch landing no longer skips a hidden Setup in both layouts", &ok)
        check(!workspace.contains("PlaceName.layout == .sidebar && AppSettings.shared.hiddenModules.contains(.setup)"),
              "R5-UX-01: the launch landing still opens a Personal floating-bar install on Setup", &ok)
    }
}

#endif
