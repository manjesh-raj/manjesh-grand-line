// Manjesh Grand Line - native macOS app.
//
// F3 (production review section 25): the self-update channel's read half -
// what version am I, what version is published, and is there a difference.
//
// **Why this exists.** The Updates page checks every tool on the machine
// against its real source and can update each one, and the app itself was
// the single thing on that page's list that could not do either: GL-18's
// hardcoded `VERSION="0.1.0"` meant every build ever built reported the same
// number, and there was nothing published to compare it to. GL-18 fixed the
// first half (`build_native_app.sh` derives the version from `git describe`);
// this is the second.
//
// **Why an in-house flow rather than Sparkle.** The report offered both, and
// noted Sparkle would be vendored to stay consistent with this app's
// zero-remote-dependencies rule. Sparkle is not viable here, and the reason
// is a hard constraint rather than a preference: it ships as an Xcode-built
// `.framework` with its own build phases and an embedded XPC bundle, and this
// project builds with plain `swift build` on Command Line Tools with **no
// Xcode at all** (see `native/README.md` and AGENTS.md). Vendoring it as
// source would mean reimplementing its packaging, which is strictly more work
// than the flow it would replace. So: a minimal in-house
// check → download → verify → swap → relaunch, in
// `AppUpdateInstaller.swift`.
//
// **What is honestly not finished.** Verification before the swap requires a
// Developer ID-signed, notarized artifact, which requires a paid Apple
// Developer Program membership and certificates only the captain can obtain.
// `AppUpdateInstaller` therefore *refuses* to install an artifact it cannot
// verify rather than installing it anyway - see that file's header. The
// release workflow (`.github/workflows/release.yml`) has the signing and
// notarization steps written out and disabled, naming the exact secrets the
// captain would add. Nothing here pretends that step is done.

import Foundation

/// This app's own version, read from the bundle it is running out of.
enum AppVersion {

    /// The marketing version - `CFBundleShortVersionString`, which
    /// `build_native_app.sh` sets to the numeric part of `git describe`
    /// (Launch Services requires a plain dotted number there).
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? unbundledPlaceholder
    }

    /// The full build string - `CFBundleVersion`, the whole `git describe`
    /// including commits-ahead, short SHA and `-dirty`. This is the one worth
    /// showing a captain who is debugging "which build am I actually
    /// running", which is why the Updates row shows it as the detail line.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? unbundledPlaceholder
    }

    /// A `swift run` / `.build/debug` binary has no `Info.plist` at all, so
    /// both keys are absent. Saying so is better than showing "0.0.0", which
    /// reads like a real version and would make the update row claim an
    /// update is available on every dev build.
    static let unbundledPlaceholder = "dev build"

    /// `true` when running from a real assembled `.app`. The update flow is
    /// meaningless otherwise - there is no bundle to swap - and the Updates
    /// row says so rather than offering a button that cannot work.
    static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") != nil
    }

    /// Compares two version strings as dotted numeric components, ignoring a
    /// leading `v` and anything after the numeric run (so `v0.2.0-7-gabc` and
    /// `0.2.0` compare equal - a dev build seven commits past a tag is not
    /// "newer than the release" in any sense that should offer an update, and
    /// definitely not older).
    ///
    /// Returns `< 0` if `lhs` is older, `0` if equal, `> 0` if newer.
    /// Missing trailing components are zero, so `1.2` == `1.2.0`.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let a = numericComponents(lhs)
        let b = numericComponents(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    static func numericComponents(_ version: String) -> [Int] {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        // Keep the leading dotted-number run only: `0.2.0-7-gabc1234` -> `0.2.0`.
        var numeric = ""
        for character in trimmed {
            if character.isNumber || character == "." { numeric.append(character) } else { break }
        }
        return numeric.split(separator: ".").compactMap { Int($0) }
    }
}

/// A published release, as far as this app cares about one.
struct AppRelease: Equatable {
    /// The git tag, e.g. `v0.2.0`.
    let tag: String
    /// The human-facing release page, for the "what changed" link.
    let htmlURL: URL
    /// The `.zip` asset holding the built `.app`, if the release has one. A
    /// release with no asset is a real, ordinary state (a tag pushed before
    /// the release workflow existed, or a workflow run that failed) and is
    /// reported as "published, nothing to download" rather than an error.
    let assetURL: URL?
    let assetName: String?
    let assetSize: Int
}

/// The result of asking GitHub what the newest release is.
enum AppUpdateStatus: Equatable {
    /// Running the newest published release (or newer, on a dev build past
    /// the tag).
    case upToDate(current: String, latest: String)
    /// A newer release exists.
    case updateAvailable(current: String, release: AppRelease)
    /// A newer release exists but has no downloadable artifact.
    case updateAvailableWithoutArtifact(current: String, release: AppRelease)
    /// Nothing has been released yet - no tags, or no releases created from
    /// them. Distinct from a failure: there is genuinely nothing to compare
    /// against, and saying "couldn't check" there would be wrong (GL-14's
    /// rule - an empty result and a failed one must never render the same).
    case noReleaseYet(current: String)
    /// Running from a `swift run` binary with no bundle to replace.
    case notBundled
    /// The check itself did not succeed.
    case checkFailed(String)
}

/// Reads the app's own release feed. One fixed repository, in one place, the
/// same way `DotfilesSource.cloneURL` is the single pointer at the captain's
/// config repo.
enum AppUpdateSource {

    /// The repository this app is released from. If it ever moves, this is
    /// the only line to change.
    static let repositoryFullName = "manjesh-raj/manjesh-grand-line"

    static var releasesPageURL: URL {
        URL(string: "https://github.com/\(repositoryFullName)/releases")!
    }

    /// Asks GitHub for the newest release and compares it against the running
    /// bundle. Blocking - callers run it off the main thread, like every
    /// other `*Source` in this app.
    static func check() -> AppUpdateStatus {
        guard AppVersion.isBundled else { return .notBundled }
        let current = AppVersion.short

        switch fetchLatestRelease() {
        case .failure(let reason):
            return .checkFailed(reason)
        case .success(nil):
            return .noReleaseYet(current: current)
        case .success(.some(let release)):
            guard AppVersion.compare(current, release.tag) < 0 else {
                return .upToDate(current: current, latest: release.tag)
            }
            return release.assetURL == nil
                ? .updateAvailableWithoutArtifact(current: current, release: release)
                : .updateAvailable(current: current, release: release)
        }
    }

    enum FetchOutcome {
        case success(AppRelease?)
        case failure(String)
    }

    /// `GET /repos/{owner}/{repo}/releases/latest`. Authenticated
    /// opportunistically through `gh auth token` for the same reason
    /// `DocsSyncSource` does it (the unauthenticated 60/hour-per-IP quota is
    /// shared with every other tool on the machine and is genuinely
    /// exhaustible - see that file's header), but never *required*: this
    /// repository's releases are readable without a token.
    static func fetchLatestRelease() -> FetchOutcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repositoryFullName)/releases/latest") else {
            return .failure("bad release URL")
        }
        var request = URLRequest(url: url)
        request.setValue("FirstmateCockpit", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // The same disk-backed `URLCache` bypass `BackupGitHub` needed: a
        // cached 404 from before the first release existed would otherwise
        // outlive the first real release, across launches.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        if let token = DocsSyncSource.ghAuthToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var statusCode = -1
        var transportError: String?
        let task = URLSession.shared.dataTask(with: request) { body, response, error in
            data = body
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error { transportError = error.localizedDescription }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        // 404 is the honest "no release has ever been published" answer from
        // this endpoint, not a failure.
        if statusCode == 404 { return .success(nil) }
        if statusCode == -1 {
            // GL-14: name the recognisable offline shape rather than echoing
            // a sentinel a captain cannot act on.
            return .failure(transportError.map { "couldn't reach GitHub (\($0))" } ?? "couldn't reach GitHub")
        }
        guard (200..<300).contains(statusCode), let data else {
            return .failure("GitHub returned HTTP \(statusCode)")
        }
        guard let release = parseRelease(data) else {
            return .failure("couldn't read GitHub's release response")
        }
        return .success(release)
    }

    /// Split out from the network call so the parsing is testable against a
    /// recorded payload without a network round trip.
    static func parseRelease(_ data: Data) -> AppRelease? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
                let size: Int
            }
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let htmlURL = URL(string: payload.html_url) else { return nil }
        // A draft is not published and must never be offered; `latest`
        // already excludes drafts, but the field is cheap to honour and this
        // parser is also used against hand-fed payloads in the self-test.
        if payload.draft == true { return nil }

        // The artifact is the one `.zip` asset the release workflow uploads.
        let asset = (payload.assets ?? []).first { $0.name.lowercased().hasSuffix(".zip") }
        return AppRelease(
            tag: payload.tag_name,
            htmlURL: htmlURL,
            assetURL: asset.flatMap { URL(string: $0.browser_download_url) },
            assetName: asset?.name,
            assetSize: asset?.size ?? 0
        )
    }
}
