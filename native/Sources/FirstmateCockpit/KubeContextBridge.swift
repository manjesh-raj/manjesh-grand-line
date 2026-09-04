// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-context-badge`: a context/namespace safety badge on a
// host page's toolbar - the wrong-cluster guard a bastion's own shell prompt
// can never show, since kube-ps1 (the tool this replaces) is a shell
// function and can't be installed on the bastion (see the scout report,
// `data/grandline-k8s-toolkit-scout/report.md`, item 2).
//
// **Why this is a new, lightweight sibling of `SRELeadBridge`, not a reuse of
// it.** `SRELeadBridge` exists to bridge a real cross-process gap:
// `sre_kubectl_mcp.py` (a Python process, itself a subprocess of `claude`)
// and this Swift app have no shared memory, so that whole class - a
// `bridgeDir`, a polling `Timer` watching for `request-<id>.json` files a
// *different process* wrote, JSON files written back as the response - is a
// file-based protocol for bridging two processes. This badge has no AI
// reasoning step and no Python process at all: it always wants to run
// exactly the same two fixed, hardcoded commands
// (`kubectl config current-context` / `kubectl config get-contexts`), and
// the caller (`ConsoleController`) and the consumer of the result (the same
// `ConsoleController`) are the same Swift process. There is nothing for a
// file-based, cross-process protocol to bridge. Standing up a whole
// `SRELeadSession` (which resolves `claude`, resolves python3, writes an MCP
// config, and creates a scratch directory - `SRELead.setUp()`) just to get
// two kubectl commands typed into a tab would also make the badge depend on
// `claude`/python3 being installed and authenticated, which has nothing to
// do with whether `kubectl` itself works - and would show a whole AI chat
// pane opening just to read a context name.
//
// So this class talks to the terminal with the *exact same mechanism*
// `SRELeadBridge` uses - wrap a command with two fresh random markers,
// inject it via `TerminalView.send(txt:)` (`Snippet`'s "Run" action already
// does this, machine-initiated here), poll the terminal's own buffer for the
// end marker, extract the text between the markers as the real output - but
// driven directly in Swift with a completion closure instead of a file-based
// request/response protocol, and with no Python process, no MCP config, and
// no `claude` dependency anywhere in this path. `SRELeadBridgeTerminal` (see
// `SRELeadBridge.swift`) is the exact protocol this reuses - `TabModel`
// already conforms to it, so no new terminal abstraction is needed either.
//
// **Read-only by construction, not by validation.** The two commands this
// class ever sends are Swift string literals - never built from AI output,
// captain-typed text, or any other untrusted input - so there is no
// "argument the tool decided to type" for a character-set/verb allowlist to
// gate, unlike `sre_kubectl_mcp.py`'s `_validate_args` (which exists
// specifically because an AI decides what to type there). `_ALLOWED_VERBS`
// was still widened to include `config get-contexts`/`config
// current-context` (see that file's own header) so the same read-only
// enforcement stays the one place SRE Lead's own AI could also be asked
// about the current context/namespace, but this badge never calls into that
// script or that allowlist at all.
//
// **Cross-bridge collision.** SRE Lead's own `SRELeadBridge` and this class
// can both target the *same* tab at once - a captain can start SRE Lead on
// the very tab whose host also opted into this badge - and the shared
// terminal is one real shell that cannot safely receive two independently-
// injected commands at overlapping moments: injecting a second marker-
// wrapped command mid-way through the first genuinely interleaves keystrokes
// in the real shell, corrupting both commands' output. Each bridge's own
// single-flight tracking (`SRELeadBridge`'s private `inFlight`, this class's
// own `inFlight`) only guards against *itself* running twice concurrently -
// it says nothing about a sibling bridge targeting the same tab.
// `isTerminalBusyElsewhere` (a closure, not a shared property bolted onto
// `TabModel`) is the seam: `ConsoleController` wires each bridge's closure to
// read the *other* bridge's own `isBusy` flag, so neither injects while the
// other is mid-command, without either bridge needing to know the other's
// concrete type. See `SRELeadBridge.isBusy`/`isTerminalBusyElsewhere` for the
// other half of this.

import Foundation

/// The parsed result of one refresh: which context `kubectl` is currently
/// pointed at, and which namespace that context defaults to.
struct KubeContextInfo: Equatable {
    let contextName: String
    let namespace: String

    /// A deliberately simple, explicitly documented HEURISTIC (the task's own
    /// wording) - a case-insensitive substring match on "prod" against the
    /// context name - never a certified environment classification. This
    /// intentionally also flags a context literally named e.g. "preprod-eks"
    /// (it contains "prod" as a substring): erring toward extra caution on a
    /// preprod cluster is judged better than a false sense of safety for a
    /// context that could plausibly BE production-adjacent, and the badge's
    /// own tooltip says plainly that this is a heuristic, not a guarantee.
    var looksLikeProduction: Bool {
        contextName.lowercased().contains("prod")
    }
}

/// Why a refresh did not produce a fresh `KubeContextInfo`. A failure here
/// never clears an already-known-good badge (see
/// `ConsoleController+KubeContextBadge.swift`) - it only means "the badge
/// might be a little stale until the next attempt."
enum KubeContextError: Error, Equatable {
    /// The target tab is gone (closed mid-refresh).
    case unavailable(String)
    /// Refused before injecting anything: the captain is actively typing in
    /// this tab, a refresh is already in flight, or a sibling bridge (SRE
    /// Lead) is currently running its own command on this same tab.
    case busy(String)
    /// The end marker never appeared within `commandTimeout`.
    case timeout
    /// The captain typed into the tab while this refresh was running, so the
    /// output can't be trusted - discarded, matching `SRELeadBridge`'s own
    /// concurrency guard.
    case discarded(String)
    /// Extracted text didn't contain both markers in the expected order -
    /// the tab may have changed unexpectedly.
    case markersNotFound
    /// `kubectl` itself failed or produced unparseable output (e.g. no
    /// current context configured, `kubectl` not on PATH).
    case commandFailed(String)

    var message: String {
        switch self {
        case .unavailable(let m), .busy(let m), .discarded(let m), .commandFailed(let m): return m
        case .timeout: return "timed out waiting for kubectl"
        case .markersNotFound: return "could not find the command's own output markers in the terminal"
        }
    }
}

/// Pure parsing of the two commands' combined output - no terminal/bridge
/// dependency at all, so every shape is covered by a plain unit test.
enum KubeContextParser {

    /// Parses `"kubectl config current-context; echo <separator>; kubectl
    /// config get-contexts"`'s combined output (everything the shared
    /// terminal printed between the bridge's own start/end markers) into a
    /// `KubeContextInfo`, or a `KubeContextError` describing what went wrong.
    static func parse(rawCombinedOutput: String, separator: String) -> Result<KubeContextInfo, KubeContextError> {
        var before: [String] = []
        var after: [String] = []
        var seenSeparator = false
        for line in rawCombinedOutput.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == separator {
                seenSeparator = true
                continue
            }
            if seenSeparator { after.append(line) } else { before.append(line) }
        }

        // `kubectl config current-context` always prints a single bare token
        // (a context name has no whitespace - a DNS-1123-subdomain-like
        // string) with no trailing content on success. Anything else - no
        // output, more than one non-empty line, or a line containing
        // whitespace (an error message, "command not found", ...) - means it
        // failed, and the raw text is surfaced verbatim rather than guessed
        // at as a context name. This structural check is more robust than
        // matching a literal "error:" prefix, since a missing `kubectl`
        // binary produces a shell error with no such prefix at all.
        let currentContextLines = before.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard currentContextLines.count == 1,
              let contextName = currentContextLines.first,
              !contextName.contains(where: { $0.isWhitespace }) else {
            let message = currentContextLines.joined(separator: " ")
            return .failure(.commandFailed(
                message.isEmpty ? "kubectl produced no usable output for 'config current-context'" : message
            ))
        }

        let namespace = namespace(forContext: contextName, inGetContextsOutput: after.joined(separator: "\n"))
        return .success(KubeContextInfo(contextName: contextName, namespace: namespace))
    }

    /// `kubectl config get-contexts`'s table: `CURRENT  NAME  CLUSTER
    /// AUTHINFO  NAMESPACE`, where NAMESPACE is often blank (kubectl leaves
    /// that column empty rather than omitting it when a context has no
    /// namespace explicitly set). Finds the row whose NAME matches
    /// `contextName` and returns its NAMESPACE value, or `"default"` when
    /// that row has no namespace column at all (or the table can't be found/
    /// parsed - a `get-contexts` failure still lets the badge show the
    /// context name alone from `current-context`).
    static func namespace(forContext contextName: String, inGetContextsOutput raw: String) -> String {
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Strip a leading "*" (marks the active context) before
            // splitting into columns, so the column positions line up the
            // same way whether or not this is the row for the currently
            // active context.
            let withoutMarker = trimmed.hasPrefix("*")
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                : trimmed
            let columns = withoutMarker.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Skip the header row and anything shorter than NAME/CLUSTER/
            // AUTHINFO.
            guard columns.count >= 3, columns[0] == contextName else { continue }
            // NAME CLUSTER AUTHINFO [NAMESPACE] - the namespace column is
            // only present at all when this context actually has one set.
            return columns.count >= 4 ? columns[3] : "default"
        }
        return "default"
    }
}

/// The context/namespace badge's refresh mechanism for one tab. See this
/// file's header for the full design reasoning.
final class KubeContextBridge {
    private weak var target: SRELeadBridgeTerminal?
    private var timer: Timer?
    private var inFlight: InFlight?
    /// When the next refresh attempt may fire - `nil` means "never
    /// attempted, go immediately." Set by `report(_:)` after every outcome,
    /// success or failure, so a run of refusals can't retry every single
    /// tick.
    private var nextAttemptAt: Date?

    /// How often to poll the terminal buffer while a refresh is in flight -
    /// this only runs for the brief window between injecting the command and
    /// the end marker appearing (typically well under a second for
    /// `kubectl config`), never continuously the way SRE Lead's own 5Hz poll
    /// does for the life of a whole session.
    static let pollInterval: TimeInterval = 0.3

    /// How often to kick off a fresh, successful refresh while idle.
    ///
    /// Context/namespace changes are rare and always driven by a deliberate
    /// captain action (switching context/namespace by hand) - unlike a live
    /// log tail's near-real-time need, this badge does not need to catch a
    /// change within seconds. Each refresh also visibly types a command into
    /// the tab, so the goal is "feels current" without repeating that in the
    /// tab's own scrollback every few seconds the way a 5-10s log-tail
    /// cadence would. 30s is long enough that a captain watching the tab
    /// never sees the refresh line more often than about once a minute of
    /// active use, and short enough that a context switch is reflected well
    /// within the time it takes to notice and type a first real command.
    let refreshInterval: TimeInterval

    /// How soon to retry after a **busy** refusal specifically (the captain
    /// was typing, or a sibling bridge was mid-command) - much shorter than
    /// `refreshInterval`, since "the tab was busy a moment ago" usually
    /// resolves within a few seconds, and there's no reason to leave the
    /// badge stale for up to a full `refreshInterval` over a refusal that
    /// cost nothing (no command was ever injected). An instance property
    /// with a default (not a `static let`), for the same reason
    /// `refreshInterval` is: a self-test needs to prove the busy-vs-hard-
    /// failure retry cadence actually differs without sleeping for real
    /// wall-clock seconds.
    let busyRetryInterval: TimeInterval

    /// Refused before injecting anything when a captain's real keystroke/
    /// paste landed within this many seconds of a refresh attempt - the same
    /// concept and default `SRELeadBridge.userActivityQuietWindow` uses.
    let userActivityQuietWindow: TimeInterval

    /// Stays comfortably under `SRELeadBridge.commandTimeout`'s own default:
    /// `kubectl config current-context`/`get-contexts` are two of the
    /// cheapest possible kubectl calls (no API server round trip for
    /// current-context, and get-contexts reads only the local kubeconfig),
    /// so a shorter ceiling than SRE Lead's 25s is appropriate - a genuinely
    /// hung shell should fail fast rather than block the next scheduled
    /// refresh for as long as SRE Lead would tolerate for an arbitrary
    /// cluster query.
    let commandTimeout: TimeInterval

    /// Called with every outcome - success or failure - so the caller can
    /// update `TabModel.kubeContextInfo` (only on success; see this file's
    /// header on never clearing an already-known-good badge over a
    /// transient failure) and refresh the toolbar pill when this is the
    /// current tab.
    var onUpdate: ((Result<KubeContextInfo, KubeContextError>) -> Void)?

    /// Read before injecting - `true` when a sibling bridge (SRE Lead's own,
    /// on the same tab) is already mid-command. See this file's header.
    /// Defaults to "never busy elsewhere" so a caller that doesn't wire this
    /// (e.g. a self-test with no SRE Lead session at all) behaves exactly as
    /// if there were no sibling to worry about.
    var isTerminalBusyElsewhere: () -> Bool = { false }

    private struct InFlight {
        let startMarker: String
        let endMarker: String
        let sepMarker: String
        let startedAt: Date
        /// Only lines at or beyond this index (in the buffer snapshot taken
        /// right before injection) are ever searched - matching
        /// `SRELeadBridge.InFlight.searchFromLine`'s exact reasoning: a
        /// marker string that happens to appear earlier in scrollback can
        /// never be mistaken for this refresh's own output.
        let searchFromLine: Int
    }

    init(
        target: SRELeadBridgeTerminal, refreshInterval: TimeInterval = 30, busyRetryInterval: TimeInterval = 5,
        userActivityQuietWindow: TimeInterval = 0.5, commandTimeout: TimeInterval = 15
    ) {
        self.target = target
        self.refreshInterval = refreshInterval
        self.busyRetryInterval = busyRetryInterval
        self.userActivityQuietWindow = userActivityQuietWindow
        self.commandTimeout = commandTimeout
    }

    /// True while this bridge itself has an outstanding refresh - the seam a
    /// sibling bridge on the same tab (`SRELeadBridge`) reads before
    /// injecting its own command. See this file's header.
    var isBusy: Bool { inFlight != nil }

    /// Start the periodic refresh cycle: an immediate first attempt (so the
    /// badge isn't blank until a full `refreshInterval` elapses), then a
    /// repeating poll that both watches an in-flight command and decides
    /// when it's time for the next one.
    func start() {
        stop()
        refreshNow()
        let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inFlight = nil
    }

    /// Attempt a refresh right now, bypassing the `refreshInterval`/
    /// `busyRetryInterval` cooldown (though not the busy/quiet-window
    /// guards) - `start()`'s own first call, and the entry point a self-test
    /// drives directly rather than waiting on the real `Timer` `start()`
    /// schedules (which needs a pumped run loop this codebase's headless
    /// self-test binaries never provide - see `SRELeadBridgeSelfTest`'s own
    /// convention of calling `tick()` by hand for the identical reason).
    func refreshNow() {
        beginRefreshIfDue(force: true)
    }

    // MARK: Polling

    /// Not `private`, for the same reason `SRELeadBridge.tick()` isn't - a
    /// self-test drives this directly instead of relying on `start()`'s
    /// timer.
    func tick() {
        if let current = inFlight {
            checkInFlight(current)
            return
        }
        beginRefreshIfDue(force: false)
    }

    private func beginRefreshIfDue(force: Bool) {
        if !force, let nextAttemptAt, Date() < nextAttemptAt { return }
        beginRefresh()
    }

    private func beginRefresh() {
        // Single-flight, enforced here rather than only by `tick()`'s own
        // "don't call this while `inFlight != nil`" branch - `refreshNow()`
        // is a second entry point into this method (bypassing `tick()`
        // entirely) that a caller (or a self-test) could otherwise call
        // while a refresh is already outstanding, which would overwrite
        // `inFlight` with a second injection and lose track of the first
        // one's own markers/search offset.
        guard inFlight == nil else {
            report(.failure(.busy("a context refresh is already running")))
            return
        }
        guard let target else {
            report(.failure(.unavailable("the connected host's interactive terminal tab is no longer available")))
            return
        }
        guard !isTerminalBusyElsewhere() else {
            report(.failure(.busy("SRE Lead is currently running a command in this tab")))
            return
        }
        let now = Date()
        if let last = target.lastUserActivity, now.timeIntervalSince(last) < userActivityQuietWindow {
            report(.failure(.busy("the tab looks like it's actively being used right now")))
            return
        }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let startMarker = "GL_KUBECTX_START_\(unique)"
        let endMarker = "GL_KUBECTX_END_\(unique)"
        let sepMarker = "GL_KUBECTX_SEP_\(unique)"
        let searchFromLine = target.currentBufferLines().count

        // One injection, one round trip: `;` (not `&&`) so `get-contexts`
        // still runs even if `current-context` fails (no context set), and
        // the separator marker is what splits the two commands' output back
        // apart in `KubeContextParser.parse`.
        let command = "kubectl config current-context; echo \(sepMarker); kubectl config get-contexts"
        target.sendCommand("echo \(startMarker); \(command); echo \(endMarker)\n")
        inFlight = InFlight(startMarker: startMarker, endMarker: endMarker, sepMarker: sepMarker,
                            startedAt: now, searchFromLine: searchFromLine)
    }

    private func checkInFlight(_ current: InFlight) {
        guard let target else {
            finish(.failure(.unavailable("the connected host's interactive terminal tab is no longer available")))
            return
        }
        if Date().timeIntervalSince(current.startedAt) > commandTimeout {
            finish(.failure(.timeout))
            return
        }

        let allLines = target.currentBufferLines()
        guard allLines.count > current.searchFromLine else { return }
        let newLines = Array(allLines[current.searchFromLine...])

        guard let endIdx = newLines.firstIndex(where: { isMarkerLine($0, marker: current.endMarker) }) else {
            return // still running
        }
        guard let startIdx = newLines[..<endIdx].firstIndex(where: { isMarkerLine($0, marker: current.startMarker) }) else {
            finish(.failure(.markersNotFound))
            return
        }

        // Concurrency guard: a real keystroke/paste from the captain at any
        // point after injection means the shared shell's input/output could
        // have interleaved with ours - discard rather than risk returning
        // corrupted output, matching `SRELeadBridge.checkInFlight`'s own rule.
        if let last = target.lastUserActivity, last > current.startedAt {
            finish(.failure(.discarded("the tab received input while the refresh was running")))
            return
        }

        let output = newLines[(startIdx + 1)..<endIdx].joined(separator: "\n")
        finish(KubeContextParser.parse(rawCombinedOutput: output, separator: current.sepMarker))
    }

    private func finish(_ result: Result<KubeContextInfo, KubeContextError>) {
        inFlight = nil
        report(result)
    }

    private func report(_ result: Result<KubeContextInfo, KubeContextError>) {
        switch result {
        case .success:
            nextAttemptAt = Date().addingTimeInterval(refreshInterval)
        case .failure(.busy):
            nextAttemptAt = Date().addingTimeInterval(busyRetryInterval)
        case .failure:
            nextAttemptAt = Date().addingTimeInterval(refreshInterval)
        }
        onUpdate?(result)
    }

    /// A line counts as "the marker itself" only when it is *exactly* the
    /// marker (after trimming whitespace) - the terminal's echo of the typed
    /// input line contains the marker as a substring but is never equal to
    /// it, matching `SRELeadBridge.isMarkerLine`'s own reasoning.
    private func isMarkerLine(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == marker
    }
}
