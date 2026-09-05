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
//
// **`fm/grandline-k8s-badge-fixes`: three real issues from the captain's
// first hands-on test, fixed here rather than rebuilt from scratch.**
//
// (1) Backoff, and a real give-up state. A tab whose `kubectl` can never
// succeed (the common real shape: a plain entry-hop bastion with no
// `kubectl` on PATH at all - see issue 3 below for why that tab even had a
// bridge in the first place) used to retry the identical failing command
// every `busyRetryInterval` (5s) forever, spamming the tab with
// `-bash: kubectl: command not found` lines with no end. `hasStoppedRetrying`
// is the fix: after `maxConsecutiveFailures` **genuine** command failures in
// a row (never a `.busy`/`.discarded` refusal, which cost nothing and say
// nothing about whether `kubectl` itself works), the bridge stops scheduling
// any further automatic attempt and reports one final, distinguishable
// failure so the toolbar can show a clear "unavailable" state instead of a
// stale/flickering one. `start()` - called both to activate the badge for a
// tab and, again, as the captain's own explicit "try again" click from that
// unavailable state - is what resets the count and takes one more shot.
//
// (2) The badge used to render `kubectl config current-context`'s raw
// output verbatim, which for a real AWS EKS context is a whole ARN
// (`arn:aws:eks:us-east-1:682528822458:cluster/raas-prod`) - unreadable at a
// glance, the opposite of what a glanceable safety badge is for.
// `KubeContextInfo.shortLabel` extracts just the `cluster/<name>` suffix for
// that one well-known shape and falls back to the raw string verbatim for
// anything else, so an unfamiliar context name is never mangled - the full
// original string is still always available, as the toolbar button's own
// tooltip.
//
// (3) The opt-in used to be per-HOST: `Host.kubeContextBadgeOptIn` created
// and *started* a bridge for every `.ssh` tab that host ever opened
// (`addTab`), including a plain entry-hop tab with no `kubectl` at all - a
// captain's real setup is one saved "bastion" host whose tabs sometimes reach
// a `kubectl`-capable box further in and sometimes don't, and there is no way
// for this app to tell which tab is which just from how it was opened. That
// mismatch is what produced issue 1's spam in the first place. The badge is
// per-**TAB** now, following `TabModel.sreLead`/`SRELeadTabState`'s own
// precedent exactly: `Host.kubeContextBadgeOptIn` only decides whether a
// tab's toolbar even offers the toggle at all (an *availability* signal, one
// captain-chosen host at a time, unchanged in that respect); actually
// creating a `KubeContextBridge` and starting it is an explicit action the
// captain takes on one specific tab
// (`ConsoleController.activateKubeContextBadge(for:)`, wired to the toolbar
// toggle), never something `addTab` does on its own. A freshly opened or
// duplicated tab therefore always starts inactive, exactly like a fresh
// tab's SRE Lead - see `TabModel.kubeContextBadgeOptIn`'s own doc comment.

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

    /// `fm/grandline-k8s-badge-fixes`, issue 2: a friendly, glanceable name
    /// for the toolbar toggle's own visible text - `contextName` itself is
    /// still what the tooltip shows in full, so nothing is lost, only
    /// decluttered. `KubeContextParser.shortLabel` does the actual work; this
    /// wrapper exists so every caller reaches it the same way `looksLikeProduction`
    /// is already reached, off the parsed value rather than the raw string.
    var shortLabel: String {
        KubeContextParser.shortLabel(for: contextName)
    }
}

/// Why a refresh did not produce a fresh `KubeContextInfo`. A failure here
/// never clears an already-known-good badge on its own (see
/// `ConsoleController+Toolbar.swift`'s `updateKubeContextBadgeControls`/
/// `ConsoleController+Tabs.swift`'s `activateKubeContextBadge`) - it only
/// means "the badge might be a little stale until the next attempt," unless
/// enough of these in a row make the bridge give up entirely
/// (`KubeContextBridge.hasStoppedRetrying`).
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

    /// `fm/grandline-k8s-badge-fixes`, issue 2: extracts a short, glanceable
    /// name out of a context string for the toolbar toggle's own visible
    /// text - the raw string is always still available via
    /// `KubeContextInfo.contextName` (and shown in full as the tooltip).
    ///
    /// The one shape handled specially is a real AWS EKS context name (what
    /// `aws eks update-kubeconfig` writes, and what the captain's own live
    /// bastion actually produces): a full ARN ending in
    /// `cluster/<cluster-name>`, e.g.
    /// `arn:aws:eks:us-east-1:682528822458:cluster/raas-prod` ->
    /// `raas-prod`. Deliberately conservative: only a string that actually
    /// starts with `arn:` and contains a `cluster/` segment is shortened at
    /// all - anything else (a friendly context name like `dev-eks`, a plain
    /// `minikube`, or some other cluster's own ARN shape this app has never
    /// seen) is returned completely unchanged rather than guessed at or
    /// mangled.
    static func shortLabel(for contextName: String) -> String {
        guard contextName.hasPrefix("arn:"), let range = contextName.range(of: "cluster/") else {
            return contextName
        }
        let suffix = contextName[range.upperBound...]
        return suffix.isEmpty ? contextName : String(suffix)
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
    /// The cadence `timer` is currently scheduled at, so
    /// `rescheduleTimerIfNeeded` can leave an already-correct timer alone.
    private var scheduledCadence: Cadence = .none

    /// "Is the page that owns this badge out of sight right now?" - 3.2 of
    /// `data/grandline-full-app-audit/report.md`.
    ///
    /// **This is the correctness half of that fix, and it is a pull rather
    /// than a push on purpose.** A periodic refresh does not merely burn a
    /// wake-up: it *types a visible `kubectl config ...` command into the
    /// captain's own live bastion session*, and it used to do that every
    /// `refreshInterval` whether or not anyone could see the tab - the only
    /// gates were the typing quiet-window and the sibling-bridge busy check,
    /// neither of which knows anything about visibility. Consulting this at
    /// the moment of the attempt (`beginRefreshIfDue`) is what makes "no
    /// command is ever injected into an unseen session" true even if every
    /// visibility *notification* is missed; `refreshGating()`'s push is only
    /// the energy half, killing the timer promptly rather than at the next
    /// scheduled attempt.
    ///
    /// Derived rather than tracked, for the reason
    /// `CockpitTerminalView.refreshDisplayGating` states: a missed signal
    /// then costs at most one stale reading that the next evaluation
    /// corrects, instead of latching a visible badge into a paused state.
    ///
    /// Defaults to "never paused", which is exactly every existing caller's
    /// and self-test's prior behaviour.
    var shouldPauseRefreshes: () -> Bool = { false }

    /// What the timer should be doing. `.dueAt` is a **one-shot** at the
    /// moment the next attempt is actually allowed - the fix for the audit's
    /// other half of 3.2, which is that a fixed 0.3s repeating poll spent
    /// ~1000 wake-ups spinning through each healthy 300s `refreshInterval`
    /// window just to re-read one `Date` comparison.
    private enum Cadence: Equatable {
        case none
        case inFlight
        case dueAt(Date)
    }

    /// How often to poll the terminal buffer while a refresh is in flight -
    /// this only runs for the brief window between injecting the command and
    /// the end marker appearing (typically well under a second for
    /// `kubectl config`), never continuously the way SRE Lead's own 5Hz poll
    /// does for the life of a whole session.
    static let pollInterval: TimeInterval = 0.3

    /// How often to kick off a fresh refresh while the tab keeps succeeding.
    ///
    /// Context/namespace changes are rare and always driven by a deliberate
    /// captain action (switching context/namespace by hand) - unlike a live
    /// log tail's near-real-time need, this badge does not need to catch a
    /// change within seconds. Each refresh also visibly types a command into
    /// the tab, so the goal is "feels current" without repeating that in the
    /// tab's own scrollback every few seconds the way a 5-10s log-tail
    /// cadence would.
    ///
    /// `fm/grandline-k8s-badge-fixes`: raised from 30s to 5 minutes. A
    /// *successful* low-frequency background refresh costs nothing worth
    /// worrying about and genuinely adds value (the badge stays honest
    /// without another explicit click), but the captain's own reported bar
    /// - issue 1 - is "every few minutes, not every 30s"; 30s repeating
    /// visibly in a tab's own scrollback read as noisy even while succeeding.
    let refreshInterval: TimeInterval

    /// How soon to retry after a **busy** refusal specifically (the captain
    /// was typing, a sibling bridge was mid-command, or a refresh was already
    /// running) - much shorter than `refreshInterval`, since "the tab was
    /// busy a moment ago" usually resolves within a few seconds, and there's
    /// no reason to leave the badge stale over a refusal that cost nothing
    /// (no command was ever injected). Unlike a real command failure below,
    /// this never counts toward `maxConsecutiveFailures` - contention says
    /// nothing about whether `kubectl` itself works. An instance property
    /// with a default (not a `static let`), for the same reason
    /// `refreshInterval` is: a self-test needs to prove the busy-vs-hard-
    /// failure retry cadence actually differs without sleeping for real
    /// wall-clock seconds.
    let busyRetryInterval: TimeInterval

    /// How soon to retry after a **genuine** command failure (e.g. `kubectl`
    /// not on PATH, no current context set) - one of the up to
    /// `maxConsecutiveFailures` short retries before giving up altogether.
    /// Deliberately its own, slightly longer cadence than `busyRetryInterval`:
    /// a real failure is less likely to resolve within moments than "the
    /// captain was typing a second ago" is.
    let failureRetryInterval: TimeInterval

    /// `fm/grandline-k8s-badge-fixes`, issue 1: how many **genuine** command
    /// failures in a row (never a `.busy`/`.discarded` refusal - see
    /// `busyRetryInterval`'s own doc comment) this bridge tolerates before it
    /// stops scheduling any further automatic attempt at all and reports
    /// `hasStoppedRetrying`. Kept low on purpose - a tab whose `kubectl` can
    /// never succeed (the real, reported case: a plain entry-hop bastion with
    /// no `kubectl` on PATH) should say so quickly rather than spend minutes
    /// quietly failing first. The captain's own click on the toolbar's
    /// resulting "unavailable" state is what tries again (`start()` resets
    /// this count), so giving up early costs nothing - it is never a dead
    /// end, only a pause until asked to try again.
    let maxConsecutiveFailures: Int

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
    /// update the tab's own `kubeContextBadgeStatus` (only on success, or on
    /// the one genuine failure that trips `hasStoppedRetrying`; see this
    /// file's header on never clearing an already-known-good badge over a
    /// merely transient failure) and refresh the toolbar toggle when this is
    /// the current tab.
    var onUpdate: ((Result<KubeContextInfo, KubeContextError>) -> Void)?

    /// Read before injecting - `true` when a sibling bridge (SRE Lead's own,
    /// on the same tab) is already mid-command. See this file's header.
    /// Defaults to "never busy elsewhere" so a caller that doesn't wire this
    /// (e.g. a self-test with no SRE Lead session at all) behaves exactly as
    /// if there were no sibling to worry about.
    var isTerminalBusyElsewhere: () -> Bool = { false }

    /// How many **genuine** command failures have happened in a row since the
    /// last success (or the last `start()`) - reset to 0 by either. Never
    /// incremented by a `.busy`/`.discarded` refusal.
    private var consecutiveFailureCount = 0

    /// `fm/grandline-k8s-badge-fixes`, issue 1: `true` once
    /// `consecutiveFailureCount` has reached `maxConsecutiveFailures` and
    /// this bridge has stopped scheduling any further automatic attempt.
    /// `start()` is the only thing that clears it (both first activation and
    /// the captain's own explicit "try again" click go through `start()`).
    private(set) var hasStoppedRetrying = false

    /// The most recent failure's own message, kept so a caller building the
    /// "unavailable" tooltip doesn't need to have captured the last
    /// `onUpdate` result itself. `nil` after a success.
    private(set) var lastFailureMessage: String?

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
        target: SRELeadBridgeTerminal, refreshInterval: TimeInterval = 300, busyRetryInterval: TimeInterval = 5,
        failureRetryInterval: TimeInterval = 10, maxConsecutiveFailures: Int = 3,
        userActivityQuietWindow: TimeInterval = 0.5, commandTimeout: TimeInterval = 15
    ) {
        self.target = target
        self.refreshInterval = refreshInterval
        self.busyRetryInterval = busyRetryInterval
        self.failureRetryInterval = failureRetryInterval
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
        self.userActivityQuietWindow = userActivityQuietWindow
        self.commandTimeout = commandTimeout
    }

    /// True while this bridge itself has an outstanding refresh - the seam a
    /// sibling bridge on the same tab (`SRELeadBridge`) reads before
    /// injecting its own command. See this file's header.
    var isBusy: Bool { inFlight != nil }

    /// Start (or restart) the refresh cycle: an immediate first attempt (so
    /// the badge isn't blank until a full `refreshInterval` elapses), then a
    /// repeating poll that both watches an in-flight command and decides when
    /// it's time for the next one.
    ///
    /// `fm/grandline-k8s-badge-fixes`: this is now the **one** entry point for
    /// two distinct things a caller wants, deliberately unified rather than
    /// given two names - both are "start trying, from a clean slate":
    /// activating the badge for a tab for the first time, and the captain's
    /// own explicit "try again" click on an already-`hasStoppedRetrying`
    /// badge. Either way, `consecutiveFailureCount`/`hasStoppedRetrying`/
    /// `lastFailureMessage` reset here, so a stale give-up from a previous
    /// run can never suppress a fresh attempt.
    func start() {
        stop()
        consecutiveFailureCount = 0
        hasStoppedRetrying = false
        lastFailureMessage = nil
        nextAttemptAt = nil
        isStopped = false
        refreshNow()
        rescheduleTimerIfNeeded()
    }

    /// Stops the poll timer and forgets any in-flight command. Deliberately
    /// leaves `consecutiveFailureCount`/`hasStoppedRetrying`/
    /// `lastFailureMessage` untouched - this is "pause" (deactivation, a tab
    /// closing, a reconnect about to restart), not "give up", and only
    /// `start()` resets that state.
    func stop() {
        timer?.invalidate()
        timer = nil
        scheduledCadence = .none
        isStopped = true
        inFlight = nil
    }

    /// Matches `KubeBridge`/`SRELeadBridge`. Every teardown path in
    /// `ConsoleController+Tabs` already calls `stop()` first, so this is
    /// insurance rather than a fix: a `Timer` is retained by the run loop, so
    /// a bridge dropped without stopping would leave its `.inFlight` timer
    /// firing into a `nil` `self` forever. (A `.dueAt` timer is
    /// non-repeating, so it expires on its own either way.)
    deinit { timer?.invalidate() }

    /// `true` between a `stop()` and the next `start()`. Distinct from
    /// "paused": a stopped bridge is deactivated (the badge was turned off,
    /// the tab closed, a reconnect is about to restart it) and only `start()`
    /// brings it back, whereas a paused one is merely out of sight and
    /// resumes on its own with its give-up state and `nextAttemptAt`
    /// untouched.
    private var isStopped = true

    /// Re-evaluate what the timer should be doing, now.
    ///
    /// The energy half of the visibility fix: `shouldPauseRefreshes` is
    /// already consulted at the moment of every attempt, so calling this is
    /// never required for *correctness* - it just means a page that has just
    /// gone out of sight stops waking up immediately, rather than at its next
    /// scheduled attempt (up to a whole `refreshInterval` later).
    func refreshGating() {
        rescheduleTimerIfNeeded()
    }

    // MARK: Timer cadence

    private func desiredCadence() -> Cadence {
        // An in-flight command is always watched to completion, even while
        // paused: it has already been typed into the real shell, so its
        // output is coming either way - and abandoning it would leave
        // `inFlight` (and therefore `isBusy`, the seam `SRELeadBridge` reads
        // before injecting its own command) stuck set forever.
        if inFlight != nil { return .inFlight }
        if isStopped || hasStoppedRetrying { return .none }
        if shouldPauseRefreshes() { return .none }
        return .dueAt(nextAttemptAt ?? Date())
    }

    private func rescheduleTimerIfNeeded() {
        let want = desiredCadence()
        if timer != nil, scheduledCadence == want { return }
        timer?.invalidate()
        timer = nil
        scheduledCadence = want

        switch want {
        case .none:
            return
        case .inFlight:
            let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            // 3.4: let the kernel coalesce this with nearby work.
            t.tolerance = Self.pollInterval * 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        case .dueAt(let due):
            // A one-shot, not a repeat: `tick()` reschedules from whatever
            // state it leaves behind, so there is nothing for a repeating
            // timer to do between two attempts. Floored just above zero so a
            // clock adjustment that puts `due` in the past cannot turn this
            // into a busy loop; `Timer.tolerance` only ever delays a fire, so
            // the timer can never arrive before `due`.
            let delay = max(0.05, due.timeIntervalSinceNow)
            let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.tick()
            }
            // Proportional, and generous for the long healthy wait: a badge
            // that reads the same cluster it read five minutes ago does not
            // care about a few seconds either way.
            t.tolerance = min(30, max(0.05, delay * 0.1))
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    #if FM_SELFTESTS
    /// How long until the next scheduled wake-up, or `nil` when nothing is
    /// scheduled - the seam a self-test reads to prove the idle badge is
    /// genuinely asleep rather than spinning at `pollInterval`.
    var debugSecondsUntilNextWake: TimeInterval? {
        guard let timer, timer.isValid else { return nil }
        return timer.fireDate.timeIntervalSinceNow
    }

    /// `true` while a repeating in-flight-cadence timer is scheduled.
    var debugIsPollingInFlight: Bool {
        if case .inFlight = scheduledCadence, timer != nil { return true }
        return false
    }

    /// `true` while no timer is scheduled at all.
    var debugIsIdleStopped: Bool { timer == nil }
    #endif

    /// Attempt a refresh right now, bypassing the `refreshInterval`/
    /// `busyRetryInterval`/`failureRetryInterval` cooldown AND the give-up
    /// state (though not the busy/quiet-window guards, which are genuine
    /// "not right now" refusals rather than exhaustion) - `start()`'s own
    /// first call, and the entry point a self-test drives directly rather
    /// than waiting on the real `Timer` `start()` schedules (which needs a
    /// pumped run loop this codebase's headless self-test binaries never
    /// provide - see `SRELeadBridgeSelfTest`'s own convention of calling
    /// `tick()` by hand for the identical reason).
    func refreshNow() {
        beginRefreshIfDue(force: true)
        // Keeps "every state change reschedules" true for this entry point
        // too, not just for `tick()`. `start()` happens to reschedule right
        // after its own call; a future caller should not have to know that.
        if !isStopped { rescheduleTimerIfNeeded() }
    }

    // MARK: Polling

    /// Not `private`, for the same reason `SRELeadBridge.tick()` isn't - a
    /// self-test drives this directly instead of relying on `start()`'s
    /// timer.
    func tick() {
        // Whatever this tick does, the cadence the *next* wake-up runs at is
        // decided from the state this one leaves behind. Guarded on the
        // bridge actually being started so a self-test driving `tick()` by
        // hand on a never-started bridge does not get a real `Timer`
        // scheduled behind its back.
        defer { if !isStopped { rescheduleTimerIfNeeded() } }
        if let current = inFlight {
            checkInFlight(current)
            return
        }
        beginRefreshIfDue(force: false)
    }

    private func beginRefreshIfDue(force: Bool) {
        if !force {
            // 3.2's correctness half. A periodic refresh visibly types into
            // the captain's live session, so an unseen page must not fire one
            // - checked here, at the attempt, rather than relying on the
            // timer having been torn down, so a missed visibility signal
            // cannot leak a command into a hidden session. Deliberately
            // leaves `nextAttemptAt` alone: this is "not now", not an
            // outcome, so the badge picks straight up where it left off when
            // the page comes back.
            //
            // `force` still bypasses it - that path is activation and the
            // captain's own explicit retry click, neither of which happens on
            // a page nobody is looking at.
            guard !shouldPauseRefreshes() else { return }
            // `fm/grandline-k8s-badge-fixes`, issue 1: once this bridge has
            // given up, an ordinary tick (the periodic poll's own idle check)
            // must never quietly try again on its own - that would be exactly
            // the "stop retrying automatically" contract violated the moment
            // the captain looks away. Only a *forced* call (`start()`, i.e.
            // activation or an explicit retry click) may proceed here.
            guard !hasStoppedRetrying else { return }
            if let nextAttemptAt, Date() < nextAttemptAt { return }
        }
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

    /// `fm/grandline-k8s-badge-fixes`, issue 1: this is where the give-up
    /// decision actually happens, and every field it touches is set *before*
    /// `onUpdate?(result)` fires - so a caller reading `hasStoppedRetrying`/
    /// `lastFailureMessage` from inside its own `onUpdate` closure always sees
    /// this outcome's own effect, never a stale one from before it.
    private func report(_ result: Result<KubeContextInfo, KubeContextError>) {
        switch result {
        case .success:
            consecutiveFailureCount = 0
            hasStoppedRetrying = false
            lastFailureMessage = nil
            nextAttemptAt = Date().addingTimeInterval(refreshInterval)
        case .failure(.busy(let message)), .failure(.discarded(let message)):
            // Transient contention (the captain was typing, a sibling bridge
            // was mid-command, or a refresh was already running) - never a
            // real `kubectl` failure, so it never counts toward the give-up
            // threshold below and can never trip `hasStoppedRetrying` on its
            // own.
            lastFailureMessage = message
            nextAttemptAt = Date().addingTimeInterval(busyRetryInterval)
        case .failure(let error):
            lastFailureMessage = error.message
            consecutiveFailureCount += 1
            if consecutiveFailureCount >= maxConsecutiveFailures {
                // Give up: stop the poll timer outright rather than merely
                // leaving `nextAttemptAt` far in the future - there is
                // nothing left for it to watch, and no reason to keep waking
                // up every `pollInterval` to find that out again. `start()`
                // is the only way back in.
                hasStoppedRetrying = true
                nextAttemptAt = nil
                timer?.invalidate()
                timer = nil
                scheduledCadence = .none
            } else {
                nextAttemptAt = Date().addingTimeInterval(failureRetryInterval)
            }
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
