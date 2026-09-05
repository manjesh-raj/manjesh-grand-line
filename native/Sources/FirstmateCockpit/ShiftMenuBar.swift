// Manjesh Grand Line - native macOS app.
//
// The Shift menu bar item (phase 5, cockpit-shift-power-features): a status
// bar icon showing today's task count, with a popover (mockup's
// `.mb-popover`) listing today's task count, the next follow-up, and a
// quick-add field that creates a real task via `ShiftStore.addTask` - the
// same store every other Shift entry point writes through, not a separate
// write path.
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

    init(store: ShiftStore) {
        self.store = store
        super.init()

        if let button = statusItem.button {
            // fm/grandline-rail-followup-fixes: this used to be
            // "arrow.triangle.2.circlepath" (a refresh/sync glyph, unrelated
            // to what this status item actually does) - a captain screenshot
            // asked for the app's own "sailboat" mark instead (the same
            // symbol as the rail's logo, `IconRailController.loadView`'s
            // `mark.image`), since a standalone menu bar item has no nearby
            // app branding of its own to tie it back to Manjesh Grand Line.
            button.image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Tasks")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            button.imagePosition = .imageLeading
            button.toolTip = "Tasks"
            button.target = self
            button.action = #selector(iconClicked)
        }

        popover.contentViewController = contentController
        popover.behavior = .transient
        popover.delegate = self
        contentController.onQuickAdd = { [weak self] title in
            self?.createQuickTask(title: title)
        }

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

    #if FM_SELFTESTS
    var debugPopover: NSPopover { popover }
    func debugPrepareToShow() { prepareToShow() }
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
            statusItem.button?.toolTip = "Tasks - Manjesh Grand Line is locked"
            contentController.update(tasksToday: 0, nextFollowUp: nil, nextFollowUpDate: nil)
            return
        }
        statusItem.button?.toolTip = "Tasks"
        let cal = Calendar.current
        let today = Date()
        let dueTodayCount = store.activeTasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return cal.isDate(due, inSameDayAs: today)
        }.count

        let nextFollowUp = store.followUps
            .filter { $0.status == .pending }
            .compactMap { fu -> (ShiftFollowUp, Date)? in
                guard let date = ShiftDateFormatting.dateTime(from: fu.followUpAt, time: fu.followUpTime) else { return nil }
                return (fu, date)
            }
            .sorted { $0.1 < $1.1 }
            .first

        statusItem.button?.title = " \(dueTodayCount)"
        contentController.update(tasksToday: dueTodayCount, nextFollowUp: nextFollowUp?.0, nextFollowUpDate: nextFollowUp?.1)
    }
}

/// The popover's content: two stat rows + the next follow-up's title + a
/// quick-add field - built as a plain `NSViewController` rather than a shared
/// destination controller, since a popover already gets its own vibrant
/// background from AppKit and needs no `NSVisualEffectView` of its own.
///
/// That is where this file's own reasoning used to stop, and it was the bug:
/// AppKit supplying the *material* says nothing about which side of
/// light/dark it resolves against. The labels below are deliberately plain
/// `.labelColor` system-semantic text, so they are correct only once the
/// popover's appearance is forced to the active theme's mode - which
/// `ShiftMenuBarController.prepareToShow()` now does on every open.
private final class ShiftMenuBarPopoverController: NSViewController {
    private let headerLabel = NSTextField(labelWithString: "Tasks")
    private let tasksRow = ShiftMenuBarStatRow(label: "Tasks today")
    private let followUpRow = ShiftMenuBarStatRow(label: "Next follow-up")
    private let nextFollowUpTitle = NSTextField(labelWithString: "")
    private let quickAddField = HelmTextField(placeholder: "Quick add a task, press \u{23CE}\u{2026}")
    var onQuickAdd: ((String) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 140))
        view = root

        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        nextFollowUpTitle.font = .systemFont(ofSize: 11)
        // Re-derived from the active theme on every popover refresh (see
        // `update(tasksToday:nextFollowUp:nextFollowUpDate:)`), not a fixed
        // system grey - audit §5.3.
        nextFollowUpTitle.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        nextFollowUpTitle.lineBreakMode = .byTruncatingTail
        nextFollowUpTitle.maximumNumberOfLines = 2

        let divider = NSBox()
        divider.boxType = .separator

        quickAddField.target = self
        quickAddField.action = #selector(quickAddSubmitted)

        let stack = NSStackView(views: [
            headerLabel, tasksRow, followUpRow, nextFollowUpTitle, divider, quickAddField,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            tasksRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            followUpRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quickAddField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    /// This controller has no `ThemeManager` observation of its own - the menu
    /// bar item owns one and calls this, so there is a single place the
    /// popover's appearance and its content's colours move together.
    func applyTheme(_ theme: HelmTheme) {
        nextFollowUpTitle.textColor = HelmTheme.mutedInk(theme)
    }

    func update(tasksToday: Int, nextFollowUp: ShiftFollowUp?, nextFollowUpDate: Date?) {
        applyTheme(ThemeManager.shared.theme)
        tasksRow.setValue("\(tasksToday)")
        if let nextFollowUp, let nextFollowUpDate {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("jm")
            followUpRow.setValue(f.string(from: nextFollowUpDate))
            nextFollowUpTitle.stringValue = nextFollowUp.title
            nextFollowUpTitle.isHidden = false
        } else {
            followUpRow.setValue("\u{2014}")
            nextFollowUpTitle.isHidden = true
        }
    }

    func focusQuickAdd() {
        quickAddField.stringValue = ""
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.quickAddField)
        }
    }

    @objc private func quickAddSubmitted() {
        let text = quickAddField.stringValue
        quickAddField.stringValue = ""
        onQuickAdd?(text)
    }
}

private final class ShiftMenuBarStatRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = label
        nameLabel.font = .systemFont(ofSize: 12)
        valueLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        valueLabel.alignment = .right

        let row = NSStackView(views: [nameLabel, valueLabel])
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setValue(_ text: String) { valueLabel.stringValue = text }
}
