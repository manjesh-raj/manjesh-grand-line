// Grand Line - native macOS app.
//
// The Shift menu bar item (phase 5, cockpit-shift-power-features): a status
// bar icon showing today's task count, with a popover and a quick-add field
// that creates a real task via `ShiftStore.addTask` - the same store every
// other Shift entry point writes through, not a separate write path.
//
// The popover is the Tasks popover in the Bridge shape the captain approved
// (`TasksBridgeView.swift`): Today with the date, the done-today count and
// the streak, a Now card with Check off, Start focus and Open, Up next with
// the follow-ups in time order, a backlog to claim from, and a footer whose
// main action is Open Tasks. It is the same pane the compact popover's Today
// tab shows. It used to be two stat rows ("Tasks today: 3", "Next follow-up")
// and the quick-add field; the count still sits in the menu bar, the next
// follow-up is an Up next row with its time, and the quick-add field stays.
//
// Kept independent of the main window's `ShiftController` (which only exists
// once the window is built) so the menu bar item and its counts are correct
// even before the captain has ever opened the main window's Shift page.

import AppKit

final class ShiftMenuBarController: NSObject, NSPopoverDelegate {
    private let store: ShiftStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let contentController = ShiftMenuBarPopoverController()

    /// Start the focus timer on a task. Wired by `AppDelegate` to the
    /// window's one `FocusTimerController`; nil hides the Now card's button.
    var onStartFocus: ((ShiftTask) -> Void)? {
        didSet { contentController.showsStartFocus = onStartFocus != nil }
    }
    /// Raise the window on Tasks, on one task, on one follow-up, or on
    /// Settings › Menu Bar. Every one of them closes the popover first.
    var onOpenTasks: (() -> Void)?
    var onOpenTask: ((String) -> Void)?
    var onOpenFollowUp: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?

    init(store: ShiftStore) {
        self.store = store
        super.init()
        // Audit 2 §2.7/§6.2: closed on the way into the lock like every
        // other popover in the app - a popover is its own window, layered
        // above the lock overlay. Weak, because there is no unregister.
        AppLockGate.shared.registerLockDismissiblePopover(owner: self) { [weak self] in self?.popover }

        if let button = statusItem.button {
            // fm/grandline-rail-followup-fixes: this used to be
            // "arrow.triangle.2.circlepath" (a refresh/sync glyph, unrelated
            // to what this status item actually does) - a captain screenshot
            // asked for the app's own "sailboat" mark instead (the same
            // symbol as the rail's logo, `IconRailController.loadView`'s
            // `mark.image`), since a standalone menu bar item has no nearby
            // app branding of its own to tie it back to Grand Line.
            button.image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Tasks")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            button.imagePosition = .imageLeading
            button.toolTip = "Tasks"
            button.target = self
            button.action = #selector(iconClicked)
        }

        // **UX issue X2.** Starts hidden, and `CompactModeController.refresh()`
        // is the single place that decides whether it appears - the same
        // shape that controller's own item already used. Before X2 the
        // merged item was the exception and these three were visible from
        // construction; now that the merge is the default, an item that
        // showed itself at launch and was hidden a few lines later would
        // flash on every ordinary start.
        statusItem.isVisible = false

        popover.contentViewController = contentController
        popover.behavior = .transient
        popover.delegate = self
        contentController.onQuickAdd = { [weak self] title in
            self?.createQuickTask(title: title)
        }
        wirePane()

        store.observe { [weak self] in self?.refreshCounts() }

        // GL-09: this status item lives outside the locked window entirely, so
        // before this it kept showing the due count, kept opening a popover
        // that discloses the next follow-up's title, and its quick-add kept
        // writing tasks *and pushing them to GitHub* while the app was locked.
        // Re-derive on every lock transition rather than only on a store
        // change, so locking while the count is visible clears it immediately.
        AppLockGate.shared.observe { [weak self] _ in
            self?.popover.performClose(nil)
            self?.refreshCounts()
        }

        // A theme change while the popover is already open has to reach it
        // too: `prepareToShow()` sets the appearance, and an already-shown
        // popover never goes back through there. In practice this popover is
        // `.transient` and the theme control lives in the main window (so
        // reaching it dismisses this), which is exactly why the open-time
        // set is the load-bearing half - but "in practice it cannot happen"
        // is how the original omission was justified, so this closes it
        // rather than reasoning about it.
        //
        // `ThemeManager.observe` fires synchronously at registration, which
        // is safe here: `popover` and `contentController` are both stored
        // `let`s initialised inline, so they exist by the time `init` runs a
        // single line of its own body.
        ThemeManager.shared.observe { [weak self] theme in
            self?.applyTheme(theme)
        }
        refreshCounts()
    }

    /// F22: compact mode merges Tasks into one status item whose popover
    /// carries it as a tab, so the mode hides this one rather than leaving
    /// two doors to the same surface - see
    /// `CompactModePolicy.showsPerFeatureStatusItems`, which is the only
    /// thing that decides this and is asserted in CI's blocking lane.
    ///
    /// Hidden, never torn down: `NSStatusItem.isVisible` is exactly this
    /// API, the item keeps its store observation and its lock observer while
    /// hidden, and turning compact mode off puts it back with its count
    /// already current. An open popover is closed on the way out, because a
    /// popover whose anchor just left the menu bar has nothing to sit under.
    func setStatusItemVisible(_ visible: Bool) {
        statusItem.isVisible = visible
        if !visible { popover.performClose(nil) }
    }

    @objc private func iconClicked() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // GL-09: locked means the popover does not open at all. Not "opens
        // empty" - an empty popover invites a second click, and there is
        // nothing here worth showing behind a lock.
        guard AppLockGate.shared.allows(.menuBarPopover) else {
            AppLog.lifecycle.info("menu-bar popover refused - app is locked (GL-09)")
            NSSound.beep()
            return
        }
        prepareToShow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Everything an open does before the popover is actually put on screen.
    /// Split out of `iconClicked` so a self-test can drive the real path
    /// without needing a live `statusItem.button` (which a headless process
    /// may not have) and without actually showing a popover.
    private func prepareToShow() {
        refreshCounts()
        contentController.focusQuickAdd()
        // `ThemeManager.swift`'s checklist item 2, applied to a popover.
        //
        // This was the ONE popover in the app that never forced its own
        // appearance - the avatar popover (`DaylightBarController`), the
        // notification centre, Claude usage, the Console composer, Recents
        // and the Whiteboard composer have all done it for years. Without it
        // every system-semantic colour in this content (`.labelColor` on the
        // header and both stat rows, the field editor AppKit lends the
        // quick-add field, the focus ring) resolves against the *OS's* own
        // light/dark setting rather than the in-app theme - so on a Mac in
        // system Dark with a light Helm theme selected this popover rendered
        // near-white text on AppKit's own light vibrant material, and vice
        // versa. Set on every open rather than once, because the theme can
        // change between two opens and an `NSPopover` reads its appearance
        // when it is shown.
        applyTheme(ThemeManager.shared.theme)
    }

    /// The one place this popover's appearance and its theme-derived colours
    /// are set, called both on open and on a live theme change.
    private func applyTheme(_ theme: HelmTheme) {
        popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        contentController.applyTheme(theme)
    }

    /// Every inline action on the pane. Each write takes the same lock check
    /// `createQuickTask` does (GL-09: the popover cannot be open while locked,
    /// but these are the writes), and each is a store method the Tasks page
    /// already uses: Claim is the existing In progress status.
    private func wirePane() {
        contentController.onCheckOffTask = { [weak self] id in
            guard AppLockGate.shared.allows(.menuBarPopover) else { return }
            self?.store.setTaskCompleted(id: id, completed: true)
        }
        contentController.onClaimTask = { [weak self] id in
            guard AppLockGate.shared.allows(.menuBarPopover) else { return }
            self?.store.claimTask(id: id)
        }
        contentController.onCompleteFollowUp = { [weak self] id in
            guard AppLockGate.shared.allows(.menuBarPopover) else { return }
            self?.store.setFollowUpStatus(id: id, done: true)
        }
        contentController.onStartFocus = { [weak self] id in
            guard AppLockGate.shared.allows(.menuBarPopover), let self,
                  let task = self.store.activeTasks.first(where: { $0.id == id }) else { return }
            self.onStartFocus?(task)
        }
        contentController.onOpenTask = { [weak self] id in
            self?.closeThen { self?.onOpenTask?(id) }
        }
        contentController.onOpenFollowUp = { [weak self] id in
            self?.closeThen { self?.onOpenFollowUp?(id) }
        }
        contentController.onOpenTasks = { [weak self] in
            self?.closeThen { self?.onOpenTasks?() }
        }
        contentController.onOpenSettings = { [weak self] in
            self?.closeThen { self?.onOpenSettings?() }
        }
        contentController.onTogglePin = { [weak self] pinned in self?.setPinned(pinned) }
        contentController.onSizeChanged = { [weak self] size in self?.popover.contentSize = size }
    }

    /// Navigating to the window is the end of the popover's job, pinned or not.
    private func closeThen(_ action: () -> Void) {
        popover.performClose(nil)
        action()
    }

    /// The header's pin: a pinned popover stays open when the captain clicks
    /// into another app, the way Tootask's does. `.applicationDefined` is
    /// AppKit's own "only closes when told to" behaviour, and the icon, the
    /// lock (`registerLockDismissiblePopover`) and every navigating action
    /// still close it. Not persisted: a pin is about this
    /// sitting, and a popover that reopened pinned after a relaunch would
    /// surprise.
    private func setPinned(_ pinned: Bool) {
        popover.behavior = pinned ? .applicationDefined : .transient
    }

    #if FM_SELFTESTS
    var debugPopover: NSPopover { popover }
    func debugPrepareToShow() { prepareToShow() }
    var debugContent: ShiftMenuBarPopoverController { contentController }
    func debugRefresh() { refreshCounts() }
    #endif

    private func createQuickTask(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Belt and braces: the popover cannot be open while locked, but this is
        // the write, and a write is the thing that must not happen.
        guard AppLockGate.shared.allows(.menuBarPopover) else {
            popover.performClose(nil)
            return
        }
        var task = ShiftTask.fresh()
        // Reuse the same natural-language date detection the New Task sheet's
        // title field already offers (cockpit-shift-create-edit), so "tomorrow
        // 3pm renew the cert" typed straight into the menu bar behaves the
        // same as typing it into the full editor.
        if let parsed = ShiftDateParser.parse(trimmed) {
            let (dateStr, timeStr) = ShiftDateFormatting.components(from: parsed.date)
            task.dueDate = dateStr
            task.dueTime = parsed.hasTime ? timeStr : nil
        }
        task.title = trimmed
        store.addTask(task)
        popover.performClose(nil)
    }

    private func refreshCounts() {
        // Locked: the title shows the app's own mark and nothing else. The
        // count is a real disclosure - "3 things due today" is information
        // about the captain's day, readable by anyone at the machine.
        guard AppLockGate.shared.allows(.menuBarContent) else {
            statusItem.button?.title = ""
            statusItem.button?.toolTip = "Tasks - Grand Line is locked"
            contentController.present(.empty)
            return
        }
        statusItem.button?.toolTip = "Tasks"
        let cal = Calendar.current
        let today = Date()
        let dueTodayCount = store.activeTasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return cal.isDate(due, inSameDayAs: today)
        }.count

        statusItem.button?.title = " \(dueTodayCount)"
        contentController.present(TasksBridge.digest(tasks: store.activeTasks,
                                                     completed: store.allCompletedTasks(),
                                                     followUps: store.followUps,
                                                     projects: store.projects,
                                                     focusSecondsToday: store.focusSecondsToday(reference: today),
                                                     now: today))
    }
}

/// The popover's content: the Bridge-shaped `TasksBridgePane` in a scroll
/// view, the quick-add field, and the footer with Open Tasks and Settings.
///
/// `ShiftMenuBarController.prepareToShow()` forces the popover's appearance
/// to the active theme on every open, and this view forces its own as well
/// (`ThemeManager.swift`'s checklist item 2), so the field editor, the focus
/// ring and every system-semantic colour follow the Helm theme rather than
/// the OS.
///
/// The pane scrolls inside a capped height rather than growing the popover
/// past `maxBodyHeight`: a captain with a long backlog gets a scroller, not a
/// popover that runs off the bottom of the screen.
final class ShiftMenuBarPopoverController: NSViewController {
    static let width: CGFloat = CompactModePopoverController.width
    /// Tall enough for the header, the Now card, the five Up next rows and
    /// the backlog at the default text size, measured in the tour lab.
    static let maxBodyHeight: CGFloat = 560

    var onQuickAdd: ((String) -> Void)?
    var onCheckOffTask: ((String) -> Void)?
    var onClaimTask: ((String) -> Void)?
    var onCompleteFollowUp: ((String) -> Void)?
    var onStartFocus: ((String) -> Void)?
    var onOpenTask: ((String) -> Void)?
    var onOpenFollowUp: ((String) -> Void)?
    var onOpenTasks: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onTogglePin: ((Bool) -> Void)?
    /// Forwarded to `popover.contentSize` after every render.
    var onSizeChanged: ((NSSize) -> Void)?
    var showsStartFocus = false {
        didSet {
            pane.onStartFocus = showsStartFocus ? { [weak self] id in self?.onStartFocus?(id) } : nil
        }
    }

    private let pane = TasksBridgePane(showsPin: true)
    private let scroll = NSScrollView()
    private let quickAddField = HelmTextField(placeholder: "Quick add a task, press \u{23CE}\u{2026}")
    private let footer = TasksBridgeFooter(showsSettings: true)
    private let divider = NSView()
    private var scrollHeight: NSLayoutConstraint?
    private var theme: HelmTheme = ThemeManager.shared.theme

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        root.wantsLayer = true
        view = root

        pane.onCheckOffTask = { [weak self] id in self?.onCheckOffTask?(id) }
        pane.onClaimTask = { [weak self] id in self?.onClaimTask?(id) }
        pane.onCompleteFollowUp = { [weak self] id in self?.onCompleteFollowUp?(id) }
        pane.onOpenTask = { [weak self] id in self?.onOpenTask?(id) }
        pane.onOpenFollowUp = { [weak self] id in self?.onOpenFollowUp?(id) }
        pane.header.onTogglePin = { [weak self] pinned in self?.onTogglePin?(pinned) }
        footer.onOpenTasks = { [weak self] in self?.onOpenTasks?() }
        footer.onOpenSettings = { [weak self] in self?.onOpenSettings?() }

        // Flipped and pinned to the clip view: gotchas (9) and (4).
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(pane)
        scroll.documentView = document

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        quickAddField.target = self
        quickAddField.action = #selector(quickAddSubmitted)
        quickAddField.translatesAutoresizingMaskIntoConstraints = false

        for v in [scroll, divider, quickAddField, footer] as [NSView] { root.addSubview(v) }
        let scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 200)
        self.scrollHeight = scrollHeight
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            pane.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            pane.topAnchor.constraint(equalTo: document.topAnchor),
            pane.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s1),
            scrollHeight,
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: HelmMetrics.s1),
            divider.heightAnchor.constraint(equalToConstant: 1),
            quickAddField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s3),
            quickAddField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s3),
            quickAddField.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: HelmMetrics.s2),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s3),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s3),
            footer.topAnchor.constraint(equalTo: quickAddField.bottomAnchor, constant: HelmMetrics.s2),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s3),
        ])
        applyTheme(theme)
    }

    /// This controller has no `ThemeManager` observation of its own - the menu
    /// bar item owns one and calls this, so there is a single place the
    /// popover's appearance and its content's colours move together.
    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        _ = view
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(HelmCard.dividerAlpha).cgColor
        pane.applyTheme(theme)
    }

    /// GL-P3: this popover re-renders on every open and on every store change.
    func present(_ digest: TasksBridgeDigest) {
        _ = view
        pane.present(digest, theme: theme)
        // The scroll region takes the pane's natural height up to the cap,
        // so a short day is a short popover and a long one scrolls.
        view.layoutSubtreeIfNeeded()
        let natural = pane.fittingSize.height
        scrollHeight?.constant = min(natural, Self.maxBodyHeight)
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(NSSize(width: Self.width, height: view.fittingSize.height))
    }

    func focusQuickAdd() {
        quickAddField.stringValue = ""
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.quickAddField)
        }
    }

    @objc private func quickAddSubmitted() {
        let text = quickAddField.stringValue
        quickAddField.stringValue = ""
        onQuickAdd?(text)
    }

    #if FM_SELFTESTS
    var debugPane: TasksBridgePane { pane }
    var debugFooter: TasksBridgeFooter { footer }
    var debugScroll: NSScrollView { scroll }
    var debugQuickAddField: HelmTextField { quickAddField }
    func debugSubmitQuickAdd(_ text: String) {
        quickAddField.stringValue = text
        quickAddSubmitted()
    }
    #endif
}
