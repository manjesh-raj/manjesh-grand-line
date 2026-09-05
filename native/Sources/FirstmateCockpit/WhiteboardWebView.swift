// Manjesh Grand Line - native macOS app.
//
// The Whiteboard destination's `WKWebView` host: the native half of the bridge
// to the vendored Excalidraw bundle, and the display gating that keeps a
// whiteboard nobody is looking at from costing anything.
//
// ## Gating (E1's lesson, applied to a web view)
//
// The audit's headline battery finding was a terminal that kept repainting
// while merely backgrounded, because nothing ever told it to stop
// (`CockpitTerminalView`'s "Display gating" section). A canvas app inside a web
// view is exactly the same shape of risk, so the same discipline applies here,
// in three layers - and the order matters, because only the first two are
// load-bearing:
//
//   1. **It is never built until first use.** The destination is registered
//      lazily (`DestinationRegistry`), and this view does not load its page
//      until `activate()` is called. A session that never opens the Whiteboard
//      pays nothing at all: no web content process, no canvas, no fonts.
//   2. **WebKit's own visibility state does the heavy lifting.** A `WKWebView`
//      whose `NSView` is hidden (or whose window is closed/minimised/fully
//      occluded) is reported to WebKit as not visible, which is what makes
//      `document.visibilityState` `hidden` and stops both compositing and
//      `requestAnimationFrame`. The destination model already hides the view
//      (`isHidden = true`) on navigate-away, so this is free - but "free"
//      only holds if nothing in the page runs on a timer, which is why the
//      JS side has no always-on loop (see `whiteboard.js`'s own header).
//   3. **The page is told anyway.** `suspend()`/`resume()` pause Excalidraw's
//      own CSS transitions and drop focus - the part WebKit cannot know about -
//      and are the seam a future "stop doing X while hidden" needs.
//
// `viewDidHide`/`viewDidUnhide` are the trigger, for the same reason
// `CockpitTerminalView` uses them: they fire on *effective* visibility, so both
// this app's destination hiding and any future tabbing reach the gate for free
// rather than being wired per page.
//
// ## The bridge
//
// One `WKScriptMessageHandler` (`grandlineWhiteboard`), one message shape.
// Every native call carries a call id and gets exactly one `{type:"reply"}`
// back, so a failure inside the page surfaces as a real error message rather
// than an `evaluateJavaScript` that returned `undefined`. The handler is held
// by a weak proxy: `WKUserContentController` retains its handlers strongly, and
// a view retaining its own configuration's handler which retains the view is
// the standard WebKit leak.

import AppKit
import WebKit

struct WhiteboardBridgeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class WhiteboardWebView: WKWebView {

    /// Fires once the Excalidraw component has mounted and its API is live.
    var onReady: (() -> Void)?
    /// A page-level script error or unhandled rejection. Never fatal - the
    /// canvas may well still be usable - so the controller reports it and
    /// leaves the board alone.
    var onPageError: ((String) -> Void)?

    private(set) var isReady = false
    private(set) var hasLoaded = false
    /// The last gate decision, so a redundant notification does not re-post the
    /// same suspend/resume into the page on every window event.
    private(set) var isSuspended = false

    private var pendingCalls: [Int: (Result<[String: Any], WhiteboardBridgeError>) -> Void] = [:]
    private var nextCallID = 1

    private var occlusionObserver: NSObjectProtocol?
    private var windowOccluded = false

    // MARK: Construction

    init() {
        let config = WKWebViewConfiguration()
        // A local scratch canvas has nothing to remember between launches and
        // nothing worth writing to the app's data store, so it gets an
        // ephemeral store: no cookies, no localStorage, nothing on disk after
        // the process exits. (What *is* preserved is the live board across
        // navigating away and back, because the destination stays mounted for
        // the process's life - see `DestinationRegistry`'s retention note.)
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        config.userContentController = controller
        super.init(frame: .zero, configuration: config)

        controller.add(WhiteboardMessageProxy(target: self), name: Self.messageHandlerName)
        translatesAutoresizingMaskIntoConstraints = false
        // The page paints its own background (Excalidraw's canvas) and the card
        // behind it paints the theme's, so the web view's own under-page fill
        // would only ever be a white flash between the two on a theme change
        // or a reload. `underPageBackgroundColor` is the public API for this
        // (macOS 12+); the older `setValue(false, forKey: "drawsBackground")`
        // trick is private and can throw on an unknown key.
        underPageBackgroundColor = .clear
        // Recovery: with no navigation delegate, a content process WebKit
        // jettisons under memory pressure left `hasLoaded`/`isReady` stuck
        // `true`, so `activate()` could never reload and the canvas was a dead
        // white surface until the app was relaunched.
        navigationDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    static let messageHandlerName = "grandlineWhiteboard"

    // MARK: Loading

    /// Loads the vendored bundle. Safe to call repeatedly - the first call
    /// wins, so a second visit to the destination never restarts the canvas
    /// and never discards the captain's board.
    ///
    /// Returns `false` when the bundle is not on this machine, which is the
    /// controller's cue to show its "no bundle" empty state instead.
    @discardableResult
    func activate() -> Bool {
        guard !hasLoaded else { return true }
        guard let index = WhiteboardAssets.indexURL(), let dir = WhiteboardAssets.webDirectory() else {
            AppLog.lifecycle.error("whiteboard: no Excalidraw bundle found")
            return false
        }
        hasLoaded = true
        // Read access is scoped to the bundle directory: everything the page
        // needs is inside it, and the page's own CSP blocks anything else.
        loadFileURL(index, allowingReadAccessTo: dir)
        return true
    }

    // MARK: Bridge

    /// Calls one of `window.GrandLineWhiteboard`'s entry points.
    ///
    /// `completion` is called on the main thread exactly once - either from the
    /// page's reply, or immediately with a failure when the page is not ready
    /// or `evaluateJavaScript` itself fails. A caller never has to time out.
    func call(_ name: String,
              payload: [String: Any] = [:],
              requiresReady: Bool = true,
              completion: ((Result<[String: Any], WhiteboardBridgeError>) -> Void)? = nil) {
        guard hasLoaded else {
            completion?(.failure(WhiteboardBridgeError(message: "the whiteboard has not been opened yet")))
            return
        }
        guard isReady || !requiresReady else {
            completion?(.failure(WhiteboardBridgeError(message: "the canvas is still starting up")))
            return
        }
        let callID = nextCallID
        nextCallID += 1
        if let completion { pendingCalls[callID] = completion }

        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            pendingCalls[callID] = nil
            completion?(.failure(WhiteboardBridgeError(message: "could not encode the request")))
            return
        }
        // `name` is never captain-supplied - it is one of this file's own
        // literals - and the payload travels as JSON, so nothing here is
        // string-interpolating untrusted text into a script.
        let script = "window.GrandLineWhiteboard.\(name)(\(callID), \(json));"
        evaluateJavaScript(script) { [weak self] _, error in
            guard let self, let error else { return }
            if let pending = self.pendingCalls.removeValue(forKey: callID) {
                pending(.failure(WhiteboardBridgeError(message: error.localizedDescription)))
            }
        }
        // A page-side path that throws before it replies leaves the caller's
        // spinner up forever - `evaluateJavaScript`'s own completion fires
        // successfully in that case, since the *call* worked. Nothing here can
        // know the page will never answer, so the wait is bounded instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.callTimeout) { [weak self] in
            guard let self, let pending = self.pendingCalls.removeValue(forKey: callID) else { return }
            pending(.failure(WhiteboardBridgeError(
                message: "the whiteboard did not answer in time - try again, or reopen the destination")))
        }
    }

    /// How long a bridge call waits for the page's reply before giving up.
    /// Generous: `loadScene` on a large diagram is real work.
    static let callTimeout: TimeInterval = 20

    /// Puts this view back in its pre-`activate()` state, so the next
    /// `activate()` genuinely reloads. Every in-flight bridge call is failed
    /// rather than abandoned - a caller waiting on one would otherwise spin
    /// forever.
    private func resetAfterPageLoss(_ reason: String) {
        AppLog.lifecycle.error("whiteboard: \(reason, privacy: .public) - reloading the canvas")
        isReady = false
        hasLoaded = false
        let pending = pendingCalls
        pendingCalls = [:]
        for completion in pending.values {
            completion(.failure(WhiteboardBridgeError(message: "the whiteboard reloaded - try that again")))
        }
        onPageError?("The whiteboard had to reload, so the board was cleared.")
        activate()
    }

    fileprivate func handle(message body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            isReady = true
            // A page that finished loading while the destination was already
            // hidden must not come up live: re-assert whatever the gate says.
            refreshDisplayGating(force: true)
            onReady?()
        case "error":
            onPageError?((body["message"] as? String) ?? "the whiteboard page reported an error")
        case "reply":
            guard let callID = body["callID"] as? Int else { return }
            guard let completion = pendingCalls.removeValue(forKey: callID) else { return }
            if (body["ok"] as? Bool) == true {
                completion(.success(body))
            } else {
                completion(.failure(WhiteboardBridgeError(
                    message: (body["message"] as? String) ?? "the whiteboard could not do that")))
            }
        default:
            break
        }
    }

    // MARK: Display gating

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerOcclusionObserver()
        refreshDisplayGating()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshDisplayGating()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshDisplayGating()
    }

    private func registerOcclusionObserver() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        guard let window else {
            windowOccluded = false
            return
        }
        windowOccluded = false
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let w = note.object as? NSWindow {
                self.windowOccluded = !w.occlusionState.contains(.visible)
            }
            self.refreshDisplayGating()
        }
    }

    /// Is this view genuinely on screen right now?
    ///
    /// Same derivation - and the same reason for deriving rather than tracking -
    /// as `CockpitTerminalView.refreshDisplayGating`, including reading
    /// occlusion from the notification rather than live: a process the window
    /// server does not composite reports "not visible" for a perfectly fine
    /// window, and a headless self-test must not be told its canvas is hidden.
    var isOnScreen: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return !windowOccluded && !isHiddenOrHasHiddenAncestor
    }

    /// Push the current visibility into the page, if it changed.
    ///
    /// `force` re-asserts it even when the flag matches - used once when the
    /// page first reports ready, since everything before that went nowhere.
    func refreshDisplayGating(force: Bool = false) {
        let shouldSuspend = !isOnScreen
        guard force || shouldSuspend != isSuspended else { return }
        isSuspended = shouldSuspend
        guard isReady else { return }
        call(shouldSuspend ? "suspend" : "resume")
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// Whether a bridge call is still waiting for its reply - a leaked
    /// completion would mean a caller hangs forever.
    var debugPendingCallCount: Int { pendingCalls.count }
    /// Feed a message as if the page had posted it, so the reply plumbing and
    /// the ready/error paths are testable without a real page.
    func debugHandle(message: [String: Any]) { handle(message: message) }
    func debugSetOccluded(_ occluded: Bool) {
        windowOccluded = occluded
        refreshDisplayGating()
    }
    #endif
}

/// Breaks the `WKUserContentController` -> handler -> web view retain cycle.
private final class WhiteboardMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: WhiteboardWebView?
    init(target: WhiteboardWebView) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        target?.handle(message: body)
    }
}

// MARK: - Page-loss recovery

extension WhiteboardWebView: WKNavigationDelegate {

    /// Audit §5.3: the bundle's CSP does not - and cannot - stop a *top-level
    /// navigation*. WebKit implements no `navigate-to` directive, so a
    /// `window.location = "https://…"` from a compromised or newly-updated
    /// vendored bundle would go straight out. This is the gate Docs has always
    /// had (`DocsController`'s own delegate) applied to the two AI-adjacent
    /// surfaces, through the one shared `WebNavigationPolicy` definition.
    ///
    /// Refusals are dropped silently unless they are a real web URL - see
    /// `WebNavigationPolicy.opensExternally` for why a fixed local bundle's
    /// non-web navigation is never handed to `NSWorkspace`.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if let dir = WhiteboardAssets.webDirectory(),
           WebNavigationPolicy.allowsFileURL(url, under: dir) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        AppLog.lifecycle.info("whiteboard: refused a navigation leaving the bundle (\(url.scheme ?? "?", privacy: .public))")
        if WebNavigationPolicy.opensExternally(url) { NSWorkspace.shared.open(url) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resetAfterPageLoss("the web content process was terminated")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A navigation *we* just cancelled surfaces here as an error too
        // (`NSURLErrorCancelled`). Treating that as page loss would call
        // `activate()`, which reloads, which the policy above refuses again -
        // an unbounded reload loop pegging a web content process. A deliberate
        // refusal is not a lost page.
        if (error as NSError).code == NSURLErrorCancelled { return }
        resetAfterPageLoss("the page failed to load (\(error.localizedDescription))")
    }
}
