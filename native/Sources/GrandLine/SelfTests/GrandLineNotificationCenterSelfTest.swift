// Grand Line - native macOS app.
//
// Permanent, env-gated self-test for `GrandLineNotificationCenter` - run via
// `FM_RUN_NOTIFICATION_CENTER_TESTS=1 .build/debug/GrandLine`, same
// convention as `QuotaDataSelfTest.swift`/`ShiftStoreSelfTest.swift`. Pure
// logic only - no AppKit, no real source (`NotificationSources.swift`) -
// this exercises `set`/`remove`/`dismiss`/`markAllRead`/`badgeCount`
// directly against synthetic `AppNotification`s.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum GrandLineNotificationCenterSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            SelfTestAssertions.record(condition, name, into: &failures)
        }

        let center = GrandLineNotificationCenter.shared
        center.debugReset()

        func note(_ id: String, title: String = "Title", subtext: String,
                  kind: AppNotificationKind, source: String = "") -> AppNotification {
            AppNotification(id: id, title: title, subtext: subtext, source: source,
                            kind: kind, tint: .good, navigate: {})
        }

        // MARK: basic add / badge count

        center.set(note("a", subtext: "x", kind: .actionNeeded), id: "a")
        check("badge count reflects one entry", center.badgeCount == 1)
        check("entry is present", center.entries.contains { $0.id == "a" })

        center.set(note("b", subtext: "y", kind: .informational), id: "b")
        check("badge count reflects two entries", center.badgeCount == 2)

        // MARK: dedup - re-setting the same id with the same content must not add a duplicate

        center.set(note("a", subtext: "x", kind: .actionNeeded), id: "a")
        check("re-setting an identical entry does not duplicate it", center.entries.filter { $0.id == "a" }.count == 1)
        check("badge count unchanged after a no-op re-set", center.badgeCount == 2)

        // MARK: updating an existing entry in place (changed subtext/title)

        center.set(note("a", title: "New title", subtext: "x2", kind: .actionNeeded), id: "a")
        check("updated entry replaces the old one, not duplicates", center.entries.filter { $0.id == "a" }.count == 1)
        check("updated entry carries the new subtext", center.entries.first { $0.id == "a" }?.subtext == "x2")

        // MARK: actionNeeded auto-clear on resolution (set(nil, id:))

        center.set(nil, id: "a")
        check("actionNeeded entry removed once resolved", !center.entries.contains { $0.id == "a" })
        check("badge count drops after auto-clear", center.badgeCount == 1)

        // MARK: informational clears on resolution too

        center.set(nil, id: "b")
        check("informational entry removed once resolved", center.entries.isEmpty)

        // MARK: manual dismiss - informational only, and resurfaces only on a real content change

        center.set(note("c", subtext: "3 tools have updates", kind: .informational), id: "c")
        center.dismiss(id: "c")
        check("dismissed entry disappears from the list", !center.entries.contains { $0.id == "c" })

        center.set(note("c", subtext: "3 tools have updates", kind: .informational), id: "c")
        check("re-setting the same condition after dismiss does not resurface it", !center.entries.contains { $0.id == "c" })

        center.set(note("c", subtext: "4 tools have updates", kind: .informational), id: "c")
        check("a materially changed condition resurfaces even after a prior dismiss", center.entries.contains { $0.id == "c" })

        center.set(nil, id: "c")
        center.set(note("c", subtext: "3 tools have updates", kind: .informational), id: "c")
        check("a dismissal is cleared once the condition fully resolves and later recurs", center.entries.contains { $0.id == "c" })
        center.set(nil, id: "c")

        // MARK: dismiss must not affect actionNeeded entries

        center.set(note("d", subtext: "needs you", kind: .actionNeeded), id: "d")
        center.dismiss(id: "d")
        check("dismiss is a no-op on an actionNeeded entry", center.entries.contains { $0.id == "d" })
        center.set(nil, id: "d")

        // MARK: dismissAllInformational clears every informational entry, leaves actionNeeded alone
        //
        // `fm/grandline-notification-center-redesign` renamed this from
        // `markAllRead()`, which now means what it says everywhere else in
        // macOS - the dots go out and the rows stay (asserted further down).

        center.set(note("e1", subtext: "fyi one", kind: .informational), id: "e1")
        center.set(note("e2", subtext: "fyi two", kind: .informational), id: "e2")
        center.set(note("f", subtext: "still needed", kind: .actionNeeded), id: "f")
        check("three entries present before dismissAllInformational", center.badgeCount == 3)
        center.dismissAllInformational()
        check("dismissAllInformational clears both informational entries", !center.entries.contains { $0.id == "e1" } && !center.entries.contains { $0.id == "e2" })
        check("dismissAllInformational leaves the actionNeeded entry untouched", center.entries.contains { $0.id == "f" })
        check("badge count reflects only the surviving actionNeeded entry", center.badgeCount == 1)

        // MARK: a dismissed-via-dismissAllInformational entry obeys the same resurface-on-change rule as dismiss(id:)

        check("bulk-dismissed entry stays hidden on an identical re-set", {
            center.set(note("e1", subtext: "fyi one", kind: .informational), id: "e1")
            return !center.entries.contains { $0.id == "e1" }
        }())
        center.set(note("e1", subtext: "fyi one CHANGED", kind: .informational), id: "e1")
        check("bulk-dismissed entry resurfaces on a real change", center.entries.contains { $0.id == "e1" })
        center.set(nil, id: "e1")
        center.set(nil, id: "f")

        // MARK: read state - the blue dot, and its resurface-on-change rule
        //
        // Keyed by the exact subtext for the same reason `dismissedDetail` is:
        // a row whose detail has moved on since it was read is carrying
        // information the captain has not seen.

        center.set(note("r1", subtext: "two behind", kind: .informational), id: "r1")
        check("a fresh entry is unread", !center.isRead(center.entries[0]))
        check("unreadCount counts it", center.unreadCount == 1)
        center.setRead(true, id: "r1")
        check("setRead(true) marks it read", center.isRead(center.entries[0]))
        check("a read entry is still in the list", center.entries.contains { $0.id == "r1" })
        check("unreadCount drops to zero", center.unreadCount == 0)
        center.set(note("r1", subtext: "five behind", kind: .informational), id: "r1")
        check("a read entry whose detail changes is unread again", !center.isRead(center.entries[0]))
        center.markAllRead()
        check("markAllRead clears the dot", center.isRead(center.entries[0]))
        check("markAllRead does NOT remove the row", center.entries.contains { $0.id == "r1" })
        center.setRead(false, id: "r1")
        check("setRead(false) puts the dot back - what Undo calls", !center.isRead(center.entries[0]))
        center.set(nil, id: "r1")

        // MARK: snooze hides an entry until its own date, with no source involved

        var fakeNow = Date(timeIntervalSince1970: 1_700_000_000)
        center.clock = { fakeNow }
        center.set(note("s1", subtext: "later", kind: .informational), id: "s1")
        center.snooze(id: "s1", until: fakeNow.addingTimeInterval(3600))
        check("a snoozed entry leaves the visible list", !center.entries.contains { $0.id == "s1" })
        check("a snoozed entry is counted as hidden", center.snoozedCount == 1)
        check("the badge does not count a snoozed entry", center.badgeCount == 0)
        fakeNow = fakeNow.addingTimeInterval(3601)
        check("the snooze expires on its own, with no source re-publishing",
              center.entries.contains { $0.id == "s1" })
        check("nothing is hidden once it has expired", center.snoozedCount == 0)

        // MARK: mute is per source, and restoreHidden undoes both mechanisms

        center.set(note("m1", subtext: "one", kind: .informational, source: "Updates"), id: "m1")
        center.set(note("m2", subtext: "two", kind: .informational, source: "Updates"), id: "m2")
        center.set(note("m3", subtext: "three", kind: .informational, source: "Tasks"), id: "m3")
        center.mute(source: "Updates")
        check("muting a source hides every entry from it",
              !center.entries.contains { $0.source == "Updates" })
        check("muting a source leaves another source alone", center.entries.contains { $0.id == "m3" })
        check("muted entries count as hidden", center.snoozedCount == 2)
        center.snooze(id: "s1", until: fakeNow.addingTimeInterval(3600))
        check("snoozed and muted are counted together", center.snoozedCount == 3)
        center.restoreHidden()
        check("restoreHidden brings back both the muted and the snoozed", center.snoozedCount == 0)
        check("restoreHidden un-mutes the source itself", !center.isMuted(source: "Updates"))
        for id in ["s1", "m1", "m2", "m3"] { center.set(nil, id: id) }
        center.clock = { Date() }

        // MARK: a mute survives a relaunch (Bridge extra)

        // The mute used to be session-scoped. It is a setting now, written to
        // `AppDefaults.store` (this process's own suite domain under a test,
        // never the captain's), and read back on launch.
        center.set(note("p1", subtext: "one", kind: .informational, source: "GitHub Sync"), id: "p1")
        center.mute(source: "GitHub Sync")
        check("the mute is written to AppDefaults.store",
              AppDefaults.store.stringArray(forKey: "fm.notifications.mutedSources") == ["GitHub Sync"])
        center.debugReloadPersistedMutes()
        check("a muted source is still muted after a relaunch", center.isMuted(source: "GitHub Sync"))
        check("a muted source's entry is still hidden after a relaunch",
              !center.entries.contains { $0.id == "p1" })
        center.setMuted(false, source: "GitHub Sync")
        center.debugReloadPersistedMutes()
        check("an unmute is persisted too", !center.isMuted(source: "GitHub Sync")
              && AppDefaults.store.object(forKey: "fm.notifications.mutedSources") == nil)
        // Settings mutes a source that has nothing published today.
        center.setMuted(true, source: "Vault")
        center.debugReloadPersistedMutes()
        check("Settings can mute a source with no live entry", center.isMuted(source: "Vault"))
        center.restoreHidden()
        center.debugReloadPersistedMutes()
        check("restoreHidden clears the persisted mutes as well", center.mutedSourceNames.isEmpty)
        center.set(nil, id: "p1")

        // MARK: quiet while a focus session runs (Bridge extra)

        var quietNow = Date(timeIntervalSince1970: 1_800_000_000)
        center.clock = { quietNow }
        center.set(AppNotification(id: "q-before", title: "Before", subtext: "x", kind: .informational,
                                   tint: .info, date: quietNow.addingTimeInterval(-60), navigate: {}),
                   id: "q-before")
        center.setFocusSessionActive(true)
        check("a focus session turns quiet on", center.isFocusQuietActive)
        quietNow = quietNow.addingTimeInterval(30)
        center.set(AppNotification(id: "q-info", title: "FYI", subtext: "x", kind: .informational,
                                   tint: .info, date: quietNow, navigate: {}), id: "q-info")
        center.set(AppNotification(id: "q-act", title: "Needs you", subtext: "x", kind: .actionNeeded,
                                   tint: .warn, date: quietNow, navigate: {}), id: "q-act")
        check("an informational entry arriving mid-session is held",
              !center.entries.contains { $0.id == "q-info" } && center.heldCount == 1)
        check("an action-needed entry still shows mid-session", center.entries.contains { $0.id == "q-act" })
        check("what was already listed when the session started stays",
              center.entries.contains { $0.id == "q-before" })
        check("the badge does not count a held entry", center.badgeCount == 2)
        check("a held entry is not counted as snoozed", center.snoozedCount == 0)
        center.restoreHidden()
        check("Restore does not release a held entry", center.heldCount == 1)
        center.setFocusSessionActive(false)
        check("ending the session releases what was held",
              center.entries.contains { $0.id == "q-info" } && center.heldCount == 0)
        center.setQuietWhileFocusing(false, sessionRunning: false)
        check("the setting is written to AppDefaults.store",
              AppDefaults.store.object(forKey: "fm.notifications.quietWhileFocusing") as? Bool == false)
        center.setFocusSessionActive(true)
        quietNow = quietNow.addingTimeInterval(30)
        center.set(AppNotification(id: "q-info2", title: "FYI 2", subtext: "x", kind: .informational,
                                   tint: .info, date: quietNow, navigate: {}), id: "q-info2")
        check("with the setting off, nothing is held", center.entries.contains { $0.id == "q-info2" }
              && !center.isFocusQuietActive)
        center.setQuietWhileFocusing(true, sessionRunning: true)
        check("turning the setting on mid-session starts holding", center.isFocusQuietActive)
        center.setFocusSessionActive(false)
        for id in ["q-before", "q-info", "q-act", "q-info2"] { center.set(nil, id: id) }
        center.clock = { Date() }

        // MARK: the Bridge panel's sections (pure half of NotificationBridgePanelSelfTest)

        let sectionBase = Date(timeIntervalSince1970: 1_750_000_000)
        func dated(_ id: String, _ kind: AppNotificationKind, _ offset: TimeInterval, warning: Bool = false) -> AppNotification {
            AppNotification(id: id, title: id, subtext: "", kind: kind, tint: .info,
                            date: sectionBase.addingTimeInterval(offset), isWarning: warning, navigate: {})
        }
        let sections = NotificationBridgeSections([
            dated("info-old", .informational, -500), dated("act-new", .actionNeeded, -10),
            dated("act-old", .actionNeeded, -900), dated("act-overdue", .actionNeeded, -5, warning: true),
            dated("info-new", .informational, -20),
        ])
        check("Now is the overdue entry even though it is the newest", sections.now?.id == "act-overdue")
        check("Up next is the rest of the action-needed entries, oldest first",
              sections.upNext.map(\.id) == ["act-old", "act-new"])
        check("When you have a minute is the informational entries, newest first",
              sections.later.map(\.id) == ["info-new", "info-old"])
        check("the drawn order is Now, Up next, then later",
              sections.ordered.map(\.id) == ["act-overdue", "act-old", "act-new", "info-new", "info-old"])
        let onlyInfo = NotificationBridgeSections([dated("i", .informational, 0)])
        check("with nothing action-needed there is no Now card", onlyInfo.now == nil && !onlyInfo.isEmpty)
        check("an empty store is empty", NotificationBridgeSections([]).isEmpty)

        // MARK: the inline snooze presets (Bridge extra)

        // Local noon on a known Monday (26 Oct 2026), in the calendar
        // production passes - see AGENTS.md on day-string fixtures.
        let cal = Calendar.current
        func local(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
            cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        let monday = local(26, 12)
        check("1 hour is an hour", NotificationSnoozePreset.oneHour.date(from: monday, calendar: cal) == local(26, 13))
        check("Tonight is 18:00 today", NotificationSnoozePreset.tonight.date(from: monday, calendar: cal) == local(26, 18))
        check("Tomorrow is 09:00 tomorrow", NotificationSnoozePreset.tomorrow.date(from: monday, calendar: cal) == local(27, 9))
        check("Next week is 09:00 next Monday",
              NotificationSnoozePreset.nextWeek.date(from: monday, calendar: cal) == local(2, 9, month: 11))
        check("Next week on a Monday morning is not an hour away",
              NotificationSnoozePreset.nextWeek.date(from: local(26, 8), calendar: cal) == local(2, 9, month: 11))
        check("Next week on a Sunday is the next morning",
              NotificationSnoozePreset.nextWeek.date(from: local(1, 12, month: 11), calendar: cal) == local(2, 9, month: 11))
        check("all four are offered at noon", NotificationSnoozePreset.offered(at: monday, calendar: cal).count == 4)
        check("Tonight is not offered within an hour of it",
              !NotificationSnoozePreset.offered(at: local(26, 17, 30), calendar: cal).contains(.tonight))

        // MARK: a resolved entry starts genuinely fresh

        center.set(note("f1", subtext: "x", kind: .informational), id: "f1")
        center.setRead(true, id: "f1")
        center.snooze(id: "f1", until: Date().addingTimeInterval(9999))
        center.set(nil, id: "f1")
        center.set(note("f1", subtext: "x", kind: .informational), id: "f1")
        check("a recurring condition comes back visible", center.entries.contains { $0.id == "f1" })
        check("a recurring condition comes back unread", !center.isRead(center.entries[0]))
        center.set(nil, id: "f1")

        // MARK: observers fire on every real change, not on no-op re-sets

        var fireCount = 0
        let token = center.observe { fireCount += 1 }
        check("observe fires immediately on registration", fireCount == 1)
        center.set(note("g", subtext: "z", kind: .actionNeeded), id: "g")
        check("observer fires on a real add", fireCount == 2)
        center.set(note("g", subtext: "z", kind: .actionNeeded), id: "g")
        check("observer does not fire on a no-op re-set", fireCount == 2)
        center.set(nil, id: "g")
        check("observer fires on removal", fireCount == 3)
        center.set(nil, id: "g")
        check("observer does not fire on removing something already absent", fireCount == 3)
        center.unobserve(token)
        center.set(note("h", subtext: "z", kind: .actionNeeded), id: "h")
        check("unobserved token no longer receives updates", fireCount == 3)
        center.set(nil, id: "h")

        center.debugReset()

        // MARK: PF3 - the store is capped, and sheds informational rows first

        // Every source publishes by id and most replace in place, so in
        // practice the store stays small. Nothing *made* it small, though, and
        // a source that mints a fresh id per event grows it for the life of
        // the process - taking the panel's own rebuild cost with it.
        let cap = GrandLineNotificationCenter.maxStoredEntries
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<20 {
            center.set(AppNotification(id: "keep-\(i)", title: "Needs you", subtext: "\(i)",
                                       kind: .actionNeeded, tint: .warn,
                                       date: base.addingTimeInterval(Double(i)),
                                       navigate: {}), id: "keep-\(i)")
        }
        check("the fixture seeded 20 action-needed entries", center.entries.count == 20)
        for i in 0..<(cap + 50) {
            center.set(AppNotification(id: "chatter-\(i)", title: "FYI", subtext: "\(i)",
                                       kind: .informational, tint: .info,
                                       date: base.addingTimeInterval(Double(1000 + i)),
                                       navigate: {}), id: "chatter-\(i)")
        }
        check("the store is capped rather than unbounded", center.entries.count <= cap)
        check("the cap sheds informational entries, not the ones that need the captain",
              center.entries.filter { $0.kind == .actionNeeded }.count == 20)
        // Oldest-first, so what survives is the recent chatter rather than a
        // random slice of it.
        check("the newest informational entry survived the cap",
              center.entries.contains { $0.id == "chatter-\(cap + 49)" })
        check("the oldest informational entry was the one shed",
              !center.entries.contains { $0.id == "chatter-0" })

        // MARK: snooze and read state survive a relaunch (F2)

        center.debugReset()
        var persistNow = Date(timeIntervalSince1970: 1_750_000_000)
        center.clock = { persistNow }
        center.set(note("ps1", subtext: "one", kind: .informational, source: "Updates"), id: "ps1")
        center.set(note("ps2", subtext: "two", kind: .informational), id: "ps2")
        center.snooze(id: "ps1", until: persistNow.addingTimeInterval(7 * 86_400))
        center.setRead(true, id: "ps2")
        check("a snooze is written to AppDefaults.store",
              AppDefaults.store.dictionary(forKey: "fm.notifications.snoozedUntil")?["ps1"] is Date)
        check("a read mark is written to AppDefaults.store",
              AppDefaults.store.dictionary(forKey: "fm.notifications.readDetail")?["ps2"] != nil)
        center.debugReloadPersistedState()
        check("a next-week snooze survives a relaunch", !center.entries.contains { $0.id == "ps1" })
        check("read state survives a relaunch",
              center.entries.first { $0.id == "ps2" }.map(center.isRead) == true)
        center.snooze(id: "ps2", until: persistNow.addingTimeInterval(60))
        persistNow = persistNow.addingTimeInterval(120)
        center.debugReloadPersistedState()
        check("a snooze that expired while the app was closed is dropped on load",
              center.entries.contains { $0.id == "ps2" } && !center.snoozedEntries.contains { $0.entry.id == "ps2" })
        AppSettings.shared.notificationReadDetail = ["ps2": ("two", persistNow.addingTimeInterval(-31 * 86_400))]
        center.debugReloadPersistedState()
        check("a read mark older than its lifetime is dropped on load",
              center.entries.first { $0.id == "ps2" }.map(center.isRead) == false)

        // MARK: the Snoozed list, and unsnooze leaves mutes alone (F3)

        center.set(note("ps3", subtext: "three", kind: .informational), id: "ps3")
        center.set(note("ps4", subtext: "four", kind: .actionNeeded), id: "ps4")
        center.snooze(id: "ps3", until: persistNow.addingTimeInterval(7200))
        center.snooze(id: "ps4", until: persistNow.addingTimeInterval(3600))
        check("snoozedEntries lists what is snoozed, soonest back first",
              center.snoozedEntries.map(\.entry.id) == ["ps4", "ps3", "ps1"])
        center.mute(source: "Updates")
        check("an entry that is also muted is not listed as snoozed",
              !center.snoozedEntries.contains { $0.entry.id == "ps1" })
        center.unsnooze(id: "ps4")
        check("unsnooze brings one entry back now", center.entries.contains { $0.id == "ps4" }
              && center.snoozedEntries.map(\.entry.id) == ["ps3"])
        center.unsnoozeAll()
        check("unsnoozeAll brings every snoozed entry back", center.entries.contains { $0.id == "ps3" }
              && center.snoozedEntries.isEmpty)
        check("unsnoozeAll leaves a mute alone", center.isMuted(source: "Updates"))
        center.setMuted(false, source: "Updates")
        check("with the mute lifted and the snooze gone, the entry is back", center.entries.contains { $0.id == "ps1" })
        for id in ["ps1", "ps2", "ps3", "ps4"] { center.set(nil, id: id) }
        check("a resolved condition takes its persisted state with it",
              AppSettings.shared.notificationSnoozedUntil.isEmpty && AppSettings.shared.notificationReadDetail.isEmpty)

        // MARK: an expired snooze comes back on its own timer (R4-BUG-02)

        // `entries` is derived on read, so the badge's number is right the
        // moment the clock passes the deadline - but nobody re-reads it.
        // The bell and the Snoozed list repaint only when observers are told,
        // and a source whose text does not change never tells them (`set`
        // returns early on an identical entry). So the assertions read what
        // an observer was last handed, and nothing calls `set` in between.
        var expiryNow = Date(timeIntervalSince1970: 1_760_000_000)
        center.clock = { expiryNow }
        center.set(note("ex1", subtext: "one", kind: .informational), id: "ex1")
        center.set(note("ex2", subtext: "two", kind: .actionNeeded), id: "ex2")
        center.snooze(id: "ex2", until: expiryNow.addingTimeInterval(1800))
        center.snooze(id: "ex1", until: expiryNow.addingTimeInterval(600))
        check("the expiry timer is armed for the earliest snooze",
              center.debugSnoozeExpiryDeadline == expiryNow.addingTimeInterval(600))
        check("the expiry timer carries a tolerance", (center.debugSnoozeExpiryTolerance ?? 0) > 0)
        var heardBadge = -1
        var heardSnoozed: [String] = []
        let expiryToken = center.observe {
            heardBadge = center.badgeCount
            heardSnoozed = center.snoozedEntries.map(\.entry.id)
        }
        check("the fixture starts with both entries snoozed (\(heardBadge), \(heardSnoozed))",
              heardBadge == 0 && heardSnoozed == ["ex1", "ex2"])
        center.debugFireSnoozeExpiryTimer()
        check("a timer that fires before the deadline brings nothing back", heardBadge == 0 && heardSnoozed == ["ex1", "ex2"])
        expiryNow = expiryNow.addingTimeInterval(601)
        center.debugFireSnoozeExpiryTimer()
        check("the expired snooze reaches the bell with no source re-publishing (badge \(heardBadge))", heardBadge == 1)
        check("the Snoozed list loses the expired entry (\(heardSnoozed))", heardSnoozed == ["ex2"])
        check("the expired snooze is dropped from AppDefaults.store",
              AppSettings.shared.notificationSnoozedUntil["ex1"] == nil
                  && AppSettings.shared.notificationSnoozedUntil["ex2"] != nil)
        check("the timer re-arms for the next snooze",
              center.debugSnoozeExpiryDeadline == expiryNow.addingTimeInterval(1800 - 601))
        center.unsnooze(id: "ex2")
        check("with nothing snoozed no timer is armed", center.debugSnoozeExpiryDeadline == nil)
        center.unobserve(expiryToken)
        for id in ["ex1", "ex2"] { center.set(nil, id: id) }
        center.clock = { Date() }

        // MARK: a detail is shortened by path and word, not mid-word (F4)

        let longDetail = "3 failures in a row \u{00B7} /Users/pat/manjesh/firstmate/projects/manjesh-config"
            + " and origin/main have both moved on independently since then"
        let short = NotificationSources.shortDetail(longDetail, home: "/Users/pat")
        check("the home directory becomes ~ and a deep path keeps its last two segments",
              short.contains("~/\u{2026}/projects/manjesh-config") && !short.contains("/Users/pat"))
        let lastWord = short.dropLast().split(separator: " ").last.map(String.init) ?? ""
        check("the cut lands on a word boundary: \(short)", short.hasSuffix("\u{2026}") && short.count <= 91
              && longDetail.split(separator: " ").map(String.init).contains(lastWord))
        check("a short detail is left alone", NotificationSources.shortDetail("Ready", home: "/Users/pat") == "Ready")
        check("a shallow path is left alone",
              NotificationSources.shortDetail("cannot read /etc/hosts", home: "/Users/pat") == "cannot read /etc/hosts")

        // MARK: the snooze menu's and the Snoozed list's time strings

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let enUS = Locale(identifier: "en_US")
        let wednesday = utc.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 10, minute: 42))!
        func at(_ day: Int, _ hour: Int) -> Date {
            utc.date(from: DateComponents(year: 2026, month: day < 28 ? 11 : 10, day: day, hour: hour))!
        }
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        let tonight = plain(NotificationBridgeTimeText.snoozeTime(at(28, 18), now: wednesday, calendar: utc, locale: enUS))
        check("a snooze ending today shows the time alone: \(tonight)", tonight == "6:00 PM")
        let thursday = plain(NotificationBridgeTimeText.snoozeTime(at(29, 9), now: wednesday, calendar: utc, locale: enUS))
        check("a snooze ending this week shows the weekday: \(thursday)", thursday == "Thu 9:00 AM")
        let farOff = plain(NotificationBridgeTimeText.snoozeTime(at(9, 9), now: wednesday, calendar: utc, locale: enUS))
        check("a snooze beyond a week shows the date: \(farOff)", farOff.contains("Nov") && farOff.contains("9"))
        check("a Snoozed row ending today says Back at",
              plain(NotificationBridgeTimeText.returns(at(28, 18), now: wednesday, calendar: utc, locale: enUS)) == "Back at 6:00 PM")
        check("a Snoozed row ending tomorrow says tomorrow",
              plain(NotificationBridgeTimeText.returns(at(29, 9), now: wednesday, calendar: utc, locale: enUS)) == "Back tomorrow, 9:00 AM")

        // MARK: a fallback label names the page, not its path (F9)

        let savedLayout = PlaceName.layout
        PlaceName.layout = .sidebar
        NotificationSources.setGitHubSync(count: 3, navigate: {})
        let forkLabel = center.entries.first { $0.id == NotificationSources.githubSyncID }?.primaryAction?.label
        check("the fork row's fallback says \(forkLabel ?? "nothing"), not a breadcrumb",
              forkLabel == "Open \(PlaceName.short(.githubSync))" && forkLabel?.contains("\u{203A}") == false)
        NotificationSources.setGitHubSync(count: 0, navigate: {})
        PlaceName.layout = savedLayout

        center.debugReset()

        if failures.isEmpty {
            print("GrandLineNotificationCenterSelfTest: all checks passed")
            return true
        } else {
            print("GrandLineNotificationCenterSelfTest: FAILED - \(failures.joined(separator: "; "))")
            return false
        }
    }
}

#endif
