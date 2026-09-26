// Grand Line - native macOS app.
//
// The in-app Notification Center (`fm/grandline-notification-center`,
// captain-approved design: `data/grandline-notification-center/design-
// reference.html`). A single aggregation point for every "the captain
// should know about this" signal already computed somewhere else in the
// app - fleet decisions, PR readiness, tool updates, fork drift, Vault
// attention, machine-setup drift, SRE Lead replies, Shift due items, and
// fleet tasks finishing - so there is one bell + one badge + one list
// instead of a captain needing to remember to open six different pages.
//
// Mirrors this codebase's own established "app-lifetime singleton with an
// `observe`/notify shape" convention (`ThemeManager`, `FontSizeManager`,
// `DocsSyncCenter`) rather than inventing a new one. Every real source is a
// thin adapter (see `NotificationSources.swift`) that reads state a page
// already computes (or, for the handful of signals with nowhere else to
// live, a small dedicated poller - `BackgroundSignalsPoller.swift`) and
// calls `set(_:id:)`/`remove(id:)` here. This file owns none of the
// detection logic itself, only the aggregated list, its two clearing
// semantics, and the observer fan-out the bell/panel UI subscribe to.
//
// **`fm/grandline-notification-center-redesign` added three captain-facing
// states on top of that, and none of them is a clearing semantic.** Read
// state (the blue dot), snooze (hidden until a date, then back on its own)
// and per-source mute (hidden for the session) are all *views* of the
// published list - `stored` holds everything a source has published, and
// `entries` derives what is visible. That is deliberate: a snooze expiring
// has to bring a row back with no source involved, which only works if
// visibility is recomputed rather than remembered. Read state follows
// `dismissedDetail`'s own precedent and is keyed by the exact subtext, so a
// row whose detail moves on after being read goes back to unread rather than
// quietly hiding new information under a cleared dot.
//
// Two kinds of item, per the design doc's own "two fundamentally different
// kinds of item" section:
//   - `.actionNeeded` ("waiting for you"): a decision needs input, a PR is
//     ready, an SRE Lead reply is unread. These auto-clear the moment the
//     underlying condition resolves (the next `set`/`remove` from that
//     source reflects it) - there is no manual dismiss for this kind, since
//     dismissing something that still genuinely needs the captain would be
//     actively misleading.
//   - `.informational` ("FYI, something changed"): an update is available,
//     a fork is behind, a security tool needs attention, setup drifted.
//     These clear on resolution too, but can also be manually dismissed
//     ("I know, I'll do it later") via `dismiss(id:)`/
//     `dismissAllInformational()`. A
//     dismiss is remembered by the *exact subtext* of the dismissed entry
//     (`dismissedDetail`) - if the same underlying condition is still true
//     next time this source reports in with the identical detail text, the
//     dismissal holds and it stays hidden; the moment the detail text
//     changes (a new tool joins the update-available count, a fork's
//     behind-by count changes), that's materially new information and the
//     item resurfaces. This is the direct implementation of the design
//     doc's own resolution: "the honest default is to keep resurfacing it
//     until the real condition clears," while still honoring a "not now."
//
// Every source owns exactly one notification id and calls `set(_:id:)` with
// its own freshly-computed truth on every check: passing a real
// `AppNotification` means "this condition is true right now, here is its
// current text," passing `nil` means "resolved." There is no separate
// diffing step here and therefore no way for the same underlying condition
// to produce two entries - `id` is the dedup key, always exactly one entry
// per id. SRE Lead's per-tab replies are the one signal with more than one
// live id at once (`sre-lead.<tabID>`), each independently set/removed by
// its own tab.

import Foundation

enum AppNotificationKind: Equatable {
    case actionNeeded
    case informational
}

/// One sub-item of an expandable row - a tool with an update, a fork behind
/// upstream, a drifted setup check. The captain's reference opens these in
/// place so one tool can be updated without leaving the popover, which is why
/// `perform` is a real action rather than a second navigation.
///
/// `perform` is excluded from `Equatable` (closures cannot conform) for the
/// same reason `AppNotification.navigate` is: everything else fully
/// determines whether two children are the same child.
struct AppNotificationChild: Equatable {
    let id: String
    let name: String
    /// The version pair, the behind-by count, the expected-vs-found line.
    let meta: String
    /// `nil` for a child that is only information - no button is drawn.
    let actionLabel: String?
    /// A version pair reads as a version pair only in a monospaced face; a
    /// setup check's prose does not.
    let isMonospaced: Bool
    let perform: (() -> Void)?

    init(id: String, name: String, meta: String, actionLabel: String? = nil,
         isMonospaced: Bool = false, perform: (() -> Void)? = nil) {
        self.id = id
        self.name = name
        self.meta = meta
        self.actionLabel = actionLabel
        self.isMonospaced = isMonospaced
        self.perform = perform
    }

    static func == (lhs: AppNotificationChild, rhs: AppNotificationChild) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.meta == rhs.meta
            && lhs.actionLabel == rhs.actionLabel && lhs.isMonospaced == rhs.isMonospaced
    }
}

/// The one real action a row offers, revealed where the timestamp sits when
/// the row is hovered or selected. `doneMessage` is what the footer's toast
/// says afterwards - written by the source, because only the source knows
/// what its own action accomplished.
struct AppNotificationAction {
    let label: String
    let doneMessage: String
    let perform: () -> Void

    init(label: String, doneMessage: String, perform: @escaping () -> Void) {
        self.label = label
        self.doneMessage = doneMessage
        self.perform = perform
    }
}

/// One row in the panel. Two entries with the same `id` are always meant to
/// be the same logical notification (see `GrandLineNotificationCenter.set`);
/// `navigate`, `primaryAction` and each child's `perform` are excluded from
/// `Equatable` since closures can't conform - every other field fully
/// determines whether two entries are "the same," which is all the self-test
/// and `set`'s own resurface-on-change logic need.
///
/// **`date` is excluded too, and that is load-bearing.** Every source
/// re-publishes its own freshly-computed truth on every poll, so a `date` that
/// counted towards equality would make each pass look like a change - which
/// would re-notify every observer, re-mark a read row unread, and reset the
/// row's own "3h ago" to "just now" every fifteen minutes. Equality is about
/// the *content*; `set` keeps the date the entry already had whenever the
/// content is unchanged (see `set`).
struct AppNotification: Equatable {
    let id: String
    let title: String
    /// The row's detail line, on its own - "kubectl, helm, terraform",
    /// "Overdue by 1 day". The source name and the clear rule used to be
    /// crammed in here ("Updates · clears when installed"); they are their own
    /// fields now, because the redesign renders them in two different places
    /// (the detail's `Source: detail` prefix, and the expanded "clears when…"
    /// line).
    let subtext: String
    /// The display name of the page this came from - "Tasks", "Updates",
    /// "GitHub Sync", "Bootstrap". Also the key the context menu's "Mute …"
    /// mutes, so two entries from one page mute together.
    let source: String
    /// One sentence, the reference's own copy shape: "Clears when every update
    /// is installed."
    let clearCondition: String
    let kind: AppNotificationKind
    let tint: HelmTint
    /// When this condition was first seen. Drives the row's relative
    /// timestamp; see the type's own note above for why it is not part of `==`.
    let date: Date
    /// A timestamp the source states outright rather than one derived from
    /// `date` - "1d overdue" is a fact about a due date, not about when the
    /// app noticed.
    let timeText: String?
    /// Paints the detail line and the timestamp in the critical hue. Overdue,
    /// not merely old.
    let isWarning: Bool
    let children: [AppNotificationChild]
    let primaryAction: AppNotificationAction?
    let navigate: () -> Void

    init(id: String,
         title: String,
         subtext: String,
         source: String = "",
         clearCondition: String = "",
         kind: AppNotificationKind,
         tint: HelmTint,
         date: Date = Date(),
         timeText: String? = nil,
         isWarning: Bool = false,
         children: [AppNotificationChild] = [],
         primaryAction: AppNotificationAction? = nil,
         navigate: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtext = subtext
        self.source = source
        self.clearCondition = clearCondition
        self.kind = kind
        self.tint = tint
        self.date = date
        self.timeText = timeText
        self.isWarning = isWarning
        self.children = children
        self.primaryAction = primaryAction
        self.navigate = navigate
    }

    static func == (lhs: AppNotification, rhs: AppNotification) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtext == rhs.subtext
            && lhs.source == rhs.source && lhs.clearCondition == rhs.clearCondition
            && lhs.kind == rhs.kind && lhs.tint == rhs.tint
            && lhs.timeText == rhs.timeText && lhs.isWarning == rhs.isWarning
            && lhs.children == rhs.children
    }
}

/// An opaque handle to a live `GrandLineNotificationCenter.observe`
/// registration - mirrors `ThemeObservation`. Every observer in this app so
/// far (the topbar bell) is an app-lifetime singleton and can discard it.
final class NotificationCenterObservation {}

final class GrandLineNotificationCenter {
    static let shared = GrandLineNotificationCenter()

    /// Everything the sources have published and not withdrawn - including
    /// what is currently snoozed or muted away. `entries` is the visible view
    /// of this, and is what every caller outside this file reads.
    private var stored: [AppNotification] = []

    /// What the panel and the badge show: published, minus snoozed, minus
    /// muted. Deliberately a derived value rather than a second array - a
    /// snooze that expires has to bring a row back with no source involved,
    /// and that only works if "visible" is recomputed rather than remembered.
    var entries: [AppNotification] { stored.filter { isVisible($0) } }

    /// `id -> the subtext it had when dismissed`. See the file header for
    /// why the exact subtext (not just a bare "dismissed" bit) is what's
    /// remembered.
    private var dismissedDetail: [String: String] = [:]

    /// `id -> the subtext it had when marked read`, on exactly the same
    /// principle as `dismissedDetail`: a read row whose detail text changes
    /// is carrying information the captain has not seen, so it goes back to
    /// unread. That is what makes the blue dot mean something after the first
    /// time it is cleared.
    private var readDetail: [String: String] = [:]

    /// `id -> when it comes back`. A snooze is not a dismissal: the entry is
    /// still published, still true, and reappears on its own.
    private var snoozedUntil: [String: Date] = [:]

    /// Sources the captain has muted from the row's context menu. Session-
    /// scoped, like a snooze - a mute that outlived a relaunch would be a
    /// setting, and this app has a Settings page for settings.
    private var mutedSources: Set<String> = []

    private var observers: [(token: NotificationCenterObservation, fn: () -> Void)] = []

    /// The bell's badge count - every *visible* entry, regardless of kind. A
    /// badge that counted snoozed rows would be counting things the panel does
    /// not list.
    var badgeCount: Int { entries.count }

    /// How many published entries are hidden right now, by either mechanism -
    /// what the footer's "N snoozed" offers to bring back.
    var snoozedCount: Int { stored.count - entries.count }

    /// The clock every snooze is measured against, injectable so a suite can
    /// drive a snooze expiring without sleeping (the same shape
    /// `FocusTimerController.clock` uses, and for the same reason).
    var clock: () -> Date = { Date() }

    private init() {}

    private func isVisible(_ entry: AppNotification) -> Bool {
        if mutedSources.contains(entry.source), !entry.source.isEmpty { return false }
        if let until = snoozedUntil[entry.id], until > clock() { return false }
        return true
    }

    @discardableResult
    func observe(_ fn: @escaping () -> Void) -> NotificationCenterObservation {
        let token = NotificationCenterObservation()
        observers.append((token, fn))
        fn()
        return token
    }

    func unobserve(_ token: NotificationCenterObservation) {
        observers.removeAll { $0.token === token }
    }

    /// The one entry point every source calls. `notification == nil` means
    /// "the condition this id represents is no longer true" - removes it
    /// unconditionally (including any remembered dismissal, so a condition
    /// that resolves and later recurs starts fresh). `notification != nil`
    /// means "still true, here is the current text" - added if new, updated
    /// in place if already present, or silently skipped if it's an
    /// `.informational` entry the captain already dismissed with this exact
    /// subtext (see file header).
    func set(_ notification: AppNotification?, id: String) {
        guard let notification else {
            let changed = stored.contains { $0.id == id }
            stored.removeAll { $0.id == id }
            forget(id: id)
            if changed { notifyObservers() }
            return
        }
        precondition(notification.id == id, "AppNotification.id must match the id it's set under")
        if notification.kind == .informational, dismissedDetail[id] == notification.subtext {
            return
        }
        dismissedDetail.removeValue(forKey: id)
        if let idx = stored.firstIndex(where: { $0.id == id }) {
            guard stored[idx] != notification else { return }
            stored[idx] = notification
        } else {
            stored.append(notification)
            enforceCap()
        }
        notifyObservers()
    }

    /// PF3: the store was never capped. Every source publishes by id and most
    /// of them replace their own entry in place, so in practice it stays
    /// small - but nothing *made* it small, and a source that mints a fresh id
    /// per event (a crew reply, an SRE Lead answer, a schedule run) grows it
    /// for the life of the process, taking the panel's own rebuild cost with
    /// it.
    ///
    /// The cap sheds `.informational` entries first, oldest first, because
    /// those are the ones the captain can dismiss anyway. An `.actionNeeded`
    /// entry is only ever dropped when there is nothing else left to drop -
    /// and if a source still considers it true it comes straight back on that
    /// source's next publish, which is what makes shedding safe here at all.
    static let maxStoredEntries = 200

    private func enforceCap() {
        guard stored.count > Self.maxStoredEntries else { return }
        var overflow = stored.count - Self.maxStoredEntries
        let byAge = stored.enumerated().sorted { $0.element.date < $1.element.date }
        var doomed = Set<String>()
        for (_, entry) in byAge where overflow > 0 && entry.kind == .informational {
            doomed.insert(entry.id)
            overflow -= 1
        }
        for (_, entry) in byAge where overflow > 0 && !doomed.contains(entry.id) {
            doomed.insert(entry.id)
            overflow -= 1
        }
        stored.removeAll { doomed.contains($0.id) }
        for id in doomed { forget(id: id) }
    }

    /// Removes an entry outright regardless of kind, with no dismissal
    /// remembered - used when the captain's own action IS the resolution
    /// (e.g. opening the tab an SRE Lead reply landed on), as opposed to
    /// `dismiss(id:)`'s "not now, but still true" semantics.
    func remove(id: String) {
        guard stored.contains(where: { $0.id == id }) else { return }
        stored.removeAll { $0.id == id }
        forget(id: id)
        notifyObservers()
    }

    /// Manual dismiss - `.informational` only. An `.actionNeeded` item can't
    /// be dismissed away from something that still genuinely needs the
    /// captain; per the design doc, those only ever clear via resolution.
    func dismiss(id: String) {
        guard let entry = entries.first(where: { $0.id == id }), entry.kind == .informational else { return }
        dismissedDetail[id] = entry.subtext
        stored.removeAll { $0.id == id }
        notifyObservers()
    }

    /// Every `.informational` entry currently showing, dismissed in one shot.
    ///
    /// **This used to be called `markAllRead()`, and the rename is the point.**
    /// The captain's redesign reference gives "Mark all read" its ordinary
    /// meaning - it clears the unread dots and leaves every row in the list -
    /// so the header button now calls `markAllRead()` below and this kept the
    /// behaviour under a name that says what it does. Nothing in the UI reaches
    /// it today; it stays because the store's dismiss semantics (and their
    /// resurface-on-change rule) are a real contract with a suite behind them,
    /// and deleting the bulk form would leave that contract half-tested.
    func dismissAllInformational() {
        let informational = entries.filter { $0.kind == .informational }
        guard !informational.isEmpty else { return }
        for entry in informational { dismissedDetail[entry.id] = entry.subtext }
        let ids = Set(informational.map(\.id))
        stored.removeAll { ids.contains($0.id) }
        notifyObservers()
    }

    // MARK: - Read state

    /// Whether the blue unread dot is off for this entry. Compares the detail
    /// text that was read against the entry's current one, so a row whose
    /// content has moved on since is unread again - see `readDetail`.
    func isRead(_ entry: AppNotification) -> Bool {
        readDetail[entry.id] == entry.subtext
    }

    func setRead(_ read: Bool, id: String) {
        guard let entry = stored.first(where: { $0.id == id }) else { return }
        let wasRead = isRead(entry)
        if read {
            readDetail[id] = entry.subtext
        } else {
            readDetail.removeValue(forKey: id)
        }
        guard wasRead != read else { return }
        notifyObservers()
    }

    /// The panel header's "Mark all read": every visible row's dot goes out,
    /// and every row stays in the list.
    func markAllRead() {
        let unread = entries.filter { !isRead($0) }
        guard !unread.isEmpty else { return }
        for entry in unread { readDetail[entry.id] = entry.subtext }
        notifyObservers()
    }

    var unreadCount: Int { entries.filter { !isRead($0) }.count }

    // MARK: - Snooze and mute

    /// Hide this entry until `date`. It is still published and still true - it
    /// comes back on its own, with no source involved, which is what separates
    /// a snooze from `dismiss(id:)`.
    func snooze(id: String, until date: Date) {
        guard stored.contains(where: { $0.id == id }) else { return }
        snoozedUntil[id] = date
        notifyObservers()
    }

    /// Hide every entry from this source for the session. `source` is
    /// `AppNotification.source`, so muting "Updates" mutes whatever the Updates
    /// page publishes next as well.
    func mute(source: String) {
        guard !source.isEmpty, !mutedSources.contains(source) else { return }
        guard stored.contains(where: { $0.source == source }) else { return }
        mutedSources.insert(source)
        notifyObservers()
    }

    func isMuted(source: String) -> Bool { mutedSources.contains(source) }

    /// The footer's "N snoozed" - un-snooze and un-mute everything in one go.
    func restoreHidden() {
        guard !snoozedUntil.isEmpty || !mutedSources.isEmpty else { return }
        snoozedUntil.removeAll()
        mutedSources.removeAll()
        notifyObservers()
    }

    /// Everything a single id can have remembered about it, dropped together -
    /// a condition that resolves and later recurs starts genuinely fresh, not
    /// pre-read and pre-snoozed.
    private func forget(id: String) {
        dismissedDetail.removeValue(forKey: id)
        readDetail.removeValue(forKey: id)
        snoozedUntil.removeValue(forKey: id)
    }

    private func notifyObservers() {
        observers.forEach { $0.fn() }
    }

    /// Test-only reset - not used by production code. Lets
    /// `GrandLineNotificationCenterSelfTest` start from a clean slate
    /// without disturbing the app-lifetime singleton's observers.
    func resetForTesting() {
        stored.removeAll()
        dismissedDetail.removeAll()
        readDetail.removeAll()
        snoozedUntil.removeAll()
        mutedSources.removeAll()
        clock = { Date() }
    }
}
