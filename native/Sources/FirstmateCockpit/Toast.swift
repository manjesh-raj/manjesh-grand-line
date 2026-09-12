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

        // G1: a checkmark *symbol*, not a literal "✓" in a bold system font.
        // A text tick renders at whatever weight the font gives it and sits on
        // the text baseline rather than optically centred against the message
        // beside it; the symbol is designed to sit beside a label.
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                              accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        // Corrected against the card surface the tick actually lands on, not
        // used raw: a `HelmTint` hue is safe as a fill and is not automatically
        // safe as ink (`HelmContrast`'s own rule).
        glyph.contentTintColor = HelmContrast.legibleTintedText(
            tintHex: HelmTint.good.hex(in: theme),
            over: HelmTheme.nsColor(theme.chromeBackgroundHex),
            theme: theme)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
        // G1: "the theme's ink" - one rule for all fourteen palettes now. The
        // fixed white-on-ink capsule this replaced ignored the theme's own
        // surfaces entirely, which is the finding verbatim.
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.translatesAutoresizingMaskIntoConstraints = false

        var arranged: [NSView] = [glyph, label]
        var undoButton: HelmButton?
        if undo != nil {
            // G1: "the Undo affordance styled as a capsule button inside".
            // `.secondary` is the bordered capsule; `.quiet` was a bare word,
            // which on a card surface no longer reads as a control at all now
            // that the surface is light in half the palettes.
            let button = HelmButton(title: "Undo", variant: .secondary, size: .small)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            arranged.append(button)
            undoButton = button
        }

        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.alphaValue = 0
        pill.addSubview(stack)

        container.addSubview(pill)
        // G1: **bottom**-centre, above the content area. Top-centre put every
        // confirmation underneath the floating bar and across its search pill -
        // the one strip of chrome guaranteed to be there.
        let bottom = pill.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                                  constant: -bottomInset)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -9),
            pill.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bottom,
        ])

        container.layoutSubtreeIfNeeded()
        // G1: "`card`-on-elevation styling". The app's one card surface, so a
        // toast cannot disagree with the cards it floats over, plus the second
        // of §2.5's two elevation levels - which is what `raised` is for.
        HelmCard.applyCardSurface(to: pill, theme: theme,
                                  cornerRadius: HelmMetrics.capsuleRadius(forHeight: pill.bounds.height),
                                  daylightRadius: HelmMetrics.capsuleRadius(forHeight: pill.bounds.height))
        let shadow = HelmCard.elevation(for: theme, level: .raised)
        pill.layer?.masksToBounds = false
        pill.layer?.shadowColor = shadow.shadowColor?.cgColor
        pill.layer?.shadowOpacity = 1
        pill.layer?.shadowRadius = shadow.shadowBlurRadius / 2
        pill.layer?.shadowOffset = CGSize(width: shadow.shadowOffset.width,
                                          height: shadow.shadowOffset.height)

        // A new *undo* pill still supersedes whatever undo was on screen -
        // including committing that delete by simply never running its handler.
        // G1 asks for stackable *toasts*, which is a different thing: two
        // plain confirmations stacking is readable, whereas two pending undos
        // is a state a captain cannot reason about (GL-33's own reasoning,
        // unchanged).
        if undo != nil {
            activeUndo?.dismiss()
            activeUndo = nil
        }

        let entry = Entry(pill: pill, bottom: bottom, container: container)
        live.append(entry)
        restack(in: container, animated: false)

        // G1: "spring rise + fade (translate 12pt)". The rise is a layer
        // translation rather than a constraint animation so it composes with
        // `restack`'s own constant writes without the two fighting over the
        // same constraint.
        if HelmMotion.isReduced {
            pill.alphaValue = 1
        } else {
            pill.wantsLayer = true
            pill.layer?.transform = CATransform3DMakeTranslation(0, -riseDistance, 0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = HelmMotion.springDuration
                context.timingFunction = HelmMotion.spring()
                context.allowsImplicitAnimation = true
                pill.layer?.transform = CATransform3DIdentity
                pill.animator().alphaValue = 1
            }
        }

        let dismiss = {
            entry.retire()
            guard !HelmMotion.isReduced else {
                pill.removeFromSuperview()
                restack(in: container, animated: false)
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                pill.layer?.transform = CATransform3DMakeTranslation(0, -riseDistance, 0)
                pill.animator().alphaValue = 0
            }, completionHandler: {
                pill.removeFromSuperview()
                restack(in: container, animated: true)
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

    // MARK: G1 - stacking

    /// How far above the container's bottom edge the lowest pill sits.
    static let bottomInset: CGFloat = 24
    /// The gap between two stacked pills.
    static let stackSpacing: CGFloat = 8
    /// How far a pill rises as it fades in (G1's "translate 12pt").
    static let riseDistance: CGFloat = 12

    /// One live pill. Held weakly on the container so a page torn down while a
    /// toast is up cannot keep it - and `retire()` is idempotent, because the
    /// dismiss closure and an undo click can both reach it.
    private final class Entry {
        let pill: NSView
        let bottom: NSLayoutConstraint
        weak var container: NSView?
        var retired = false
        init(pill: NSView, bottom: NSLayoutConstraint, container: NSView) {
            self.pill = pill
            self.bottom = bottom
            self.container = container
        }
        func retire() { retired = true }
    }

    private static var live: [Entry] = []

    /// Re-place every live pill in `container`, newest at the bottom.
    ///
    /// Called on show and after every dismissal, so a pill leaving the middle
    /// of the stack closes the gap rather than leaving a hole.
    private static func restack(in container: NSView, animated: Bool) {
        live.removeAll { $0.container == nil || $0.retired && $0.pill.superview == nil }
        var offset = bottomInset
        // Newest last in `live`, and newest lowest on screen - so the stack
        // grows upward away from the content the captain is looking at.
        for entry in live.reversed() where entry.container === container && !entry.retired {
            entry.pill.superview?.layoutSubtreeIfNeeded()
            let height = max(entry.pill.bounds.height, entry.pill.fittingSize.height)
            // **Never `constraint.animator().constant` on the unanimated
            // branch.** The animator proxy routes the write through AppKit's
            // animation machinery whether or not a context is open, so an
            // "unanimated" assignment does not take immediately - which is the
            // trap `HelmMotion.fade`'s own header records, and which showed up
            // here as two toasts landing on top of each other.
            if animated && !HelmMotion.isReduced {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = HelmMotion.stateDuration
                    entry.bottom.animator().constant = -offset
                }
            } else {
                entry.bottom.constant = -offset
            }
            offset += height + stackSpacing
        }
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
