// Grand Line - native macOS app.
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
// server. It used to be asserted only through `surfaces`, because a toast was
// a plain view with nothing to read. Since TO-1 (the hero capsule) a pill is a
// `ToastPill` that knows its kind, and `Toast` records each VoiceOver
// announcement it posts, so the toast half is read back too:
//
//   - **The kind reaches the toast.** `report` used to drop it, so a failure
//     drew the same green check as a save. Each kind is reported and the
//     newest pill's kind and glyph are read back.
//   - **Each toast is announced once**, with "Undo available" when it has
//     Undo. A VoiceOver announcement cannot be read back from the system, so
//     this reads `Toast.debugAnnouncements`, which `announce` appends to on
//     the same path that posts.
//   - **The capsule's colours hold in every app theme**: white words at 4.5:1
//     on the lighter stop, and each kind's glyph at 3:1 on both stops.
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
        ok = checkTheKindReachesTheToast() && ok
        ok = checkEachToastIsAnnouncedOnce() && ok
        ok = checkTheToastWords() && ok
        ok = checkTheCapsuleColoursInEveryTheme() && ok
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

    // MARK: TO-1 - the hero capsule

    /// Finding 1 of the hero restyle report: `report` dropped its kind before
    /// `Toast.show`, so "Docs sync failed" drew a green check.
    private static func checkTheKindReachesTheToast() -> Bool {
        var ok = true
        let kinds: [Feedback.Kind] = [.done, .warning, .failure]
        // Discriminating power first: three kinds, three glyphs.
        check(Set(kinds.map(ToastHeroWords.symbol(for:))).count == 3,
              "TO-1: the three kinds do not have three glyphs - the checks below could not tell them apart", &ok)
        for kind in kinds {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            let message = "report \(kind)"
            Feedback.report(message, kind: kind, persistence: .transient, in: view)
            guard let pill = Toast.debugPills(in: view).last else {
                fail("TO-1: a \(kind) report put no toast on its page", &ok)
                continue
            }
            check(pill.message == message, "TO-1: the \(kind) toast reads \"\(pill.message)\"", &ok)
            check(pill.kind == kind, "TO-1: a \(kind) report drew a \(pill.kind) toast - Feedback dropped its kind", &ok)
            check(pill.glyphSymbol == ToastHeroWords.symbol(for: kind),
                  "TO-1: a \(kind) toast wears \(pill.glyphSymbol)", &ok)
        }
        // A plain `Toast.show` is still a done, as every caller drew before.
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        Toast.show(in: plain, message: "Saved")
        check(Toast.debugPills(in: plain).last?.kind == .done, "TO-1: a plain toast is no longer a done", &ok)
        return ok
    }

    /// Finding 2: toasts were never announced. One announcement per toast,
    /// posted from the real `show` path.
    private static func checkEachToastIsAnnouncedOnce() -> Bool {
        var ok = true
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        Toast.debugAnnouncements.removeAll()
        Toast.show(in: view, message: "Copied to clipboard")
        check(Toast.debugAnnouncements == ["Copied to clipboard"],
              "TO-1: a toast was announced as \(Toast.debugAnnouncements), want it once, as written", &ok)
        Toast.showUndo(in: view, message: "Note deleted") {}
        check(Toast.debugAnnouncements.last == "Note deleted, Undo available",
              "TO-1: an Undo toast was announced as \(Toast.debugAnnouncements.last ?? "nothing")", &ok)
        Feedback.report("Docs sync failed", kind: .failure, persistence: .transient, in: view)
        check(Toast.debugAnnouncements.count == 3 && Toast.debugAnnouncements.last == "Docs sync failed",
              "TO-1: a report's toast was not announced exactly once (\(Toast.debugAnnouncements))", &ok)
        // No page, no toast, and so nothing to announce.
        Feedback.report("a background pass failed", kind: .failure, persistence: .transient, in: nil)
        check(Toast.debugAnnouncements.count == 3, "TO-1: a report with no page announced a toast nobody can see", &ok)
        Toast.debugAnnouncements.removeAll()
        return ok
    }

    private static func checkTheToastWords() -> Bool {
        var ok = true
        for kind in [Feedback.Kind.done, .warning, .failure] {
            let symbol = ToastHeroWords.symbol(for: kind)
            check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                  "TO-1: \(symbol) is not an SF Symbol on this system - the glyph would be blank", &ok)
        }
        check(ToastHeroWords.symbol(for: .done) == "checkmark"
                && ToastHeroWords.symbol(for: .warning) == "exclamationmark.triangle"
                && ToastHeroWords.symbol(for: .failure) == "xmark",
              "TO-1: the glyphs are not the board's check, triangle and cross", &ok)
        check(ToastHeroWords.announcement(message: "Saved", hasUndo: false) == "Saved",
              "TO-1: a plain toast's announcement is not its message", &ok)
        check(ToastHeroWords.announcement(message: "Deleted \u{201C}prod\u{201D}", hasUndo: true)
                == "Deleted \u{201C}prod\u{201D}, Undo available",
              "TO-1: an Undo toast's announcement does not say Undo is there", &ok)
        check(ToastHeroWords.announcement(message: "Task moved.", hasUndo: true) == "Task moved. Undo available.",
              "TO-1: a message ending a sentence got a comma after its full stop", &ok)
        return ok
    }

    /// Pure maths over every app theme, so CI's blocking lane holds the
    /// capsule's two contrast floors in all 26 palettes rather than the two
    /// the board drew.
    private static func checkTheCapsuleColoursInEveryTheme() -> Bool {
        var ok = true
        var failures: [String] = []
        for theme in HelmTheme.appThemes {
            let palette = ToastPill.palette(in: theme)
            let words = HelmContrast.ratio(palette.ink, palette.lighterStop)
            if words < HelmContrast.textTarget {
                failures.append("\(theme.id) words \(String(format: "%.2f", words))")
            }
            let darker = HelmContrast.relativeLuminance(palette.start) < HelmContrast.relativeLuminance(palette.end)
                ? palette.start : palette.end
            for kind in [Feedback.Kind.done, .warning, .failure] {
                let mark = HelmContrast.components(HelmHeroSurface.signalColor(tintHex: kind.tint.hex(in: theme), on: palette))
                let worst = min(HelmContrast.ratio(mark, palette.lighterStop), HelmContrast.ratio(mark, darker))
                if worst < HelmContrast.nonTextTarget {
                    failures.append("\(theme.id) \(kind) glyph \(String(format: "%.2f", worst))")
                }
            }
        }
        check(HelmTheme.appThemes.count >= 2, "TO-1: no app themes to sweep - the sweep would be vacuous", &ok)
        check(failures.isEmpty, "TO-1: the capsule misses a contrast floor: \(failures)", &ok)
        return ok
    }
}

#endif
