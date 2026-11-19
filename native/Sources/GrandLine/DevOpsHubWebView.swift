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

import AppKit
import CryptoKit
import WebKit

final class DevOpsHubWebView: NSView, WKNavigationDelegate, WKUIDelegate {

    /// The site's load progress, 0...1, while a load is in flight.
    var onProgress: ((Double) -> Void)?
    /// The first page finished loading (or failed to, which still ends the
    /// wait: the site then shows WebKit's own error and Reload is there).
    var onFinished: (() -> Void)?

    let webView: WKWebView
    private(set) var origin: URL?
    private var progressObservation: NSKeyValueObservation?

    init(projectID: String) {
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

    /// Load the site at `origin` from its start page.
    func load(origin: URL) {
        self.origin = origin
        open(origin)
    }

    func reload() {
        if webView.url == nil, let origin {
            open(origin)
        } else {
            webView.reload()
        }
    }

    /// The one place this view loads a URL. WebKit fetches in its own
    /// process, where no `URLProtocol` can see it, so the network gate is
    /// asked first (R2-SEC-01). It lets loopback through, which is all this
    /// view ever loads.
    private func open(_ url: URL) {
        guard NetworkGate.allowsOutOfProcessLoad(url) else { return }
        webView.load(URLRequest(url: url))
    }

    /// The server stopped: drop the page so nothing stale is left behind it.
    func unload() {
        origin = nil
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
        AppLog.ui.error("DevOps Hub site failed to load: \(error.localizedDescription, privacy: .public)")
        onFinished?()
    }

    /// A jettisoned content process leaves a blank page: load it again, as
    /// `CodePreviewWebView` does.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLog.ui.error("DevOps Hub site's web content process ended; reloading")
        if let origin { open(origin) }
    }
}
