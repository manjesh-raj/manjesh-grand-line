// Manjesh Grand Line - native macOS app.
//
// The sign-in itself: the browser half of `GoogleOAuth.swift`'s flow, plus
// the token refresh every later API call goes through.
//
// Everything here is callbacks on main, exactly once, the same contract
// `ClaudeOneShot` (GL-26) and `Subprocess` (GL-02) already hold their callers
// to - a UI that has to reason about which thread its completion arrived on
// is a UI that will eventually get it wrong.
//
// **The consent window is `ASWebAuthenticationSession`, so this process never
// sees a password.** See `GoogleOAuth.swift`'s header for why that, rather
// than a `WKWebView`, is the security-relevant choice.

import AppKit
import AuthenticationServices

/// Presents the consent screen. Replaced in the suites, which is what lets
/// the whole sign-in be driven with no browser and no Google.
protocol GoogleConsentPresenting: AnyObject {
    /// Opens `url`, waits, and calls back **on the main thread exactly once**
    /// with the redirect Google sent, or the reason there is none.
    func present(url: URL, callbackScheme: String, from window: NSWindow?,
                 completion: @escaping (Result<URL, GoogleOAuthError>) -> Void)
}

final class WebAuthenticationConsentPresenter: NSObject, GoogleConsentPresenting,
                                               ASWebAuthenticationPresentationContextProviding {
    /// Held for the session's lifetime: `ASWebAuthenticationSession` is
    /// documented to be cancelled if it is deallocated, and a local would be.
    private var session: ASWebAuthenticationSession?
    private weak var anchorWindow: NSWindow?

    func present(url: URL, callbackScheme: String, from window: NSWindow?,
                 completion: @escaping (Result<URL, GoogleOAuthError>) -> Void) {
        anchorWindow = window
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
            // The session's own completion is already on main, but saying so
            // explicitly is what makes this protocol's contract true for
            // every implementation rather than for this one.
            DispatchQueue.main.async {
                self.session = nil
                if let callback {
                    completion(.success(callback))
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    completion(.failure(.cancelled))
                } else if let error {
                    completion(.failure(.transport(error.localizedDescription)))
                } else {
                    completion(.failure(.badResponse("the sign-in window closed with no result")))
                }
            }
        }
        session.presentationContextProvider = self
        // Deliberately `false`. A shared session is what lets Google reuse
        // whichever account Safari is already signed into, and the two slots
        // exist precisely so the captain can hold two different accounts -
        // `prompt=select_account` plus a non-ephemeral session is what lets
        // them pick.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            DispatchQueue.main.async {
                self.session = nil
                completion(.failure(.transport("the sign-in window could not be opened")))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorWindow ?? NSApp?.keyWindow ?? NSApp?.windows.first ?? NSWindow()
    }
}

/// Drives one slot's sign-in, sign-out and token refresh.
///
/// One instance for the app (`shared`), because it owns the in-flight state
/// of a sign-in and two of them would let the captain start the same slot
/// twice.
final class GoogleSignInController {

    static let shared = GoogleSignInController()

    var accounts: GoogleAccountStoring { GoogleAccountStore.shared }
    var transport: GoogleOAuthTransport = URLSessionGoogleOAuthTransport()
    var presenter: GoogleConsentPresenting = WebAuthenticationConsentPresenter()
    /// Injectable so a suite can drive expiry deterministically - the same
    /// one-clock rule `FocusTimerController` learned (AGENTS.md).
    var clock: () -> Date = { Date() }

    /// Slots with a sign-in in flight, so a second click on the same card is
    /// ignored rather than opening a second consent window.
    private(set) var inFlight: Set<GoogleAccountSlot> = []

    /// Fired whenever a slot's stored record changes, so every surface
    /// repaints from one place.
    var onAccountsChanged: (() -> Void)?

    private init() {}

    // MARK: Sign in

    func signIn(slot: GoogleAccountSlot, from window: NSWindow?,
                completion: @escaping (Result<GoogleAccountRecord, GoogleOAuthError>) -> Void) {
        guard !inFlight.contains(slot) else { return }
        guard let configuration = GoogleOAuth.configuration() else {
            completion(.failure(.notConfigured))
            return
        }
        inFlight.insert(slot)
        let challenge = GoogleOAuth.makeChallenge()
        let redirect = GoogleOAuth.redirectURI(for: configuration)
        let url = GoogleOAuth.authorizationURL(configuration: configuration,
                                               redirectURI: redirect,
                                               challenge: challenge,
                                               loginHint: accounts.record(for: slot)?.email)
        presenter.present(url: url,
                          callbackScheme: GoogleOAuth.redirectScheme(for: configuration),
                          from: window) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(slot, .failure(error), completion)
            case .success(let callback):
                switch GoogleOAuth.authorizationCode(from: callback, expectedState: challenge.state) {
                case .failure(let error):
                    self.finish(slot, .failure(error), completion)
                case .success(let code):
                    self.exchange(code: code, verifier: challenge.verifier,
                                  configuration: configuration, redirect: redirect,
                                  slot: slot, completion: completion)
                }
            }
        }
    }

    private func exchange(code: String, verifier: String,
                          configuration: GoogleOAuthConfiguration, redirect: String,
                          slot: GoogleAccountSlot,
                          completion: @escaping (Result<GoogleAccountRecord, GoogleOAuthError>) -> Void) {
        let fields = GoogleOAuth.exchangeFields(configuration: configuration, code: code,
                                                verifier: verifier, redirectURI: redirect)
        transport.postForm(to: GoogleOAuth.tokenEndpoint, fields: fields) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.finish(slot, .failure(.transport(error.localizedDescription)), completion)
                case .success(let data):
                    switch GoogleOAuth.parseTokenResponse(data) {
                    case .failure(let error):
                        self.finish(slot, .failure(error), completion)
                    case .success(let response):
                        let record = GoogleOAuth.record(merging: response,
                                                        into: self.accounts.record(for: slot),
                                                        now: self.clock())
                        do {
                            // GL-10: no silent `try?` on a persistence write.
                            try self.accounts.save(record, for: slot)
                        } catch {
                            self.finish(slot, .failure(.transport(error.localizedDescription)), completion)
                            return
                        }
                        AppLog.keychain.info("google \(slot.rawValue, privacy: .public) connected")
                        self.finish(slot, .success(record), completion)
                    }
                }
            }
        }
    }

    private func finish(_ slot: GoogleAccountSlot,
                        _ result: Result<GoogleAccountRecord, GoogleOAuthError>,
                        _ completion: @escaping (Result<GoogleAccountRecord, GoogleOAuthError>) -> Void) {
        inFlight.remove(slot)
        if case .success = result { onAccountsChanged?() }
        completion(result)
    }

    // MARK: Sign out

    /// Forgets this slot, and asks Google to invalidate the refresh token.
    ///
    /// The local removal happens **first and unconditionally**: a revocation
    /// that fails (no network, an already-revoked token) must still sign the
    /// captain out of this app, or "Disconnect" becomes a button that
    /// sometimes does nothing.
    func signOut(slot: GoogleAccountSlot) {
        let record = accounts.record(for: slot)
        accounts.remove(slot)
        onAccountsChanged?()
        guard let token = record?.refreshToken ?? record?.accessToken, !token.isEmpty else { return }
        transport.postForm(to: GoogleOAuth.revocationEndpoint, fields: ["token": token]) { _ in }
    }

    // MARK: Refresh

    /// An access token good to use right now, refreshing if the stored one is
    /// stale.
    ///
    /// The only path any API call takes. `completion` is on main, exactly
    /// once.
    func accessToken(for slot: GoogleAccountSlot,
                     completion: @escaping (Result<String, GoogleOAuthError>) -> Void) {
        guard let record = accounts.record(for: slot) else {
            completion(.failure(.notConfigured))
            return
        }
        if record.accessTokenIsFresh(at: clock()) {
            completion(.success(record.accessToken))
            return
        }
        guard let refresh = record.refreshToken, !refresh.isEmpty,
              let configuration = GoogleOAuth.configuration() else {
            // A stated gap, not a zero (GL-14): the connection is real and
            // currently unusable, which is a different thing from an empty
            // calendar.
            completion(.failure(.badResponse("this account has no refresh token, so sign in again")))
            return
        }
        let fields = GoogleOAuth.refreshFields(configuration: configuration, refreshToken: refresh)
        transport.postForm(to: GoogleOAuth.tokenEndpoint, fields: fields) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(.transport(error.localizedDescription)))
                case .success(let data):
                    switch GoogleOAuth.parseTokenResponse(data) {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let response):
                        let updated = GoogleOAuth.record(merging: response, into: record,
                                                         now: self.clock())
                        do { try self.accounts.save(updated, for: slot) } catch {
                            completion(.failure(.transport(error.localizedDescription)))
                            return
                        }
                        self.onAccountsChanged?()
                        completion(.success(updated.accessToken))
                    }
                }
            }
        }
    }
}
