// Manjesh Grand Line - native macOS app.
//
// The credential vault's window-backed half: the real destination in a real
// window, driving the real controls a captain clicks. The storage layer is
// `CredentialVaultSelfTest` (pure logic, in CI); this suite is in
// `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list.
//
//   `FM_RUN_CREDENTIAL_VAULT_VIEW_TESTS=1 .build/debug/FirstmateCockpit`
//
// **What this suite is actually for.** The captain's headline requirement is
// "one click from a stored credential to my clipboard", and his explicit
// correction was that Reveal and Copy are *separate* actions with their own
// icons, both on the list row itself, because he wants to copy without
// revealing while screen sharing. Every one of those is a claim about real
// buttons, and none of it can be checked by reading the model:
//
//   * Clicking the row's **Copy** button must put the value on the clipboard
//     and leave the row masked.
//   * Clicking the row's **Reveal** button must put the value on the row and
//     leave the clipboard alone.
//
// So both are driven through the genuine `NSButton` target/action a click
// dispatches, and both directions are asserted - "copy did not reveal" is as
// much the requirement as "copy copied".
//
// GL-27: compiled into debug builds only. Do not remove this guard when
// editing this file - `Phase3PolishSelfTest` asserts every file in this
// directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CredentialVaultViewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                print("  FAIL: \(message)")
                ok = false
            }
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("credential-vault-view-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // The captain's real pasteboard is what `CredentialVaultClipboard`
        // writes to - there is no scratch `NSPasteboard.general`, and the copy
        // action's whole contract is about that shared one. Saved and restored.
        let pasteboard = NSPasteboard.general
        let captainsClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let captainsClipboard { pasteboard.setString(captainsClipboard, forType: .string) }
        }

        // The theme is real `UserDefaults` state on this machine. Saved and put
        // back, per the rule `Phase3PolishSelfTest.checkSuitesRestoreTheTheme`
        // enforces - a suite that leaks it makes every *later* suite in the run
        // measure geometry under a theme nobody selected.
        let captainsTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(captainsTheme) }

        // The page defers everything privileged it does on appearing while the
        // app-lock gate says locked, and the gate *starts* locked (the app
        // does). A suite never runs the real unlock, so it has to say so - and
        // put it back.
        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer { AppLockGate.shared.setLocked(wasLocked) }

        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        NSApp.setActivationPolicy(.accessory)
        // Ordered front - far off-screen, so nothing appears on the captain's
        // display - because a window that was never ordered in reports
        // `isVisible == false`, which several visibility gates read. Never
        // `makeKeyAndOrderFront`/`activate`: this machine runs the captain's
        // own instance.
        window.orderFront(nil)

        checkCreateAndUnlock(scratch: scratch, window: window, check)
        checkRevealAndCopyAreSeparate(scratch: scratch, window: window, check)
        checkSearchAndCategoryFilter(scratch: scratch, window: window, check)
        checkDeleteConfirmAndUndo(scratch: scratch, window: window, check)
        checkAutoLock(scratch: scratch, window: window, check)
        checkSidebarDrivesTheFilter(scratch: scratch, window: window, check)
        checkRecordRowFitsItsHeight(scratch: scratch, window: window, check)
        checkInspectorShowsWholeValues(scratch: scratch, window: window, check)
        checkSelectionFollowsTheList(scratch: scratch, window: window, check)
        checkLockClearsTheInspector(scratch: scratch, window: window, check)
        checkUnreadableNeverOffersCreate(scratch: scratch, window: window, check)
        checkEditorRoundTrip(check)
        checkExactlyOneSwitchPerToggleRow(check)
        checkPasswordChangeWarnsAboutGitHistory(check)
        checkThemeSweep(scratch: scratch, window: window, check)
        checkListBodyFillsItsCard(check)
        checkHeaderlessCardGivesItsBodyTheCard(check)

        window.contentView = nil
        if ok {
            print("CredentialVaultViewSelfTest: all checks passed")
            return true
        }
        print("CredentialVaultViewSelfTest: FAILED")
        return false
    }

    // MARK: Harness

    /// A mounted page over a fresh scratch root. `seed` runs against the store
    /// after the vault is created, before the first render.
    private static func mounted(_ scratch: URL,
                                name: String,
                                window: NSWindow,
                                password: String = "view-test-password",
                                createVault: Bool = true,
                                seed: (CredentialVaultStore) -> Void = { _ in })
        -> (controller: CredentialVaultController, store: CredentialVaultStore) {
        let root = scratch.appendingPathComponent(name, isDirectory: true)
        let store = CredentialVaultStore(root: root)
        if createVault {
            _ = store.createVault(masterPassword: password)
            seed(store)
        }
        let controller = CredentialVaultController(store: store)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        controller.viewDidAppear()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, store)
    }

    /// The first `.record` row's index in the list - the rows are interleaved
    /// with category group headers, so a test must not assume row 0.
    private static func firstRecordRow(_ list: CredentialVaultListSection) -> Int? {
        (0..<list.debugRowCount).first { list.debugItem($0)?.isRecord == true }
    }

    // MARK: Cases

    private static func checkCreateAndUnlock(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- the gate: create, then lock, then unlock --")
        // A page over a directory with no vault shows the create state, not the
        // list.
        let (controller, store) = mounted(scratch, name: "gate", window: window, createVault: false)
        check(controller.debugIsUnlockShowing, "a page with no vault should show the gate")
        check(!controller.debugIsListShowing, "a page with no vault should not show the list")
        check(controller.drillHeaderSubtitle == "Not set up yet",
              "the drill subtitle should say the vault is not set up, got \(String(describing: controller.drillHeaderSubtitle))")
        // None of the page actions make sense behind the gate.
        check(controller.debugAddButton.isHidden, "Add should be hidden behind the gate")
        check(controller.debugLockButton.isHidden, "Lock should be hidden behind the gate")
        check(controller.debugSettingsButton.isHidden, "Settings should be hidden behind the gate")

        // Create it for real, then confirm the page swaps to the list.
        _ = store.createVault(masterPassword: "view-test-password")
        controller.debugRender()
        check(controller.debugIsListShowing, "the list should show once the vault is unlocked")
        check(!controller.debugIsUnlockShowing, "the gate should be hidden once unlocked")
        check(!controller.debugAddButton.isHidden, "Add should be available once unlocked")

        // An unlocked vault with no credentials shows the list's own empty row
        // - deliberately not a third page state.
        check(controller.debugList.debugRowCount == 1,
              "an empty vault should render exactly one (empty-state) row, got \(controller.debugList.debugRowCount)")
        check(controller.debugList.debugItem(0)?.isRecord == false,
              "the one row of an empty vault should be the empty state, not a record")

        // The real Lock button re-locks and shows the gate again.
        controller.debugLockButton.performClick(nil)
        check(!store.isUnlocked, "clicking Lock should lock the store")
        check(controller.debugIsUnlockShowing, "clicking Lock should show the gate again")
        check(store.credentials.isEmpty, "locking should drop the decrypted model")
    }

    private static func checkRevealAndCopyAreSeparate(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- reveal and copy: two independent one-click actions --")
        let secret = "view-test-secret-value-7f3c"
        let (controller, store) = mounted(scratch, name: "revealcopy", window: window) { store in
            _ = store.add(VaultCredential(title: "AWS root account", category: .cloud,
                                          account: "root@682528822458", secret: secret,
                                          tags: ["prod"]))
        }
        let list = controller.debugList
        guard let row = firstRecordRow(list) else {
            check(false, "the list should render a record row for the seeded credential")
            return
        }
        guard let revealButton = list.debugRevealButton(row), let copyButton = list.debugCopyButton(row) else {
            check(false, "every row must carry BOTH a Reveal and a Copy button - the captain's explicit ask")
            return
        }
        let id = list.debugItem(row)?.credentialID ?? ""

        // --- Copy: clipboard yes, screen no. ---
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("something-else-entirely", forType: .string)
        copyButton.performClick(nil)
        check(pasteboard.string(forType: .string) == secret,
              "clicking a row's Copy button should put the value on the clipboard")
        check(!controller.debugRevealedIDs.contains(id),
              "Copy must NOT reveal the value on screen - the whole point of the split (screen sharing)")
        // The row still shows the account, not the secret.
        let maskedMeta = list.debugItem(row)?.content.meta ?? ""
        check(!maskedMeta.contains(secret),
              "after Copy the row's own text must not contain the value, got \"\(maskedMeta)\"")
        check(store.auditLog.contains { $0.kind == .copied && $0.itemID == id },
              "Copy should log a `copied` audit event")
        check(!store.auditLog.contains { $0.kind == .revealed && $0.itemID == id },
              "Copy must not log a `revealed` event - reveal and copy are distinct facts")
        check(controller.debugClipboardPillVisible,
              "a copy with a clear timeout should show the countdown pill")

        // --- Reveal: screen yes, clipboard no. ---
        pasteboard.clearContents()
        pasteboard.setString("untouched-by-reveal", forType: .string)
        revealButton.performClick(nil)
        check(controller.debugRevealedIDs.contains(id), "clicking Reveal should reveal the row")
        check(pasteboard.string(forType: .string) == "untouched-by-reveal",
              "Reveal must NOT touch the clipboard")
        // The revealed value is genuinely on the row.
        guard let revealedRow = firstRecordRow(list), let revealedItem = list.debugItem(revealedRow) else {
            check(false, "the list should still render the row after a reveal")
            return
        }
        check(revealedItem.content.meta == secret,
              "a revealed row should show the value, got \(String(describing: revealedItem.content.meta))")
        check(revealedItem.content.metaIsCode,
              "a revealed value should render in the code face - the visible signal that this is the secret")
        check(revealedItem.isRevealed, "the row should report itself revealed so its glyph flips")
        check(store.auditLog.contains { $0.kind == .revealed && $0.itemID == id },
              "Reveal should log a `revealed` audit event")

        // Reveal again to hide - and hiding logs nothing new.
        let revealsBefore = store.auditLog.filter { $0.kind == .revealed }.count
        list.debugRevealButton(revealedRow)?.performClick(nil)
        check(!controller.debugRevealedIDs.contains(id), "clicking Reveal again should re-mask the row")
        check(store.auditLog.filter { $0.kind == .revealed }.count == revealsBefore,
              "hiding a value should not log a second reveal - only putting it on screen is the event")

        // Locking clears every reveal, so an unlock never starts with a value
        // on screen.
        list.debugRevealButton(revealedRow)?.performClick(nil)
        check(!controller.debugRevealedIDs.isEmpty, "precondition: something is revealed before locking")
        controller.debugLockButton.performClick(nil)
        check(controller.debugRevealedIDs.isEmpty, "locking should clear every revealed row")

        // And the row's overflow menu is what carries the rest, so routine use
        // never needs Item Detail.
        pasteboard.clearContents()
    }

    private static func checkSearchAndCategoryFilter(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- search and category chips --")
        let (controller, _) = mounted(scratch, name: "filter", window: window) { store in
            _ = store.add(VaultCredential(title: "Gmail, personal", category: .email,
                                          account: "manjesh.p@gmail.com", secret: "gmail-value", tags: ["personal"]))
            _ = store.add(VaultCredential(title: "AWS root account", category: .cloud,
                                          account: "root", secret: "aws-value", tags: ["prod"]))
            _ = store.add(VaultCredential(title: "GitHub PAT", category: .apiKey,
                                          account: "manjesh-raj", secret: "ghp-value", tags: ["ci"]))
        }
        let list = controller.debugList
        func recordCount() -> Int {
            (0..<list.debugRowCount).filter { list.debugItem($0)?.isRecord == true }.count
        }
        // Three records plus three category group headers.
        check(recordCount() == 3, "all three credentials should render, got \(recordCount())")

        controller.debugSetQuery("aws")
        check(recordCount() == 1, "searching \"aws\" should leave one record, got \(recordCount())")
        controller.debugSetQuery("PROD")
        check(recordCount() == 1, "search should match a tag, case-insensitively, got \(recordCount())")
        // The one thing search must never do.
        controller.debugSetQuery("gmail-value")
        check(recordCount() == 0,
              "search must NEVER match a secret value - it would be a disclosure channel with no audit event")
        controller.debugSetQuery("zzzz-no-match")
        check(recordCount() == 0 && list.debugRowCount == 1,
              "a search with no matches should render exactly the empty state")

        controller.debugSetQuery("")
        controller.debugSelectCategory(CredentialCategory.email.rawValue)
        check(recordCount() == 1, "the Email chip should leave one record, got \(recordCount())")
        controller.debugSelectCategory(CredentialVaultController.allTabID)
        check(recordCount() == 3, "the All chip should bring every record back, got \(recordCount())")

        check(controller.drillHeaderSubtitle?.contains("3 credentials") == true,
              "the drill subtitle should report the count, got \(String(describing: controller.drillHeaderSubtitle))")
        controller.debugSetQuery("aws")
        check(controller.drillHeaderSubtitle?.contains("1 of 3 credentials") == true,
              "a filtered list's subtitle should say how many of how many, got \(String(describing: controller.drillHeaderSubtitle))")
    }

    private static func checkDeleteConfirmAndUndo(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- delete: store + undo (the modal itself is not driven here) --")
        // The confirm is a real `NSAlert.runModal`, which a headless suite
        // cannot answer - so this drives the store side of the flow and the
        // undo restore, exactly as `CredentialVaultSelfTest` does, and the
        // *routing* (a modal precedes it, Cancel first and default) is asserted
        // by a source guard below.
        let (controller, store) = mounted(scratch, name: "delete", window: window) { store in
            _ = store.add(VaultCredential(title: "Legacy VPN credential", secret: "legacy-value", notes: "unused"))
        }
        let list = controller.debugList
        guard let row = firstRecordRow(list), let id = list.debugItem(row)?.credentialID else {
            check(false, "the seeded credential should render")
            return
        }
        guard case .success(let removed) = store.delete(id: id) else {
            check(false, "delete should succeed")
            return
        }
        controller.debugRender()
        check(list.debugRowCount == 1 && list.debugItem(0)?.isRecord == false,
              "after the only credential is deleted the list should show its empty state")
        guard case .success = store.restore(removed) else {
            check(false, "restore should succeed")
            return
        }
        controller.debugRender()
        check(firstRecordRow(list) != nil, "an undone delete should put the row back")
        check(store.credential(id: id)?.secret == "legacy-value",
              "an undone delete should bring the value back intact")
        check(store.credential(id: id)?.notes == "unused", "an undone delete should bring the notes back too")
    }

    private static func checkAutoLock(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- auto-lock --")
        let (controller, store) = mounted(scratch, name: "autolock", window: window) { store in
            _ = store.add(VaultCredential(title: "Something", secret: "value"))
            _ = store.updateSettings(VaultSettings(autoLockSeconds: 60,
                                                   clipboardClearSeconds: 20,
                                                   touchIDUnlockEnabled: false))
        }
        check(controller.debugAutoLockTimerRunning,
              "an appeared page with a real auto-lock setting should be running its timer")

        // Not yet idle - a check must not lock.
        controller.debugSetLastInteraction(Date())
        controller.debugCheckAutoLock()
        check(store.isUnlocked, "a vault interacted with a moment ago must not auto-lock")

        // Genuinely idle past the threshold.
        controller.debugSetLastInteraction(Date().addingTimeInterval(-120))
        controller.debugCheckAutoLock()
        check(!store.isUnlocked, "a vault idle past its threshold should auto-lock")
        check(controller.debugIsUnlockShowing, "auto-locking should show the gate")
        check(store.auditLog.isEmpty, "a locked store holds no decrypted log in memory")

        // "Never" means never.
        let (never, neverStore) = mounted(scratch, name: "autolock-never", window: window) { store in
            _ = store.updateSettings(VaultSettings(autoLockSeconds: 0,
                                                   clipboardClearSeconds: 20,
                                                   touchIDUnlockEnabled: false))
        }
        check(!never.debugAutoLockTimerRunning,
              "auto-lock set to Never should schedule no timer at all")
        never.debugSetLastInteraction(Date().addingTimeInterval(-100_000))
        never.debugCheckAutoLock()
        check(neverStore.isUnlocked, "auto-lock set to Never must never lock, however idle")

        // Navigating away stops the timer but does NOT lock - see the
        // controller's own header on why that is the right call.
        let (nav, navStore) = mounted(scratch, name: "autolock-nav", window: window) { store in
            _ = store.updateSettings(VaultSettings(autoLockSeconds: 60,
                                                   clipboardClearSeconds: 20,
                                                   touchIDUnlockEnabled: false))
        }
        nav.viewDidDisappear()
        check(!nav.debugAutoLockTimerRunning, "leaving the page should stop its timer (GL-13)")
        check(navStore.isUnlocked, "leaving the page must not lock the vault - the whole-app lock covers walking away")

        // The whole app locking DOES lock it.
        nav.lockForAppLock()
        check(!navStore.isUnlocked, "the app locking should lock the vault")
    }

    /// **The H2 security guard, re-pointed at the shape the detail now has.**
    ///
    /// It used to assert that locking dismissed the detail *sheet*. That was
    /// exactly right while the detail was a `presentAsSheet` child window
    /// layered above the app's lock overlay (which is only a subview of the
    /// main window), holding a plaintext credential captured at construction
    /// and toggling masked/plaintext display of it with no reference to vault
    /// state at all - so every lock path cleared the key and re-rendered the
    /// page behind a sheet that still held, and could still Reveal, the secret.
    ///
    /// The detail is a panel inside the page now
    /// (`CredentialVaultInspectorView`), so the *window* half of that defect is
    /// gone by construction - there is no child window left floating above the
    /// overlay. The property worth guarding did not go with it, and is what
    /// this case asserts instead: **every lock path must empty the panel.**
    /// Locking is supposed to mean the decrypted value leaves memory and the
    /// screen, not that something is drawn over it - and `lockForAppLock` in
    /// particular can run against an already-locked store (auto-lock fires, the
    /// captain walks away, the app locks), which is the case that would
    /// otherwise return early with the panel still full.
    ///
    /// The editor and settings sheets are still real sheets, so the dismissal
    /// half is still asserted through those.
    ///
    /// Driven per path, each on its own page, because the four are four
    /// separate call sites and a fix applied to one is exactly the shape of
    /// regression worth catching.
    private static func checkLockClearsTheInspector(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- locking empties the inspector and dismisses every open sheet --")

        /// A fresh page with a credential showing in the inspector.
        func selected(_ name: String) -> (controller: CredentialVaultController, store: CredentialVaultStore)? {
            let (controller, store) = mounted(scratch, name: name, window: window) { store in
                _ = store.add(VaultCredential(title: "Prod DB", account: "dba@prod",
                                              secret: "super-secret-value"))
            }
            guard let id = store.credentials.first?.id else {
                check(false, "\(name): the page needs a seeded credential to select")
                return nil
            }
            controller.debugSelectCredential(id: id)
            guard controller.debugInspector.credential != nil else {
                check(false, "\(name): selecting a credential should fill the inspector")
                return nil
            }
            return (controller, store)
        }

        /// The panel holds nothing: no credential, nothing revealed, and no
        /// plaintext anywhere in the labels it rendered.
        func assertEmptied(_ controller: CredentialVaultController, _ path: String) {
            let inspector = controller.debugInspector
            check(inspector.credential == nil,
                  "\(path) must empty the inspector, still showing \(inspector.credential?.title ?? "-")")
            check(controller.debugSelectedID == nil,
                  "\(path) must drop the selection, still \(controller.debugSelectedID ?? "-")")
            check(!inspector.debugIsRevealed, "\(path) must leave the panel masked")
            check(inspector.debugIsEmptyStateShowing,
                  "\(path) must leave the panel on its empty state")
            let onScreen = inspector.debugValueLabels.map(\.stringValue).joined(separator: " ")
                + " " + inspector.debugSecretLabel.stringValue
            check(!onScreen.contains("super-secret-value"),
                  "\(path) must leave no plaintext on screen, got \(onScreen)")
        }

        // ---- Path 1: the Lock button ----
        if let (controller, store) = selected("lock-panel-manual") {
            controller.debugLockTapped()
            assertEmptied(controller, "the Lock button")
            check(!store.isUnlocked, "...and still lock the vault")
        }

        // ---- Path 2: the auto-lock timer ----
        if let (controller, store) = selected("lock-panel-idle") {
            controller.debugSetLastInteraction(Date().addingTimeInterval(-100_000))
            controller.debugCheckAutoLock()
            assertEmptied(controller, "auto-locking")
            check(!store.isUnlocked, "...and still lock the vault")
        }

        // ---- Path 3: the whole app locking ----
        if let (controller, store) = selected("lock-panel-app") {
            controller.lockForAppLock()
            assertEmptied(controller, "the app locking")
            check(!store.isUnlocked, "...and still lock the vault")
        }

        // ---- Path 3b: the store's own lock already empties the panel ----
        //
        // Worth asserting because it is the *reason* a panel is safer than the
        // sheet it replaced, and it is not obvious from any one call site: the
        // page renders off `store.onChange`, and `render()` clears the panel
        // whenever the store is locked - so a bare `store.lock` empties it
        // without any lock path having to remember to. The sheet had no
        // equivalent; it was a separate window holding its own copy, which is
        // precisely why H2 had to add a dismissal to all four paths.
        //
        // `lockForAppLock` then still has to leave it empty rather than
        // restore anything, which is what the second half checks - that method
        // returns early on an already-locked store, and its `clearInspector()`
        // is deliberately *before* that guard.
        if let (controller, store) = selected("lock-panel-already-locked") {
            store.lock(reason: "test")
            check(controller.debugInspector.credential == nil,
                  "locking the store alone should already empty the panel through the page's own render")
            controller.lockForAppLock()
            assertEmptied(controller, "an app lock after the vault already locked")
        }

        // ---- Path 4: the app-lock gate on its own ----
        //
        // The page registers with `AppLockGate` as well, so any future path
        // that locks the app without going through `lockForAppLock` is covered.
        if let (controller, _) = selected("lock-panel-gate") {
            AppLockGate.shared.setLocked(true)
            assertEmptied(controller, "the app-lock gate alone")
            AppLockGate.shared.setLocked(false)
        }

        // ---- The two remaining sheets are still sheets ----
        //
        // The editor is a real `presentAsSheet` child window and still has to
        // be dismissed on a lock, for the original H2 reason.
        let (sheetController, _) = mounted(scratch, name: "lock-editor-sheet", window: window) { store in
            _ = store.add(VaultCredential(title: "Prod DB", secret: "super-secret-value"))
        }
        sheetController.debugAddButton.performClick(nil)
        if sheetController.debugPresentedSheetCount == 1 {
            sheetController.debugLockTapped()
            check(sheetController.debugPresentedSheetCount == 0,
                  "locking must still dismiss the editor sheet, \(sheetController.debugPresentedSheetCount) left")
        } else {
            // A headless process cannot always establish a real sheet
            // presentation; say so rather than reporting a pass that asserted
            // nothing (`WhiteboardViewSelfTest`'s own convention for the half
            // of a claim its environment cannot reach).
            print("  NOTE: this process could not present a real sheet - skipping the editor-sheet check")
        }

        // ---- Defence in depth: a locked vault refuses a reveal ----
        //
        // The clear above is not the only thing standing between a locked vault
        // and a plaintext secret on screen - the panel holds its own copy of
        // the credential, so the page's own `onReveal` must refuse as well.
        //
        // Driven by calling **the page's real closure**, not by clicking the
        // panel's button and not against a copy of the guard written here.
        // Both of those were tried and both were vacuous: through the page the
        // button is unreachable, because `store.lock` re-renders and empties
        // the panel first; and a standalone panel handed a locally-written
        // `onReveal` asserts that the *test* has a guard, which passes happily
        // while the page has none (confirmed - removing the page's own
        // `store.isUnlocked` check did not fail that version).
        if let (controller, store) = selected("lock-panel-reveal"),
           let credential = store.credentials.first {
            store.lock(reason: "test")
            var verdict: Bool?
            controller.debugInspector.onReveal?(credential) { verdict = $0 }
            check(verdict == false,
                  "a locked vault must refuse a reveal, got \(String(describing: verdict))")
        }

        // ...and the same closure must still allow one when the vault is open,
        // or the refusal above would pass against a reveal that never works.
        if let (controller, store) = selected("unlocked-panel-reveal"),
           let credential = store.credentials.first {
            var verdict: Bool?
            controller.debugInspector.onReveal?(credential) { verdict = $0 }
            let deadline = Date().addingTimeInterval(5)
            while verdict == nil, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            check(verdict == true,
                  "an unlocked vault must still allow a reveal, got \(String(describing: verdict))")
            // The panel's own button is wired to that closure and renders the
            // result, which is the other half of the same claim.
            controller.debugInspector.debugRevealButton.performClick(nil)
            check(controller.debugInspector.debugIsRevealed,
                  "...and the panel's Reveal button should put it on screen")
        }
    }

    private static func checkSidebarDrivesTheFilter(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- the sidebar filters, counts and highlights --")
        let (controller, _) = mounted(scratch, name: "sidebar", window: window) { store in
            _ = store.add(VaultCredential(title: "Gmail", category: .email,
                                          account: "manjesh@gmail.com", secret: "a"))
            _ = store.add(VaultCredential(title: "Work email", category: .email,
                                          account: "manjesh.p@pramata.com", secret: "b"))
            _ = store.add(VaultCredential(title: "AWS root", category: .cloud, account: "root", secret: "c"))
            _ = store.add(VaultCredential(title: "GitHub PAT", category: .apiKey,
                                          account: "manjesh-raj", secret: "d", tags: ["ci"]))
        }
        let sidebar = controller.debugSidebar
        let list = controller.debugList
        func recordCount() -> Int {
            (0..<list.debugRowCount).filter { list.debugItem($0)?.isRecord == true }.count
        }

        // One "All credentials" row over one row per category, in the enum's
        // own order - so the sidebar's shape is a function of the model rather
        // than a hand-maintained list that can drift from it.
        check(sidebar.debugRowCount == CredentialCategory.allCases.count + 1,
              "the sidebar should have an All row plus one per category, got \(sidebar.debugRowCount)")
        check(sidebar.debugRowTitles.first == "All credentials",
              "the first row should be All credentials, got \(sidebar.debugRowTitles.first ?? "-")")
        check(sidebar.debugRowTitles.dropFirst() == ArraySlice(CredentialCategory.allCases.map(\.title)),
              "the collection rows should be the categories in order, got \(sidebar.debugRowTitles)")
        check(sidebar.debugHeaders == ["Vault", "Collections"],
              "the two section headers should be Vault and Collections, got \(sidebar.debugHeaders)")

        // Counts: the All row totals, each collection reports its own.
        check(sidebar.debugRowCounts.first == "4",
              "All credentials should count every credential, got \(sidebar.debugRowCounts.first ?? "-")")
        check(sidebar.debugRowCounts == ["4", "2", "1", "1", "0"],
              "each collection should report its own count, got \(sidebar.debugRowCounts)")

        // Clicking a collection filters the list *and* moves the highlight.
        let emailRow = 1
        sidebar.debugClickRow(emailRow)
        check(recordCount() == 2, "clicking Email should leave the two email credentials, got \(recordCount())")
        check(sidebar.debugSelectedIndex == emailRow,
              "clicking a row should select it, got \(String(describing: sidebar.debugSelectedIndex))")

        sidebar.debugClickRow(0)
        check(recordCount() == 4, "clicking All credentials should bring every record back, got \(recordCount())")
        check(sidebar.debugSelectedIndex == 0, "All credentials should be selected again")

        // The counts are scoped by the search, which is what makes the sidebar
        // navigation ("where are my matches") rather than a second copy of the
        // filter chips it replaced.
        controller.debugSetQuery("manjesh")
        check(sidebar.debugRowCounts == ["3", "2", "0", "1", "0"],
              "counts should be scoped by the current search, got \(sidebar.debugRowCounts)")
        controller.debugSetQuery("")
    }

    /// Selecting a credential fills the panel, and the panel shows the whole of
    /// every value it renders.
    ///
    /// **The truncation half is the point of the redesign, not a nicety.** The
    /// sheet this replaced put its content in `HelmFormSheet`'s capped, centred
    /// column, which at the sheet's own width resolved to roughly 190pt - so a
    /// real account rendered as `manjesh@...` and a real timestamp as
    /// `13 Sep 2...`. A field that cannot show its own value has stopped doing
    /// its job, so this asserts the rendered width against the width the text
    /// actually needs rather than merely that a label exists.
    private static func checkInspectorShowsWholeValues(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- the inspector fills from a row click and does not truncate --")
        let account = "manjesh.p@pramata.com"
        let location = "console.aws.amazon.com"
        let (controller, store) = mounted(scratch, name: "inspector", window: window) { store in
            _ = store.add(VaultCredential(title: "AWS root account", category: .cloud,
                                          account: account, secret: "aws-root-value",
                                          location: location, tags: ["prod", "critical"],
                                          notes: "Break-glass only."))
        }
        let inspector = controller.debugInspector
        check(inspector.credential == nil, "nothing should be selected on first render")
        check(inspector.debugIsEmptyStateShowing, "an unselected panel should show its empty state")

        guard let id = store.credentials.first?.id else {
            check(false, "the page needs a seeded credential")
            return
        }
        // Through the list's own selection, which is what a single click does -
        // not by calling the page's selector directly.
        let table = controller.debugList.debugTable
        guard let row = (0..<controller.debugList.debugRowCount)
            .first(where: { controller.debugList.debugItem($0)?.isRecord == true }) else {
            check(false, "there should be a record row to click")
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        check(inspector.credential?.id == id,
              "selecting a row should fill the inspector, got \(inspector.credential?.title ?? "-")")
        check(!inspector.debugIsEmptyStateShowing, "a filled panel should not show its empty state")
        check(controller.debugSelectedID == id, "the page should remember what is selected")

        // Every numbered section, in order, with the numbers the captain's
        // reference names. Notes is `03` only because this credential has some.
        check(inspector.debugSectionTitles == ["01 \u{00B7} Secret", "02 \u{00B7} Where it's used",
                                               "03 \u{00B7} Notes", "04 \u{00B7} History"],
              "the numbered sections should read in order, got \(inspector.debugSectionTitles)")

        // The values themselves, whole.
        let rendered = inspector.debugValueLabels
        check(rendered.contains { $0.stringValue == account },
              "the account should render, got \(rendered.map(\.stringValue))")
        check(rendered.contains { $0.stringValue == location },
              "the location should render, got \(rendered.map(\.stringValue))")
        for label in rendered where !label.stringValue.isEmpty {
            // `fittingSize` is what the text needs; `frame` is what it got. A
            // label narrower than its own need is one rendering an ellipsis.
            let needed = label.fittingSize.width
            check(label.frame.width + 0.5 >= needed,
                  "\"\(label.stringValue)\" is truncated: \(label.frame.width)pt for \(needed)pt of text")
        }

        // The half that actually catches it. A field hugging its own content
        // does not truncate either - it just sits in a narrow box beside empty
        // space, which is precisely what the old sheet's capped, centred column
        // produced and what "cramped" meant here. The property is that a field
        // *fills* the column, so a longer value than these still has the whole
        // of it.
        let columnWidth = inspector.debugContentWidth
        check(columnWidth > 200, "the panel's content column should have real width, got \(columnWidth)")
        for well in inspector.debugValueWells {
            check(abs(well.frame.width - columnWidth) < 1,
                  "a field should fill the panel's column: \(well.frame.width)pt in a \(columnWidth)pt column")
        }

        // Masked until asked, and the mask never leaks the secret's length.
        check(!inspector.debugIsRevealed, "a freshly selected credential starts masked")
        check(!inspector.debugSecretLabel.stringValue.contains("aws-root-value"),
              "the value must not be on screen before Reveal")

        // Closing the panel drops the selection without touching the store.
        inspector.debugCloseButton.performClick(nil)
        check(inspector.credential == nil, "the close button should empty the panel")
        check(controller.debugSelectedID == nil, "...and drop the page's selection")
        check(store.credentials.count == 1, "...and delete nothing")
    }

    /// A selection that stops being visible must not leave the panel showing a
    /// record the captain can no longer see beside it.
    private static func checkSelectionFollowsTheList(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- the selection follows what the list is showing --")
        let (controller, store) = mounted(scratch, name: "selection", window: window) { store in
            _ = store.add(VaultCredential(title: "Gmail", category: .email,
                                          account: "manjesh@gmail.com", secret: "a"))
            _ = store.add(VaultCredential(title: "AWS root", category: .cloud, account: "root", secret: "b"))
        }
        guard let aws = store.credentials.first(where: { $0.category == .cloud }) else {
            check(false, "the page needs a seeded credential")
            return
        }
        controller.debugSelectCredential(id: aws.id)
        check(controller.debugInspector.credential?.id == aws.id, "setup: the AWS credential is selected")

        // Filtered out by a search.
        controller.debugSetQuery("gmail")
        check(controller.debugInspector.credential == nil,
              "a credential filtered out of the list should drop out of the panel too")
        controller.debugSetQuery("")

        // Filtered out by a collection.
        controller.debugSelectCredential(id: aws.id)
        controller.debugSidebar.debugClickRow(1)
        check(controller.debugInspector.credential == nil,
              "a credential outside the selected collection should drop out of the panel")
        controller.debugSidebar.debugClickRow(0)

        // Deleted out from under the panel.
        controller.debugSelectCredential(id: aws.id)
        check(controller.debugInspector.credential != nil, "setup: selected again")
        _ = store.delete(id: aws.id)
        check(controller.debugInspector.credential == nil,
              "deleting the selected credential should empty the panel")
    }

    /// A record row's content has to fit the fixed `rowHeight` the table gives
    /// it - and this is a regression guard for a real defect this redesign
    /// introduced and then fixed, not a precaution.
    ///
    /// Dropping the per-row category kicker (the group header directly above
    /// every row already names it) meant passing `kicker: ""`, and
    /// `HelmAccentRow` rendered that as a full, empty text line: the kicker
    /// label was the one label in that component never hidden when empty, while
    /// `metaLabel` had been for its whole life. On a table with a fixed
    /// `rowHeight` an extra line is not empty space - it pushed the meta line
    /// past the card's bottom edge and clipped its descenders, so
    /// `manjesh@gmail.com` rendered with the tails of its `j` and `g` sliced
    /// off. Measured rather than eyeballed: the row's own fitting height
    /// against what the list gives it.
    private static func checkRecordRowFitsItsHeight(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- a record row's content fits the row it is given --")
        let (controller, _) = mounted(scratch, name: "rowfit", window: window) { store in
            // Descenders in both lines, and a long account, so a clipped or
            // overflowing row shows up rather than happening to fit.
            _ = store.add(VaultCredential(title: "Gmail, personal (jpg)", category: .email,
                                          account: "manjesh.p@pramata.com", secret: "a", tags: ["personal"]))
        }
        let list = controller.debugList
        guard let row = (0..<list.debugRowCount).first(where: { list.debugItem($0)?.isRecord == true }),
              let accentRow = list.debugAccentRow(row) else {
            check(false, "there should be a record row to measure")
            return
        }
        let given = CredentialVaultListSection.recordRowHeight
        let needed = accentRow.fittingSize.height
        check(needed > 0, "the measured row had no height at all")
        check(needed <= given,
              "a record row needs \(needed)pt but the list gives it \(given)pt - its meta line is clipped")

        // The structural half: the kicker is genuinely gone rather than drawn
        // in the background colour, which would leave the line paid for.
        check(accentRow.debugKickerText.isEmpty,
              "a vault row should carry no kicker - its group header names the category")
    }

    private static func checkUnreadableNeverOffersCreate(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- GL-01: an unreadable vault never offers to create a new one --")
        let root = scratch.appendingPathComponent("unreadable", isDirectory: true)
        let seed = CredentialVaultStore(root: root)
        _ = seed.createVault(masterPassword: "view-test-password")
        _ = seed.add(VaultCredential(title: "Real credential", secret: "real-value"))
        let intactSize = (try? Data(contentsOf: seed.fileURL))?.count ?? 0
        check(intactSize > 0, "precondition: a real vault file exists")

        try? Data("{ not json at all".utf8).write(to: seed.fileURL)
        let store = CredentialVaultStore(root: root)
        let controller = CredentialVaultController(store: store)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()

        check(controller.debugIsUnlockShowing, "an unreadable vault should show the gate, not the list")
        check(controller.drillHeaderSubtitle == "Unavailable",
              "the subtitle should say unavailable, got \(String(describing: controller.drillHeaderSubtitle))")
        // The load path backed the original aside rather than overwriting it.
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.contains(".corrupt-") } ?? []
        check(!backups.isEmpty, "GL-01: the unreadable file should have been backed up aside")

        // The one thing this state must never do: no create action anywhere in
        // the gate's live view tree. Walking the real tree rather than reading
        // a mode flag, because the flag being right is not the property that
        // protects the captain's credentials - the absent button is.
        var buttonTitles: [String] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, !button.isHiddenOrHasHiddenAncestor {
                buttonTitles.append(button.title)
            }
            view.subviews.forEach(walk)
        }
        walk(controller.debugUnlockView)
        let offersCreate = buttonTitles.contains { $0.lowercased().contains("create") }
        check(!offersCreate,
              "an unreadable vault must offer NO create action - it would write over real credentials. Visible buttons: \(buttonTitles)")
    }

    /// L3: the change-password section says that rotating the master password
    /// does not reach the old ciphertext already in the config repo's history.
    ///
    /// The re-key is all-or-nothing for the file on disk, but the vault is
    /// committed and pushed on every change - so every earlier commit still
    /// holds the old `vault.enc.json` under the old key, and the old password
    /// still opens *those*. Rewriting that history is not something this
    /// button can offer, so the captain has to be told: the common reason to
    /// rotate is a suspected leak, which is exactly the case where "future
    /// writes only" is not the protection they think they bought.
    ///
    /// Driven the same way `checkEditorRoundTrip` drives the editor - the
    /// sheet's `loadView` builds the whole form, no real presentation needed.
    private static func checkPasswordChangeWarnsAboutGitHistory(_ check: (Bool, String) -> Void) {
        print("\n-- the settings sheet's master-password warning --")
        let settings = CredentialVaultSettingsController(settings: .default,
                                                         auditEvents: [],
                                                         syncSummary: "Synced.",
                                                         touchIDAvailable: false)
        _ = settings.view
        let text = allLabelText(in: settings.view)

        // The warning itself. Asserted on the rendered text rather than on a
        // stored property, because a card built but never added to the tree
        // reads identically from the outside.
        check(text.contains(where: { $0.lowercased().contains("rotate the underlying secrets") }),
              "the section must tell the captain to rotate the secrets themselves after a suspected leak")
        check(text.contains(where: { $0.lowercased().contains("earlier commits") }),
              "...and say why - the old encrypted vault is still in the repo's history")

        // Next to the action, not three sections away: a warning the captain
        // has to scroll to find is one they will not read.
        guard let warning = text.firstIndex(where: { $0.lowercased().contains("earlier commits") }),
              let button = text.firstIndex(where: { $0 == "Change master password" }) else {
            // The button's title is drawn by `HelmButton`'s `attributedTitle`
            // rather than a child label, so it may not appear in a label
            // sweep. The warning above is the load-bearing half either way.
            print("  NOTE: the change button's title is not a scanned label - ordering not asserted")
            return
        }
        check(warning < button,
              "the warning precedes the action it is about, got warning at \(warning), button at \(button)")
    }

    /// Every non-empty label string in a view tree, in tree order.
    private static func allLabelText(in view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty { out.append(field.stringValue) }
        for sub in view.subviews { out.append(contentsOf: allLabelText(in: sub)) }
        return out
    }

    private static func checkEditorRoundTrip(_ check: (Bool, String) -> Void) {
        print("\n-- the editor sheet --")
        // Driven without presenting a real sheet: `loadView` builds the whole
        // form, and `onSave` is what the page consumes.
        let editor = CredentialVaultEditorController(editing: nil)
        _ = editor.view
        var saved: VaultCredential?
        editor.onSave = { saved = $0 }

        // An empty title is refused rather than saving a nameless record.
        editor.debugSave()
        check(saved == nil, "an empty title should be refused")

        editor.debugTitleField.stringValue = "Codacy API token"
        editor.debugSecretField.stringValue = "  token-with-spaces  "
        editor.debugNotesView.string = "Rotate every 90 days."
        editor.debugTagsInput.setTokens(["ci"])
        editor.debugTouchIDRow.isOn = true
        editor.debugSelectCategory(.apiKey)
        editor.debugSave()
        guard let saved else {
            check(false, "a titled credential should save")
            return
        }
        check(saved.title == "Codacy API token", "the title should round-trip")
        check(saved.category == .apiKey, "the category should round-trip")
        check(saved.tags == ["ci"], "tags should round-trip")
        check(saved.notes == "Rotate every 90 days.", "notes should round-trip")
        check(saved.requiresTouchIDToReveal, "the per-item Touch ID gate should round-trip")
        // The secret is deliberately NOT trimmed - whitespace can be part of a
        // real token, and silently altering a stored value is worse than
        // storing what was typed.
        check(saved.secret == "  token-with-spaces  ",
              "the secret must be stored exactly as typed, not trimmed, got \"\(saved.secret)\"")

        // The Show toggle is local to the form and moves the value between the
        // masked and plain fields rather than losing it.
        let editing = CredentialVaultEditorController(editing: saved)
        _ = editing.view
        check(editing.debugSecretField.stringValue == saved.secret, "editing should preload the secret")
        check(!editing.debugSecretIsVisible, "the secret should start masked even in the editor")
        editing.debugShowSecretButton.performClick(nil)
        check(editing.debugSecretIsVisible, "the Show button should unmask")
        check(editing.debugPlainSecretField.stringValue == saved.secret,
              "unmasking should carry the value across, not blank it")
        editing.debugPlainSecretField.stringValue = "edited-in-plain-view"
        var resaved: VaultCredential?
        editing.onSave = { resaved = $0 }
        editing.debugSave()
        check(resaved?.secret == "edited-in-plain-view",
              "a value edited while unmasked should be what saves, got \(String(describing: resaved?.secret))")
        check(resaved?.id == saved.id, "editing must keep the same id, not create a second record")
    }

    /// A captain-reported bug: the editor's "Require Touch ID to reveal" row
    /// and the settings sheet's "Unlock with Touch ID" row each once passed a
    /// second, separate switch into `HelmToggleRow`'s `trailing:` slot on top
    /// of the row's own built-in one - rendering two switches for one
    /// setting. `isOn` alone cannot see a stray extra control sitting beside
    /// the one actually wired up, so this walks the real, rendered view tree.
    private static func checkExactlyOneSwitchPerToggleRow(_ check: (Bool, String) -> Void) {
        print("\n-- exactly one switch per toggle row --")

        let editor = CredentialVaultEditorController(editing: nil)
        _ = editor.view
        let editorSwitches = countSwitchControls(in: editor.debugTouchIDRow)
        check(editorSwitches == 1,
              "the editor's Touch ID row should render exactly one switch, found \(editorSwitches)")

        let settings = CredentialVaultSettingsController(settings: .default,
                                                          auditEvents: [],
                                                          syncSummary: "Synced.",
                                                          touchIDAvailable: true)
        _ = settings.view
        let settingsSwitches = countSwitchControls(in: settings.debugTouchIDRow)
        check(settingsSwitches == 1,
              "the settings sheet's Touch ID row should render exactly one switch, found \(settingsSwitches)")
    }

    /// Every `NSSwitch`/`HelmToggle` in a view's subtree. `HelmToggle` is
    /// treated as one atomic control rather than recursed into - it builds an
    /// internal `NSSwitch` of its own (its pre-Daylight fallback shape), so
    /// counting that too would double-count a single, correctly-used
    /// `HelmToggle`.
    private static func countSwitchControls(in view: NSView) -> Int {
        if view is HelmToggle { return 1 }
        var count = view is NSSwitch ? 1 : 0
        for sub in view.subviews { count += countSwitchControls(in: sub) }
        return count
    }

    // MARK: The list is actually on screen

    /// The saved credential must be **visible**, not merely present in the
    /// data source.
    ///
    /// The captain's report: "In the top it says one credential saved.
    /// However, in the UI I am not able to see anything." Both halves of that
    /// were true at once, which is what made it hard to find - the store held
    /// the credential, `renderList` built the right rows, the table reported
    /// the right `numberOfRows`, and the drill subtitle said "1 credential".
    /// What was wrong was **geometry**: `HelmCard`'s vertical chain had two
    /// free heights against one equation for a headerless card whose body has
    /// no intrinsic height, and the solver resolved a 559pt-tall card's scroll
    /// view to `(12, 12, 1148, 0)`. See `HelmCard.headerCollapsed`.
    ///
    /// So this asserts the *shape on screen* rather than the model. A row
    /// count check alone passed throughout the bug - the rows were there - and
    /// so did every other case in this file.
    ///
    /// **It mounts a real `AppShellController`, and that is the whole reason
    /// it reproduces.** The defect was an ambiguity, so which way it resolved
    /// depended on the surrounding hierarchy: measured, the same page built
    /// standalone - with its frame set by hand, as every other case here does,
    /// or even pinned by constraints inside a plain host - resolved the
    /// harmless way and rendered fine, while the real shell resolved it the
    /// other way every time. `NSView.hasAmbiguousLayout` does not flag it
    /// either (measured: `false` on both sides of the fix), so there is no
    /// cheaper deterministic stand-in for the real thing.
    private static func checkListBodyFillsItsCard(_ check: (Bool, String) -> Void) {
        print("\n-- the list is on screen, not just in the data source --")
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 1220, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                         snippetStore: snippetStore, dictationStore: DictationStore()),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: ShiftStore(),
            dictationStore: DictationStore(), commandLibraryStore: CommandLibraryStore(),
            scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                 isFirstmateConsole: false) })
        window.contentViewController = shell
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        // The page defers everything privileged until the app is unlocked.
        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer { AppLockGate.shared.setLocked(wasLocked) }

        shell.show(.poneglyph)
        window.displayIfNeeded()
        shell.view.layoutSubtreeIfNeeded()

        let store = shell.debugPoneglyphStore
        let controller = shell.debugPoneglyph
        _ = store.createVault(masterPassword: "view-test-password")
        _ = store.add(VaultCredential(title: "Gmail", category: .email,
                                      account: "captain@example.com", secret: "s"))
        window.displayIfNeeded()
        shell.view.layoutSubtreeIfNeeded()

        let list = controller.debugList
        // The brief's own ask: the list's item count matches what the vault
        // reports. Kept even though it passed throughout the bug - it is the
        // half that would catch a future filter or reload defect.
        let records = (0..<list.debugRowCount).filter { list.debugItem($0)?.isRecord == true }
        check(records.count == store.credentials.count,
              "the list should render one record per stored credential, got \(records.count) for \(store.credentials.count)")
        check(controller.drillHeaderSubtitle?.hasPrefix("1 credential") == true,
              "the drill subtitle should report the one credential, got \(String(describing: controller.drillHeaderSubtitle))")

        // The half that actually catches it.
        guard let scroll = list.debugTable.enclosingScrollView else {
            check(false, "the list's table should be inside a scroll view")
            return
        }
        check(list.card.frame.height > 200,
              "the list card should have real height, got \(list.card.frame.height)")
        check(scroll.frame.height > list.card.frame.height / 2,
              "the list's scroll view should fill its card, got \(scroll.frame.height) inside a \(list.card.frame.height)pt card")
        guard let row = records.first else {
            check(false, "there should be a record row to look at")
            return
        }
        let rowRect = scroll.contentView.convert(list.debugTable.rect(ofRow: row), from: list.debugTable)
        check(scroll.contentView.bounds.intersects(rowRect),
              "the credential's row should be inside the visible rect, row \(rowRect) vs clip \(scroll.contentView.bounds)")
    }

    /// The component-level half of the same bug, and the deterministic one.
    ///
    /// A `HelmCard` with no header and a body that has no intrinsic height of
    /// its own - an `NSScrollView` has none at all - must still give that body
    /// the card. Asserted directly on `HelmCard` because the page-level case
    /// above depends on the surrounding hierarchy to resolve the ambiguity one
    /// way rather than the other, and this does not.
    private static func checkHeaderlessCardGivesItsBodyTheCard(_ check: (Bool, String) -> Void) {
        print("\n-- a headerless card gives its body the whole card --")
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let card = HelmCard()
        let scroll = NSScrollView()
        scroll.documentView = NSView()
        card.setBody(scroll, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        check(abs(scroll.frame.height - (card.frame.height - 24)) < 1,
              "a headerless card's body should be the card less its insets, got \(scroll.frame.height) inside \(card.frame.height)")

        // And a card that *does* have a header still gives the header its room
        // - the collapse must be lifted, not merely applied.
        let headed = HelmCard()
        let body = NSScrollView()
        body.documentView = NSView()
        headed.setHeader(symbol: "lock.fill", title: "Titled")
        headed.setBody(body)
        let host2 = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        host2.addSubview(headed)
        NSLayoutConstraint.activate([
            headed.leadingAnchor.constraint(equalTo: host2.leadingAnchor),
            headed.trailingAnchor.constraint(equalTo: host2.trailingAnchor),
            headed.topAnchor.constraint(equalTo: host2.topAnchor),
            headed.bottomAnchor.constraint(equalTo: host2.bottomAnchor),
        ])
        host2.layoutSubtreeIfNeeded()
        check(headed.headerContainer.frame.height > 20,
              "a card with a header should still give it room, got \(headed.headerContainer.frame.height)")
        check(body.frame.height > 200,
              "a headed card should still give its body the rest, got \(body.frame.height)")
    }

    private static func checkThemeSweep(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- theme sweep: the page forces its own appearance --")
        let (controller, _) = mounted(scratch, name: "theme", window: window) { store in
            _ = store.add(VaultCredential(title: "Themed credential", category: .email, secret: "v"))
        }
        // `daylight`/`dusk` and one legacy pair, which is the spread every
        // Daylight-era suite in this app sweeps.
        for id in ["daylight", "dusk", "helm-light", "helm-dark"] {
            guard let theme = HelmTheme.allThemes.first(where: { $0.id == id }) else {
                check(false, "theme \(id) should exist")
                continue
            }
            ThemeManager.shared.setTheme(theme)
            controller.view.layoutSubtreeIfNeeded()
            // The bug this catches is the one three destinations shipped with:
            // a page that never forces its root appearance re-themes only the
            // colours it paints itself, and leaves every system-resolved
            // surface (scroller chrome, menus, the shared field editor)
            // following the OS's light/dark instead.
            let expected: NSAppearance.Name = theme.mode == .dark ? .darkAqua : .aqua
            let actual = controller.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            check(actual == expected,
                  "\(id): the page's effectiveAppearance should be \(expected.rawValue), was \(String(describing: actual?.rawValue))")
            // And it still renders a real row rather than collapsing.
            check(firstRecordRow(controller.debugList) != nil,
                  "\(id): the list should still render its record row after a theme change")
        }
    }
}

#endif
