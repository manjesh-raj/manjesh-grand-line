// Manjesh Grand Line - native macOS app.
//
// `Feedback` - the one place that decides *where* a message lands.
//
// Review #3's UX14: "Toasts are shown on the page that produced them (B8),
// notifications go to the bell, some failures go to Health, and a few still go
// to an `NSAlert`. GL-30 wrote the rule; the implementation is uneven.
// *Direction:* one `Feedback.report(kind:scope:)` that routes by rule."
//
// GL-30 is already written down and is already right:
//
//   > Modal for a blocked decision, toast for a transient confirmation,
//   > Notification Center for anything still true after the toast fades.
//
// What was missing is that every call site applied it from memory. A caller
// reached for `Toast.show` because the page next door did, and the question the
// rule actually asks - *is this still true in thirty seconds?* - was never
// posed. This type poses it, in the signature, and then routes.
//
// # The shape, and why it is these two axes
//
// A caller states two facts about what happened and never names a surface:
//
//   - `Kind` - what it is (done / warning / failure). This picks the wording's
//     tint and, for the bell, the notification kind.
//   - `Persistence` - whether it is **still true after a toast would have
//     faded**. That single question is GL-30's own dividing line, and it is
//     the one a call site can actually answer about its own situation.
//
// A blocked *decision* is deliberately **not** on these axes. A decision needs
// an answer, so it needs a return path and a sheet - `HelmConfirm` and
// `DestructiveConfirm` already own that, and folding them in here would mean a
// router that sometimes returns a value and sometimes does not. GL-30's
// "modal" third is theirs; this covers the two thirds that were uneven.
//
// # What this is not
//
// It is not a new toast, a new bell or a new anything - it dispatches to
// `Toast` and `GrandLineNotificationCenter`, which are unchanged. A caller
// that already reaches the right surface behaves identically after migrating;
// what it gains is that the *decision* is no longer re-made at the call site.

import AppKit

enum Feedback {
    /// What happened.
    enum Kind {
        /// Something the captain asked for, and it worked.
        case done
        /// It worked, but not entirely, or it needs looking at eventually.
        case warning
        /// It did not work.
        case failure

        var tint: HelmTint {
            switch self {
            case .done: return .good
            case .warning: return .warn
            case .failure: return .critical
            }
        }

        /// How the bell files it, when it gets that far.
        var notificationKind: AppNotificationKind {
            switch self {
            case .done: return .informational
            case .warning, .failure: return .actionNeeded
            }
        }
    }

    /// Is this still true after a toast would have faded?
    ///
    /// The one question GL-30 actually turns on, and the one a call site can
    /// answer about its own situation without knowing anything about the app's
    /// surfaces.
    enum Persistence {
        /// No. "Copied", "Saved", "Sent to the terminal" - the fact is used
        /// and gone before the pill is.
        case transient
        /// Yes. A failed sync, a store that could not be written, a
        /// credential that could not be read. A captain who looked away for
        /// ten seconds must still be able to find out.
        case lasting
    }

    /// Report something, and let the rule decide where it goes.
    ///
    /// - Parameters:
    ///   - message: the sentence the captain reads. One sentence.
    ///   - kind: what happened.
    ///   - persistence: whether it is still true in thirty seconds.
    ///   - view: the page that produced it, for the toast half. `nil` is
    ///     legitimate and means "there is no page" (a background pass, a
    ///     terminate-time flush) - the message then goes only where it can,
    ///     which is the bell.
    ///   - id: the bell entry's identity, for the `lasting` half. A stable id
    ///     is what lets a recurring condition *update* its entry instead of
    ///     stacking a new one every pass, and what lets it be cleared when it
    ///     resolves - see `clear(id:)`.
    ///   - detail: the bell's second line. Defaults to naming the page.
    ///   - navigate: what the bell row does when clicked.
    static func report(_ message: String,
                       kind: Kind,
                       persistence: Persistence,
                       in view: NSView?,
                       id: String? = nil,
                       detail: String? = nil,
                       navigate: (() -> Void)? = nil) {
        // The toast half. A `lasting` message gets one **too**, not instead:
        // the captain is looking at the page right now, and making them find
        // the bell for something that just happened would be worse feedback,
        // not better. GL-30's rule is about what survives, not about
        // suppressing the immediate signal.
        if let view {
            Toast.show(in: view, message: message)
        }

        guard persistence == .lasting else { return }
        // Without an id there is nothing to update or clear later, and an
        // un-clearable bell entry is worse than none - it would sit there
        // claiming a condition that has since resolved. A caller that cannot
        // supply one is telling us this is not really a lasting condition.
        guard let id else {
            AppLog.lifecycle.error("Feedback: a lasting report with no id was dropped from the bell - \(message, privacy: .public)")
            return
        }
        GrandLineNotificationCenter.shared.set(
            AppNotification(id: id,
                            title: message,
                            subtext: detail ?? "",
                            kind: kind.notificationKind,
                            tint: kind.tint,
                            navigate: navigate ?? {}),
            id: id)
    }

    /// The condition behind a `lasting` report has resolved.
    ///
    /// The half that is easy to forget and that makes the whole mechanism
    /// honest: a bell that only ever accumulates is a bell nobody reads.
    /// Pairs one-to-one with `report(... persistence: .lasting, id:)`.
    static func clear(id: String) {
        GrandLineNotificationCenter.shared.set(nil, id: id)
    }

    /// The routing rule as data, so a suite can assert it without a window, a
    /// toast or a notification center.
    ///
    /// Returns every surface a report reaches. This is the function
    /// `FeedbackRoutingSelfTest` checks; `report` above is the same decision
    /// expressed as side effects, and the suite asserts they agree.
    static func surfaces(persistence: Persistence,
                         hasView: Bool,
                         hasID: Bool) -> Set<Surface> {
        var result: Set<Surface> = []
        if hasView { result.insert(.toast) }
        if persistence == .lasting, hasID { result.insert(.notificationCenter) }
        return result
    }

    enum Surface: Hashable {
        case toast
        case notificationCenter
    }
}
