// Grand Line - native macOS app.
//
// `WorkspaceContent` - the body area every destination is mounted into, and
// the mechanics of showing one: the lazy-mount table, the per-page pins, the
// hidden-page detach and the navigation transition.
//
// Split out of `AppShellController` in stage 2 of the modular-shell migration
// (full review section 5.8, step 2), so the split-view shell that step 3
// builds can host the same destinations through the same mounter. The
// classic shell pins `bodyContainer` under the floating bar; the split shell
// will pin it into its content pane. Nothing about how a page is mounted,
// shown or hidden changed in the move: every method below is the shell's own
// code, and `DestinationMounter` itself is untouched.
//
// **What it deliberately does not know.** No destination, no store, no
// chrome. The pages are handed to `mounter` as slots by `Workspace`, and the
// view controller that adopts them as children is whichever shell is showing
// this container (`parentController`).

import AppKit

final class WorkspaceContent {

    /// The shell that adopts every mounted page as a child view controller.
    /// Set by the shell as soon as it exists - before its `loadView`, which is
    /// where the eager slots mount.
    weak var parentController: NSViewController?

    /// The dedicated host pages, which are mounted here too but are not
    /// slots (they are built per host, not per destination). Supplied by
    /// `HostSessionCoordinator`, so this type never learns what a host is.
    var hostPages: () -> [ConsoleController] = { [] }

    /// The body area every destination view (fixed or host page) is added
    /// to - a stored property (rather than a `loadView`-local `let`) so
    /// `connectHost`/`removeHostConsole` can add and remove host pages after
    /// the initial layout pass.
    let bodyContainer = NSView()

    /// GL-37: the destination table plus the lazy-mount mechanics - see
    /// `DestinationRegistry.swift`.
    ///
    /// `weak` with a guard rather than the `unowned self` these closures held
    /// while they lived on `AppShellController`: the mounter is owned by this
    /// object and only ever runs from a navigation reached through it, so
    /// `self` is alive in practice, but the migration plan's step 2 asks for
    /// the guard (a closure outliving its owner would be a crash under
    /// `unowned` and a no-op under `weak`). The behaviour is otherwise
    /// identical.
    private(set) lazy var mounter = DestinationMounter(
        mount: { [weak self] controller in
            guard let self else { return }
            self.parentController?.addChild(controller)
            self.embed(controller.view)
        },
        setVisible: { [weak self] controller, visible in
            guard let self else { return }
            self.setDestinationVisible(controller.view, visible)
        }
    )

    /// Pin a destination view to fill `bodyContainer` below the top bar -
    /// the same anchors every fixed destination and every host page use.
    func embed(_ destinationView: NSView) {
        destinationView.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(destinationView)
        let pins = [
            destinationView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            destinationView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            // A2: the drill header no longer sits between the bar and the
            // page, so a destination starts at the body container's own top.
            destinationView.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            destinationView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(pins)
        destinationPins[ObjectIdentifier(destinationView)] = pins
    }

    /// The four pins `embed` put on each destination view, so
    /// `setDestinationVisible` can take a hidden page out of the window's
    /// constraint graph without taking it out of the view hierarchy.
    private(set) var destinationPins: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    /// Show or hide one destination, and attach or detach it from the
    /// window's constraint graph to match (full review #3's PF1).
    ///
    /// ## Why this is not just `isHidden`
    ///
    /// **A hidden `NSView` still participates fully in Auto Layout** -
    /// AGENTS.md gotcha (11) says so in the other direction, and it is what
    /// makes GL-37's "mounted, only ever hidden" expensive rather than free.
    /// Every mounted destination is pinned to `bodyContainer`, so all ~27 of
    /// them are one required-constraint chain inside the window, and AppKit
    /// walks that entire chain every time it has to re-derive
    /// `minFullScreenContentSize` for a full-screen-capable window.
    ///
    /// Measured with a standalone stock-AppKit probe (5s `sample` at 1ms,
    /// main-thread samples in
    /// `_doUpdateTilingConstraintsImmediately -> minFullScreenContentSize ->
    /// NSISEngine`), one mounted-destination count per row, with a label's
    /// text changing 20x/second as the invalidation source:
    ///
    ///     1 mounted     16 samples    0.4% of the main thread
    ///     3 mounted    134            3.1%
    ///     7 mounted    357            8.3%
    ///    14 mounted    973           22.7%
    ///    27 mounted   1877           43.4%
    ///
    /// Near-linear in the number of mounted destinations, and the captain's
    /// own running instance measured 1090 samples (26.8% of its main thread,
    /// 76% of everything it was doing other than blocking) - squarely on that
    /// curve. A settled graph of any size costs **zero**: this is not stock
    /// AppKit idle work, it is the re-solve that any invalidation triggers.
    ///
    /// Deactivating a hidden page's four pins leaves its subtree with no
    /// required path to the window, so the derivation skips it. Same probe,
    /// 27 mounted, same 20Hz invalidation: **1777 samples -> 34**, i.e.
    /// 41.2% of the main thread -> 0.8%.
    ///
    /// ## What this deliberately does not do
    ///
    /// Nothing is torn down. GL-37's "a mounted slot is only ever hidden,
    /// never torn down" holds exactly as before - the controller, its view
    /// hierarchy, its scroll position, its in-flight fetches and any live ssh
    /// session are all untouched. This changes only whether a *hidden* page's
    /// geometry is something Auto Layout still has to solve for, which by
    /// definition nothing can observe while it is hidden. Unmounting cold
    /// destinations - GL-37's other half, and what the review reached for -
    /// would buy the same thing and cost a great deal more.
    func setDestinationVisible(_ destinationView: NSView, _ visible: Bool) {
        guard let pins = destinationPins[ObjectIdentifier(destinationView)] else {
            // A view this controller did not embed. Honour the visibility
            // change rather than silently ignoring it - the detach is an
            // optimisation, and it must never be the reason a page fails to
            // appear.
            destinationView.isHidden = !visible
            return
        }
        if visible {
            // Re-pin *before* unhiding, so the page is never on screen for a
            // pass with no constraints tying it to the container - which is
            // the one way this could read as a layout bug rather than as a
            // saving.
            for pin in pins where !pin.isActive { pin.isActive = true }
            // And lay the page out at the container's *current* size before
            // it is shown. Unhiding is what makes AppKit send the page its
            // `viewWillAppear`, synchronously, and a page whose pins were
            // only just re-activated still holds the frame it had when it
            // was hidden. Home's `viewWillAppear` rebuilds its grid from its
            // own clip width, so after a resize on another page it built the
            // grid for the old width and nothing rebuilt it: the polish
            // report's B1, measured as a Morning briefing column at maxX
            // 1488 in an 1100pt window. The page itself, not the container,
            // so the other mounted pages are not laid out for nothing.
            destinationView.layoutSubtreeIfNeeded()
            destinationView.isHidden = false
            destinationView.needsLayout = true
        } else {
            destinationView.isHidden = true
            for pin in pins where pin.isActive { pin.isActive = false }
        }
    }

    // MARK: B4 - the navigation transition

    /// Which way a navigation reads, and therefore which way the incoming page
    /// slides in from.
    enum TransitionDirection {
        /// Going deeper: the page enters from the trailing side and settles
        /// leftward, the way a push reads.
        case drillIn
        /// Coming back out to the hub: the mirror image.
        case back

        var entryOffset: CGFloat {
            switch self {
            case .drillIn: return WorkspaceContent.destinationTransitionOffset
            case .back: return -WorkspaceContent.destinationTransitionOffset
            }
        }
    }

    /// §3B B4's spec, measured from its own text: "a 150-200ms crossfade + 8-12pt
    /// slide".
    static let destinationTransitionDuration: TimeInterval = HelmMotion.moveDuration
    static let destinationTransitionOffset: CGFloat = 10

    #if FM_SELFTESTS
    /// What the last navigation decided. The *decision* (which direction, and
    /// whether it was skipped) is not otherwise observable once the animation
    /// has settled, and "was this skipped?" is exactly what B4's own text asks
    /// to be true - so it is recorded rather than inferred from a frame read
    /// that would be identical either way a moment later.
    /// `entryOffset` is what was actually applied, not what the direction
    /// *would* give: a frame read cannot answer this, because
    /// `NSAnimationContext.runAnimationGroup`'s body runs synchronously, so
    /// the model transform is already back at identity by the time this method
    /// returns. The animation's own existence on the layer is what the suite
    /// checks alongside this.
    private(set) var lastTransitionForTests: (direction: TransitionDirection, skipped: Bool,
                                              reducedMotion: Bool, entryOffset: CGFloat)?
    #endif

    /// B4: fade and slide a freshly-shown destination in.
    ///
    /// **What the report asks for, and the one place this deviates.** §3B B4
    /// describes "outgoing view fades to 0 / incoming from 0". This animates
    /// the incoming page only, and hides the outgoing one immediately exactly
    /// as `hideAllDestinations()` always did. The reason is not effort: three
    /// things in this shell ask "which destination is on screen?" by looking
    /// for the one mounted view that is not hidden -
    /// `visibleDestinationView()` (which feeds `firstBodyKeyView()` and
    /// therefore the whole key view loop, and which returns the *first* match),
    /// plus accessibility and hit-testing. Keeping a second destination
    /// visible for 180ms makes all three temporarily answer wrong, and the
    /// alternative - snapshotting the outgoing page into a throwaway layer -
    /// puts a full-page `cacheDisplay` on the main thread on every single
    /// navigation, which is precisely the class of cost the same audit's §3
    /// energy work went looking for. Both pages are opaque and cover the same
    /// rect, so a true crossfade would render them muddled through each other
    /// for those 180ms rather than reading cleaner; a page fading and sliding
    /// in over the app's own ground is the motion the finding describes,
    /// minus a double render.
    ///
    /// Gated through `HelmMotion`, which per its own rule means the end state
    /// *instantly* - never the same motion, slower.
    func animateDestinationEntrance(_ destinationView: NSView,
                                            direction: TransitionDirection,
                                            skip: Bool) {
        // A navigation to the page already showing is not a navigation. It
        // still re-runs everything else `show(_:)` does (a Setup tab switch, a
        // drill-header refresh), it just does not re-announce itself.
        #if FM_SELFTESTS
        lastTransitionForTests = (direction: direction, skipped: skip,
                                  reducedMotion: HelmMotion.isReduced,
                                  entryOffset: skip || HelmMotion.isReduced ? 0 : direction.entryOffset)
        #endif
        guard !skip else {
            destinationView.alphaValue = 1
            destinationView.layer?.transform = CATransform3DIdentity
            return
        }
        guard !HelmMotion.isReduced else {
            destinationView.alphaValue = 1
            destinationView.layer?.transform = CATransform3DIdentity
            return
        }

        // Snap to the entry state. `CATransaction` with actions disabled,
        // because a view-backed layer's `transform` would otherwise pick up
        // Core Animation's default implicit animation and slide *into* the
        // start position (`HelmMotion.withoutImplicitAnimation` is the same
        // mechanism, but it is deliberately Reduce-Motion-gated and this has
        // to happen in both states).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        destinationView.alphaValue = 0
        destinationView.layer?.transform = CATransform3DMakeTranslation(direction.entryOffset, 0, 0)
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.destinationTransitionDuration
            // One ease-out, which is the audit's §3L motion spec's own second
            // curve ("one spring ... and one ease-out (0.15s) as the only two
            // curves"). A spring belongs on a gesture-driven or interruptible
            // move; a 180pt-per-second settle into place does not need one.
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            destinationView.animator().alphaValue = 1
            // The slide is a *layer* property, which `allowsImplicitAnimation`
            // does not animate on a view-backed layer (measured, P1 of the
            // polish report): it used to land in one frame while only the
            // fade ran. `animateLayers` attaches the travel explicitly.
            HelmMotion.animateLayers(duration: Self.destinationTransitionDuration,
                                     on: [destinationView.layer]) {
                destinationView.layer?.transform = CATransform3DIdentity
            }
        }
    }

    /// The page on screen: the one mounted slot or host page that is not
    /// hidden. Read by the shell's key view loop and by its width repair.
    func visibleDestinationView() -> NSView? {
        for slot in mounter.mountedSlots where !slot.controller.view.isHidden {
            return slot.controller.view
        }
        for controller in hostPages()
        where controller.isViewLoaded && !controller.view.isHidden {
            return controller.view
        }
        return nil
    }

    /// P3 of the polish report: installed by `AppDelegate` (see
    /// `PageCrossfade`'s header for why never by this controller). `nil` means
    /// the outgoing page cuts, which is what every self-test's shell does.
    var pageCrossfade: PageCrossfade?

    /// Hand the page on screen now to `pageCrossfade`, before
    /// `hideAllDestinations` takes it away.
    func crossfadeOutgoingPage(unless repeated: Bool) {
        guard !repeated, let pageCrossfade else { return }
        guard let page = bodyContainer.subviews.first(where: {
            !$0.isHidden && destinationPins[ObjectIdentifier($0)] != nil
        }) else { return }
        pageCrossfade.crossfade(from: page, in: bodyContainer)
    }
}
