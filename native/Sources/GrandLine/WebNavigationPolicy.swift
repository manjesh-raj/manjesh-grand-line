// Grand Line - native macOS app.
//
// The one answer to "may this web view navigate here?", shared by all three of
// this app's `WKWebView` hosts (Docs' playbook viewer, the Whiteboard's
// Excalidraw bundle, Code Preview's Monaco bundle).
//
// ## Why this exists (audit §5.3 / §5.4)
//
// Both vendored bundles ship a hard CSP (`default-src 'self'`, `connect-src
// 'self'`, `object-src 'none'`, `base-uri 'none'`) and are loaded with
// `loadFileURL(_:allowingReadAccessTo:)` scoped to their own directory - and
// none of that stops a *top-level navigation*. WebKit does not implement CSP's
// `navigate-to` directive, so a `window.location = "https://…"` from a
// compromised or newly-updated vendored bundle would simply go out, carrying
// whatever the page knows in its URL. Docs already cancelled that class of
// navigation; the two AI-adjacent surfaces did not.
//
// The second half is §5.4: Docs' own containment check was
// `path.hasPrefix(docsPath)`, which is a *string* prefix - so a sibling
// directory named `…/docs-evil/` matches `…/docs` and would have been treated
// as inside the synced folder. The check here is path-*component*-wise, which
// is the only form that cannot be defeated by a longer sibling name.
//
// One definition rather than three copies, because three copies is how the
// prefix bug ends up fixed in one of them.

import AppKit
import Foundation

enum WebNavigationPolicy {

    /// Is `url` a file URL genuinely inside `directory`?
    ///
    /// Component-wise, never a string prefix: `/a/docs-evil/x` is not inside
    /// `/a/docs`, though its path very much has that prefix. The directory
    /// itself counts as inside it, so the bundle's own `index.html` parent
    /// never has to be special-cased.
    ///
    /// Both sides are standardized (which resolves `..`, so a traversal
    /// cannot walk out and back in) and symlink-resolved before comparison -
    /// resolving is what makes the two comparable at all when one side
    /// reaches the same real directory through a symlink (macOS's own
    /// `/var` -> `/private/var` is the everyday case), and it also means a
    /// symlink planted *inside* the bundle pointing outward resolves to its
    /// real target and is refused.
    ///
    /// Deliberately case-*sensitive* even though the default macOS volume is
    /// not: every URL this is asked about is derived from the very path this
    /// app handed to `loadFileURL`, so the casing matches, and erring toward
    /// refusal is the right direction for a security check.
    static func allowsFileURL(_ url: URL, under directory: URL) -> Bool {
        guard url.isFileURL else { return false }
        let target = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard !root.isEmpty, target.count >= root.count else { return false }
        return Array(target.prefix(root.count)) == root
    }

    /// Should a refused navigation be handed to the system browser instead?
    ///
    /// Only a real web URL. A refused `file:`/`blob:`/`data:`/custom-scheme
    /// navigation out of a *fixed local bundle* is anomalous by definition -
    /// there is no legitimate one - so it is dropped silently rather than
    /// handed to `NSWorkspace`, which would otherwise open an arbitrary local
    /// path in Finder or a helper app on the page's say-so.
    ///
    /// All three hosts use this now. Docs used to opt out - it hosts a
    /// browsable site, so any outbound *web* link may be legitimate - but S4
    /// of the 2026-09-25 review pointed out that "any outbound link" was
    /// being read as "any URL of any scheme", against content that is a
    /// synced copy of a remote repository. A `shortcuts://` or
    /// `x-apple.systempreferences:` URL in a doc fired a system action just
    /// by the page being viewed. `http`/`https` is what a browsable site
    /// needs; nothing else is.
    static func opensExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Hands `url` to the system only when `opensExternally` allows it.
    ///
    /// R2-SEC-11: the one way to open a URL that came from data rather than
    /// from this app's own source - a pull request link from a forge's API, a
    /// notification's URL, a fork's name, a saved reading-list link. Those
    /// were handed to `NSWorkspace` as they arrived, so a forge response (or a
    /// git-synced store) carrying `file:` or a custom scheme opened a local
    /// path or fired a system action on a click. The web views already
    /// applied this check; these sites now apply the same one.
    /// `source` names the surface for the refusal's log line.
    @discardableResult
    static func openExternally(_ url: URL, from source: String) -> Bool {
        guard opensExternally(url) else {
            AppLog.ui.error("refused to open a \(url.scheme ?? "scheme-less", privacy: .public) URL from \(source, privacy: .public)")
            return false
        }
        #if FM_SELFTESTS
        if let opener = openerForTests {
            opener(url)
            return true
        }
        #endif
        NSWorkspace.shared.open(url)
        return true
    }

    #if FM_SELFTESTS
    /// Records what would have been opened, so a suite never opens a browser.
    /// Every user restores `nil`.
    static var openerForTests: ((URL) -> Void)?
    #endif
}
