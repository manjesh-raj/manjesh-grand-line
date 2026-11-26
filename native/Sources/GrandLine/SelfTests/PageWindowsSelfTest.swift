// Grand Line - native macOS app.
//
// F-15 of full review 4: open a page in its own window.
// Run with `FM_RUN_PAGE_WINDOWS_TESTS=1 .build/debug/GrandLine`.
//
// Headless. The windows `PageWindows` builds are never ordered onto a
// screen in a test process (it checks `ProcessMode`), so this asserts the
// view hierarchy, not pixels.
//
// What it pins:
//
//  - **The same page moves**: the page's own view ends up in the new
//    window, and the main window's body shows the placeholder instead -
//    there is no second controller.
//  - **Visibility follows the placeholder** while the page is out, and the
//    page stays shown in its window when the main window navigates away.
//  - **Bringing it back** (or closing the window) puts the page back pinned
//    in the body with the visibility it would have had.
//  - **One window per page**, kept on top when asked, and none while locked
//    (GL-09).
//  - **The focus timer window** is the chip's panel over the same timer.
//  - **Source guards** on the sidebar row and the Window menu item.

#if FM_SELFTESTS

import AppKit

enum PageWindowsSelfTest {

    static func run() -> Bool {
        var ok = true
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        AppLockGate.shared.setLocked(false)
        let cases: [(String, () -> String?)] = [
            ("the same page moves into the window", test_moves),
            ("visibility follows the placeholder", test_visibility),
            ("bringing it back, and closing the window", test_bringBack),
            ("one window per page, on top, and the lock", test_oneWindowAndLock),
            ("the focus timer window", test_timerWindow),
            ("the sidebar and the Window menu", test_wiring),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[page-windows] \(name): \(failure)", &ok) } else { print("[page-windows] PASS \(name)") }
        }
        print(ok ? "[page-windows] ALL PASS" : "[page-windows] FAILED")
        return ok
    }

    final class Page: NSViewController {
        override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)) }
    }

    static func setUp() -> (WorkspaceContent, Page, PageWindows) {
        let content = WorkspaceContent()
        content.bodyContainer.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let page = Page()
        content.embed(page.view)
        content.setDestinationVisible(page.view, true)
        let windows = PageWindows(content: content, mount: { _ in page }, timer: { nil })
        return (content, page, windows)
    }

    static func test_moves() -> String? {
        let (content, page, windows) = setUp()
        guard let window = windows.open(.stickyBoard, keepOnTop: false) else { return "no window" }
        guard page.view.window === window || page.view.superview === window.contentView else { return "the page did not move into the window" }
        guard let placeholder = content.bodyContainer.subviews.first(where: { $0 is PageWindowPlaceholder }) else {
            return "the main window has no placeholder"
        }
        guard !placeholder.isHidden else { return "the placeholder is hidden while the page is the one on screen" }
        guard !content.bodyContainer.subviews.contains(page.view) else { return "the page is still in the main window too" }
        windows.bringBack(.stickyBoard)
        return nil
    }

    static func test_visibility() -> String? {
        let (content, page, windows) = setUp()
        windows.open(.notebook, keepOnTop: false)
        content.setDestinationVisible(page.view, false)
        guard let placeholder = content.detachedPlaceholders.values.first, placeholder.isHidden else {
            return "navigating away did not hide the placeholder"
        }
        guard !page.view.isHidden else { return "navigating away in the main window hid the page in its own window" }
        content.setDestinationVisible(page.view, true)
        guard !placeholder.isHidden else { return "navigating back did not show the placeholder" }
        windows.bringBack(.notebook)
        return nil
    }

    static func test_bringBack() -> String? {
        let (content, page, windows) = setUp()
        windows.open(.console, keepOnTop: false)
        content.setDestinationVisible(page.view, false)
        windows.bringBack(.console)
        guard page.view.superview === content.bodyContainer else { return "the page did not come back" }
        guard content.detachedPlaceholders.isEmpty, !content.bodyContainer.subviews.contains(where: { $0 is PageWindowPlaceholder }) else {
            return "the placeholder outlived the page's return"
        }
        guard page.view.isHidden else { return "the page came back shown though another page was on screen" }
        content.setDestinationVisible(page.view, true)
        guard content.destinationPins[ObjectIdentifier(page.view)]?.allSatisfy(\.isActive) == true else {
            return "the returned page is not pinned to the body"
        }
        // Closing the window is the other way back.
        guard let window = windows.open(.console, keepOnTop: false) else { return "no second window" }
        windows.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        return page.view.superview === content.bodyContainer && !windows.isDetached(.console)
            ? nil : "closing the window did not bring the page back"
    }

    static func test_oneWindowAndLock() -> String? {
        let (content, _, windows) = setUp()
        defer { withExtendedLifetime(content) {} }
        guard let first = windows.open(.stickyBoard, keepOnTop: false) else { return "no window" }
        guard let again = windows.open(.stickyBoard, keepOnTop: true), again === first else { return "a second window opened for one page" }
        guard first.level == .floating else { return "kept on top did not float the window" }
        windows.bringBack(.stickyBoard)
        AppLockGate.shared.setLocked(true)
        defer { AppLockGate.shared.setLocked(false) }
        return windows.open(.notebook, keepOnTop: false) == nil ? nil : "a page opened in its own window while locked"
    }

    static func test_timerWindow() -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-windows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", dir.path, 1)
        defer { if let saved { setenv("FM_SHIFT_DIR", saved, 1) } else { unsetenv("FM_SHIFT_DIR") } }
        let timer = FocusTimerController(store: ShiftStore())
        let content = WorkspaceContent()
        defer { withExtendedLifetime(content) {} }
        let windows = PageWindows(content: content, mount: { _ in nil }, timer: { timer })
        guard let window = windows.openFocusTimer() else { return "no timer window" }
        guard window.contentViewController is FocusTimerPanelController, window.level == .floating else {
            return "the timer window is not the chip's panel, kept on top"
        }
        return windows.openFocusTimer() === window ? nil : "a second timer window opened"
    }

    static func test_wiring() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { print("[page-windows] SKIP guard"); return nil }
        func read(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        guard read("WorkspaceSidebar.swift").contains("menuItem(\"Open in New Window\", symbol:") else {
            return "the sidebar row lost Open in New Window"
        }
        guard read("MainMenuBuilder.swift").contains("#selector(AppDelegate.openPageInNewWindow)") else {
            return "the Window menu lost Open Page in New Window"
        }
        return read("MainSplitShellController.swift").contains("self?.workspace.pageWindows.open(target, keepOnTop: onTop)")
            ? nil : "the shell no longer routes the sidebar's item to the page windows"
    }
}

#endif
