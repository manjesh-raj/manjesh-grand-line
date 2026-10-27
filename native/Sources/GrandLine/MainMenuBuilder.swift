// Grand Line - native macOS app.
//
// The main menu bar (R2-ARCH-02, review #1's T-16 `MainMenuBuilder`): every
// top-level menu, every item, its chord and its target, and the File menu's
// live retitling. Moved verbatim out of `main.swift`, where it was 700 lines
// of the app delegate, into an extension of `AppDelegate` of its own.
//
// It stays an extension rather than becoming a new type on purpose: the
// builder reads the delegate's own state (`appShell`, `workspaceLayout`, the
// File menu items it keeps for retitling, the Go menu's observer) and targets
// the delegate's own verbs, so a separate type would rewrite every one of
// those references - a rewrite, not the move this split was meant to be.
// `AppDelegate.buildMenu(installing:targets:)` is the same call it always was.

import AppKit
import SwiftTerm

/// R2-ARCH-05: the two objects the main menu's items target - the showing
/// shell, for the verbs that differ by layout, and the workspace's navigator,
/// for every navigation verb. `buildMenu` derives both from `appShell` when
/// it installs the menu; a suite hands in stand-ins to check every item's
/// action reaches an object that answers it, without building the shell.
struct MenuTargets {
    let shell: AnyObject?
    let navigator: AnyObject?
}

extension AppDelegate {

    // MARK: Menu

    /// The main menu. Two load-bearing groups:
    ///  - Edit > Paste (⌘V) targets the first responder via `NSText.paste(_:)`,
    ///    which resolves to the focused terminal's `paste(_:)` - the screenshot-
    ///    paste-into-Claude flow. A plain `swift run` executable has no Paste
    ///    action otherwise (the old WKWebView got one for free from the browser).
    ///  - Edit > Find targets the responder chain, resolving to
    ///    `ConsoleController` (the window's content view controller), so ⌘F
    ///    works from the keyboard.
    ///
    /// There is no Tab, View, Window, or Help top-level menu
    /// (`fm/grandline-console-tabs-restore-tabmenu-fix`) - see the long
    /// comment at the end of this method for what that costs and what still
    /// works. ⌘T / ⌘D / ⇧⌘R / ⌘W / ⌘R / ⌘1…⌘9 / zoom / theme no longer have
    /// any keyboard shortcut; every one of their underlying actions is still
    /// reachable from the tab strip, the console toolbar, or Settings.
    // MARK: - NSMenuDelegate

    /// Re-title the File menu's one item every time that menu opens - UX4.
    ///
    /// `menuNeedsUpdate` rather than `validateMenuItem`: the latter is asked
    /// whether an item is *enabled*, and this item is always enabled; what
    /// changes is what it says. AppKit calls this immediately before the menu
    /// is drawn, and also before resolving a key equivalent against it, so the
    /// title a captain reads and the action ⌘N performs are derived from the
    /// same read of `contextualNewAction`.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "File", let contextualNewItem else { return }
        contextualNewItem.title = appShell.workspace.navigator.contextualNewAction.menuTitle
        snippetListItem?.title = CodePreviewSidebarPreferences.isVisible()
            ? "Hide Snippet List" : "Show Snippet List"
    }

    /// Build the app's menu bar, and (by default) install it.
    ///
    /// `installing: false` builds the identical tree and installs nothing -
    /// it touches neither `NSApp` nor `appShell`. That exists for
    /// `NavigationCoherenceSelfTest`, which asserts UX3/UX4's menu shape: a
    /// headless process has no `NSApp` (it is an implicitly-unwrapped
    /// `NSApplication!` and is nil until something calls
    /// `NSApplication.shared`), so a suite that reads `NSApp.mainMenu` back
    /// crashes rather than failing. Building the real tree and handing it over
    /// is what lets that suite stay **pure logic** - in CI's *blocking* lane -
    /// while still asserting the menu bar this method actually produces, not a
    /// reconstruction of it.
    ///
    /// Every menu item's `target` is the only thing that differs, and only
    /// because a target is an object rather than a shape: with `installing:
    /// false` there is no shell to point at, and every assertion that suite
    /// makes is about titles, chords and structure.
    @discardableResult
    func buildMenu(installing: Bool = true, targets: MenuTargets? = nil) -> NSMenu {
        let mainMenu = NSMenu()
        // `appShell` is lazy and builds the app's real controllers, so a
        // non-installing build must not touch it.
        let menuTarget: AnyObject? = targets?.shell ?? (installing ? appShell : nil)
        // R2-ARCH-05: the navigation verbs' own object. The menu used to
        // target the shell for them too, and the shell forwarded every one;
        // `menuTarget` is now only for the verbs that differ by layout.
        let navigatorTarget: AnyObject? = targets?.navigator ?? (installing ? appShell.workspace.navigator : nil)

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = AppPaths.displayName
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        // Nav-redesign task, item 5: Settings is a rail destination in the
        // main window now, not a separate window.
        appMenu.addItem(withTitle: "Settings…", symbol: "gearshape", action: #selector(Navigator.selectSettings), keyEquivalent: ",")
            .target = navigatorTarget
        appMenu.addItem(NSMenuItem.separator())
        // GL-17: Services, plus the standard Hide Others / Show All trio a Mac
        // user expects to find here. `NSApp.servicesMenu` is what makes the
        // system populate the submenu; without the assignment it stays empty.
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        if installing { NSApp.servicesMenu = servicesMenu }
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu - one item, and the reason it exists: UX4's contextual ⌘N.
        //
        // ⌘N used to create a *task* from all twenty-six destinations, even on
        // Hosts (where a new host was ⌘⌃N) and on the six pages that own a
        // creatable thing of their own and had no shortcut for it at all. This
        // item routes to whatever the showing page owns
        // (`ContextualNewAction`), and `menuNeedsUpdate` re-titles it on every
        // open so it *says* "New Sticky Note…" on the Sticky Board rather than
        // doing one thing while reading another.
        //
        // **Exactly one item in this menu bar may carry ⌘N**, which is this
        // one. The Tasks menu's own "New Task…" keeps its title and its place
        // and loses its key equivalent - H3's comment in the Hosts menu below
        // records what happens otherwise: AppKit resolves a chord to the first
        // *enabled* match in menu order, this app implements no
        // `validateMenuItem`, so a second ⌘N simply makes one of the two dead.
        // Creating a task is still ⌘N from every page that owns nothing
        // creatable, which is the fallback `ContextualNewAction` documents.
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.delegate = self
        contextualNewItem = NSMenuItem(title: ContextualNewAction.task.menuTitle,
                                       action: #selector(Navigator.newContextualItem),
                                       keyEquivalent: "n").withSymbol("plus.circle")
        contextualNewItem?.target = navigatorTarget
        if let contextualNewItem { fileMenu.addItem(contextualNewItem) }
        // F11's ⌘R. Checked free against this file's own chords before it was
        // taken - nothing else in `NSApp.mainMenu` claims "r" with any
        // modifier mask - which is the check `NavigationCoherenceSelfTest`
        // enforces for every chord here (AGENTS.md: a duplicate key equivalent
        // silently makes one of the two items permanently dead).
        //
        // It sits in the File menu beside the contextual ⌘N rather than in a
        // menu of its own: it is the page's own verb, the same way ⌘N is, and
        // this app's convention is that a page action reachable from a chord
        // gets a real menu item so the chord is discoverable.
        let runSnippetItem = NSMenuItem(title: "Run Snippet",
                                        action: #selector(Navigator.runCodeSnippetFromMenu),
                                        keyEquivalent: "r").withSymbol("play.fill")
        runSnippetItem.target = navigatorTarget
        fileMenu.addItem(runSnippetItem)
        // Code Preview's snippet list, on VS Code's own ⌘B for its sidebar.
        // Checked free against this file's own chords before it was taken -
        // nothing in `NSApp.mainMenu` claims "b" with any modifier mask, the
        // configurable terminal and dictation chords default to other keys,
        // and the vendored Monaco build binds no ⌘B of its own (that is a VS
        // Code *workbench* binding, which `monaco-editor` does not ship).
        // Same page-verb shape as Run Snippet: a no-op off its own page.
        let snippetListItem = NSMenuItem(title: "Hide Snippet List",
                                         action: #selector(Navigator.toggleCodePreviewSidebarFromMenu),
                                         keyEquivalent: "b").withSymbol("sidebar.left")
        snippetListItem.target = navigatorTarget
        fileMenu.addItem(snippetListItem)
        self.snippetListItem = snippetListItem
        // F15's capture, beside F11's Run Snippet and for the same reason: a
        // page verb reachable from a chord gets a real menu item, so the chord
        // is discoverable and lands in the Help menu's generated shortcut
        // sheet for free (`KeyboardShortcutCatalog` walks this tree).
        //
        // **Not the mockup's ⌘⇧5.** That chord belongs to macOS's own
        // Screenshot app system-wide, so an app menu item declaring it would
        // never fire - the system consumes the event before any app sees it,
        // which is a dead menu item of exactly the kind AGENTS.md's duplicate-
        // chord rule exists to prevent, just with the system rather than a
        // sibling item as the winner. ⌘⇧S was checked free against this file's
        // own chords (⌘⌃S is Show Hosts; nothing claims ⇧⌘S), which is what
        // `NavigationCoherenceSelfTest` enforces.
        let captureRegionItem = NSMenuItem(title: "Capture Screen Region\u{2026}",
                                           action: #selector(Navigator.captureScreenRegionFromMenu),
                                           keyEquivalent: "s").withSymbol("camera.viewfinder")
        captureRegionItem.keyEquivalentModifierMask = [.command, .shift]
        captureRegionItem.target = navigatorTarget
        fileMenu.addItem(captureRegionItem)
        // No chord: the board's own header button is the discoverable copy
        // action, and every free ⌘⇧ letter that reads as "copy" is taken
        // (⌘⇧C is the Log Analyzer's Copy Analysis). Same "menu item only, no
        // keyEquivalent" convention as Quick Connect and Find in Terminal.
        let copyBoardItem = NSMenuItem(title: "Copy Board as Image",
                                       action: #selector(Navigator.copyWhiteboardImageFromMenu),
                                       keyEquivalent: "").withSymbol("doc.on.doc")
        copyBoardItem.target = navigatorTarget
        fileMenu.addItem(copyBoardItem)

        // Edit menu - Cut/Copy/Paste/Select All + Find.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", symbol: "scissors", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", symbol: "doc.on.doc", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", symbol: "doc.on.clipboard", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // F3: ⌘⇧V. Checked free against this file's own menu before it was
        // taken - the Edit menu's Paste is ⌘V and nothing claimed ⇧⌘V - which
        // is the check `NavigationCoherenceSelfTest` now enforces for every
        // chord here (AGENTS.md: a duplicate key equivalent silently makes one
        // of the two items permanently dead).
        let clipboardHistoryItem = NSMenuItem(title: "Clipboard History\u{2026}",
                                              action: #selector(WorkspaceShellController.toggleClipboardHistory),
                                              keyEquivalent: "v").withSymbol("doc.on.clipboard")
        clipboardHistoryItem.keyEquivalentModifierMask = [.command, .shift]
        clipboardHistoryItem.target = menuTarget
        editMenu.addItem(clipboardHistoryItem)
        // Off by default (Settings > Capture), and hidden while it is off.
        self.clipboardHistoryMenuItem = clipboardHistoryItem
        applyClipboardHistoryMenuVisibility()
        editMenu.addItem(withTitle: "Select All", symbol: "selection.pin.in.out", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Find…", symbol: "magnifyingglass", action: #selector(ConsoleController.showFind), keyEquivalent: "f")
        // Phase 4 ("Knowledge and speed") reassigned ⌘K from "Find in
        // Terminal" (Fix 4's original mapping) to the real unified search
        // palette below - plain find-in-terminal stays reachable with no
        // shortcut here (same "menu item only, no keyEquivalent" convention
        // as "Quick Connect" below) since the console toolbar's own
        // magnifying-glass icon already triggers the identical action
        // independently of any menu shortcut, and ⌘F ("Find…" above) covers
        // the common case too.
        let findInTerminalItem = NSMenuItem(title: "Find in Terminal", action: #selector(Navigator.activateConsoleFind), keyEquivalent: "").withSymbol("text.magnifyingglass")
        findInTerminalItem.target = navigatorTarget
        editMenu.addItem(findInTerminalItem)
        // ⌘K opens the app's one command palette, matching the topbar Search
        // pill's own ⌘K badge. F5 expanded what it searches from Runbooks +
        // Postmortems to hosts, saved commands, tasks/follow-ups/projects,
        // runbooks, postmortems and app actions/destinations - and absorbed
        // Shift's own ⌘⇧P palette. See `UnifiedSearch.swift`'s header (and
        // `UnifiedSearchProviders.swift`'s) for the design, including why
        // terminal history is still not included.
        let unifiedSearchItem = NSMenuItem(title: "Search…", action: #selector(AppDelegate.showUnifiedSearch), keyEquivalent: "k").withSymbol("sparkle.magnifyingglass")
        unifiedSearchItem.target = self
        editMenu.addItem(unifiedSearchItem)

        // Hosts menu - the Phase 1 connection manager. New Host targets the
        // panel directly (so it works regardless of focus - the editor now
        // opens as its own window, so this doesn't need the Hosts
        // destination on screen); Show Hosts and Quick Connect route through
        // the shell so the Hosts destination is showing first. The panel's
        // own Connect opens an ssh tab in the console and switches to it
        // (Fix 2: Hosts and Console are decoupled destinations now).
        let hostsMenuItem = NSMenuItem()
        mainMenu.addItem(hostsMenuItem)
        let hostsMenu = NSMenu(title: "Hosts")
        hostsMenuItem.submenu = hostsMenu
        // H3: this used to be a plain ⌘N, which is also what the Tasks menu's
        // "New Task…" declares. AppKit resolves a key equivalent to the first
        // *enabled* match in menu order and neither item is ever disabled (this
        // app implements no `validateMenuItem` at all), so the Hosts menu -
        // added first - swallowed ⌘N and the Tasks item's displayed shortcut
        // could never fire. ⌘N stays with New Task, which is the far more
        // frequent action and the one AGENTS.md documents; New Host takes ⌘⌃N,
        // matching this menu's own "Show Hosts" (⌘⌃S).
        let newHostItem = NSMenuItem(title: "New Host…", action: #selector(Navigator.newHostFromMenu), keyEquivalent: "n").withSymbol("plus.circle")
        newHostItem.keyEquivalentModifierMask = [.command, .control]
        newHostItem.target = navigatorTarget
        hostsMenu.addItem(newHostItem)
        // No keyboard shortcut (⌘K now belongs to Find in Terminal above) -
        // reachable via this menu item or by clicking the Hosts rail icon.
        let quickConnectItem = NSMenuItem(title: "Quick Connect", action: #selector(Navigator.revealHostsQuickConnect), keyEquivalent: "").withSymbol("bolt.horizontal.circle")
        quickConnectItem.target = navigatorTarget
        hostsMenu.addItem(quickConnectItem)
        hostsMenu.addItem(NSMenuItem.separator())
        let showHostsItem = NSMenuItem(title: "Show Hosts", action: #selector(Navigator.selectHosts), keyEquivalent: "s").withSymbol("server.rack")
        showHostsItem.keyEquivalentModifierMask = [.command, .control]
        showHostsItem.target = navigatorTarget
        hostsMenu.addItem(showHostsItem)

        // UX3: SSH Keys and Snippets used to be two *top-level* menus of two
        // items each, for two tabs of this same Hosts destination - while
        // Straw Hat, Poneglyph, Sticky Board, Code Preview, Whiteboard,
        // Schedules, Kubernetes and Review had no menu at all. That is the
        // finding's "two-item top-level menus for tabs of the Hosts page (the
        // notch-budget finding)" exactly, and folding them here is what buys
        // the notch room the Window/Go/Help menus below need.
        //
        // **Every shortcut is unchanged** (⌘⇧N, ⌘⇧K, ⌘⌥N, ⌘⌥P), and so is
        // every title and every action - AppKit resolves a key equivalent
        // against the whole `mainMenu` tree regardless of which submenu an
        // item sits in, so moving an item cannot break its chord. What changes
        // is only where a captain *reads* them, and reading "New SSH Key…"
        // under Hosts is where it belonged: the Keys tab is a tab of the
        // Hosts page.
        hostsMenu.addItem(NSMenuItem.separator())
        let newKeyItem = NSMenuItem(title: "New SSH Key\u{2026}", action: #selector(Navigator.newKeyFromMenu), keyEquivalent: "n").withSymbol("key")
        newKeyItem.keyEquivalentModifierMask = [.command, .shift]
        newKeyItem.target = navigatorTarget
        hostsMenu.addItem(newKeyItem)
        let manageKeysItem = NSMenuItem(title: "Manage SSH Keys\u{2026}", action: #selector(Navigator.selectKeys), keyEquivalent: "k").withSymbol("key.horizontal")
        manageKeysItem.keyEquivalentModifierMask = [.command, .shift]
        manageKeysItem.target = navigatorTarget
        hostsMenu.addItem(manageKeysItem)
        let newSnippetItem = NSMenuItem(title: "New Snippet\u{2026}", action: #selector(Navigator.newSnippetFromMenu), keyEquivalent: "n").withSymbol("plus.rectangle.on.rectangle")
        newSnippetItem.keyEquivalentModifierMask = [.command, .option]
        newSnippetItem.target = navigatorTarget
        hostsMenu.addItem(newSnippetItem)
        let manageSnippetsItem = NSMenuItem(title: "Manage Snippets\u{2026}", action: #selector(Navigator.selectSnippets), keyEquivalent: "p").withSymbol("rectangle.stack")
        manageSnippetsItem.keyEquivalentModifierMask = [.command, .option]
        manageSnippetsItem.target = navigatorTarget
        hostsMenu.addItem(manageSnippetsItem)

        // Session switching (`fm/grandline-session-switcher`, item 3). These
        // live in the Hosts menu rather than a new top-level one: a session
        // *is* a host, and this app's menu bar already overruns the
        // notched-display budget (AGENTS.md's menu-bar section), so a 12th
        // top-level menu would push the gap wider for no gain.
        //
        // **⌘⌃1…9, not ⌘1…9, and that is forced rather than preferred.** The
        // mockup shows ⌘1/⌘2 on the pills, but ⌘1-⌘9 was already spoken for
        // *twice* in this app at the time this shipped: the Tab menu's
        // "Select Tab N" (nil-target, so it only resolved while a
        // Console/Tools tab held first responder) and the View menu's five
        // space shortcuts (explicit target, always enabled). Both of those
        // menus are gone now (`fm/grandline-console-tabs-restore-tabmenu-
        // fix`), which frees ⌘1-⌘9 again, but this stays on ⌘⌃1…9 regardless -
        // an already-shipped shortcut isn't this fix's to change.
        // A session's whole point is being reachable from anywhere, i.e.
        // precisely where the always-enabled space item wins, so ⌘1 could
        // never have reached a session. ⌘⌃ is the modifier this menu already
        // uses for its own two items (⌘⌃N, ⌘⌃S) and its number space is free.
        //
        // ⌘] / ⌘[ were verified unused anywhere in this menu bar.
        hostsMenu.addItem(NSMenuItem.separator())
        let nextSessionItem = NSMenuItem(title: "Next Session",
                                        action: #selector(Navigator.nextSession),
                                        keyEquivalent: "]")
        nextSessionItem.withSymbol("chevron.forward.circle")
        nextSessionItem.target = navigatorTarget
        hostsMenu.addItem(nextSessionItem)
        let previousSessionItem = NSMenuItem(title: "Previous Session",
                                            action: #selector(Navigator.previousSession),
                                            keyEquivalent: "[")
        previousSessionItem.withSymbol("chevron.backward.circle")
        previousSessionItem.target = navigatorTarget
        hostsMenu.addItem(previousSessionItem)
        for n in 1...9 {
            let item = NSMenuItem(title: "Session \(n)",
                                  action: #selector(Navigator.selectSessionByShortcut(_:)),
                                  keyEquivalent: "\(n)")
            item.keyEquivalentModifierMask = [.command, .control]
            item.tag = n
            item.target = navigatorTarget
            hostsMenu.addItem(item)
        }

        // Shift menu (cockpit-shift-create-edit, phase 2) - task/follow-up
        // creation. Both items target the app shell directly (like the Hosts
        // menu's "New Host…" above), so they work regardless of which
        // destination is currently showing - the shell switches to `.shift`
        // itself before presenting the sheet.
        let shiftMenuItem = NSMenuItem()
        mainMenu.addItem(shiftMenuItem)
        let shiftMenu = NSMenu(title: "Tasks")
        shiftMenuItem.submenu = shiftMenu
        // UX4: no key equivalent any more - the File menu's contextual item is
        // the app's one ⌘N, and it still creates a task from every page that
        // owns nothing else creatable (which is most of them). See that item's
        // own comment for why a second ⌘N here would make one of the two dead
        // rather than giving the captain a choice. The item itself stays: it
        // is how "New Task…" is *discovered*, which is the whole point of a
        // menu bar, and it works from anywhere regardless of the showing page.
        let newTaskItem = NSMenuItem(title: "New Task…", action: #selector(Navigator.newShiftTaskFromMenu), keyEquivalent: "").withSymbol("plus.circle")
        newTaskItem.target = navigatorTarget
        shiftMenu.addItem(newTaskItem)
        let newFollowUpItem = NSMenuItem(title: "New Follow-up…", action: #selector(Navigator.newShiftFollowUpFromMenu), keyEquivalent: "f").withSymbol("bell.badge")
        newFollowUpItem.keyEquivalentModifierMask = [.command, .shift]
        newFollowUpItem.target = navigatorTarget
        shiftMenu.addItem(newFollowUpItem)
        // cockpit-fix-shift-new-project: no keyEquivalent - this menu follows
        // "Weekly Review"'s own no-shortcut precedent rather than force a
        // collision. (It could take ⌘⇧P now that F5 freed it, but a shortcut
        // the captain never had is not this task's to invent.)
        let newProjectItem = NSMenuItem(title: "New Project…", action: #selector(Navigator.newShiftProjectFromMenu), keyEquivalent: "").withSymbol("folder.badge.plus")
        newProjectItem.target = navigatorTarget
        shiftMenu.addItem(newProjectItem)
        shiftMenu.addItem(NSMenuItem.separator())
        // F5 (`fm/grandline-feature-f5-command-palette-expansion`) removed
        // this menu's own "Search Tasks… ⌘⇧P" item: ⌘K now searches tasks,
        // follow-ups and projects alongside hosts, commands, runbooks and app
        // actions, so a second search item pointing at a second palette was
        // exactly the duplication the review asked to collapse. Tasks are
        // still fully searchable - from the Edit menu's "Search… ⌘K" or the
        // topbar Search pill. ⌘⇧P is now unbound.
        let weeklyReviewItem = NSMenuItem(title: "Weekly Review", action: #selector(Navigator.showShiftWeeklyReview), keyEquivalent: "").withSymbol("calendar")
        weeklyReviewItem.target = navigatorTarget
        shiftMenu.addItem(weeklyReviewItem)
        // In-app fallback for quick capture's global ⌥Space hotkey (see
        // `ShiftGlobalHotkey`'s header) - works with no Accessibility
        // permission at all as long as this app is frontmost, so it's a
        // meaningful discoverability aid even before that permission is
        // granted.
        let quickCaptureItem = NSMenuItem(title: "Capture\u{2026}", action: #selector(AppDelegate.showShiftQuickCapture), keyEquivalent: "").withSymbol("square.and.pencil")
        quickCaptureItem.target = self
        self.quickCaptureMenuItem = quickCaptureItem
        applyQuickCaptureMenuChord(AppSettings.shared.quickCaptureShortcut)
        shiftMenu.addItem(quickCaptureItem)

        // Log Analyzer menu (`fm/grandline-log-analyzer-build`, spec §24).
        //
        // **Shortcut collisions were checked against this file, not assumed.**
        // ⌘⇧L / ⌘⇧C / ⌘⇧T / ⌘⇧I were all genuinely free. ⌘⇧R was NOT - the
        // Tab menu's "Rename Tab…" claimed it back when the Tab menu was a
        // top-level entry - so spec §24's "⌘⇧R Create RCA" is bound to
        // **⌘⇧A** instead (A for "after-action review"), which is free;
        // taking ⌘⇧R would have silently broken an already-shipped shortcut.
        // The Tab menu is gone from the menu bar now
        // (`fm/grandline-console-tabs-restore-tabmenu-fix`), which frees
        // ⇧⌘R again - Log Analyzer stays on ⌘⇧A regardless, since changing
        // an already-shipped shortcut isn't this fix's job. ⌘↵ (Analyze) is
        // not a menu item at all:
        // it is `analyzeButton`'s own `keyEquivalent`, so it only fires while
        // the page is on screen rather than analyzing from any destination.
        // Esc is handled by `LogAnalyzerController.cancelOperation`, the
        // responder-chain path, for the same reason.
        let logAnalyzerMenuItem = NSMenuItem()
        mainMenu.addItem(logAnalyzerMenuItem)
        let logAnalyzerMenu = NSMenu(title: "Log Analyzer")
        logAnalyzerMenuItem.submenu = logAnalyzerMenu

        let openAnalyzerItem = NSMenuItem(title: "Open Log Analyzer",
                                          action: #selector(Navigator.showLogAnalyzer), keyEquivalent: "l")
        openAnalyzerItem.withSymbol("doc.text.magnifyingglass")
        openAnalyzerItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(openAnalyzerItem)

        let analyzeClipboardItem = NSMenuItem(title: "Analyze Clipboard",
                                              action: #selector(Navigator.analyzeClipboardInLogAnalyzer),
                                              keyEquivalent: "")
        analyzeClipboardItem.withSymbol("clipboard")
        logAnalyzerMenu.addItem(analyzeClipboardItem)
        logAnalyzerMenu.addItem(NSMenuItem.separator())

        let copyAnalysisItem = NSMenuItem(title: "Copy Analysis",
                                          action: #selector(Navigator.logAnalyzerCopyAnalysis), keyEquivalent: "c")
        copyAnalysisItem.withSymbol("doc.on.doc")
        copyAnalysisItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(copyAnalysisItem)

        let sendToTerminalItem = NSMenuItem(title: "Send Top Command to Terminal",
                                            action: #selector(Navigator.logAnalyzerSendToTerminal), keyEquivalent: "t")
        sendToTerminalItem.withSymbol("terminal")
        sendToTerminalItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(sendToTerminalItem)

        let investigateItem = NSMenuItem(title: "Investigate Further",
                                         action: #selector(Navigator.logAnalyzerInvestigateFurther), keyEquivalent: "i")
        investigateItem.withSymbol("magnifyingglass.circle")
        investigateItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(investigateItem)

        let createRCAItem = NSMenuItem(title: "Create RCA",
                                       action: #selector(Navigator.logAnalyzerCreateRCA), keyEquivalent: "a")
        createRCAItem.withSymbol("doc.badge.plus")
        createRCAItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(createRCAItem)

        for item in logAnalyzerMenu.items { item.target = navigatorTarget }

        // Go menu - UX3's "a 'Go' menu listing every destination with its
        // shortcut", and UX4's "give ⌘1-⌘5 to the spaces (the original
        // Daylight spec)". Six of them since
        // `fm/grandline-overview-page-daily-review` added a sixth pill, so
        // the range is ⌘1-⌘6 and Home sits at ⌘2.
        //
        // **UX issue X3 removed Home's separate ⌘0 row.** The menu used to
        // open with "Home ⌘0" and then list "Home ⌘2" three rows later -
        // one destination, two rows, the same word twice, which is half of
        // what the review read off this menu. One of the two chords had to
        // go, and ⌘0 is the one that does not fit a model: ⌘1-⌘6 mirrors
        // the bar's pills left to right and is what `DaylightSpace
        // .shortcutIndex` already means, while ⌘0 was a leftover from
        // before the pills were numbered at all. ⌘2 reaches the same page
        // (`selectSpace` on the Home space shows the canvas), so nothing is
        // unreachable - only the second spelling of it is gone.
        //
        // ⌘1-⌘9 have been genuinely free since the Tab menu's removal (see
        // the Hosts menu's own session-switcher comment, which records that
        // and why the session switcher stayed on ⌘⌃1-9 regardless). The
        // spaces take ⌘1 upward in declaration order, which is what
        // `DaylightSpace.shortcutIndex` reports - the loop below reads it
        // rather than a hand-written list, so a sixth pill needed no edit
        // here.
        //
        // The destination list below is generated from
        // `AllDestinationsOverlayController.groups()` - the same grouping the
        // ⌘⇧D map draws - rather than a hand-written second list, so a new
        // `RailDestination` appears in both surfaces with no edit here.
        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "Go")
        goMenuItem.submenu = goMenu
        // R2-UX-02: the spaces are the floating bar's map, so only it lists
        // them. The sidebar layout's Go menu is the sidebar's own map, at
        // the end of this menu (`WorkspaceGoMenu`).
        for space in DaylightSpace.allCases where workspaceLayout == .floatingBar {
            let item = NSMenuItem(title: space.title,
                                  action: #selector(WorkspaceShellController.selectSpaceByShortcut(_:)),
                                  keyEquivalent: "\(space.shortcutIndex)")
            item.withSymbol(space.heroSymbol)
            item.tag = space.shortcutIndex
            item.target = menuTarget
            goMenu.addItem(item)
        }
        if workspaceLayout == .floatingBar { goMenu.addItem(NSMenuItem.separator()) }
        // P9: the standard sidebar command for the seven pages whose column is
        // a real split-view sidebar. Not the system's ⌃⌘S, which this app
        // already gives to Show Hosts; ⌥⌘S was checked free against this
        // file's chords, which `NavigationCoherenceSelfTest` enforces.
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar",
                                           action: #selector(WorkspaceShellController.toggleSidebarFromMenu),
                                           keyEquivalent: "s").withSymbol("sidebar.left")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        toggleSidebarItem.target = menuTarget
        goMenu.addItem(toggleSidebarItem)
        // R2-UX-09: in the sidebar layout ⌥⌘S is always the app's sidebar,
        // so a page's own column (Notebook, Settings, Schedules) has its own
        // item, a Shift away.
        if workspaceLayout == .sidebar {
            let pageColumnItem = NSMenuItem(title: "Toggle Page Column",
                                            action: #selector(WorkspaceShellController.togglePageColumnFromMenu),
                                            keyEquivalent: "s").withSymbol("sidebar.squares.left")
            pageColumnItem.keyEquivalentModifierMask = [.command, .option, .shift]
            pageColumnItem.target = menuTarget
            goMenu.addItem(pageColumnItem)
        }
        goMenu.addItem(NSMenuItem.separator())
        let allDestinationsItem = NSMenuItem(title: "All Destinations\u{2026}",
                                             action: #selector(AppDelegate.showAllDestinations),
                                             keyEquivalent: "d").withSymbol("square.grid.3x3")
        // ⌘⇧D, not the finding's suggested ⌘⇧A: ⌘⇧A is already "Create RCA"
        // in the Log Analyzer menu below, and that menu's own comment is
        // explicit that it took ⌘⇧A *because* ⇧⌘R was occupied at the time,
        // and equally explicit that an already-shipped shortcut is not a later
        // task's to change. ⌘⇧D was verified unbound anywhere in this method.
        allDestinationsItem.keyEquivalentModifierMask = [.command, .shift]
        allDestinationsItem.target = self
        goMenu.addItem(allDestinationsItem)
        // **UX issue X3.** Everything above this point already has its own
        // item: Home at Cmd-0, and every space pill at Cmd-1..Cmd-5. The
        // groups below are the complete destination map (the same one the
        // All Destinations overlay draws, where completeness is the whole
        // point), so without this Home appeared a second time, under
        // "Elsewhere".
        //
        // Filtered here rather than in `groups()` because the overlay is a
        // map and must stay complete; a menu that already listed something
        // ten rows up must not list it again.
        let alreadyListed: Set<RailDestination> = [.homeCanvas]
        if workspaceLayout == .sidebar {
            // R2-UX-03: a module's tabs, before and after the one showing -
            // the system's own "show previous/next tab" chords. On Console,
            // a host page and Tools `TabKeyboardShortcuts` sees ⌘⇧[ / ⌘⇧]
            // first and moves between that page's own tabs, as it always has.
            goMenu.addItem(NSMenuItem.separator())
            let previousTab = NSMenuItem(title: "Previous Tab",
                                         action: #selector(WorkspaceShellController.selectPreviousModuleTab(_:)),
                                         keyEquivalent: "{").withSymbol("chevron.backward")
            previousTab.target = menuTarget
            goMenu.addItem(previousTab)
            let nextTab = NSMenuItem(title: "Next Tab",
                                     action: #selector(WorkspaceShellController.selectNextModuleTab(_:)),
                                     keyEquivalent: "}").withSymbol("chevron.forward")
            nextTab.target = menuTarget
            goMenu.addItem(nextTab)
            WorkspaceGoMenu.populate(goMenu, target: menuTarget, hidden: AppSettings.shared.hiddenModules)
            // R2-UX-01 (b): a module shown or hidden in Settings comes and
            // goes here too, as it does in the sidebar.
            if installing {
                if let goMenuObserver { NotificationCenter.default.removeObserver(goMenuObserver) }
                goMenuObserver = NotificationCenter.default.addObserver(
                    forName: AppSettings.hiddenModulesDidChange, object: nil, queue: .main
                ) { [weak goMenu, weak menuTarget] _ in
                    guard let goMenu else { return }
                    WorkspaceGoMenu.populate(goMenu, target: menuTarget, hidden: AppSettings.shared.hiddenModules)
                }
            }
        }
        for group in AllDestinationsOverlayController.groups() where workspaceLayout == .floatingBar {
            let remaining = group.destinations.filter { !alreadyListed.contains($0) }
            guard !remaining.isEmpty else { continue }
            goMenu.addItem(NSMenuItem.separator())
            // A disabled header row, the standard Mac way to caption a run of
            // items inside one menu - the alternative (a submenu per space)
            // would put every destination two levels deep, which is the
            // opposite of what a "show me everything" menu is for.
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            goMenu.addItem(header)
            for destination in remaining {
                let item = NSMenuItem(title: destination.title,
                                      action: #selector(WorkspaceShellController.selectDestinationFromMenu(_:)),
                                      keyEquivalent: "")
                item.withSymbol(destination.symbol)
                item.representedObject = destination.rawValue
                item.target = menuTarget
                item.indentationLevel = 1
                goMenu.addItem(item)
            }
        }

        // Window menu - UX3's "⌘M minimise is dead, no Zoom/Bring All to
        // Front".
        //
        // Assigning `NSApp.windowsMenu` is what makes AppKit keep the window
        // list at the bottom of it up to date and what gives the standard
        // items their system behaviour; the three items themselves are the
        // stock selectors, so none of this is behaviour this app implements.
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", symbol: "minus", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", symbol: "square.stack", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        // R2-ARCH-06: the sidebar layout's toolbar is customisable. The
        // system's own sheet, through the window's own action - a right
        // click on the toolbar offers the same item. The floating bar has no
        // window toolbar to customise.
        if workspaceLayout == .sidebar {
            windowMenu.addItem(NSMenuItem.separator())
            windowMenu.addItem(withTitle: "Customize Toolbar\u{2026}", symbol: "slider.horizontal.3",
                               action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        }
        if installing { NSApp.windowsMenu = windowMenu }

        // Help menu - UX3's "add Help -> 'Keyboard Shortcuts…' (generated from
        // the same tables the Settings recorder reads) and 'Manual checks'".
        //
        // The sheet is generated by walking this very menu tree (plus the two
        // configurable families Settings owns) - see
        // `KeyboardShortcutCatalog`'s header for why a walk rather than a
        // second table.
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts\u{2026}",
                                       action: #selector(AppDelegate.showKeyboardShortcuts),
                                       keyEquivalent: "/").withSymbol("keyboard")
        shortcutsItem.keyEquivalentModifierMask = [.command, .shift]
        shortcutsItem.target = self
        helpMenu.addItem(shortcutsItem)
        let manualChecksItem = NSMenuItem(title: "Manual Checks",
                                          action: #selector(AppDelegate.showManualChecks),
                                          keyEquivalent: "").withSymbol("checklist")
        manualChecksItem.target = self
        helpMenu.addItem(manualChecksItem)
        if installing { NSApp.helpMenu = helpMenu }

        // No Tab or View top-level menu.
        //
        // View/Window/Help were standard-system-provided menus that never
        // fit this app: the View menu's `⌘1`-`⌘5` space shortcuts and
        // light/dark toggle duplicated `DaylightBarController`'s own
        // pills/button, its zoom items duplicated the Console toolbar's zoom
        // buttons and Settings' font-size presets; Window's minimize/zoom
        // are native title-bar chrome independent of any menu; Help pointed
        // at two repo docs with no other entry point. Their removal drops
        // the now-dead `openRepoDoc`/`openSetupGuide`/`openReadme` helpers
        // (their only callers) and `AppShellController`'s
        // `selectSpaceByShortcut(_:)`/`toggleTheme()` menu-item wrappers
        // (`selectSpace(_:)` itself is still very much alive - it's what
        // `DaylightBarController`'s own space pills call; only the
        // `NSMenuItem`-shaped `⌘1`-`⌘5` wrapper around it is gone. Same for
        // `ThemeManager.shared.toggle()`, still called directly by
        // `DaylightBarController`'s own theme-toggle button).
        //
        // The Tab menu (new / duplicate / rename / close / reconnect / jump
        // to tab N) is a separate, later removal
        // (`fm/grandline-console-tabs-restore-tabmenu-fix`) - the captain's
        // own original intent, distinct from the View/Window/Help cleanup
        // above: every capability it offered has a non-keyboard equivalent
        // already built into the tab strip (`TabChipView`) - the "+" button
        // for New, a chip's own double-click for Rename, and its right-click
        // menu for Rename/Duplicate/Close/**Reconnect** (the last one added
        // alongside this removal specifically so "reconnect a dead tab"
        // stays reachable with no menu backing it - see
        // `TabChipView.onReconnect`) - and jumping to a specific tab is
        // simply clicking its chip, which was always the primary way to do
        // it. What does NOT survive, because AppKit's standard key-equivalent
        // handling only walks items that are genuinely part of
        // `NSApp.mainMenu`'s tree (hiding a top-level item via `isHidden`
        // excludes its whole submenu from that walk exactly like removing it
        // outright does - there is no "present in the tree but invisible in
        // the bar" middle ground) is every one of the Tab menu's keyboard
        // shortcuts: ⌘T (new tab), ⌘D (duplicate), ⇧⌘R (rename), ⌘W (close),
        // ⌘R (reconnect), and ⌘1-⌘9 (jump to tab N). This is the same,
        // captain-accepted trade-off as ⌘M silently doing nothing once the
        // Window menu above went - the shortcuts are gone, the underlying
        // action is one click away either way. This is also shared with
        // `ToolsController`'s own, separate multi-instance tab strip, which
        // reused these exact selector names precisely so one Tab menu could
        // drive whichever controller had focus (see `ToolsController`'s own
        // `newShellTab`/`duplicateCurrentTab`/`renameCurrentTab`/
        // `closeCurrentTab`) - Tools' own "+" button and its tab chips'
        // double-click/right-click are completely unaffected, since neither
        // ever routed through this menu to begin with.

        if installing { NSApp.mainMenu = mainMenu }
        return mainMenu
    }
}
