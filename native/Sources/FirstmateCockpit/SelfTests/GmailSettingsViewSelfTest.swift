// Manjesh Grand Line - native macOS app.
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
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.googleCalendarEnabled = savedCalendar
            GoogleAccountStore.shared = savedStore
            GoogleOAuthClientStore.shared.override = savedOverride
        }

        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        checkTheCategoryExistsAndCarriesTheCard(check)
        checkTheTwoSlotsAreIndependent(check)
        checkTheFourStates(check)
        checkTheClientIDFieldAndItsStatusLine(check)
        checkBothRegistersPaintLegibleText(check)
        checkNothingHereCapsTheWindow(check)

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
        check(SettingsController.Category.gmail.title == "Gmail",
              "and titled the way the captain named it")
        withMountedSettings { settings, _, _ in
            check(settings.debugSelectedCategory == .gmail, "selecting it should move the pane")
            check(settings.debugCardsInTree == 1,
                  "exactly the Gmail card should be mounted, got \(settings.debugCardsInTree)")
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
