// Manjesh Grand Line - native macOS app.
//
// F3's write half: download the published artifact, **verify it**, swap the
// bundle, relaunch.
//
// # The verification gate is the whole point of this file
//
// A self-update mechanism that installs whatever it downloaded is a remote
// code execution channel with extra steps: anything that can answer a GitHub
// API call or serve a redirect can replace the app the captain runs, on a
// machine that holds their SSH keys and Keychain-backed secrets. So
// `install` refuses - loudly, with a reason - whenever it cannot establish
// that the downloaded bundle is signed by the identity this app is
// distributed under. It does not fall back to installing anyway, and there is
// no flag to make it.
//
// **What that means today, stated plainly.** The captain does not yet have a
// Developer ID certificate - it needs a paid Apple Developer Program
// membership, and no amount of code here can substitute for one. Until the
// release workflow's signing and notarization steps are enabled (they exist,
// disabled, in `.github/workflows/release.yml`, naming the exact secrets
// required), every artifact this downloads will fail verification and this
// installer will refuse it. That is the correct behaviour, not a gap to work
// around: the check-and-notify half of F3 is genuinely useful on its own (the
// Updates row tells the captain a release exists and links to it), and the
// install half turns itself on the moment real signing exists, with no code
// change here.
//
// `expectedTeamIdentifier` is the one thing to fill in when it does.
//
// # Mechanics worth knowing
//
// - **`ditto`, not `unzip`.** `/usr/bin/ditto -x -k` preserves the extended
//   attributes and symlinks a signed `.app` needs; `unzip` does not reliably,
//   and a bundle that unpacks with a broken signature fails verification for
//   a reason that has nothing to do with its actual provenance.
// - **`replaceItemAt`, not delete-then-move.** An atomic swap means a failure
//   partway through leaves the old app intact rather than no app at all.
// - **Relaunch is a detached helper, not `open -n`.** The bundle sets
//   `LSMultipleInstancesProhibited` (GL-05), so the new copy cannot start
//   while this process is alive. A small detached `sh` waits for this PID to
//   go away and then opens the app.
//
// Nothing in this file runs unless a captain clicks Update on the Updates
// page's App row.

import AppKit
import Foundation

enum AppUpdateInstallOutcome {
    case installedPendingRelaunch
    case failed(String)
    /// Verification could not be satisfied. Separated from `failed` because
    /// it is not a bug or a transient problem - it is the expected state
    /// until signing exists - and the UI says something different about it.
    case refusedUnverified(String)
}

enum AppUpdateInstaller {

    /// The Apple Developer Team ID the released app is signed with.
    ///
    /// `nil` until the captain has a Developer ID certificate. While it is
    /// `nil`, `verify` reports that no artifact can be trusted and `install`
    /// refuses every download - see the file header. Set this to the real
    /// Team ID at the same time the release workflow's signing step is
    /// enabled; the two have to agree or a correctly-signed artifact will
    /// still be refused.
    static let expectedTeamIdentifier: String? = nil

    /// Human-readable explanation of the current gate, shown in the UI so
    /// the state is never mysterious.
    static var verificationUnavailableReason: String {
        "Signed releases aren't set up yet - this build has no Developer ID to verify a download against, so installing in place is disabled. Open the release page to download it yourself."
    }

    static var canInstall: Bool { expectedTeamIdentifier != nil }

    // MARK: Install

    /// Downloads `release`'s artifact, verifies it, and swaps it in. Blocking;
    /// call off the main thread. `progress` is reported on the calling queue.
    static func install(_ release: AppRelease, progress: ((String) -> Void)? = nil) -> AppUpdateInstallOutcome {
        guard let assetURL = release.assetURL else {
            return .failed("that release has no downloadable build attached")
        }
        // The policy gate first, deliberately: it is the one refusal that is
        // true regardless of where or how this build is running, and putting
        // an environmental check in front of it would let a future
        // environment change silently move which refusal a caller sees.
        guard canInstall else {
            return .refusedUnverified(verificationUnavailableReason)
        }
        guard let currentBundle = currentBundleURL() else {
            return .failed("this build isn't running from an .app bundle, so there is nothing to replace")
        }

        let workspace: URL
        do {
            workspace = try makeWorkspace()
        } catch {
            return .failed("couldn't create a temporary directory: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        progress?("Downloading \(release.tag)…")
        let zipURL = workspace.appendingPathComponent(release.assetName ?? "update.zip")
        if let reason = download(assetURL, to: zipURL) {
            return .failed(reason)
        }

        progress?("Unpacking…")
        let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Subprocess.run(tool: "ditto", arguments: ["-x", "-k", zipURL.path, unpacked.path],
                                   timeout: 300, log: AppLog.subprocess,
                                   extraCandidates: ["/usr/bin/ditto"])
        guard ditto.ok else {
            return .failed("couldn't unpack the download: \(ditto.stderr.isEmpty ? "ditto exited \(ditto.status)" : ditto.stderr)")
        }
        guard let downloadedApp = findApp(in: unpacked) else {
            return .failed("the download didn't contain an .app bundle")
        }

        progress?("Verifying signature…")
        switch verify(bundleAt: downloadedApp) {
        case .refused(let reason):
            AppLog.lifecycle.error("refusing an unverified app update: \(reason, privacy: .public)")
            return .refusedUnverified(reason)
        case .ok:
            break
        }

        progress?("Installing…")
        do {
            try swap(newBundle: downloadedApp, over: currentBundle)
        } catch {
            return .failed("couldn't replace the app: \(error.localizedDescription)")
        }

        scheduleRelaunch(of: currentBundle)
        return .installedPendingRelaunch
    }

    // MARK: Verification

    enum VerificationResult {
        case ok
        case refused(String)
    }

    /// Three independent checks, all of which must pass:
    ///
    ///   1. `codesign --verify --deep --strict` - the bundle's own seal is
    ///      intact and nothing inside it was modified after signing.
    ///   2. The signing authority is a Developer ID and the Team ID matches
    ///      `expectedTeamIdentifier` - an intact signature proves only that
    ///      *somebody* signed it, and an ad-hoc or self-signed bundle passes
    ///      check 1 happily.
    ///   3. `spctl --assess --type execute` - Gatekeeper accepts it, which is
    ///      what actually requires notarization.
    ///
    /// Check 2 is the one that carries the security property; 1 and 3 are
    /// there so a failure reports the specific reason rather than a generic
    /// "rejected".
    static func verify(bundleAt url: URL) -> VerificationResult {
        guard let expectedTeam = expectedTeamIdentifier else {
            return .refused(verificationUnavailableReason)
        }

        let seal = Subprocess.run(tool: "codesign", arguments: ["--verify", "--deep", "--strict", url.path],
                                  timeout: 120, extraCandidates: ["/usr/bin/codesign"])
        guard seal.ok else {
            return .refused("the download's code signature is not intact (codesign: \(seal.stderr.isEmpty ? "exit \(seal.status)" : seal.stderr))")
        }

        let info = Subprocess.run(tool: "codesign", arguments: ["--display", "--verbose=4", url.path],
                                  timeout: 120, extraCandidates: ["/usr/bin/codesign"])
        // `codesign --display` writes its fields to stderr, not stdout.
        guard let reason = signatureRejection(in: info.stderr + "\n" + info.stdout, expectedTeam: expectedTeam) else {
            let gatekeeper = Subprocess.run(tool: "spctl", arguments: ["--assess", "--type", "execute", url.path],
                                            timeout: 120, extraCandidates: ["/usr/sbin/spctl"])
            guard gatekeeper.ok else {
                return .refused("Gatekeeper rejected the download - it is probably not notarized (spctl: \(gatekeeper.stderr.isEmpty ? "exit \(gatekeeper.status)" : gatekeeper.stderr))")
            }
            return .ok
        }
        return .refused(reason)
    }

    /// The pure half of check 2, split out so it is testable against recorded
    /// `codesign --display` output with no real bundle involved. Returns the
    /// rejection reason, or `nil` when the identity is acceptable.
    static func signatureRejection(in codesignOutput: String, expectedTeam: String) -> String? {
        let lines = codesignOutput.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        let authorities = lines.filter { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) }
        guard !authorities.isEmpty else {
            return "the download is not signed by a recognisable identity"
        }
        guard authorities.contains(where: { $0.hasPrefix("Developer ID Application:") }) else {
            return "the download is signed, but not with a Developer ID (found: \(authorities.first ?? "?"))"
        }

        let teamLine = lines.first { $0.hasPrefix("TeamIdentifier=") }
        let team = teamLine.map { String($0.dropFirst("TeamIdentifier=".count)) } ?? "not set"
        guard team == expectedTeam else {
            return "the download is signed by team \(team), not \(expectedTeam)"
        }
        return nil
    }

    // MARK: Steps

    private static func makeWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The `.app` this process is running out of - `Bundle.main.bundleURL`
    /// only when that really is a bundle, so a `swift run` binary resolves to
    /// `nil` instead of pointing the swap at `.build/debug`.
    static func currentBundleURL() -> URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", AppVersion.isBundled else { return nil }
        return url
    }

    private static func download(_ url: URL, to destination: URL) -> String? {
        var request = URLRequest(url: url)
        request.setValue("FirstmateCockpit", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 600
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let semaphore = DispatchSemaphore(value: 0)
        var failure: String?
        let task = URLSession.shared.downloadTask(with: request) { tempURL, response, error in
            defer { semaphore.signal() }
            if let error { failure = "download failed: \(error.localizedDescription)"; return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else { failure = "download failed: HTTP \(status)"; return }
            guard let tempURL else { failure = "download produced no file"; return }
            do {
                try FileManager.default.moveItem(at: tempURL, to: destination)
            } catch {
                failure = "couldn't save the download: \(error.localizedDescription)"
            }
        }
        task.resume()
        semaphore.wait()
        return failure
    }

    private static func findApp(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        if let direct = contents.first(where: { $0.pathExtension == "app" }) { return direct }
        // A zip built from a parent directory nests the bundle one level in.
        for entry in contents where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let nested = findApp(in: entry) { return nested }
        }
        return nil
    }

    /// Atomic where the filesystem allows it: `replaceItemAt` keeps the old
    /// bundle until the new one is fully in place, so an interruption cannot
    /// leave the captain with no app.
    private static func swap(newBundle: URL, over current: URL) throws {
        // Stage next to the destination so the replace is same-volume; a
        // cross-volume `replaceItemAt` degrades to a copy that can fail
        // halfway.
        let staged = current.deletingLastPathComponent()
            .appendingPathComponent(".grandline-update-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: newBundle, to: staged)
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// A detached `sh` that waits for this process to exit and then opens the
    /// (now replaced) bundle. `LSMultipleInstancesProhibited` means the new
    /// copy cannot start while this one is alive, so the wait is required
    /// rather than defensive.
    private static func scheduleRelaunch(of bundle: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Both values are interpolated into a shell command, so quote them.
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(shellQuoted(bundle.path))"
        // `Subprocess.launchDetached`, not `Subprocess.run`: that runner
        // waits for the child, and this child is waiting for *us*. It is on
        // the shared runner rather than a hand-rolled `Process` here so the
        // "no hand-rolled Process" source guard stays meaningful.
        let started = Subprocess.launchDetached(executable: "/bin/sh", arguments: ["-c", script],
                                                log: AppLog.lifecycle, label: "relaunch-helper")
        if started {
            AppLog.lifecycle.info("app update staged; relaunch helper started")
        } else {
            AppLog.lifecycle.error("couldn't start the relaunch helper - the update is installed but will need a manual relaunch")
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
