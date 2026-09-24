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
        center.resetForTesting()

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

        center.resetForTesting()

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
