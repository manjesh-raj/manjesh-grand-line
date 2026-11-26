// Grand Line - native macOS app.
//
// UX-08 of the 2026-11-25 full review: Ask the crew starts with things to
// ask. The page was an empty box with a prompt at the bottom; the inspector's
// small crew panel offered three starter questions and the full page none.
// The empty page now offers six, each drawn from the captain's own data where
// it has any (overdue tasks, the follow-ups waiting on someone, a failing
// service), and a plain question where it does not.
//
// Pure: every input is a count or a name the page already holds, so the
// questions are asserted in CI's blocking lane. A starter fills the composer
// rather than sending, so nothing reaches Claude without the captain's Return.

import Foundation

enum StrawHatStarters {

    struct Starter: Equatable {
        /// The question the composer is filled with.
        let question: String
        /// Where it comes from, under the question.
        let detail: String
    }

    /// What the page knows when it builds the starters.
    struct Input: Equatable {
        var openTasks = 0
        var overdueTasks = 0
        var dueToday = 0
        var pendingFollowUps = 0
        /// The worst failing service's name, when one is failing.
        var failingService: String?
        var servicesReporting = 0
        var schedules = 0
    }

    static let count = 6

    static func make(_ input: Input) -> [Starter] {
        var starters: [Starter] = []
        func tasks(_ n: Int) -> String { n == 1 ? "1 open task" : "\(n) open tasks" }
        if input.overdueTasks > 0 {
            starters.append(.init(question: "What is overdue, and what can wait?",
                                  detail: "From your \(tasks(input.openTasks))"))
        } else if input.openTasks > 0 {
            starters.append(.init(question: "What should I do first today?",
                                  detail: input.dueToday > 0 ? "\(input.dueToday) due today, of \(tasks(input.openTasks))"
                                      : "From your \(tasks(input.openTasks))"))
        } else {
            starters.append(.init(question: "Help me get started on this week",
                                  detail: "Writes tasks you confirm"))
        }
        starters.append(.init(question: "Plan my week from the board", detail: "Writes a draft you confirm"))
        if let failing = input.failingService {
            starters.append(.init(question: "Why does \(failing) keep failing?", detail: "From Health's last error"))
        } else {
            starters.append(.init(question: "Is anything on this Mac unhealthy?",
                                  detail: input.servicesReporting > 0
                                      ? "From Health's \(input.servicesReporting) services" : "From Health"))
        }
        starters.append(.init(question: "Summarise what changed since Monday", detail: "From the log and your notes"))
        if input.pendingFollowUps > 0 {
            starters.append(.init(question: "Who am I waiting on?",
                                  detail: input.pendingFollowUps == 1 ? "From your 1 follow-up"
                                      : "From your \(input.pendingFollowUps) follow-ups"))
        } else {
            starters.append(.init(question: "Turn an idea into tasks", detail: "Usopp drafts, you confirm"))
        }
        starters.append(.init(question: "What could I automate?",
                              detail: input.schedules > 0 ? "From your \(input.schedules) schedules and saved commands"
                                  : "From your saved commands"))
        return starters
    }
}
