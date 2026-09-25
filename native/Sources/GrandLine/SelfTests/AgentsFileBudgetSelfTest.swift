// Grand Line - native macOS app.
//
// Process issue P7 of the 2026-09-25 review: "`AGENTS.md` is 139KB, about 35K
// tokens, imported into every session, and growing again".
//
// `CLAUDE.md` is one line - `@AGENTS.md` - so every agent session in this
// repository pays for every byte of that file before it reads a line of code.
// It was touched in 68 of the last 80 commits, and its own "Maintaining this
// file" section had already told everybody not to append to it, three sections
// before this review counted three sections that had been appended anyway.
//
// A convention that has been ignored that consistently is not a convention, so
// this is the budget as a check. It is deliberately the crudest possible
// measure - one number, one file - because anything cleverer becomes a thing
// to argue with rather than a line to stay under.
//
// **When this fails, the fix is almost never to raise the number.** The
// question the file's own last section asks is which of two homes a paragraph
// belongs in: a rule that will still be true after the next three features
// belongs here, and an account of what one branch did, measured, tried first
// and deliberately left out belongs in `docs/history/`, which no session
// imports. P7's own fix is the worked example - the gotcha catalogue kept its
// 22 rules and its 22 headings here, and its 50KB of measurement narrative
// moved to `docs/history/47-appkit-gotchas.md` verbatim.
//
// Raising it is a real option, but it is a decision about what every future
// session pays, so it wants a sentence in the PR saying what was added and why
// it could not be history.
//
// Pure logic and one file read - no window, no session. Deliberately NOT in
// `NEEDS_SESSION`, so it guards CI's blocking lane.
#if FM_SELFTESTS

import Foundation

enum AgentsFileBudgetSelfTest {

    /// The ceiling, in bytes.
    ///
    /// P7 measured 139KB (142,336 bytes) and this branch's split brought it to
    /// about 108KB. The budget is 120,000 - roughly 11KB of headroom, which is
    /// a few genuine standing rules and not another section.
    private static let budget = 120_000

    /// A floor as well, because a guard that only has a ceiling passes
    /// perfectly when somebody deletes the file, and this one's whole subject
    /// is a file that is read rather than compiled.
    private static let floor = 40_000

    static func run() -> Bool {
        var ok = true
        print("== AgentsFileBudgetSelfTest ==")
        ok = checkAgentsFileIsWithinBudget() && ok
        print(ok ? "AgentsFileBudgetSelfTest: OK" : "AgentsFileBudgetSelfTest: FAILED")
        return ok
    }

    private static func checkAgentsFileIsWithinBudget() -> Bool {
        var ok = true
        guard let appDir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not next to this binary")
            return true
        }
        // .../Sources/GrandLine -> .../Sources -> native/ -> the repo root.
        let repoRoot = appDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let agents = repoRoot.appendingPathComponent("AGENTS.md")

        guard let data = try? Data(contentsOf: agents) else {
            fail("AGENTS.md not readable at \(agents.path)", &ok)
            return ok
        }
        let size = data.count
        print("  AGENTS.md: \(size) bytes, budget \(budget)")

        check(size >= floor,
              "AGENTS.md is \(size) bytes, below the \(floor) floor - this guard is "
              + "measuring the wrong file, or the standing rules have been deleted", &ok)
        check(size <= budget,
              "AGENTS.md is \(size) bytes, over the \(budget)-byte budget by "
              + "\(size - budget). Every agent session in this repository imports this "
              + "file, so the fix is normally to move an account of what one branch did "
              + "into docs/history/ (which nothing imports) and keep only the standing "
              + "rule here - not to raise the number. See AGENTS.md's own "
              + "\"Maintaining this file\" section.",
              &ok)

        // `CLAUDE.md` is the reason the number matters: it imports this file
        // into every session. If that import ever goes away, this guard is
        // measuring something nobody pays for and should be reconsidered
        // rather than left quietly passing.
        if let claude = try? String(contentsOf: repoRoot.appendingPathComponent("CLAUDE.md"),
                                    encoding: .utf8) {
            check(claude.contains("@AGENTS.md"),
                  "CLAUDE.md no longer imports AGENTS.md - this budget's premise has changed", &ok)
        }
        return ok
    }
}

#endif
