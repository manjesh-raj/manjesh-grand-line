// Manjesh Grand Line - native macOS app.
//
// Fix 5 (fixes4): a brief, non-blocking success confirmation. Nothing like
// this existed anywhere in the app before this fix - Save actions (hosts,
// keys) just silently closed with no feedback that anything happened. A
// small pill anchored under the top edge of the given view, styled from the
// active Helm theme, fading in and back out on its own.

// GL-30 - the app's one written rule for telling the captain something went
// wrong or right. Pick by *how long it has to matter*, not by how bad it is:
//
//   - **Modal** (`NSAlert`) - only when an action is blocked pending a
//     decision the captain has to make now: a destructive delete, an import
//     that will overwrite, a conflict that cannot be auto-resolved. A modal
//     for information is a modal that gets dismissed unread.
//   - **Toast** (this file) - a transient confirmation of something that just
//     happened and needs no decision: saved, copied, deleted-with-undo. It
//     fades, and nothing is lost if it is missed.
//   - **Notification Center** (`GrandLineNotificationCenter` /
//     `NotificationSources`) - anything that is still true after the toast
//     fades: a persistence write that failed, a service that has been failing
//     for three passes, a signal that needs action later. It stays until the
//     condition resolves.
//
// The failure mode this exists to prevent is the middle case swallowing the
// third: a toast saying "couldn't save" is a toast the captain can miss
// entirely, and the data is still unsaved afterwards. Phase 2 wired the
// persistence and service-health paths into the Notification Center for exactly
// that reason (`PersistenceFailureReporter`, `ServiceHealthRegistry`); this
// note is the rule those two now follow, written down so the next path does
// too.

import AppKit

enum Toast {
    /// The app's one undo affordance (GL-33).
    ///
    /// There is no `UndoManager` anywhere in this app, and retrofitting one
    /// across six stores with six different persistence shapes is not what the
    /// review asked for - what it asked for is that deleting a record not be
    /// instantly irreversible. So: the same confirmation pill, with a real
    /// Undo button beside it, holding exactly one pending undo at a time.
    ///
    /// The contract a caller has to honour is the important part: `onUndo`
    /// must genuinely restore the record, so a caller passes a closure that
    /// re-adds the *value it already had in hand* rather than one that tries
    /// to reconstruct it. That is why this is not wired to deletions whose
    /// content is genuinely gone - an SSH key's private bytes leave the
    /// Keychain on delete, and an "Undo" that silently produced a key entry
    /// with no key material would be a lie.
    ///
    /// One slot, deliberately: two stacked undo pills is a state a captain
    /// cannot reason about, and the second delete's pill replacing the first
    /// (committing it) matches how every other one-slot undo on this platform
    /// behaves.
    static func showUndo(in container: NSView, message: String, onUndo: @escaping () -> Void) {
        show(in: container, message: message, undo: onUndo)
    }

    static func show(in container: NSView, message: String) {
        show(in: container, message: message, undo: nil)
    }

    /// §6.14's toast hue - the one a Daylight undo's action word takes.
    ///
    /// Blue, not the calling page's own domain hue: a toast is presented on
    /// whatever container the caller hands over (`AppShellController.view` for a
    /// host save, `HostsController.view` for a key save), and it has no way to
    /// know which destination that is. §6.14 asks for "the domain hue's light
    /// stop" and the app's own identity hue is the honest answer to "which
    /// domain" for a control that floats above all of them.
    private static let toastHue: HelmDomainHue = .blue

    private static func show(in container: NSView, message: String, undo: (() -> Void)?) {
        let theme = ThemeManager.shared.theme
        // §6.14: capsule, `ink` fill, white 12 semibold text, raised shadow,
        // top-centre. The other twelve palettes keep the bordered
        // `chromeBackground` pill they have always rendered - a dark-on-dark
        // toast on `helm-dark` would be worse, not more consistent.
        let daylight = theme.isDaylight

        let glyph = NSTextField(labelWithString: "\u{2713}")
        glyph.font = .systemFont(ofSize: 12, weight: .bold)
        glyph.textColor = daylight ? .white : HelmTheme.nsColor(theme.ansiHex[2])
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.font = daylight
            ? .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
            : .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = daylight ? .white : HelmTheme.nsColor(theme.chromeInkHex)
        label.translatesAutoresizingMaskIntoConstraints = false

        var arranged: [NSView] = [glyph, label]
        var undoButton: HelmButton?
        if undo != nil {
            let button = HelmButton(title: "Undo", variant: .quiet, size: .small)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            // A `.quiet` button's own label is `muted`, which is a *page*
            // colour and would disappear against the ink capsule. §6.14's
            // "action word in the domain hue's light stop" is what replaces it,
            // through `labelColorOverride` rather than by assigning
            // `attributedTitle` - `restyle()` owns that property and would
            // overwrite an external assignment on the next theme change.
            if daylight { button.labelColorOverride = toastHue.pair(in: theme).h2 }
            arranged.append(button)
            undoButton = button
        }

        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = daylight
            ? HelmTheme.nsColor(theme.daylightTokens.ink).cgColor
            : HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        pill.layer?.borderWidth = daylight ? 0 : 1
        pill.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        if daylight {
            // The capsule radius has to come from the pill's *resolved* height,
            // which is only known after a layout pass - so the radius is set
            // below, once the constraints have run. The raised shadow is drawn
            // on this same layer: nothing clips it, because a pill has no
            // rounded child to mask.
            let shadow = HelmCard.elevation(for: theme, level: .raised)
            pill.layer?.shadowColor = shadow.shadowColor?.cgColor
            pill.layer?.shadowOpacity = 1
            pill.layer?.shadowRadius = shadow.shadowBlurRadius / 2
            pill.layer?.shadowOffset = CGSize(width: shadow.shadowOffset.width,
                                              height: shadow.shadowOffset.height)
        } else {
            pill.layer?.cornerRadius = 10
        }
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.alphaValue = 0
        pill.addSubview(stack)

        container.addSubview(pill)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -9),
            pill.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            pill.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        ])

        if daylight {
            container.layoutSubtreeIfNeeded()
            pill.layer?.cornerRadius = HelmMetrics.capsuleRadius(forHeight: pill.bounds.height)
        }

        // A new pill supersedes whatever was on screen - including, for an
        // undo pill, committing the previous delete by simply never running
        // its handler.
        activeUndo?.dismiss()
        activeUndo = nil

        // Phase 6's Reduce Motion audit: appear and disappear instantly rather
        // than cross-fading when the captain has asked for less motion. The
        // pill still shows for the same duration - what goes away is the fade,
        // not the message.
        HelmMotion.animate(duration: 0.18) { pill.animator().alphaValue = 1 }

        let dismiss = {
            guard !HelmMotion.isReduced else {
                pill.removeFromSuperview()
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                pill.animator().alphaValue = 0
            }, completionHandler: {
                pill.removeFromSuperview()
            })
        }

        guard let undo, let undoButton else {
            DispatchQueue.main.asyncAfter(deadline: .now() + plainDuration, execute: dismiss)
            return
        }

        // An undo pill stays up longer, because it is asking a question rather
        // than reporting a fact.
        let slot = UndoSlot(pill: pill, dismiss: dismiss, undo: undo)
        activeUndo = slot
        undoButton.target = slot
        undoButton.action = #selector(UndoSlot.undoClicked)
        let expiry = DispatchWorkItem { [weak slot] in
            guard let slot, activeUndo === slot else { return }
            activeUndo = nil
            slot.dismissWithoutUndo()
        }
        slot.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + undoDuration, execute: expiry)
    }

    /// How long a plain confirmation stays up, and how long an undo offer does.
    private static let plainDuration: TimeInterval = 1.8
    private static let undoDuration: TimeInterval = 6.0

    /// The one pending undo. Static because the pill is app-modal in spirit -
    /// there is one of them on screen at a time, whichever page put it there.
    private static var activeUndo: UndoSlot?

    /// A pending undo offer. An object rather than a closure pair so it can be
    /// an `@objc` target for the button and be compared by identity when the
    /// expiry timer fires.
    private final class UndoSlot: NSObject {
        private let pill: NSView
        private let dismissPill: () -> Void
        private let undo: () -> Void
        var expiry: DispatchWorkItem?
        private var spent = false

        init(pill: NSView, dismiss: @escaping () -> Void, undo: @escaping () -> Void) {
            self.pill = pill
            self.dismissPill = dismiss
            self.undo = undo
        }

        @objc func undoClicked() {
            guard !spent else { return }
            spent = true
            expiry?.cancel()
            if Toast.activeUndo === self { Toast.activeUndo = nil }
            dismissPill()
            undo()
        }

        /// The offer expired, or another pill replaced it: the delete stands.
        func dismissWithoutUndo() {
            guard !spent else { return }
            spent = true
            expiry?.cancel()
            dismissPill()
        }

        /// Used when a newer pill takes the slot.
        func dismiss() { dismissWithoutUndo() }
    }
}
