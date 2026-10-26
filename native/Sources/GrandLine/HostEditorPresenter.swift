// Grand Line - native macOS app.
//
// The Add/Edit Host window (R2-ARCH-02, review #1's T-16 `HostEditorPresenter`):
// the form as a window of its own, its save and delete routed through the
// host store, and the toast that confirms them on the main window. Moved
// verbatim out of `main.swift`, as an extension of `AppDelegate` rather than a
// new type, for `MainMenuBuilder.swift`'s reason: the shell's
// `onPresentHostEditor` and the Hosts page reach it through the delegate.

import AppKit
import SwiftTerm

extension AppDelegate {

    // MARK: Host editor window (nav-redesign task, item 3)

    /// Open (or bring forward) the Add/Edit Host form as its own window -
    /// the same visual weight as Settings, not a sheet cramped into the
    /// narrow Hosts panel. `HostEditorController`'s fields and its inline
    /// "+ New Key…" flow (which still opens as a sheet on top of *this*
    /// window) are unchanged from PR #14.
    func presentHostEditor(for host: Host?) {
        let existingLabels = Set(hostStore.hosts.filter { $0.id != host?.id }.map { $0.label } + ["Firstmate"])
        let editor = HostEditorController(host: host, keyStore: keyStore, snippets: snippetStore.snippets, existingLabels: existingLabels)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if self.hostStore.host(id: saved.id) != nil {
                self.hostStore.update(saved)
            } else {
                self.hostStore.add(saved)
            }
            self.appShell.showToast("\u{201C}\(saved.label)\u{201D} saved")
        }
        // GL-06: the host editor window's Delete button was unconfirmed too,
        // and deleting a host also tears down that host's live console page
        // (see `HostStore.observe` in `applicationDidFinishLaunching`). Same
        // copy as the Hosts list's own row-level confirmation, via the one
        // shared prompt. Deferred a runloop turn because `deleteHost()` closes
        // the editor window right after this returns.
        editor.onDelete = { [weak self] id in
            DispatchQueue.main.async {
                guard let self, let host = self.hostStore.host(id: id) else { return }
                guard DestructiveConfirm.confirm(
                    message: "Delete \u{201C}\(host.label)\u{201D}?",
                    detail: "This removes the saved host and closes its console page. "
                          + "It does not affect any running session."
                ) else { return }
                self.hostStore.delete(id: id)
            }
        }

        // Reuse one window across repeated Add/Edit calls (matching the Keys/
        // Snippets windows below) rather than piling up a new one on every
        // "+" click - only `contentViewController` needs to change since a
        // fresh `HostEditorController` is built above for whichever host is
        // being edited this time.
        let win: NSWindow
        if let existing = hostEditorWindow {
            win = existing
        } else {
            win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.isReleasedWhenClosed = false
            // cockpit-native-host-form-fixes, Fix 1: without this, opening
            // Add/Edit Host while the main `AppShellController` window is
            // full screen makes macOS treat this second regular window as a
            // tile to dock into that same full-screen Space (its default
            // behavior for a second standard window), stretching the
            // centered form back out to full width - the exact regression
            // the centered-form fix (PR #20) was meant to close, just gated
            // behind full-screen mode. `.fullScreenAuxiliary` tells AppKit
            // this window is allowed to float over a full-screen Space
            // instead of tiling into it; `.moveToActiveSpace` matters
            // because this window is cached and reused (`hostEditorWindow`)
            // for the app's whole lifetime, so a later reopen always
            // surfaces on whichever Space (full-screen or not) is active at
            // that moment, not the Space it happened to be in last time.
            // `.floating` keeps it visually above the full-screen window's
            // own content - Space membership alone doesn't guarantee that.
            win.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            win.level = .floating
            // F2(a): A1's window fusion, applied to the one other real window
            // this app opens. Before this, the Host editor wore a stock
            // titlebar with the teal domain ribbon starting *underneath* it -
            // two stacked strips of chrome, which is precisely the shape A1
            // removed from the main window. `WindowChromeFusion.apply` makes
            // the titlebar transparent and titleless while keeping
            // close/minimise/zoom, so the ribbon runs edge to edge along the
            // very top and the lights sit over it.
            //
            // The lights stay where AppKit puts them: this window has no
            // floating bar to hand them to, so the natural top-leading cluster
            // is right, and the sheet reserves room below it rather than the
            // cluster moving (`reservesWindowChromeInset`).
            WindowChromeFusion.apply(to: win)
            win.followHelmTheme()
            hostEditorWindow = win
            // GL-09: a `.floating` window stays above the lock overlay - which
            // is a subview of the *main* window, not a screen-level shield - so
            // a Host Editor open at lock time remained fully usable, editing and
            // saving real host records. Registered once, when the window is
            // created; the gate orders it out on every lock.
            AppLockGate.shared.registerSecondaryWindow(owner: self) { [weak self] in self?.hostEditorWindow }
        }
        // Still set, though `titleVisibility` is `.hidden` under F2(a)'s
        // fusion: the Window menu, Mission Control and the proxy menu all read
        // it, and the sheet's own heading is what the captain actually sees.
        win.title = host == nil ? "New Host" : "Edit Host"
        win.contentViewController = editor
        // Set here rather than in the controller so the two halves of F2(a) -
        // fusing the window and reserving room for the lights it now shows
        // over the content - sit in one function and cannot drift apart.
        (editor.view as? HelmFormSheet)?.reservesWindowChromeInset = true
        // Fix 2 (third round): the form's content column caps at 520pt and
        // centers (`HostEditorController.maxContentWidth`), so 568pt
        // (520 + 24pt margin each side) is the narrowest width that shows the
        // whole column without horizontal clipping - AppKit enforces that as
        // a live floor via the content view controller's fitting size (verified
        // with a live probe: dragging the window narrower than 568 settles
        // back to 568 on the next layout pass, same as any AppKit dialog
        // window whose content can't shrink further). 580 leaves a hair of
        // margin above that floor; 640 is the default so the centering is
        // visibly obvious - not flush with the window edges - without the
        // captain having to widen it by hand. Height has no such floor (the
        // form scrolls vertically), so 620 stays the height floor unchanged.
        win.contentMinSize = NSSize(width: 580, height: 620)
        win.setContentSize(NSSize(width: 640, height: 780))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
