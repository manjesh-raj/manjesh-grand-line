// Grand Line - native macOS app.
//
// F-15 of full review 4: open a page in its own window.
//
// A Notebook page, the Sticky Board, the Console (its tabs) or the focus
// timer can be popped out into a window of its own, optionally kept on top -
// for a second display.
//
// **The same page, not a second copy.** Pages mount lazily and are never torn
// down (GL-37), so popping one out moves its mounted controller's view into
// the new window rather than building a second controller. There is exactly
// one Notebook, one Sticky Board and one Console, writing through the same
// stores (GL-23); the two windows cannot disagree or race each other's
// writes, because there is nothing in the second window that is not the
// first window's own page. The main window keeps a placeholder in the page's
// place ("Sticky Board is open in its own window") with Show it and Bring it
// back here. Closing the window brings the page back.
//
// The focus timer window is the toolbar chip's ring popover, given a window
// of its own: the same `FocusTimerPanelController` over the same
// `FocusTimerController`, so the window and the chip read one clock.
//
// **The lock (GL-09).** Every popped-out window is registered with the lock
// gate, so it is ordered out when the app locks, like any other window that
// shows the captain's data outside the main one.

import AppKit

// MARK: - What can pop out

enum PageWindowTarget: String, CaseIterable {
    case notebook
    case stickyBoard
    case console

    var destination: RailDestination {
        switch self {
        case .notebook: return .notebook
        case .stickyBoard: return .stickyBoard
        case .console: return .console
        }
    }

    var title: String { PlaceName.of(destination) }

    /// The sidebar modules whose row offers "Open in New Window".
    static func target(for module: WorkspaceModule) -> PageWindowTarget? {
        switch module {
        case .knowledge, .notebook: return .notebook
        case .stickyBoard: return .stickyBoard
        case .console: return .console
        default: return nil
        }
    }

    static func target(for destination: RailDestination) -> PageWindowTarget? {
        allCases.first { $0.destination == destination }
    }
}

// MARK: - The placeholder

/// What the main window shows in a popped-out page's place.
final class PageWindowPlaceholder: NSView {

    var onShow: (() -> Void)?
    var onBringBack: (() -> Void)?

    private let card = HelmCard()
    private let empty: HelmEmptyState
    let target: PageWindowTarget

    init(target: PageWindowTarget) {
        self.target = target
        let show = HelmButton(title: "Show it", variant: .primary, size: .small, symbol: "macwindow")
        let back = HelmButton(title: "Bring it back here", variant: .secondary, size: .small, symbol: "arrow.down.left.and.arrow.up.right")
        let buttons = NSStackView(views: [show, back])
        buttons.spacing = HelmMetrics.s2
        empty = HelmEmptyState(symbol: "macwindow.on.rectangle",
                               title: "\(target.title) is open in its own window",
                               body: "Changes show in both places, because it is the same page. Closing that window brings it back.",
                               size: .standard, accessory: buttons)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        show.target = self
        show.action = #selector(showTapped)
        back.target = self
        back.action = #selector(backTapped)
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: HelmMetrics.s5),
        ])
        empty.applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func showTapped() { onShow?() }
    @objc private func backTapped() { onBringBack?() }

    func applyTheme(_ theme: HelmTheme) { empty.applyTheme(theme) }

    #if FM_SELFTESTS
    func debugShow() { showTapped() }
    func debugBringBack() { backTapped() }
    #endif
}

// MARK: - The windows

final class PageWindows: NSObject, NSWindowDelegate {

    private unowned let content: WorkspaceContent
    /// Mounts a page (navigating to it) and answers its controller.
    private let mount: (RailDestination) -> NSViewController?
    private(set) var windows: [PageWindowTarget: NSWindow] = [:]
    private var pages: [PageWindowTarget: NSViewController] = [:]
    private(set) var timerWindow: NSWindow?
    private let timer: () -> FocusTimerController?

    init(content: WorkspaceContent, mount: @escaping (RailDestination) -> NSViewController?,
         timer: @escaping () -> FocusTimerController?) {
        self.content = content
        self.mount = mount
        self.timer = timer
        super.init()
        AppLockGate.shared.registerSecondaryWindow(owner: self) { [weak self] in self?.anyVisibleWindow() }
    }

    /// The gate orders out one window per provider call, so each window
    /// registers its own provider as it opens; this one is the backstop.
    private func anyVisibleWindow() -> NSWindow? {
        (Array(windows.values) + [timerWindow].compactMap { $0 }).first { $0.isVisible }
    }

    func isDetached(_ target: PageWindowTarget) -> Bool { windows[target] != nil }

    // MARK: Pages

    /// Moves the page into its own window, or brings its window forward.
    @discardableResult
    func open(_ target: PageWindowTarget, keepOnTop: Bool) -> NSWindow? {
        if let existing = windows[target] {
            existing.level = keepOnTop ? .floating : .normal
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        guard AppLockGate.shared.allows(.pageWindow), let controller = mount(target.destination) else { return nil }
        let page = controller.view
        let size = NSSize(width: max(page.bounds.width, 760), height: max(page.bounds.height, 620))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = target.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = keepOnTop ? .floating : .normal
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.setFrameAutosaveName("GrandLine.PageWindow.\(target.rawValue)")
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = HelmTheme.nsColor(ThemeManager.shared.theme.backgroundHex).cgColor
        window.contentView = host
        window.addTitlebarAccessoryViewController(Self.onTopAccessory(window: window, isOn: keepOnTop))

        content.detach(page, placeholder: placeholder(for: target))
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.topAnchor.constraint(equalTo: host.topAnchor, constant: 28),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        page.isHidden = false
        windows[target] = window
        pages[target] = controller
        AppLockGate.shared.registerSecondaryWindow(owner: window) { [weak window] in window }
        if !ProcessMode.current.isIsolated {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        return window
    }

    /// Puts the page back in the main window and closes its window.
    func bringBack(_ target: PageWindowTarget) {
        guard let window = windows.removeValue(forKey: target), let controller = pages.removeValue(forKey: target) else { return }
        window.delegate = nil
        content.reattach(controller.view)
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let target = windows.first(where: { $0.value === window })?.key {
            bringBack(target)
        } else if window === timerWindow {
            timerWindow = nil
        }
    }

    private func placeholder(for target: PageWindowTarget) -> PageWindowPlaceholder {
        let placeholder = PageWindowPlaceholder(target: target)
        placeholder.onShow = { [weak self] in self?.windows[target]?.makeKeyAndOrderFront(nil) }
        placeholder.onBringBack = { [weak self] in self?.bringBack(target) }
        return placeholder
    }

    // MARK: The focus timer

    /// The chip's ring popover, in a window of its own.
    @discardableResult
    func openFocusTimer(keepOnTop: Bool = true) -> NSWindow? {
        if let timerWindow {
            timerWindow.makeKeyAndOrderFront(nil)
            return timerWindow
        }
        guard AppLockGate.shared.allows(.pageWindow), let timer = timer() else { return nil }
        let panel = FocusTimerPanelController(timer: timer)
        let window = NSPanel(contentViewController: panel)
        window.styleMask = [.titled, .closable, .utilityWindow, .fullSizeContentView]
        window.title = "Focus timer"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = keepOnTop ? .floating : .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        window.addTitlebarAccessoryViewController(Self.onTopAccessory(window: window, isOn: keepOnTop))
        timerWindow = window
        AppLockGate.shared.registerSecondaryWindow(owner: window) { [weak window] in window }
        if !ProcessMode.current.isIsolated { window.makeKeyAndOrderFront(nil) }
        return window
    }

    // MARK: Keep on top

    /// The titlebar's "On top" switch.
    static func onTopAccessory(window: NSWindow, isOn: Bool) -> NSTitlebarAccessoryViewController {
        let button = OnTopButton(window: window, isOn: isOn)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = button
        accessory.layoutAttribute = .trailing
        return accessory
    }

    final class OnTopButton: NSView {
        private weak var hostWindow: NSWindow?
        private let button: HelmButton
        init(window: NSWindow, isOn: Bool) {
            self.hostWindow = window
            button = HelmButton(title: "On top", variant: isOn ? .primary : .quiet, size: .small, symbol: "pin")
            super.init(frame: NSRect(x: 0, y: 0, width: 92, height: 28))
            button.target = self
            button.action = #selector(toggle)
            button.toolTip = "Keep this window above other windows"
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
        @objc func toggle() {
            guard let window = hostWindow else { return }
            let on = window.level != .floating
            window.level = on ? .floating : .normal
            button.variant = on ? .primary : .quiet
        }
    }
}
