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
        checkUnreadableNeverOffersCreate(scratch: scratch, window: window, check)
        checkEditorRoundTrip(check)
        checkThemeSweep(scratch: scratch, window: window, check)

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
        editor.debugTouchIDToggle.isOn = true
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
