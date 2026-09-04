// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-cluster-tail`: the ONE piece of bridge plumbing the
// `.kubernetes` destination's two big features - the Cluster browser
// (k9s-equivalent) and the Log Tail (stern-equivalent) - both consume. The
// task brief is explicit that this is built once and shared, not twice.
//
// **What this is, relative to its two siblings.** `SRELeadBridge` bridges a
// genuine cross-process gap (a Python MCP subprocess writing request files
// this Swift app answers), so it is a file-based protocol.
// `KubeContextBridge` is the opposite extreme: it always sends exactly two
// fixed, hardcoded commands and needs no request concept at all. This class
// sits between them - same Swift process on both ends (no files), but a
// *varying* command per request (which pod's logs, which namespace's
// deployments), which neither sibling models. It therefore adds the one
// thing neither has: a small serialized request queue.
//
// **Why a queue, when the underlying constraint is single-flight.** The
// shared terminal is one real shell: injecting a second marker-wrapped
// command while the first is still running genuinely interleaves keystrokes
// and corrupts both outputs (see `KubeContextBridge.swift`'s header on the
// same hazard between two *different* bridges). `SRELeadBridge` and
// `KubeContextBridge` both handle that by *refusing* a second request - fine
// when there is only ever one. But a Cluster refresh is inherently three
// commands (`get pods -o wide`, `top pods`, `get events`) and a Log Tail
// poll is one per selected pod, and refusing 4 of 5 would make either
// feature useless. So `enqueue(_:)` accepts a request and this class issues
// them **one at a time**, exactly as the scout report's own mockup describes
// ("serialized, one at a time, because the bridge is single-flight"). The
// hard constraint is unchanged - at most one command is ever in the tab -
// only the caller-facing shape differs.
//
// **A queued request is never allowed to sit forever.** A request that
// cannot be issued because the captain is typing (or a sibling bridge is
// mid-command) stays queued and is retried on the next tick, but carries its
// own `queuedAt`: past `queueDeadline` it is failed with `.busy` rather than
// waiting behind contention indefinitely. That matters because a caller
// (the Log Tail's own timer) will keep enqueueing fresh work - without a
// deadline, a captain typing for a minute would build a backlog of stale
// polls that all fire at once the moment they stop.
//
// **Backoff and give-up, learned the hard way and inherited deliberately.**
// `fm/grandline-k8s-badge-fixes` had to fix exactly this in
// `KubeContextBridge` after the captain's first real use: a tab whose
// `kubectl` can never succeed (the common real shape - a plain entry-hop
// bastion with no `kubectl` on PATH at all) retried the identical failing
// command forever, spamming the tab with `command not found`. The task brief
// for this file says in as many words not to re-learn that. So:
// `maxConsecutiveFailures` **genuine** command failures in a row (never a
// `.busy`/`.discarded` refusal, which cost nothing and say nothing about
// whether `kubectl` works) trips `hasStoppedRetrying`, at which point every
// queued request is failed, the queue is cleared, the timer is stopped and
// nothing further is attempted until `resume()` - the captain's own explicit
// "try again". `KubeBridgeSelfTest.checkBackoffStopsAfterRepeatedFailures`
// proves it rather than this comment asserting it.
//
// **Read-only by construction.** Every command this class sends is built by
// `KubeCommand` from a fixed set of templates - never from AI output, never
// from free-typed captain text. The five verbs used anywhere in either
// feature (`get`, `describe`, `top`, `events`, `logs`) are already allowed by
// `sre_kubectl_mcp.py`'s `_ALLOWED_VERBS`, so this task widens no allowlist
// at all (unlike the context-badge task, which needed `config`). There is no
// exec, no edit, no delete, no scale, and there must never be one here - a
// mutating action belongs in the Command Library behind its own risk gate.
//
// **Cross-bridge collision.** SRE Lead's bridge and the context badge's
// bridge can both target the same tab as this one. Each bridge's own
// single-flight tracking only guards against *itself*, so - exactly as
// `KubeContextBridge` already does - `isTerminalBusyElsewhere` is the seam a
// caller wires to read the siblings' `isBusy`, and `isBusy` is what the
// siblings read back.
//
// **A queued-but-not-yet-issued request must say why (`fm/grandline-k8s-feed
// -tab-stall-fix`).** `pump()`'s two contention checks (busy elsewhere, the
// captain typing in the feed tab) used to just `return` and leave the queued
// command sitting there silently - a real captain hit this checking on the
// feed tab by typing a manual login directly into it, which kept
// `.waitingForQuietTab` true for as long as they kept typing, and the page
// rendered a plain "Refreshing…" with no way to tell that from kubectl
// genuinely being slow. `pendingReason`/`pendingSince` are what let a page
// distinguish "held back by contention, here's why and for how long" from
// "genuinely running" (`inFlightLabel`) - see `KubeBridgePendingReason`'s own
// header. The existing `queueDeadline` (45s) already bounds the wait and
// hands it back with `.busy`, which the page's own poll loop then retries
// automatically a poll cycle later - that bounded-wait-then-auto-retry shape
// is kept exactly as-is (see `KubernetesController.refreshCluster`'s own
// note on the choice **not** to bypass the activity check and send anyway:
// doing so would be the one thing this bridge exists to prevent).
//
// **`stop()` used to silently drop an in-flight request's own completion
// (`fm/grandline-k8s-refresh-stuck-audit`).** The `fm/grandline-k8s-feed-tab
// -stall-fix` work above fixed the *queued-but-not-yet-issued* half of "a
// request that never resolves" - but `stop()` itself had the identical bug
// one level deeper: it set `inFlight = nil` without ever calling that
// request's `completion`, only failing what was still sitting in `queue`.
// That is silent by construction: `pendingReason` (the mechanism the prior
// fix built) only ever describes something *queued*, so a request already
// issued to the terminal when `stop()` ran left no trace anywhere - not in
// `pendingReason`, not in `queueDepth`, nothing. A caller that fans a batch
// out across several commands (`KubernetesController.refreshCluster()`'s
// `enqueueBatch`, tracking its own "how many are still outstanding" counter)
// would then have that counter stuck above zero forever, because the one
// completion that would have brought it to zero was the one `stop()` just
// dropped - and the caller has no way to tell the difference between "still
// genuinely running" and "silently abandoned". `stop()` is reachable mid
// -command any time the captain switches the feed-tab picker or the scope
// strip (`KubernetesController.teardownFeed()`), and a real discovery sweep
// against a real cluster easily takes long enough for exactly that timing.
// See `checkInFlightRequestResolvedOnStop`/`checkBatchStillCompletesWhenStopp
// edMidFlight` for the fix, proven against the bug rather than merely
// described.

import Foundation

/// The fixed, read-only kubectl command set either feature can ask for.
///
/// A closed enum rather than a string parameter, deliberately: it is the
/// structural reason nothing can smuggle a mutating verb through this bridge
/// (the same reasoning `ScheduledActionKind` uses for F11's scheduled
/// actions). A namespace or pod name still reaches a command as text, so
/// `KubeCommand.isSafeToken` gates those - they come from kubectl's own
/// discovery output or a captain's namespace field, and a value carrying a
/// shell metacharacter must never be pasted into a real shell.
enum KubeCommand: Equatable {
    /// `kubectl get pods -n <ns> -o wide`
    case getPods(namespace: String)
    /// `kubectl top pods -n <ns>` - may legitimately fail (no metrics-server),
    /// which is why the Cluster browser treats its absence as "no cpu/mem
    /// columns" rather than as a failed refresh.
    case topPods(namespace: String)
    /// `kubectl get deployments -n <ns>`
    case getDeployments(namespace: String)
    /// `kubectl get services -n <ns>`
    case getServices(namespace: String)
    /// `kubectl get events -n <ns> --sort-by=.lastTimestamp`
    case getEvents(namespace: String)
    /// `kubectl describe pod <name> -n <ns>`
    case describePod(name: String, namespace: String)
    /// `kubectl logs <pod> -n <ns> --since=<n>s --timestamps`
    case podLogs(pod: String, namespace: String, sinceSeconds: Int)

    /// A conservative allowlist for anything that reaches a real shell as a
    /// bare word: DNS-1123 label characters plus the dot a namespaced or
    /// FQDN-ish name can carry. Deliberately narrower than what Kubernetes
    /// itself accepts - a name this rejects simply is not offered, which is a
    /// far better failure than pasting a shell metacharacter into the
    /// captain's authenticated bastion session. Mirrors
    /// `sre_kubectl_mcp.py`'s own `_validate_args` character set in spirit;
    /// nothing here calls into that script.
    static func isSafeToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 253 else { return false }
        return token.allSatisfy { ch in
            ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII || ch == "-" || ch == "." || ch == "_"
        }
    }

    /// The literal command text, or `nil` when any interpolated token fails
    /// `isSafeToken`. A `nil` here is a refusal to build the command at all -
    /// never a fallback to some "safe" default, which would silently run a
    /// different query than the caller asked for.
    var commandText: String? {
        switch self {
        case .getPods(let ns):
            guard Self.isSafeToken(ns) else { return nil }
            return "kubectl get pods -n \(ns) -o wide"
        case .topPods(let ns):
            guard Self.isSafeToken(ns) else { return nil }
            return "kubectl top pods -n \(ns)"
        case .getDeployments(let ns):
            guard Self.isSafeToken(ns) else { return nil }
            return "kubectl get deployments -n \(ns)"
        case .getServices(let ns):
            guard Self.isSafeToken(ns) else { return nil }
            return "kubectl get services -n \(ns)"
        case .getEvents(let ns):
            guard Self.isSafeToken(ns) else { return nil }
            return "kubectl get events -n \(ns) --sort-by=.lastTimestamp"
        case .describePod(let name, let ns):
            guard Self.isSafeToken(name), Self.isSafeToken(ns) else { return nil }
            return "kubectl describe pod \(name) -n \(ns)"
        case .podLogs(let pod, let ns, let since):
            guard Self.isSafeToken(pod), Self.isSafeToken(ns), since > 0, since <= 3600 else { return nil }
            return "kubectl logs \(pod) -n \(ns) --since=\(since)s --timestamps"
        }
    }

    /// A short human label for the UI's "what is it doing right now" line.
    var shortLabel: String {
        switch self {
        case .getPods: return "get pods"
        case .topPods: return "top pods"
        case .getDeployments: return "get deployments"
        case .getServices: return "get services"
        case .getEvents: return "get events"
        case .describePod(let name, _): return "describe \(name)"
        case .podLogs(let pod, _, _): return "logs \(pod)"
        }
    }
}

/// Why a request did not produce output. Mirrors `KubeContextError`'s own
/// split between transient contention (which says nothing about whether
/// `kubectl` works) and a genuine command failure (which counts toward
/// giving up).
enum KubeBridgeError: Error, Equatable {
    /// The feed tab is gone (closed, or the host page torn down).
    case unavailable(String)
    /// Refused without injecting: the captain is typing in the feed tab, a
    /// sibling bridge holds the tab, or the request waited past
    /// `queueDeadline` behind contention.
    case busy(String)
    /// The end marker never appeared within `commandTimeout`.
    case timeout
    /// The captain typed into the feed tab mid-command, so the extracted text
    /// can't be trusted.
    case discarded(String)
    /// Both markers were not found in the expected order.
    case markersNotFound
    /// The command could not even be built - a namespace or pod name failed
    /// `KubeCommand.isSafeToken`. Never retried: retrying an unbuildable
    /// command produces the identical refusal forever.
    case unsafeCommand(String)
    /// This bridge has given up after `maxConsecutiveFailures` genuine
    /// failures; only `resume()` clears it.
    case stopped(String)

    /// Whether this outcome counts toward the give-up threshold. Contention
    /// and an unbuildable command both answer `false`, for different reasons:
    /// contention costs nothing and is not kubectl's fault, and an unsafe
    /// token is the caller's bug rather than a sign the tab is dead.
    var countsAsGenuineFailure: Bool {
        switch self {
        case .busy, .discarded, .unsafeCommand, .stopped: return false
        case .unavailable, .timeout, .markersNotFound: return true
        }
    }

    var message: String {
        switch self {
        case .unavailable(let m), .busy(let m), .discarded(let m), .unsafeCommand(let m), .stopped(let m): return m
        case .timeout: return "timed out waiting for kubectl"
        case .markersNotFound: return "could not find the command's own output markers in the terminal"
        }
    }
}

/// Why nothing has been issued to the feed tab yet - distinct from
/// **genuinely running** (`KubeBridge.inFlightLabel`) and from **gave up**
/// (`KubeBridge.hasStoppedRetrying`).
///
/// `fm/grandline-k8s-feed-tab-stall-fix`: before this existed, a request
/// stuck behind either reason rendered identically to a request that had
/// genuinely been issued and was just taking a while - a plain "Refreshing…"
/// spinner with no way to tell "kubectl is slow" from "this app is
/// deliberately holding back". The captain's own repro was checking on the
/// feed tab by typing a manual login directly into it: that keeps
/// `.waitingForQuietTab` true for as long as they keep typing (see
/// `SRELeadBridgeTerminal.lastUserActivity`), and the page gave no
/// indication that their own typing was the thing pausing it.
///
/// `nil` (not a case here - see `KubeBridge.pendingReason`'s own type) means
/// nothing is being held back: the queue is empty, something is genuinely in
/// flight, or this bridge has given up.
enum KubeBridgePendingReason: Equatable {
    /// A sibling bridge (SRE Lead's, or the context badge's) already holds
    /// the tab - `KubeBridge.isTerminalBusyElsewhere`. Costs nothing and is
    /// retried on the very next tick once the sibling releases it.
    case busyElsewhere
    /// A real keystroke or paste landed in the feed tab within
    /// `KubeBridge.userActivityQuietWindow` - the exact safety check this
    /// bridge must never weaken (see `checkInFlight`'s own discard guard for
    /// the in-flight half of the same rule).
    case waitingForQuietTab

    /// The line the UI actually shows, so the wording lives in one place
    /// rather than being re-derived at every render call site.
    var statusText: String {
        switch self {
        case .busyElsewhere:
            return "Waiting for another automated action in the feed tab to finish"
        case .waitingForQuietTab:
            return "Waiting for the feed tab to be idle - avoid typing into it directly"
        }
    }
}

/// One queued or in-flight request.
private struct KubeRequest {
    let id: UUID
    let command: KubeCommand
    let commandText: String
    let queuedAt: Date
    let priority: KubeRequestPriority
    let completion: (Result<String, KubeBridgeError>) -> Void
}

/// Why a request was asked for - which is what decides its place in the
/// queue (`fm/grandline-k8s-ui-revamp`, bug 2).
///
/// The captain reported a `describe` click timing out shortly after an
/// identical one succeeded. A `describe` is issued the instant a row is
/// clicked, but the queue was strictly FIFO, so it landed **behind** whatever
/// the 30s discovery poll had just queued - and on a real cluster reached
/// through a bastion, each of those is a real API round trip. Waiting several
/// seconds for output the captain asked for, behind output nobody asked for,
/// is the wrong order.
///
/// This changes **only the order work is issued in**. It does not weaken the
/// single-flight constraint (still at most one command in the tab, ever), the
/// activity guard, the busy-elsewhere guard, or the deadline: an interactive
/// request jumps ahead of *queued* background work and never preempts
/// anything already injected.
enum KubeRequestPriority: Int, Comparable {
    /// A poll nobody asked for: the discovery sweep, the log tail's cycle.
    case background = 0
    /// Something the captain just clicked: a `describe`, a manual Refresh.
    case interactive = 1

    static func < (lhs: KubeRequestPriority, rhs: KubeRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Runs a bounded, read-only kubectl command against one dedicated terminal
/// tab and hands back its raw text. See this file's header for the design.
final class KubeBridge {

    private weak var target: SRELeadBridgeTerminal?
    private var timer: Timer?
    private var queue: [KubeRequest] = []
    private var inFlight: InFlight?

    /// How often the poll timer runs. Fast enough that a completed command is
    /// noticed promptly (a Cluster sweep chains three of them, so per-command
    /// latency compounds) while still well under the cost `SRELeadBridge`'s
    /// own 5Hz poll had before GL-34 - `checkInFlight` reads only the
    /// viewport on most ticks, exactly like that class does.
    static let pollInterval: TimeInterval = 0.25

    /// GL-34's safety net: the cheap viewport probe cannot see a marker the
    /// captain has scrolled away from (scrolling is not keystroke activity,
    /// so it never trips the input guard), so every Nth tick falls back to a
    /// full buffer read.
    ///
    /// **40, not `SRELeadBridge`'s 10** (`fm/grandline-k8s-ui-revamp`, bug 4).
    /// At `pollInterval` 0.25s that is one full read every 10s rather than
    /// every 2.5s, and a full read is not cheap: measured at **107ms** on a
    /// real headless `Terminal` at the interactive geometry, on the main
    /// thread, which is the whole app's UI thread. A command is bounded by
    /// `commandTimeout` (20s), so the safety net still fires twice inside
    /// any command's own lifetime - it just stops costing the rest of the
    /// app four stalls per command that the viewport probe was already
    /// covering.
    static let fullScanEvery = 40

    /// Per-command ceiling. Longer than `KubeContextBridge`'s 15s (its two
    /// `config` commands never touch the API server) and shorter than
    /// `SRELeadBridge`'s 25s: a `get`/`logs` against a real cluster is a real
    /// API round trip, but a tail poll that takes 20s has already missed its
    /// own next cycle.
    let commandTimeout: TimeInterval

    /// How long a request may sit unissued behind contention before it is
    /// failed with `.busy`. See this file's header on why a queued request
    /// must never wait indefinitely.
    let queueDeadline: TimeInterval

    /// Refused before injecting when a real keystroke/paste landed within
    /// this many seconds - the same concept and default
    /// `SRELeadBridge.userActivityQuietWindow` uses.
    let userActivityQuietWindow: TimeInterval

    /// `fm/grandline-k8s-badge-fixes`' lesson, inherited: how many genuine
    /// command failures in a row before this bridge stops attempting anything
    /// at all. Kept low on purpose - a feed tab where `kubectl` can never
    /// succeed should say so in seconds, not spend minutes quietly failing.
    let maxConsecutiveFailures: Int

    /// Read before injecting - `true` when a sibling bridge (SRE Lead's, or
    /// the context badge's) already holds this tab.
    var isTerminalBusyElsewhere: () -> Bool = { false }

    /// Fired whenever `hasStoppedRetrying` or the in-flight command changes,
    /// so a page can re-render its "feed is working / feed has given up"
    /// state without polling this object.
    var onStateChanged: (() -> Void)?

    private(set) var consecutiveFailureCount = 0

    /// `true` once this bridge has given up. Only `resume()` clears it.
    private(set) var hasStoppedRetrying = false

    /// The most recent genuine failure's message, for the page's own
    /// "unavailable, here's why" line. `nil` after any success.
    private(set) var lastFailureMessage: String?

    /// What is running right now, for a live "running `get pods`…" label.
    private(set) var inFlightLabel: String?

    /// Why the front of the queue hasn't been issued yet - `nil` whenever
    /// nothing is being held back (queue empty, something genuinely in
    /// flight, or `hasStoppedRetrying`). Set only from `pump()`, live, so a
    /// page rendering "Refreshing…" can show the real reason instead of a
    /// generic spinner. See `KubeBridgePendingReason`'s own header for why
    /// this exists at all.
    private(set) var pendingReason: KubeBridgePendingReason?

    /// When the request currently held back by `pendingReason` was first
    /// queued - `nil` whenever `pendingReason` is `nil`. Lets the UI say how
    /// long it's been waiting, not just that it is waiting.
    var pendingSince: Date? { pendingReason == nil ? nil : queue.first?.queuedAt }

    /// True while this bridge holds the tab - the seam a sibling bridge reads.
    var isBusy: Bool { inFlight != nil }

    var queueDepth: Int { queue.count }

    /// How much work has to finish before the first queued interactive
    /// request can be issued: whatever sits ahead of it in the queue, plus
    /// the one command already in the tab (if any).
    ///
    /// This is what lets the describe panel say "queued behind other
    /// Kubernetes activity" honestly, instead of a bare spinner that looks
    /// identical to a hang. With nothing interactive queued it reports the
    /// whole queue plus the in-flight command, which is the same number a
    /// request enqueued right now would face.
    var workAheadOfNextInteractive: Int {
        let ahead = queue.firstIndex(where: { $0.priority == .interactive }) ?? queue.count
        return ahead + (inFlight == nil ? 0 : 1)
    }

    private struct InFlight {
        let request: KubeRequest
        let startMarker: String
        let endMarker: String
        let startedAt: Date
        /// Only lines at or beyond this index are ever searched, so a marker
        /// that happens to appear earlier in scrollback can never be mistaken
        /// for this request's own output - `SRELeadBridge.InFlight.
        /// searchFromLine`'s exact reasoning.
        let searchFromLine: Int
        var ticks: Int
    }

    init(target: SRELeadBridgeTerminal,
         commandTimeout: TimeInterval = 20,
         queueDeadline: TimeInterval = 45,
         userActivityQuietWindow: TimeInterval = 0.5,
         maxConsecutiveFailures: Int = 3) {
        self.target = target
        self.commandTimeout = commandTimeout
        self.queueDeadline = queueDeadline
        self.userActivityQuietWindow = userActivityQuietWindow
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
    }

    deinit { timer?.invalidate() }

    // MARK: Lifecycle

    /// Starts the poll timer if it isn't already running. Idempotent, and
    /// cheap when idle: with an empty queue and nothing in flight a tick does
    /// nothing but return.
    func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops the timer, fails everything still queued **and anything
    /// currently in flight**, and forgets any in-flight command.
    ///
    /// Deliberately leaves `consecutiveFailureCount`/`hasStoppedRetrying`
    /// alone - this is "pause" (the page went away, the feed tab changed),
    /// not "give up", exactly like `KubeContextBridge.stop()`. Bypasses
    /// `deliver(_:_:)` for the same reason: a stopped-by-teardown request
    /// must never itself count toward the give-up threshold.
    ///
    /// **The in-flight resolution is the fix for
    /// `fm/grandline-k8s-refresh-stuck-audit`.** Before it, `inFlight = nil`
    /// silently discarded that request's own `completion` - see this file's
    /// header for why that left a caller's own multi-command counter
    /// (`KubernetesController.refreshCluster()`'s `isRefreshingCluster`)
    /// stuck forever, with no trace anywhere in this bridge's own visible
    /// state to explain why.
    func stop() {
        timer?.invalidate()
        timer = nil
        pendingReason = nil
        let droppedInFlight = inFlight
        inFlight = nil
        inFlightLabel = nil
        let pending = queue
        queue.removeAll()
        if let request = droppedInFlight?.request {
            AppLog.ui.info("""
                KubeBridge stop(): resolving an in-flight command (\
                \(request.command.shortLabel, privacy: .public)) that was still \
                waiting on its markers, plus \(pending.count, privacy: .public) \
                still-queued request(s) - none are left dangling.
                """)
            request.completion(.failure(.unavailable("the log/cluster feed was stopped")))
        } else if !pending.isEmpty {
            AppLog.ui.info("KubeBridge stop(): failing \(pending.count, privacy: .public) still-queued request(s)")
        }
        for request in pending {
            request.completion(.failure(.unavailable("the log/cluster feed was stopped")))
        }
        onStateChanged?()
    }

    /// The captain's own explicit "try again" after this bridge gave up -
    /// the single entry point back in, matching `KubeContextBridge.start()`'s
    /// deliberate unification of activation and retry.
    func resume() {
        AppLog.ui.info("KubeBridge resume(): captain-initiated retry after give-up")
        consecutiveFailureCount = 0
        hasStoppedRetrying = false
        lastFailureMessage = nil
        pendingReason = nil
        start()
        onStateChanged?()
    }

    /// Points this bridge at a different terminal (the captain picked a
    /// different feed tab). Everything queued against the old tab is failed
    /// rather than silently re-aimed - a `describe` for a pod discovered on
    /// one cluster must never be answered by a different one.
    func retarget(_ newTarget: SRELeadBridgeTerminal?) {
        AppLog.ui.info("KubeBridge retarget(): switching feed tab (had target: \(self.target != nil, privacy: .public))")
        stop()
        target = newTarget
        consecutiveFailureCount = 0
        hasStoppedRetrying = false
        lastFailureMessage = nil
        pendingReason = nil
        if newTarget != nil { start() }
        onStateChanged?()
    }

    // MARK: Requests

    /// Queues one read-only command. The completion always fires exactly
    /// once, on the main thread, with either the command's raw text (whatever
    /// the shell printed between the markers) or a `KubeBridgeError`.
    func enqueue(_ command: KubeCommand,
                 priority: KubeRequestPriority = .background,
                 completion: @escaping (Result<String, KubeBridgeError>) -> Void) {
        guard !hasStoppedRetrying else {
            completion(.failure(.stopped(lastFailureMessage ?? "the feed stopped after repeated failures")))
            return
        }
        guard let text = command.commandText else {
            // Never counted as a genuine failure and never retried: the same
            // unbuildable command would be refused identically forever.
            completion(.failure(.unsafeCommand("\(command.shortLabel) contains a value this app will not type into a shell")))
            return
        }
        let request = KubeRequest(id: UUID(), command: command, commandText: text,
                                  queuedAt: Date(), priority: priority, completion: completion)
        // Stable insertion, never a sort: an interactive request goes after
        // any interactive work already waiting (so two quick clicks stay in
        // click order) and before the first background one. Sorting the whole
        // queue would reorder same-priority work, and a Cluster sweep's own
        // three commands genuinely depend on arriving in the order they were
        // batched.
        if let index = queue.firstIndex(where: { $0.priority < request.priority }) {
            queue.insert(request, at: index)
        } else {
            queue.append(request)
        }
        start()
        // Try immediately rather than waiting up to a whole `pollInterval`:
        // a Cluster sweep chains three commands and a Log Tail poll one per
        // pod, so a quarter-second of dead time per command is visible.
        pump()
    }

    /// Queues several commands in order and calls back once, with each
    /// command's own result, after the last has settled. The Cluster
    /// browser's sweep is exactly this shape.
    ///
    /// Deliberately reports every result rather than failing the whole batch
    /// on the first error: `top pods` legitimately fails on a cluster with no
    /// metrics-server, and that must not blank out the pod table that `get
    /// pods` returned perfectly well.
    func enqueueBatch(_ commands: [KubeCommand],
                      priority: KubeRequestPriority = .background,
                      completion: @escaping ([(KubeCommand, Result<String, KubeBridgeError>)]) -> Void) {
        guard !commands.isEmpty else {
            completion([])
            return
        }
        var results: [(KubeCommand, Result<String, KubeBridgeError>)] = []
        var remaining = commands.count
        for command in commands {
            enqueue(command, priority: priority) { result in
                results.append((command, result))
                remaining -= 1
                if remaining == 0 { completion(results) }
            }
        }
    }

    // MARK: Polling

    /// Not `private`, for the same reason `SRELeadBridge.tick()` isn't: a
    /// self-test drives this by hand rather than relying on the real `Timer`,
    /// which needs a pumped run loop the headless self-test binaries never
    /// provide.
    func tick() {
        if inFlight != nil {
            checkInFlight()
            return
        }
        pump()
        // **Idle costs nothing** (`fm/grandline-k8s-ui-revamp`, bug 4). This
        // is a repeating 4Hz main-thread timer, and it used to keep firing
        // for the whole life of the app once a feed tab had ever been
        // adopted - including while the Kubernetes page was closed, since
        // only `stop()`/`giveUp()` ever invalidated it and the page's own
        // `viewDidDisappear` deliberately does not call `stop()` (that would
        // fail work still in flight). A tick with nothing to do is cheap but
        // not free, and "cheap but forever, in the background" is precisely
        // the shape of a slow app.
        //
        // `enqueue` calls `start()`, so this is a genuine idle-stop rather
        // than a teardown: the next request restarts the timer, and no state
        // is lost or failed on the way through.
        if inFlight == nil, queue.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Issue the next queued request if the tab will have it.
    private func pump() {
        guard inFlight == nil, !hasStoppedRetrying else { return }
        expireStaleQueuedRequests()
        guard let next = queue.first else {
            setPendingReason(nil)
            return
        }

        guard let target else {
            setPendingReason(nil)
            failFront(.unavailable("the feed tab is no longer available"))
            return
        }
        guard !isTerminalBusyElsewhere() else {
            setPendingReason(.busyElsewhere) // stay queued; retried next tick
            return
        }
        if let last = target.lastUserActivity, Date().timeIntervalSince(last) < userActivityQuietWindow {
            setPendingReason(.waitingForQuietTab) // stay queued; the captain is typing in the feed tab
            return
        }
        setPendingReason(nil)

        queue.removeFirst()
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let startMarker = "GL_KUBE_START_\(unique)"
        let endMarker = "GL_KUBE_END_\(unique)"
        // **No full-buffer read at issue time** (`fm/grandline-k8s-ui-revamp`,
        // bug 4). This used to be `target.currentBufferLines().count`, i.e. a
        // whole-scrollback stringification on the main thread *per command
        // issued*, purely to record a starting index. Measured on a real
        // headless `Terminal` at the interactive geometry (10,000 lines x 150
        // cols): **107ms**, and a Cluster sweep issues two or three commands.
        //
        // It is no longer needed for correctness either: the search below is
        // marker-relative (see `markerIndex`), and both markers carry a fresh
        // UUID per request, so there is nothing earlier in scrollback that
        // could be mistaken for this request's own. `0` means "no hint",
        // which is exactly the full-buffer search the fallback already does.
        let searchFromLine = 0
        // `startedAt` is stamped **before** the injection, never after.
        // `checkInFlight`'s discard guard asks "did a keystroke land after we
        // started?", so a keystroke arriving *during* `sendCommand` would be
        // invisible to a timestamp taken afterwards - and that is precisely
        // the window in which the captain's input and ours interleave in the
        // real shell. `KubeContextBridge` stamps it the same way.
        let startedAt = Date()
        target.sendCommand("echo \(startMarker); \(next.commandText); echo \(endMarker)\n")
        inFlight = InFlight(request: next, startMarker: startMarker, endMarker: endMarker,
                            startedAt: startedAt, searchFromLine: searchFromLine, ticks: 0)
        inFlightLabel = next.command.shortLabel
        AppLog.ui.info("KubeBridge: issuing \(next.command.shortLabel, privacy: .public)")
        onStateChanged?()
    }

    /// Records why `pump()` couldn't issue anything this tick, firing
    /// `onStateChanged?()` only on an actual change - so being blocked on the
    /// same reason tick after tick (the poll runs at `pollInterval`, 4x a
    /// second) doesn't turn into a 4Hz UI repaint.
    private func setPendingReason(_ reason: KubeBridgePendingReason?) {
        guard pendingReason != reason else { return }
        pendingReason = reason
        onStateChanged?()
    }

    /// Fail anything that has waited past `queueDeadline` behind contention.
    /// See the header: without this, a captain typing for a minute builds a
    /// backlog of stale polls that all fire at once when they stop.
    private func expireStaleQueuedRequests() {
        let now = Date()
        guard queue.contains(where: { now.timeIntervalSince($0.queuedAt) > queueDeadline }) else { return }
        var kept: [KubeRequest] = []
        var expired: [KubeRequest] = []
        for request in queue {
            if now.timeIntervalSince(request.queuedAt) > queueDeadline { expired.append(request) } else { kept.append(request) }
        }
        queue = kept
        for request in expired {
            // `.busy` on purpose: waiting behind the captain's own typing is
            // contention, and must never count toward the give-up threshold.
            deliver(request, .failure(.busy("\(request.command.shortLabel) waited too long for a free terminal")))
        }
    }

    private func failFront(_ error: KubeBridgeError) {
        guard !queue.isEmpty else { return }
        let request = queue.removeFirst()
        deliver(request, .failure(error))
    }

    private func checkInFlight() {
        guard var current = inFlight else { return }
        guard let target else {
            finish(.failure(.unavailable("the feed tab is no longer available")))
            return
        }
        if Date().timeIntervalSince(current.startedAt) > commandTimeout {
            finish(.failure(.timeout))
            return
        }

        // GL-34: the end marker is the last thing a completed command prints,
        // so it is on screen when it arrives - a viewport read is a
        // sufficient "is it done?" probe on most ticks, with a periodic full
        // read for the scrolled-away case.
        current.ticks += 1
        inFlight = current
        let periodicFullScan = current.ticks % Self.fullScanEvery == 0
        if !periodicFullScan {
            let viewport = target.currentViewportLines()
            guard viewport.contains(where: { isMarkerLine($0, marker: current.endMarker) }) else { return }
        }

        let allLines = target.currentBufferLines()
        // **Marker-relative, never index-relative** (`fm/grandline-k8s-ui-revamp`,
        // bug 2). `searchFromLine` was an *absolute* index into the buffer,
        // captured at injection time, and that is only stable while the buffer
        // is still growing. A feed tab has a bounded scrollback, so once it
        // saturates the emulator evicts from the top: `currentBufferLines()`
        // stops growing (`allLines.count > searchFromLine` is false forever, so
        // a perfectly good command times out) and every surviving line has
        // *shifted down* by however many were evicted, so the start marker can
        // now sit before the recorded index. Both failures land as a bare
        // "timed out waiting for kubectl" on a describe that ran fine minutes
        // earlier - exactly the intermittency the captain reported.
        //
        // Both markers carry a fresh UUID per request, so they are unique in
        // the buffer by construction and searching the whole of it is exact.
        // `searchFromLine` survives only as a cheap *hint*: when the start
        // marker really is at or after it (the common, unsaturated case) the
        // search is unchanged; when it is not, the marker still wins.
        // Order matters and is unchanged from before this fix: the **end**
        // marker is what says "the command finished", so its absence means
        // "still running" (bounded by `commandTimeout` above), while an end
        // marker with no start marker before it is a genuine
        // `markersNotFound` - the shape a shell that swallowed our echo
        // produces, and one the backoff cases depend on.
        guard let endIdx = Self.markerIndex(in: allLines, marker: current.endMarker,
                                            hint: current.searchFromLine) else { return }
        // `lastIndex` on a slice returns an index into the *base* array.
        guard let startIdx = allLines[..<endIdx]
            .lastIndex(where: { isMarkerLine($0, marker: current.startMarker) }) else {
            finish(.failure(.markersNotFound))
            return
        }
        // Concurrency guard: a real keystroke at any point after injection
        // means the shell's input/output could have interleaved with ours -
        // discard rather than return corrupted output, matching
        // `SRELeadBridge.checkInFlight`'s own rule.
        if let last = target.lastUserActivity, last > current.startedAt {
            finish(.failure(.discarded("the feed tab received input while the command was running")))
            return
        }
        finish(.success(allLines[(startIdx + 1)..<endIdx].joined(separator: "\n")))
    }

    private func finish(_ result: Result<String, KubeBridgeError>) {
        guard let current = inFlight else { return }
        inFlight = nil
        inFlightLabel = nil
        deliver(current.request, result)
        // Only pump on after delivering, so a completion that enqueues more
        // work (the Cluster sweep's own chaining) is already in the queue.
        pump()
    }

    /// Records the outcome's effect on the give-up state **before** calling
    /// the completion, so a caller reading `hasStoppedRetrying` from inside
    /// its own callback always sees this outcome's effect rather than a stale
    /// one - `KubeContextBridge.report`'s own rule.
    private func deliver(_ request: KubeRequest, _ result: Result<String, KubeBridgeError>) {
        switch result {
        case .success:
            AppLog.ui.info("KubeBridge: \(request.command.shortLabel, privacy: .public) succeeded")
            consecutiveFailureCount = 0
            lastFailureMessage = nil
        case .failure(let error):
            AppLog.ui.error("""
                KubeBridge: \(request.command.shortLabel, privacy: .public) failed - \
                \(error.message, privacy: .public) (counts toward give-up: \
                \(error.countsAsGenuineFailure, privacy: .public))
                """)
            lastFailureMessage = error.message
            if error.countsAsGenuineFailure {
                consecutiveFailureCount += 1
                if consecutiveFailureCount >= maxConsecutiveFailures { giveUp() }
            }
        }
        request.completion(result)
        onStateChanged?()
    }

    /// Stop everything and refuse further work until `resume()`. Every queued
    /// request is failed rather than left dangling - a caller that never
    /// hears back cannot tell "gave up" from "still running".
    private func giveUp() {
        AppLog.ui.error("""
            KubeBridge: giving up after \(self.consecutiveFailureCount, privacy: .public) consecutive \
            genuine failures - \(self.lastFailureMessage ?? "no detail", privacy: .public)
            """)
        hasStoppedRetrying = true
        timer?.invalidate()
        timer = nil
        inFlight = nil
        inFlightLabel = nil
        pendingReason = nil
        let pending = queue
        queue.removeAll()
        let reason = lastFailureMessage ?? "kubectl kept failing in the feed tab"
        for request in pending {
            request.completion(.failure(.stopped(reason)))
        }
    }

    #if FM_SELFTESTS
    /// Whether the 4Hz poll timer is currently scheduled - the idle-stop
    /// (`tick()`) is only observable through this.
    var debugIsPolling: Bool { timer != nil }
    #endif

    /// A line counts as the marker only when it is *exactly* the marker: the
    /// terminal's echo of the typed input contains it as a substring but is
    /// never equal to it (`SRELeadBridge.isMarkerLine`'s reasoning).
    private func isMarkerLine(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == marker
    }

    /// Locates a per-request marker in the buffer, using `hint` (the line
    /// count recorded at injection time) only as a **fast path**.
    ///
    /// Not `private`, so `KubeBridgeSelfTest` can drive the eviction case
    /// directly - a real scrollback eviction cannot be produced against
    /// `FakeBridgeTerminal` without teaching it a whole circular buffer.
    ///
    /// Why the fall-back matters (`fm/grandline-k8s-ui-revamp`, bug 2): once
    /// the feed tab's scrollback saturates, the emulator evicts from the top,
    /// so the recorded absolute index points *past* where the marker now
    /// lives. The hinted slice then finds nothing and the whole buffer is
    /// searched instead. The marker carries a fresh UUID per request, so a
    /// full-buffer search is exact rather than a guess; `lastIndex` picks the
    /// most recent occurrence purely as belt and braces.
    static func markerIndex(in lines: [String], marker: String, hint: Int) -> Int? {
        func matches(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces) == marker }
        if hint >= 0, hint < lines.count,
           let hinted = lines[hint...].lastIndex(where: matches) {
            return hinted
        }
        return lines.lastIndex(where: matches)
    }
}
