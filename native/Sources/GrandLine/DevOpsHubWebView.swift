// Grand Line - native macOS app.
//
// The web view a DevOps Hub project's site shows in.
//
// Two things set it apart from this app's other `WKWebView` hosts, which all
// load a bundled folder from `file://` with a throwaway data store:
//
//   - **It loads over HTTP, from `LocalStaticServer` on 127.0.0.1.** A Vite
//     build is ES modules, and WebKit will not run a module from `file://`.
//     The navigation policy allows that one origin (scheme, host and port)
//     and nothing else: an outbound web link goes to the default browser
//     through `WebNavigationPolicy.openExternally`, and any other scheme is
//     dropped, as every other host here does.
//   - **Its storage persists.** The DevOps Atlas course keeps its progress,
//     theme and language in `localStorage`, so a throwaway store would reset
//     the course on every launch. Each project gets its own store
//     (`WKWebsiteDataStore(forIdentifier:)`, macOS 14 and later), and on
//     macOS 13 the default store, which no other web view in this app uses.
//     A self-test or tour process gets a throwaway one, so a suite never
//     writes WebKit data anywhere.
//
// Full review 4 (S-02) added one more: **it carries the run's key.** The
// server answers only a request with the run's key in its cookie, unless
// the project allows the browser, so `load(origin:accessToken:)` sets that
// cookie in this view's store (HttpOnly, so the page's own script cannot
// read it) before the first request.
//
// Full review 2026-11-25 added two more (B-04, B-05):
//
//   - **A site's own dialogs work.** `alert`, `confirm` and `prompt` are the
//     app's `HelmConfirm`, titled with the project's name, and a file input
//     opens an `NSOpenPanel` sheet. Without these WebKit answered `confirm`
//     with false and `prompt` with null and showed nothing, so a site asking
//     "Reset your progress?" silently did nothing. None of them shows over
//     the app lock (`AppLockedSurface.devopsHubSiteDialog`).
//   - **A site that keeps crashing stops being reloaded.** One ended content
//     process is reloaded, as before. A second within `crashWindow` stops
//     there and the page says the site keeps crashing, with Reload, rather
//     than starting a new WebContent process forever.

import AppKit
import CryptoKit
import WebKit

final class DevOpsHubWebView: NSView, WKNavigationDelegate, WKUIDelegate {

    /// The site's load progress, 0...1, while a load is in flight.
    var onProgress: ((Double) -> Void)?
    /// The first page finished loading (or failed to, which still ends the
    /// wait: the site then shows WebKit's own error and Reload is there).
    var onFinished: (() -> Void)?
    /// B-05: the site's content process ended twice within `crashWindow`,
    /// and this view stopped reloading it. `reload()` starts it again.
    var onKeepsCrashing: (() -> Void)?
    /// What the site's own dialogs call it: the project's name.
    var siteName: String

    /// B-05: when the site's content process last ended, while it has not yet
    /// been reloaded by hand.
    private var lastTermination: Date?
    /// The view gave up reloading a site that keeps crashing.
    private(set) var keepsCrashing = false
    /// The clock the crash window is measured on.
    var clock: () -> Date = Date.init

    let webView: WKWebView
    private(set) var origin: URL?
    private var progressObservation: NSKeyValueObservation?

    init(projectID: String) {
        siteName = projectID
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore(for: projectID)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setAccessibilityLabel("\(projectID) site")
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let progress = view.estimatedProgress
            DispatchQueue.main.async { self?.onProgress?(progress) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        progressObservation?.invalidate()
    }

    static let cornerRadius: CGFloat = 12

    func applyTheme(_ theme: HelmTheme) {
        layer?.borderColor = HelmFlatList.hairRowColor(theme).cgColor
        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
    }

    // MARK: Storage

    /// A project's own persistent store, or a throwaway one in a self-test or
    /// tour process.
    static func dataStore(for projectID: String) -> WKWebsiteDataStore {
        if ExternalToolGuard.isActive { return .nonPersistent() }
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: storeIdentifier(for: projectID))
        }
        return .default()
    }

    /// A stable UUID per project id, so the same project finds the same
    /// store on every launch.
    static func storeIdentifier(for projectID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("grandline.devopshub.\(projectID)".utf8)).prefix(16))
        // RFC 4122 version 5 / variant bits, so it is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: Loading

    /// Load the site at `origin` from its start page, carrying the run's
    /// key when there is one (S-02).
    func load(origin: URL, accessToken: String? = nil) {
        self.origin = origin
        resetCrashCount()
        loadGeneration &+= 1
        let generation = loadGeneration
        let start = { [weak self] in
            guard let self, self.loadGeneration == generation, self.origin == origin else { return }
            self.open(origin)
        }
        guard let accessToken, let cookie = Self.accessCookie(token: accessToken, origin: origin) else { return start() }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { start() }
    }

    /// A newer `load` or an `unload` supersedes a load still setting its cookie.
    private var loadGeneration = 0

    /// The run's key as the cookie the server reads: this host only, every
    /// path, HttpOnly and same-site, and gone with the session.
    static func accessCookie(token: String, origin: URL) -> HTTPCookie? {
        guard let host = origin.host, let port = origin.port else { return nil }
        return HTTPCookie(properties: [
            .name: LocalStaticServer.cookieName(port: UInt16(clamping: port)),
            .value: token,
            .domain: host,
            .path: "/",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict,
        ])
    }

    /// Reload by hand (the strip's Reload, ⌘R, the crash state's Reload),
    /// which also gives a site that kept crashing a fresh count.
    func reload() {
        let restarting = keepsCrashing
        resetCrashCount()
        if restarting || webView.url == nil, let origin {
            open(origin)
        } else {
            webView.reload()
        }
    }

    private func resetCrashCount() {
        lastTermination = nil
        keepsCrashing = false
    }

    /// The one place this view loads a URL. WebKit fetches in its own
    /// process, where no `URLProtocol` can see it, so the network gate is
    /// asked first (R2-SEC-01). It lets loopback through, which is all this
    /// view ever loads.
    private func open(_ url: URL) {
        guard NetworkGate.allowsOutOfProcessLoad(url) else { return }
        #if FM_SELFTESTS
        debugOpenCount += 1
        #endif
        webView.load(URLRequest(url: url))
    }

    #if FM_SELFTESTS
    /// How many times this view has asked WebKit to load the site.
    private(set) var debugOpenCount = 0
    #endif

    /// The server stopped: drop the page so nothing stale is left behind it.
    func unload() {
        loadGeneration &+= 1
        origin = nil
        resetCrashCount()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: The navigation policy

    /// Whether `url` is the served site itself: http, a loopback name, and
    /// the served port.
    static func isSameSite(_ url: URL, origin: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased(),
              host == LocalStaticServer.loopbackHost || host == "localhost" else { return false }
        return url.port == origin.port
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.absoluteString == "about:blank" { return decisionHandler(.allow) }
        if let origin, Self.isSameSite(url, origin: origin) { return decisionHandler(.allow) }
        // Only a link followed by hand in the page itself leaves for the
        // browser; a script's own redirect or a frame's load does not.
        if navigationAction.targetFrame?.isMainFrame ?? true, navigationAction.navigationType == .linkActivated {
            WebNavigationPolicy.openExternally(url, from: "DevOps Hub")
        }
        decisionHandler(.cancel)
    }

    /// `target="_blank"` and `window.open`: never a second web view here, and
    /// a web link goes to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if let origin, Self.isSameSite(url, origin: origin) {
                open(url)
            } else {
                WebNavigationPolicy.openExternally(url, from: "DevOps Hub")
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinished?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    /// B-04: a load can also fail after it has started, and that is a
    /// different callback. Unhandled, the page never heard the load end, so
    /// its progress strip could stay up.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        AppLog.ui.error("DevOps Hub site failed to load: \(error.localizedDescription, privacy: .public)")
        onFinished?()
    }

    // MARK: A site that crashes

    /// Two ended content processes this close together are a site that
    /// crashes on load (a memory blow-up, a broken WebAssembly module), not a
    /// process the system jettisoned once.
    static let crashWindow: TimeInterval = 60

    /// Whether a termination at `now`, after one at `last`, is the second
    /// within `crashWindow`.
    static func isRepeatedCrash(at now: Date, after last: Date?) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) < crashWindow
    }

    /// A jettisoned content process leaves a blank page: load it again, as
    /// `CodePreviewWebView` does. B-05: once, not forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !keepsCrashing, let origin else { return }
        let now = clock()
        if Self.isRepeatedCrash(at: now, after: lastTermination) {
            AppLog.ui.error("DevOps Hub site's web content process ended twice in \(Int(Self.crashWindow), privacy: .public)s; not reloading")
            keepsCrashing = true
            onKeepsCrashing?()
            return
        }
        AppLog.ui.error("DevOps Hub site's web content process ended; reloading")
        lastTermination = now
        open(origin)
    }

    // MARK: The site's own dialogs (B-04)

    /// None of them shows over the app lock. WebKit's own answers then stand:
    /// nothing for an alert, false for a confirm, null for a prompt and no
    /// file for an input.
    private var mayShowDialog: Bool { AppLockGate.shared.allows(.devopsHubSiteDialog) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        if mayShowDialog { HelmConfirm.confirm(Self.alertRequest(message, site: siteName)) }
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard mayShowDialog else { return completionHandler(false) }
        completionHandler(HelmConfirm.confirm(Self.confirmRequest(message, site: siteName)) == .confirm)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard mayShowDialog else { return completionHandler(nil) }
        let (request, field) = Self.promptRequest(prompt, defaultText: defaultText, site: siteName)
        completionHandler(HelmConfirm.confirm(request) == .confirm ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard mayShowDialog, let window = webView.window else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        Self.configure(panel, allowsMultipleSelection: parameters.allowsMultipleSelection,
                       allowsDirectories: parameters.allowsDirectories, site: siteName)
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    /// `alert()`: one button, as a browser's.
    static func alertRequest(_ message: String, site: String) -> HelmConfirm.Request {
        var request = dialogRequest(message, site: site)
        request.cancelTitle = nil
        return request
    }

    /// `confirm()`: OK and Cancel, Return answering OK, as a browser's.
    static func confirmRequest(_ message: String, site: String) -> HelmConfirm.Request {
        dialogRequest(message, site: site)
    }

    /// `prompt()`: a field holding the page's default text, with the
    /// keyboard in it. The field is what the answer is read from.
    static func promptRequest(_ message: String, defaultText: String?, site: String)
        -> (request: HelmConfirm.Request, field: HelmTextField) {
        let field = HelmTextField()
        field.stringValue = defaultText ?? ""
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        var request = dialogRequest(message, site: site)
        request.accessory = field
        request.initialResponder = field
        return (request, field)
    }

    private static func dialogRequest(_ message: String, site: String) -> HelmConfirm.Request {
        var request = HelmConfirm.Request(title: "\(site) says", body: message)
        request.confirmTitle = "OK"
        request.symbol = "globe"
        request.hue = RailDestination.devopsHub.domainHue
        return request
    }

    /// A file input's panel: files, several only when the input says
    /// `multiple`, and folders only when it asks for them.
    static func configure(_ panel: NSOpenPanel, allowsMultipleSelection: Bool, allowsDirectories: Bool,
                          site: String) {
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowsDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.prompt = "Choose"
        panel.message = "Choose \(allowsMultipleSelection ? "files" : "a file") for \(site)."
    }
}
