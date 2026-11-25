// Grand Line - native macOS app.
//
// Fix 5 (fixes4): a brief, non-blocking success confirmation. Nothing like
// this existed anywhere in the app before this fix - Save actions (hosts,
// keys) just silently closed with no feedback that anything happened.
//
// Since G1 it is a capsule at the **bottom centre** of the given view, on the
// raised elevation, rising 12pt as it fades in, with Undo as a capsule button
// inside. (This header said "under the top edge" for a while after G1 moved
// it, and the UI/UX revamp's UI-62 was written from that sentence - the code
// had already done what UI-62 asks.)
//
// ## TO-1 Hero capsule (Helm 10.4.0)
//
// The captain's pick on the hero restyle board
// (`data/grandline-hero-restyle-designs-scout/`). The capsule paints the hero
// gradient (`HelmHeroSurface`, the quiet-ink palette the hero columns use)
// with the words in its white ink, so a confirmation speaks the same language
// as the sidebar, the hero cards and the popover heads. Three things changed
// beyond the paint, and two of them were defects:
//
//   - **The glyph says the kind.** `show` takes a `Feedback.Kind`, and the
//     glass circle holds a check, a triangle or a cross, each in that state's
//     hue lifted to read on the gradient (`HelmHeroSurface.signalColor`).
//     Before this every toast drew a green check, and `Feedback.report`
//     dropped its kind on the way in, so "Docs sync failed" looked like a
//     success.
//   - **VoiceOver hears each toast once** (`announce`). The pill is never
//     focused and is gone in seconds, so without the announcement a VoiceOver
//     user got nothing at all.
//   - **Undo's hairline drains** over the six seconds the offer stands, so the
//     time left is visible. Under Reduce Motion there is no drain.
//
// Timings, stacking and the single Undo slot (GL-33) are unchanged. Under
// Reduce Motion the pill still appears and leaves at once, with no rise: the
// board draws an opacity fade there, and the app's rule is the end state,
// instantly (`HelmMotion`'s header), which is what this did before TO-1.

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
        show(in: container, message: message, kind: .done, undo: onUndo)
    }

    /// Marks a presented pill so a suite can count what is really on screen.
    ///
    /// Review #3's B8 is about *where* a toast lands, and a toast is a plain
    /// `NSView` in whatever container it was handed - there is no other way to
    /// ask "is one showing here" from outside.
    static let pillIdentifier = NSUserInterfaceItemIdentifier("helm.toast.pill")

    #if FM_SELFTESTS
    /// How many toast pills are currently in `root`'s view tree.
    static func debugCount(in root: NSView) -> Int {
        var found = root.identifier == pillIdentifier ? 1 : 0
        for sub in root.subviews { found += debugCount(in: sub) }
        return found
    }

    /// The pills in `root`'s view tree, oldest first.
    static func debugPills(in root: NSView) -> [ToastPill] {
        var found: [ToastPill] = []
        if let pill = root as? ToastPill { found.append(pill) }
        for sub in root.subviews { found += debugPills(in: sub) }
        return found
    }

    /// Every announcement `show` has posted in this process, in order. A
    /// VoiceOver announcement goes to the system and cannot be read back, so
    /// `announce` records what it posts here, on the same path.
    static var debugAnnouncements: [String] = []
    #endif

    /// Report something that just happened. `kind` picks the glyph: a check
    /// for done (the default, and what every caller drew before TO-1), a
    /// triangle for a warning, a cross for a failure.
    static func show(in container: NSView, message: String, kind: Feedback.Kind = .done) {
        show(in: container, message: message, kind: kind, undo: nil)
    }

    private static func show(in container: NSView, message: String, kind: Feedback.Kind,
                             undo: (() -> Void)?) {
        let theme = ThemeManager.shared.theme
        let pill = ToastPill(message: message, kind: kind, hasUndo: undo != nil, theme: theme)
        pill.alphaValue = 0
        pill.identifier = Self.pillIdentifier
        let undoButton = pill.undoButton

        container.addSubview(pill)
        // G1: **bottom**-centre, above the content area. Top-centre put every
        // confirmation underneath the floating bar and across its search pill -
        // the one strip of chrome guaranteed to be there.
        let bottom = pill.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                                  constant: -bottomInset)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bottom,
        ])

        container.layoutSubtreeIfNeeded()
        pill.applyCapsule(theme: theme)
        announce(ToastHeroWords.announcement(message: message, hasUndo: undo != nil))

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
            HelmMotion.withoutActions {
                pill.layer?.transform = CATransform3DMakeTranslation(0, -riseDistance, 0)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = HelmMotion.springDuration
                context.timingFunction = HelmMotion.spring()
                pill.animator().alphaValue = 1
                // The rise is a layer `transform`, which `allowsImplicitAnimation`
                // does not animate on a view-backed layer (measured, P1 of the
                // polish report) - it used to snap while only the fade ran.
                HelmMotion.animateLayers(duration: HelmMotion.springDuration,
                                         timing: HelmMotion.spring(), on: [pill.layer]) {
                    pill.layer?.transform = CATransform3DIdentity
                }
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
                ctx.duration = HelmMotion.springDuration
                HelmMotion.animateLayers(duration: HelmMotion.springDuration, on: [pill.layer]) {
                    pill.layer?.transform = CATransform3DMakeTranslation(0, -riseDistance, 0)
                }
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
        // TO-1: the hairline drains over exactly the time the offer stands.
        pill.startDrain(duration: undoDuration)
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

    /// How much room a page should leave under its own content so a toast
    /// never lands on top of it (review U10).
    ///
    /// `bottomInset` plus a pill's own height plus a gap. The height is a
    /// constant rather than measured, because a page's layout is decided
    /// before any toast exists - and it is stated here rather than at the
    /// call site so a change to the pill's padding or font moves every page
    /// that reserves space, not just the one somebody remembered.
    /// TO-1: 36, the board's capsule, which holds the 22pt glyph circle and a
    /// small Undo pill with 6pt to spare above and below. It was 34.
    static let pillHeight: CGFloat = 36
    static let reservedBottomSpace: CGFloat = bottomInset + pillHeight + 12
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
    static let plainDuration: TimeInterval = 1.8
    static let undoDuration: TimeInterval = 6.0

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

    // MARK: TO-1 - VoiceOver

    /// One announcement per toast (finding 2 of the hero restyle report).
    ///
    /// The pill is never focused and leaves within seconds, so nothing about
    /// it reached VoiceOver on its own. The same shape as the dictation HUD's
    /// (`DictationHUD.swift`'s `present`): an announcement needs no focus and
    /// takes none from the page the captain is working in.
    private static func announce(_ text: String) {
        #if FM_SELFTESTS
        debugAnnouncements.append(text)
        #endif
        NSAccessibility.post(element: NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

// MARK: - TO-1 Hero capsule

/// One toast: the hero gradient as a capsule, a glass circle holding the
/// kind's glyph, the message in the hero's ink, and Undo as a ghost pill whose
/// hairline drains while the offer stands.
///
/// Internal rather than private so a suite can read what one pill painted.
/// Only `Toast` builds one.
final class ToastPill: NSView {

    static let glyphSide: CGFloat = 22
    static let glyphPointSize: CGFloat = 11
    static let messageSize: CGFloat = 12
    static let spacing: CGFloat = 9
    static let leadingInset: CGFloat = 14
    static let trailingInset: CGFloat = 14
    /// With Undo the pill closes in on the button, as the board draws it, so
    /// the drain's ring sits 3pt from the capsule's own edge.
    static let undoTrailingInset: CGFloat = 6
    static let verticalInset: CGFloat = 6
    /// The capsule's inner hairline, the board's 16% white edge.
    static let edgeAlpha: CGFloat = 0.16
    /// How far the drain's ring stands off the Undo pill, its width and its
    /// strength in the ink.
    static let drainOutset: CGFloat = 3
    static let drainLineWidth: CGFloat = 1.5
    static let drainAlpha: CGFloat = 0.75

    /// The one palette a toast paints: the theme's hero colour through the
    /// quiet-ink rule the hero columns use, as the board's `.hero.q`.
    static func palette(in theme: HelmTheme) -> HelmHeroSurface.Palette {
        HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: theme)
    }

    let message: String
    let kind: Feedback.Kind
    let palette: HelmHeroSurface.Palette
    /// The glyph's SF Symbol, kept beside the image it was built from.
    let glyphSymbol: String
    private let surface = HelmHeroSurface()
    private let glyphTile = NSView()
    private let glyph = NSImageView()
    private let label: NSTextField
    let undoButton: HelmButton?
    private let drain: UndoDrainView?

    init(message: String, kind: Feedback.Kind, hasUndo: Bool, theme: HelmTheme) {
        self.message = message
        self.kind = kind
        let palette = Self.palette(in: theme)
        self.palette = palette
        glyphSymbol = ToastHeroWords.symbol(for: kind)
        label = NSTextField(labelWithString: message)
        let ink = HelmContrast.color(palette.ink)
        if hasUndo {
            let button = HelmButton(title: "Undo", variant: .secondary, size: .small)
            button.heroInk = ink
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            undoButton = button
            // Reduce Motion: no drain at all, rather than a still ring that
            // would read as a border.
            drain = HelmMotion.isReduced
                ? nil : UndoDrainView(color: ink.withAlphaComponent(Self.drainAlpha), lineWidth: Self.drainLineWidth)
        } else {
            undoButton = nil
            drain = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // A white-ink hero is a dark surface, so the Undo pill's focus ring
        // and any system colour on it resolve the dark appearance's.
        let darkInk = HelmContrast.relativeLuminance(palette.ink) < 0.5
        appearance = NSAppearance(named: darkInk ? .aqua : .darkAqua)
        // The board's capsule glow: the card-sized one lay across the right
        // half of a 36pt pill as a grey wash.
        surface.glowShape = .capsule
        surface.apply(palette)
        addSubview(surface)

        glyphTile.wantsLayer = true
        glyphTile.translatesAutoresizingMaskIntoConstraints = false
        glyphTile.layer?.cornerRadius = Self.glyphSide / 2
        glyphTile.layer?.backgroundColor = ink.withAlphaComponent(PopoverHeroHeader.glassFillAlpha).cgColor
        glyphTile.layer?.borderColor = ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha).cgColor
        glyphTile.layer?.borderWidth = 1
        glyph.image = NSImage(systemSymbolName: glyphSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.glyphPointSize, weight: .semibold))
        // The kind's own hue, lifted until it clears the non-text floor on
        // both of the gradient's stops. A raw red cross on a deep blue
        // gradient is two dark colours side by side.
        glyph.contentTintColor = HelmHeroSurface.signalColor(tintHex: kind.tint.hex(in: theme), on: palette)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        glyphTile.addSubview(glyph)

        label.setScaledFont(ofSize: Self.messageSize, weight: .semibold)
        label.textColor = ink
        label.translatesAutoresizingMaskIntoConstraints = false

        var arranged: [NSView] = [glyphTile, label]
        if let undoButton { arranged.append(undoButton) }
        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // The height hugs the board's 36pt, and grows only if a large text
        // scale needs more: a fixed height would clip the words, and a height
        // nothing ties lets the content decide it alone (gotcha (16)).
        let hug = heightAnchor.constraint(equalToConstant: Toast.pillHeight)
        hug.priority = NSLayoutConstraint.Priority(249)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            glyphTile.widthAnchor.constraint(equalToConstant: Self.glyphSide),
            glyphTile.heightAnchor.constraint(equalToConstant: Self.glyphSide),
            glyph.centerXAnchor.constraint(equalTo: glyphTile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: glyphTile.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -(hasUndo ? Self.undoTrailingInset : Self.trailingInset)),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.verticalInset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.verticalInset),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Toast.pillHeight),
            hug,
        ])

        if let drain, let undoButton {
            addSubview(drain)
            NSLayoutConstraint.activate([
                drain.leadingAnchor.constraint(equalTo: undoButton.leadingAnchor, constant: -Self.drainOutset),
                drain.trailingAnchor.constraint(equalTo: undoButton.trailingAnchor, constant: Self.drainOutset),
                drain.topAnchor.constraint(equalTo: undoButton.topAnchor, constant: -Self.drainOutset),
                drain.bottomAnchor.constraint(equalTo: undoButton.bottomAnchor, constant: Self.drainOutset),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Round the capsule and lift it, once it has its real height. The inner
    /// hairline is the board's white edge, full strength under Increase
    /// Contrast. The shadow is the kit's raised elevation, the second of
    /// §2.5's two levels, which is what a toast has always floated on.
    func applyCapsule(theme: HelmTheme) {
        let radius = HelmMetrics.capsuleRadius(forHeight: bounds.height)
        let ink = HelmContrast.color(palette.ink)
        surface.layer?.cornerRadius = radius
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = ink.withAlphaComponent(HelmDisplayAccessibility.edgeAlpha(Self.edgeAlpha)).cgColor
        guard let layer else { return }
        layer.cornerRadius = radius
        layer.masksToBounds = false
        HelmCard.applyElevation(.raised, to: layer, theme: theme,
                                path: CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius,
                                             transform: nil))
    }

    /// Drain Undo's hairline over `duration`, linearly, so the ring is gone
    /// exactly when the offer is. A no-op under Reduce Motion, where there is
    /// no ring.
    func startDrain(duration: TimeInterval) {
        guard let shape = drain?.shape else { return }
        let ease = CABasicAnimation(keyPath: "strokeEnd")
        ease.fromValue = 1
        ease.toValue = 0
        ease.duration = duration
        ease.timingFunction = CAMediaTimingFunction(name: .linear)
        HelmMotion.withoutActions { shape.strokeEnd = 0 }
        shape.add(ease, forKey: Self.drainKey)
    }

    static let drainKey = "toast.undo.drain"

    #if FM_SELFTESTS
    var debugSurface: HelmHeroSurface { surface }
    var debugGlyph: NSImageView { glyph }
    var debugGlyphTile: NSView { glyphTile }
    var debugLabel: NSTextField { label }
    /// The drain's ring, or nil when there is none (no Undo, Reduce Motion).
    var debugDrainShape: CAShapeLayer? { drain?.shape }
    var debugDrainView: NSView? { drain }
    #endif
}

/// The ring around Undo that drains. It takes no clicks, so a press lands on
/// the button under it.
private final class UndoDrainView: NSView {
    let shape = CAShapeLayer()
    private let lineWidth: CGFloat

    init(color: NSColor, lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = lineWidth
        layer?.addSublayer(shape)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let ring = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = HelmMetrics.capsuleRadius(forHeight: ring.height)
        HelmMotion.withoutActions {
            shape.frame = bounds
            shape.path = CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }
}
