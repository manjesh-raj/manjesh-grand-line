// Manjesh Grand Line - native macOS app.
//
// Runs one real video generation via the provisioned venv's `ltx-2-mlx`
// console script (`generate --distilled`, LTX-2.3 q4) - the exact command
// and parameters `fm/grandline-videogen-feasibility-scout`'s scout report
// validated live (85.8s wall-clock, 21.03GB peak memory footprint, 0 swaps,
// a real playable H.264+AAC mp4 on an M5 Pro/24GB machine; see that report
// for the full evidence).
//
// Uses `Subprocess.run` from a background queue (GL-02/03/04/15/26's shared
// runner - concurrent stdout/stderr draining, no shell, a real bound
// timeout), the same shape `DictationCleanup`/`ConsoleCommandComposer` use
// for their own single blocking external-tool call. Deliberately no live
// progress parsing for this v1 - the validated run completes in well under
// two minutes, and `VideoGenController` shows a single "Generating..."
// state for the duration rather than scraping the tool's own tqdm output
// (not a documented/stable interface - see the scout report's own
// integration plan for why that's a real design tradeoff, not an oversight).

import Foundation

struct VideoGenResult {
    let outputPath: URL
    let durationSeconds: TimeInterval
}

struct VideoGenError: Error {
    let message: String
}

enum VideoGenEngine {

    /// Generous relative to the validated ~86s real run - a slower captain
    /// machine, a cold model-mmap first load, or transient system contention
    /// should still finish well inside this before being treated as hung.
    static let timeout: TimeInterval = 360

    /// `-f 97` at `--frame-rate 24` is exactly the scout's own validated
    /// combination (97/24 = 4.04s) - not a captain-configurable duration in
    /// this v1. `--distilled` is the one pipeline mode validated; see the
    /// scout report's §3.6 for what a captain-configurable duration/mode
    /// would need (more download, more validation) before it should ship.
    private static let frameRate = "24"
    private static let frameCount = "97"

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
        completion: @escaping (Result<VideoGenResult, VideoGenError>) -> Void
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            completion(.failure(VideoGenError(message: "Describe what you want to generate first.")))
            return
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

        let arguments = [
            "generate", "--distilled",
            "--prompt", trimmedPrompt,
            "--model", VideoGenEnvironment.modelDir().path,
            "--frame-rate", frameRate,
            "-f", frameCount,
            "-o", outputURL.path,
            "--seed", String(seed ?? Int.random(in: 0..<1_000_000)),
        ]

        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let result = Subprocess.run(
                executable: executableOverrideForTests ?? VideoGenEnvironment.venvLtxBinaryPath,
                arguments: arguments,
                extraEnv: ["HF_HOME": VideoGenEnvironment.hfCacheDir().path],
                timeout: timeout,
                log: AppLog.store,
                label: "ltx-2-mlx generate --distilled"
            )
            let elapsed = Date().timeIntervalSince(started)
            let fileExists = FileManager.default.fileExists(atPath: outputURL.path)
            DispatchQueue.main.async {
                if result.ok, fileExists {
                    completion(.success(VideoGenResult(outputPath: outputURL, durationSeconds: elapsed)))
                } else if result.timedOut {
                    completion(.failure(VideoGenError(message: "Generation didn't finish within \(Int(timeout))s.")))
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
