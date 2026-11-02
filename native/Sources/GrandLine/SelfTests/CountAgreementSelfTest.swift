// Grand Line - native macOS app.
//
// `fm/grandline-github-sync-counts`, the second half of the captain's ask:
// "check this count on the other pages as well and make every count correct".
// An audit of every count, badge and x / y in the app found these wrong, and
// each case below pins one fix:
//
//   - W1: "tool updates" was counted as every tool needing an action (a
//     newer version, a missing install, a failed check) but worded as
//     "updates" on Home, in the bell and in the briefing - so thirteen failed
//     checks read "13 tools have updates" beside Setup's "Updates 0".
//   - W4/W5: Setup's "Setup steps" card and Home's / the bell's drift count
//     were two readings of the same five steps, and a hidden setup page could
//     re-stamp its old answers as new on a theme change. There is one
//     per-step reading now, and the drift count is derived from it.
//   - W17: the scheduled tool check and tool install ran their checks and
//     told nobody.
//   - W9, W12, W14, W15: the surfaces those touch are window-backed or need a
//     live forge, so they are source guards here (AGENTS.md: say which).
//
// Headless, so it runs on CI's blocking lane.
//
// Run with:
//   swift build && FM_RUN_COUNT_AGREEMENT_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum CountAgreementSelfTest {

    static func run() -> Bool {
        print("CountAgreementSelfTest")
        var ok = true
        checkToolCountsAreWordedByWhatTheyCount(&ok)
        checkOneReadingOfTheSetupSteps(&ok)
        checkTheScheduledToolCheckPublishes(&ok)
        checkTheGuardedFixes(&ok)
        print(ok ? "\nCountAgreementSelfTest: all checks passed" : "\nCountAgreementSelfTest: FAILED")
        return ok
    }

    private static func outcome(_ status: DependencyStatus) -> CheckOutcome {
        CheckOutcome(installedLabel: "1.0.0", latestLabel: "1.1.0", status: status, detail: "fixture", log: "")
    }

    private static func isolated(_ body: () -> Void) {
        let poller = BackgroundSignalsPoller.shared
        let counts = poller.lastCounts
        let override = DependencyCheckCache.checkOverrideForTests
        poller.debugResetReadingClock()
        poller.debugSetCounts(.init())
        SetupStepsReading.shared.resetForTests()
        defer {
            DependencyCheckCache.checkOverrideForTests = override
            poller.debugResetReadingClock()
            poller.debugSetCounts(counts)
            SetupStepsReading.shared.resetForTests()
            GrandLineNotificationCenter.shared.debugReset()
        }
        body()
    }

    // MARK: W1

    private static func checkToolCountsAreWordedByWhatTheyCount(_ ok: inout Bool) {
        print("\n-- a tool count says updates only when every one is an update --")
        check(NotificationSources.ToolAttention.phrase(attention: 3, updates: 3) == "3 tools have updates",
              "three updates are three updates", &ok)
        check(NotificationSources.ToolAttention.phrase(attention: 13, updates: 0) == "13 tools need attention",
              "thirteen failed checks are not thirteen updates", &ok)
        isolated {
            BackgroundSignalsPoller.shared.publishToolStatuses(
                [.checkFailed, .checkFailed, .notInstalled, .updateAvailable, .upToDate])
            let title = GrandLineNotificationCenter.shared.entries
                .first { $0.id == NotificationSources.toolUpdatesID }?.title
            check(title == "4 tools need attention",
                  "the bell over one update, a missing tool and two failed checks reads '\(title ?? "nothing")'", &ok)
        }
        var inputs = BriefingInputs()
        inputs.toolUpdateCount = 13
        inputs.toolsWithUpdateCount = 0
        let clause = MorningBriefingLocal.clauses(from: inputs).first { $0.target == .updates }?.text
        check(clause == "13 tools need attention", "the briefing reads '\(clause ?? "nothing")'", &ok)
        inputs.toolsWithUpdateCount = 13
        let updates = MorningBriefingLocal.clauses(from: inputs).first { $0.target == .updates }?.text
        check(updates == "13 tools have an update", "and says updates when they are: '\(updates ?? "nothing")'", &ok)
    }

    // MARK: W4 / W5

    private static func checkOneReadingOfTheSetupSteps(_ ok: inout Bool) {
        print("\n-- the drift count and the Setup steps card are one reading --")
        isolated {
            let poller = BackgroundSignalsPoller.shared
            let reading = SetupStepsReading.shared
            let now = Date()
            var allDone: [SetupStepKind: Bool?] = [:]
            for kind in SetupStepKind.allCases { allDone[kind] = true }
            var dotfilesDrifted = allDone
            dotfilesDrifted[.dotfiles] = false

            poller.publishSetupStepResults(dotfilesDrifted, gatheredAt: now)
            check(poller.lastCounts.setupDrift == 1 && reading.progress.done == SetupStepKind.allCases.count - 1,
                  "a pass with dotfiles drifted: drift \(String(describing: poller.lastCounts.setupDrift)), card \(reading.progress)", &ok)

            // A newer answer about one step - a scheduled drift check, two
            // steps only - moves the card *and* the drift count together.
            poller.publishSetupStepResults([.dotfiles: true, .agentInstructions: true], gatheredAt: now.addingTimeInterval(5))
            check(reading.progress.done == SetupStepKind.allCases.count,
                  "the card reads every step done: \(reading.progress)", &ok)
            check(poller.lastCounts.setupDrift == 0,
                  "and the drift count Home and the bell read agrees: \(String(describing: poller.lastCounts.setupDrift))", &ok)

            // A hidden page re-stamping an answer it had before must not roll
            // either back. Its old answer arrives with its old time.
            poller.publishSetupStepResults(dotfilesDrifted, gatheredAt: now.addingTimeInterval(-60))
            check(poller.lastCounts.setupDrift == 0 && reading.progress.done == SetupStepKind.allCases.count,
                  "an older answer rolled the steps back: drift \(String(describing: poller.lastCounts.setupDrift)), card \(reading.progress)", &ok)
        }
        // The page half: a re-render that learned nothing publishes nothing,
        // so it cannot stamp old answers as new. Source guard, because both
        // pages are window-backed.
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  NOTE: could not resolve the app sources - skipping the page guards")
            return
        }
        for name in ["BootstrapController.swift", "AutomationController.swift"] {
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            check(text.contains("guard results != lastPublishedSteps else { return }"),
                  "\(name) publishes its step answers even when they have not changed", &ok)
        }
    }

    // MARK: W17

    private static func checkTheScheduledToolCheckPublishes(_ ok: inout Bool) {
        print("\n-- a scheduled tool check reaches the counts --")
        isolated {
            DependencyCheckCache.checkOverrideForTests = { item in
                outcome(item.id == DependencyCatalog.items.first?.id ? .updateAvailable : .upToDate)
            }
            _ = ScheduleActions.run(.toolUpdateCheck, backupStores: nil)
            let deadline = Date().addingTimeInterval(3)
            while BackgroundSignalsPoller.shared.lastCounts.toolsWithUpdate == nil && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            let counts = BackgroundSignalsPoller.shared.lastCounts
            check(counts.toolsWithUpdate == 1 && counts.toolsTotal == DependencyCatalog.items.count,
                  "the run published \(String(describing: counts.toolsWithUpdate)) update(s) of \(String(describing: counts.toolsTotal))", &ok)
        }
    }

    // MARK: W9, W12, W14, W15, W17 (drift), W2

    private static func checkTheGuardedFixes(_ ok: inout Bool) {
        print("\n-- the fixes on window-backed or live-only surfaces --")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  NOTE: could not resolve the app sources - skipping")
            return
        }
        func code(_ name: String) -> String {
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        check(code("HomeCanvasController.swift").contains("if let attention = counts.vaultAttention {"),
              "W9: Home's Vault card hides a known attention count behind an unknown secrets count", &ok)
        check(code("HostsController.swift").contains("if hostStore.loadStatus == .clean { counts[\"Hosts\"]"),
              "W12: an unreadable hosts.json reads as 'Hosts 0'", &ok)
        check(code("ReviewController.swift").contains("if !isTotalFailure { onReadyToMergeCountChanged?("),
              "W14: a scan that reached no forge withdraws the bell's ready-to-merge row", &ok)
        check(code("CompactMode.swift").contains("forName: .NSCalendarDayChanged"),
              "W15: the menu-bar overdue count does not turn over at midnight", &ok)
        check(code("ScheduleRunner.swift").contains("publishSetupStepResults(answers, gatheredAt: startedAt)"),
              "W17: the scheduled drift check does not publish what it read", &ok)
        check(code("UpdatesController.swift").contains("caption: \"Tools tracked\""),
              "W2: the catalog's size is captioned as if every tool were installed", &ok)
    }
}

#endif
