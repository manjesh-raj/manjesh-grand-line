// Manjesh Grand Line - native macOS app.
//
// Runs one real video generation via the provisioned venv's `ltx-2-mlx`
// console script - `fm/grandline-videogen-feasibility-scout`'s scout report
// validated the `generate --distilled` combination live (85.8s wall-clock,
// 21.03GB peak memory footprint, 0 swaps, a real playable H.264+AAC mp4 on an
// M5 Pro/24GB machine, 97 frames @ 24fps = 4.04s, 704x448) - see that report
// for the full evidence behind the one point every estimate below is derived
// from.
//
// `fm/grandline-videogen-settings-fix` made duration/resolution/clarity/
// reference-type genuinely captain-configurable, replacing the earlier
// hardcoded `frameCount = "97"` (which made every clip ~4s regardless of
// what a captain asked for - see this task's own brief for the captain
// report). What's real about each control, verified directly against the
// installed CLI (`ltx-2-mlx generate --help`) and the vendored pipeline
// source in `~/Library/Application Support/FirstmateCockpit/videogen/venv`
// before any of it shipped:
//
//   - Duration: `--frames`/`-f` is passed straight to the pipeline with no
//     snapping of its own - only the tool's own *auto-duration* prediction
//     path (`--auto-duration`, unused here) snaps a predicted value. A
//     concrete frame count this app sends has to already satisfy
//     `(frames - 1) % 8 == 0` (the causal VAE's temporal grid,
//     `snap_frames_to_grid` in `ltx_pipelines_mlx.utils.blocks`) or the
//     pipeline's own shape math breaks - `frameCount(forSeconds:frameRate:)`
//     below does that snapping itself, on the *captain's* side, rounding to
//     the nearest grid point (not flooring, which is what the tool's own
//     auto-duration snap does to stay under a budget ceiling - a captain-
//     requested duration should land as close to what was asked for as the
//     grid allows). Confirmed against the scout's own validated case:
//     `frameCount(forSeconds: 4, frameRate: 24) == 97`.
//   - Resolution: `--height`/`--width` are genuinely configurable, but every
//     pipeline mode this page can select floors a non-conforming dimension
//     down to a multiple of 32 (`--one-stage`) or 64 (`--distilled`/
//     `--two-stages-hq`, both half-res-then-2x-upscale - see
//     `snap_output_dimensions` in the vendored `ltx_core_mlx.components
//     .patchifiers`) with no captain-visible warning from this app. Every
//     preset below is an exact multiple of 64 for exactly that reason - what
//     a captain picks is what actually renders, regardless of which clarity
//     mode is also selected.
//   - Clarity: `--distilled`/`--one-stage`/`--two-stage`/`--two-stages-hq`
//     are real, mutually exclusive pipeline-mode flags (the CLI itself
//     rejects more than one). `.standard` is the exact `--distilled`
//     invocation the scout report validated; `.draft` stays on that same
//     validated pipeline with its own step counts halved (a mechanically
//     safe, always-legal reduction - fewer diffusion steps, same code path);
//     `.high` is `--two-stages-hq`, a materially different, CFG-guided
//     pipeline - genuinely higher quality, genuinely slower, and NOT
//     independently wall-clock-validated on this hardware the way `.standard`
//     was. See `VideoGenClarity`'s own doc comment for the full reasoning
//     and the honest caveats on its cost estimate.
//   - Reference type: `--image PATH` (legacy single-image I2V - `FRAME_IDX=0
//     STRENGTH=1.0`) is real I2V conditioning, confirmed to be forwarded by
//     every pipeline mode this page uses (`args.images` reaches
//     `DistilledPipeline`/`TI2VidTwoStagesHQPipeline` alike in the vendored
//     `ltx_pipelines_mlx.cli`). There is deliberately no third
//     "video reference" option - this CLI has no video-URL/YouTube-link
//     conditioning flag anywhere, and building one that silently no-ops or
//     downgrades would repeat exactly the overpromise this task exists to
//     fix. See `VideoGenReferenceType`.
//
// Uses `Subprocess.run` from a background queue (GL-02/03/04/15/26's shared
// runner - concurrent stdout/stderr draining, no shell, a real bound
// timeout - now derived per-request from the captain's own settings rather
// than one fixed constant, see `VideoGenEngine.timeout(forFrameCount:
// width:height:clarity:)`), the same shape `DictationCleanup`/
// `ConsoleCommandComposer` use for their own single blocking external-tool
// call. Deliberately no live progress parsing for this v1 - see the scout
// report's own integration plan for why that's a real design tradeoff, not
// an oversight.

import Foundation

struct VideoGenResult {
    let outputPath: URL
    let durationSeconds: TimeInterval
}

struct VideoGenError: Error {
    let message: String
}

/// What the prompt describes the shot as being conditioned by. `.text` is
/// the only option before this task; `.image` is real I2V via `--image`. A
/// `.videoLink`-style third case is deliberately absent - see this file's
/// header.
enum VideoGenReferenceType: Equatable {
    case text
    case image(path: String)

    var isImage: Bool { if case .image = self { return true }; return false }
}

/// A resolution preset - every value is an exact multiple of 64px, see this
/// file's header for why that specific modulus (not 32) is what keeps every
/// clarity mode this page offers from silently floor-snapping a captain's
/// choice.
enum VideoGenResolutionPreset: String, CaseIterable, Equatable {
    case small
    case standard
    case large

    var title: String {
        switch self {
        case .small: return "Small (Fast)"
        case .standard: return "Standard"
        case .large: return "Large (HQ)"
        }
    }

    /// `.standard` is the scout report's own validated 704x448. `.small`/
    /// `.large` scale that aspect ratio (~1.55-1.6:1) up/down while staying
    /// on the 64px grid.
    var width: Int {
        switch self {
        case .small: return 512
        case .standard: return 704
        case .large: return 896
        }
    }
    var height: Int {
        switch self {
        case .small: return 320
        case .standard: return 448
        case .large: return 576
        }
    }
}

/// A pipeline-mode/quality preset. See this file's header for the full
/// reasoning behind each mapping; the short version:
///
///   - `.standard` = `--distilled` at its own defaults (8+3=11 no-CFG
///     denoising steps) - the exact, wall-clock-validated combination.
///   - `.draft` = the *same* `--distilled` pipeline with `--stage1-steps 4
///     --stage2-steps 2` (4+2=6 steps) - a genuine, always-legal reduction
///     on an already-validated code path, not a second, unvalidated one.
///   - `.high` = `--two-stages-hq`, a real, materially different pipeline
///     (`ti2vid_two_stages_hq.py`'s `TI2VidTwoStagesHQPipeline` - CFG-guided,
///     `res_2s` sampler for stage 1, real refine steps for stage 2).
enum VideoGenClarity: String, CaseIterable, Equatable {
    case draft
    case standard
    case high

    var title: String {
        switch self {
        case .draft: return "Draft"
        case .standard: return "Standard"
        case .high: return "High"
        }
    }

    var subtitle: String {
        switch self {
        case .draft: return "Fastest, roughest."
        case .standard: return "The validated default."
        case .high: return "Best quality - takes longer."
        }
    }

    var flags: [String] {
        switch self {
        case .draft: return ["--distilled", "--stage1-steps", "4", "--stage2-steps", "2"]
        case .standard: return ["--distilled"]
        case .high: return ["--two-stages-hq"]
        }
    }

    /// Rough relative cost per output pixel per frame against `.standard`
    /// (`--distilled`'s own default 8+3=11 no-CFG steps) as `1.0` - a
    /// step/CFG-count *ratio*, not a wall-clock measurement:
    /// `.draft`'s 4+2=6 steps against 11 (≈0.55); `.high`'s CFG-doubled
    /// (`--two-stages-hq` runs the conditional and unconditional pass every
    /// step) 15-step stage 1 plus a 3-step stage 2 (≈15*2+3=33 step-units)
    /// against 11 (≈3.0). Used only to hedge the UI's own honestly-labeled
    /// time estimate - never for the real subprocess timeout bound below,
    /// which is deliberately far more generous than this ratio alone.
    var relativeStepCost: Double {
        switch self {
        case .draft: return 0.55
        case .standard: return 1.0
        case .high: return 3.0
        }
    }
}

enum VideoGenEngine {

    /// LTX-2.3 was trained at 24fps; the CLI's own help text warns values far
    /// from that drift out of distribution. Not captain-configurable -
    /// duration is expressed as a frame *count* at this fixed rate, per the
    /// task's own instruction.
    static let frameRate = "24"
    static var frameRateValue: Double { Double(frameRate) ?? 24 }

    /// A floor under the dynamic per-request timeout below - never smaller
    /// than the original validated case's own generous bound, regardless of
    /// how cheap a particular duration/resolution/clarity combination's own
    /// estimate comes out.
    private static let minimumTimeout: TimeInterval = 360

    /// The scout report's own validated numbers - the one point every
    /// estimate in this file is derived from. See the header.
    private static let baselineSeconds: Double = 85.8
    private static let baselineFrames: Double = 97
    private static let baselinePixels: Double = 704 * 448

    /// Converts a captain-chosen duration to a frame count on the VAE's
    /// temporal grid (`(frames - 1) % timeScale == 0`) - see this file's
    /// header for why this snapping has to happen on the captain's side
    /// rather than the tool's. Rounds to the *nearest* grid point rather than
    /// flooring.
    static func frameCount(forSeconds seconds: Double, frameRate: Double, timeScale: Int = 8) -> Int {
        let raw = max(1, (seconds * frameRate).rounded())
        let k = ((raw - 1) / Double(timeScale)).rounded()
        return max(1, Int(k) * timeScale + 1)
    }

    /// The real, honestly-hedged duration a given frame count renders as,
    /// after the grid snap above - what `VideoGenController` shows next to
    /// the captain's requested duration.
    static func actualSeconds(forFrameCount frameCount: Int, frameRate: Double = 24) -> Double {
        Double(frameCount) / frameRate
    }

    /// A reasoned (not measured, except at the one validated point) estimate
    /// of wall-clock generation time - see `VideoGenClarity.relativeStepCost`'s
    /// doc comment for the reasoning behind the clarity multiplier.
    static func estimatedSeconds(forFrameCount frameCount: Int, width: Int, height: Int, clarity: VideoGenClarity) -> Double {
        let frameRatio = Double(frameCount) / baselineFrames
        let pixelRatio = Double(width * height) / baselinePixels
        return baselineSeconds * frameRatio * pixelRatio * clarity.relativeStepCost
    }

    /// The real subprocess timeout bound - deliberately generous (4x the
    /// reasoned estimate above, never below `minimumTimeout`) so a slower
    /// captain machine, a cold model-mmap first load, transient system
    /// contention, or this file's own estimate simply being wrong for a
    /// combination that was never independently wall-clock-validated all
    /// still finish inside it before being treated as hung.
    static func timeout(forFrameCount frameCount: Int, width: Int, height: Int, clarity: VideoGenClarity) -> TimeInterval {
        let estimate = estimatedSeconds(forFrameCount: frameCount, width: width, height: height, clarity: clarity)
        return max(minimumTimeout, estimate * 4)
    }

    /// Test-only seams, same convention as `DictationCleanup
    /// .claudePathOverrideForTests` - unconditionally present (harmless
    /// `nil` in production), so `VideoGenSelfTest` can drive the real
    /// `Subprocess.run` call end to end against a fast, disposable fake
    /// script instead of the real ~19GB venv binary, and can exercise the
    /// "model not set up" guard's *complement* without needing multi-GB
    /// dummy files on disk just to satisfy `VideoGenEnvironment
    /// .currentState()`'s real size-floor checks.
    static var executableOverrideForTests: String?
    static var readyOverrideForTests: Bool?

    /// Runs one generation. `completion` is always called on the main
    /// thread, exactly once.
    static func generate(
        prompt: String,
        seed: Int? = nil,
        durationSeconds: Double = 5,
        resolution: VideoGenResolutionPreset = .standard,
        clarity: VideoGenClarity = .standard,
        reference: VideoGenReferenceType = .text,
        completion: @escaping (Result<VideoGenResult, VideoGenError>) -> Void
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            completion(.failure(VideoGenError(message: "Describe what you want to generate first.")))
            return
        }
        if case .image(let path) = reference {
            guard FileManager.default.fileExists(atPath: path) else {
                completion(.failure(VideoGenError(message: "The reference image couldn't be found. Choose one again.")))
                return
            }
        }
        let isReady: Bool
        if let override = readyOverrideForTests {
            isReady = override
        } else if case .ready = VideoGenEnvironment.currentState() {
            isReady = true
        } else {
            isReady = false
        }
        guard isReady else {
            completion(.failure(VideoGenError(message: "The video model isn't set up yet.")))
            return
        }

        let outputDir = VideoGenEnvironment.outputDir()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            completion(.failure(VideoGenError(message: "Couldn't create \(outputDir.path): \(error.localizedDescription)")))
            return
        }
        let outputURL = outputDir.appendingPathComponent(filename(for: trimmedPrompt))

        let frames = frameCount(forSeconds: durationSeconds, frameRate: frameRateValue)
        var arguments = clarity.flags + [
            "--prompt", trimmedPrompt,
            "--model", VideoGenEnvironment.modelDir().path,
            "--frame-rate", frameRate,
            "-f", String(frames),
            "--height", String(resolution.height),
            "--width", String(resolution.width),
            "-o", outputURL.path,
            "--seed", String(seed ?? Int.random(in: 0..<1_000_000)),
        ]
        if case .image(let path) = reference {
            arguments += ["--image", path]
        }

        let runTimeout = timeout(forFrameCount: frames, width: resolution.width, height: resolution.height, clarity: clarity)

        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let result = Subprocess.run(
                executable: executableOverrideForTests ?? VideoGenEnvironment.venvLtxBinaryPath,
                arguments: arguments,
                extraEnv: ["HF_HOME": VideoGenEnvironment.hfCacheDir().path],
                timeout: runTimeout,
                log: AppLog.store,
                label: "ltx-2-mlx \(clarity.flags.first ?? "generate")"
            )
            let elapsed = Date().timeIntervalSince(started)
            let fileExists = FileManager.default.fileExists(atPath: outputURL.path)
            DispatchQueue.main.async {
                if result.ok, fileExists {
                    completion(.success(VideoGenResult(outputPath: outputURL, durationSeconds: elapsed)))
                } else if result.timedOut {
                    completion(.failure(VideoGenError(message: "Generation didn't finish within \(Int(runTimeout))s.")))
                } else {
                    completion(.failure(VideoGenError(message: result.failureSummary ?? "Generation failed.")))
                }
            }
        }
    }

    /// A short, filesystem-safe, human-recognisable name - a slug of the
    /// prompt plus a timestamp, so two clips from the same prompt never
    /// collide and a captain browsing `~/Movies/Grand Line/` in Finder can
    /// tell what each file is without opening it.
    static func filename(for prompt: String) -> String {
        let slug = prompt
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, char in
                if char == "-", partial.hasSuffix("-") { return }
                partial.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let truncated = String(slug.prefix(60))
        let stamp = Self.timestampFormatter.string(from: Date())
        let base = truncated.isEmpty ? "clip" : truncated
        return "\(base)-\(stamp).mp4"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
