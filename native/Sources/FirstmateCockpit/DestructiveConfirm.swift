// Manjesh Grand Line - native macOS app.
//
// GL-06: the one confirmation prompt for an irreversible delete.
//
// The bug this closes: the row-level `⋯` menus in `HostsController` correctly
// confirmed before deleting a host, an SSH key or a snippet - the key one's
// copy even warned that the Keychain private key and passphrase go with it -
// but each editor *sheet's* own Delete button called the same store method
// straight through with no prompt at all. For a key that is unrecoverable
// private-key loss one misclick away, since key material lives only in the
// Keychain and is deliberately excluded from `.glbackup` exports.
//
// This exists as a shared function rather than being fixed three times because
// the third caller lives in `main.swift` (the host editor is a window owned by
// the app delegate, not by `HostsController`), so there was no existing
// `private func confirm` for it to reach.
//
// G3 (UI modernization audit §3G) re-pointed the body at `HelmConfirm`. Every
// caller and every guarantee below is unchanged - what changed is that the
// dialog is now drawn in the app's own language instead of the system's.

import AppKit

enum DestructiveConfirm {

    /// A modal, two-button "are you sure" where Return means Cancel and
    /// Escape means Cancel. Both safe keys do the safe thing - the point of a
    /// confirmation is that a reflexive keypress cannot complete the deletion.
    ///
    /// - Parameters:
    ///   - message: the headline, e.g. `Delete "Prod Bastion"?`.
    ///   - detail: what is actually lost. Say it plainly - this is the last
    ///     thing standing between a click and unrecoverable data.
    ///   - confirmTitle: the destructive button's title (default "Delete").
    ///   - window: present as a sheet on this window when given; app-modal
    ///     otherwise. An editor sheet that is about to close should pass `nil`
    ///     and let this run app-modally.
    /// - Returns: `true` only if the captain explicitly chose the destructive
    ///   button.
    @discardableResult
    static func confirm(message: String,
                        detail: String,
                        confirmTitle: String = "Delete",
                        window: NSWindow? = nil) -> Bool {
        // G3: the app's own themed confirm rather than a centre-screen
        // system alert. The *semantics* are byte-for-byte what they were -
        // `confirmIsDefault: false` is what keeps Return on Cancel, which is
        // this function's whole reason for putting Cancel first.
        //
        // `window:` is still accepted and still unread. It was already unread
        // before G3 (the body always ran app-modally), and making it real now
        // would be a behaviour change smuggled into a restyle - two callers
        // pass it and would silently move from app-modal to sheet-modal.
        return HelmConfirm.confirm(title: message,
                                   body: detail,
                                   confirmTitle: confirmTitle,
                                   destructive: true,
                                   confirmIsDefault: false,
                                   symbol: "trash.fill",
                                   hue: .rose)
    }
}
