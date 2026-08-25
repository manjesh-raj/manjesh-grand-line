// Manjesh Grand Line - native macOS app.
//
// Where the Whiteboard destination's web bundle lives, and how it is found.
//
// The bundle itself (`native/Vendor/Excalidraw/web/`) is a committed, vendored
// build of the real `@excalidraw/excalidraw` package - see that directory's
// README for provenance, licensing and how to regenerate it. Nothing here
// builds, downloads or updates it: this file only answers "where is it on this
// machine", and answers `nil` rather than crashing when it is missing.
//
// The resolution order is `SRELead.resolveKubectlScript()`'s, verbatim in
// spirit - the same problem (a real file this app ships that has to be findable
// both from an assembled `.app` and from the `swift build`/`swift run` dev
// flow), so the same three-step answer rather than a second invention:
//
//   1. `Bundle.main.resourceURL` - the assembled `.app`, where
//      `build_native_app.sh` copies the directory into `Contents/Resources`
//      exactly as it already does for `icon.icns` and `sre_kubectl_mcp.py`.
//   2. `FM_WHITEBOARD_WEB_DIR` - an explicit override, for a self-test or for
//      pointing a running app at a freshly rebuilt bundle.
//   3. A walk up from the current working directory looking for
//      `native/Vendor/Excalidraw/web` - the dev flow.
//
// **Deliberately not `Bundle.module`.** An SPM resource bundle's generated
// accessor `fatalError`s when it cannot resolve its path, and this app's own
// bundle assembly does not lay resource bundles out where that accessor looks -
// `Vendor/whisper.cpp/README.md` and `CaptainIcon.swift` both record that
// lesson. A missing whiteboard bundle has to degrade to a legible empty state,
// never to a crash on a destination the captain merely clicked.

import Foundation

enum WhiteboardAssets {

    /// The directory holding `index.html`, `whiteboard.js`, `whiteboard.css`
    /// and `fonts/`. `nil` when no candidate has a readable `index.html`.
    static func webDirectory() -> URL? {
        let fm = FileManager.default

        func isUsable(_ dir: URL) -> Bool {
            fm.isReadableFile(atPath: dir.appendingPathComponent(indexFileName).path)
        }

        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent(bundleDirectoryName, isDirectory: true)
            if isUsable(candidate) { return candidate }
        }
        if let override = ProcessInfo.processInfo.environment["FM_WHITEBOARD_WEB_DIR"] {
            let candidate = URL(fileURLWithPath: override, isDirectory: true)
            if isUsable(candidate) { return candidate }
        }
        var dir = fm.currentDirectoryPath
        for _ in 0..<6 {
            let candidate = URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent("native/Vendor/Excalidraw/web", isDirectory: true)
            if isUsable(candidate) { return candidate }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// Is the bundle on this machine at all? Cheap enough to ask on every
    /// render (one `stat`), and the honest input to an empty state rather than
    /// a claim cached at launch that a rebuild would invalidate.
    static var isAvailable: Bool { webDirectory() != nil }

    /// The page to load. `nil` propagates "no bundle on this machine".
    static func indexURL() -> URL? {
        webDirectory()?.appendingPathComponent(indexFileName)
    }

    /// What the empty state says when the bundle is missing. Names the real
    /// script rather than telling the captain to reinstall: the one way this
    /// happens is a source checkout whose vendored bundle was not committed or
    /// an `.app` assembled by something other than `build_native_app.sh`.
    static let missingBundleMessage =
        "The Excalidraw bundle isn't on this machine. Run native/Scripts/build-excalidraw-web.sh " +
        "to regenerate native/Vendor/Excalidraw/web, or set FM_WHITEBOARD_WEB_DIR to point at it."

    /// The name `build_native_app.sh` copies the directory to inside
    /// `Contents/Resources`. Shared with that script by convention, not by
    /// mechanism - keep the two in step.
    static let bundleDirectoryName = "ExcalidrawWeb"

    static let indexFileName = "index.html"
}
