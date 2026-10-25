// Grand Line - native macOS app.
//
// X11 (review UX): every AI surface says where the captain's data goes.
//
// The finding was that the daily review's "Generated locally · no data left
// this Mac" was the app's only such line, while the Reading List's AI summary
// and the Straw Hat crew - which both send the captain's own material to
// Claude - said nothing. (That card, and its local claim, were removed with
// the Today page.)
//
// **Pure logic, no window or view hierarchy.** It reads the app's own
// sources and compares two strings, so it is deliberately not in
// `NEEDS_SESSION` and guards the blocking CI job. The *rendered* half - that
// the Reading List's line reaches a real card in the right three states, and
// nowhere else - is `ReadingListViewSelfTest.checkAISummarySaysWhereTheTextWent`,
// which is window-backed and lives there for that reason.
//
// What this file adds that a rendered check cannot: every surface that sends
// states the claim through `AITransparency`, in the right tense. An
// unverified trust line is not decoration, it is a promise.
//
// Run with:
//   swift build && FM_RUN_AI_TRANSPARENCY_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum AITransparencySelfTest {

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        checkTheClaimsSayWhereTheTextWent(check)
        checkEverySurfaceStatesItsOwnClaim(check)
        checkEveryAICallerHasASurfaceThatSaysSo(check)

        if failures.isEmpty {
            print("AITransparencySelfTest: OK")
            return true
        }
        print("AITransparencySelfTest: \(failures.count) failure(s)")
        for f in failures { print("  - \(f)") }
        return false
    }

    /// The past-tense claim says the material left, and the future-tense one
    /// says it will be sent without claiming it already has.
    private static func checkTheClaimsSayWhereTheTextWent(_ check: (Bool, String) -> Void) {
        let sent = AITransparency.sentToClaude("this page's text")
        check(!sent.isEmpty, "the sent-to-Claude claim is empty")
        check(sent.lowercased().contains("left this mac") && !sent.lowercased().contains("no data"),
              "the sent-to-Claude claim does not say material left the machine: \(sent)")
        check(AITransparency.willSendToClaude("x").lowercased().contains("sends"),
              "the future-tense claim is not in the future tense: \(AITransparency.willSendToClaude("x"))")
        check(!AITransparency.willSendToClaude("x").lowercased().contains("left this mac"),
              "a button that has sent nothing claims something already left this Mac")
    }

    /// Each surface that sends states a claim, and states it through
    /// `AITransparency` rather than as its own literal - which is what keeps
    /// them one voice.
    private static func checkEverySurfaceStatesItsOwnClaim(_ check: (Bool, String) -> Void) {
        let expected: [(file: String, needle: String, why: String)] = [
            ("ReadingListCardView.swift", "AITransparency.sentToClaude",
             "the AI summary, which sends the page's text"),
            ("ReadingListCardView.swift", "AITransparency.willSendToClaude",
             "the Summarise button, before it sends anything"),
            ("StrawHatChatView.swift", "AITransparency.sentToClaude",
             "the crew, which sends what the captain types and what it reads from the stores"),
        ]
        for (file, needle, why) in expected {
            guard let body = source(file) else {
                check(false, "could not read \(file) - this guard cannot run")
                continue
            }
            check(body.contains(needle), "\(file) no longer states \(needle) - \(why)")
        }
    }

    /// R2-SEC-05: every file that runs `claude -p`, and the file holding the
    /// control that starts it. Each of those controls says, through
    /// `AITransparency.willSendToClaude`, what it is about to send. A twelfth
    /// caller fails here until it names its surface.
    static let aiCallers: [String: [String]] = [
        "CommandLibraryAI.swift": ["CommandLibraryViews.swift", "CommandLibraryAIPopover.swift"],
        "ConsoleCommandComposer.swift": ["ConsoleController+Toolbar.swift", "ConsoleComposerPopover.swift"],
        "DictationCleanup.swift": ["DictationController.swift"],
        "LogAnalyzerAI.swift": ["LogAnalyzerController.swift"],
        "MorningBriefingData.swift": ["MorningBriefingCard.swift"],
        "ReadingListAI.swift": ["ReadingListCardView.swift"],
        "ShiftQuickCapture.swift": ["ShiftQuickCapture.swift"],
        "SRELeadPostmortem.swift": ["ConsoleController+SRELead.swift"],
        "SRELeadRunner.swift": ["SRELeadChatView.swift"],
        "StrawHatRunner.swift": ["StrawHatChatView.swift"],
        "WhiteboardDiagram.swift": ["WhiteboardController.swift"],
    ]

    private static func checkEveryAICallerHasASurfaceThatSaysSo(_ check: (Bool, String) -> Void) {
        guard let files = SelfTestSources.appSourceFiles(), files.count > 50 else {
            check(false, "could not list the app's sources - this guard cannot run")
            return
        }
        let callers = files.filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("ClaudeOneShot.run(") == true }
            .map(\.lastPathComponent)
        check(callers.count >= 11, "fixture: found \(callers.count) claude -p callers - the scan is not seeing the app")
        for caller in callers {
            guard let surfaces = aiCallers[caller] else {
                check(false, "R2-SEC-05: \(caller) runs claude -p and names no surface that tells the captain")
                continue
            }
            for surface in surfaces {
                check(source(surface)?.contains("AITransparency.willSendToClaude(") == true,
                      "R2-SEC-05: \(surface) starts \(caller)'s claude -p call without saying what it sends")
            }
        }
    }

    private static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }
}

#endif
