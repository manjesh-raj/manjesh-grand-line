// Grand Line - native macOS app.
//
// F4's title/favicon/summary, through Apple's own `LinkPresentation` and
// nothing else. The report's wording is "local `LinkPresentation`", and
// "local" is the operative half: `LPMetadataProvider` fetches **the page
// itself** and reads its own `<title>`/`og:` tags in-process. No metadata
// service, no API key, no third party learning what the captain reads.
//
// ## The seam, and why there is one
//
// `LPMetadataProvider` is a network call. A self-test that drove it would be
// asserting the weather - so the fetch is behind `ReadingListMetadataFetching`
// and the controller holds whichever conforming fetcher it was given. The
// real one is `LinkPresentationMetadataFetcher`; suites inject a canned one
// and assert what the *card* does with each of the three outcomes, which is
// the part that can actually regress.
//
// This is the same shape `ClaudeOneShot`'s per-caller
// `claudePathOverrideForTests` seams already use, for the same reason: the
// interesting behaviour is on this side of the boundary.
//
// ## What is stored, and what is not
//
// Title and description go into the link's own record. The **favicon does
// not** - it is written as a PNG under `reading-list/icons/<host>.png`, one
// file per host rather than one per link, so twenty saved kubernetes.io
// articles cost one small file instead of twenty base64 blobs inside a
// git-synced YAML document nobody can read a diff of.
//
// A host with no usable icon simply has no file, and the card falls back to
// the monogram tile - which is what the reviewed mockup draws in the first
// place, so the fallback is the design rather than a degraded state.

import AppKit
import Foundation
import LinkPresentation

/// What one fetch produced.
struct ReadingListMetadata: Equatable {
    var title: String
    var summary: String
    /// PNG bytes for the site's icon, when the page offered one this machine
    /// could decode. `nil` is ordinary - see the file header.
    var iconPNG: Data?

    init(title: String = "", summary: String = "", iconPNG: Data? = nil) {
        self.title = title
        self.summary = summary
        self.iconPNG = iconPNG
    }
}

/// The seam. One method, callback on the main thread exactly once - the same
/// contract `ClaudeOneShot.run` gives its callers, so a page never has to
/// think about which queue a result arrived on.
protocol ReadingListMetadataFetching: AnyObject {
    func fetch(url: String, completion: @escaping (Result<ReadingListMetadata, ReadingListMetadataError>) -> Void)
}

struct ReadingListMetadataError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - The real one

final class LinkPresentationMetadataFetcher: ReadingListMetadataFetching {

    /// Bounded, like every other outbound call in this app.
    ///
    /// `LPMetadataProvider` has its own `timeout` property, and it is set
    /// **as well as** the guard below rather than instead of it: the provider
    /// cancels its own fetch, but a completion handler that never arrives at
    /// all would leave a card saying "fetching\u{2026}" for the rest of the
    /// session, and a card stuck on a state that is no longer true is exactly
    /// what GL-14 is about.
    static let timeout: TimeInterval = 15

    /// How large an icon this will decode. A favicon is a few kilobytes; a
    /// megabyte of PNG behind `apple-touch-icon` is not something to write
    /// into the captain's config repo once per host.
    static let maximumIconBytes = 256 * 1024

    /// The side the icon is normalised to before it is written. One size for
    /// every host, so the card's tile never has to scale a 512pt raster down
    /// on every render.
    static let iconSide: CGFloat = 32

    func fetch(url: String,
               completion: @escaping (Result<ReadingListMetadata, ReadingListMetadataError>) -> Void) {
        guard let parsed = URL(string: url) else {
            DispatchQueue.main.async {
                completion(.failure(ReadingListMetadataError(message: "That is not a URL this app can open.")))
            }
            return
        }

        let provider = LPMetadataProvider()
        provider.timeout = Self.timeout

        // `startFetchingMetadata` promises one call; the latch is here because
        // the watchdog below can also complete, and two completions would
        // update a card twice with different verdicts. One `NSLock`, one
        // write, one read - GL-28's shape.
        let lock = NSLock()
        var finished = false
        func finish(_ result: Result<ReadingListMetadata, ReadingListMetadataError>) {
            lock.lock()
            let alreadyDone = finished
            finished = true
            lock.unlock()
            guard !alreadyDone else { return }
            DispatchQueue.main.async { completion(result) }
        }

        // The watchdog: a provider whose handler never fires at all. Generous
        // against its own timeout so the provider's own, better-worded failure
        // wins the race in every ordinary case.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout + 5) {
            finish(.failure(ReadingListMetadataError(
                message: "\(parsed.host ?? "The site") did not answer in time.")))
        }

        provider.startFetchingMetadata(for: parsed) { metadata, error in
            if let error {
                finish(.failure(ReadingListMetadataError(message: Self.describe(error))))
                return
            }
            guard let metadata else {
                finish(.failure(ReadingListMetadataError(message: "That page returned no readable metadata.")))
                return
            }
            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = Self.summary(from: metadata)

            guard let iconProvider = metadata.iconProvider else {
                finish(.success(ReadingListMetadata(title: title, summary: summary)))
                return
            }
            Self.loadIcon(iconProvider) { png in
                finish(.success(ReadingListMetadata(title: title, summary: summary, iconPNG: png)))
            }
        }
    }

    /// `LPLinkMetadata` carries no description property of its own, so the
    /// page's `og:description` is read out of the value it *does* expose -
    /// `_summary` is private API and is deliberately not touched. What is
    /// available publicly is the remote video/image metadata and the title;
    /// where nothing usable exists this returns "" and the card simply has no
    /// summary well until the captain asks for an AI one, which is the
    /// mockup's own middle card.
    private static func summary(from metadata: LPLinkMetadata) -> String {
        // `originalURL`'s own fragment is occasionally the only human-readable
        // thing a link carries (a deep link into a long doc). It is a weak
        // signal and is used only when it is genuinely wordy, never as a
        // stand-in for a description that does not exist.
        guard let fragment = metadata.originalURL?.fragment?
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              fragment.contains(" "), fragment.count >= 12 else { return "" }
        return "Saved at the section \u{201C}\(fragment)\u{201D}."
    }

    private static func loadIcon(_ provider: NSItemProvider,
                                 completion: @escaping (Data?) -> Void) {
        guard provider.canLoadObject(ofClass: NSImage.self) else {
            completion(nil)
            return
        }
        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
            guard let image = object as? NSImage else {
                completion(nil)
                return
            }
            completion(normalisedPNG(image))
        }
    }

    /// Redraw whatever arrived at `iconSide` and hand back PNG bytes.
    ///
    /// `lockFocus` into an `NSImage`'s own bitmap cache needs no window server
    /// - AGENTS.md's self-test classification note says so explicitly - which
    /// is what keeps this callable from a headless context.
    static func normalisedPNG(_ image: NSImage) -> Data? {
        let side = iconSide
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count <= maximumIconBytes else { return nil }
        return png
    }

    /// `LPError`'s own cases, in this app's voice. The raw
    /// `localizedDescription` is "An error occurred" for most of them, which
    /// tells a captain nothing about whether to retry.
    static func describe(_ error: Error) -> String {
        guard let lp = error as? LPError else { return error.localizedDescription }
        switch lp.code {
        case .metadataFetchTimedOut: return "That site did not answer in time."
        case .metadataFetchCancelled: return "The fetch was cancelled."
        case .metadataFetchFailed: return "That page could not be read."
        case .unknown: return "That page could not be read."
        default: return error.localizedDescription
        }
    }
}

// MARK: - The favicon cache

/// Where a host's icon lives on disk, and the one place that decides it.
///
/// Keyed by **host**, not by link id - see the file header. The filename is
/// sanitised rather than trusted: a host comes out of a URL the captain
/// pasted, and a `..` in it would write outside the folder.
enum ReadingListIconCache {

    static func filename(forHost host: String) -> String? {
        var out = ""
        for scalar in host.lowercased() {
            if scalar.isLetter || scalar.isNumber || scalar == "-" || scalar == "." {
                out.append(scalar)
            } else {
                out.append("-")
            }
        }
        // A name that is only dots would land on `.` or `..`, which is the
        // path-escape this guard exists for.
        guard out.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return String(out.prefix(96)) + ".png"
    }
}
