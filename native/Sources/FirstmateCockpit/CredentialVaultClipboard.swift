// Manjesh Grand Line - native macOS app.
//
// Copy-a-secret-and-clear-it-again. Genuinely new functionality: the report
// confirmed by grep that no clipboard auto-clear mechanism existed anywhere in
// this app before this feature.
//
// **The whole design is one rule: never clear a pasteboard the captain has
// written to since.** `NSPasteboard.changeCount` increments on every write by
// any process, so recording it at copy time and comparing before clearing turns
// "clear after 20 seconds" into "clear after 20 seconds *if nothing else has
// been copied*". Without that check the timer is a hazard rather than a
// safeguard: copy a password, paste it, copy a URL from a browser, and 20
// seconds later this app would silently wipe the URL. The report calls this out
// by name as the safe pattern, and it is the only reason a timer like this is
// acceptable at all.
//
// **Why this is a class with one shared instance rather than a fire-and-forget
// helper.** One pending clear at a time, cancellable: copying a second secret
// must not leave the first copy's timer running to clear the second one early.
// The instance is also what the countdown UI observes.

import AppKit

final class CredentialVaultClipboard {

    static let shared = CredentialVaultClipboard()

    /// Fires every second while a copied value is still on the clipboard, with
    /// the seconds remaining, and once with `nil` when the window closes (the
    /// value was cleared, superseded, or the captain copied something else).
    /// The page's countdown pill is the only subscriber today.
    var onCountdown: ((Int?) -> Void)?

    private var pendingClear: DispatchWorkItem?
    private var ticker: Timer?
    /// The `changeCount` this app's own copy produced. The clear only fires
    /// while the pasteboard still reports exactly this.
    private var copiedChangeCount: Int?
    private var expiresAt: Date?

    private init() {}

    /// Copy `value` and schedule its clear.
    ///
    /// `seconds <= 0` copies without ever clearing - `VaultSettings` has no
    /// such choice today (its four options are all real timeouts), but the
    /// parameter is honest about what 0 would mean rather than silently
    /// treating it as a default.
    func copy(_ value: String, clearAfter seconds: Int) {
        cancelPendingClear()

        // Read *after* the write: this is the count our own copy produced, and
        // it is what a later legitimate copy will move past.
        copiedChangeCount = Self.writeConcealed(value, to: NSPasteboard.general)

        guard seconds > 0 else {
            onCountdown?(nil)
            return
        }

        expiresAt = Date().addingTimeInterval(TimeInterval(seconds))
        let work = DispatchWorkItem { [weak self] in self?.clearIfUntouched() }
        pendingClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)

        onCountdown?(seconds)
        // `.common` modes so the countdown keeps ticking while a menu or a
        // modal sheet is up - the captain may well be mid-paste in another app
        // with a sheet open here. Tolerance because a display timer has no
        // reason to be a hard wake-up (audit §3.4's rule for every `Timer` in
        // this app).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: The concealed write (M2)

    /// The marker pasteboard types that tell the rest of the system this item
    /// is a secret. Writing only `.string` (which is all this class did before
    /// the end-to-end review's M2 finding) makes a copied password an ordinary
    /// clipboard item, with two consequences that both outlive the auto-clear
    /// this class exists for (20s by default, `VaultSettings`-configurable):
    ///
    ///  - **Universal Clipboard / Handoff syncs it over the network** to the
    ///    captain's other Apple devices, which flatly contradicts this
    ///    feature's deliberate `ThisDeviceOnly` Keychain posture.
    ///  - **Clipboard-history managers persist it** (Paste, Alfred, Maccy,
    ///    Raycast...), so the secret survives in a searchable history long
    ///    after this app has cleared the live pasteboard.
    ///
    /// Marking the item is how password managers meet this, and it is the only
    /// lever available: nothing an app writes to `NSPasteboard.general` can be
    /// made unreadable, so the honest goal is "everything that reads this
    /// pasteboard is *told* not to keep or sync it".
    ///
    /// **Be precise about what each marker actually buys**, because they differ:
    ///
    ///  - `org.nspasteboard.ConcealedType` is the documented community
    ///    convention from nspasteboard.org that clipboard-history managers
    ///    check for and honour. This is the load-bearing one for the
    ///    clipboard-history half of the finding.
    ///  - `org.nspasteboard.TransientType` says the content is short-lived, so
    ///    a manager should not archive it. True by construction here - this
    ///    class exists to clear the value again - and it covers a manager that
    ///    honours transience but not concealment.
    ///  - `com.apple.is-sensitive` is an Apple-side marker widely reported to
    ///    suppress Universal Clipboard sync, and it is the only lever anyone
    ///    has for that half of the finding. **Treat it as unverified
    ///    best-effort**, stated plainly rather than dressed up: it is not a
    ///    public documented API constant, this task could not test a real
    ///    two-device Handoff sync, and no amount of marking could *prove* a
    ///    given macOS version honours it. Writing it cannot make anything
    ///    worse, which is the whole argument for including it.
    ///
    /// `org.nspasteboard.AutoGeneratedType` is deliberately **not** written.
    /// It means "this content was not produced by a user selection", and here
    /// the captain pressed Copy - claiming otherwise would be a false statement
    /// to whatever reads it, for no benefit the markers above do not already
    /// give.
    private static let concealedMarkerTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.apple.is-sensitive"),
    ]

    /// Write `value` to `pasteboard` as a concealed item, and return the
    /// `changeCount` the write produced.
    ///
    /// Shared with `CredentialVaultController.copyAccount`, deliberately:
    /// having one function be the only way this app puts credential material
    /// on a pasteboard is what stops a second copy path shipping unmarked, the
    /// way the account copy did.
    ///
    /// The marker payload is empty `Data` - these types are presence flags,
    /// not content. They are written *after* the string so a reader that only
    /// understands `.string` still finds the value where it expects it, and
    /// the `changeCount` is read last: `clearContents()` is what increments it,
    /// so every `setData`/`setString` after that one call shares a single
    /// count, and this class's whole guard depends on recording exactly it.
    @discardableResult
    static func writeConcealed(_ value: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        for marker in concealedMarkerTypes {
            pasteboard.setData(Data(), forType: marker)
        }
        return pasteboard.changeCount
    }

    /// Seconds left before the pending clear, or nil when nothing is pending.
    var secondsRemaining: Int? {
        guard let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSinceNow.rounded(.up)))
    }

    /// Clear now, if the pasteboard is still ours - the "Clear now" action.
    func clearNow() {
        clearIfUntouched()
    }

    private func tick() {
        guard let remaining = secondsRemaining else {
            cancelPendingClear()
            onCountdown?(nil)
            return
        }
        // Somebody else copied something: the clear will no-op when it fires,
        // so stop claiming a countdown that no longer means anything.
        if NSPasteboard.general.changeCount != copiedChangeCount {
            cancelPendingClear()
            onCountdown?(nil)
            return
        }
        onCountdown?(remaining)
    }

    private func clearIfUntouched() {
        defer {
            cancelPendingClear()
            onCountdown?(nil)
        }
        guard let expected = copiedChangeCount else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expected else {
            // The captain copied something else. Leaving it alone is the whole
            // point of tracking the count.
            AppLog.ui.info("credential vault: clipboard changed since the copy - leaving it alone")
            return
        }
        pasteboard.clearContents()
    }

    private func cancelPendingClear() {
        pendingClear?.cancel()
        pendingClear = nil
        ticker?.invalidate()
        ticker = nil
        copiedChangeCount = nil
        expiresAt = nil
    }

    #if FM_SELFTESTS
    /// The `changeCount` this class believes it owns - so a suite can assert
    /// the guard's *decision* rather than only its outcome.
    var copiedChangeCountForTests: Int? { copiedChangeCount }

    /// Run the clear synchronously, as the timer would. Lets a suite drive the
    /// untouched/touched branches without waiting real seconds.
    func clearIfUntouchedForTests() { clearIfUntouched() }
    #endif
}
