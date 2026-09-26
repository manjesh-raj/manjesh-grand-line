// Grand Line - native macOS app.
//
// Google sign-in for the two Gmail slots, and the one thing this app does
// with it: reading a calendar.
//
// ## What is here, and what is blocked
//
// The flow is complete and real - PKCE, the system browser, the loopback
// redirect, the token exchange, the refresh. What it cannot do on this
// machine is finish, because an OAuth client ID is issued by a Google Cloud
// project the captain owns and this task cannot create one. There is no fake
// default: `GoogleOAuth.configuration()` returns `nil` until a real client id
// is supplied, and every surface says so plainly rather than presenting a
// Connect button that fails with a Google error page. See
// `docs/history/43-google-accounts.md` for the two things the captain has to
// do.
//
// ## Why `ASWebAuthenticationSession`, and no Google SDK
//
// This app is standard-library-first, and the whole of Google's sign-in SDK
// here would be one `URLSession` POST and a browser window. More to the
// point, `ASWebAuthenticationSession` is the *correct* surface: it runs the
// consent screen in Safari's own process, so this app never sees the
// captain's Google password, cannot read the consent page's DOM, and gets
// back nothing but the authorization code. A `WKWebView` would put all three
// inside this process, which is exactly what RFC 8252 tells a native app not
// to do.
//
// ## PKCE, and why the client secret is not here
//
// Google classifies a Mac app as an "installed application", whose client
// secret is - Google's own documentation says so - not confidential: it ships
// inside the app. So this uses **PKCE** (RFC 7636) as the actual protection:
// a per-attempt 32-byte random verifier, its SHA-256 sent up front, the
// verifier itself sent only with the code. An intercepted code is useless
// without the verifier, which never leaves this process.
//
// A client secret is still accepted (Google issues one for a Desktop client
// and its token endpoint wants it back), and it is stored in the Keychain
// beside the tokens rather than in a plist or a JSON store.
//
// ## The redirect, and why it needs no `Info.plist`
//
// The reversed client id - `com.googleusercontent.apps.<id>:/oauth2redirect`
// - which is the scheme Google issues for an iOS/macOS OAuth client, derived
// here rather than configured so it can never disagree with the client id it
// belongs to.
//
// **`ASWebAuthenticationSession` intercepts that redirect itself**, by the
// `callbackURLScheme` it was handed, and never asks the OS to route it. That
// matters here more than usual: the unbundled debug binary has no
// `Info.plist` at all (the same gap `DailyReviewCalendar.canPrompt` has to
// work around), so an `Info.plist`-registered scheme would work in the
// packaged app and silently not in every development build. A loopback
// redirect would also work, but needs this process to run an HTTP listener
// on a port - a socket this app has no other reason to open.

import Foundation
import CryptoKit

/// Everything a sign-in needs that this app cannot invent.
struct GoogleOAuthConfiguration: Equatable {
    /// `<something>.apps.googleusercontent.com`, from the captain's own
    /// Google Cloud project.
    let clientID: String
    /// Optional. Google issues one for a Desktop client and its token
    /// endpoint expects it; it is not a secret in the usual sense (see the
    /// file header) but it is stored like one anyway.
    let clientSecret: String?

    /// Whether this looks like a real Google client id rather than a
    /// placeholder somebody typed to get past the field.
    ///
    /// Deliberately a *shape* check and nothing more - only Google can say
    /// whether an id exists. What this catches is the empty string and the
    /// "TODO"/"xxx" a half-filled settings field leaves behind, which would
    /// otherwise reach the consent screen and come back as an opaque Google
    /// error.
    var looksWellFormed: Bool {
        clientID.hasSuffix(".apps.googleusercontent.com") && clientID.count > 30
    }
}

/// The result of a completed exchange, before it becomes a
/// `GoogleAccountRecord`.
struct GoogleTokenResponse: Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let grantedScopes: [String]
    /// The `id_token`'s `email` claim, when one came back.
    let email: String?
}

enum GoogleOAuthError: LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case stateMismatch
    case deniedByUser(String)
    case transport(String)
    case badResponse(String)
    /// Signed in, but Google did not grant the calendar scope - a real state
    /// rather than a failure, and the surfaces say so.
    case calendarScopeNotGranted

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Grand Line has no Google OAuth client ID yet - add one in Settings \u{203A} Gmail."
        case .cancelled:
            return "Sign-in was cancelled."
        case .stateMismatch:
            return "The sign-in response did not match the request, so it was rejected."
        case .deniedByUser(let reason):
            return "Google declined the sign-in: \(reason)."
        case .transport(let reason):
            return "Grand Line could not reach Google: \(reason)."
        case .badResponse(let reason):
            return "Google\u{2019}s reply could not be read: \(reason)."
        case .calendarScopeNotGranted:
            return "That account is connected, but it did not grant calendar access."
        }
    }
}

/// The network half, so a suite can exercise the whole flow without a real
/// Google and without a real network.
protocol GoogleOAuthTransport: AnyObject {
    /// POSTs a form-encoded body to Google's token endpoint. `completion`
    /// runs exactly once; the thread is the transport's own, and every caller
    /// here hops to main itself.
    func postForm(to url: URL, fields: [String: String],
                  completion: @escaping (Result<Data, Error>) -> Void)
}

/// The real one. `URLSession`, nothing else - no subprocess, so no argv and
/// no environment ever carries any of this (GL-15 has nothing to apply to).
final class URLSessionGoogleOAuthTransport: GoogleOAuthTransport {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func postForm(to url: URL, fields: [String: String],
                  completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuth.formBody(fields).data(using: .utf8)
        // GL-02's sibling rule for a network call: bounded, always.
        request.timeoutInterval = 30
        session.dataTask(with: request) { data, _, error in
            if let error { completion(.failure(error)); return }
            completion(.success(data ?? Data()))
        }.resume()
    }
}

/// The pure half of the flow: everything that can be computed and asserted
/// without a browser, a network or a Google.
enum GoogleOAuth {

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Read-only, and this app asks for nothing else.
    ///
    /// `calendar.readonly` rather than `calendar`: the app's own standing rule
    /// is that its calendar path never writes (AGENTS.md's "one calendar path,
    /// and it is read-only"), and the right place to enforce that against a
    /// remote calendar is the scope the captain consents to - a token that
    /// cannot write is a stronger guarantee than a file that does not call
    /// `save`.
    static let calendarReadonlyScope = "https://www.googleapis.com/auth/calendar.readonly"
    /// The signed-in address, for the card to display. `userinfo.email`
    /// rather than the full profile: the app wants the address and nothing
    /// else about the person.
    static let emailScope = "https://www.googleapis.com/auth/userinfo.email"

    static let scopes = [emailScope, calendarReadonlyScope]

    /// The environment override, for a captain who would rather not type the
    /// id into a settings field. Read once per call rather than cached, so
    /// setting it takes effect on the next sign-in.
    static let clientIDEnvironmentVariable = "FM_GOOGLE_OAUTH_CLIENT_ID"
    static let clientSecretEnvironmentVariable = "FM_GOOGLE_OAUTH_CLIENT_SECRET"

    /// The configured client, or `nil` when there is none.
    ///
    /// **`nil` is the shipped state**, and every surface treats it as a stated
    /// gap rather than as an error: this app cannot create a Google Cloud
    /// project. The environment wins over the stored value so a captain can
    /// try one without committing it.
    static func configuration(stored: GoogleOAuthConfiguration? = GoogleOAuthClientStore.shared.configuration(),
                              environment: [String: String] = ProcessInfo.processInfo.environment)
        -> GoogleOAuthConfiguration? {
        if let id = environment[clientIDEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            let secret = environment[clientSecretEnvironmentVariable]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return GoogleOAuthConfiguration(clientID: id,
                                            clientSecret: (secret?.isEmpty ?? true) ? nil : secret)
        }
        guard let stored, !stored.clientID.isEmpty else { return nil }
        return stored
    }

    /// The redirect this app hands Google, and the scheme
    /// `ASWebAuthenticationSession` listens on. Derived from the client id,
    /// never configured separately - the two must agree and Google rejects
    /// the request outright when they do not.
    ///
    /// Google's own convention for an installed app: the client id's leading
    /// segment appended to `com.googleusercontent.apps`, reversed-DNS style.
    static func redirectScheme(for configuration: GoogleOAuthConfiguration) -> String {
        let leading = configuration.clientID
            .replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(leading)"
    }

    static func redirectURI(for configuration: GoogleOAuthConfiguration) -> String {
        "\(redirectScheme(for: configuration)):/oauth2redirect"
    }

    // MARK: PKCE

    /// One attempt's PKCE pair plus its CSRF `state`.
    struct Challenge: Equatable {
        let verifier: String
        let challenge: String
        let state: String
    }

    /// A fresh challenge. 32 bytes of `SecRandomCopyBytes`-grade randomness
    /// each, base64url with no padding - RFC 7636 §4.1's own recommended
    /// length, and long enough that guessing it is not a threat model.
    static func makeChallenge() -> Challenge {
        let verifier = base64URL(randomBytes(32))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Challenge(verifier: verifier,
                         challenge: base64URL(Data(digest)),
                         state: base64URL(randomBytes(16)))
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        // `SystemRandomNumberGenerator` is documented to be cryptographically
        // secure on Apple platforms and cannot fail, unlike
        // `SecRandomCopyBytes`' status code - which is the only reason it is
        // preferred here.
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes)
    }

    /// base64url, unpadded - the only encoding RFC 7636 accepts for either
    /// half of the pair.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: The authorization request

    /// The URL the system browser opens.
    ///
    /// `prompt=consent` **and** `access_type=offline` together are what make
    /// Google return a refresh token. Without them a second sign-in to an
    /// account that has consented before returns an access token alone, and
    /// the connection silently stops working an hour later - which reads as a
    /// broken feature rather than as a missing parameter.
    ///
    /// `login_hint` is how the two slots stay independent: without it, a
    /// captain signing into the second slot is handed whichever account the
    /// browser is already signed into, and both cards end up naming the same
    /// address.
    static func authorizationURL(configuration: GoogleOAuthConfiguration,
                                 redirectURI: String,
                                 challenge: Challenge,
                                 loginHint: String? = nil) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: challenge.state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ]
        if let loginHint, !loginHint.isEmpty {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = items
        return components.url!
    }

    /// Pull the authorization code out of the redirect Google sent back,
    /// rejecting anything whose `state` is not the one this attempt sent.
    ///
    /// The state check is not ceremony: without it a redirect an attacker
    /// caused would be accepted as the captain's own sign-in, which is the
    /// CSRF this parameter exists for.
    static func authorizationCode(from url: URL, expectedState: String) -> Result<String, GoogleOAuthError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.badResponse("the redirect was not a readable URL"))
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") {
            return .failure(error == "access_denied" ? .cancelled : .deniedByUser(error))
        }
        guard value("state") == expectedState else { return .failure(.stateMismatch) }
        guard let code = value("code"), !code.isEmpty else {
            return .failure(.badResponse("no authorization code came back"))
        }
        return .success(code)
    }

    // MARK: The token exchange

    static func exchangeFields(configuration: GoogleOAuthConfiguration,
                               code: String, verifier: String, redirectURI: String) -> [String: String] {
        var fields = [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if let secret = configuration.clientSecret, !secret.isEmpty {
            fields["client_secret"] = secret
        }
        return fields
    }

    static func refreshFields(configuration: GoogleOAuthConfiguration,
                              refreshToken: String) -> [String: String] {
        var fields = [
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = configuration.clientSecret, !secret.isEmpty {
            fields["client_secret"] = secret
        }
        return fields
    }

    /// `application/x-www-form-urlencoded`, with every value percent-encoded.
    ///
    /// Hand-rolled rather than `URLComponents`, because `URLComponents`
    /// leaves `+` unescaped in a query value and `+` decodes to a space in a
    /// form body - which corrupts exactly the base64url verifier this flow
    /// depends on, silently, as an "invalid_grant" from Google.
    static func formBody(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }

    /// Google's token-endpoint JSON -> this app's own type.
    static func parseTokenResponse(_ data: Data) -> Result<GoogleTokenResponse, GoogleOAuthError> {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.badResponse("it was not JSON"))
        }
        if let error = object["error"] as? String {
            let description = (object["error_description"] as? String) ?? error
            return .failure(.deniedByUser(description))
        }
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            return .failure(.badResponse("it carried no access token"))
        }
        let scopeString = (object["scope"] as? String) ?? ""
        let granted = scopeString.split(separator: " ").map(String.init)
        // `expires_in` can arrive as a JSON number or as a string depending on
        // the endpoint; both are read rather than one being assumed.
        let expires = (object["expires_in"] as? NSNumber)?.doubleValue
            ?? Double((object["expires_in"] as? String) ?? "") ?? 3600
        return .success(GoogleTokenResponse(
            accessToken: access,
            refreshToken: object["refresh_token"] as? String,
            expiresIn: expires,
            grantedScopes: granted,
            email: emailClaim(fromIDToken: object["id_token"] as? String)))
    }

    /// The `email` claim out of an `id_token`, **without verifying it**.
    ///
    /// Safe, and worth saying why: the token arrived over TLS directly from
    /// Google's token endpoint in response to a request this process made, so
    /// there is no third party in the path whose signature there would be
    /// anything to check. The claim is used for display only - the slot, not
    /// the address, is this app's identity for an account - so even a wrong
    /// value grants nothing.
    static func emailClaim(fromIDToken token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let email = object["email"] as? String, !email.isEmpty else { return nil }
        return email
    }

    /// One exchange response plus the record it replaces -> the record to
    /// store.
    ///
    /// The two things this owns that a plain initialiser would get wrong:
    /// Google omits `refresh_token` on a re-consent it considers unchanged,
    /// so the stored one is **kept** rather than nulled; and an exchange that
    /// carried no `id_token` keeps the address already on file rather than
    /// blanking the card.
    static func record(merging response: GoogleTokenResponse,
                       into existing: GoogleAccountRecord?,
                       now: Date = Date()) -> GoogleAccountRecord {
        GoogleAccountRecord(
            email: response.email ?? existing?.email ?? "",
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? existing?.refreshToken,
            accessTokenExpiry: now.addingTimeInterval(response.expiresIn),
            grantedScopes: response.grantedScopes.isEmpty
                ? (existing?.grantedScopes ?? []) : response.grantedScopes,
            connectedAt: existing?.connectedAt ?? now)
    }
}

/// Where the captain's own client id is kept.
///
/// In the Keychain rather than `UserDefaults`, for one reason that is not
/// about the id: the **client secret** lives beside it, and a secret in a
/// `.plist` under `~/Library/Preferences` is a secret on disk in plaintext.
/// Keeping the pair together is also what stops one being updated without the
/// other.
final class GoogleOAuthClientStore {

    static let shared = GoogleOAuthClientStore()

    static let service = KeychainService.resolve("com.manjesh.grandline.native.google-oauth-client")
    private static let account = "client"

    /// The suites' replacement, set by `main.swift`'s `#if FM_SELFTESTS`
    /// block - the same backstop every file-backed store gets.
    var override: GoogleOAuthConfiguration??

    private var cache: GoogleOAuthConfiguration??
    private var migrationObserver: NSObjectProtocol?

    init() {
        // B30: same race as `KeychainGoogleAccountStore`'s, same repair. The
        // rename's Keychain migration runs two seconds after launch, and a
        // "no client configured" cached from the pre-migration Keychain sends
        // Settings into offering to set one up over a pair that already
        // exists - and `setConfiguration` deletes before it adds.
        migrationObserver = NotificationCenter.default.addObserver(
            forName: LegacyNameMigration.keychainItemsCopiedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.forgetCachedAbsence()
        }
    }

    deinit {
        if let migrationObserver { NotificationCenter.default.removeObserver(migrationObserver) }
    }

    /// Drops a cached "there is no client configured". A configuration that
    /// really was read is kept - a migration only ever copies items in.
    func forgetCachedAbsence() {
        if case .some(.none) = cache { cache = nil }
    }

    func configuration() -> GoogleOAuthConfiguration? {
        if let override { return override }
        if let cache { return cache }
        let (value, cacheable) = read()
        // Review bug B1: a Keychain error is not "no client configured", so it
        // is not cached either - the next call retries once the Keychain
        // settles, rather than reporting "not set up" for the whole session.
        //
        // B30: nor is "absent" settled while the rename's Keychain migration
        // may still copy the item across.
        if value == nil, LegacyNameMigration.keychainMigrationIsOutstanding() { return nil }
        if cacheable { cache = .some(value) }
        return value
    }

    func setConfiguration(_ configuration: GoogleOAuthConfiguration?) throws {
        if override != nil { override = .some(configuration); return }
        cache = .some(configuration)
        delete()
        guard let configuration, !configuration.clientID.isEmpty else { return }
        let payload = ["clientID": configuration.clientID,
                       "clientSecret": configuration.clientSecret ?? ""]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    /// The stored pair, and whether the answer is worth caching. `false` means
    /// the Keychain refused rather than answered.
    private func read() -> (GoogleOAuthConfiguration?, cacheable: Bool) {
        // Review bug B1's tri-state. Collapsing a Keychain error into "no
        // client configured" makes Settings offer to set one up over a client
        // id that is already stored, and `setConfiguration` deletes before it
        // adds - so answering that offer would replace the captain's real pair
        // with whatever was typed. The caller does not cache a refusal, so the
        // next call retries.
        let outcome = ClipboardHistoryKey.read(service: Self.service, account: Self.account)
        if case .failed(let status) = outcome {
            AppLog.keychain.error("google oauth client: the Keychain would not answer (\(status))")
            return (nil, cacheable: false)
        }
        guard case .found(let data) = outcome,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let id = object["clientID"], !id.isEmpty else { return (nil, cacheable: true) }
        let secret = object["clientSecret"] ?? ""
        return (GoogleOAuthConfiguration(clientID: id, clientSecret: secret.isEmpty ? nil : secret),
                cacheable: true)
    }

    private func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
