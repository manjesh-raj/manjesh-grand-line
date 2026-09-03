// Manjesh Grand Line - native macOS app.
//
// The "Video" Stores card's model/environment state (fm/grandline-videogen-
// feasibility-scout's own scout report is the validation this feature is
// built on: LTX-2.3, distilled q4 pipeline, `dgrauet/ltx-2-mlx`, real
// measured 85.8s/21GB-peak generation on an M5 Pro/24GB machine - see that
// report for the full evidence before changing the pipeline choice here).
//
// Deliberately NOT `WhisperModelManager`'s shape (a `URLSessionDownloadTask`
// singleton downloading one file with a progress callback). Two reasons,
// both load-bearing:
//
//   - The download is 12 files across ~27GB plus a pinned-commit `pip
//     install`, not one file - re-implementing multi-file resumable
//     download/retry/progress-aggregation in Swift, correctly, is a much
//     bigger and riskier undertaking than the feature itself, and the scout
//     report's own integration plan flagged this as a real open design
//     question rather than a given.
//   - This app already has an established, well-tested pattern for exactly
//     "run a real long external command and show its real output" -
//     `AppShellController.runInConsole`, the same mechanism Bootstrap's
//     dotfiles clone and Vault's `av save`/`av inject` already use. A
//     ~13-minute, ~27GB provisioning step is precisely the case a real
//     terminal's own progress bars serve better than a hand-rolled Swift
//     one, and it means this file owns no download/retry logic at all - only
//     "is setup done" (a cheap file-existence check) and "here is the
//     command to run it".
//
// So this file is pure state derivation (does the venv + every required
// model file already exist, at a plausible size) plus locating the setup
// script - the actual download/install work lives entirely in
// `native/Scripts/videogen-setup.sh`, run via the Console tab.

import Foundation

/// This page's status - mirrors `WhisperModelState`'s shape (a state enum, no
/// silent partial/unknown state) but has no `.downloading(progress:)` case,
/// since the download itself is a real Console tab this file has no visibility
/// into mid-run (see the file header). `.settingUp` only means "a setup
/// command was launched from this session" - a captain who force-quits the
/// app mid-download and reopens it just sees `.notSetUp` again (an honest
/// re-read of real on-disk state), and re-running setup is idempotent
/// (`videogen-setup.sh` skips whatever already downloaded correctly).
enum VideoGenState: Equatable {
    case notSetUp
    case settingUp
    case ready
    case failed(String)
}

enum VideoGenEnvironment {

    /// `~/Library/Application Support/FirstmateCockpit/videogen/`, overridable
    /// via `FM_VIDEOGEN_DIR` - the same convention `WhisperModelManager`/
    /// `DictationStore`/etc. already established, and the exact directory the
    /// scout task's own validation pass left ~27GB of already-downloaded,
    /// reusable model weights in.
    static func rootDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_VIDEOGEN_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("videogen", isDirectory: true)
    }

    static func venvDir() -> URL { rootDir().appendingPathComponent("venv", isDirectory: true) }
    static func modelDir() -> URL {
        rootDir().appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("ltx-2.3-mlx-q4", isDirectory: true)
    }
    static func hfCacheDir() -> URL { rootDir().appendingPathComponent("hf-cache", isDirectory: true) }

    static var venvLtxBinaryPath: String {
        venvDir().appendingPathComponent("bin/ltx-2-mlx").path
    }

    /// Where generated clips are saved - deliberately NOT under Application
    /// Support (that's app-managed infrastructure a captain never browses
    /// directly). `~/Movies/Grand Line/` is a location a captain would
    /// actually find on their own, matching the captain's own "downloadable/
    /// already-on-Mac" ask - overridable via `FM_VIDEOGEN_OUTPUT_DIR` for
    /// tests, so a self-test never writes into a captain's real `~/Movies`.
    static func outputDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_VIDEOGEN_OUTPUT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Grand Line", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/Grand Line", isDirectory: true)
    }

    /// The exact file set `DistilledPipeline.load()` (in the vendored
    /// `dgrauet/ltx-2-mlx` source, `packages/ltx-pipelines-mlx/src/
    /// ltx_pipelines_mlx/distilled.py`) reads for `generate --distilled` on
    /// the LTX-2.3 q4 pack - traced through the real loader code during the
    /// scout's own validation, not guessed from the HF repo's file listing
    /// (which also carries two unused transformer variants and two unused
    /// LoRA files this pipeline mode never touches). `videogen-setup.sh`
    /// fetches exactly this list; kept here too so `currentState()` can check
    /// "is setup actually done" independently of whether the script that
    /// produced it agrees.
    static let requiredModelFiles: [(name: String, minimumSize: Int)] = [
        ("config.json", 10),
        ("embedded_config.json", 10),
        ("quantize_config.json", 10),
        ("split_model.json", 10),
        ("connector.safetensors", 1_000_000_000),
        ("transformer-distilled.safetensors", 1_000_000_000),
        ("vae_encoder.safetensors", 100_000_000),
        ("vae_decoder.safetensors", 100_000_000),
        ("audio_vae.safetensors", 10_000_000),
        ("vocoder.safetensors", 10_000_000),
        ("spatial_upscaler_x2_v1_1.safetensors", 100_000_000),
        ("spatial_upscaler_x2_v1_1_config.json", 10),
    ]

    /// Real, cheap on-disk state - no caching, matching `WhisperModelManager
    /// .refreshState()`'s own "re-read on every appear, no polling" rule
    /// (PRODUCT.md's "quiet until it matters"). A file present but truncated
    /// below its plausible floor (an interrupted download) reads as not-ready,
    /// same reasoning as `WhisperModelManager.validate`'s size-floor check.
    static func currentState() -> VideoGenState {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: venvLtxBinaryPath) else { return .notSetUp }
        let dir = modelDir()
        for file in requiredModelFiles {
            let path = dir.appendingPathComponent(file.name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int, size >= file.minimumSize else {
                return .notSetUp
            }
        }
        return .ready
    }

    /// Locate `videogen-setup.sh`: a copy alongside the app bundle
    /// (`build_native_app.sh` copies it into `Contents/Resources`, the same
    /// convention `SRELead.resolveKubectlScript()` already established for
    /// `sre_kubectl_mcp.py`), an `FM_VIDEOGEN_SETUP_SCRIPT` override, then the
    /// source tree itself for the `swift run`/`swift build` dev flow.
    static func resolveSetupScript() -> String? {
        let fm = FileManager.default
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("videogen-setup.sh").path
            if fm.isReadableFile(atPath: candidate) { return candidate }
        }
        if let override = ProcessInfo.processInfo.environment["FM_VIDEOGEN_SETUP_SCRIPT"], fm.isReadableFile(atPath: override) {
            return override
        }
        var dir = fm.currentDirectoryPath
        for _ in 0..<6 {
            let candidate = (dir as NSString).appendingPathComponent("native/Scripts/videogen-setup.sh")
            if fm.isReadableFile(atPath: candidate) { return candidate }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// The shell command `runInConsole` runs for "Set Up" - `nil` when the
    /// script can't be found at all (a packaging bug, not a captain-facing
    /// state `VideoGenState` needs its own case for; `VideoGenController`
    /// disables the button and says so).
    static func setupCommand() -> String? {
        guard let script = resolveSetupScript() else { return nil }
        return "bash \"\(script)\""
    }
}
