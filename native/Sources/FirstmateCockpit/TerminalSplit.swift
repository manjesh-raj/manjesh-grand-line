// Manjesh Grand Line - native macOS app.
//
// Split panes inside one Console tab (`fm/grand-line-terminal-shortcuts-
// settings`). A tab used to be exactly one terminal; it is now a small tree of
// them, and this file is the whole of that tree - the model, the view, and
// every mutation. `ConsoleController+Splits.swift` is the thin layer that
// turns a keystroke into one of these calls.
//
// ## Why `NSSplitView` and not a hand-built layout
//
// Weighed rather than assumed, and the deciding argument is this codebase's
// own gotcha catalogue rather than a preference for the older API.
//
// A hand-built two-pane layout means Auto Layout: a stack (or a pair of
// constraints) per split, per nesting level, rebuilt on every split and
// close. Every recurring layout defect AGENTS.md records lives in exactly
// that shape - a stack left at `.gravityAreas` with no rule for who absorbs
// the slack (gotcha 10), a hugging priority set on something with no
// intrinsic size where it is a documented no-op (gotcha 12), and above all a
// content constraint above `NSLayoutPriorityWindowSizeStayPut` silently
// becoming a floor on the whole window (gotcha 13, hit five separate times).
// A terminal is a view with a real intrinsic-ish minimum, nested arbitrarily
// deep, rebuilt at runtime - close to the worst possible candidate for a new
// hand-rolled constraint web. And dragging a divider, which every terminal
// that splits is expected to allow, would all be new code.
//
// One trap inside that choice, measured rather than read: **`NSSplitView`'s
// `arrangedSubviews` API is Auto Layout based, and its plain `subviews` API is
// the frame-based one.** Building the tree with `addArrangedSubview` gave every
// pane a `.zero` frame - the split view had installed constraints of its own
// against children that have no intrinsic size, so nothing sized them and the
// manual halving below was overwritten. The classic API (`addSubview`,
// `adjustSubviews`, `setPosition(_:ofDividerAt:)`) is what a frame-driven tree
// wants, and it is what this file uses throughout.
//
// `NSSplitView` sizes its plain subviews **by frame**. It participates in
// no constraint graph of its own, so nothing it does can propagate a width
// demand up through `content` into `bodyContainer` and cap the window - the
// gotcha-13 class is structurally unreachable here rather than merely
// avoided. Dividers, minimum sizes and drag come with it. The cost is an
// older API and frame-based children, which is why `TerminalSplitContainer`
// below is deliberately frame-based too: one `layout()` that sets one frame,
// rather than four constraints per level.
//
// Auto Layout still owns everything *outside* this file: the container itself
// is pinned into `content` with exactly the four constraints the tab's single
// terminal used to have, at the same `terminalInset`. From `content`'s point
// of view nothing about a tab changed.
//
// ## What a split pane runs, and the one decision worth revisiting
//
// **A login shell, always - even on a host page whose tab is an `ssh`
// session.** For the shared Firstmate console, where every tab is already a
// login shell, that is identical to what the tab itself runs. For an `.ssh`
// tab it is deliberately not a second connection to that host, for the same
// reason `SessionRestore` refuses to restore a host page's *duplicated* ssh
// tabs: each one is a real second connection and a real second Touch ID
// prompt. `connectSSH` is also tab-scoped by construction - the materialised
// key's temp file and the `awaitingKeyUnlock` re-entrancy guard both live on
// `TabModel`, and per-pane ssh would mean threading a pane through all of it.
// A split pane on a host page says so in one dim line when it opens, and ⌘D
// (duplicate tab) remains the way to ask for a second real session.
//
// ## What is not persisted, and why
//
// Splits live as long as the tab does. `SessionRestore` deliberately restores
// only a tab's *name*, building a fresh launch from this run's settings, and
// restoring a pane tree would mean forking N shells at launch for a layout
// the captain may not want back. A relaunch comes back to one pane per tab.

import AppKit
import SwiftTerm

/// Which way a new pane is placed relative to the one being split.
enum TerminalSplitDirection {
    case right, left, down

    /// A vertical *divider* means panes side by side - `NSSplitView.isVertical`
    /// is about the divider, not the arrangement, which is the one thing about
    /// that API worth reading twice.
    var usesVerticalDivider: Bool {
        switch self {
        case .right, .left: return true
        case .down: return false
        }
    }

    /// Whether the new pane goes before the existing one in the split view's
    /// arranged order. `NSSplitView` is flipped, so index 0 is the leading
    /// (left) or top child.
    var placesNewPaneFirst: Bool {
        switch self {
        case .left: return true
        case .right, .down: return false
        }
    }
}

/// One terminal inside a tab.
///
/// A class because it owns a live view and a running process, and because the
/// tree identifies panes by reference.
final class TerminalPane {
    let id = UUID()
    let view: TerminalPaneView
    var terminal: CockpitTerminalView { view.terminal }
    /// Whether this pane's child process has been started. The tab's own
    /// `started` covers the primary pane; a pane created while the page is
    /// off screen defers exactly like a tab does.
    var started = false
    /// Set while the pane is being torn down, so its own `processTerminated`
    /// is ignored rather than drawing a reconnect hint into a view on its way
    /// out - the same flag, for the same reason, as `TabModel.isClosing`.
    var isClosing = false
    /// The focus-tracking registration, released in `teardown()`.
    var focusRegistration: HelmFocusRegistration?

    init(view: TerminalPaneView) {
        self.view = view
    }

    func teardown() {
        isClosing = true
        if let focusRegistration {
            HelmFocusSensing.shared.unregister(focusRegistration)
            self.focusRegistration = nil
        }
        terminal.terminate()
        view.removeFromSuperview()
    }
}

/// The view for one pane: a terminal, plus the hairline that says which pane
/// the keyboard is in.
///
/// Frame-driven (`translatesAutoresizingMaskIntoConstraints` left at its
/// default `true`) because its parent is either an `NSSplitView` or
/// `TerminalSplitContainer`, both of which position by frame. The terminal
/// inside is frame-driven too, via `autoresizingMask` - mixing a constraint
/// pin into a frame-positioned parent is how a view ends up sized zero.
final class TerminalPaneView: NSView {

    /// The focused pane's hairline. Only ever drawn when a tab has more than
    /// one pane: with a single pane there is nothing to tell apart, and a
    /// border round the only terminal would read as chrome that means
    /// something.
    static let focusBorderWidth: CGFloat = 1

    let terminal: CockpitTerminalView

    private var showsFocusRing = false
    private var isFocused = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(terminal: CockpitTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = Self.focusBorderWidth
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        applyBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let inset = showsFocusRing ? Self.focusBorderWidth : 0
        terminal.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    /// `showsRing` is the tab's "more than one pane" answer; `focused` is
    /// which one has the keyboard. Kept as two inputs rather than one so a
    /// single-pane tab never draws a ring even while it is, trivially, the
    /// focused pane.
    func setFocusState(focused: Bool, showsRing: Bool) {
        guard isFocused != focused || showsFocusRing != showsRing else { return }
        isFocused = focused
        showsFocusRing = showsRing
        applyBorder()
        needsLayout = true
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        applyBorder()
    }

    private func applyBorder() {
        guard showsFocusRing else {
            layer?.borderColor = NSColor.clear.cgColor
            return
        }
        // The focused pane takes the theme's accent; an unfocused one takes
        // the same hairline every card border in this app uses, so the panes
        // read as separated either way and only one reads as live.
        let hex = isFocused ? theme.accentHex : theme.chromeLineHex
        layer?.borderColor = HelmTheme.nsColor(hex).withAlphaComponent(isFocused ? 1 : 0.6).cgColor
    }
}

/// A tab's pane tree: one view pinned into `content` where the tab's single
/// terminal used to be.
///
/// The view hierarchy **is** the model. A parallel tree would be a second
/// source of truth for something `NSSplitView` already stores perfectly well,
/// and the two would drift the first time a mutation was added to one and not
/// the other. `panes` is a flat list kept only for ordering - which pane is
/// "next" - and is maintained alongside every structural change here.
final class TerminalSplitContainer: NSView {

    /// Every pane in this tab, in the order focus cycles through them. The
    /// first is the tab's primary pane (`TabModel.terminal`), which is the
    /// one a tab has before it is ever split and the one every tab-scoped
    /// feature - SRE Lead, the kube badge, block view, the log-capture bridge
    /// - stays bound to.
    private(set) var panes: [TerminalPane] = []

    /// Which pane has the keyboard. Never `nil` once the container holds a
    /// pane; a pane going away hands it to a neighbour.
    private(set) var focusedPane: TerminalPane?

    /// Set while one pane is filling the tab. The pane is genuinely
    /// reparented onto this container for the duration, so hiding the tree is
    /// enough - see `setZoomed`.
    private(set) var zoomedPane: TerminalPane?
    /// Where a zoomed pane came from, so unzoom can put it back at the same
    /// size as well as in the same slot - the divider the captain had dragged
    /// is part of the layout they expect back.
    private var zoomOrigin: (holder: NSSplitView, index: Int, frame: CGRect)?

    /// The tree's root - a pane view, or an `NSSplitView` of them.
    private var rootView: NSView?

    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Fired whenever the pane set or the focused pane changes, so the
    /// console can refresh anything that follows it.
    var onPanesChanged: (() -> Void)?

    var paneCount: Int { panes.count }
    var isSplit: Bool { panes.count > 1 }

    override func layout() {
        super.layout()
        if let zoomed = zoomedPane {
            zoomed.view.frame = bounds
        } else {
            rootView?.frame = bounds
        }
    }

    // MARK: Building

    /// Install the tab's first pane. Called once, from `addTab`.
    func adoptPrimary(_ pane: TerminalPane) {
        precondition(panes.isEmpty, "the primary pane is installed once")
        panes = [pane]
        rootView = pane.view
        addSubview(pane.view)
        pane.view.frame = bounds
        focusedPane = pane
        refreshFocusRings()
        onPanesChanged?()
    }

    // MARK: Splitting

    /// Put `newPane` beside `target`, and focus it.
    ///
    /// The whole mutation is: find where `target` sits, take it out, put an
    /// `NSSplitView` holding both in its place. Everything else - divider,
    /// drag, minimum sizes, resizing the pair when the window resizes - is the
    /// split view's.
    @discardableResult
    func split(_ target: TerminalPane, direction: TerminalSplitDirection, newPane: TerminalPane) -> Bool {
        guard panes.contains(where: { $0 === target }) else { return false }
        unzoom()

        let splitView = makeSplitView(vertical: direction.usesVerticalDivider)
        let targetView = target.view
        let frame = targetView.frame

        // Take `target` out of wherever it is, remembering the slot so the
        // new split view lands in exactly the same place.
        if let holder = targetView.superview as? NSSplitView {
            let index = holder.subviews.firstIndex(of: targetView) ?? 0
            targetView.removeFromSuperview()
            splitView.frame = frame
            holder.insert(splitView, at: index)
            holder.adjustSubviews()
        } else {
            targetView.removeFromSuperview()
            splitView.frame = bounds
            rootView = splitView
            addSubview(splitView)
        }

        // Both children start at the split view's own size; `halve` then puts
        // the divider in the middle. Giving them a real frame first matters:
        // `adjustSubviews` works from the proportions it finds, and a `.zero`
        // child stays `.zero`.
        let ordered = direction.placesNewPaneFirst ? [newPane.view, targetView] : [targetView, newPane.view]
        for view in ordered {
            view.frame = splitView.bounds
            splitView.addSubview(view)
        }
        halve(splitView)

        // Focus order follows the screen: a pane placed left of or above its
        // target belongs before it in the cycle, not at the end of the list.
        let targetIndex = panes.firstIndex(where: { $0 === target }) ?? panes.count - 1
        panes.insert(newPane, at: direction.placesNewPaneFirst ? targetIndex : targetIndex + 1)

        focusedPane = newPane
        refreshFocusRings()
        onPanesChanged?()
        return true
    }

    private func makeSplitView(vertical: Bool) -> NSSplitView {
        let splitView = NSSplitView(frame: .zero)
        splitView.isVertical = vertical
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = true
        splitView.autoresizingMask = [.width, .height]
        return splitView
    }

    /// Give a freshly built split view's two children half the space each.
    ///
    /// Explicit rather than left to `adjustSubviews()`: that method preserves
    /// the *existing* proportions, and a child that has just been added has
    /// whatever frame it arrived with - which for a brand new pane is
    /// `.zero`, i.e. a split that renders as one full pane and one invisible
    /// one.
    private func halve(_ splitView: NSSplitView) {
        let bounds = splitView.bounds
        guard bounds.width > 0, bounds.height > 0, splitView.subviews.count == 2 else { return }
        splitView.adjustSubviews()
        let total = splitView.isVertical ? bounds.width : bounds.height
        splitView.setPosition(((total - splitView.dividerThickness) / 2).rounded(.down), ofDividerAt: 0)
    }

    // MARK: Closing

    /// The pane wrapping the tab's own `TabModel.terminal`.
    ///
    /// Set once by `ConsoleController.addTab` and never reassigned. `closePane`
    /// reads it to refuse closing it - see that method.
    weak var primaryPane: TerminalPane?

    /// Remove `pane` and give its space to its sibling. Refuses to remove the
    /// last pane - a tab always has at least one terminal, and closing the
    /// tab is ⌘W's job - **and refuses to remove the primary pane**, which is
    /// review #3's B13.
    ///
    /// The primary pane wraps `TabModel.terminal`, a `let` that ~50 consumers
    /// read as "this tab's session": the SRE Lead bridge, the kube-context
    /// badge, the block tracker, the Log Analyzer capture, the window title
    /// and `focusedTerminal(of:)`'s own fallback. Closing it ran
    /// `pane.teardown()`, which terminates that terminal's process and detaches
    /// its view - **reproduced live**: split once, click back into the original
    /// pane, press the close-pane chord, and the tab's real session went from
    /// running to terminated while the tab stayed open and every one of those
    /// consumers kept talking to the corpse. On a host page that is the SSH
    /// connection. Worse, `handleSplitPaneTermination` deliberately skips the
    /// primary, so its exit fell through to the tab's own `processTerminated`
    /// and, with "Reconnect automatically" on, re-forked the launch into the
    /// detached view.
    ///
    /// Refusing is the honest size for this feature. Promoting a survivor to
    /// primary would mean re-pointing every one of those consumers at a
    /// different terminal mid-session, which is a much larger change than the
    /// capability is worth; `ConsoleController.closeFocusedPane` turns the
    /// refusal into a one-line explanation in the pane rather than a silent
    /// no-op, so the chord never just appears to do nothing.
    @discardableResult
    func closePane(_ pane: TerminalPane) -> Bool {
        guard panes.count > 1, panes.contains(where: { $0 === pane }) else { return false }
        guard pane !== primaryPane else { return false }
        unzoom()

        let view = pane.view
        guard let holder = view.superview as? NSSplitView else { return false }
        let survivors = holder.subviews.filter { $0 !== view }
        view.removeFromSuperview()

        // A split view with one child left is no longer a split: collapse it
        // so the tree never accumulates single-child levels, which would both
        // waste divider space and make every later lookup walk further.
        if let survivor = survivors.first {
            survivor.removeFromSuperview()
            if let grandparent = holder.superview as? NSSplitView {
                let index = grandparent.subviews.firstIndex(of: holder) ?? 0
                survivor.frame = holder.frame
                holder.removeFromSuperview()
                grandparent.insert(survivor, at: index)
                grandparent.adjustSubviews()
            } else {
                holder.removeFromSuperview()
                survivor.frame = bounds
                rootView = survivor
                addSubview(survivor)
            }
        }

        let index = panes.firstIndex(where: { $0 === pane }) ?? 0
        panes.remove(at: index)
        pane.teardown()

        if focusedPane === pane {
            focusedPane = panes[min(index, panes.count - 1)]
        }
        refreshFocusRings()
        needsLayout = true
        onPanesChanged?()
        return true
    }

    /// Tear every pane down - the whole tab is going away.
    func teardownAll() {
        for pane in panes { pane.teardown() }
        panes = []
        focusedPane = nil
        zoomedPane = nil
        zoomOrigin = nil
        rootView?.removeFromSuperview()
        rootView = nil
    }

    // MARK: Focus

    func focus(_ pane: TerminalPane) {
        guard panes.contains(where: { $0 === pane }) else { return }
        focusedPane = pane
        refreshFocusRings()
        onPanesChanged?()
    }

    /// The pane `offset` steps away from the focused one, wrapping. Returns
    /// `nil` when there is nothing to move to.
    func pane(cycling offset: Int) -> TerminalPane? {
        guard panes.count > 1, let current = focusedPane,
              let index = panes.firstIndex(where: { $0 === current }) else { return nil }
        let next = (index + offset + panes.count) % panes.count
        return panes[next]
    }

    /// Adopt the pane whose subtree the keyboard is actually in.
    ///
    /// This is what makes clicking a pane focus it, without this container
    /// having to intercept mouse events that belong to the terminal.
    /// `ConsoleController` drives it from each pane's `HelmFocusSensing`
    /// registration.
    func noteFocusMoved(to pane: TerminalPane) {
        guard focusedPane !== pane, panes.contains(where: { $0 === pane }) else { return }
        focusedPane = pane
        refreshFocusRings()
        onPanesChanged?()
    }

    private func refreshFocusRings() {
        let showsRing = isSplit
        for pane in panes {
            pane.view.setFocusState(focused: pane === focusedPane, showsRing: showsRing)
        }
    }

    // MARK: Zoom

    /// Fill the tab with the focused pane, or put it back.
    @discardableResult
    func toggleZoom() -> Bool {
        if zoomedPane != nil {
            unzoom()
            return true
        }
        guard isSplit, let pane = focusedPane, let holder = pane.view.superview as? NSSplitView else { return false }
        let index = holder.subviews.firstIndex(of: pane.view) ?? 0
        zoomOrigin = (holder, index, pane.view.frame)
        pane.view.removeFromSuperview()
        rootView?.isHidden = true
        addSubview(pane.view)
        pane.view.frame = bounds
        zoomedPane = pane
        onPanesChanged?()
        return true
    }

    /// Put a zoomed pane back where it came from. A no-op when nothing is
    /// zoomed, so every mutation above can call it unconditionally.
    func unzoom() {
        guard let pane = zoomedPane, let origin = zoomOrigin else { return }
        pane.view.removeFromSuperview()
        pane.view.frame = origin.frame
        origin.holder.insert(pane.view, at: min(origin.index, origin.holder.subviews.count))
        origin.holder.adjustSubviews()
        rootView?.isHidden = false
        zoomedPane = nil
        zoomOrigin = nil
        needsLayout = true
        onPanesChanged?()
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        for pane in panes { pane.view.applyTheme(theme) }
    }

    func pane(containing terminal: TerminalView) -> TerminalPane? {
        panes.first { $0.terminal === terminal }
    }
}

private extension NSSplitView {
    /// `NSView` has no insert-at-index, and a split view's pane order is its
    /// subview order - so "before the view currently at `index`", or last.
    func insert(_ view: NSView, at index: Int) {
        if index < subviews.count {
            addSubview(view, positioned: .below, relativeTo: subviews[index])
        } else {
            addSubview(view)
        }
    }
}
