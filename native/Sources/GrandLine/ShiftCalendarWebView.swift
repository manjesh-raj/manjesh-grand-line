// Grand Line - native macOS app.
//
// The Calendar page's `WKWebView` host: the native half of the bridge to
// the vendored Schedule-X bundle (`Vendor/ScheduleX/src/task-calendar.js` is
// the other half), and the display gating that keeps a calendar nobody is
// looking at from costing anything.
//
// This is `CodePreviewWebView`'s shape applied a third time, and the
// duplication is deliberate for the reason that file gives: the three web
// hosts share a shape (call ids, a weak message-handler proxy, page-loss
// recovery, visibility gating) but not a surface. Their page globals, their
// messages and their replies all differ, and a shared base class would take a
// "which page am I" parameter on every method.
//
// ## What crosses the bridge
//
// Native to page: `configure` once, then `setEvents`, `setTheme`, `setView`,
// `showDate`, `suspend`/`resume`, and `state` (read back from the page's DOM,
// for a self-test). Page to native: `ready`, `error`, `range` (the visible
// period changed), `open` (an event was clicked), `add` (a day or a time slot
// was double-clicked) and `move` (an event was dropped somewhere new).
//
// `move` is a request, never a fact. The page has already drawn the event in
// its new place, but nothing is written until `ShiftController` asks the
// store, and the store's answer comes back as the next `setEvents` - so a drop
// the store refuses snaps back, and the page never shows a date the store does
// not hold.

import AppKit
import WebKit

struct ShiftCalendarBridgeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class ShiftCalendarWebView: WKWebView {

    /// The page mounted Schedule-X and its bridge is live.
    var onReady: (() -> Void)?
    /// A page-level script error. Never fatal; reported and logged.
    var onPageError: ((String) -> Void)?
    /// The visible period changed: the first and last day it covers, as
    /// `YYYY-MM-DD`. Deliberately not the view: Schedule-X reports a range
    /// for things the captain did not do (it used to switch itself to Day
    /// when a hidden page collapsed, R4-BUG-01), so a range report never
    /// changes the scale. `onViewSelected` does.
    var onRangeChanged: ((_ start: String, _ end: String) -> Void)?
    /// The page's own view handler ran - a pill in the card, or "+N more" on
    /// a crowded day - with Schedule-X's view name.
    var onViewSelected: ((String) -> Void)?
    /// An event was clicked. The id is the task's, also for a projection.
    var onOpenTask: ((String) -> Void)?
    /// A follow-up's event was clicked.
    var onOpenFollowUp: ((String) -> Void)?
    /// A day (or, in week and day view, a time slot) was double-clicked.
    var onAddTask: ((_ day: String, _ time: String?) -> Void)?
    /// An event was dropped on a new day or time.
    var onMoveTask: ((_ taskID: String, _ day: String, _ time: String?) -> Void)?
    /// A follow-up's event was dropped on a new day or time.
    var onMoveFollowUp: ((_ id: String, _ day: String, _ time: String?) -> Void)?
    /// The day the page is focused on (`YYYY-MM-DD`), as its last range
    /// report said: what a New Task from the toolbar is dated to.
    private(set) var focusedDay: String?

    private(set) var isReady = false
    private(set) var hasLoaded = false
    private(set) var isSuspended = false

    private var pendingCalls: [Int: (Result<[String: Any], ShiftCalendarBridgeError>) -> Void] = [:]
    private var nextCallID = 1

    private var occlusionObserver: NSObjectProtocol?
    private var windowOccluded = false

    // MARK: Construction

    init() {
        let config = WKWebViewConfiguration()
        // The tasks live in `ShiftStore`'s own files. The page keeps nothing
        // worth remembering, so it gets no persistent website data at all.
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        config.userContentController = controller
        super.init(frame: .zero, configuration: config)

        controller.add(ShiftCalendarMessageProxy(target: self), name: Self.messageHandlerName)
        translatesAutoresizingMaskIntoConstraints = false
        // The page paints the theme's own surface, and the card behind it does
        // too, so WebKit's under-page fill would only ever show as a flash.
        underPageBackgroundColor = .clear
        // The same recovery `CodePreviewWebView` has: without a navigation
        // delegate a jettisoned content process leaves the calendar dead
        // until relaunch.
        navigationDelegate = self
        setAccessibilityLabel("Task calendar")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    static let messageHandlerName = "grandlineTaskCalendar"

    // MARK: Loading

    /// Loads the vendored bundle. Safe to call repeatedly; the first call
    /// wins. Returns `false` when the bundle is not on this machine, which is
    /// the view's cue to show its "no bundle" empty state instead.
    @discardableResult
    func activate() -> Bool {
        guard !hasLoaded else { return true }
        guard let index = ShiftCalendarAssets.indexURL(), let dir = ShiftCalendarAssets.webDirectory() else {
            AppLog.lifecycle.error("task calendar: no Schedule-X bundle found")
            return false
        }
        hasLoaded = true
        // Read access is scoped to the bundle directory, and the page's own
        // CSP refuses every connection besides.
        loadFileURL(index, allowingReadAccessTo: dir)
        return true
    }

    // MARK: Bridge

    /// Calls one of `window.GrandLineTaskCalendar`'s entry points.
    ///
    /// `completion` runs on the main thread exactly once: from the page's
    /// reply, or immediately with a failure when the page is not ready or the
    /// script itself fails, or after `callTimeout` when the page never
    /// answers. A caller never has to time out on its own.
    func call(_ name: String,
              payload: [String: Any] = [:],
              requiresReady: Bool = true,
              completion: ((Result<[String: Any], ShiftCalendarBridgeError>) -> Void)? = nil) {
        guard hasLoaded else {
            completion?(.failure(ShiftCalendarBridgeError(message: "the calendar has not been opened yet")))
            return
        }
        guard isReady || !requiresReady else {
            completion?(.failure(ShiftCalendarBridgeError(message: "the calendar is still starting up")))
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            completion?(.failure(ShiftCalendarBridgeError(message: "could not encode the request")))
            return
        }
        let callID = nextCallID
        nextCallID += 1
        if let completion { pendingCalls[callID] = completion }
        #if FM_SELFTESTS
        debugCalls.append(name)
        #endif

        // `name` is always one of this file's callers' own literals, and the
        // payload - which carries task titles the captain typed - travels as
        // JSON, so no text is ever interpolated into the script.
        let script = "window.GrandLineTaskCalendar.\(name)(\(callID), \(json));"
        evaluateJavaScript(script) { [weak self] _, error in
            guard let self, let error else { return }
            if let pending = self.pendingCalls.removeValue(forKey: callID) {
                pending(.failure(ShiftCalendarBridgeError(message: error.localizedDescription)))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.callTimeout) { [weak self] in
            guard let self, let pending = self.pendingCalls.removeValue(forKey: callID) else { return }
            pending(.failure(ShiftCalendarBridgeError(message: "the calendar did not answer in time")))
        }
    }

    static let callTimeout: TimeInterval = 10

    private func resetAfterPageLoss(_ reason: String) {
        AppLog.lifecycle.error("task calendar: \(reason, privacy: .public) - reloading")
        isReady = false
        hasLoaded = false
        let pending = pendingCalls
        pendingCalls = [:]
        for completion in pending.values {
            completion(.failure(ShiftCalendarBridgeError(message: "the calendar reloaded")))
        }
        // Nothing is lost: the page holds no tasks of its own, so a reload
        // is redrawn from the store as soon as it reports ready.
        activate()
    }

    fileprivate func handle(message body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            isReady = true
            refreshDisplayGating(force: true)
            onReady?()
        case "error":
            onPageError?((body["message"] as? String) ?? "the calendar reported an error")
        case "range":
            guard let start = body["start"] as? String, let end = body["end"] as? String else { return }
            if let date = body["date"] as? String { focusedDay = date }
            onRangeChanged?(start, end)
        case "view":
            guard let view = body["view"] as? String else { return }
            onViewSelected?(view)
        case "open":
            guard let id = body["taskID"] as? String else { return }
            if (body["kind"] as? String) == ShiftCalendarEntry.Kind.followUp.rawValue {
                onOpenFollowUp?(id)
            } else {
                onOpenTask?(id)
            }
        case "add":
            guard let day = body["day"] as? String else { return }
            onAddTask?(day, body["time"] as? String)
        case "move":
            guard let id = body["taskID"] as? String, let day = body["day"] as? String else { return }
            if (body["kind"] as? String) == ShiftCalendarEntry.Kind.followUp.rawValue {
                onMoveFollowUp?(id, day, body["time"] as? String)
            } else {
                onMoveTask?(id, day, body["time"] as? String)
            }
        case "reply":
            guard let callID = body["callID"] as? Int,
                  let completion = pendingCalls.removeValue(forKey: callID) else { return }
            if (body["ok"] as? Bool) == true {
                completion(.success(body))
            } else {
                completion(.failure(ShiftCalendarBridgeError(
                    message: (body["message"] as? String) ?? "the calendar could not do that")))
            }
        default:
            break
        }
    }

    // MARK: Display gating
    //
    // `CodePreviewWebView`'s three layers: never loaded until the Calendar page
    // is first shown, WebKit's own visibility state for a hidden view, and an
    // explicit `suspend` so the page's one timer (the now-line's minute tick)
    // stops while nobody can see it.

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
        windowOccluded = false
        guard let window else { return }
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

    /// Same derivation as `CodePreviewWebView.isOnScreen`, including reading
    /// occlusion from the notification rather than live.
    var isOnScreen: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return !windowOccluded && !isHiddenOrHasHiddenAncestor
    }

    func refreshDisplayGating(force: Bool = false) {
        let shouldSuspend = !isOnScreen
        guard force || shouldSuspend != isSuspended else { return }
        isSuspended = shouldSuspend
        guard isReady else { return }
        call(shouldSuspend ? "suspend" : "resume")
    }

    // MARK: Self-test surface

    #if FM_SELFTESTS
    /// Every bridge call made, by name, in order. GL-27: debug builds only.
    var debugCalls: [String] = []
    var debugPendingCallCount: Int { pendingCalls.count }
    /// Feed a message as if the page had posted it.
    func debugHandle(message: [String: Any]) { handle(message: message) }
    #endif
}

/// Breaks the `WKUserContentController` -> handler -> web view retain cycle.
private final class ShiftCalendarMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: ShiftCalendarWebView?
    init(target: ShiftCalendarWebView) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        target?.handle(message: body)
    }
}

// MARK: - Navigation policy and page-loss recovery

extension ShiftCalendarWebView: WKNavigationDelegate {

    /// The bundle's CSP cannot stop a top-level navigation, so this is the
    /// gate - the same `WebNavigationPolicy` the other two web hosts use.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if let dir = ShiftCalendarAssets.webDirectory(),
           WebNavigationPolicy.allowsFileURL(url, under: dir) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        AppLog.lifecycle.info("task calendar: refused a navigation leaving the bundle (\(url.scheme ?? "?", privacy: .public))")
        if WebNavigationPolicy.opensExternally(url) { NSWorkspace.shared.open(url) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resetAfterPageLoss("the web content process was terminated")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A navigation this delegate cancelled arrives here too; it is not a
        // lost page, and reloading on it would loop.
        if (error as NSError).code == NSURLErrorCancelled { return }
        resetAfterPageLoss("the page failed to load (\(error.localizedDescription))")
    }
}
