// Manjesh Grand Line - native macOS app.
//
// The Code Preview destination's `WKWebView` host: the native half of the
// bridge to the vendored Monaco bundle, and the display gating that keeps an
// editor nobody is looking at from costing anything.
//
// This is `WhiteboardWebView` applied a second time, and the duplication is
// deliberate rather than overlooked. The two share a *shape* - a bridge with
// call ids, a weak message-handler proxy, page-loss recovery, three-layer
// visibility gating - but not a surface: their message-handler names, their
// page globals, their reply payloads and their unsolicited messages (`change`
// and `cursor` here; nothing like them there) all differ. Factoring the shape
// out would produce a base class whose every method took a "which page am I"
// parameter, which is how one shared abstraction becomes two features that can
// only be changed together. See `HelmAccentRow`/`ToolRowLayout`'s own note in
// AGENTS.md for the same call made for the same reason.
//
// ## Gating (E1's lesson, applied to a second web view)
//
// Three layers, and only the first two are load-bearing:
//
//   1. **It is never built until first use.** The destination is registered
//      lazily (`DestinationRegistry`), and this view does not load its page
//      until `activate()` is called. A session that never opens Code Preview
//      pays nothing at all: no web content process, no editor, no font.
//   2. **WebKit's own visibility state does the heavy lifting.** A `WKWebView`
//      whose `NSView` is hidden (or whose window is closed/minimised/fully
//      occluded) is reported to WebKit as not visible, which is what stops
//      compositing and `requestAnimationFrame`. That is free - but "free" only
//      holds if nothing in the page runs on a timer, which is why the JS side
//      has no always-on loop.
//   3. **The page is told anyway.** `suspend()`/`resume()` stop Monaco's CSS
//      transitions and its blinking caret, drop focus, and - the part unique
//      to this feature - flush any debounced edit, so the last keystrokes
//      before a navigate-away are never left waiting on a timer in a page
//      nobody is looking at.
//
// `viewDidHide`/`viewDidUnhide` are the trigger, for the same reason
// `CockpitTerminalView` uses them: they fire on *effective* visibility.

import AppKit
import WebKit

struct CodePreviewBridgeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Where the caret is, for the status line.
struct CodePreviewCursor: Equatable {
    var line: Int
    var column: Int
    /// Characters in the selection, or 0 when there is none.
    var selected: Int
    var lines: Int
}

final class CodePreviewWebView: WKWebView {

    /// Fires once Monaco has mounted and its API is live.
    var onReady: (() -> Void)?
    /// A page-level script error or unhandled rejection. Never fatal - the
    /// editor may well still be usable - so the controller reports it and
    /// leaves the snippets alone.
    var onPageError: ((String) -> Void)?
    /// A debounced edit: the snippet's id and its full new text. This is the
    /// one unsolicited message that carries the captain's own work, so the
    /// controller treats it as the trigger to persist.
    var onSnippetChanged: ((String, String) -> Void)?
    /// Caret moved. Throttled only by how fast a caret can move; the handler
    /// updates one label.
    var onCursorMoved: ((CodePreviewCursor) -> Void)?

    private(set) var isReady = false
    private(set) var hasLoaded = false
    /// The last gate decision, so a redundant notification does not re-post the
    /// same suspend/resume into the page on every window event.
    private(set) var isSuspended = false

    private var pendingCalls: [Int: (Result<[String: Any], CodePreviewBridgeError>) -> Void] = [:]
    private var nextCallID = 1

    private var occlusionObserver: NSObjectProtocol?
    private var windowOccluded = false

    // MARK: Construction

    init() {
        let config = WKWebViewConfiguration()
        // Every snippet lives in a real file this app writes (see
        // `CodePreviewStore`), so the page itself has nothing worth
        // remembering between launches - and an editor that quietly kept a
        // second copy of the captain's code in WebKit's local storage would be
        // a second source of truth nobody asked for. Ephemeral store: nothing
        // on disk after the process exits.
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        config.userContentController = controller
        super.init(frame: .zero, configuration: config)

        controller.add(CodePreviewMessageProxy(target: self), name: Self.messageHandlerName)
        translatesAutoresizingMaskIntoConstraints = false
        // Monaco paints its own background from the theme this app pushes, and
        // the card behind it paints the theme's too, so the web view's own
        // under-page fill would only ever be a white flash between the two on
        // a theme change or a reload.
        underPageBackgroundColor = .clear
        // Recovery: with no navigation delegate, a content process WebKit
        // jettisons under memory pressure would leave `hasLoaded`/`isReady`
        // stuck `true`, so `activate()` could never reload and the editor
        // would be a dead surface until relaunch.
        navigationDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    static let messageHandlerName = "grandlineCodePreview"

    // MARK: Loading

    /// Loads the vendored bundle. Safe to call repeatedly - the first call
    /// wins, so a second visit to the destination never restarts the editor
    /// and never discards what is open.
    ///
    /// Returns `false` when the bundle is not on this machine, which is the
    /// controller's cue to show its "no bundle" empty state instead.
    @discardableResult
    func activate() -> Bool {
        guard !hasLoaded else { return true }
        guard let index = CodePreviewAssets.indexURL(), let dir = CodePreviewAssets.webDirectory() else {
            AppLog.lifecycle.error("code preview: no Monaco bundle found")
            return false
        }
        hasLoaded = true
        // Read access is scoped to the bundle directory: everything the page
        // needs is inside it, and the page's own CSP blocks anything else.
        loadFileURL(index, allowingReadAccessTo: dir)
        return true
    }

    // MARK: Bridge

    /// Calls one of `window.GrandLineCodePreview`'s entry points.
    ///
    /// `completion` is called on the main thread exactly once - either from the
    /// page's reply, or immediately with a failure when the page is not ready
    /// or `evaluateJavaScript` itself fails. A caller never has to time out.
    func call(_ name: String,
              payload: [String: Any] = [:],
              requiresReady: Bool = true,
              completion: ((Result<[String: Any], CodePreviewBridgeError>) -> Void)? = nil) {
        guard hasLoaded else {
            completion?(.failure(CodePreviewBridgeError(message: "the code panel has not been opened yet")))
            return
        }
        guard isReady || !requiresReady else {
            completion?(.failure(CodePreviewBridgeError(message: "the editor is still starting up")))
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
            completion?(.failure(CodePreviewBridgeError(message: "could not encode the request")))
            return
        }
        // `name` is never captain-supplied - it is one of this file's own
        // literals - and the payload travels as JSON, so nothing here is
        // string-interpolating untrusted text into a script. That matters more
        // in this feature than in most: the payload routinely *is* code the
        // captain pasted from somewhere else.
        let script = "window.GrandLineCodePreview.\(name)(\(callID), \(json));"
        evaluateJavaScript(script) { [weak self] _, error in
            guard let self, let error else { return }
            if let pending = self.pendingCalls.removeValue(forKey: callID) {
                pending(.failure(CodePreviewBridgeError(message: error.localizedDescription)))
            }
        }
        // A page-side path that throws before it replies leaves the caller's
        // spinner up forever - `evaluateJavaScript`'s own completion fires
        // successfully in that case, since the *call* worked. Nothing here can
        // know the page will never answer, so the wait is bounded instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.callTimeout) { [weak self] in
            guard let self, let pending = self.pendingCalls.removeValue(forKey: callID) else { return }
            pending(.failure(CodePreviewBridgeError(
                message: "the editor did not answer in time - try again, or reopen the destination")))
        }
    }

    /// How long a bridge call waits for the page's reply before giving up.
    /// Generous: installing a large pasted snippet is real work.
    static let callTimeout: TimeInterval = 20

    /// Puts this view back in its pre-`activate()` state, so the next
    /// `activate()` genuinely reloads. Every in-flight bridge call is failed
    /// rather than abandoned.
    private func resetAfterPageLoss(_ reason: String) {
        AppLog.lifecycle.error("code preview: \(reason, privacy: .public) - reloading the editor")
        isReady = false
        hasLoaded = false
        let pending = pendingCalls
        pendingCalls = [:]
        for completion in pending.values {
            completion(.failure(CodePreviewBridgeError(message: "the editor reloaded - try that again")))
        }
        // Deliberately *not* worded as "your work was lost": unlike the
        // Whiteboard's in-memory board, every snippet is a real file on disk,
        // so a reload re-opens them from the store with everything the last
        // debounce wrote.
        onPageError?("The editor had to reload. Your snippets were re-opened from disk.")
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
            onPageError?((body["message"] as? String) ?? "the code panel reported an error")
        case "change":
            guard let id = body["id"] as? String, let content = body["content"] as? String else { return }
            onSnippetChanged?(id, content)
        case "cursor":
            onCursorMoved?(CodePreviewCursor(
                line: (body["line"] as? Int) ?? 1,
                column: (body["column"] as? Int) ?? 1,
                selected: (body["selected"] as? Int) ?? 0,
                lines: (body["lines"] as? Int) ?? 0))
        case "reply":
            guard let callID = body["callID"] as? Int else { return }
            guard let completion = pendingCalls.removeValue(forKey: callID) else { return }
            if (body["ok"] as? Bool) == true {
                completion(.success(body))
            } else {
                completion(.failure(CodePreviewBridgeError(
                    message: (body["message"] as? String) ?? "the editor could not do that")))
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
    /// Same derivation - and the same reason for deriving rather than tracking
    /// - as `CockpitTerminalView.refreshDisplayGating`, including reading
    /// occlusion from the notification rather than live: a process the window
    /// server does not composite reports "not visible" for a perfectly fine
    /// window, and a headless self-test must not be told its editor is hidden.
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
    /// the ready/error/change paths are testable without a real page.
    func debugHandle(message: [String: Any]) { handle(message: message) }
    func debugSetOccluded(_ occluded: Bool) {
        windowOccluded = occluded
        refreshDisplayGating()
    }
    #endif
}

/// Breaks the `WKUserContentController` -> handler -> web view retain cycle.
private final class CodePreviewMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: CodePreviewWebView?
    init(target: CodePreviewWebView) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        target?.handle(message: body)
    }
}

// MARK: - Page-loss recovery

extension CodePreviewWebView: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resetAfterPageLoss("the web content process was terminated")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resetAfterPageLoss("the page failed to load (\(error.localizedDescription))")
    }
}
