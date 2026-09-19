// Manjesh Grand Line - native macOS app.
//
// `FM_RUN_FEEDBACK_ROUTING_TESTS` - review #3's UX14.
//
// The finding is that GL-30's rule was written down and then applied from
// memory at every call site. `Feedback` puts the rule in one place; this
// asserts that the rule is what it claims to be, and - the part that actually
// catches a regression - that `Feedback.report`'s real side effects agree with
// `Feedback.surfaces`'s description of them.
//
// That second half matters because a routing table nobody dispatches through
// is just a comment. The bell is real here (`GrandLineNotificationCenter` is a
// plain observable store, no window needed), so a `lasting` report is asserted
// by *reading the bell back*, not by trusting the table.
//
// The toast half needs a real `NSView` to mount into, which needs no window
// server - but `Toast.show` is not observable, so the toast side is asserted
// through `surfaces` plus the one thing that is observable: passing no view
// must not crash and must still reach the bell.
//
// GL-27: debug builds only.
#if FM_SELFTESTS

import AppKit

enum FeedbackRoutingSelfTest {
    static func run() -> Bool {
        var ok = true
        ok = checkTheRule() && ok
        ok = checkReportAgreesWithTheRule() && ok
        ok = checkKindMapping() && ok
        return ok
    }

    /// GL-30's rule, restated as the four combinations that exist.
    private static func checkTheRule() -> Bool {
        var ok = true
        // A transient confirmation on a page: the toast, and only the toast.
        // A "Copied" that also sat in the bell forever would be the opposite
        // failure from the one this finding is about, and just as wrong.
        check(Feedback.surfaces(persistence: .transient, hasView: true, hasID: true) == [.toast],
              "UX14: a transient report reached more than the toast", &ok)
        check(Feedback.surfaces(persistence: .transient, hasView: true, hasID: false) == [.toast],
              "UX14: a transient report's routing should not depend on an id", &ok)

        // Still true after the toast fades: both. Both, not instead - the
        // captain is looking at the page right now, and making them find the
        // bell for something that just happened would be worse feedback.
        check(Feedback.surfaces(persistence: .lasting, hasView: true, hasID: true)
                == [.toast, .notificationCenter],
              "UX14: a lasting report must reach the bell as well as the page", &ok)

        // No page - a background pass, a terminate-time flush. It goes where
        // it can.
        check(Feedback.surfaces(persistence: .lasting, hasView: false, hasID: true)
                == [.notificationCenter],
              "UX14: a lasting report with no page should still reach the bell", &ok)
        check(Feedback.surfaces(persistence: .transient, hasView: false, hasID: true).isEmpty,
              "UX14: a transient report with no page has nowhere to go and should reach nothing", &ok)

        // A lasting report with no id cannot be cleared later, and an
        // un-clearable bell entry is worse than none - it would sit there
        // claiming a condition that has since resolved.
        check(Feedback.surfaces(persistence: .lasting, hasView: true, hasID: false) == [.toast],
              "UX14: a lasting report with no id must not create an un-clearable bell entry", &ok)
        return ok
    }

    /// **The half that stops the table being a comment.** Drives the real
    /// `report`/`clear` and reads the real bell back.
    private static func checkReportAgreesWithTheRule() -> Bool {
        var ok = true
        let center = GrandLineNotificationCenter.shared
        let id = "feedback-routing-selftest"
        // Leave the bell as we found it - this is a process-wide singleton,
        // and a suite that leaked an entry would be the hermeticity failure
        // AGENTS.md devotes a section to.
        defer { center.set(nil, id: id) }
        center.set(nil, id: id)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

        // Discriminating power first: the bell must genuinely be empty of this
        // id, or every check below passes vacuously.
        check(!center.entries.contains { $0.id == id },
              "UX14: the bell already held the test id - the checks below would be vacuous", &ok)

        // Transient: nothing reaches the bell.
        Feedback.report("copied", kind: .done, persistence: .transient, in: view, id: id)
        check(!center.entries.contains { $0.id == id },
              "UX14: a transient report put an entry in the bell", &ok)

        // Lasting: it does.
        Feedback.report("the sync failed", kind: .failure, persistence: .lasting,
                        in: view, id: id, detail: "Docs")
        guard let entry = center.entries.first(where: { $0.id == id }) else {
            fail("UX14: a lasting report did not reach the bell - the router's two halves disagree", &ok)
            return ok
        }
        check(entry.title == "the sync failed", "UX14: the bell entry lost the message", &ok)
        check(entry.subtext == "Docs", "UX14: the bell entry lost its detail line", &ok)
        check(entry.kind == .actionNeeded, "UX14: a failure should file as action-needed", &ok)

        // A recurring condition **updates** its entry rather than stacking a
        // new one every pass - what the stable id is for.
        Feedback.report("the sync failed again", kind: .failure, persistence: .lasting,
                        in: view, id: id, detail: "Docs")
        check(center.entries.filter { $0.id == id }.count == 1,
              "UX14: a repeated lasting report stacked a second bell entry", &ok)
        check(center.entries.first(where: { $0.id == id })?.title == "the sync failed again",
              "UX14: a repeated lasting report did not update its entry's text", &ok)

        // And the half that is easy to forget: it can be cleared.
        Feedback.clear(id: id)
        check(!center.entries.contains { $0.id == id },
              "UX14: clearing a resolved condition left its bell entry behind", &ok)

        // No view must not crash, and must still reach the bell.
        Feedback.report("a background pass failed", kind: .failure, persistence: .lasting,
                        in: nil, id: id)
        check(center.entries.contains { $0.id == id },
              "UX14: a lasting report with no page did not reach the bell", &ok)
        return ok
    }

    private static func checkKindMapping() -> Bool {
        var ok = true
        // A `done` is information; a warning and a failure both want acting
        // on. Asserted because the bell renders and sorts on this.
        check(Feedback.Kind.done.notificationKind == .informational,
              "UX14: a success should file as informational", &ok)
        check(Feedback.Kind.warning.notificationKind == .actionNeeded,
              "UX14: a warning should file as action-needed", &ok)
        check(Feedback.Kind.failure.notificationKind == .actionNeeded,
              "UX14: a failure should file as action-needed", &ok)
        // The three tints are distinct, or the tint carries no information.
        let tints = Set([Feedback.Kind.done, .warning, .failure].map(\.tint))
        check(tints.count == 3, "UX14: the three kinds do not have three distinct tints", &ok)
        return ok
    }
}

#endif
