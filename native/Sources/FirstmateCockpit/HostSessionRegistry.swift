// HostSessionRegistry.swift - the app's one answer to "which saved hosts have
// a live SSH session right now, and which of them is the captain looking at?"
//
// `fm/grandline-session-switcher`. Before this, "connected" was implied by the
// existence of a key in `AppShellController.hostConsoles` and read in exactly
// one place (`isHostConnected`, for F9's multi-host picker). The session
// switcher needs the same fact in four more: the persistent session strip on
// the app-wide bar, the Hosts list's per-row live state, the ⌘K palette's
// pinned "Active sessions" group, and the ⌘⌃1…9 / ⌘] / ⌘[ shortcuts. Four
// more independent notions of "is this host live" is exactly how they start
// disagreeing, so this is one registry all five read.
//
// **It is a registry, not a monitor** - the same shape (and for the same
// reason) as `ServiceHealthRegistry`: it polls nothing, opens nothing, and
// never decides on its own that a session exists or has ended. The one writer
// is `AppShellController`, from the three moments it already owned that fact:
// `connectHost` (a page was built, or an existing one revealed), the reveal
// path (which page is showing), and `removeHostConsole` (a page was torn
// down). A second writer would be a second source of truth again.
//
// Thread contract: main thread only, like every other observable in this app's
// chrome. `dispatchPrecondition` says so rather than leaving it to convention,
// because a session's start/end is the kind of fact a background completion
// handler looks like a natural place to record.
import Foundation

/// One live SSH session, as much of it as any switcher surface needs.
///
/// Deliberately *not* a reference to the `ConsoleController` behind it: the
/// strip, the Hosts row and the palette all need a label, a colour and a
/// duration, and none of them should be able to reach into a terminal.
/// `AppShellController` keeps the controller half in `hostConsoles` and is the
/// only thing that maps an id back to one.
/// Whether a registered session has a live child process behind it, or is
/// only a *page* that exists (audit 2 §4.6/§6.3).
///
/// The distinction did not exist before F2 (#336): every entry in this
/// registry was created by a real `connectHost` that went on to appear, fork
/// `ssh` and land the captain in a shell. F2 registers a *restored* page
/// too - and a restored page deliberately forks nothing until the captain
/// opens it (that is the guarantee that stops a relaunch opening six SSH
/// connections and six Touch ID prompts), so the strip claimed
/// "connected · 14m", the Hosts row showed a live chip, and F9's picker
/// reported the host as connected, all for a page with no process at all.
/// #340's lock deferral widened it: now even the *showing* restored page has
/// nothing running until the app is unlocked.
///
/// Registering only started sessions was the other option the audit offered
/// and is the wrong one here: switching *into* a restored page is correct and
/// useful (revealing it is what connects it), so dropping it from the strip,
/// the shortcuts and ⌘K would remove the affordance F2 exists to provide.
/// What was wrong was never that the entry existed - only what it claimed.
enum HostSessionState: Equatable {
    /// A tab on this host's page has a live child process.
    case connected
    /// The page exists but nothing has started on it - an F2-restored page
    /// the captain has not opened yet, a page whose start the lock screen is
    /// still deferring, or one connected with `navigate: false` that never
    /// appeared. Switching to it starts it.
    case restored
}

struct HostSession: Equatable {
    let hostID: UUID
    /// The host's own label, re-read on every `register` so a renamed host is
    /// current everywhere the same way `connectHost`'s own closures already
    /// re-read it.
    var label: String
    /// The captain's own per-host colour (`Host.accentHex`) - a literal hue
    /// rather than a semantic `HelmTint`, exactly like
    /// `HelmAccentRow.Content.tintHex`, because it is a choice they made in
    /// the host editor and mapping it onto the nearest semantic tint would
    /// silently discard it. This is what makes a DEV pill amber and a PROD
    /// pill teal without either surface knowing what DEV or PROD mean.
    var accentHex: String?
    /// When this session was first opened. Set once, on the first `register`
    /// for a host, and deliberately *not* refreshed by a later re-reveal -
    /// "Connected · 14m" should say how long the session has been up, not how
    /// long since it was last looked at.
    var startedAt: Date

    /// Whether anything is actually running behind this entry. Set by
    /// `AppShellController` from the page's own `hasLiveSession`, never
    /// inferred here - this stays a registry that records a fact someone else
    /// established, the same contract `ServiceHealthRegistry` keeps.
    var state: HostSessionState

    /// `true` only for a genuinely live session. Every surface that claims
    /// "Connected" reads this rather than mere membership.
    var isConnected: Bool { state == .connected }

    /// What to say about this entry's age. A restored page has no connection
    /// to measure, so it says what it is instead of putting a duration on
    /// something that never started.
    var stateText: String {
        switch state {
        case .connected: return "Connected \u{00B7} \(durationText)"
        case .restored: return "Restored \u{00B7} not connected"
        }
    }

    /// "14m" / "2h 05m" / "just now". A whole-minute resolution on purpose:
    /// this string is rendered on a Hosts row that is rebuilt on page visit
    /// and on session change rather than on a timer (see
    /// `HostsController.liveSessionProvider`'s note), so a seconds-precise
    /// value would be visibly stale within a second of being drawn while a
    /// minutes-precise one is honest for a whole minute.
    static func durationText(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return String(format: "%dh %02dm", hours, minutes % 60)
    }

    var durationText: String { Self.durationText(since: startedAt) }
}

/// The live set, plus which one is on screen.
///
/// Order is **insertion order**, never sorted: the ⌘⌃1…9 shortcuts and the
/// strip's own left-to-right pill order are the same list, and re-sorting on
/// label would silently move a captain's ⌘⌃2 out from under them the moment
/// an unrelated host was renamed.
final class HostSessionRegistry {

    /// Fired after any change - a session opened, closed, renamed, or the
    /// active one moved. One notification for all four, because every reader
    /// re-renders from `sessions` wholesale rather than diffing.
    private var observers: [UUID: (HostSessionRegistry) -> Void] = [:]

    private(set) var sessions: [HostSession] = []

    /// The session whose page is showing, if any. `nil` whenever the captain
    /// is on an ordinary destination - a live session that is not on screen is
    /// still live, it is just not active.
    private(set) var activeHostID: UUID?

    // MARK: Read

    var isEmpty: Bool { sessions.isEmpty }

    func session(for hostID: UUID) -> HostSession? {
        sessions.first { $0.hostID == hostID }
    }

    func isLive(_ hostID: UUID) -> Bool { session(for: hostID) != nil }

    /// 1-based, matching the ⌘⌃1…9 hints the strip renders. `nil` past the
    /// ninth session - there is no tenth shortcut, and inventing one would
    /// put a hint on a pill nothing can reach.
    func shortcutIndex(for hostID: UUID) -> Int? {
        guard let index = sessions.firstIndex(where: { $0.hostID == hostID }), index < 9 else { return nil }
        return index + 1
    }

    /// The session `offset` steps from the active one, wrapping - ⌘] is
    /// `+1`, ⌘[ is `-1`. With nothing active (the captain is on an ordinary
    /// destination) this answers the *first* session for a forward step and
    /// the *last* for a backward one, so both shortcuts do something useful
    /// from anywhere rather than needing a session revealed first.
    func session(steppedBy offset: Int) -> HostSession? {
        guard !sessions.isEmpty else { return nil }
        guard let activeHostID, let current = sessions.firstIndex(where: { $0.hostID == activeHostID }) else {
            return offset >= 0 ? sessions.first : sessions.last
        }
        let count = sessions.count
        let next = ((current + offset) % count + count) % count
        return sessions[next]
    }

    // MARK: Write (AppShellController only)

    /// A session for `hostID` exists. Idempotent: a second call for a host
    /// that is already live refreshes its label and colour (a rename between
    /// connects) and leaves `startedAt` alone.
    ///
    /// `state` is the caller's answer to "is anything actually running on this
    /// page" (audit 2 §4.6) - see `HostSessionState`. A re-register never
    /// *downgrades* a live session to `.restored`: `connectHost` runs before
    /// the page has appeared, so it reports `.restored` even for a host that
    /// is already connected, and honouring that would blank a live pill on
    /// every re-reveal. `setState` is the one path that moves an entry either
    /// way, driven by the page's own start/teardown.
    func register(hostID: UUID, label: String, accentHex: String?, state: HostSessionState) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let index = sessions.firstIndex(where: { $0.hostID == hostID }) {
            var existing = sessions[index]
            let nextState = existing.isConnected ? existing.state : state
            guard existing.label != label || existing.accentHex != accentHex
                || existing.state != nextState else { return }
            existing.label = label
            existing.accentHex = accentHex
            existing.state = nextState
            sessions[index] = existing
        } else {
            sessions.append(HostSession(hostID: hostID, label: label,
                                        accentHex: accentHex, startedAt: Date(), state: state))
        }
        notify()
    }

    /// A page's "is anything running on it" answer changed (audit 2 §4.6).
    ///
    /// Restamps `startedAt` on the `.restored` -> `.connected` transition, so
    /// "Connected · 14m" measures the *connection* rather than however long
    /// the restored page had been sitting there unopened since launch - which
    /// is the same reason `register` leaves `startedAt` alone on a re-reveal.
    ///
    /// A no-op for a host with no entry, so a page can report freely without
    /// knowing whether the shell still tracks it.
    func setState(hostID: UUID, _ state: HostSessionState) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = sessions.firstIndex(where: { $0.hostID == hostID }) else { return }
        guard sessions[index].state != state else { return }
        var existing = sessions[index]
        if existing.state == .restored, state == .connected { existing.startedAt = Date() }
        existing.state = state
        sessions[index] = existing
        notify()
    }

    /// Whether `hostID` has a genuinely live session, as opposed to merely a
    /// page this registry knows about. The predicate every "Connected" claim
    /// and every immediate-send decision uses; `isLive` remains "is there an
    /// entry at all", which is what switching and the ⌘K grouping want.
    func isConnected(_ hostID: UUID) -> Bool {
        sessions.first(where: { $0.hostID == hostID })?.isConnected ?? false
    }

    /// The session for `hostID` is gone. A no-op for a host that was never
    /// live, so the teardown path can call it unconditionally.
    func unregister(hostID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = sessions.firstIndex(where: { $0.hostID == hostID }) else { return }
        sessions.remove(at: index)
        if activeHostID == hostID { activeHostID = nil }
        notify()
    }

    /// Which session's page is on screen. `nil` when none is.
    func setActive(_ hostID: UUID?) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Never claim a host that has no session - that would light a strip
        // pill for something the captain cannot switch back into.
        let resolved = hostID.flatMap { isLive($0) ? $0 : nil }
        guard activeHostID != resolved else { return }
        activeHostID = resolved
        notify()
    }

    // MARK: Observation

    /// Token-based, matching `ThemeManager.observe`/`BackgroundSignalsPoller.
    /// observeCounts` rather than a single overwritable closure - the strip,
    /// the Hosts page and the shell itself all need to hear every change.
    @discardableResult
    func observe(_ handler: @escaping (HostSessionRegistry) -> Void) -> UUID {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = UUID()
        observers[token] = handler
        handler(self)
        return token
    }

    func unobserve(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notify() {
        for handler in observers.values { handler(self) }
    }
}
