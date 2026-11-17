// Grand Line - native macOS app.
//
// R5-UX-08 of review #5: errors should say what to do, everywhere, the way
// Setup's and the Schedules page's do.
//
// A schedule that fails cannot be recorded without saying what failed, why,
// and what the captain can do about it (`ScheduleActionResult(failing:...)`,
// rendered as three captioned fields by the run log). The Health page's
// "Last error: gh: could not reach api.github.com" and the Updates page's
// "Check failed" said only the middle part. This turns the raw error those
// pages already hold into the same three parts, `ScheduleFailureExplanation`,
// so every failure surfaced in a row reads the same way.
//
// Pure: it reads the error text a page already has, never runs anything, and
// says only what that text supports - an error it cannot classify gets the
// page's own general next step rather than an invented diagnosis.

import Foundation

enum FailureExplainer {

    /// What an error's own text says went wrong, as far as it says.
    enum Cause: Equatable {
        case network
        case signedOut
        case diskFull
        case permission
        case timedOut
        case missingTool
        case unknown
    }

    /// Reads the cause from an error's text. The first match wins, in an
    /// order that puts the most specific reading first.
    static func cause(of text: String) -> Cause {
        let t = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { t.contains($0) } }
        if has("no space left", "disk full", "out of space") { return .diskFull }
        if has("not found on path", "command not found", "no such file or directory", "homebrew not found") {
            return .missingTool
        }
        if has("authentication failed", "bad credentials", "401", "403", "not logged in", "gh auth login",
               "could not read username", "permission denied (publickey)") {
            return .signedOut
        }
        if has("permission denied", "operation not permitted", "read-only file system") { return .permission }
        if has("timed out", "timeout", "time out", "stopped after") { return .timedOut }
        if has("could not reach", "could not resolve host", "network is unreachable", "connection refused",
               "connection reset", "offline", "not connected to the internet", "unable to access") {
            return .network
        }
        return .unknown
    }

    // MARK: A background service (the Health page)

    /// A background service's last failure, in three parts. `canRetry` is
    /// whether its row offers Retry, so the next step names a button that
    /// is really there.
    static func explain(service: HealthService, detail: String, canRetry: Bool) -> ScheduleFailureExplanation {
        let again = canRetry ? "press Retry" : "wait for its next pass"
        let next: String
        switch cause(of: detail) {
        case .network:
            next = "Check your connection, then \(again)."
        case .signedOut:
            next = "Sign in again with gh auth login in a terminal, then \(again)."
        case .diskFull:
            next = "Free some disk space, then \(again)."
        case .permission:
            next = "Check Grand Line can write to its folders, then \(again)."
        case .timedOut:
            next = "It may have been slow rather than broken: \(again)."
        case .missingTool:
            next = "Install the missing tool from \(PlaceName.of(.bootstrap)), then \(again)."
        case .unknown:
            next = service.generalNextStep(again: again)
        }
        return ScheduleFailureExplanation(whatFailed: service.whatFailed, why: sentence(detail), whatToDo: next)
    }

    // MARK: A tool's check (the Updates page)

    /// A tool whose check or update failed, in three parts. `detail` is the
    /// row's own reason (`CheckOutcome.detail`), and `log` its output.
    static func explain(tool name: String, status: DependencyStatus, detail: String, log: String)
        -> ScheduleFailureExplanation {
        let whatFailed = status == .updateFailed
            ? "\(name) couldn\u{2019}t be updated."
            : "\(name) couldn\u{2019}t be checked for updates."
        let next: String
        // The row's own button for trying again.
        let again = status == .updateFailed ? "Update" : "Check"
        switch cause(of: detail + "\n" + log) {
        case .network:
            next = "Check your connection, then press \(again). Nothing was changed."
        case .signedOut:
            next = "Sign in again with gh auth login in a terminal, then press Check."
        case .missingTool:
            next = "Install it from \(PlaceName.of(.bootstrap)), or check your shell's PATH, then press Check."
        case .diskFull:
            next = "Free some disk space, then press Check."
        case .permission:
            next = "Run the update in Terminal, where it can ask for your password."
        case .timedOut:
            next = "It may have been slow rather than broken: press \(again) to try again."
        case .unknown:
            next = log.isEmpty
                ? "Press \(again) to try again. If it keeps failing, run the tool's own version command in Terminal."
                : "Read the output in this tool's details for the cause, then press \(again) to try again."
        }
        return ScheduleFailureExplanation(whatFailed: whatFailed, why: sentence(detail), whatToDo: next)
    }

    /// The error as a sentence: trimmed, with a full stop. Not capitalised,
    /// because it so often starts with a command's own name ("gh: ...").
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No reason was recorded." }
        return ".!?\u{2026}".contains(trimmed.last ?? " ") ? trimmed : trimmed + "."
    }
}

extension ScheduleFailureExplanation {
    /// The three parts on one line, for a row's subtitle or a tooltip:
    /// the reason, then the next step.
    var rowLine: String { "\(why) \(whatToDo)" }

    /// A row whose status column already says it failed: the next step
    /// first, so a one-line subtitle that truncates loses the error text
    /// (still in its tooltip) rather than the thing to do about it.
    func rowLine(failedAt when: String) -> String { "\(whatToDo) Last error \(when): \(why)" }
}

extension HealthService {
    /// What a failure of this service means for the captain, about the task
    /// rather than the code.
    var whatFailed: String {
        switch self {
        case .backgroundSignals: return "The background check of tool updates, forks, Vault and setup drift didn\u{2019}t finish."
        case .fleetTasks: return "The fleet\u{2019}s task state couldn\u{2019}t be read."
        case .shiftGitSync: return "Tasks, runbooks or commands couldn\u{2019}t be synced to your config repo."
        case .dotfilesAutoSync: return "Dotfile edits couldn\u{2019}t be committed and pushed."
        case .docsSync: return "The DevOps Playbook and runbooks couldn\u{2019}t be pulled."
        case .shiftDueItems: return "A due-item reminder couldn\u{2019}t be delivered."
        case .persistence: return "A change couldn\u{2019}t be saved to disk."
        case .scheduledAutomations: return "A scheduled automation didn\u{2019}t finish."
        }
    }

    /// The next step when the error's text does not say more.
    func generalNextStep(again: String) -> String {
        switch self {
        case .shiftGitSync, .dotfilesAutoSync:
            return "Run git status in the config repo to see what is in the way, then \(again)."
        case .scheduledAutomations:
            return "Open \(PlaceName.of(.schedules)) and the run\u{2019}s history for its full report."
        case .persistence:
            return "Make the change again. If it fails again, Copy diagnostics on this page has the app\u{2019}s own error log."
        case .shiftDueItems:
            return "Check that notifications for Grand Line are allowed in System Settings."
        default:
            return "\(again.prefix(1).uppercased() + again.dropFirst()). If it keeps failing, Copy diagnostics on this page has the details."
        }
    }
}
