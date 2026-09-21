// Manjesh Grand Line - native macOS app.
//
// F16/F17's window-backed half: the countdown ring on a real row, the
// generator and secure-note controls in the real Add sheet, the Recovery &
// import sheet driven end to end, and the menu-bar popover including the
// state it must refuse to show.
//
//   `FM_RUN_PONEGLYPH_TOTP_VIEW_TESTS=1 .build/debug/FirstmateCockpit`
//
// The pure half - RFC 6238, the generator's arithmetic, the recovery wrap and
// the CSV parsers - is `PoneglyphTOTPRecoverySelfTest`, which is in CI's
// blocking lane. This file is in `NEEDS_SESSION` because every case below
// mounts a real `NSWindow` and drives real `NSButton` target/actions.
//
// **The clock is fabricated, through the app's own one clock.**
// `TOTPTicker.shared.clock` is the single instant every TOTP surface reads
// (see `PoneglyphTOTPViews.swift`), so a suite can put it at a chosen second
// and assert the exact code and the exact ring fraction. It is restored in a
// `defer`, the same discipline `fm.themeID` gets - a leaked fabricated clock
// would make every later suite in the run measure a countdown from 2001.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum PoneglyphTOTPRecoveryViewSelfTest {

    /// A real base32 seed, and the instant the assertions below are written
    /// against. `TOTP.code` at this instant is deterministic, so the row's
    /// rendered text can be asserted exactly rather than by shape.
    private static let seed = "JBSWY3DPEHPK3PXP"
    private static let instant = Date(timeIntervalSince1970: 1_700_000_010)

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("poneglyph-totp-view-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let pasteboard = NSPasteboard.general
        let captainsClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let captainsClipboard { pasteboard.setString(captainsClipboard, forType: .string) }
        }

        let captainsTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(captainsTheme) }

        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        defer { AppLockGate.shared.setLocked(wasLocked) }

        TOTPTicker.shared.clock = { instant }
        defer { TOTPTicker.shared.debugResetClock() }

        let window = OffScreenProbe.window(width: 1200, height: 760, styleMask: [.titled, .resizable])
        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)

        checkRowRingAndCode(scratch: scratch, window: window, check)
        checkRowTicksWithTheClock(scratch: scratch, window: window, check)
        checkSecureNoteRow(scratch: scratch, window: window, check)
        checkEditorKindAndGenerator(check)
        checkEditorTOTPField(check)
        checkRecoverySheet(scratch: scratch, window: window, check)
        checkRecoveryKitRenders(check)
        checkImportFlow(scratch: scratch, window: window, check)
        checkMenuBarPopover(scratch: scratch, window: window, check)
        checkThemeSweep(scratch: scratch, window: window, check)

        window.contentView = nil
        if ok {
            print("PoneglyphTOTPRecoveryViewSelfTest: all checks passed")
            return true
        }
        print("PoneglyphTOTPRecoveryViewSelfTest: FAILED")
        return false
    }

    // MARK: Harness

    private static func mounted(_ scratch: URL,
                                name: String,
                                window: NSWindow,
                                seed seeder: (CredentialVaultStore) -> Void = { _ in })
        -> (controller: CredentialVaultController, store: CredentialVaultStore) {
        let root = scratch.appendingPathComponent(name, isDirectory: true)
        let store = CredentialVaultStore(root: root)
        _ = store.createVault(masterPassword: "poneglyph-view-test-password")
        seeder(store)
        let controller = CredentialVaultController(store: store)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        controller.viewDidAppear()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, store)
    }

    private static func firstRecordRow(_ list: CredentialVaultListSection) -> Int? {
        (0..<list.debugRowCount).first { list.debugItem($0)?.isRecord == true }
    }

    // MARK: F16 - the row

    private static func checkRowRingAndCode(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- a 2FA row draws the live code and a countdown ring --")
        let (controller, _) = mounted(scratch, name: "row", window: window) { store in
            var credential = VaultCredential(title: "AWS root", category: .cloud,
                                             account: "root@example.com", secret: "the-password")
            credential.totp = VaultTOTP(secret: seed)
            _ = store.add(credential)
        }
        let list = controller.debugList
        guard let row = firstRecordRow(list) else {
            check(false, "the page needs a record row")
            return
        }
        guard let ring = list.debugTOTPRing(row), let codeButton = list.debugTOTPCodeButton(row) else {
            check(false, "a credential with a 2FA seed must render a ring and a code button")
            return
        }
        let expected = TOTP.code(VaultTOTP(secret: seed), at: instant)
        check(expected != nil, "the fixture's own seed must produce a code")
        check(codeButton.title == TOTP.grouped(expected ?? ""),
              "the row must show the grouped code \(TOTP.grouped(expected ?? "")), got \(codeButton.title)")
        // The exact remaining seconds at this instant: 1700000010 mod 30 is
        // 0, so a full 30-second window has just started.
        check(ring.secondsText == "30", "the ring must show the whole window at a boundary, got \(ring.secondsText)")
        check(abs(ring.fraction - 1) < 0.001, "a fresh window must draw a full ring, got \(ring.fraction)")

        // Copy puts the code - not the password - on the clipboard, and does
        // so concealed. Both halves matter: a code that arrived unmarked
        // would be archived by the app's own clipboard history.
        NSPasteboard.general.clearContents()
        codeButton.performClick(nil)
        check(NSPasteboard.general.string(forType: .string) == expected,
              "clicking the code must copy the code itself, got \(NSPasteboard.general.string(forType: .string) ?? "nil")")
        check(CredentialVaultClipboard.isConcealed(),
              "a copied 2FA code must be marked concealed like every other vault value")

        // And it must not have copied the password instead - the failure
        // this pair exists to catch, since both are one click apart.
        check(NSPasteboard.general.string(forType: .string) != "the-password",
              "copying the code must never put the stored password on the clipboard")

        // A credential with no seed renders neither control - the
        // discriminating half, without which "the ring appeared" proves
        // nothing about it being driven by the data.
        let (plain, _) = mounted(scratch, name: "row-plain", window: window) { store in
            _ = store.add(VaultCredential(title: "No 2FA", secret: "x"))
        }
        if let plainRow = firstRecordRow(plain.debugList) {
            check(plain.debugList.debugTOTPRing(plainRow) == nil,
                  "a credential with no 2FA seed must draw no ring")
            check(plain.debugList.debugTOTPCodeButton(plainRow) == nil,
                  "...and no code button")
        } else {
            check(false, "the second fixture needs a record row")
        }
    }

    private static func checkRowTicksWithTheClock(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- the row's countdown follows the app's one clock --")
        let (controller, _) = mounted(scratch, name: "tick", window: window) { store in
            var credential = VaultCredential(title: "GitHub", secret: "p")
            credential.totp = VaultTOTP(secret: seed)
            _ = store.add(credential)
        }
        guard let row = firstRecordRow(controller.debugList),
              let ring = controller.debugList.debugTOTPRing(row),
              let button = controller.debugList.debugTOTPCodeButton(row) else {
            check(false, "the page needs a 2FA row")
            return
        }
        let firstCode = button.title
        check(ring.secondsText == "30", "setup: the window starts full")

        // 29 seconds later, still the same code, nearly empty ring.
        TOTPTicker.shared.clock = { instant.addingTimeInterval(29) }
        TOTPTicker.shared.tick()
        check(ring.secondsText == "1", "at 29s in, one second must remain, got \(ring.secondsText)")
        check(ring.fraction < 0.05, "the ring must be nearly empty, got \(ring.fraction)")
        check(button.title == firstCode, "the code must not change inside its own window")

        // One more second: a new window and a different code.
        TOTPTicker.shared.clock = { instant.addingTimeInterval(30) }
        TOTPTicker.shared.tick()
        check(ring.secondsText == "30", "a new window must reset the ring, got \(ring.secondsText)")
        check(button.title != firstCode, "the code must rotate at the boundary - it stayed \(button.title)")
        TOTPTicker.shared.clock = { instant }

        // The page unsubscribes when it goes off screen (GL-13). Asserted
        // through the ticker's own observer count, since a live timer on a
        // hidden page is exactly the defect.
        let before = TOTPTicker.shared.debugObserverCount
        controller.viewDidDisappear()
        check(TOTPTicker.shared.debugObserverCount == before - 1,
              "leaving the page must drop its ticker subscription, \(before) -> \(TOTPTicker.shared.debugObserverCount)")
    }

    private static func checkSecureNoteRow(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- a secure note row offers neither Reveal nor Copy --")
        let (controller, _) = mounted(scratch, name: "note", window: window) { store in
            var note = VaultCredential(title: "Bastion break-glass",
                                       secret: "Step 1\nStep 2\nStep 3")
            note.kind = .secureNote
            _ = store.add(note)
        }
        let list = controller.debugList
        guard let row = firstRecordRow(list), let item = list.debugItem(row) else {
            check(false, "the page needs a note row")
            return
        }
        check(item.reveal == nil, "a note must not offer Reveal - six lines do not fit a row")
        check(item.copy == nil, "a note must not offer Copy - prose on the pasteboard is the defect")
        check(list.debugRevealButton(row) == nil, "...and the Reveal button must not be rendered")
        check(list.debugCopyButton(row) == nil, "...nor the Copy button")
        let meta = item.content.meta ?? ""
        check(meta.contains("3 lines"),
              "the row must say how long the note is without showing it, got \(meta)")
        check(!meta.contains("Step 1"),
              "the row must never render the note's own contents: \(meta)")
    }

    // MARK: F16 - the editor

    private static func checkEditorKindAndGenerator(_ check: (Bool, String) -> Void) {
        print("\n-- the Add sheet's kind switch, generator and note body --")
        let editor = CredentialVaultEditorController(editing: nil)
        editor.loadView()
        editor.view.layoutSubtreeIfNeeded()

        check(editor.debugSecretRowIsShown, "a login must show the secret field")
        check(!editor.debugNoteBodyIsShown, "a login must not show the note body")
        check(editor.debugTOTPSectionIsShown, "a login must show the Two-factor section")

        editor.debugSelectKind(.secureNote)
        editor.view.layoutSubtreeIfNeeded()
        check(!editor.debugSecretRowIsShown, "a note must hide the one-line secret field")
        check(editor.debugNoteBodyIsShown, "a note must show the multi-line body")
        check(!editor.debugTOTPSectionIsShown, "a note must hide the Two-factor section, header included")
        check(!editor.debugGeneratorIsShown, "a note must never leave the password generator open")

        // A note saves its body into the same sealed `secret` field - the
        // claim that there is no parallel storage path for notes.
        var saved: VaultCredential?
        editor.onSave = { saved = $0 }
        editor.debugTitleField.stringValue = "Break glass"
        editor.debugNoteBodyView.string = "line one\nline two"
        editor.debugSave()
        check(saved?.kind == .secureNote, "the saved record must carry the note kind")
        check(saved?.secret == "line one\nline two",
              "a note's body must land in the sealed secret field, got \(saved?.secret ?? "nil")")

        // The generator.
        let login = CredentialVaultEditorController(editing: nil)
        login.loadView()
        login.view.layoutSubtreeIfNeeded()
        check(!login.debugGeneratorIsShown, "the generator must start closed")
        login.debugToggleGenerator()
        check(login.debugGeneratorIsShown, "the button must open the generator")

        let panel = login.debugGenerator
        let first = panel.debugValue
        check(!first.isEmpty, "the generator must produce a value as soon as it is shown")
        check(panel.debugStrengthText.contains("bits"),
              "the strength chip must state the entropy, got \(panel.debugStrengthText)")
        panel.debugRegenerate()
        check(panel.debugValue != first, "Regenerate must produce a different password")

        panel.debugSelectMode(.pin)
        check(panel.debugValue.allSatisfy(\.isNumber), "PIN mode must produce digits, got \(panel.debugValue)")
        check(panel.debugLengthText.contains("digits"),
              "the length label must say what it counts, got \(panel.debugLengthText)")
        panel.debugSelectMode(.words)
        check(panel.debugValue.contains("-"), "words mode must join with a separator, got \(panel.debugValue)")
        panel.debugSetLength(8)
        check(panel.debugLengthText == "8 words", "the slider must drive the label, got \(panel.debugLengthText)")

        // "Use this password" is the only write into the form - the
        // property `PasswordGeneratorPanel`'s header states.
        login.debugTitleField.stringValue = "Generated"
        let generated = panel.debugValue
        check(login.debugSecretField.stringValue.isEmpty,
              "generating must not have touched the secret field on its own")
        panel.debugPressUse()
        check(login.debugSecretField.stringValue == generated,
              "Use this password must fill the secret field, got \(login.debugSecretField.stringValue)")
        var savedLogin: VaultCredential?
        login.onSave = { savedLogin = $0 }
        login.debugSave()
        check(savedLogin?.secret == generated, "and the saved credential must carry it")
    }

    private static func checkEditorTOTPField(_ check: (Bool, String) -> Void) {
        print("\n-- the Two-factor field says what it parsed --")
        let editor = CredentialVaultEditorController(editing: nil)
        editor.loadView()

        editor.debugSetTOTPText("otpauth://totp/GitHub:me?secret=\(seed)&issuer=GitHub&digits=8&period=60")
        check(editor.debugTOTPStatusText.contains("GitHub"), "the status must name the issuer, got \(editor.debugTOTPStatusText)")
        check(editor.debugTOTPStatusText.contains("8 digits"), "...its digit count")
        check(editor.debugTOTPStatusText.contains("every 60s"), "...and its period")
        check(editor.debugTOTPStatusText.contains("code now"),
              "...and the live code, which is the only check that the seed is the RIGHT one")

        editor.debugSetTOTPText("definitely not base32 !!")
        check(editor.debugTOTPStatusText.contains("isn't a readable"),
              "an unreadable seed must say so rather than being stored, got \(editor.debugTOTPStatusText)")

        editor.debugSetTOTPText(seed)
        editor.debugTitleField.stringValue = "With 2FA"
        var saved: VaultCredential?
        editor.onSave = { saved = $0 }
        editor.debugSave()
        check(saved?.totp?.secret == seed, "a bare base32 seed must be saved, got \(saved?.totp?.secret ?? "nil")")

        // Switching to a note drops the seed rather than storing one nothing
        // would ever render.
        let note = CredentialVaultEditorController(editing: nil)
        note.loadView()
        note.debugSetTOTPText(seed)
        note.debugSelectKind(.secureNote)
        note.debugTitleField.stringValue = "A note"
        note.debugNoteBodyView.string = "body"
        var savedNote: VaultCredential?
        note.onSave = { savedNote = $0 }
        note.debugSave()
        check(savedNote?.totp == nil, "a secure note must never carry a 2FA seed")

        // The pasteboard refusal: a concealed clipboard is not read.
        let editor2 = CredentialVaultEditorController(editing: nil)
        editor2.loadView()
        _ = CredentialVaultClipboard.writeConcealed("otpauth://totp/x?secret=\(seed)", to: .general)
        editor2.debugPasteTOTP()
        check(editor2.debugTOTPField.stringValue.isEmpty,
              "Paste must refuse a concealed pasteboard, got \(editor2.debugTOTPField.stringValue)")
        check(editor2.debugTOTPStatusText.contains("concealed"),
              "...and must say why, got \(editor2.debugTOTPStatusText)")
        // The discriminating half: an ordinary pasteboard IS read, so the
        // refusal above is about the marker rather than about paste being
        // broken.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("otpauth://totp/x?secret=\(seed)", forType: .string)
        editor2.debugPasteTOTP()
        check(editor2.debugTOTPField.stringValue.contains(seed),
              "an unmarked pasteboard must paste normally, got \(editor2.debugTOTPField.stringValue)")
    }

    // MARK: F17 - the recovery sheet

    private static func checkRecoverySheet(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- the Recovery & import sheet prints a key --")
        let root = scratch.appendingPathComponent("recovery-sheet", isDirectory: true)
        let store = CredentialVaultStore(root: root)
        _ = store.createVault(masterPassword: "recovery-sheet-password")
        _ = store.add(VaultCredential(title: "Thing", secret: "v"))

        let sheet = CredentialVaultRecoverySheetController(store: store)
        window.contentView = sheet.view
        sheet.view.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
        sheet.view.layoutSubtreeIfNeeded()

        check(!sheet.debugCodeCardIsShown, "no code card before a key has been printed")
        check(sheet.debugRecoveryStatus.contains("no recovery key"),
              "the sheet must state the vault has none, got \(sheet.debugRecoveryStatus)")

        sheet.debugPrintNewKey()
        sheet.view.layoutSubtreeIfNeeded()
        check(sheet.debugCodeCardIsShown, "printing must show the card")
        guard let code = sheet.debugPrintedCode else {
            check(false, "the sheet must hold the code it just printed")
            return
        }
        check(CredentialVaultRecovery.looksWellFormed(code), "the printed code must be well formed: \(code)")
        check(sheet.debugCodeText.contains(" "), "the card must group the code for transcription: \(sheet.debugCodeText)")
        check(CredentialVaultRecovery.normalize(sheet.debugCodeText) == CredentialVaultRecovery.normalize(code),
              "the card must render the code that was actually enrolled")
        check(store.hasRecoveryKey, "the store must now carry a wrap")

        // The unlock screen offers the door only once a key exists - the
        // pairing that makes F17 usable rather than only implemented.
        let gate = CredentialVaultUnlockView()
        gate.setMode(.unlock(touchIDAvailable: false, recoveryAvailable: false))
        check(!gate.debugRecoveryLinkVisible, "a vault with no key must not offer the recovery door")
        gate.setMode(.unlock(touchIDAvailable: false, recoveryAvailable: true))
        check(gate.debugRecoveryLinkVisible, "a vault with a key must offer it")
        check(gate.debugPasswordFieldVisible && !gate.debugRecoveryFieldVisible,
              "the password field is still the default door")
        gate.debugClickRecoveryLink()
        check(gate.debugRecoveryFieldVisible && !gate.debugPasswordFieldVisible,
              "taking the recovery door must swap the field")
        check(gate.debugPrimaryTitle.contains("recovery"),
              "...and the button, got \(gate.debugPrimaryTitle)")
        // A short code is refused before a derivation runs, so a
        // transcription slip never burns an attempt against the throttle.
        var attempted = false
        gate.onUnlockWithRecoveryKey = { _ in attempted = true }
        gate.debugTypeRecoveryKey("ABC")
        gate.debugClickPrimary()
        check(!attempted, "an obviously short code must not reach the store")
        check(gate.debugMessageText.contains("32"), "...and must say what shape is expected, got \(gate.debugMessageText)")
        gate.debugTypeRecoveryKey(code)
        gate.debugClickPrimary()
        check(attempted, "a well-formed code must be handed to the store")
        gate.debugClickRecoveryLink()
        check(gate.debugPasswordFieldVisible && !gate.debugRecoveryFieldVisible,
              "backing out must restore the password door")

        // A session opened by recovery must not be asked for the password it
        // cannot know.
        let settings = CredentialVaultSettingsController(settings: .default, auditEvents: [],
                                                         syncSummary: "local", touchIDAvailable: false,
                                                         unlockedViaRecoveryKey: true)
        settings.loadView()
        check(!settings.debugCurrentPasswordFieldVisible,
              "a recovery-unlocked session must not be asked for the old master password")
        let ordinary = CredentialVaultSettingsController(settings: .default, auditEvents: [],
                                                         syncSummary: "local", touchIDAvailable: false)
        ordinary.loadView()
        check(ordinary.debugCurrentPasswordFieldVisible,
              "an ordinary session must still be asked for it - the gate is the security argument")
    }

    /// The printed card renders real content at page size.
    ///
    /// Asserted by **pixel**, not by "the view exists": a print view that
    /// draws nothing still lays out, still produces a PDF, and still passes
    /// every structural check. The fixture asserts its own discriminating
    /// power first - a blank page of the same size must read as blank - so a
    /// card that stops drawing fails here instead of passing vacuously.
    private static func checkRecoveryKitRenders(_ check: (Bool, String) -> Void) {
        print("\n-- the printable card actually draws --")
        let code = CredentialVaultRecovery.newCode()
        let kit = CredentialVaultRecoveryKitView(code: code, createdAt: Date(), vaultFileName: "vault.enc.json")

        let pdf = kit.pdfData()
        check(pdf.count > 1000, "the card's PDF must carry real content, got \(pdf.count) bytes")

        guard let rep = kit.bitmapImageRepForCachingDisplay(in: kit.bounds) else {
            check(false, "could not build a bitmap rep for the card")
            return
        }
        kit.cacheDisplay(in: kit.bounds, to: rep)
        // AGENTS.md: the rep is measured in PIXELS, not points - on a retina
        // machine that is a factor of two, and sampling point coordinates
        // would land in the top-left quadrant of the page.
        let scaleX = CGFloat(rep.pixelsWide) / kit.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / kit.bounds.height
        func inkAt(x: CGFloat, y: CGFloat) -> Bool {
            guard let colour = rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY)) else { return false }
            // Compared in the rep's own colour space, never via a conversion
            // to sRGB - the other rule that same section records.
            guard let converted = colour.usingColorSpace(rep.colorSpace) else { return false }
            return converted.brightnessComponent < 0.6
        }
        // The kicker line and the code block: two bands that must carry ink.
        let bands = stride(from: CGFloat(54), to: CGFloat(260), by: 4)
        let inked = bands.contains { y in
            stride(from: CGFloat(56), to: CGFloat(520), by: 4).contains { x in inkAt(x: x, y: y) }
        }
        check(inked, "the top third of the printed card must carry ink")
        // Discriminating power: the bottom margin is genuinely empty, so
        // "found ink" above means something.
        let bottomInked = stride(from: CGFloat(760), to: CGFloat(790), by: 4).contains { y in
            stride(from: CGFloat(56), to: CGFloat(520), by: 4).contains { x in inkAt(x: x, y: y) }
        }
        check(!bottomInked, "the page's bottom margin must be blank - otherwise the ink check proves nothing")

        // The card is drawn for paper: white ground regardless of the app's
        // theme, which is the whole reason it does not observe ThemeManager.
        let themeBefore = ThemeManager.shared.theme
        ThemeManager.shared.setTheme(HelmTheme.allThemes.first { $0.mode == .dark } ?? themeBefore)
        guard let darkRep = kit.bitmapImageRepForCachingDisplay(in: kit.bounds) else {
            check(false, "could not re-render the card under a dark theme")
            ThemeManager.shared.setTheme(themeBefore)
            return
        }
        kit.cacheDisplay(in: kit.bounds, to: darkRep)
        let corner = darkRep.colorAt(x: 4, y: 4)?.usingColorSpace(darkRep.colorSpace)
        check((corner?.brightnessComponent ?? 0) > 0.9,
              "the printed card must stay white under a dark theme, got \(corner?.brightnessComponent ?? -1)")
        ThemeManager.shared.setTheme(themeBefore)
    }

    // MARK: F17 - import

    private static func checkImportFlow(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- the import half, end to end into a real vault --")
        let root = scratch.appendingPathComponent("import-sheet", isDirectory: true)
        let store = CredentialVaultStore(root: root)
        _ = store.createVault(masterPassword: "import-sheet-password")

        let sheet = CredentialVaultRecoverySheetController(store: store)
        window.contentView = sheet.view
        sheet.view.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
        sheet.view.layoutSubtreeIfNeeded()

        check(!sheet.debugImportButtonEnabled, "nothing to import before a file is chosen")

        let csv = """
        Title,Url,Username,Password,OTPAuth,Tags,Notes
        Work Gmail,https://mail.google.com,me@example.com,pw1,otpauth://totp/G:me?secret=\(seed),work,
        AWS root,https://console.aws.amazon.com,root,pw2,,,
        ,,,,,,
        """
        sheet.debugLoadCSV(csv, named: "1password-export.csv")
        sheet.view.layoutSubtreeIfNeeded()
        check(sheet.debugImportSummary.contains("2 credentials"),
              "the summary must count the importable rows, got \(sheet.debugImportSummary)")
        check(sheet.debugImportSummary.contains("1 skipped"),
              "...and the skipped one, got \(sheet.debugImportSummary)")
        check(sheet.debugSkippedText.contains("Line 4"),
              "the skip must be reported with its line number, got \(sheet.debugSkippedText)")
        check(sheet.debugMappingRowCount == 7,
              "one mapping row per CSV column, got \(sheet.debugMappingRowCount)")
        check(sheet.debugImportButtonTitle == "Import 2 credentials",
              "the button must say what it will do, got \(sheet.debugImportButtonTitle)")

        sheet.debugRunImport()
        check(store.credentials.count == 2, "both rows must land in the vault, got \(store.credentials.count)")
        check(store.credentials.contains { $0.totp?.secret == seed },
              "the imported 2FA seed must survive into the sealed record")

        // The imported secret is genuinely encrypted on disk - the one claim
        // worth checking at the byte level rather than trusting the path.
        guard let bytes = store.rawFileBytesForTests(),
              let text = String(data: bytes, encoding: .utf8) else {
            check(false, "could not read the vault file back")
            return
        }
        check(!text.contains("pw1") && !text.contains("Work Gmail") && !text.contains(seed),
              "no imported value, title or 2FA seed may appear in the file on disk")

        // A second import of the same file, merging, must update rather than
        // duplicate - and without merging it must add.
        sheet.debugLoadCSV(csv, named: "1password-export.csv")
        check(sheet.debugSkippedText.contains("already in the vault"),
              "a re-import must flag the duplicates, got \(sheet.debugSkippedText)")
        sheet.debugSetMerge(true)
        sheet.debugRunImport()
        check(store.credentials.count == 2, "merging must not duplicate, got \(store.credentials.count)")
        sheet.debugLoadCSV(csv, named: "again.csv")
        sheet.debugSetMerge(false)
        sheet.debugRunImport()
        check(store.credentials.count == 4, "not merging must add second copies, got \(store.credentials.count)")
    }

    // MARK: F16 - the menu bar

    private static func checkMenuBarPopover(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- the menu-bar quick-copy popover --")
        let (controller, store) = mounted(scratch, name: "menubar", window: window) { store in
            var aws = VaultCredential(title: "AWS root", account: "root@example.com", secret: "pw")
            aws.totp = VaultTOTP(secret: seed)
            _ = store.add(aws)
            _ = store.add(VaultCredential(title: "No 2FA", secret: "pw"))
        }
        let menuBar = PoneglyphMenuBarController()
        menuBar.codesProvider = { controller.quickCodeEntries }
        menuBar.vaultIsUnlocked = { controller.isVaultUnlocked }
        menuBar.onCopy = { controller.copyQuickCode(id: $0) }

        menuBar.debugPrepareToShow()
        let content = menuBar.debugContent
        check(content.debugRowCount == 1,
              "only the credential with a 2FA seed belongs in the popover, got \(content.debugRowCount)")
        check(content.debugTitles == ["AWS root"], "the row must name the credential, got \(content.debugTitles)")
        let expected = TOTP.code(VaultTOTP(secret: seed), at: instant)
        check(content.debugCodeTexts == [TOTP.grouped(expected ?? "")],
              "the row must show the live code, got \(content.debugCodeTexts)")
        check(content.debugSecondsTexts == ["30"], "...and the countdown, got \(content.debugSecondsTexts)")
        check(content.debugIsTicking, "an open popover must be subscribed to the ticker")

        NSPasteboard.general.clearContents()
        content.debugPressCopy(0)
        check(NSPasteboard.general.string(forType: .string) == expected,
              "the popover's copy must put the code on the clipboard, got \(NSPasteboard.general.string(forType: .string) ?? "nil")")
        check(CredentialVaultClipboard.isConcealed(), "...concealed, like every other vault copy")
        check(content.debugFlashText(0) == "Copied",
              "the row must confirm in place - a popover has no Toast host, got \(content.debugFlashText(0))")
        check(store.auditLog.contains { $0.kind == .copied },
              "a code copied from the menu bar must be audited exactly like one copied in the window")

        // A locked vault is a different state from an empty one (GL-14).
        store.lock(reason: "self-test")
        menuBar.debugPrepareToShow()
        check(content.debugRowCount == 0, "a locked vault must show no codes")
        check(content.debugEmptyText.contains("locked"),
              "...and must say it is locked rather than that there are none, got \(content.debugEmptyText)")

        // GL-09: locked app, no popover at all. Driven through the real
        // click path, which is only safe while locked - see
        // `debugIconClicked`'s own note.
        AppLockGate.shared.setLocked(true)
        if menuBar.debugHasStatusButton {
            menuBar.debugIconClicked()
            check(!menuBar.debugPopover.isShown, "a locked app must refuse to open the popover at all")
        }
        AppLockGate.shared.setLocked(false)

        // And the gate is a real, distinct case rather than a shared one.
        check(AppLockedSurface.poneglyphMenuBarPopover != AppLockedSurface.strawHatMenuBarPopover,
              "Poneglyph's menu-bar gate must be its own case")
    }

    // MARK: Themes

    private static func checkThemeSweep(scratch: URL, window: NSWindow, _ check: (Bool, String) -> Void) {
        print("\n-- the new surfaces render under a light and a dark theme --")
        let light = HelmTheme.allThemes.first { $0.mode == .light }
        let dark = HelmTheme.allThemes.first { $0.mode == .dark }
        guard let light, let dark else {
            check(false, "the app must offer a light and a dark theme")
            return
        }
        for theme in [light, dark] {
            ThemeManager.shared.setTheme(theme)
            let (controller, store) = mounted(scratch, name: "theme-\(theme.id)", window: window) { store in
                var credential = VaultCredential(title: "AWS root", secret: "v")
                credential.totp = VaultTOTP(secret: seed)
                _ = store.add(credential)
            }
            controller.view.layoutSubtreeIfNeeded()
            guard let row = firstRecordRow(controller.debugList),
                  let ring = controller.debugList.debugTOTPRing(row) else {
                check(false, "\(theme.id): the 2FA row must render")
                continue
            }
            check(ring.frame.width > 0 && ring.frame.height > 0,
                  "\(theme.id): the ring must have a real frame, got \(ring.frame)")

            let sheet = CredentialVaultRecoverySheetController(store: store)
            sheet.view.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
            sheet.view.layoutSubtreeIfNeeded()
            sheet.debugPrintNewKey()
            sheet.view.layoutSubtreeIfNeeded()
            check(!sheet.debugCodeText.isEmpty, "\(theme.id): the sheet must render its code card")

            let panel = PasswordGeneratorPanel()
            panel.applyTheme(theme)
            panel.layoutSubtreeIfNeeded()
            check(!panel.debugValue.isEmpty, "\(theme.id): the generator must render a value")
        }
    }
}

#endif
