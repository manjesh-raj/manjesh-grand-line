// Manjesh Grand Line - native macOS app.
//
// F22's compact mode: the whole app as one menu-bar item, for a captain who
// never wants the window.
//
// **This adds no fourth status item - it replaces three.** Tasks
// (`ShiftMenuBar.swift`), the crew (`StrawHatMenuBar.swift`) and Poneglyph
// (`PoneglyphMenuBar.swift`) each shipped their own `NSStatusItem`, and the
// reviewed F22 mockup's own judgment note is explicit about why that is the
// wrong end state for a window-less captain: "a popover with a real
// segmented header is the shape that lets them merge without a user learning
// three separate status items". So compact mode hides all three and shows
// one, whose popover carries them as tabs - and turning it off puts the three
// back exactly as they were. Nothing is deleted and nothing is duplicated:
// the Vault and Crew tabs host the *same* content controllers those two
// status items already own, at a compact width (see
// `CompactModePopoverController`).
//
// **What compact mode does not do.** It disables nothing. The app lock, the
// dictation hotkey, Schedules, the notification scheduler and every
// background poller keep running exactly as they do with the window open -
// the window is hidden, not the app. That is the mockup's own closing line
// and it is a real constraint on this file: nothing here may gate a
// subsystem, only the window and the status items.
//
// The three decisions this mode makes - which status items exist, whether
// closing the last window quits, and which activation policy the app runs
// under - are `CompactModePolicy`, a value type with no AppKit state, so
// they are asserted by `FM_RUN_COMPACT_MODE_TESTS` in CI's *blocking* lane
// rather than only by the windowed suite.

import AppKit

// MARK: - The policy

/// The three settings, and everything that follows from them.
///
/// Pure logic on purpose. The interesting part of compact mode is not the
/// popover - it is that four separate pieces of app-level state (three status
/// items' visibility, the terminate-on-last-window answer, the activation
/// policy, and what the status item is allowed to say) all have to agree, and
/// a controller that derives each of them inline is a controller where they
/// can silently disagree. `CompactModeController` holds one of these and asks
/// it; a self-test builds one and asserts it.
struct CompactModePolicy: Equatable {
    /// Settings > Compact mode's master switch (`AppSettings.compactModeEnabled`).
    let isEnabled: Bool
    /// Whether the Dock icon goes away with the window.
    let hidesDockIcon: Bool
    /// Whether the status item carries the overdue count as a title.
    let badgesOverdueCount: Bool

    init(isEnabled: Bool, hidesDockIcon: Bool, badgesOverdueCount: Bool) {
        self.isEnabled = isEnabled
        self.hidesDockIcon = hidesDockIcon
        self.badgesOverdueCount = badgesOverdueCount
    }

    /// Read straight off the shared settings - the one place the three keys
    /// are turned into a policy, so no call site assembles a partial one.
    static func current(_ settings: AppSettings = .shared) -> CompactModePolicy {
        CompactModePolicy(isEnabled: settings.compactModeEnabled,
                          hidesDockIcon: settings.compactModeHidesDockIcon,
                          badgesOverdueCount: settings.compactModeBadgesOverdueCount)
    }

    /// Whether the one merged "Grand Line" status item is in the menu bar.
    var showsCompactStatusItem: Bool { isEnabled }

    /// Whether Tasks', the crew's and Poneglyph's own three status items are.
    ///
    /// The exact inverse of the above rather than an independent setting:
    /// three items plus a fourth that contains all three is the state the
    /// mockup's judgment note rules out, and making it unreachable here is
    /// cheaper than making it unreachable in Settings.
    var showsPerFeatureStatusItems: Bool { !isEnabled }

    /// `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`.
    ///
    /// The whole mode rests on this: compact mode hides the main window, and
    /// with the stock `true` answer hiding it would quit the app. Note it is
    /// keyed on `isEnabled` alone - a captain who enabled compact mode and
    /// left the Dock icon on still has a running app with no window, which is
    /// the normal state of this mode.
    var terminatesAfterLastWindowClosed: Bool { !isEnabled }

    /// `.accessory` is `LSUIElement` at runtime: no Dock icon, no app menu,
    /// status item only.
    ///
    /// Only reachable with *both* switches on, and it returns to `.regular`
    /// the moment compact mode is turned off - so "hide the Dock icon" can
    /// never outlive the mode that justified it and leave a captain with a
    /// window they cannot get back to from the Dock.
    var activationPolicy: NSApplication.ActivationPolicy {
        isEnabled && hidesDockIcon ? .accessory : .regular
    }

    /// What the status item shows beside its glyph.
    ///
    /// GL-09 first: locked means no title at all. `ShiftMenuBarController`'s
    /// own `refreshCounts()` records why - "3 things due today" is
    /// information about the captain's day, readable by anyone at the
    /// machine - and this item is no less readable than that one.
    ///
    /// Then the mockup's own default: off. Its note is the reasoning and it
    /// is worth keeping as code rather than as a comment in a settings pane -
    /// "a permanent red number is a bad neighbour in a menu bar" - so the
    /// badge is opt-in and, even when opted in, an overdue count of zero
    /// renders nothing rather than a " 0".
    func statusItemTitle(overdueCount: Int, contentAllowed: Bool) -> String {
        guard contentAllowed, badgesOverdueCount, overdueCount > 0 else { return "" }
        return " \(overdueCount)"
    }
}

// MARK: - The hotkey

/// ⌃⌥G - the mockup's own footer chord, which toggles the compact popover
/// from anywhere.
///
/// Shaped on `ShiftGlobalHotkey` (`ShiftQuickCapture.swift`) rather than
/// re-derived: same local + global monitor pair, same honesty about the
/// global half needing Accessibility trust, same `start()`/`stop()`. Two
/// deliberate differences:
///
///   * It is installed **only while compact mode is on**. A chord for
///     "open the menu-bar popover" is meaningless when there is no menu-bar
///     popover, and a monitor nothing can reach is exactly the kind of thing
///     `AppSettings.snippetExpansionEnabled`'s own note refuses to leave
///     installed and ignored.
///   * It asks for no permission of its own. ⌥Space and the snippet expander
///     both prompt, because each *is* the feature; this one is a convenience
///     on top of a status item that is always clickable, so an ungranted
///     Accessibility permission costs a captain the chord and nothing else.
///     The local monitor still works whenever this app is frontmost.
final class CompactModeHotkey {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let handler: () -> Void

    /// `kVK_ANSI_G`. The same "a Carbon keycode literal, without linking
    /// Carbon" note `ShiftGlobalHotkey.spaceKeyCode` carries.
    static let gKeyCode: UInt16 = 5

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    var isInstalled: Bool { localMonitor != nil || globalMonitor != nil }

    func start() {
        guard !isInstalled else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.matches(event) {
                self?.handler()
                return nil
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.matches(event) { self?.handler() }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    /// Exposed rather than private so the suite asserts the real chord the
    /// footer advertises, instead of a second copy of this predicate.
    static func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == gKeyCode else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option]
    }
}

// MARK: - The controller

/// The merged status item, its popover, and the app-level effects of turning
/// the mode on and off.
///
/// **It owns no store**, for exactly the reason
/// `PoneglyphMenuBarController`'s header gives: `ShiftStore`,
/// `StickyBoardStore` and `CredentialVaultStore` all cache, GL-23 says a
/// caching store gets one instance, and the instances that exist belong to
/// `AppDelegate` and `AppShellController`. Every number this item shows and
/// every write it makes arrives through a closure `AppDelegate` wires, which
/// is the forward-don't-own convention every out-of-window surface in this
/// app already follows.
final class CompactModeController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let content: CompactModePopoverController
    private var themeObservation: ThemeObservation?
    private lazy var hotkey = CompactModeHotkey { [weak self] in self?.togglePopover() }

    /// The live policy. Re-read from `AppSettings` on every `refresh()`
    /// rather than cached at init, so Settings' three toggles take effect on
    /// the click rather than on the next launch.
    private(set) var policy: CompactModePolicy = .current()

    /// How many of the captain's tasks are overdue, for the opt-in badge.
    var overdueCountProvider: (() -> Int)?
    /// Raise the real window and leave compact mode's window-hidden state -
    /// the popover's "Open full window" and the ⌘↩ it maps to.
    var onOpenFullWindow: (() -> Void)?
    /// Hide the main window, which is what entering the mode actually does.
    var onHideMainWindow: (() -> Void)?
    /// The gear in the popover's header: the full window, on Settings.
    var onOpenSettings: (() -> Void)?

    /// The three surfaces whose own status items this mode merges. Supplied
    /// as a closure per item rather than as three references, so this file
    /// has no opinion about which controllers exist or in what order
    /// `AppDelegate` builds them.
    var perFeatureStatusItemVisibility: ((Bool) -> Void)?

    init(content: CompactModePopoverController) {
        self.content = content
        super.init()

        // Audit 2 §2.7/§6.2, and the same registration all three of the
        // status items this replaces make: a popover is its own window,
        // layered *above* the lock overlay, so it is closed on the way into
        // the lock rather than merely refused on the next open.
        AppLockGate.shared.registerLockDismissiblePopover { [weak self] in self?.popover }

        if let button = statusItem.button {
            // The app's own mark, for the same reason
            // `ShiftMenuBarController` was changed to use it: a standalone
            // menu bar item has no nearby branding to tie it back to Manjesh
            // Grand Line. This one has a better claim to it than that one
            // ever did - in compact mode it *is* the app.
            button.image = Self.statusItemIcon()
            button.imagePosition = .imageLeading
            button.toolTip = "Manjesh Grand Line"
            button.target = self
            button.action = #selector(iconClicked)
        }

        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        // Set up front as well as on every report, so the very first frame
        // AppKit lays out is already the card's real size rather than a
        // default it then corrects.
        popover.contentSize = CompactModePopoverController.contentSize
        content.onSizeChanged = { [weak self] size in self?.popover.contentSize = size }
        content.onOpenFullWindow = { [weak self] in
            self?.popover.performClose(nil)
            self?.onOpenFullWindow?()
        }
        content.onOpenSettings = { [weak self] in
            self?.popover.performClose(nil)
            self?.onOpenSettings?()
        }
        content.onDismiss = { [weak self] in self?.popover.performClose(nil) }

        // GL-09: this item lives outside the locked window entirely. Close
        // the popover and drop the badge on every lock transition, rather
        // than only on the next open - locking while a count is visible has
        // to clear it immediately.
        AppLockGate.shared.observe { [weak self] _ in
            self?.popover.performClose(nil)
            self?.refreshStatusItemTitle()
        }

        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.applyTheme(theme)
        }

        // Nothing is shown until `refresh()` decides it should be. A fresh
        // install has compact mode off, so this status item is built and
        // immediately hidden, which costs one `NSStatusItem` - the honest
        // alternative (build it lazily on first enable) would mean the mode
        // could not be turned on from a settings pane without the app
        // delegate reaching back in, and `NSStatusItem.isVisible` is exactly
        // the API for this.
        statusItem.isVisible = false
    }

    // MARK: Mode transitions

    /// Re-read the settings and make the world match them.
    ///
    /// Idempotent, and safe to call from anywhere: Settings calls it on each
    /// of its three toggles, `AppDelegate` calls it once at launch, and the
    /// popover's own "Open full window" calls it after writing the setting
    /// back. Everything that follows from the three switches happens here and
    /// nowhere else, so there is one path to read when a transition
    /// misbehaves.
    func refresh() {
        let previous = policy
        policy = .current()

        statusItem.isVisible = policy.showsCompactStatusItem
        perFeatureStatusItemVisibility?(policy.showsPerFeatureStatusItems)
        refreshStatusItemTitle()

        // The activation policy is set unconditionally rather than only on a
        // change: `NSApplication.setActivationPolicy` is idempotent, and the
        // launch call has to establish it from whatever the process started
        // with rather than from a remembered previous value.
        NSApp?.setActivationPolicy(policy.activationPolicy)

        if policy.isEnabled {
            hotkey.start()
            // Only on the *transition* in. Calling this on every refresh
            // would mean flipping the badge toggle re-hid a window the
            // captain had deliberately brought back with "Open full window"
            // (which leaves the mode on).
            if !previous.isEnabled {
                popover.performClose(nil)
                onHideMainWindow?()
            }
        } else {
            hotkey.stop()
            popover.performClose(nil)
        }

        // Assembled before the log call rather than interpolated into it:
        // `os.Logger`'s interpolation is an autoclosure, so reading a property
        // inside it needs an explicit `self` that says nothing useful here.
        let summary = "enabled=\(policy.isEnabled), dock icon "
            + (policy.activationPolicy == .accessory ? "hidden" : "shown")
        AppLog.lifecycle.info("compact mode refreshed - \(summary, privacy: .public)")
    }

    /// Re-derive only the status item's badge.
    ///
    /// GL-24's shape, and the reason this is not `refresh()`: a task completed
    /// anywhere in the app moves this number, and `ShiftStore.observe` fires
    /// on every mutation - so the store observer must not be re-applying the
    /// activation policy, re-deciding three status items' visibility and
    /// logging a line every time a checkbox is ticked. An observer repaints;
    /// it does not re-run a transition.
    func refreshBadge() {
        refreshStatusItemTitle()
    }

    /// The popover's footer button and ⌃⌥G's escape hatch: leave compact
    /// mode and come back to the window.
    ///
    /// Writes the setting rather than only raising the window, because a mode
    /// you can leave but which is still on next launch is not a mode anyone
    /// can get out of. The window-raising half is `onOpenFullWindow`, which
    /// `AppDelegate` wires - this only has to make sure the activation policy
    /// is back to `.regular` *before* the window is ordered front, which is
    /// what `refresh()` does.
    func exitCompactMode() {
        AppSettings.shared.compactModeEnabled = false
        refresh()
    }

    // MARK: The popover

    @objc private func iconClicked() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // GL-09, and refused outright rather than opened empty - the same
        // posture both the crew's and Poneglyph's items take, for the same
        // reason: an empty popover invites a second click, and every one of
        // these four tabs would be showing the captain's own data.
        guard AppLockGate.shared.allows(.compactModePopover) else {
            AppLog.lifecycle.info("compact-mode popover refused - app is locked (GL-09)")
            NSSound.beep()
            return
        }
        prepareToShow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// ⌃⌥G. Toggles rather than opens, matching what the footer advertises.
    private func togglePopover() {
        guard policy.isEnabled else { return }
        // The hotkey can fire while another app is frontmost, so the popover
        // needs this app active to be usable at all - a `.transient` popover
        // over an inactive app closes on the first click into it.
        if !popover.isShown { NSApp?.activate(ignoringOtherApps: true) }
        iconClicked()
    }

    /// Everything an open does before the popover is on screen. Split out for
    /// the reason all three of its siblings split it: a suite can drive the
    /// real open path without a live `statusItem.button`, which a headless
    /// process may not have.
    private func prepareToShow() {
        refreshStatusItemTitle()
        applyTheme(ThemeManager.shared.theme)
        content.prepareToShow()
    }

    func popoverDidClose(_ notification: Notification) {
        content.popoverDidClose()
    }

    private func applyTheme(_ theme: HelmTheme) {
        // `ThemeManager.swift`'s checklist item 2, applied to a popover -
        // without it every system-semantic colour in this content resolves
        // against the OS's light/dark setting rather than the active Helm
        // theme. Set on open as well as on change, because an `NSPopover`
        // reads its appearance when it is shown.
        popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        content.applyTheme(theme)
    }

    private func refreshStatusItemTitle() {
        let allowed = AppLockGate.shared.allows(.menuBarContent)
        let overdue = allowed ? (overdueCountProvider?() ?? 0) : 0
        statusItem.button?.title = policy.statusItemTitle(overdueCount: overdue, contentAllowed: allowed)
        statusItem.button?.toolTip = allowed
            ? "Manjesh Grand Line"
            : "Manjesh Grand Line is locked"
    }

    /// A monochrome template glyph at menu-bar size - never the destination's
    /// gradient tile, per `PoneglyphMenuBarController.statusItemIcon()`'s own
    /// note about a coloured tile reading as a foreign object in the menu bar.
    private static func statusItemIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Manjesh Grand Line")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        image?.isTemplate = true
        return image
    }

    #if FM_SELFTESTS
    var debugPopover: NSPopover { popover }
    var debugContent: CompactModePopoverController { content }
    var debugStatusItemIsVisible: Bool { statusItem.isVisible }
    var debugStatusItemTitle: String { statusItem.button?.title ?? "" }
    /// Whether this process actually got a status-bar button.
    ///
    /// A headless self-test process never calls `NSApp.run()`, so a real
    /// `NSStatusItem`'s button cannot be relied on to exist - the same
    /// finding `PoneglyphMenuBarController.debugHasStatusButton` records.
    /// A suite asserting a badge has to skip *loudly* when there is no
    /// button, or it silently passes.
    var debugHasStatusButton: Bool { statusItem.button != nil }
    var debugHotkeyIsInstalled: Bool { hotkey.isInstalled }
    func debugPrepareToShow() { prepareToShow() }
    func debugRefreshStatusItemTitle() { refreshStatusItemTitle() }
    #endif
}
