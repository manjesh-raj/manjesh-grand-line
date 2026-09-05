// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-sre-lead-shared-terminal`: the file-based bridge that lets SRE
// Lead's kubectl MCP tool (`native/Scripts/sre_kubectl_mcp.py`, a subprocess of
// `claude`, itself in its own tmux session - see `SRELead.swift`) run a kubectl
// command in the *same, already-authenticated* interactive terminal tab the
// captain used to log all the way into the connected host, instead of opening a
// second, independent SSH connection.
//
// Why: the captain confirmed a hard constraint on the real "EKS Preprod
// Bastion" host - its EKS Bastion hop is username/password-gated by policy,
// with no SSH key auth possible there. Five prior attempts (PRs #70-73, plus
// an abandoned PTY investigation) all tried to make a second, independent,
// fully-automated SSH connection complete that same login chain - which can
// never work, since nothing can supply a password that is not stored
// anywhere, by design. See `sre_kubectl_mcp.py`'s module docstring and the
// AGENTS.md SRE Lead bullet for the full history; do not resurrect a second-
// connection approach for this or any other password-gated hop.
//
// The Python script and this Swift app are different processes with no shared
// memory, so the bridge is a small polling protocol over files in a per-session
// scratch directory (`SRELeadSession.bridgeDir`, created by `SRELead.setUp`):
// Python writes `request-<id>.json` (`{"command": "<kubectl ...>"}`), this
// class notices it, injects `<command>` into the target tab exactly the way
// `Snippet`'s "Run" action already does (`TerminalView.send(txt:)` -
// `ConsoleController.runSnippetInActiveTab`/`runStartupSnippet`), wrapped with
// two fresh random markers so the real output can be extracted unambiguously
// from the tab's scrollback, then writes `response-<id>.json`. Python polls for
// that file to appear (see `_run_kubectl` there) up to its own timeout.

import Foundation

/// Everything `SRELeadBridge` needs from a terminal it injects commands into
/// and reads output back from, abstracted so the polling/extraction/busy-
/// detection logic below can be unit-tested without AppKit or SwiftTerm - see
/// `FirstmateCockpitTests.SRELeadBridgeTests`'s `FakeBridgeTerminal`. `TabModel`
/// conforms below by delegating to its own `terminal`.
protocol SRELeadBridgeTerminal: AnyObject {
    /// Type `text` into the terminal, exactly like `TerminalView.send(txt:)`.
    func sendCommand(_ text: String)

    /// The terminal's entire current buffer, one entry per row - the same
    /// shape `Terminal.getBufferAsData()` already returns, just split into
    /// lines.
    ///
    /// This is **not** cheap on a real terminal: it translates every row of a
    /// 10,000-line scrollback to a string. GL-34 is exactly that cost being
    /// paid on the main thread on every tick, so it is now called only twice
    /// per request - once to record where this request's output starts, and
    /// once when the end marker has actually been seen.
    func currentBufferLines() -> [String]

    /// Just the rows currently on screen (GL-34).
    ///
    /// The end marker is the last thing a completed command prints before the
    /// prompt comes back, so it is on screen when it arrives - which makes a
    /// viewport-sized read (tens of rows) a sufficient "is it done yet?"
    /// probe, in place of a whole-scrollback read. `checkInFlight` still falls
    /// back to a full read periodically, for the one case this cannot see: the
    /// captain scrolling the view away while a command runs (scrolling is not
    /// keystroke activity, so it does not trip the input guard).
    func currentViewportLines() -> [String]

    /// The most recent moment the captain (a real keystroke or paste, never
    /// this bridge's own `sendCommand`) touched this terminal, or `nil` if
    /// never. Used to refuse a request when the tab looks actively in use,
    /// and to detect (after the fact) that the captain typed into the tab
    /// while an injected command was still running.
    var lastUserActivity: Date? { get }

    /// Pin (or release) the wide, shallow terminal geometry a tab whose
    /// output is *parsed* needs - see `CockpitTerminalView`'s own
    /// `applyMachineReadableGeometry` for the mechanism and the measured
    /// numbers, and `Vendor/SwiftTerm/README.md`'s "Fifth patch" for why a
    /// vendored change was required to make it stick.
    ///
    /// Defaulted to a no-op so a bridge target that has no real terminal
    /// behind it (every self-test's stand-in) needs no implementation, and so
    /// a *future* bridge target that genuinely cannot widen degrades to
    /// today's behaviour rather than failing to compile.
    func setMachineReadableGeometry(_ enabled: Bool)
}

extension SRELeadBridgeTerminal {
    func setMachineReadableGeometry(_ enabled: Bool) {}
}

/// Bridges one dedicated host page's SRE Lead session to its primary
/// interactive tab.
///
/// **How this class learns there is work to do (3.1 of
/// `data/grandline-full-app-audit/report.md`).** A request arrives as a
/// `request-<id>.json` file that a *different process*
/// (`sre_kubectl_mcp.py`, itself a subprocess of `claude`) writes into
/// `bridgeDir` - so unlike `KubeBridge`, nothing in this process knows when
/// to look. This class used to answer that with one always-running 5Hz
/// `Timer` whose idle half did two `FileManager` directory enumerations a
/// second, per SRE-Lead-active tab, up to the 5-tab cap, for the life of the
/// session - including with Console hidden and the app backgrounded. That is
/// the cost the audit measured: invisible, but real and permanent.
///
/// It is now event-driven, with a timer in two roles rather than one:
///
///   - **A `DispatchSource` vnode watcher on `bridgeDir`** (`.write`, plus
///     `.delete`/`.rename` so a dir that goes away is noticed) is the real
///     "there is something to claim" signal. It costs nothing while idle and
///     is *more* responsive than the old poll - a request is claimed the
///     moment the file lands rather than up to `idlePollInterval` later.
///     The handler runs on `.main` because every step of handling a request
///     (`sendCommand`, reading the terminal buffer) must happen there anyway
///     (AppKit/SwiftTerm).
///   - **The `Timer` is now scheduled per state** (`rescheduleTimerIfNeeded`):
///     `pollInterval` (5Hz) only while a command is genuinely in flight, and
///     otherwise a slow `idleSafetyNetInterval` sweep.
///
/// **Why the idle sweep is kept at all**, rather than stopping the timer
/// outright the way `KubeBridge.tick()` does: `KubeBridge`'s own requests are
/// enqueued *in-process* (`enqueue` calls `start()`), so a full idle-stop
/// there can never miss one. Here the producer is another process and the
/// wake-up is a kernel event, so a dropped event (a stale fd after the
/// directory is replaced, a watcher this class failed to install at all)
/// would mean SRE Lead silently hangs waiting on a tool call that was never
/// claimed. The sweep is the cheap re-derivation that bounds that failure to
/// one interval instead of forever - the same "don't fully trust the event,
/// keep a cheap re-check" posture this codebase already takes for a required
/// constraint tie (AGENTS.md gotcha 14) and for the scrolled-away end marker
/// (`fullScanEvery`). At 30s idle it is ~60x less work than the 2 scans a
/// second it replaces, and 4x less again while backgrounded.
///
/// **There is deliberately no visibility pause here**, unlike
/// `KubeContextBridge` (audit 3.2). An SRE Lead investigation is
/// asynchronous: the captain asks a question, navigates away, and the agent's
/// tool call must still be served. The watcher already makes an unseen tab
/// cost nothing while idle, so pausing would buy no energy and would strand a
/// real request.
final class SRELeadBridge {
    private let bridgeDir: URL
    private weak var target: SRELeadBridgeTerminal?
    private var timer: Timer?
    /// The interval `timer` is currently scheduled at, so
    /// `rescheduleTimerIfNeeded` can leave an already-correct timer alone
    /// rather than tearing one down and building an identical one on every
    /// tick.
    private var scheduledTimerInterval: TimeInterval?
    /// The vnode watcher on `bridgeDir`, and the descriptor it owns. The
    /// descriptor is closed by the source's own cancel handler, which is the
    /// only safe place to close it (cancelling is asynchronous).
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var inFlight: InFlight?
    /// GL-34 throttles: when the idle request scan last ran, and how many
    /// ticks the current in-flight command has been checked for.
    private var lastIdleScan: Date?
    private var inFlightTicks = 0

    /// F8 (incident mode): fired when `sre_kubectl_mcp.py`'s `run_runbook`
    /// finishes and drops an `event-<id>.json` summary in this same bridge
    /// directory.
    ///
    /// **This observes an execution, it never performs one.** The runbook
    /// still runs exactly where it always did - inside `run_runbook`, step by
    /// step, through `_execute_via_bridge`, which is the same command-injection
    /// path every `kubectl_readonly` call already uses. All this adds is a
    /// summary file the tool writes once at the end, so the app can record
    /// that it happened without inferring it from a sequence of anonymous
    /// `request-*.json` commands (which carry no runbook identity at all).
    var onRunbookRun: ((RunbookRunEvent) -> Void)?

    /// The fields `run_runbook`'s own result already computes. No log output
    /// and no command text crosses this boundary - the incident record only
    /// ever says *which* runbook ran and how many of its steps did.
    struct RunbookRunEvent: Equatable {
        let name: String
        let ran: Int
        let total: Int
        let ok: Bool
        let refused: Bool
    }

    /// A request is refused as "busy" if the captain touched the tab within
    /// this many seconds before injection. An instance property (not a
    /// `static let`), defaulted below, so `FirstmateCockpitTests` can pass a
    /// much smaller value and keep the test suite fast rather than sleeping
    /// through the production window.
    let userActivityQuietWindow: TimeInterval

    /// Stays comfortably under `sre_kubectl_mcp.py`'s own `_TIMEOUT_SECONDS`
    /// (30s) so a timeout here always produces a real response file before
    /// Python's own poll gives up. Also overridable for tests, for the same
    /// reason as `userActivityQuietWindow`.
    let commandTimeout: TimeInterval

    /// `fm/grandline-k8s-context-badge`: read before injecting - `true` when
    /// a sibling bridge on the same tab (`KubeContextBridge`, the context/
    /// namespace safety badge) is already mid-command. See that file's
    /// header for the full cross-bridge-collision reasoning: two
    /// independently-injected commands overlapping on one real shared shell
    /// genuinely interleave keystrokes, corrupting both. `nil` (the default)
    /// means "no sibling bridge to worry about," which is every existing
    /// caller/test's exact prior behavior.
    var isTerminalBusyElsewhere: (() -> Bool)?

    /// True while this bridge itself has an outstanding command - the seam
    /// `KubeContextBridge` reads via its own `isTerminalBusyElsewhere`
    /// closure before injecting.
    var isBusy: Bool { inFlight != nil }

    /// How often to poll for the in-flight command's end marker.
    ///
    /// Kept at 5Hz because a captain is waiting on a real answer here and the
    /// per-tick cost is now a viewport read rather than a full-scrollback one
    /// (GL-34) - this cadence is only paid while a command is genuinely
    /// running.
    static let pollInterval: TimeInterval = 0.2

    /// How often to look for a *new* request file while nothing is running
    /// (GL-34).
    ///
    /// This is the cost that used to be paid forever, per SRE-Lead-active tab:
    /// a directory enumeration five times a second whether or not the agent
    /// had asked for anything. A request comes from `claude` deciding to call
    /// a tool, which is seconds of model latency away regardless, so a 1Hz
    /// idle poll is invisible to the captain and is 5x less idle work.
    ///
    /// An instance property with a default, for the same reason
    /// `userActivityQuietWindow` and `commandTimeout` are: a self-test drives
    /// `tick()` by hand and must not have to sleep through a real second
    /// between two requests.
    let idlePollInterval: TimeInterval

    /// How often the *timer* sweeps `bridgeDir` while nothing is running -
    /// the safety net behind the vnode watcher, not the primary mechanism.
    /// See this class's header for why it exists rather than idle-stopping
    /// outright.
    ///
    /// An instance property with a default, for the same reason
    /// `idlePollInterval` is: a self-test asserts which cadence the timer is
    /// scheduled at and must be able to tell the two apart by value.
    let idleSafetyNetInterval: TimeInterval

    /// The idle sweep once the app has been inactive for
    /// `AppActivityState.backgroundThreshold`. The watcher still delivers a
    /// real request immediately, so stretching the *net* costs no
    /// responsiveness at all - it only removes wake-ups nobody is waiting on.
    let backgroundedIdleSafetyNetInterval: TimeInterval

    /// Reads the shared "has the captain been away a while?" answer
    /// (`AppActivityState`). A closure rather than a direct call so a
    /// self-test can reach the backgrounded branch without waiting five real
    /// minutes - the production default is exactly what the three pollers E3
    /// already gates read.
    var isBackgrounded: () -> Bool = { AppActivityState.shared.isBackgrounded }

    /// While a command is in flight, do a full-scrollback check this often
    /// even though the viewport probe found nothing - the scrolled-away case
    /// described on `currentViewportLines`.
    static let fullScanEvery = 10

    private struct InFlight {
        let id: String
        let startMarker: String
        let endMarker: String
        let startedAt: Date
        /// Only lines at or beyond this index (in the buffer snapshot taken
        /// right before injection) are ever searched - so a marker string
        /// that happens to appear earlier in scrollback (an unrelated prior
        /// run, or the captain's own typing) can never be mistaken for this
        /// request's own output.
        let searchFromLine: Int
    }

    init(
        bridgeDir: URL, target: SRELeadBridgeTerminal,
        userActivityQuietWindow: TimeInterval = 0.5, commandTimeout: TimeInterval = 25,
        idlePollInterval: TimeInterval = 1.0,
        idleSafetyNetInterval: TimeInterval = 30,
        backgroundedIdleSafetyNetInterval: TimeInterval = 120
    ) {
        self.bridgeDir = bridgeDir
        self.target = target
        self.userActivityQuietWindow = userActivityQuietWindow
        self.commandTimeout = commandTimeout
        self.idlePollInterval = idlePollInterval
        self.idleSafetyNetInterval = idleSafetyNetInterval
        self.backgroundedIdleSafetyNetInterval = backgroundedIdleSafetyNetInterval
    }

    deinit {
        timer?.invalidate()
        dirWatcher?.cancel()
    }

    func start() {
        stop()
        startWatchingBridgeDir()
        rescheduleTimerIfNeeded()
        // A request written between `SRELead.setUp()` finishing and the
        // watcher being installed would otherwise wait for the first idle
        // sweep. Cheap, and it makes "activation claims anything already
        // waiting" true rather than probable.
        directoryChanged()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scheduledTimerInterval = nil
        stopWatchingBridgeDir()
        inFlight = nil
        lastIdleScan = nil
        inFlightTicks = 0
    }

    // MARK: Timer cadence

    /// The cadence the current state wants: fast only while a command is
    /// genuinely running, otherwise the slow watcher-safety-net sweep.
    private func desiredTimerInterval() -> TimeInterval {
        if inFlight != nil { return Self.pollInterval }
        return isBackgrounded() ? backgroundedIdleSafetyNetInterval : idleSafetyNetInterval
    }

    /// Rebuild `timer` only when the interval the state wants has actually
    /// changed. Called at the end of every `tick()`, so entering and leaving
    /// an in-flight command switches cadence on its own with no caller
    /// having to remember to.
    private func rescheduleTimerIfNeeded() {
        let want = desiredTimerInterval()
        if timer != nil, scheduledTimerInterval == want { return }
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: want, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 3.4: let the kernel coalesce this wake-up with nearby work rather
        // than demanding an exact one. Apple's own battery guidance.
        t.tolerance = want * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scheduledTimerInterval = want
    }

    #if FM_SELFTESTS
    /// Which interval the timer is scheduled at right now, or `nil` when no
    /// timer is scheduled - the seam the self-test reads to prove the idle
    /// cadence is genuinely slow rather than that a tick happened to be
    /// cheap.
    var debugScheduledTimerInterval: TimeInterval? { scheduledTimerInterval }

    /// Whether the vnode watcher is installed - the other half of that proof:
    /// a slow idle timer with no watcher behind it would be a responsiveness
    /// regression, not a fix.
    var debugIsWatchingBridgeDir: Bool { dirWatcher != nil }
    #endif

    // MARK: Watching `bridgeDir` for a request another process wrote

    private func startWatchingBridgeDir() {
        stopWatchingBridgeDir()
        let fd = open(bridgeDir.path, O_EVTONLY)
        guard fd >= 0 else {
            // Not fatal, and deliberately not an error the captain sees: the
            // idle sweep still claims every request, just up to one interval
            // later. Logged because a bridge running on the sweep alone is a
            // real (if bounded) responsiveness change worth being able to see
            // in `log show` (GL-11).
            let code = errno
            AppLog.ui.info("SRELeadBridge: could not watch \(self.bridgeDir.path, privacy: .public) for requests (errno \(code, privacy: .public)); falling back to the periodic sweep alone.")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self, let current = self.dirWatcher else { return }
            // `.delete`/`.rename` mean this descriptor now refers to
            // something that is no longer the bridge directory, so the
            // watcher has to be rebuilt against whatever is at that path now
            // (or give up to the sweep if nothing is). Read before the scan,
            // since the scan may itself write a response file.
            let stale = !current.data.intersection([.delete, .rename]).isEmpty
            self.directoryChanged()
            if stale { self.startWatchingBridgeDir() }
        }
        // The only correct place to close the descriptor: cancellation is
        // asynchronous, so closing it anywhere else can close an fd the
        // source is still using (and, worse, one a later `open` has reused).
        src.setCancelHandler { close(fd) }
        dirWatcher = src
        src.resume()
    }

    private func stopWatchingBridgeDir() {
        dirWatcher?.cancel()
        dirWatcher = nil
    }

    /// A real file-system event is the authoritative "there is something to
    /// claim" signal, so it must not be dropped by `tick()`'s own idle
    /// throttle - clearing `lastIdleScan` is what makes the very next scan
    /// run regardless of how recently one did.
    private func directoryChanged() {
        lastIdleScan = nil
        tick()
    }

    /// Records one real `bridgeDir` enumeration. Compiled away entirely
    /// outside a self-test build - this exists only so 3.1's own suite can
    /// assert the audit's stated cost in the audit's own unit (directory
    /// scans per unit time) rather than only asserting the timer cadence
    /// that produces them.
    private func noteDirectoryScan() {
        #if FM_SELFTESTS
        directoryScanCount += 1
        #endif
    }

    #if FM_SELFTESTS
    /// How many times this bridge has enumerated `bridgeDir`. The idle half
    /// of the old 5Hz poll did two of these a second, per SRE-Lead-active
    /// tab, forever.
    private(set) var directoryScanCount = 0

    /// Drives the exact path the real vnode handler calls. A headless
    /// self-test binary never pumps a run loop, so the kernel event itself
    /// cannot be awaited - the same reason every case in
    /// `SRELeadBridgeSelfTest` calls `tick()` by hand rather than relying on
    /// `start()`'s timer.
    func debugSimulateDirectoryChange() { directoryChanged() }
    #endif

    // MARK: Polling

    func tick() {
        // Whatever this tick does, the cadence the *next* one runs at is
        // decided from the state this one leaves behind.
        defer { if timer != nil || scheduledTimerInterval != nil { rescheduleTimerIfNeeded() } }
        if let current = inFlight {
            checkInFlight(current)
        }
        if inFlight != nil {
            // Still busy (either it was already running, or `checkInFlight`
            // just started it) - any other request that shows up while busy
            // is refused outright rather than silently queued, so a captain
            // (or a parallel SRE Lead subagent) calling this tool twice at
            // once gets a clear "busy" error instead of a long, surprising
            // wait or, worse, two commands' output getting interleaved.
            rejectAllPending(reason: "SRE Lead's shared terminal is already running another command - try again once it finishes.")
            return
        }
        // GL-34: the idle half of the poll runs at `idlePollInterval`, not at
        // the timer's own rate. `now`-based rather than a tick counter so a
        // timer that gets coalesced (App Nap, a busy main thread) still scans
        // about as often in wall-clock terms as intended.
        let now = Date()
        if let lastIdleScan, now.timeIntervalSince(lastIdleScan) < idlePollInterval { return }
        lastIdleScan = now
        drainEvents()
        guard let request = nextPendingRequest() else { return }
        beginProcessing(request)
    }

    /// Claims (reads, then deletes) every `event-*.json` the MCP tool has
    /// dropped since the last idle scan. Drained on the idle cadence, not on
    /// every 5Hz tick, for the same reason `nextPendingRequest` is: a
    /// directory enumeration five times a second per SRE-Lead-active tab is
    /// exactly the cost GL-34 removed. A runbook's event is written after its
    /// last step's response, so the bridge is never busy when one lands.
    private func drainEvents() {
        guard onRunbookRun != nil else { return }
        let fm = FileManager.default
        noteDirectoryScan()
        guard let files = try? fm.contentsOfDirectory(at: bridgeDir, includingPropertiesForKeys: nil) else { return }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.lastPathComponent.hasPrefix("event-") && file.pathExtension == "json" {
            let data = try? Data(contentsOf: file)
            // Deleted on claim, exactly like a request file, so a slow tick
            // can never report the same runbook run twice.
            try? fm.removeItem(at: file)
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["kind"] as? String) == "runbook_run",
                  let name = obj["runbook"] as? String, !name.isEmpty else { continue }
            onRunbookRun?(RunbookRunEvent(name: name,
                                          ran: obj["ran"] as? Int ?? 0,
                                          total: obj["total"] as? Int ?? 0,
                                          ok: obj["ok"] as? Bool ?? false,
                                          refused: obj["refused"] as? Bool ?? false))
        }
    }

    private struct PendingRequest { let id: String; let command: String }

    /// Claims (reads, then deletes) the oldest waiting request file, if any.
    /// Deleting immediately on claim means a request is never processed
    /// twice, even if a tick runs slowly.
    private func nextPendingRequest() -> PendingRequest? {
        let fm = FileManager.default
        noteDirectoryScan()
        guard let files = try? fm.contentsOfDirectory(at: bridgeDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let requestFiles = files
            .filter { $0.lastPathComponent.hasPrefix("request-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let file = requestFiles.first else { return nil }

        let id = String(file.lastPathComponent.dropFirst("request-".count).dropLast(".json".count))
        guard let data = try? Data(contentsOf: file) else {
            try? fm.removeItem(at: file)
            return nil
        }
        try? fm.removeItem(at: file)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String, !command.isEmpty else {
            return nil
        }
        return PendingRequest(id: id, command: command)
    }

    private func rejectAllPending(reason: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: bridgeDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("request-") && file.pathExtension == "json" {
            let id = String(file.lastPathComponent.dropFirst("request-".count).dropLast(".json".count))
            try? fm.removeItem(at: file)
            writeResponse(id: id, ok: false, error: reason)
        }
    }

    // MARK: Starting a command

    private func beginProcessing(_ request: PendingRequest) {
        guard let target else {
            writeResponse(id: request.id, ok: false, error: "The connected host's interactive terminal tab is no longer available - reconnect the host first.")
            return
        }
        let now = Date()
        if let last = target.lastUserActivity, now.timeIntervalSince(last) < userActivityQuietWindow {
            writeResponse(id: request.id, ok: false, error: "The connected terminal tab looks like it's actively being used right now - try again in a moment.")
            return
        }
        // `fm/grandline-k8s-context-badge`: refuse rather than collide with a
        // sibling bridge's own in-flight command on this same tab - see
        // `isTerminalBusyElsewhere`'s doc comment.
        if isTerminalBusyElsewhere?() == true {
            writeResponse(id: request.id, ok: false, error: "The context/namespace badge is currently refreshing on this tab - try again in a moment.")
            return
        }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let startMarker = "SRE_LEAD_START_\(unique)"
        let endMarker = "SRE_LEAD_END_\(unique)"
        let searchFromLine = target.currentBufferLines().count

        target.sendCommand("echo \(startMarker); \(request.command); echo \(endMarker)\n")
        inFlightTicks = 0
        inFlight = InFlight(
            id: request.id, startMarker: startMarker, endMarker: endMarker,
            startedAt: now, searchFromLine: searchFromLine
        )
    }

    // MARK: Watching the in-flight command

    private func checkInFlight(_ current: InFlight) {
        guard let target else {
            writeResponse(id: current.id, ok: false, error: "The connected host's interactive terminal tab is no longer available - reconnect the host first.")
            inFlight = nil
            return
        }

        if Date().timeIntervalSince(current.startedAt) > commandTimeout {
            writeResponse(id: current.id, ok: false, error: "Timed out waiting for the command to finish in the shared terminal.")
            inFlight = nil
            return
        }

        // GL-34: the cheap probe. Only when the end marker is genuinely on
        // screen (or the periodic safety net comes due) is the whole
        // scrollback read and split - which is what this method used to do
        // five times a second, per active tab, against a 10,000-line buffer.
        inFlightTicks += 1
        let sawEndMarkerOnScreen = target.currentViewportLines()
            .contains { isMarkerLine($0, marker: current.endMarker) }
        let periodicFullScan = inFlightTicks % Self.fullScanEvery == 0
        guard sawEndMarkerOnScreen || periodicFullScan else { return }

        let allLines = target.currentBufferLines()
        guard allLines.count > current.searchFromLine else { return }
        let newLines = Array(allLines[current.searchFromLine...])

        guard let endIdx = newLines.firstIndex(where: { isMarkerLine($0, marker: current.endMarker) }) else {
            return // still running
        }
        guard let startIdx = newLines[..<endIdx].firstIndex(where: { isMarkerLine($0, marker: current.startMarker) }) else {
            writeResponse(id: current.id, ok: false, error: "Could not find the command's own output markers in the terminal - the tab may have changed unexpectedly.")
            inFlight = nil
            return
        }

        // Concurrency guard: a real keystroke/paste from the captain at any
        // point after injection means the shared shell's input/output could
        // have interleaved with ours - discard rather than risk returning
        // corrupted output.
        if let last = target.lastUserActivity, last > current.startedAt {
            writeResponse(id: current.id, ok: false, error: "The terminal received input from the captain while this command was running, so its output can't be trusted - discarded. Try again.")
            inFlight = nil
            return
        }

        let output = newLines[(startIdx + 1)..<endIdx].joined(separator: "\n")
        writeResponse(id: current.id, ok: true, output: output)
        inFlight = nil
    }

    /// A line counts as "the marker itself" only when it is *exactly* the
    /// marker (after trimming whitespace) - the terminal's echo of the typed
    /// input line (`"echo <marker>; <command>; echo <otherMarker>"`) contains
    /// the marker as a substring but is never equal to it, so this can't
    /// mistake the echoed command for the marker's own output.
    private func isMarkerLine(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == marker
    }

    // MARK: Responses

    private func writeResponse(id: String, ok: Bool, output: String? = nil, error: String? = nil) {
        var obj: [String: Any] = ["ok": ok]
        if let output { obj["output"] = output }
        if let error { obj["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }

        let fm = FileManager.default
        let tmp = bridgeDir.appendingPathComponent("response-\(id).json.tmp")
        let final = bridgeDir.appendingPathComponent("response-\(id).json")
        guard (try? data.write(to: tmp)) != nil else { return }
        try? fm.removeItem(at: final)
        try? fm.moveItem(at: tmp, to: final)
    }
}

// MARK: - TabModel conformance

extension TabModel: SRELeadBridgeTerminal {
    func sendCommand(_ text: String) {
        terminal.send(txt: text)
    }

    func currentBufferLines() -> [String] {
        guard let data = terminal.terminal?.getBufferAsData() else { return [] }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.components(separatedBy: "\n")
    }

    /// GL-34. `Terminal.getLine(row:)` is indexed from the *display* offset,
    /// so this is genuinely the rows on screen (which is also why it cannot
    /// see a marker the captain has scrolled away from - see
    /// `SRELeadBridge.fullScanEvery` for the safety net that covers it).
    func currentViewportLines() -> [String] {
        guard let term = terminal.terminal else { return [] }
        return (0..<term.rows).compactMap { term.getLine(row: $0)?.translateToString(trimRight: true) }
    }

    var lastUserActivity: Date? { terminal.lastUserActivity }

    /// `fm/grandline-k8s-ui-revamp`. Scoped to this one tab's own terminal
    /// view: the brief is explicit that no other tab's column width may
    /// change, and this is the only path that touches it.
    func setMachineReadableGeometry(_ enabled: Bool) {
        terminal.applyMachineReadableGeometry(enabled, interactiveScrollback: ConsoleController.interactiveScrollbackLines)
    }
}
