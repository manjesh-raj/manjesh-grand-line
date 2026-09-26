// Grand Line - native macOS app.
//
// F12's AppKit half: the global keyboard monitor that notices a `;abbrev`
// being typed anywhere on the machine, and the injection that replaces it with
// the snippet's text. `SnippetExpansion.swift` holds every decision this file
// makes; this one is the plumbing around them.
//
// ## Why this is not a second Accessibility integration
//
// The task brief is explicit, and it is right: a second global-input mechanism
// would mean a second permission story for one grant. There is exactly one
// "Grand Line" entry in System Settings > Privacy & Security > Accessibility,
// and three features now hang off it - `ShiftGlobalHotkey` (⌥Space),
// `DictationHotkey` (hold-to-dictate) and this. All three use the same pair of
// `NSEvent` monitors (a **local** one for "this app is frontmost", a **global**
// one that macOS only delivers to a trusted Accessibility client), and the
// injection reuses `DictationEngine.pasteAtCursor` verbatim rather than
// reimplementing the pasteboard + synthetic ⌘V dance. See that method's own
// comment for why a synthetic ⌘V beats `AXUIElement` text insertion here.
//
// ## What a test can and cannot prove about this file
//
// `injectionSinkForTests` is the seam, and it is the same idea as
// `DictationEngine.pasteSinkForTests` for the same reason: a suite can drive
// real `NSEvent`s through `handle(_:)` and assert exactly what *would* have
// been injected, without typing the captain's fixtures into whatever app
// happens to be frontmost.
//
// What no CI-safe test can exercise is the last inch: whether the synthetic
// backspaces and the synthetic ⌘V actually land in another application. That
// needs a real Accessibility grant, a real frontmost app and a real HID event
// tap, none of which a headless runner (or this repo's own agent shell, which
// has no Accessibility permission - see AGENTS.md's "Verifying native UI bugs"
// section) has. It is stated here and in the PR rather than faked.
//
// ## Keystroke privacy, stated plainly
//
// The monitor sees every key the captain presses while it is installed - that
// is what a system-wide expander is. What this file does with them is bounded
// and deliberate: characters go into `SnippetTypingBuffer`, a rolling window
// of at most `SnippetTypingBuffer.capacity` characters that is cleared on
// every terminator, every click, every app switch and every non-typing key.
// Nothing is written to disk, nothing is logged (the `AppLog` lines below name
// the *trigger* that fired, never the run that produced it), and nothing
// leaves the process. The monitors are torn down entirely when the feature is
// off, so "off" means the buffer does not exist rather than that it is
// ignored.

import AppKit
import ApplicationServices

/// What an expansion would do to the frontmost app, as one value. The real
/// path carries it out; a suite reads it.
struct SnippetInjection: Equatable {
    /// Synthetic backspaces to send first: the `;`, the abbreviation and the
    /// terminator the captain typed.
    let deleteCount: Int
    /// The text to paste - placeholders resolved, the terminator re-appended.
    let text: String
    /// Synthetic left-arrows to send afterwards, so the caret lands where
    /// `{{cursor}}` was. Zero for a snippet without one.
    let caretLeftCount: Int
}

final class SnippetExpander {

    // MARK: Collaborators

    private let store: SnippetStore

    /// Whether this app is frontmost *and* the Console is the destination on
    /// screen - the `.consoleOnly` scope's whole question. Injected because
    /// the answer lives in `AppShellController`, and a monitor reaching into
    /// the shell controller is the coupling this codebase's
    /// forward-don't-own convention exists to avoid (see `AppLockGate`'s own
    /// header making the same argument).
    var isConsoleFocusedProvider: (() -> Bool)?

    /// GL-29 / the live-clock rule: `{{date}}` and `{{time}}` read this, never
    /// `Date()` of their own, so a suite can fabricate an instant.
    var clock: () -> Date = { Date() }

    /// Set, every expansion is reported here instead of touching the
    /// pasteboard or posting a synthetic keystroke. Never set in the shipping
    /// app.
    var injectionSinkForTests: ((SnippetInjection) -> Void)?

    /// Set, `currentContext()` returns this instead of asking the OS. Lets a
    /// suite assert the policy against a frontmost app that is not really
    /// frontmost. Never set in the shipping app.
    var contextOverrideForTests: SnippetExpansionContext?

    /// The last refusal, so the UI can answer "I typed `;sig` and nothing
    /// happened". Only set when a trigger genuinely matched a snippet.
    private(set) var lastRefusal: (trigger: String, refusal: SnippetExpansionRefusal)?

    // MARK: State

    private var table: SnippetTriggerTable
    private var buffer = SnippetTypingBuffer()
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    private(set) var isRunning = false

    /// How many saved snippets have a usable trigger right now - what the
    /// Snippets page's card reports. Derived from the table rather than
    /// recounted, so the number and the behaviour cannot disagree.
    var armedTriggerCount: Int { table.count }

    init(store: SnippetStore) {
        self.store = store
        self.table = SnippetTriggerTable(store.snippets)
    }

    deinit { stop() }

    // MARK: Permission

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// The same one-grant prompt `DictationHotkey.requestPermissionIfNeeded`
    /// and `ShiftGlobalHotkey` use. A no-op once granted.
    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Lifecycle

    /// Installs the monitors iff the feature is on. Safe to call repeatedly -
    /// the Settings toggle, the store's own `onChange` and launch all route
    /// here, and each one re-derives from scratch rather than assuming.
    func refresh() {
        rebuildTable()
        if AppSettings.shared.snippetExpansionEnabled {
            start()
        } else {
            stop()
        }
    }

    func rebuildTable() {
        table = SnippetTriggerTable(store.snippets)
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        // AGENTS.md gotcha (21): a global `NSEvent` monitor is armed from the
        // trust the process held **when it was registered**, and macOS does
        // not arm one retroactively. Recorded at install time so
        // `reassertIfTrustChanged()` can notice the transition and so the
        // Settings card can say "granted, but this monitor predates the
        // grant" rather than only "granted" (B20).
        installedWhileTrusted = isAccessibilityTrusted
        buffer = SnippetTypingBuffer()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        // A click moves the caret somewhere this buffer knows nothing about,
        // so the run is over. Same for a right-click's menu.
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouse) { [weak self] event in
            self?.abandonRun()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self] _ in
            self?.abandonRun()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.abandonRun()
        }
        AppLog.lifecycle.info("snippet expander: monitors installed")
    }

    /// Whether the process was a trusted Accessibility client at the moment
    /// the current monitors were installed. See `start()`.
    private(set) var installedWhileTrusted = false

    /// True when the feature is on and its monitors were installed **after**
    /// Accessibility trust was granted - i.e. when a system-wide trigger will
    /// genuinely fire.
    ///
    /// The Settings card reads this rather than `isAccessibilityTrusted`
    /// alone. B20: on the launch that first prompts for Accessibility, the
    /// monitors are installed before the captain grants it, so the card said
    /// "Granted - 4 triggers armed" over a monitor that was permanently deaf
    /// until the next relaunch, and nothing anywhere said so.
    var isArmed: Bool { isRunning && installedWhileTrusted && isAccessibilityTrusted }

    /// Reinstalls the monitors if Accessibility trust has been granted since
    /// they were installed.
    ///
    /// `ShiftGlobalHotkey.reassertIfTrustChanged()` verbatim, for the same
    /// reason and driven from the same `didBecomeActiveNotification`: coming
    /// back to this app is the first moment the grant can be noticed, and the
    /// check is one `AXIsProcessTrusted()` read that returns immediately
    /// unless the answer actually changed.
    @discardableResult
    func reassertIfTrustChanged() -> Bool {
        guard isRunning, !installedWhileTrusted, isAccessibilityTrusted else { return false }
        AppLog.lifecycle.info("snippet expander: accessibility granted since install - reinstalling monitors")
        stop()
        start()
        return true
    }

    func stop() {
        for monitor in [localKeyMonitor, globalKeyMonitor, localMouseMonitor, globalMouseMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localKeyMonitor = nil
        globalKeyMonitor = nil
        localMouseMonitor = nil
        globalMouseMonitor = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        // Not merely "stop reading it" - the run is dropped, so turning the
        // feature off leaves nothing of the captain's typing behind.
        buffer = SnippetTypingBuffer()
        installedWhileTrusted = false
        guard isRunning else { return }
        isRunning = false
        AppLog.lifecycle.info("snippet expander: monitors removed")
    }

    private func abandonRun() {
        _ = buffer.consume(.abandon)
    }

    // MARK: The keystroke path

    /// Internal (not `private`) so the self-tests can drive it with synthetic
    /// `NSEvent`s, the same seam `DictationHotkey.handleKeyEvent` exposes and
    /// for the same reason.
    func handle(_ event: NSEvent) {
        for typingEvent in Self.typingEvents(for: event) {
            guard let typed = buffer.consume(typingEvent) else { continue }
            attemptExpansion(of: typed)
        }
    }

    /// The whole classification of a real key event into this feature's three
    /// abstract events. Static and `NSEvent`-in/value-out so the mapping is
    /// assertable on its own.
    static func typingEvents(for event: NSEvent) -> [SnippetTypingEvent] {
        // A command/control/function chord is a verb, not typing - and it
        // very often moves the caret (⌘←, ⌥⌫, ⌘V). Shift, option and caps
        // lock are how ordinary characters get typed, so they are not here.
        let disqualifying: NSEvent.ModifierFlags = [.command, .control, .function]
        if !event.modifierFlags.intersection(disqualifying).isEmpty { return [.abandon] }

        switch event.keyCode {
        case 51:
            // B20: ⌥⌫ deletes a whole **word** and ⌘⌫ deletes to the start of
            // the line, and both of them arrived here as one plain backspace -
            // so the buffer dropped a single character while the screen lost
            // the lot. The run is over either way; guessing how many
            // characters the receiving app removed is not something this
            // buffer can do, and guessing wrong is what made a later `;sig`
            // expand against a trigger that was no longer on screen. (⌘ is
            // already disqualifying above, so this is really about ⌥ - it is
            // written for both so the rule survives that list changing.)
            let wordwise: NSEvent.ModifierFlags = [.option, .command]
            return event.modifierFlags.intersection(wordwise).isEmpty ? [.backspace] : [.abandon]
        case 36, 76, 48, 53: return [.abandon]          // return, enter, tab, escape
        case 115...121, 123...126: return [.abandon]    // home/end/page, arrows
        default: break
        }

        guard let characters = event.characters, !characters.isEmpty else { return [.abandon] }
        var events: [SnippetTypingEvent] = []
        for character in characters {
            // A control character that got this far (an unmapped key, a dead
            // key's commit) ends the run rather than joining it.
            if let scalar = character.unicodeScalars.first,
               scalar.value < 32, !SnippetTrigger.isTerminator(character) {
                events.append(.abandon)
            } else {
                events.append(.character(character))
            }
        }
        return events
    }

    private func attemptExpansion(of typed: SnippetTypedTrigger) {
        guard let snippet = table.snippet(for: typed) else { return }
        let context = currentContext()
        if let refusal = SnippetExpansionPolicy.refusal(for: snippet, in: context) {
            lastRefusal = (SnippetTrigger.display(typed.abbreviation), refusal)
            // The trigger is the captain's own label for a snippet they saved,
            // not free text they were typing - so naming it in the log is
            // useful rather than disclosing. The typed run never appears.
            AppLog.lifecycle.info("""
                snippet expander: refused \(SnippetTrigger.display(typed.abbreviation), privacy: .public) \
                - \(String(describing: refusal), privacy: .public)
                """)
            return
        }
        lastRefusal = nil
        inject(expansion(for: snippet, typed: typed))
    }

    /// Pure enough to assert: given a snippet and what was typed, this is what
    /// the frontmost app is about to receive.
    func expansion(for snippet: Snippet, typed: SnippetTypedTrigger) -> SnippetInjection {
        let resolved = SnippetPlaceholders.resolve(snippet.command,
                                                   now: clock(),
                                                   clipboard: Self.clipboardText())
        // The terminator is re-typed rather than eaten: the captain typed
        // `;sig ` meaning "signature, then a space", and swallowing the space
        // would make every expansion need one more keystroke than the trigger
        // it replaced.
        let text = resolved.text + String(typed.terminator)
        let caretLeft = resolved.caretOffsetFromEnd == 0 ? 0 : resolved.caretOffsetFromEnd + 1
        return SnippetInjection(deleteCount: typed.typedLength, text: text, caretLeftCount: caretLeft)
    }

    // MARK: Context

    func currentContext() -> SnippetExpansionContext {
        if let contextOverrideForTests { return contextOverrideForTests }
        let frontmost = NSWorkspace.shared.frontmostApplication
        return SnippetExpansionContext(
            expansionEnabled: AppSettings.shared.snippetExpansionEnabled,
            accessibilityTrusted: isAccessibilityTrusted,
            // GL-09. The gate belongs at the trigger, exactly as
            // `DictationHotkey`'s does: a snippet that fired while the app was
            // locked would type the captain's saved text into whatever a
            // passer-by had open.
            appIsLocked: !AppLockGate.shared.allows(.snippetExpansion),
            isGrandLineFrontmost: frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            isConsoleFocused: isConsoleFocusedProvider?() ?? false,
            frontmostBundleID: frontmost?.bundleIdentifier,
            frontmostAppName: frontmost?.localizedName
        )
    }

    /// `nil` rather than the string whenever the pasteboard is carrying vault
    /// material. `CredentialVaultClipboard.isConcealed` is this app's one
    /// definition of that, and it is asked **before** the string is read -
    /// so "a vault secret never reaches a snippet" is a property of the
    /// control flow rather than of a filter someone could reorder.
    /// The pasteboard is a parameter (defaulting to the real one) purely so a
    /// suite can prove the refusal against a real, really-marked pasteboard
    /// rather than describing it.
    static func clipboardText(_ pasteboard: NSPasteboard = .general) -> String? {
        guard !CredentialVaultClipboard.isConcealed(pasteboard) else { return nil }
        return pasteboard.string(forType: .string)
    }

    // MARK: Injection

    private func inject(_ injection: SnippetInjection) {
        if let injectionSinkForTests {
            injectionSinkForTests(injection)
            return
        }
        guard isAccessibilityTrusted else { return }

        // Preserve the captain's clipboard across the expansion - but only
        // when it is not a vault secret. Re-writing a concealed item as a
        // plain string would strip the very markers
        // `CredentialVaultClipboard.isConcealed` exists to find, which would
        // hand it straight to the clipboard history this app also ships.
        //
        // B20: this used to capture `string(forType: .string)` alone, so an
        // expansion silently destroyed a copied image, a copied file, an RTF
        // run with its formatting, or a URL with its title - everything got
        // put back as its plain-text shadow, or as nothing at all.
        // `PasteboardSnapshot` carries every item and every type.
        let restorable = CredentialVaultClipboard.isConcealed()
            ? nil : PasteboardSnapshot.take(.general)

        for _ in 0..<injection.deleteCount { Self.postKey(Self.deleteKeyCode) }

        // One run-loop hop before the paste. The backspaces above and the ⌘V
        // below are separate synthetic events into the same HID tap, and the
        // receiving app processes them on its own run loop - posting them back
        // to back has been observed elsewhere to let a paste overtake the last
        // delete. This is a pragmatic ordering guard, not a measured constant;
        // it is called out in the PR as one of the parts only real-hardware
        // use can confirm.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            DictationEngine.pasteAtCursor(injection.text)
            // What the pasteboard reads as immediately after *our* write. The
            // restore below refuses unless it is still this - see
            // `clipboardRestoreDelay`.
            let ours = NSPasteboard.general.changeCount

            // The caret arrows do not touch the pasteboard, so they keep the
            // short hop they always had.
            if injection.caretLeftCount > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    for _ in 0..<injection.caretLeftCount { Self.postKey(Self.leftArrowKeyCode) }
                }
            }

            guard let restorable else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardRestoreDelay) {
                // B20: the restore raced the receiver. A synthetic ⌘V is
                // delivered to another process's run loop, and that process
                // reads the pasteboard whenever it gets round to it - a slow
                // or busy receiver read *after* the old contents had been put
                // back, and pasted the wrong thing. A longer wait makes that
                // rarer and cannot make it impossible, so the restore is also
                // **conditional**: if anything has written to the pasteboard
                // since our own write, that write is newer than this snapshot
                // and putting the snapshot back would be the destructive
                // answer.
                guard NSPasteboard.general.changeCount == ours else {
                    AppLog.lifecycle.info("snippet expander: pasteboard changed since the expansion - leaving it alone")
                    return
                }
                restorable.restore(to: .general)
            }
        }
    }

    /// How long to leave the expansion on the pasteboard before putting the
    /// captain's own contents back.
    ///
    /// Deliberately much longer than the 0.08s it was: the only thing this
    /// delay protects is a receiving app that has not yet got round to reading
    /// the pasteboard for the synthetic ⌘V, and half a second of a stale
    /// clipboard is a far cheaper failure than a paste that lands empty. The
    /// `changeCount` guard at the restore site is what makes the wait safe to
    /// lengthen.
    static let clipboardRestoreDelay: TimeInterval = 0.6

    static let deleteKeyCode: CGKeyCode = 51
    static let leftArrowKeyCode: CGKeyCode = 123

    private static func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Self-test surface (GL-27 - the accessors are guarded at their use site)

    #if FM_SELFTESTS
    /// Feed a whole string as if it had been typed, one character at a time.
    /// The suites' main entry point - it exercises the real buffer and the
    /// real policy, and reports through `injectionSinkForTests`.
    func debugType(_ text: String) {
        for character in text {
            guard let typed = buffer.consume(.character(character)) else { continue }
            attemptExpansion(of: typed)
        }
    }

    func debugAbandonRun() { abandonRun() }

    var debugTypedRun: String { buffer.run }
    #endif
}
