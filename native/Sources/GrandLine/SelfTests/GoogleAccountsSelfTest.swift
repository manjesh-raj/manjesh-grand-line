// Grand Line - native macOS app.
//
// `fm/grandline-overview-layout-fix-gmail-settings`: the Google sign-in
// flow's own coverage.
//
// **Pure logic, no window, no network, no Google, no Keychain.** Every piece
// that can be computed is computed here - PKCE, the authorization URL, the
// redirect parsing, the token response, the record merge, the calendar JSON,
// the two-source merge - and the two pieces that cannot (the browser and the
// HTTP round trip) are replaced by stubs, which is what lets the *whole*
// sign-in be driven end to end without a real client id.
//
// So it is deliberately **not** in `NEEDS_SESSION`: it guards the blocking CI
// lane. The card's own rendering is `GmailSettingsViewSelfTest`, which is.
//
// The one thing it cannot assert is that Google accepts any of this, and the
// PR says so rather than implying otherwise.

#if FM_SELFTESTS
// `AppKit` only for the `NSWindow?` in `GoogleConsentPresenting`'s signature -
// nothing here builds a view, a window or a responder. AGENTS.md's own rule:
// the test is what a suite *asserts*, never what it imports, which is why this
// file is not in `NEEDS_SESSION`.
import AppKit
import Foundation

enum GoogleAccountsSelfTest {

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        checkPKCE(check)
        checkAuthorizationURL(check)
        checkRedirectParsing(check)
        checkTokenParsing(check)
        checkRecordMerge(check)
        checkStoreRoundTrip(check)
        checkTheWholeSignIn(check)
        checkCalendarParsing(check)
        checkCalendarAvailabilityStates(check)
        checkTheTwoSourceMerge(check)
        checkReadOnlyByScope(check)
        checkStatusLines(check)
        checkTheAPIFailureEnvelope(check)
        checkTheHealthVerdict(check)
        checkTheHealthCheckEndToEnd(check)
        checkTheDailyReviewCardIsUnchanged(check)
        checkTheKeychainCachesSurviveTheRenameMigration(check)

        if failures.isEmpty {
            print("[GoogleAccountsSelfTest] all checks passed")
            return true
        }
        print("[GoogleAccountsSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }

    /// Turn the main run loop until `condition` holds, or give up.
    ///
    /// Every completion in this flow hops to main (`GoogleSignInController`'s
    /// own contract), and a headless suite has nothing turning the loop - so a
    /// stubbed, entirely synchronous round trip still lands one tick later.
    /// Bounded, so a wiring mistake fails the case rather than hanging the
    /// run.
    @discardableResult
    static func pump(until condition: () -> Bool, seconds: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    // MARK: Fixtures

    /// A client id of the shape Google issues, so `looksWellFormed` and the
    /// derived redirect scheme are exercised against a realistic value rather
    /// than against "test".
    static let clientID = "1234567890-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com"
    static var configuration: GoogleOAuthConfiguration {
        GoogleOAuthConfiguration(clientID: clientID, clientSecret: "GOCSPX-fixture")
    }

    /// A transport that answers with canned bodies, and records what it was
    /// asked - so the exchange's own fields can be asserted, which is the
    /// half a response fixture cannot see.
    final class StubTransport: GoogleOAuthTransport {
        var responses: [Data] = []
        private(set) var calls: [(url: URL, fields: [String: String])] = []
        var error: Error?

        func postForm(to url: URL, fields: [String: String],
                      completion: @escaping (Result<Data, Error>) -> Void) {
            calls.append((url, fields))
            if let error { completion(.failure(error)); return }
            completion(.success(responses.isEmpty ? Data() : responses.removeFirst()))
        }
    }

    final class StubPresenter: GoogleConsentPresenting {
        var result: Result<URL, GoogleOAuthError>?
        /// Built from the request, so a suite can answer with the *right*
        /// state rather than a hard-coded one.
        var respond: ((URL) -> Result<URL, GoogleOAuthError>)?
        private(set) var presentedURL: URL?
        private(set) var presentedScheme: String?

        func present(url: URL, callbackScheme: String, from window: NSWindow?,
                     completion: @escaping (Result<URL, GoogleOAuthError>) -> Void) {
            presentedURL = url
            presentedScheme = callbackScheme
            let answer = respond?(url) ?? result ?? .failure(.cancelled)
            completion(answer)
        }
    }

    final class StubCalendarTransport: GoogleCalendarTransport {
        var payload = Data()
        var error: Error?
        private(set) var calls: [(url: URL, token: String)] = []

        func get(_ url: URL, accessToken: String,
                 completion: @escaping (Result<Data, Error>) -> Void) {
            calls.append((url, accessToken))
            if let error { completion(.failure(error)); return }
            completion(.success(payload))
        }
    }

    static func record(email: String = "captain@example.com",
                       scopes: [String] = GoogleOAuth.scopes,
                       expiresIn: TimeInterval = 3600) -> GoogleAccountRecord {
        GoogleAccountRecord(email: email, accessToken: "access-token",
                            refreshToken: "refresh-token",
                            accessTokenExpiry: Date().addingTimeInterval(expiresIn),
                            grantedScopes: scopes)
    }

    // MARK: 1 - PKCE

    private static func checkPKCE(_ check: (Bool, String) -> Void) {
        let a = GoogleOAuth.makeChallenge()
        let b = GoogleOAuth.makeChallenge()
        // The fixture's own discriminating power: if two challenges were the
        // same, everything below would still pass and the protection would be
        // gone.
        check(a.verifier != b.verifier, "two challenges must not share a verifier")
        check(a.state != b.state, "two challenges must not share a CSRF state")
        // base64url, unpadded - RFC 7636 accepts nothing else, and a "+" or a
        // "=" here is rejected by Google with an opaque `invalid_request`.
        for value in [a.verifier, a.challenge, a.state] {
            check(!value.contains("+") && !value.contains("/") && !value.contains("="),
                  "\"\(value)\" is not base64url - it must carry no +, / or =")
        }
        // 32 random bytes -> 43 base64url characters, RFC 7636 §4.1's own
        // recommended length.
        check(a.verifier.count == 43, "the verifier should be 43 characters, got \(a.verifier.count)")
        check(a.challenge.count == 43, "the S256 challenge should be 43 characters, got \(a.challenge.count)")
        check(a.challenge != a.verifier,
              "the challenge must be the verifier's hash, not the verifier - sending the "
              + "verifier up front would defeat PKCE entirely")
    }

    // MARK: 2 - the authorization request

    private static func checkAuthorizationURL(_ check: (Bool, String) -> Void) {
        let challenge = GoogleOAuth.makeChallenge()
        let redirect = GoogleOAuth.redirectURI(for: configuration)
        check(redirect == "com.googleusercontent.apps.1234567890-abcdefghijklmnopqrstuvwxyz012345:/oauth2redirect",
              "the redirect should be the reversed client id, got \(redirect)")
        let url = GoogleOAuth.authorizationURL(configuration: configuration,
                                               redirectURI: redirect, challenge: challenge,
                                               loginHint: "work@example.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        check(url.host == "accounts.google.com", "the consent screen must be Google's own host")
        check(value("code_challenge_method") == "S256",
              "PKCE must be S256 - `plain` sends the verifier in the clear")
        check(value("code_challenge") == challenge.challenge, "the challenge should be sent")
        check(value("code_verifier") == nil,
              "the verifier must NOT be in the authorization URL - it is the secret half")
        check(value("state") == challenge.state, "the CSRF state should be sent")
        check(value("access_type") == "offline",
              "without access_type=offline Google returns no refresh token and the "
              + "connection dies silently an hour later")
        check(value("prompt")?.contains("consent") == true,
              "prompt=consent is the other half of getting a refresh token back")
        check(value("prompt")?.contains("select_account") == true,
              "the two slots need select_account, or both cards end up naming one account")
        check(value("login_hint") == "work@example.com",
              "a re-connect should offer the account it already had")
        // The scopes. Read-only, and nothing beyond what the feature needs -
        // this is the check that fails if somebody widens them.
        let scopes = Set((value("scope") ?? "").split(separator: " ").map(String.init))
        check(scopes == Set([GoogleOAuth.emailScope, GoogleOAuth.calendarReadonlyScope]),
              "this app asks for exactly the read-only calendar and the address, got \(scopes)")
        check(!scopes.contains("https://www.googleapis.com/auth/calendar"),
              "the writable calendar scope must never be requested")

        // No hint on a first connect.
        let plain = GoogleOAuth.authorizationURL(configuration: configuration,
                                                 redirectURI: redirect, challenge: challenge)
        let plainItems = URLComponents(url: plain, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(!plainItems.contains { $0.name == "login_hint" },
              "a first connect should carry no login hint")
    }

    // MARK: 3 - the redirect

    private static func checkRedirectParsing(_ check: (Bool, String) -> Void) {
        let state = "the-state"
        func parse(_ string: String) -> Result<String, GoogleOAuthError> {
            GoogleOAuth.authorizationCode(from: URL(string: string)!, expectedState: state)
        }
        if case .success(let code) = parse("com.example:/oauth2redirect?code=abc&state=the-state") {
            check(code == "abc", "the code should come back, got \(code)")
        } else {
            check(false, "a well-formed redirect should yield its code")
        }
        // The CSRF check, and the reason this parameter exists at all.
        if case .failure(let error) = parse("com.example:/oauth2redirect?code=abc&state=someone-elses") {
            check(error == .stateMismatch, "a wrong state should be a state mismatch, got \(error)")
        } else {
            check(false, "a redirect whose state does not match must be REJECTED, not accepted")
        }
        if case .failure(let error) = parse("com.example:/oauth2redirect?error=access_denied&state=the-state") {
            check(error == .cancelled, "access_denied reads as a cancel, got \(error)")
        } else {
            check(false, "a denied consent should not look like a success")
        }
        if case .failure = parse("com.example:/oauth2redirect?state=the-state") {} else {
            check(false, "a redirect with no code at all should fail")
        }
    }

    // MARK: 4 - the token response

    private static func checkTokenParsing(_ check: (Bool, String) -> Void) {
        // A real `id_token` shape: three dot-separated base64url segments,
        // with the middle one carrying the claims.
        let claims = Data(#"{"email":"captain@example.com","sub":"1"}"#.utf8)
        let idToken = "header.\(GoogleOAuth.base64URL(claims)).signature"
        let json = """
        {"access_token":"at-1","refresh_token":"rt-1","expires_in":3599,
         "scope":"\(GoogleOAuth.emailScope) \(GoogleOAuth.calendarReadonlyScope)",
         "id_token":"\(idToken)"}
        """
        switch GoogleOAuth.parseTokenResponse(Data(json.utf8)) {
        case .failure(let error):
            check(false, "a well-formed token response should parse, got \(error)")
        case .success(let response):
            check(response.accessToken == "at-1", "the access token should be read")
            check(response.refreshToken == "rt-1", "the refresh token should be read")
            check(response.expiresIn == 3599, "the expiry should be read, got \(response.expiresIn)")
            check(response.email == "captain@example.com",
                  "the address should come off the id_token, got \(response.email ?? "nil")")
            check(response.grantedScopes.contains(GoogleOAuth.calendarReadonlyScope),
                  "the granted scopes should be read")
        }

        // Google's own error shape, which arrives with HTTP 400 and a body.
        switch GoogleOAuth.parseTokenResponse(Data(#"{"error":"invalid_grant","error_description":"Bad Request"}"#.utf8)) {
        case .success: check(false, "an error body must not parse as a token")
        case .failure(let error):
            check(error.errorDescription?.contains("Bad Request") == true,
                  "Google's own explanation should reach the captain, got \(error)")
        }
        switch GoogleOAuth.parseTokenResponse(Data("not json".utf8)) {
        case .success: check(false, "a non-JSON body must not parse as a token")
        case .failure: break
        }

        // The form body. `URLComponents` leaves `+` unescaped in a query, and
        // `+` decodes to a space in a form body - which silently corrupts a
        // base64 verifier. This is that check.
        let body = GoogleOAuth.formBody(["code_verifier": "a+b/c=d", "client_id": "x y"])
        check(!body.contains("+") && !body.contains("/") && !body.contains("=d"),
              "every form value must be fully percent-encoded, got \(body)")
        check(body.contains("client_id=x%20y"), "a space must be encoded, got \(body)")
    }

    // MARK: 5 - the record merge

    private static func checkRecordMerge(_ check: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = GoogleAccountRecord(email: "captain@example.com", accessToken: "old",
                                           refreshToken: "keep-me",
                                           accessTokenExpiry: now,
                                           grantedScopes: GoogleOAuth.scopes,
                                           connectedAt: now.addingTimeInterval(-86_400))
        // Google's re-consent: a new access token, and NO refresh token.
        let response = GoogleTokenResponse(accessToken: "new", refreshToken: nil,
                                           expiresIn: 3600, grantedScopes: GoogleOAuth.scopes,
                                           email: nil)
        let merged = GoogleOAuth.record(merging: response, into: existing, now: now)
        check(merged.accessToken == "new", "the new access token should win")
        check(merged.refreshToken == "keep-me",
              "a response with no refresh token must KEEP the stored one - dropping it is "
              + "how a connection stops working an hour later, got \(merged.refreshToken ?? "nil")")
        check(merged.email == "captain@example.com",
              "no id_token should keep the address already on file, got \(merged.email)")
        check(merged.connectedAt == existing.connectedAt,
              "a refresh is not a new connection")
        check(merged.accessTokenExpiry == now.addingTimeInterval(3600),
              "the expiry should be now plus expires_in")

        // First connect: nothing to merge into.
        let fresh = GoogleOAuth.record(merging: GoogleTokenResponse(
            accessToken: "a", refreshToken: "r", expiresIn: 120,
            grantedScopes: [GoogleOAuth.emailScope], email: "new@example.com"),
                                        into: nil, now: now)
        check(fresh.email == "new@example.com", "a first connect takes the id_token's address")
        check(!fresh.canReadCalendar,
              "an account that granted only the email scope cannot read a calendar - "
              + "this is the state the card has to distinguish from 'connected'")

        // Freshness, with the slack that stops a call arriving expired.
        check(!fresh.accessTokenIsFresh(at: now.addingTimeInterval(90)),
              "a token with 30 seconds left must be treated as stale")
        check(fresh.accessTokenIsFresh(at: now),
              "a token with a full minute of slack left is usable")
    }

    // MARK: 6 - the store

    private static func checkStoreRoundTrip(_ check: (Bool, String) -> Void) {
        let store = InMemoryGoogleAccountStore()
        check(store.record(for: .work) == nil, "an empty store has no work account")
        check(store.connectedSlots.isEmpty, "and no connected slots")
        do { try store.save(record(email: "work@example.com"), for: .work) } catch {
            check(false, "saving should not throw: \(error)")
        }
        // The independence the captain asked for, asserted rather than
        // assumed: this is what "not mandatory to login to both" means in
        // code.
        check(store.record(for: .work)?.email == "work@example.com", "work should round-trip")
        check(store.record(for: .personal) == nil,
              "connecting work must leave personal alone")
        do { try store.save(record(email: "me@example.com"), for: .personal) } catch {
            check(false, "saving the second slot should not throw: \(error)")
        }
        check(store.connectedSlots.count == 2, "both slots can be connected at once")
        store.remove(.work)
        check(store.record(for: .work) == nil, "signing work out removes it")
        check(store.record(for: .personal)?.email == "me@example.com",
              "and must not touch personal")

        // GL-01: a record written by a build that did not have a field must
        // still decode. Every key but `email` is omitted here.
        let sparse = Data(#"{"email":"old@example.com"}"#.utf8)
        do {
            let decoded = try JSONDecoder.googleAccounts.decode(GoogleAccountRecord.self, from: sparse)
            check(decoded.email == "old@example.com", "a sparse record should still decode")
            check(decoded.grantedScopes.isEmpty, "with its missing fields defaulted")
            check(!decoded.accessTokenIsFresh(), "and an absent expiry reads as stale, not fresh")
        } catch {
            check(false, "a record missing every optional key must still decode (GL-01): \(error)")
        }
    }

    // MARK: 7 - the whole sign-in, end to end

    /// Drives `GoogleSignInController` with both halves stubbed, which is the
    /// only way to assert the wiring between them.
    private static func checkTheWholeSignIn(_ check: (Bool, String) -> Void) {
        let controller = GoogleSignInController.shared
        let store = InMemoryGoogleAccountStore()
        let presenter = StubPresenter()
        let transport = StubTransport()
        let previousStore = GoogleAccountStore.shared
        let previousOverride = GoogleOAuthClientStore.shared.override
        GoogleAccountStore.shared = store
        GoogleOAuthClientStore.shared.override = .some(configuration)
        let previousPresenter = controller.presenter
        let previousTransport = controller.transport
        controller.presenter = presenter
        controller.transport = transport
        defer {
            GoogleAccountStore.shared = previousStore
            GoogleOAuthClientStore.shared.override = previousOverride
            controller.presenter = previousPresenter
            controller.transport = previousTransport
        }

        // The presenter answers with the state the request actually carried,
        // so this exercises the real round trip rather than a fixed value.
        presenter.respond = { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            return .success(URL(string: "com.example:/oauth2redirect?code=the-code&state=\(state)")!)
        }
        transport.responses = [Data("""
        {"access_token":"at","refresh_token":"rt","expires_in":3600,
         "scope":"\(GoogleOAuth.emailScope) \(GoogleOAuth.calendarReadonlyScope)"}
        """.utf8)]

        var result: Result<GoogleAccountRecord, GoogleOAuthError>?
        controller.signIn(slot: .work, from: nil) { result = $0 }
        check(pump { result != nil }, "the stubbed sign-in should complete")
        if case .success(let record)? = result {
            check(record.accessToken == "at", "the token should be stored")
            check(store.record(for: .work)?.refreshToken == "rt",
                  "and persisted through the store, not just handed back")
        } else {
            check(false, "the stubbed sign-in should succeed, got \(String(describing: result))")
        }
        check(presenter.presentedScheme == GoogleOAuth.redirectScheme(for: configuration),
              "the session must listen on the redirect scheme the request used")

        // The exchange's own fields - the half a response fixture cannot see.
        let exchange = transport.calls.first
        check(exchange?.url == GoogleOAuth.tokenEndpoint, "the exchange goes to Google's token endpoint")
        check(exchange?.fields["code_verifier"] != nil,
              "the exchange must carry the PKCE verifier - without it PKCE protects nothing")
        check(exchange?.fields["grant_type"] == "authorization_code", "with the right grant type")
        check(exchange?.fields["client_secret"] == "GOCSPX-fixture",
              "and the client secret when one is configured")

        // A cancelled consent must not write anything.
        store.remove(.work)
        presenter.respond = { _ in .failure(.cancelled) }
        var cancelled: Result<GoogleAccountRecord, GoogleOAuthError>?
        controller.signIn(slot: .work, from: nil) { cancelled = $0 }
        pump { cancelled != nil }
        if case .failure(let error)? = cancelled {
            check(error == .cancelled, "a cancelled consent reads as cancelled, got \(error)")
        } else {
            check(false, "a cancelled consent must not succeed")
        }
        check(store.record(for: .work) == nil, "and must store nothing")

        // No client id is a stated gap, and it must not open a browser.
        GoogleOAuthClientStore.shared.override = .some(nil)
        var unconfigured: Result<GoogleAccountRecord, GoogleOAuthError>?
        let before = presenter.presentedURL
        controller.signIn(slot: .personal, from: nil) { unconfigured = $0 }
        pump { unconfigured != nil }
        if case .failure(let error)? = unconfigured {
            check(error == .notConfigured, "no client id reads as not configured, got \(error)")
        } else {
            check(false, "sign-in with no client id must fail rather than open a browser")
        }
        check(presenter.presentedURL == before,
              "and must not have presented anything at all")
    }

    // MARK: 8 - the calendar

    private static func checkCalendarParsing(_ check: (Bool, String) -> Void) {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {"items":[
          {"summary":"Cancelled thing","status":"cancelled",
           "start":{"dateTime":"2023-11-14T10:00:00Z"}},
          {"summary":"Platform standup","status":"confirmed",
           "start":{"dateTime":"2023-11-14T10:00:00Z"},
           "attendees":[{"email":"a"},{"email":"b"},{"email":"c"}],
           "hangoutLink":"https://meet.google.com/x"},
          {"summary":"Company holiday","start":{"date":"2023-11-14"}},
          {"start":{"dateTime":"2023-11-14T17:00:00Z"},"location":"Room 4\\nBuilding 2"}
        ]}
        """
        switch GoogleDailyReviewCalendar.parse(Data(json.utf8), day: day) {
        case .unavailable(let reason):
            check(false, "a well-formed events list should parse, got \(reason)")
        case .available(let rows), .partial(let rows, _):
            check(rows.count == 3,
                  "a cancelled event must be dropped - a briefing that lists a meeting the "
                  + "captain is no longer expected at is worse than one that omits it, got \(rows.count)")
            check(rows.first?.isAllDay == true,
                  "all-day events sort first, the same order the EventKit source uses")
            check(rows.first?.timeText == "all day", "and read as \"all day\"")
            let standup = rows.first { $0.title == "Platform standup" }
            check(standup != nil, "the named event should be there")
            check(standup?.detail == "3 attendees",
                  "attendees should be counted, got \(standup?.detail ?? "nil")")
            let untitled = rows.first { $0.title == "Untitled event" }
            check(untitled != nil, "an event with no summary gets a real title, not an empty one")
            check(untitled?.detail == "Room 4",
                  "a multi-line location is trimmed to its first line, got \(untitled?.detail ?? "nil")")
            check(rows.allSatisfy { $0.colorHex == nil },
                  "a Google row carries no colour - Google's colorId is an index into a "
                  + "palette this app does not have, and guessing a hex would be worse")
        }

        // Google's error shape.
        switch GoogleDailyReviewCalendar.parse(
            Data(#"{"error":{"code":403,"message":"Insufficient Permission"}}"#.utf8), day: day) {
        case .available, .partial: check(false, "an error body must not parse as an empty day (GL-14)")
        case .unavailable(let reason):
            check(reason.contains("Insufficient Permission"),
                  "Google's own message should reach the captain, got \(reason)")
        }

        // The request. Bounded to one local day, expanded, ordered.
        let url = GoogleDailyReviewCalendar.eventsURL(for: day)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        check(value("singleEvents") == "true",
              "recurring events must be expanded, or a weekly standup arrives as a rule")
        check(value("orderBy") == "startTime", "and ordered")
        check(value("timeMin") != nil && value("timeMax") != nil, "and bounded to one day")
        check(url.path.hasSuffix("/events"), "the one request shape is events.list, got \(url.path)")
    }

    private static func checkCalendarAvailabilityStates(_ check: (Bool, String) -> Void) {
        let day = Date()
        let store = InMemoryGoogleAccountStore()
        let previous = GoogleAccountStore.shared
        GoogleAccountStore.shared = store
        defer { GoogleAccountStore.shared = previous }

        let source = GoogleDailyReviewCalendar(slot: .work)

        // Not connected.
        check(source.access == .notDetermined, "no account means no access")
        check(source.events(on: day).unavailableReason?.contains("not connected") == true,
              "and a stated reason rather than an empty day")

        // Connected, but the calendar scope was not granted.
        try? store.save(record(scopes: [GoogleOAuth.emailScope]), for: .work)
        check(source.events(on: day).unavailableReason?.contains("did not grant") == true,
              "signed in without the calendar scope is its own stated gap, "
              + "got \(source.events(on: day).unavailableReason ?? "available")")

        // Connected and granted, but nothing read yet. **This is the GL-14
        // check**: the source caches, so before the first refresh there is no
        // snapshot - and no snapshot is not an empty day.
        try? store.save(record(), for: .work)
        switch source.events(on: day) {
        case .available(let rows), .partial(let rows, _):
            check(false, "an unread calendar must NOT report \(rows.count) events - "
                  + "\"not read yet\" and \"nothing on\" are different sentences (GL-14)")
        case .unavailable(let reason):
            check(reason.contains("has not been read yet"),
                  "and the reason should say so, got \(reason)")
        }

        // Now read it.
        let transport = StubCalendarTransport()
        transport.payload = Data("""
        {"items":[{"summary":"1:1 with Priya","start":{"dateTime":"2023-11-14T17:00:00Z"}}]}
        """.utf8)
        source.transport = transport
        var refreshed = false
        source.refresh(for: day) { _ in refreshed = true }
        check(pump { refreshed }, "the stubbed refresh should complete")
        check(transport.calls.first?.token == "access-token",
              "the read must carry the stored bearer token")
        check(source.events(on: day).value?.count == 1,
              "and the snapshot should then serve the column")

        // An empty day, once read, IS an empty day - the other side of GL-14,
        // and the check that stops the rule being applied too hard.
        transport.payload = Data(#"{"items":[]}"#.utf8)
        var reread = false
        source.refresh(for: day) { _ in reread = true }
        pump { reread }
        check(source.events(on: day).value?.isEmpty == true,
              "a calendar that was read and is empty reports an empty day, not a gap")

        // A stale snapshot from another day must not be served as today.
        let tomorrow = day.addingTimeInterval(24 * 60 * 60)
        check(source.events(on: tomorrow).value == nil,
              "yesterday's snapshot is not today's calendar")
    }

    private static func checkTheTwoSourceMerge(_ check: (Bool, String) -> Void) {
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let dayStart = Calendar.current.startOfDay(for: day)
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        }
        // B16: the *localised* strings deliberately, because that is what the
        // merge used to sort on - "1:00 PM" < "9:00 AM" in every 12-hour
        // locale, so the afternoon meeting came out first. The fixture's own
        // discriminating power, asserted before the merge is: if these two
        // strings did not order the wrong way round, the check below could
        // not fail however the merge sorted.
        let afternoonText = "1:00 PM"
        let morningText = "9:00 AM"
        check(afternoonText < morningText,
              "fixture: the two time strings must sort the WRONG way round as strings, "
              + "or this check cannot see a string sort at all")

        let mac = StubCalendar(result: .available([
            DailyReviewEventRow(title: "Mac event", timeText: afternoonText, detail: "",
                                colorHex: "FF0000", isAllDay: false, startsAt: at(13)),
        ]))
        let google = StubCalendar(result: .available([
            DailyReviewEventRow(title: "Google event", timeText: morningText, detail: "",
                                colorHex: nil, isAllDay: false, startsAt: at(9)),
        ]))
        let both = CompositeDailyReviewCalendar(sources: [mac, google])
        let rows = both.events(on: day).value ?? []
        check(rows.count == 2, "both sources contribute, got \(rows.count)")
        check(rows.first?.title == "Google event",
              "and the merged list is re-sorted by real start time - two sorted lists "
              + "concatenated are not a sorted list, and the display string is localised "
              + "(B16), got \(rows.map(\.title))")

        // All-day still leads, whatever the times say.
        let allDay = StubCalendar(result: .available([
            DailyReviewEventRow(title: "Offsite", timeText: "all day", detail: "",
                                colorHex: nil, isAllDay: true, startsAt: at(0)),
        ]))
        let withAllDay = CompositeDailyReviewCalendar(sources: [mac, allDay, google])
        check((withAllDay.events(on: day).value ?? []).map(\.title)
                == ["Offsite", "Google event", "Mac event"],
              "all-day first, then by start time, got "
              + "\((withAllDay.events(on: day).value ?? []).map(\.title))")

        // One source fails. Its reason must survive - as a *gap*, never as a
        // row (B16: it used to be appended as a fake untitled event, which the
        // composer then counted toward `maxEvents` and truncated away).
        let broken = StubCalendar(result: .unavailable("work mail could not be read"))
        let mixed = CompositeDailyReviewCalendar(sources: [mac, broken])
        switch mixed.events(on: day) {
        case .unavailable(let reason):
            check(false, "one working source should still show its events, got \(reason)")
        case .available:
            check(false, "a source that could not be read must not read as a clean answer (GL-14)")
        case .partial(let merged, let reason):
            check(merged.contains { $0.title == "Mac event" }, "the working source's events show")
            check(merged.count == 1,
                  "and the gap is NOT one of the rows - the captain's event count must be "
                  + "the number of events, got \(merged.map(\.title))")
            check(reason == "work mail could not be read",
                  "and the broken one's REASON is not swallowed - the captain must be able "
                  + "to tell \"nothing on\" from \"one of your two calendars failed\" (GL-14), "
                  + "got \(reason)")
        }

        // And the composer files that gap where every other stated gap goes,
        // rather than rendering it as an event.
        var inputs = DailyReviewInputs()
        inputs.now = day
        inputs.calendar = mixed.events(on: day)
        let digest = DailyReviewComposer.digest(from: inputs)
        let composedTitles = digest.events.map { $0.title }
        check(composedTitles == ["Mac event"],
              "composer: a partial calendar renders its real events only, got \(composedTitles)")
        check(digest.gaps.contains { $0.section == "Calendar"
                && $0.reason == "work mail could not be read" },
              "composer: and states the gap in the gaps list, got "
              + "\(digest.gaps.map { $0.section + ": " + $0.reason })")
        check(digest.hiddenEventCount == 0,
              "composer: a gap must not inflate the \"+N more\" count, got \(digest.hiddenEventCount)")

        // Everything off.
        let allBroken = CompositeDailyReviewCalendar(sources: [
            StubCalendar(result: .unavailable("a")), StubCalendar(result: .unavailable("b")),
        ])
        check(allBroken.events(on: day).unavailableReason == "a; b",
              "with nothing readable the column states every reason")
        check(allBroken.access == .notDetermined, "and reports no access")
        check(CompositeDailyReviewCalendar(sources: [mac, broken]).access == .readable,
              "one readable source makes the column readable")
    }

    /// B30: neither Keychain cache may treat "absent" as settled while the
    /// rename's migration can still copy the item across.
    ///
    /// A source guard, because the race needs a real legacy Keychain item, a
    /// real migration pass and a real two-second launch gap.
    /// `LegacyRenameMigrationSelfTest` asserts the *mechanism* against a
    /// stand-in store; this asserts that the two real caches use it, which is
    /// the half a behavioural test on a stand-in cannot give.
    private static func checkTheKeychainCachesSurviveTheRenameMigration(
        _ check: (Bool, String) -> Void) {
        guard let root = SelfTestSources.appSourceDirectory() else {
            check(false, "app sources are not next to this binary - this guard would pass vacuously")
            return
        }
        for name in ["GoogleAccount.swift", "GoogleOAuth.swift"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name),
                                         encoding: .utf8) else {
                check(false, "could not read \(name)")
                continue
            }
            // Discriminating power: the file really does cache, so a cache
            // that was removed outright fails here rather than passing.
            check(text.contains("private var cache"),
                  "\(name) should still hold a Keychain cache for this guard to be about")
            check(text.contains("LegacyNameMigration.keychainItemsCopiedNotification"),
                  "\(name)'s cache must drop its absences when the rename migration copies an "
                  + "item across - otherwise a migrated account reads as \"not connected\" for "
                  + "the rest of the session (B30)")
            check(text.contains("LegacyNameMigration.keychainMigrationIsOutstanding()"),
                  "\(name) must not cache an absence at all while that migration may still "
                  + "run - the repair above leaves a window, this closes it (B30)")
        }
    }

    /// Read-only, and the assertion is about the **scope**.
    ///
    /// `DailyReviewCalendar.swift`'s own read-only-ness is a source guard
    /// because EventKit hands out an object that can write. Here the
    /// guarantee is one layer down - a token that never carried a write scope
    /// cannot write - so this asserts the scope list and the request verb,
    /// which is where that guarantee actually lives.
    private static func checkReadOnlyByScope(_ check: (Bool, String) -> Void) {
        check(GoogleOAuth.scopes.allSatisfy { $0.hasSuffix(".readonly") || $0 == GoogleOAuth.emailScope },
              "every scope this app requests must be read-only, got \(GoogleOAuth.scopes)")
        guard let source = SelfTestSources.appSourceDirectory() else {
            print("  SKIP could not find the app's source directory - the read-only "
                  + "source guard did not run")
            return
        }
        let path = source.appendingPathComponent("GoogleCalendarSource.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            print("  SKIP GoogleCalendarSource.swift not found at \(path.path)")
            return
        }
        // The fixture's discriminating power: the sentinel must really be
        // there, or every absence check below passes vacuously.
        check(text.contains("func get("),
              "the sentinel is missing - this guard would pass vacuously")
        for verb in ["\"POST\"", "\"PUT\"", "\"PATCH\"", "\"DELETE\""] {
            check(!text.contains("httpMethod = \(verb)"),
                  "the Google calendar source must issue no \(verb) - it reads and nothing else")
        }
    }

    private static func checkStatusLines(_ check: (Bool, String) -> Void) {
        let none = SettingsController.gmailStatusLine(for: nil)
        check(none.contains("No OAuth client ID"),
              "with nothing configured the page says exactly what is missing, got \(none)")
        check(none.contains("Desktop app"),
              "and what to create, since this app cannot create it")
        let junk = SettingsController.gmailStatusLine(
            for: GoogleOAuthConfiguration(clientID: "nope", clientSecret: nil))
        check(junk.contains("does not look like"),
              "an obviously wrong id is called out before Google has to, got \(junk)")
        let good = SettingsController.gmailStatusLine(for: configuration)
        check(good.hasPrefix("Ready"), "a well-formed id reads as ready, got \(good)")
        check(configuration.looksWellFormed, "the fixture id should itself be well formed")
        check(!GoogleOAuthConfiguration(clientID: "", clientSecret: nil).looksWellFormed,
              "and an empty one should not")
    }


    // MARK: 13 - connection health (fm/grandline-google-calendar-connection-health)

    /// Google's real body for the captain's own failure.
    ///
    /// Copied from the message the daily review card printed, with the project
    /// number replaced - the point of the whole task is that *this exact
    /// sentence* reaches the Settings page intact, so a paraphrased fixture
    /// would test the wrong thing.
    static let apiDisabledMessage =
        "Google Calendar API has not been used in project 123456789 before or it is disabled. "
        + "Enable it by visiting https://console.developers.google.com/apis/api/"
        + "calendar-json.googleapis.com/overview?project=123456789 then retry. If you enabled "
        + "this API recently, wait a few minutes for the action to propagate to our systems "
        + "and retry."

    static var apiDisabledPayload: Data {
        let object: [String: Any] = ["error": [
            "code": 403, "status": "PERMISSION_DENIED", "message": apiDisabledMessage,
        ]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static let fixURLText = "https://console.developers.google.com/apis/api/"
        + "calendar-json.googleapis.com/overview?project=123456789"

    static func eventsPayload(count: Int) -> Data {
        let items: [[String: Any]] = (0..<count).map { index in
            ["summary": "Meeting \(index)",
             "start": ["dateTime": "2026-09-24T10:0\(index):00Z"]]
        }
        return (try? JSONSerialization.data(withJSONObject: ["items": items])) ?? Data()
    }

    private static func checkTheAPIFailureEnvelope(_ check: (Bool, String) -> Void) {
        // The fixture's own discriminating power first: the sentence really
        // does carry a URL, or every extraction below passes vacuously.
        check(apiDisabledMessage.contains("https://"),
              "the fixture must carry a URL, or the extraction checks are vacuous")

        guard let failure = GoogleAPIFailure.from(apiDisabledPayload) else {
            check(false, "an error envelope should produce a GoogleAPIFailure")
            return
        }
        check(failure.message == apiDisabledMessage,
              "Google's sentence must survive byte for byte - a paraphrase is what hid it, "
              + "got \(failure.message)")
        check(failure.fixURL?.absoluteString == fixURLText,
              "the fix-it URL should be pulled out whole, got "
              + "\(failure.fixURL?.absoluteString ?? "nil")")

        check(GoogleAPIFailure.from(eventsPayload(count: 1)) == nil,
              "a successful body carries no error envelope")

        // A message with no URL still stands on its own, and must not invent
        // a link to nowhere.
        let plain = (try? JSONSerialization.data(withJSONObject: [
            "error": ["message": "Request had invalid authentication credentials."],
        ])) ?? Data()
        check(GoogleAPIFailure.from(plain)?.fixURL == nil,
              "a message with no URL must not produce one")
        check(GoogleAPIFailure.from(plain)?.message == "Request had invalid authentication credentials.",
              "and must still carry Google's own words")

        // Trailing sentence punctuation welded onto a URL is a 404 that looks
        // like this app's fault.
        check(GoogleAPIFailure.firstURL(in: "see https://example.com/enable.")?.absoluteString
              == "https://example.com/enable",
              "a trailing full stop must not become part of the URL")
        check(GoogleAPIFailure.firstURL(in: "see (https://example.com/enable)")?.absoluteString
              == "https://example.com/enable",
              "nor a closing bracket")
        check(GoogleAPIFailure.firstURL(in: "nothing clickable here") == nil,
              "and text with no URL yields none")
    }

    private static func checkTheHealthVerdict(_ check: (Bool, String) -> Void) {
        let day = Date()

        switch GoogleCalendarHealthCheck.verdict(for: apiDisabledPayload, day: day) {
        case .failed(let message, let url):
            check(message == apiDisabledMessage,
                  "the verdict carries Google's real sentence, got \(message)")
            check(url?.absoluteString == fixURLText,
                  "and its fix-it link, got \(url?.absoluteString ?? "nil")")
        default:
            check(false, "an API-disabled body must be a failure, not a healthy read")
        }

        check(GoogleCalendarHealthCheck.verdict(for: eventsPayload(count: 3), day: day)
              == .healthy(eventCount: 3),
              "three events is a healthy read of three events")
        // GL-14 at the happy end: an empty day is a *successful read*, and the
        // line must say so rather than reading like a gap.
        check(GoogleCalendarHealthCheck.verdict(for: eventsPayload(count: 0), day: day)
              == .healthy(eventCount: 0),
              "an empty day is still a successful read")
        let empty = GmailAccountRow.healthLine(for: .healthy(eventCount: 0))
        check(empty.contains("read worked"),
              "and the line says the read worked before it says there is nothing on, got \(empty)")

        switch GoogleCalendarHealthCheck.verdict(for: Data("not json".utf8), day: day) {
        case .failed(let message, let url):
            check(message.contains("not JSON"),
                  "a non-JSON body falls back to the parser's own reason, got \(message)")
            check(url == nil, "and offers no link it cannot stand behind")
        default:
            check(false, "a non-JSON body must be a failure")
        }

        let line = GmailAccountRow.healthLine(for: .failed(message: apiDisabledMessage,
                                                           fixURL: URL(string: fixURLText)))
        check(line.contains(apiDisabledMessage),
              "the rendered line quotes Google in full rather than summarising it")
        check(line.contains(fixURLText),
              "which includes the URL, so it is readable even with the button off screen")
    }

    /// The whole check, driven end to end with a stub transport: the shape
    /// that actually runs when the captain presses Test connection.
    private static func checkTheHealthCheckEndToEnd(_ check: (Bool, String) -> Void) {
        let savedStore = GoogleAccountStore.shared
        let savedTransport = GoogleCalendarHealthCheck.shared.transport
        let savedSignInTransport = GoogleSignInController.shared.transport
        defer {
            GoogleAccountStore.shared = savedStore
            GoogleCalendarHealthCheck.shared.transport = savedTransport
            GoogleSignInController.shared.transport = savedSignInTransport
            GoogleCalendarHealthCheck.shared.debugReset()
        }
        let store = InMemoryGoogleAccountStore()
        GoogleAccountStore.shared = store
        // A fresh token, so `accessToken` short-circuits and no refresh is
        // attempted - this case is about the calendar read, not the token.
        try? store.save(record(), for: .work)
        let transport = StubCalendarTransport()
        GoogleCalendarHealthCheck.shared.transport = transport
        GoogleCalendarHealthCheck.shared.debugReset()

        transport.payload = apiDisabledPayload
        var states: [GoogleCalendarHealth] = []
        GoogleCalendarHealthCheck.shared.check(slot: .work) { states.append($0) }
        pump { states.count >= 2 }
        check(states.first == .checking,
              "the row is told it is checking before the request lands, got "
              + "\(String(describing: states.first))")
        if case .failed(let message, let url) = states.last {
            check(message == apiDisabledMessage, "and then Google's real sentence")
            check(url?.absoluteString == fixURLText, "with its fix-it link")
        } else {
            check(false, "the settled state should be a failure, got "
                  + "\(String(describing: states.last))")
        }
        check(GoogleCalendarHealthCheck.shared.result(for: .work) == states.last,
              "and the verdict is remembered for the row to repaint from")
        check(transport.calls.count == 1, "exactly one request, got \(transport.calls.count)")
        check(transport.calls.first?.url.path.hasSuffix("/events") == true,
              "and it is the same events read the daily review issues, got "
              + "\(transport.calls.first?.url.path ?? "none")")

        // The other slot is untouched - the two accounts are independent, and
        // a shared verdict cache is the obvious way to break that.
        check(GoogleCalendarHealthCheck.shared.result(for: .personal) == .notChecked,
              "checking one slot must not label the other")

        transport.payload = eventsPayload(count: 2)
        var healthy: GoogleCalendarHealth?
        GoogleCalendarHealthCheck.shared.check(slot: .work) { healthy = $0 }
        pump { healthy == .healthy(eventCount: 2) }
        check(healthy == .healthy(eventCount: 2),
              "a re-check replaces the failure with the real result, got "
              + "\(String(describing: healthy))")

        // Forgetting is what a disconnect does: a verdict about an account
        // that is gone is a lie about the row it sits under.
        GoogleCalendarHealthCheck.shared.forget(.work)
        check(GoogleCalendarHealthCheck.shared.result(for: .work) == .notChecked,
              "forget drops the verdict")

        // Signed in, no calendar scope: a real refusal that is not a network
        // failure, and must not be reported as one.
        try? store.save(record(scopes: [GoogleOAuth.emailScope]), for: .personal)
        var scoped: GoogleCalendarHealth?
        GoogleCalendarHealthCheck.shared.check(slot: .personal) { scoped = $0 }
        pump { scoped != nil }
        if case .failed(let message, _) = scoped {
            check(message.contains("never granted calendar access"),
                  "a missing scope says so rather than blaming the network, got \(message)")
        } else {
            check(false, "a scope-less account should fail the check, got "
                  + "\(String(describing: scoped))")
        }
        check(transport.calls.count == 2,
              "and no request is issued for it - there is nothing to ask, got "
              + "\(transport.calls.count)")
    }

    /// The daily review's own reporting, unchanged.
    ///
    /// This addition is additive by requirement: the card keeps saying what it
    /// said. `parse` is the function the card's text comes from, so asserting
    /// its output on the very payload the new check reads is the direct claim
    /// - and it is the function `GoogleAPIFailure` was threaded through, so it
    /// is exactly where a regression would land.
    private static func checkTheDailyReviewCardIsUnchanged(_ check: (Bool, String) -> Void) {
        let day = Date()
        let parsed = GoogleDailyReviewCalendar.parse(apiDisabledPayload, day: day)
        check(parsed.unavailableReason == apiDisabledMessage,
              "the card still reports Google's message verbatim and nothing else, got "
              + "\(parsed.unavailableReason ?? "available")")

        // And the `refresh` path's own sentence around it, which is what the
        // card actually prints.
        let source = GoogleDailyReviewCalendar(slot: .work)
        let savedStore = GoogleAccountStore.shared
        defer { GoogleAccountStore.shared = savedStore }
        let store = InMemoryGoogleAccountStore()
        GoogleAccountStore.shared = store
        try? store.save(record(), for: .work)
        let transport = StubCalendarTransport()
        transport.payload = apiDisabledPayload
        source.transport = transport
        var done = false
        source.refresh(for: day) { _ in done = true }
        pump { done }
        let reason = source.events(on: day).unavailableReason ?? ""
        check(reason == "Work mail\u{2019}s calendar could not be read - \(apiDisabledMessage)",
              "the card's own sentence is byte-identical to what it was, got \(reason)")
    }

    /// A fixed answer, for the merge cases.
    final class StubCalendar: DailyReviewCalendarReading {
        let result: DailyReviewAvailability<[DailyReviewEventRow]>
        init(result: DailyReviewAvailability<[DailyReviewEventRow]>) { self.result = result }
        var access: DailyReviewCalendarAccess {
            if case .available = result { return .readable }
            return .notDetermined
        }
        var canPrompt: Bool { false }
        func requestAccess(completion: @escaping (DailyReviewCalendarAccess) -> Void) {
            completion(access)
        }
        func events(on day: Date) -> DailyReviewAvailability<[DailyReviewEventRow]> {
            _ = day
            return result
        }
    }
}
#endif
