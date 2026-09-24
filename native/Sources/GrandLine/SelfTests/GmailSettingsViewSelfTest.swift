// Grand Line - native macOS app.
//
// `fm/grandline-overview-layout-fix-gmail-settings`: the Gmail settings
// category, rendered.
//
// **Window-backed**, and listed in `NEEDS_SESSION` for the usual reason: it
// mounts a real `SettingsController` in a real `NSWindow` and asserts real
// laid-out geometry and real rendered text. The flow's own logic - PKCE, the
// exchange, the calendar merge - is `GoogleAccountsSelfTest`, which is pure
// and guards the blocking lane.
//
// What this file is actually for is the captain's own requirement, which is a
// *UI* property and cannot be asserted anywhere else: **two independent
// accounts, neither mandatory.** Every case here is some form of "one slot's
// state does not leak into the other's".

#if FM_SELFTESTS
import AppKit

enum GmailSettingsViewSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        let savedTheme = ThemeManager.shared.theme
        let savedCalendar = AppSettings.shared.googleCalendarEnabled
        let savedStore = GoogleAccountStore.shared
        let savedOverride = GoogleOAuthClientStore.shared.override
        let savedHealthTransport = GoogleCalendarHealthCheck.shared.transport
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.googleCalendarEnabled = savedCalendar
            GoogleAccountStore.shared = savedStore
            GoogleOAuthClientStore.shared.override = savedOverride
            GoogleCalendarHealthCheck.shared.transport = savedHealthTransport
            GoogleCalendarHealthCheck.shared.debugReset()
        }

        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        checkTheCategoryExistsAndCarriesTheCard(check)
        checkTheTwoSlotsAreIndependent(check)
        checkTheFourStates(check)
        checkTheClientIDFieldAndItsStatusLine(check)
        checkPastingAndClickingAwayCommits(check)
        checkBothFieldsAreMaskedUntilRevealed(check)
        checkTheRevealedHalfCommitsToo(check)
        checkBothRegistersPaintLegibleText(check)
        checkNothingHereCapsTheWindow(check)
        checkTheHealthLineIsSilentUntilChecked(check)
        checkASuccessfulReadSaysSo(check)
        checkAnAPIDisabledReadShowsGooglesOwnErrorAndItsLink(check)
        checkTestConnectionReachesTheRealCheck(check)
        checkTheHealthLineIsLegibleInBothRegisters(check)

        if failures.isEmpty {
            print("[GmailSettingsViewSelfTest] all checks passed")
            return true
        }
        print("[GmailSettingsViewSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }

    // MARK: Fixtures

    private static func withMountedSettings(_ body: (SettingsController, OffScreenProbeWindow,
                                                     InMemoryGoogleAccountStore) -> Void) {
        autoreleasepool {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("gmail-settings-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for (key, name) in [("FM_HOSTS_FILE", "hosts.json"), ("FM_KEYS_FILE", "keys.json"),
                                ("FM_SNIPPETS_FILE", "snippets.json"),
                                ("FM_DICTATION_DIR", "dictation")] {
                setenv(key, dir.appendingPathComponent(name).path, 1)
            }
            // The captain's real Keychain is never touched - `main.swift`'s
            // own `#if FM_SELFTESTS` block already swaps this, and swapping it
            // again here means a single-suite run by hand behaves the same.
            let store = InMemoryGoogleAccountStore()
            GoogleAccountStore.shared = store
            let settings = SettingsController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                              snippetStore: SnippetStore(),
                                              dictationStore: DictationStore())
            let window = OffScreenProbe.window(width: 1400, height: 900,
                                               styleMask: [.titled, .resizable])
            window.contentView = settings.view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            settings.select(.gmail)
            settings.view.layoutSubtreeIfNeeded()
            body(settings, window, store)
        }
    }

    private static func record(email: String, calendar: Bool = true) -> GoogleAccountRecord {
        GoogleAccountRecord(email: email, accessToken: "at", refreshToken: "rt",
                            accessTokenExpiry: Date().addingTimeInterval(3600),
                            grantedScopes: calendar ? GoogleOAuth.scopes : [GoogleOAuth.emailScope])
    }

    private static let clientID = GoogleAccountsSelfTest.clientID

    // MARK: 1 - it is a real category with a real card

    private static func checkTheCategoryExistsAndCarriesTheCard(_ check: (Bool, String) -> Void) {
        check(SettingsController.Category.allCases.contains(.gmail),
              "Gmail should be a settings category")
        // "Google Accounts", not "Gmail": the captain's own Settings
        // reference (`fm/grandline-settings-page-redesign`) names the page
        // that, and the page really is about the account rather than about
        // mail - the one consumer of a connected account is the daily
        // review's calendar column.
        check(SettingsController.Category.gmail.title == "Google Accounts",
              "and titled the way the captain's reference names it, got "
              + "\"\(SettingsController.Category.gmail.title)\"")
        withMountedSettings { settings, _, _ in
            check(settings.debugSelectedCategory == .gmail, "selecting it should move the pane")
            // Three sections now - Accounts, Calendar, OAuth client - each
            // one group card, which is the shape the redesign gave every
            // page. The claim is unchanged: the selected page's cards, and
            // only those, are on screen.
            check(settings.debugGroupCardsInTree == settings.debugSections(in: .gmail).count,
                  "exactly the Google Accounts page's cards should be mounted, got "
                  + "\(settings.debugGroupCardsInTree) of "
                  + "\(settings.debugSections(in: .gmail).count)")
            let rows = settings.debugGmailRows
            check(rows.count == 2, "two slots - work and personal, got \(rows.count)")
            check(rows.map(\.slot) == [.work, .personal], "in that order")
            // Really laid out, not merely constructed - the fixture's own
            // discriminating power for everything below.
            for row in rows {
                check(row.frame.width > 300 && row.frame.height > 20,
                      "\(row.slot.rawValue) should be laid out, got \(row.frame)")
            }
        }
    }

    // MARK: 2 - the two slots are independent

    /// The captain's own words: "work-mail and personal-mail, it's not
    /// mandatory to login to both". This is that sentence as a test.
    private static func checkTheTwoSlotsAreIndependent(_ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(
            GoogleOAuthConfiguration(clientID: clientID, clientSecret: nil))
        withMountedSettings { settings, _, store in
            func row(_ slot: GoogleAccountSlot) -> GmailAccountRow? {
                settings.debugGmailRows.first { $0.slot == slot }
            }
            // Neither connected, and that is a complete, valid state.
            settings.debugRefreshGmail()
            check(row(.work)?.debugState == .notConnected, "work starts unconnected")
            check(row(.personal)?.debugState == .notConnected, "so does personal")
            check(row(.work)?.debugActionIsEnabled == true,
                  "and both can be connected - neither is required first")

            try? store.save(record(email: "work@example.com"), for: .work)
            settings.debugRefreshGmail()
            check(row(.work)?.debugState == .connected(email: "work@example.com"),
                  "connecting work shows work's address, got "
                  + "\(String(describing: row(.work)?.debugState))")
            check(row(.personal)?.debugState == .notConnected,
                  "and personal is untouched - the slots share nothing")
            check(row(.work)?.debugActionTitle == "Disconnect",
                  "a connected row offers Disconnect")
            check(row(.personal)?.debugActionTitle == "Connect",
                  "while the other still offers Connect")
            check(row(.work)?.debugStatusText.contains("work@example.com") == true,
                  "the connected account's address is displayed, got "
                  + "\(row(.work)?.debugStatusText ?? "")")
            check(row(.personal)?.debugStatusText.contains("work@example.com") == false,
                  "and never on the other card")

            try? store.save(record(email: "me@example.com"), for: .personal)
            settings.debugRefreshGmail()
            check(row(.personal)?.debugState == .connected(email: "me@example.com"),
                  "both can be connected at once")

            // Disconnect one. The real button, not the private method.
            row(.work)?.debugPressAction()
            settings.debugRefreshGmail()
            check(store.record(for: .work) == nil, "pressing Disconnect really signs work out")
            check(row(.work)?.debugState == .notConnected, "and the row says so")
            check(store.record(for: .personal)?.email == "me@example.com",
                  "while personal is untouched - this is the whole point of two slots")
        }
    }

    // MARK: 3 - four states, not two

    private static func checkTheFourStates(_ check: (Bool, String) -> Void) {
        // No client id at all.
        GoogleOAuthClientStore.shared.override = .some(nil)
        withMountedSettings { settings, _, _ in
            settings.debugRefreshGmail()
            let row = settings.debugGmailRows[0]
            check(row.debugState == .notConfigured,
                  "with no client id the row says so rather than offering a Connect that "
                  + "fails at Google, got \(row.debugState)")
            check(row.debugStatusText.contains("OAuth client ID"),
                  "and names what is missing, got \(row.debugStatusText)")
        }

        // Signed in, but without the calendar scope. The state a two-state
        // row would have collapsed into "connected".
        GoogleOAuthClientStore.shared.override = .some(
            GoogleOAuthConfiguration(clientID: clientID, clientSecret: nil))
        withMountedSettings { settings, _, store in
            try? store.save(record(email: "work@example.com", calendar: false), for: .work)
            settings.debugRefreshGmail()
            let row = settings.debugGmailRows[0]
            check(row.debugState == .connectedWithoutCalendar(email: "work@example.com"),
                  "signed in without the calendar scope is its own state, got \(row.debugState)")
            check(row.debugStatusText.contains("calendar access was not granted"),
                  "and the row says what is wrong, got \(row.debugStatusText)")
            check(row.debugActionTitle == "Disconnect",
                  "it is still a connection, so the action is still Disconnect")
        }

        // The in-flight state, which is where a second click has to be
        // ignored rather than opening a second consent window.
        let busy = GmailAccountRow.state(record: nil, isConfigured: true, isBusy: true)
        check(busy == .connecting, "a sign-in in flight has its own state")
        check(GmailAccountRow.statusLine(for: busy, slot: .work).contains("Waiting"),
              "and says what it is waiting for")
    }

    // MARK: 4 - the client-id field

    private static func checkTheClientIDFieldAndItsStatusLine(_ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(nil)
        withMountedSettings { settings, _, _ in
            settings.debugRefreshGmail()
            check(settings.debugGmailStatusText.contains("No OAuth client ID"),
                  "the page states the gap, got \(settings.debugGmailStatusText)")
            check(settings.debugGmailClientIDField.stringValue.isEmpty,
                  "and ships with the field empty - a fake default would put a Connect "
                  + "button on the page that always fails")

            // Typing one through the field's real action.
            settings.debugGmailClientIDField.stringValue = clientID
            settings.debugCommitGmailClient()
            check(GoogleOAuth.configuration()?.clientID == clientID,
                  "committing the field should configure the client")
            check(settings.debugGmailStatusText.hasPrefix("Ready"),
                  "and the status line should change, got \(settings.debugGmailStatusText)")
            check(settings.debugGmailRows[0].debugState == .notConnected,
                  "and every row should leave `notConfigured` at once")

            // Clearing it.
            settings.debugGmailClientIDField.stringValue = ""
            settings.debugCommitGmailClient()
            check(GoogleOAuth.configuration() == nil, "clearing the field unconfigures it")
        }
    }

    // MARK: 4b - pasting, then clicking away

    /// The captain's own bug (`fm/grandline-gmail-oauth-field-not-saving`):
    /// paste a client ID, click somewhere else, and the value was silently
    /// lost.
    ///
    /// Plain AppKit target/action on an `NSTextField` fires on **Return** and
    /// on nothing else - not on focus loss - so a field wired with
    /// `target`/`action` alone and no delegate commits only for the captain
    /// who happens to press Return. Every other page on this controller goes
    /// through `configure(_:)`, which wires `delegate` as well; these two were
    /// wired by hand and did not.
    ///
    /// This case therefore refuses to use `debugCommitGmailClient()`: it
    /// drives the **real** field editor (which is why the suite is window
    /// backed - a field editor only exists inside a real window) and then
    /// moves first responder away, which is the exact sequence a paste plus a
    /// click elsewhere produces. Asserting the store afterwards is asserting
    /// what was *saved*, not what was computed.
    private static func checkPastingAndClickingAwayCommits(_ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(nil)
        withMountedSettings { settings, window, _ in
            // Both controls are masked by default, so the half a click lands
            // in - and the half with a field editor - is the secure one.
            // `visibleField` is what a real captain is typing into.
            let idControl = settings.debugGmailClientIDField
            let secretControl = settings.debugGmailClientSecretField
            let idField = idControl.visibleField
            let secretField = secretControl.visibleField

            // 1. Paste into the ID field through its real field editor.
            check(window.makeFirstResponder(idField),
                  "the client ID field should accept first responder in a real window")
            guard let editor = idField.currentEditor() else {
                check(false, "the client ID field has no field editor - the paste cannot be "
                      + "simulated, so every assertion below would be vacuous")
                return
            }
            editor.insertText(clientID)
            check(idControl.stringValue == clientID,
                  "the pasted text should reach the field, got \(idControl.stringValue)")
            // The discriminating half: nothing is saved *yet*, so a pass below
            // cannot come from a store that was already configured.
            check(GoogleOAuth.configuration() == nil,
                  "mid-edit, nothing is committed yet - otherwise this case proves nothing")

            // 2. Click away. No Return is ever sent.
            check(window.makeFirstResponder(secretField),
                  "focus should move to the next field, the way a click elsewhere moves it")
            check(GoogleOAuth.configuration()?.clientID == clientID,
                  "pasting and clicking away must save the client ID - got "
                  + "\(GoogleOAuth.configuration()?.clientID ?? "nothing")")

            // 3. The secret commits on blur too, and does not clobber the ID.
            guard let secretEditor = secretField.currentEditor() else {
                check(false, "the client secret field has no field editor")
                return
            }
            secretEditor.insertText("s3cret")
            window.makeFirstResponder(nil)
            check(GoogleOAuth.configuration()?.clientSecret == "s3cret",
                  "the client secret must commit on blur as well")
            check(GoogleOAuth.configuration()?.clientID == clientID,
                  "and committing the secret must leave the ID alone")

            // 4. The Return path still works - the fix adds to it rather than
            // replacing it, so this is the regression half of the case.
            GoogleOAuthClientStore.shared.override = .some(nil)
            settings.debugRefreshGmail()
            check(GoogleOAuth.configuration() == nil, "the store was reset for the Return case")
            check(window.makeFirstResponder(idField), "focus returns to the client ID field")
            idField.currentEditor()?.insertText(clientID)
            // `sendAction` is what Return does: it fires the field's own
            // target/action without ending the edit session.
            idField.sendAction(idField.action, to: idField.target)
            check(GoogleOAuth.configuration()?.clientID == clientID,
                  "Return still commits, got \(GoogleOAuth.configuration()?.clientID ?? "nothing")")
            window.makeFirstResponder(nil)
        }
    }

    // MARK: 4c - masked by default, revealed on demand

    /// The captain's ask: both OAuth fields hidden by default, with a button
    /// to show each one.
    ///
    /// Four properties, and the last is the one that makes this a *display*
    /// change rather than a storage one:
    ///
    ///   1. Both start masked - the visible half is the one whose cell is an
    ///      `NSSecureTextFieldCell`, which is what actually draws bullets.
    ///      Asserting `isRevealed == false` alone would pass against a
    ///      control that had lost its secure cell entirely.
    ///   2. The reveal toggle puts the real value on screen, in a field that
    ///      is *not* secure.
    ///   3. Toggling again re-masks it.
    ///   4. The two toggles are independent, and `GoogleOAuthClientStore`
    ///      holds the same strings throughout - masking never reaches the
    ///      store.
    /// Whether what is on screen is really drawn as bullets. `isRevealed` is
    /// this control's own bookkeeping; the cell is AppKit's.
    private static func masksItsText(_ field: NSTextField) -> Bool {
        (field.cell as? NSSecureTextFieldCell) != nil
    }

    private static func checkBothFieldsAreMaskedUntilRevealed(_ check: (Bool, String) -> Void) {
        let secret = "s3cret-value"
        GoogleOAuthClientStore.shared.override = .some(
            GoogleOAuthConfiguration(clientID: clientID, clientSecret: secret))
        withMountedSettings { settings, _, _ in
            settings.debugRefreshGmail()
            let idControl = settings.debugGmailClientIDField
            let secretControl = settings.debugGmailClientSecretField

            // The fixture's own discriminating power: there is something to
            // hide, and the two values differ, so a control showing the wrong
            // one cannot pass by coincidence.
            check(idControl.stringValue == clientID && secretControl.stringValue == secret,
                  "both controls should hold the stored pair before anything is toggled")
            check(clientID != secret, "the two fixture values must differ")

            for (name, control) in [("client ID", idControl), ("client secret", secretControl)] {
                check(!control.isRevealed, "the \(name) should start masked")
                check(control.visibleField === control.maskedField,
                      "the \(name)'s visible half should be the secure one")
                check(masksItsText(control.visibleField),
                      "the \(name)'s visible cell does not mask its text - it would render the "
                      + "value in the clear")
                check(control.plainField.isHidden,
                      "the \(name)'s plain half should be out of layout while masked")
                check(control.revealButton.title == "Show",
                      "the \(name)'s toggle should offer Show, got \(control.revealButton.title)")
            }

            // 2. Reveal the ID only. A real click through the button's own
            // target/action, not a direct call to the toggle.
            idControl.revealButton.performClick(nil)
            settings.view.layoutSubtreeIfNeeded()
            check(idControl.isRevealed, "clicking Show should reveal the client ID")
            check(idControl.visibleField === idControl.plainField,
                  "and put the plain half in layout")
            check(!masksItsText(idControl.visibleField),
                  "the revealed half must not mask its text, or nothing is shown")
            check(idControl.visibleField.stringValue == clientID,
                  "the revealed field should show the real value, got "
                  + "\(idControl.visibleField.stringValue)")
            check(idControl.revealButton.title == "Hide",
                  "and the toggle should now offer Hide")
            check(idControl.maskedField.isHidden, "the secure half leaves layout while revealed")

            // Independence: revealing one must not reveal the other.
            check(!secretControl.isRevealed,
                  "revealing the client ID must not reveal the client secret")
            check(masksItsText(secretControl.visibleField),
                  "the client secret stays behind its own secure cell")

            // 3. Toggling again re-masks.
            idControl.revealButton.performClick(nil)
            settings.view.layoutSubtreeIfNeeded()
            check(!idControl.isRevealed, "clicking again should re-mask the client ID")
            check(masksItsText(idControl.visibleField),
                  "and put the secure cell back on screen")
            check(idControl.stringValue == clientID,
                  "re-masking must not lose the value, got \(idControl.stringValue)")

            // The secret's own toggle, so neither is asserted only through
            // the other.
            secretControl.revealButton.performClick(nil)
            check(secretControl.isRevealed && !idControl.isRevealed,
                  "the two toggles are independent in both directions")
            check(secretControl.visibleField.stringValue == secret,
                  "the revealed secret should show the real value")

            // 4. Nothing above touched the store.
            check(GoogleOAuth.configuration()?.clientID == clientID,
                  "masking is display-only - the stored client ID must be untouched, got "
                  + "\(GoogleOAuth.configuration()?.clientID ?? "nothing")")
            check(GoogleOAuth.configuration()?.clientSecret == secret,
                  "and so must the stored client secret, got "
                  + "\(GoogleOAuth.configuration()?.clientSecret ?? "nothing")")
        }
    }

    /// The commit path, driven while the field is **revealed** - the half that
    /// `checkPastingAndClickingAwayCommits` never sees, and the one a masking
    /// change could silently leave unwired. Same shape as that case: a real
    /// field editor, then focus moved away, then the *store* is read.
    private static func checkTheRevealedHalfCommitsToo(_ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(nil)
        withMountedSettings { settings, window, _ in
            let idControl = settings.debugGmailClientIDField
            idControl.revealButton.performClick(nil)
            settings.view.layoutSubtreeIfNeeded()
            check(idControl.isRevealed, "the client ID should be revealed for this case")

            let field = idControl.visibleField
            check(window.makeFirstResponder(field),
                  "the revealed field should accept first responder")
            guard let editor = field.currentEditor() else {
                check(false, "the revealed field has no field editor - every assertion below "
                      + "would be vacuous")
                return
            }
            editor.insertText(clientID)
            check(GoogleOAuth.configuration() == nil,
                  "mid-edit, nothing is committed yet - otherwise this case proves nothing")
            window.makeFirstResponder(nil)
            check(GoogleOAuth.configuration()?.clientID == clientID,
                  "typing into the revealed half and clicking away must save it - got "
                  + "\(GoogleOAuth.configuration()?.clientID ?? "nothing")")

            // And the toggle itself carries a mid-edit value across the swap,
            // rather than showing the captain a stale one.
            GoogleOAuthClientStore.shared.override = .some(nil)
            settings.debugRefreshGmail()
            let secretControl = settings.debugGmailClientSecretField
            check(window.makeFirstResponder(idControl.visibleField),
                  "focus returns to the client ID field")
            idControl.visibleField.currentEditor()?.insertText(clientID)
            idControl.revealButton.performClick(nil)
            settings.view.layoutSubtreeIfNeeded()
            check(idControl.stringValue == clientID,
                  "toggling mid-edit must carry the typed text across, got "
                  + "\(idControl.stringValue)")
            check(secretControl.stringValue.isEmpty,
                  "and must not spill into the other control")
            window.makeFirstResponder(nil)
        }
    }

    // MARK: 5 - both registers

    /// The status line is tinted (green when connected, amber when not), and
    /// a `HelmTint` hue is safe as a fill and **not** automatically safe as
    /// text - so this asserts the painted colour clears the contrast floor
    /// against the surface the label actually lands on, in a Daylight theme
    /// and a legacy one.
    private static func checkBothRegistersPaintLegibleText(_ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(
            GoogleOAuthConfiguration(clientID: clientID, clientSecret: nil))
        withMountedSettings { settings, _, store in
            try? store.save(record(email: "work@example.com"), for: .work)
            try? store.save(record(email: "me@example.com", calendar: false), for: .personal)
            let daylight = HelmTheme.allThemes.first { $0.isDaylight } ?? ThemeManager.shared.theme
            let legacy = HelmTheme.allThemes.first { !$0.isDaylight } ?? ThemeManager.shared.theme
            for theme in [daylight, legacy] {
                ThemeManager.shared.setTheme(theme)
                settings.view.layoutSubtreeIfNeeded()
                settings.debugRefreshGmail()
                let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
                for row in settings.debugGmailRows {
                    guard let painted = row.debugStatusColor else {
                        check(false, "\(row.slot.rawValue) has no painted status colour")
                        continue
                    }
                    let ratio = HelmContrast.ratio(painted, surface)
                    check(ratio >= 4.5,
                          "\(row.slot.rawValue)'s status text is \(String(format: "%.2f", ratio)):1 "
                          + "against \(theme.id)'s card surface - the floor is 4.5")
                }
            }
        }
    }


    // MARK: 7 - the connection-health line
    //
    // `fm/grandline-google-calendar-connection-health`. The captain connected
    // an account, this page said "calendar readable", and every read failed -
    // with Google's most fixable error, which only appeared days later in the
    // daily review card's fine print on another page. These five cases are
    // about the real rendered row: that the verdict is there, that it is
    // Google's own words rather than a summary, and that the fix-it link is a
    // control a captain can actually press.

    private static let apiDisabledMessage = GoogleAccountsSelfTest.apiDisabledMessage
    private static let fixURLText = GoogleAccountsSelfTest.fixURLText

    /// A row that has never been checked shows nothing, rather than a
    /// permanent "unknown" line under every account.
    private static func checkTheHealthLineIsSilentUntilChecked(_ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(
            GoogleOAuthConfiguration(clientID: clientID, clientSecret: nil))
        GoogleCalendarHealthCheck.shared.transport = RefusingGoogleCalendarTransport()
        withMountedSettings { settings, _, store in
            GoogleCalendarHealthCheck.shared.debugReset()
            try? store.save(record(email: "work@example.com"), for: .work)
            settings.debugRefreshGmail()
            guard let row = settings.debugGmailRows.first(where: { $0.slot == .work }) else {
                check(false, "the work row should exist"); return
            }
            check(!row.debugHealthIsVisible,
                  "an unchecked account shows no health line, got \"\(row.debugHealthText)\"")
            // The affordance to ask is there even before there is an answer -
            // that is the whole difference from the state the captain was in.
            check(row.debugTestButtonIsVisible,
                  "but a connected account always offers Test connection")

            // And a *disconnected* row offers neither: there is nothing to
            // test and nothing a verdict could be about.
            guard let idle = settings.debugGmailRows.first(where: { $0.slot == .personal }) else {
                check(false, "the personal row should exist"); return
            }
            check(!idle.debugTestButtonIsVisible,
                  "a row with no account offers no connection to test")
        }
    }

    private static func checkASuccessfulReadSaysSo(_ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(
            GoogleOAuthConfiguration(clientID: clientID, clientSecret: nil))
        GoogleCalendarHealthCheck.shared.transport = RefusingGoogleCalendarTransport()
        withMountedSettings { settings, _, store in
            GoogleCalendarHealthCheck.shared.debugReset()
            try? store.save(record(email: "work@example.com"), for: .work)
            GoogleCalendarHealthCheck.shared.debugSet(.healthy(eventCount: 4), for: .work)
            settings.debugRefreshGmail()
            settings.view.layoutSubtreeIfNeeded()
            guard let row = settings.debugGmailRows.first(where: { $0.slot == .work }) else {
                check(false, "the work row should exist"); return
            }
            check(row.debugHealthIsVisible, "a checked account shows its verdict")
            let text = row.debugHealthText
            check(text.contains("read worked"),
                  "a success says the read worked, got \"\(text)\"")
            check(text.contains("4 events"),
                  "and how much came back, got \"\(text)\"")
            check(!row.debugFixButtonIsVisible,
                  "a success offers no fix-it button - there is nothing to fix")
            // The verdict is laid out, not merely stored: a health line with
            // no height on screen is the same gap in a different place.
            check(row.frame.height > 0, "and the row has real laid-out height")
        }
    }

    /// The captain's exact failure, rendered.
    private static func checkAnAPIDisabledReadShowsGooglesOwnErrorAndItsLink(
        _ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(
            GoogleOAuthConfiguration(clientID: clientID, clientSecret: nil))
        GoogleCalendarHealthCheck.shared.transport = RefusingGoogleCalendarTransport()
        withMountedSettings { settings, _, store in
            GoogleCalendarHealthCheck.shared.debugReset()
            try? store.save(record(email: "work@example.com"), for: .work)
            GoogleCalendarHealthCheck.shared.debugSet(
                .failed(message: apiDisabledMessage, fixURL: URL(string: fixURLText)), for: .work)
            settings.debugRefreshGmail()
            settings.view.layoutSubtreeIfNeeded()
            guard let row = settings.debugGmailRows.first(where: { $0.slot == .work }) else {
                check(false, "the work row should exist"); return
            }
            check(row.debugHealthIsVisible, "a failed read is shown on the row itself")
            let text = row.debugHealthText
            // The claim the whole task is about: the *real* sentence, whole.
            check(text.contains(apiDisabledMessage),
                  "Google's own message must be rendered in full, not summarised - got "
                  + "\"\(text)\"")
            check(text.contains(fixURLText),
                  "including the URL, so it is readable and copyable as text too")
            check(row.debugFixButtonIsVisible, "and the fix-it page is offered as a button")
            check(row.debugFixButtonTooltip == fixURLText,
                  "whose tooltip names where it goes, got "
                  + "\(row.debugFixButtonTooltip ?? "nil")")

            // The button must be *wired by the page*, not only by this suite -
            // gotcha (20)'s lesson, and the reason the handler is asserted
            // present before it is swapped for a recorder.
            check(row.onOpenFixURL != nil,
                  "SettingsController must wire the fix-it handler, or the button is decoration")
            var opened: URL?
            row.onOpenFixURL = { opened = $0 }
            row.debugPressFix()
            check(opened?.absoluteString == fixURLText,
                  "pressing it hands back Google's own URL, got \(opened?.absoluteString ?? "nil")")

            // A failure with no URL must not grow a button to nowhere.
            GoogleCalendarHealthCheck.shared.debugSet(
                .failed(message: "Request had invalid authentication credentials.", fixURL: nil),
                for: .work)
            settings.debugRefreshGmail()
            check(!row.debugFixButtonIsVisible,
                  "a message with no link offers no button")
            check(row.debugHealthText.contains("invalid authentication credentials"),
                  "but still says exactly what Google said")

            // And the line *above* must stop claiming the calendar is
            // readable. A green "calendar readable" over a red "read failed"
            // is the captain's original complaint moved one line up.
            GoogleCalendarHealthCheck.shared.debugSet(
                .failed(message: apiDisabledMessage, fixURL: URL(string: fixURLText)), for: .work)
            settings.debugRefreshGmail()
            check(!row.debugStatusText.contains("calendar readable"),
                  "a failed read must retract the \"calendar readable\" claim, got "
                  + "\"\(row.debugStatusText)\"")
            check(row.debugStatusText.contains("scope granted"),
                  "and say the part that is still true instead, got "
                  + "\"\(row.debugStatusText)\"")
            let theme = ThemeManager.shared.theme
            let good = HelmContrast.legibleTintedText(
                tintHex: HelmTint.good.hex(in: theme),
                over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
            // Compared element-wise: `HelmContrast.ratio(_:_:) < 1.01` is a
            // *luminance* comparison and would call two different hues equal
            // (AGENTS.md).
            check(HelmContrast.components(row.debugStatusColor ?? .black)
                  != HelmContrast.components(good),
                  "and must not still be painted in the success green")

            // The healthy case is the control: the green claim survives when
            // the read really did work, or this check proves nothing.
            GoogleCalendarHealthCheck.shared.debugSet(.healthy(eventCount: 1), for: .work)
            settings.debugRefreshGmail()
            check(row.debugStatusText.contains("calendar readable"),
                  "a working account still reads as readable, got "
                  + "\"\(row.debugStatusText)\"")
            check(HelmContrast.components(row.debugStatusColor ?? .black)
                  == HelmContrast.components(good),
                  "in the success green")
        }
    }

    /// The Test button reaches the real check, through the real control.
    ///
    /// A hook that called the controller's method would pass with the button
    /// unwired, which is how two rows in this app shipped dead (gotcha (20)).
    private static func checkTestConnectionReachesTheRealCheck(_ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(
            GoogleOAuthConfiguration(clientID: clientID, clientSecret: nil))
        let transport = GoogleAccountsSelfTest.StubCalendarTransport()
        transport.payload = GoogleAccountsSelfTest.apiDisabledPayload
        GoogleCalendarHealthCheck.shared.transport = transport
        withMountedSettings { settings, _, store in
            GoogleCalendarHealthCheck.shared.debugReset()
            try? store.save(record(email: "work@example.com"), for: .work)
            settings.debugRefreshGmail()
            guard let row = settings.debugGmailRows.first(where: { $0.slot == .work }) else {
                check(false, "the work row should exist"); return
            }
            let before = transport.calls.count
            row.debugPressTest()
            GoogleAccountsSelfTest.pump { transport.calls.count > before }
            check(transport.calls.count == before + 1,
                  "pressing Test connection issues one real read, got "
                  + "\(transport.calls.count - before)")
            // Not `debugHealthIsVisible`: the `.checking` state is visible
            // too, so waiting on visibility would read the in-flight line and
            // pass or fail on a race.
            GoogleAccountsSelfTest.pump { row.debugHealth != .checking }
            check(row.debugHealthText.contains(apiDisabledMessage),
                  "and the row repaints with what Google actually said, got "
                  + "\"\(row.debugHealthText)\"")
        }
    }

    /// Both registers, both verdicts. A `HelmTint` hue is safe as a fill and
    /// is not automatically safe as text, and a failure the captain cannot
    /// read is the defect this line exists to remove.
    private static func checkTheHealthLineIsLegibleInBothRegisters(
        _ check: (Bool, String) -> Void) {
        GoogleOAuthClientStore.shared.override = .some(
            GoogleOAuthConfiguration(clientID: clientID, clientSecret: nil))
        GoogleCalendarHealthCheck.shared.transport = RefusingGoogleCalendarTransport()
        withMountedSettings { settings, _, store in
            GoogleCalendarHealthCheck.shared.debugReset()
            try? store.save(record(email: "work@example.com"), for: .work)
            try? store.save(record(email: "me@example.com"), for: .personal)
            let daylight = HelmTheme.allThemes.first { $0.isDaylight } ?? ThemeManager.shared.theme
            let legacy = HelmTheme.allThemes.first { !$0.isDaylight } ?? ThemeManager.shared.theme
            let verdicts: [GoogleCalendarHealth] = [
                .healthy(eventCount: 2),
                .failed(message: apiDisabledMessage, fixURL: URL(string: fixURLText)),
            ]
            for theme in [daylight, legacy] {
                ThemeManager.shared.setTheme(theme)
                let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
                for verdict in verdicts {
                    for slot in GoogleAccountSlot.allCases {
                        GoogleCalendarHealthCheck.shared.debugSet(verdict, for: slot)
                    }
                    settings.debugRefreshGmail()
                    settings.view.layoutSubtreeIfNeeded()
                    for row in settings.debugGmailRows {
                        guard let painted = row.debugHealthColor else {
                            check(false, "\(row.slot.rawValue) has no painted health colour")
                            continue
                        }
                        let ratio = HelmContrast.ratio(painted, surface)
                        check(ratio >= 4.5,
                              "\(row.slot.rawValue)'s health line is "
                              + "\(String(format: "%.2f", ratio)):1 against \(theme.id)'s card "
                              + "surface for \(verdict) - the floor is 4.5")
                    }
                }
            }
        }
    }

    // MARK: 6 - gotcha (13)

    /// Nothing on this pane may become the window's minimum width. The two
    /// text fields are the risk: an `NSTextField`'s own compression
    /// resistance is above `NSLayoutPriorityWindowSizeStayPut` by default,
    /// which is exactly how Bootstrap's single-line labels once capped the
    /// whole window.
    private static func checkNothingHereCapsTheWindow(_ check: (Bool, String) -> Void) {
        withMountedSettings { settings, window, _ in
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 760, height: frame.height),
                            display: true)
            settings.view.layoutSubtreeIfNeeded()
            check(abs(window.frame.width - 760) < 1,
                  "the window should hold 760pt with the Gmail pane showing, got "
                  + "\(window.frame.width)")
            // The fixture's discriminating power: the pane must really be the
            // one showing, or this passes against any pane at all.
            check(settings.debugSelectedCategory == .gmail,
                  "and it should still be the Gmail pane that is mounted")
            for row in settings.debugGmailRows {
                check(row.frame.width <= 760,
                      "\(row.slot.rawValue) should have yielded rather than overflowed, got "
                      + "\(row.frame.width)")
            }
        }
    }
}
#endif
