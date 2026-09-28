// Grand Line - native macOS app.
//
// X11 (review UX): every AI surface says where the captain's data goes.
//
// The finding was that the daily review's "Generated locally · no data left
// this Mac" was the app's only such line, so the single visible claim about
// data was made by the one surface that sends none, while the Reading List's
// AI summary and the Straw Hat crew - which both send the captain's own
// material to Claude - said nothing.
//
// **Pure logic, no window or view hierarchy.** It reads the app's own
// sources and compares two strings, so it is deliberately not in
// `NEEDS_SESSION` and guards the blocking CI job. The *rendered* half - that
// the Reading List's line reaches a real card in the right three states, and
// nowhere else - is `ReadingListViewSelfTest.checkAISummarySaysWhereTheTextWent`,
// which is window-backed and lives there for that reason.
//
// What this file adds that a rendered check cannot: the claim and the
// behaviour are compared. A file that says "no data left this Mac" must not
// reach an AI runner, and a file that reaches one must say so. That is the
// only kind of check worth having on a sentence like this - an unverified
// trust line is not decoration, it is a promise.
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

        checkTheTwoClaimsAreDifferentSentences(check)
        checkEverySurfaceStatesItsOwnClaim(check)
        checkALocalClaimReachesNoAIRunner(check)

        if failures.isEmpty {
            print("AITransparencySelfTest: OK")
            return true
        }
        print("AITransparencySelfTest: \(failures.count) failure(s)")
        for f in failures { print("  - \(f)") }
        return false
    }

    /// The cheapest way for this feature to become worthless is a refactor
    /// that collapses the two claims into one string, at which point every
    /// surface says the same thing and one of them is lying.
    private static func checkTheTwoClaimsAreDifferentSentences(_ check: (Bool, String) -> Void) {
        let sent = AITransparency.sentToClaude("this page's text")
        check(!AITransparency.local.isEmpty && !sent.isEmpty, "a claim is empty")
        check(AITransparency.local != sent, "the local and sent-to-Claude claims are the same sentence")
        check(AITransparency.local.lowercased().contains("no data left this mac"),
              "the local claim no longer says data stayed here: \(AITransparency.local)")
        check(sent.lowercased().contains("left this mac") && !sent.lowercased().contains("no data"),
              "the sent-to-Claude claim does not say material left the machine: \(sent)")
        check(AITransparency.willSendToClaude("x").lowercased().contains("sends"),
              "the future-tense claim is not in the future tense: \(AITransparency.willSendToClaude("x"))")
        check(!AITransparency.willSendToClaude("x").lowercased().contains("left this mac"),
              "a button that has sent nothing claims something already left this Mac")
    }

    /// Each of the three surfaces states a claim, and states it through
    /// `AITransparency` rather than as its own literal - which is what keeps
    /// them one voice.
    private static func checkEverySurfaceStatesItsOwnClaim(_ check: (Bool, String) -> Void) {
        let expected: [(file: String, needle: String, why: String)] = [
            ("DailyReviewCard.swift", "AITransparency.local",
             "the daily review's own line, the one the review called out as worth copying"),
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

        // The old hand-written literal must not come back beside the shared
        // one, or the two drift and the app says two things.
        if let card = source("DailyReviewCard.swift") {
            check(!card.contains("\"Generated locally"),
                  "DailyReviewCard re-inlined its trust line instead of taking it from AITransparency")
        }
    }

    /// The half that makes the sentences mean something: a surface claiming
    /// the work happened here must not reach the app's one AI runner.
    ///
    /// `ClaudeOneShot` is that runner (GL-26), and the app has exactly one,
    /// so "reaches an AI" is a single needle rather than a list that could
    /// go stale.
    private static func checkALocalClaimReachesNoAIRunner(_ check: (Bool, String) -> Void) {
        // Assert the needle can fail before trusting a clean answer: a
        // surface that genuinely does reach the runner has to read as
        // reaching it.
        guard let crew = source("StrawHatRunner.swift") else {
            check(false, "could not read StrawHatRunner.swift - the needle is unverified")
            return
        }
        check(crew.contains("ClaudeOneShot"),
              "StrawHatRunner no longer mentions ClaudeOneShot - the needle below would pass vacuously")

        for file in ["DailyReviewCard.swift", "DailyReviewData.swift", "DailyReviewCalendar.swift"] {
            guard let body = source(file) else {
                check(false, "could not read \(file) - this guard cannot run")
                continue
            }
            check(!body.contains("ClaudeOneShot"),
                  "\(file) reaches the AI runner while the daily review card claims "
                  + "\"\(AITransparency.local)\" - one of the two is now false")
        }
    }

    private static func source(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }
}

#endif
