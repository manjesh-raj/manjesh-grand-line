// Manjesh Grand Line - native macOS app.
//
// Dictation's optional local Whisper engine (fm/grandline-dictation-whisper-
// engine) - downloads and locates the large-v3-turbo ggml model, on demand,
// into local app storage. The model is never bundled into the app (it's
// ~547MB) - this is the one piece of Dictation that needs a network fetch
// the first time the local-engine toggle is turned on, mirroring how
// `DocsSyncSource`/`UpdatesSource` already fetch real external content into
// `~/Library/Application Support/FirstmateCockpit/...` on demand rather than
// shipping it in the bundle.

import CryptoKit
import Foundation

/// A plain-message error - `String` itself can't conform to `Error` directly.
struct WhisperModelValidationError: Error {
    let message: String
}

/// One model file's download/availability state - `WhisperModelManager`'s
/// one source of truth, mirroring `DictationStatus`'s own "real state, never
/// fabricated" shape.
enum WhisperModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case failed(String)
}

/// Downloads, validates, and locates the quantized large-v3-turbo ggml model
/// (per the captain-approved plan's phase-1 model choice - not a smaller/
/// faster size, and not a model-picker UI, both explicitly out of scope for
/// this pass). One instance for the app's whole lifetime, owned by the app
/// delegate alongside `DictationStore`/`DictationEngine`.
final class WhisperModelManager: NSObject {
    static let shared = WhisperModelManager()

    /// The file name whisper.cpp itself uses for this exact model (matches
    /// upstream's own `models/download-ggml-model.sh` naming convention) -
    /// also what `WhisperCppEngine.init(modelPath:)` is handed.
    static let modelFileName = "ggml-large-v3-turbo-q5_0.bin"

    /// Real, live-verified URL (HTTP 302 -> a real ~547MB file, confirmed via
    /// a direct HEAD request against this exact path before wiring this up -
    /// not guessed or fabricated) - the same host and path convention
    /// upstream whisper.cpp's own `models/download-ggml-model.sh` uses
    /// (`src="https://huggingface.co/ggerganov/whisper.cpp"`, this file's own
    /// name). Quantized to q5_0 rather than the full-precision or q8_0
    /// variant - the smaller download the plan's "still fully offline, real
    /// accuracy win" framing calls for, without the picker UI a choice of
    /// quantization level would otherwise imply.
    static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelFileName)")!

    /// The exact SHA-256 of the bytes `modelURL` serves, and the exact byte
    /// count that goes with it (audit §5.6).
    ///
    /// **Verified, not transcribed from one place.** Four independent sources
    /// agreed before this was written down: Hugging Face's Git-LFS pointer
    /// (`.../raw/main/<file>`, `oid sha256:`), the model API's own
    /// `siblings[].lfs.sha256`, the `x-linked-etag` header on the resolve URL
    /// (which for an LFS file *is* the content SHA-256), and - the one that
    /// settles it - `shasum -a 256` over a real ~547MB copy this very code
    /// path had already downloaded onto a machine.
    ///
    /// **What this buys.** Before it, a downloaded model was accepted on a
    /// size floor plus four magic bytes, so anything at least 10MB starting
    /// `0x67676d6c` was loaded into a process and handed to whisper.cpp's own
    /// C++ tensor parser. That is a large, memory-unsafe attack surface behind
    /// a TLS connection this app does not pin, reached over whatever network
    /// the captain is on. Now the bytes either hash to this value or they are
    /// never moved into place at all - the same "verify before use" discipline
    /// `AppUpdateInstaller` applies to a downloaded `.app`.
    ///
    /// **Known operational cost, stated rather than hidden.** `modelURL` points
    /// at `main`, a mutable ref, so if upstream ever re-uploads this file the
    /// download starts failing this check instead of silently installing
    /// different bytes - which is the correct direction, but it does mean the
    /// local-engine download stops working until someone re-verifies and
    /// updates this constant. The failure message says exactly that. If it ever
    /// happens, pinning `modelURL` to a specific commit (Hugging Face serves
    /// `resolve/<sha>/<file>`) makes both halves immutable together; that is
    /// deliberately not done pre-emptively here, since it changes a download
    /// URL that works.
    static let expectedSHA256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"

    /// The pinned file's exact size. Redundant against the hash for
    /// *correctness*, kept for *diagnosis*: a truncated transfer is the common
    /// failure by far, and checking this first turns it into "the download did
    /// not finish" in milliseconds instead of a bare hash mismatch half a
    /// gigabyte of reading later.
    static let expectedByteCount: Int64 = 574_041_195

    /// `~/Library/Application Support/FirstmateCockpit/whisper/`, overridable
    /// via `FM_WHISPER_MODEL_DIR` - the same `FM_*_DIR` convention
    /// `DictationStore`/`HostStore`/etc. already established, so tests can
    /// point this at a scratch directory without touching a captain's real
    /// (large, slow-to-redownload) model file.
    static func directoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_WHISPER_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
    }

    var modelPathOnDisk: String {
        Self.directoryURL().appendingPathComponent(Self.modelFileName).path
    }

    private(set) var state: WhisperModelState = .notDownloaded

    /// Mirrors `DictationStore.observe`'s "list of closures" shape - both the
    /// Dictation page (progress bar) and anything else that cares (none yet)
    /// can subscribe independently.
    private var observers: [(WhisperModelState) -> Void] = []
    func observe(_ handler: @escaping (WhisperModelState) -> Void) {
        observers.append(handler)
        handler(state)
    }

    private var session: URLSession?
    private var activeTask: URLSessionDownloadTask?

    override init() {
        super.init()
        refreshState()
    }

    /// Re-reads real on-disk state - called on init and whenever the
    /// Dictation page appears, matching every other "no polling, refresh on
    /// appear" store in this app (`DictationPermissions`, `VaultSource`).
    /// Deliberately does NOT re-validate the file's contents on every call
    /// (that would mean re-reading a 547MB file just to render a status) -
    /// the one real validation pass happens once, right after a download
    /// completes, in `didFinishDownloadingTo` below. A file that somehow got
    /// corrupted on disk after that point (manual tampering, disk failure)
    /// is still caught downstream: `WhisperCppEngine.init?` fails to load it,
    /// and `DictationEngine` falls back to Apple Speech rather than trusting
    /// this state blindly.
    func refreshState() {
        if FileManager.default.fileExists(atPath: modelPathOnDisk) {
            state = .ready
        } else if case .downloading = state {
            // Leave an in-flight download's progress alone.
        } else {
            state = .notDownloaded
        }
        notify()
    }

    var isReady: Bool { state == .ready }

    func startDownload() {
        if case .ready = state { return }
        if case .downloading = state { return }
        try? FileManager.default.createDirectory(at: Self.directoryURL(), withIntermediateDirectories: true)
        state = .downloading(progress: 0)
        notify()
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: Self.modelURL)
        activeTask = task
        task.resume()
    }

    /// Cancels an in-flight download and reports `.notDownloaded` - `URLSession`
    /// itself owns the temp file it was writing to and cleans it up once the
    /// task is cancelled (this class never sees or manages that temp path
    /// directly), so there is no partial file left anywhere a later
    /// `refreshState()` could mistake for a valid model.
    func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        session?.invalidateAndCancel()
        session = nil
        state = .notDownloaded
        notify()
    }

    /// GL-35: delete the downloaded model.
    ///
    /// The review's finding was blunt - 547MB with no way to get it back
    /// except finding the directory by hand. A captain who tried the local
    /// engine and went back to Apple Speech has no reason to keep it, and the
    /// app that manages every other tool's disk footprint should not be the
    /// one thing that strands half a gigabyte.
    ///
    /// Cancels an in-flight download first, so "delete" means the same thing
    /// in every state. Returns whether anything was actually removed.
    @discardableResult
    func deleteDownloadedModel() -> Bool {
        if case .downloading = state { cancelDownload() }
        let path = modelPathOnDisk
        guard FileManager.default.fileExists(atPath: path) else {
            refreshState()
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            AppLog.store.info("deleted the local Whisper model")
        } catch {
            AppLog.store.error("could not delete the local Whisper model: \(error.localizedDescription, privacy: .public)")
            state = .failed("Could not delete the model: \(error.localizedDescription)")
            notify()
            return false
        }
        refreshState()
        return true
    }

    /// The model file's size on disk, for a UI that wants to say what deleting
    /// it would actually reclaim. `nil` when it is not downloaded.
    var downloadedByteCount: Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: modelPathOnDisk)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    /// The real, cheap validation this class applies to a just-downloaded
    /// file before it's ever treated as a usable model - separated out so a
    /// test can exercise it directly against a crafted fixture without a
    /// real 547MB network transfer. Two checks, not a cryptographic
    /// checksum: upstream (`ggml-org/whisper.cpp`'s own
    /// `models/download-ggml-model.sh`) publishes no checksum manifest for
    /// these files to verify against (checked directly, not assumed) -
    /// (1) the file is at least plausibly large (catches a near-empty/
    /// aborted transfer), and (2) it starts with `GGML_FILE_MAGIC`
    /// (`whisper.cpp`'s own model-loader magic-number check, `0x67676d6c` -
    /// see `Vendor/whisper.cpp/Sources/CWhisper/whisper-src/whisper.cpp`'s
    /// `"invalid model data (bad magic)"` check). A file that passes both but
    /// is still truncated mid-tensor-data is caught one layer up:
    /// `WhisperCppEngine.init?` fails to load it, and `DictationEngine` falls
    /// back to Apple Speech rather than trusting this validation alone.
    static func validate(fileAt url: URL) -> Result<Void, WhisperModelValidationError> {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 10_000_000 else {
            return .failure(WhisperModelValidationError(message: "Downloaded file is too small to be a real model - the download likely failed partway through."))
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(WhisperModelValidationError(message: "Downloaded file could not be read back."))
        }
        defer { try? handle.close() }
        guard let magicData = try? handle.read(upToCount: 4), magicData.count == 4 else {
            return .failure(WhisperModelValidationError(message: "Downloaded file could not be read back."))
        }
        let magic = magicData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard magic == 0x67676d6c else {
            return .failure(WhisperModelValidationError(message: "Downloaded file failed validation (unexpected format) - it will not be used."))
        }
        return .success(())
    }

    /// The full check a *downloaded* file must pass before it is treated as a
    /// model: the cheap structural pass above, then the pinned SHA-256.
    ///
    /// Ordered cheap-first purely for the error message - a half-written
    /// transfer should say so, rather than reporting a hash mismatch that
    /// reads like tampering. Correctness comes from the checksum alone.
    ///
    /// This is the one function `didFinishDownloadingTo` calls, so no download
    /// path can reach disk having run only the structural half.
    ///
    /// **Cost, measured rather than assumed:** hashing the real 547MB model
    /// takes ~1s. That is on `URLSession`'s own delegate queue, never the main
    /// thread, and it lands after a multi-minute download - and it has to be
    /// synchronous regardless, because the temp file `location` points at is
    /// deleted the moment this returns.
    /// `validate(fileAt:)` stays separate and content-agnostic because it is
    /// also the honest answer to "does this look like a ggml model at all",
    /// which is a different question from "is it the exact file we pinned".
    static func validateDownload(fileAt url: URL) -> Result<Void, WhisperModelValidationError> {
        if case .failure(let structural) = validate(fileAt: url) { return .failure(structural) }
        return verifyPinnedContents(fileAt: url)
    }

    /// Byte-count then SHA-256, both against the pins. Split out with explicit
    /// parameters so a self-test can drive the real comparison against a small
    /// fixture instead of needing a real 547MB transfer.
    static func verifyPinnedContents(fileAt url: URL,
                                     expectedSHA256 expected: String = WhisperModelManager.expectedSHA256,
                                     expectedByteCount expectedSize: Int64 = WhisperModelManager.expectedByteCount)
        -> Result<Void, WhisperModelValidationError> {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value
        guard let size else {
            return .failure(WhisperModelValidationError(message: "Downloaded file could not be read back."))
        }
        guard size == expectedSize else {
            return .failure(WhisperModelValidationError(
                message: "The download is \(size) bytes but the expected model is \(expectedSize) - it did not finish. It will not be used."))
        }
        guard let actual = sha256Hex(ofFileAt: url) else {
            return .failure(WhisperModelValidationError(message: "Downloaded file could not be read back."))
        }
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            AppLog.store.error("whisper model checksum mismatch: expected \(expected, privacy: .public), got \(actual, privacy: .public)")
            return .failure(WhisperModelValidationError(
                message: "The downloaded model does not match its expected checksum, so it will not be used. Try again - if it keeps happening, the file published upstream has changed and the app needs updating."))
        }
        return .success(())
    }

    /// Streaming SHA-256 of a file, lowercase hex. `nil` only when the file
    /// cannot be read.
    ///
    /// Chunked deliberately: the file this exists for is ~547MB, and
    /// `Data(contentsOf:)` would mean holding all of it in memory to hash it.
    /// Bounded at `hashChunkSize` regardless of file size.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // Explicit do/catch rather than `try?`: `try?` flattens the
            // `Data?` this returns into one optional, which would make a read
            // *error* and a clean EOF indistinguishable - and silently hashing
            // a partial file to a "valid" digest is the one outcome this
            // function must never produce.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: hashChunkSize) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 4 MiB - large enough that hashing half a gigabyte is a few hundred
    /// reads rather than tens of thousands, small enough that peak memory is
    /// irrelevant.
    private static let hashChunkSize = 4 * 1024 * 1024

    private func notify() {
        let current = state
        DispatchQueue.main.async { [weak self] in
            self?.observers.forEach { $0(current) }
        }
    }
}

extension WhisperModelManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            guard let self, case .downloading = self.state else { return }
            self.state = .downloading(progress: progress)
            self.notify()
        }
    }

    /// `URLSession` hands this delegate a temp file that is deleted the
    /// moment this method returns - validation and the move into place both
    /// have to happen synchronously, right here, before that happens. A file
    /// that fails validation is never moved anywhere real - it stays exactly
    /// where `URLSession`'s own temp-file lifecycle discards it, so a failed
    /// download can never be mistaken for a valid model later.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        switch Self.validateDownload(fileAt: location) {
        case .failure(let validationError):
            DispatchQueue.main.async { [weak self] in
                self?.state = .failed(validationError.message)
                self?.notify()
            }
        case .success:
            do {
                let dest = URL(fileURLWithPath: modelPathOnDisk)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                DispatchQueue.main.async { [weak self] in
                    self?.state = .ready
                    self?.notify()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.state = .failed("Could not save the downloaded model: \(error.localizedDescription)")
                    self?.notify()
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        DispatchQueue.main.async { [weak self] in
            self?.state = .failed(error.localizedDescription)
            self?.notify()
        }
    }
}
