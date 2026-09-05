// Manjesh Grand Line - native macOS app.
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
    /// Docs deliberately does not use this: it hosts a browsable site where
    /// any outbound link may be legitimate, and it has always opened whatever
    /// it cancelled. That difference is the point - see each call site.
    static func opensExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
