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

/// One queued or in-flight request.
private struct KubeRequest {
    let id: UUID
    let command: KubeCommand
    let commandText: String
    let queuedAt: Date
    let completion: (Result<String, KubeBridgeError>) -> Void
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

    /// GL-34's safety net, same value and same reasoning as
    /// `SRELeadBridge.fullScanEvery`: the cheap viewport probe cannot see a
    /// marker the captain has scrolled away from (scrolling is not keystroke
    /// activity, so it never trips the input guard), so every Nth tick falls
    /// back to a full buffer read.
    static let fullScanEvery = 10

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

    /// True while this bridge holds the tab - the seam a sibling bridge reads.
    var isBusy: Bool { inFlight != nil }

    var queueDepth: Int { queue.count }

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

    /// Stops the timer, fails everything still queued, and forgets any
    /// in-flight command.
    ///
    /// Deliberately leaves `consecutiveFailureCount`/`hasStoppedRetrying`
    /// alone - this is "pause" (the page went away, the feed tab changed),
    /// not "give up", exactly like `KubeContextBridge.stop()`.
    func stop() {
        timer?.invalidate()
        timer = nil
        inFlight = nil
        inFlightLabel = nil
        let pending = queue
        queue.removeAll()
        for request in pending {
            request.completion(.failure(.unavailable("the log/cluster feed was stopped")))
        }
        onStateChanged?()
    }

    /// The captain's own explicit "try again" after this bridge gave up -
    /// the single entry point back in, matching `KubeContextBridge.start()`'s
    /// deliberate unification of activation and retry.
    func resume() {
        consecutiveFailureCount = 0
        hasStoppedRetrying = false
        lastFailureMessage = nil
        start()
        onStateChanged?()
    }

    /// Points this bridge at a different terminal (the captain picked a
    /// different feed tab). Everything queued against the old tab is failed
    /// rather than silently re-aimed - a `describe` for a pod discovered on
    /// one cluster must never be answered by a different one.
    func retarget(_ newTarget: SRELeadBridgeTerminal?) {
        stop()
        target = newTarget
        consecutiveFailureCount = 0
        hasStoppedRetrying = false
        lastFailureMessage = nil
        if newTarget != nil { start() }
        onStateChanged?()
    }

    // MARK: Requests

    /// Queues one read-only command. The completion always fires exactly
    /// once, on the main thread, with either the command's raw text (whatever
    /// the shell printed between the markers) or a `KubeBridgeError`.
    func enqueue(_ command: KubeCommand, completion: @escaping (Result<String, KubeBridgeError>) -> Void) {
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
        queue.append(KubeRequest(id: UUID(), command: command, commandText: text,
                                 queuedAt: Date(), completion: completion))
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
                      completion: @escaping ([(KubeCommand, Result<String, KubeBridgeError>)]) -> Void) {
        guard !commands.isEmpty else {
            completion([])
            return
        }
        var results: [(KubeCommand, Result<String, KubeBridgeError>)] = []
        var remaining = commands.count
        for command in commands {
            enqueue(command) { result in
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
    }

    /// Issue the next queued request if the tab will have it.
    private func pump() {
        guard inFlight == nil, !hasStoppedRetrying else { return }
        expireStaleQueuedRequests()
        guard let next = queue.first else { return }

        guard let target else {
            failFront(.unavailable("the feed tab is no longer available"))
            return
        }
        guard !isTerminalBusyElsewhere() else { return } // stay queued; retried next tick
        if let last = target.lastUserActivity, Date().timeIntervalSince(last) < userActivityQuietWindow {
            return // stay queued; the captain is typing in the feed tab
        }

        queue.removeFirst()
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let startMarker = "GL_KUBE_START_\(unique)"
        let endMarker = "GL_KUBE_END_\(unique)"
        let searchFromLine = target.currentBufferLines().count
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
        guard allLines.count > current.searchFromLine else { return }
        let newLines = Array(allLines[current.searchFromLine...])
        guard let endIdx = newLines.firstIndex(where: { isMarkerLine($0, marker: current.endMarker) }) else { return }
        guard let startIdx = newLines[..<endIdx].firstIndex(where: { isMarkerLine($0, marker: current.startMarker) }) else {
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
        finish(.success(newLines[(startIdx + 1)..<endIdx].joined(separator: "\n")))
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
            consecutiveFailureCount = 0
            lastFailureMessage = nil
        case .failure(let error):
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
        hasStoppedRetrying = true
        timer?.invalidate()
        timer = nil
        inFlight = nil
        inFlightLabel = nil
        let pending = queue
        queue.removeAll()
        let reason = lastFailureMessage ?? "kubectl kept failing in the feed tab"
        for request in pending {
            request.completion(.failure(.stopped(reason)))
        }
    }

    /// A line counts as the marker only when it is *exactly* the marker: the
    /// terminal's echo of the typed input contains it as a substring but is
    /// never equal to it (`SRELeadBridge.isMarkerLine`'s reasoning).
    private func isMarkerLine(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == marker
    }
}
