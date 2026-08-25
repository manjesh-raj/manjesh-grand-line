// Manjesh Grand Line - native macOS app.
//
// F7 (`fm/grandline-feature-f7-answer-crew-from-cockpit`, production-readiness
// review section 25's own highest-priority pure feature): the *write* half of
// Overview. `FleetData.swift` is read-only against firstmate's state; this is
// the one place the app writes back into it, and the review names it exactly -
// "one new `FleetActions` source next to `FleetData`".
//
// ## Two channels, and why they are not the same channel
//
// The channel was settled with the firstmate side before any of this was
// written, and the split is not an implementation detail:
//
//  - **Answering a specific task** goes through `bin/fm-send.sh <task-id>
//    [--resolve-key <key>] "<text>"`, firstmate's own *verified* submit: it
//    types the line once, sends Enter, retries only the Enter, and reads back
//    whether the submit actually landed (read that script's header before
//    touching anything here - its exit-status contract is not the usual
//    zero/nonzero, see `FleetReplyOutcome`). It is also what closes the
//    captain-facing decision record, through `--resolve-key`.
//  - **A general "message the first mate"** has no task id to address, so
//    there is nothing for `fm-send.sh` to target. It goes through the proven
//    terminal-injection path instead (`ConsoleController.sendToFirstmateMirror`
//    -> `TerminalView.send(txt:)`), the same call Snippets' "Run" and the SRE
//    Lead bridge already use. That path is deliberately not in this file: it
//    is a terminal write owned by `ConsoleController`, and keeping the two
//    apart is what makes "the general message never shells out to fm-send"
//    checkable rather than a claim (`FleetActionsSelfTest`).
//
// ## No AI anywhere
//
// The reply is exactly what the captain typed, byte for byte. There is no
// rewrite, cleanup or summarisation pass - this is a plain composer, not a
// Dictation-cleanup-shaped feature.

import Foundation

// MARK: - Decision keys

/// One still-open keyed decision on a task, as firstmate's own status ledger
/// reports it. `key` is what `fm-send.sh --resolve-key` closes.
struct FleetDecision: Equatable {
    /// The slug from a `[key=<slug>]` token, or `"default"` for a line that
    /// stated no key (firstmate's own historical one-decision-per-task
    /// bucket - a real, closable key, not a placeholder).
    let key: String
    /// `needs-decision` or `blocked` - which verb opened it.
    let verb: String
    /// The line's own note, with a consumed key token stripped.
    let note: String
}

/// A narrow Swift port of `bin/fm-classify-lib.sh`'s `status_open_decisions`
/// fold - the *only* thing this app needs from that library, and deliberately
/// not a second general-purpose status-log parser (`FleetData.swift`'s
/// `fm-crew-state.sh` shell-out stays the authoritative current-state read).
///
/// The grammar is that library's, not this app's, so it is restated here
/// rather than approximated:
///
///  - the verb is the text before the first colon, cut at the first `[` and
///    trimmed, so `needs-decision [key=x]: why` and `needs-decision: why` both
///    read `needs-decision`;
///  - a complete `[key=<slug>]` token **before the first colon** states the
///    key; failing that, a complete token at the **head of the note** states
///    it (a common real-worker shape whose stated key must not silently
///    collapse into `default`); a token deeper inside the note is prose;
///  - a stated slug outside `[A-Za-z0-9._-]` is rejected and the whole line is
///    skipped - never rewritten to `default`;
///  - `needs-decision` / `blocked` open a key (re-opening replaces),
///    `resolved` / `captain-held` close it;
///  - a reserved namespace (`pending-reply-`) may only be moved by a line
///    whose note itself begins `<namespace>...:`, so an unrelated line cannot
///    take over or clear another library's decision.
enum FleetStatusDecisions {

    static let reservedKeyPrefixes = ["pending-reply-"]

    /// The still-open decisions in a status stream, oldest-opened first.
    static func open(inStatusText text: String) -> [FleetDecision] {
        // A plain array, not a dictionary: the fold's own output order
        // (most-recently-opened last) is what the caller reasons about.
        var open: [FleetDecision] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let key = decisionKey(line) else { continue }   // invalid slug: skip the line
            let note = self.note(line)
            guard transitionAllowed(key: key, note: note) else { continue }
            switch verb(line) {
            case "needs-decision", "blocked":
                open.removeAll { $0.key == key }
                open.append(FleetDecision(key: key, verb: verb(line), note: note))
            case "resolved", "captain-held":
                open.removeAll { $0.key == key }
            default:
                break
            }
        }
        return open
    }

    /// `status_line_verb`: the leading word, ending at the first colon or the
    /// first `[`-tag, whichever comes first.
    static func verb(_ line: String) -> String {
        var v = line.components(separatedBy: ":").first ?? line
        if let bracket = v.firstIndex(of: "[") { v = String(v[v.startIndex..<bracket]) }
        return v.trimmingCharacters(in: .whitespaces)
    }

    /// `status_line_note`: everything after the first colon, trimmed, with a
    /// key-stating note-head token removed (it is key metadata, not text).
    static func note(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        var n = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if keyBeforeColon(line) == nil,
           let head = keyAtNoteHead(line), slugOK(head) {
            n = String(n.dropFirst("[key=\(head)]".count)).trimmingCharacters(in: .whitespaces)
        }
        return n
    }

    /// `_fm_decision_key`: the stated key, `"default"` when none is stated, or
    /// `nil` when a key *was* stated with an invalid slug (the fold skips that
    /// line entirely rather than treating it as `default`).
    static func decisionKey(_ line: String) -> String? {
        if let k = keyBeforeColon(line) { return slugOK(k) ? k : nil }
        guard let k = keyAtNoteHead(line) else { return "default" }
        return slugOK(k) ? k : nil
    }

    private static func keyBeforeColon(_ line: String) -> String? {
        let head = line.components(separatedBy: ":").first ?? line
        return extractKeyToken(head)
    }

    private static func keyAtNoteHead(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rest = String(line[line.index(after: colon)...]).drop(while: { $0 == " " || $0 == "\t" })
        guard rest.hasPrefix("[key=") else { return nil }
        return extractKeyToken(String(rest))
    }

    /// The slug inside the first complete `[key=...]` token in `text`.
    private static func extractKeyToken(_ text: String) -> String? {
        guard let start = text.range(of: "[key=") else { return nil }
        let after = text[start.upperBound...]
        guard let close = after.firstIndex(of: "]") else { return nil }
        return String(after[after.startIndex..<close])
    }

    private static func slugOK(_ slug: String) -> Bool {
        guard !slug.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return slug.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func transitionAllowed(key: String, note: String) -> Bool {
        for prefix in reservedKeyPrefixes where key.hasPrefix(prefix) {
            // The owner states its own vocabulary by beginning the note
            // `<namespace>...:`. Anything else is ordinary status, not a
            // transition on this key.
            guard note.hasPrefix(prefix), note.contains(":") else { return false }
        }
        return true
    }
}

// MARK: - Send outcome

/// `bin/fm-send.sh`'s exit-status contract, which is deliberately **not** the
/// usual zero-or-broken shape - read that script's header. Collapsing the
/// middle case into either neighbour would be a lie in one direction or the
/// other, which is the whole reason this is an enum rather than a `Bool`.
enum FleetReplyOutcome: Equatable {
    /// Exit 0: the submit was read back and confirmed. Any `--resolve-key`
    /// passed has been closed by `fm-send` itself.
    case confirmed
    /// Exit 3: the text was typed into the live endpoint and Enter was sent,
    /// but the submit read-back stayed unconfirmed. Not a proven failure and
    /// **never** a reason to resend blindly - the script's own instruction is
    /// to look at the pane first.
    case sentUnconfirmed(String)
    /// Any other nonzero, a timeout, or a failure to launch at all: nothing
    /// may be assumed delivered.
    case failed(String)

    /// What the captain is told. Distinct per case on purpose - the acceptance
    /// bar for this feature is that a send is never reported as a blanket
    /// "sent!" regardless of what `fm-send` actually said.
    var message: String {
        switch self {
        case .confirmed:
            return "Reply delivered to the crew."
        case .sentUnconfirmed:
            return "Reply typed and sent, but the crew didn't confirm it - check the Herdr tab before resending."
        case .failed(let reason):
            return "Reply not sent: \(reason)"
        }
    }

    /// Whether the composer should clear and collapse. An unconfirmed send did
    /// reach the endpoint, so re-typing it is exactly what the script warns
    /// against; a genuine failure keeps the captain's text so it can be
    /// retried without re-typing.
    var clearsComposer: Bool {
        switch self {
        case .confirmed, .sentUnconfirmed: return true
        case .failed: return false
        }
    }
}

// MARK: - Actions

enum FleetActions {

    /// `fm-send.sh` verifies its own submit with retries, so it is legitimately
    /// slower than a status read - but it is still bounded, like every other
    /// subprocess in this app (GL-02).
    static let sendTimeout: TimeInterval = 90

    /// Test seam: the self-test cannot run the real script (it would try to
    /// reach a live firstmate session and steer a real crewmate), so it points
    /// this at a disposable fake that reproduces the exit-status contract -
    /// the same shape as `DictationCleanup.claudePathOverrideForTests`.
    static var sendScriptOverrideForTests: String?

    static var sendScriptPath: String {
        sendScriptOverrideForTests ?? FirstmateHome.bin.appendingPathComponent("fm-send.sh").path
    }

    // MARK: Decision keys for one task

    static func statusFileURL(taskID: String) -> URL {
        FirstmateHome.state.appendingPathComponent("\(taskID).status")
    }

    /// Every still-open decision on `taskID`, read live from its status file.
    static func openDecisions(taskID: String) -> [FleetDecision] {
        guard let text = try? String(contentsOf: statusFileURL(taskID: taskID), encoding: .utf8) else { return [] }
        return FleetStatusDecisions.open(inStatusText: text)
    }

    /// The key this reply should close, or `nil` for a plain steer.
    ///
    /// **Exactly one open decision, or no key at all.** With two or more open,
    /// which one an answer settles is genuinely ambiguous, and guessing would
    /// close the wrong record; the brief's rule is to send without the flag
    /// rather than guess. Note the failure mode of a *stale* key is not a
    /// mis-send but a refusal: `fm-send` validates the key against the same
    /// ledger and exits before sending anything, so `reply` re-reads this at
    /// send time rather than trusting a snapshot taken when the page rendered.
    static func resolveKey(taskID: String) -> String? {
        resolveKey(among: openDecisions(taskID: taskID))
    }

    /// The exactly-one rule itself, split out so it is assertable without a
    /// status file on disk.
    static func resolveKey(among open: [FleetDecision]) -> String? {
        open.count == 1 ? open[0].key : nil
    }

    // MARK: The reply

    /// The argv `reply` runs. Pure, so the ordering contract (`--resolve-key`
    /// before the message, exactly as `fm-send.sh`'s usage line states) is
    /// assertable without running anything.
    static func arguments(taskID: String, resolveKey: String?, text: String) -> [String] {
        var args = [sendScriptPath, taskID]
        if let resolveKey { args += ["--resolve-key", resolveKey] }
        args.append(text)
        return args
    }

    /// Map a finished run onto the script's contract. Pure and separate from
    /// `reply` so the three outcomes can be tested without a subprocess.
    static func outcome(for result: SubprocessResult) -> FleetReplyOutcome {
        switch result.outcome {
        case .exited where result.status == 0:
            return .confirmed
        case .exited where result.status == 3:
            return .sentUnconfirmed(result.combinedLog)
        default:
            return .failed(result.failureSummary ?? "fm-send.sh failed")
        }
    }

    /// Send `text` to `taskID`'s crewmate. Blocking - callers run it off the
    /// main thread (`FleetController` does).
    static func reply(taskID: String, text: String) -> FleetReplyOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("nothing to send") }
        // GL-09: a write into the captain's own agent session, gated like
        // every other data-writing surface.
        guard AppLockGate.shared.allows(.crewReply) else {
            return .failed("the app is locked")
        }
        let script = sendScriptPath
        guard FileManager.default.fileExists(atPath: script) else {
            return .failed("fm-send.sh not found at \(script)")
        }
        let key = resolveKey(taskID: taskID)
        let result = Subprocess.run(
            executable: "/bin/bash",
            arguments: arguments(taskID: taskID, resolveKey: key, text: trimmed),
            cwd: FirstmateHome.root,
            extraEnv: ["FM_HOME": FirstmateHome.root.path],
            timeout: sendTimeout,
            label: "fm-send"
        )
        let outcome = outcome(for: result)
        AppLog.subprocess.info("fm-send \(taskID, privacy: .public): \(String(describing: outcome), privacy: .public)")
        return outcome
    }
}
