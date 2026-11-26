// Grand Line - native macOS app.
//
// F-05 of full review 4: voice memos that become notes.
//
// Hold Right ⌥ + ⇧ anywhere to record (the captain's product call). Let go,
// and the memo is transcribed on this Mac by the Whisper model Dictation
// already uses, then saved as a Notebook page under Memos or as a note on a
// task. Dropping an audio file on the Notebook transcribes it the same way.
//
// **Where the audio lives** (the captain's product call): on this Mac only,
// under the app's data folder (`voice-memos/<id>.m4a`), never in the synced
// notebook. A memo page carries a marker comment with the memo's id, so the
// page on another Mac has its transcript and says the audio is on the Mac
// that recorded it.
//
// **The key and Dictation.** Dictation holds Right ⌥ alone. A memo is Right ⌥
// with ⇧, in either order: ⇧ first never starts a dictation, and ⇧ added
// while a dictation has just started hands the key to the memo, discarding
// the dictation unpasted (`DictationEngine.discardRecording`).
//
// **Permissions.** The microphone is the same grant Dictation uses, and the
// key from another app needs the same Accessibility grant Dictation's key
// does. Both states are said in the HUD and on the Notebook's memo strip,
// with a button to the setting, and a key pressed with the app locked does
// nothing (GL-09: `AppLockedSurface.voiceMemo`).

import AppKit
import AVFoundation

// MARK: - The key

/// Watches the modifier flags for Right ⌥ + ⇧ held together. Pure state, so
/// a suite drives it with raw flags.
final class VoiceMemoHotkey {

    static let rightOptionKeyCode: UInt16 = 61
    /// The device-dependent bit macOS sets for the right Option key
    /// (`NX_DEVICERALTKEYMASK`).
    static let rightOptionDeviceBit: UInt = 0x40

    private(set) var isHeld = false
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// Whether a flags-changed event means the memo chord is down.
    static func isChordDown(flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option) && flags.contains(.shift)
            && (flags.rawValue & rightOptionDeviceBit) != 0
            && !flags.contains(.command) && !flags.contains(.control)
    }

    func update(flags: NSEvent.ModifierFlags) {
        let down = Self.isChordDown(flags: flags)
        if down, !isHeld {
            isHeld = true
            onStart?()
        } else if !down, isHeld {
            isHeld = false
            onStop?()
        }
    }

    func start() {
        stop()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(flags: event.modifierFlags)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(flags: event.modifierFlags)
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    var isInstalled: Bool { localMonitor != nil && globalMonitor != nil }
}

// MARK: - Where memos live

enum VoiceMemoFiles {

    static let directoryVariable = "FM_VOICE_MEMO_DIR"

    /// `dataRoot()/voice-memos`, on this Mac only.
    static func directory() -> URL {
        if let override = ProcessInfo.processInfo.environment[directoryVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return AppPaths.dataRoot().appendingPathComponent("voice-memos", isDirectory: true)
    }

    static func url(for id: String) -> URL {
        directory().appendingPathComponent("\(id).m4a")
    }

    static func newID(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "memo-\(f.string(from: now))-\(UUID().uuidString.prefix(4).lowercased())"
    }

    /// The file types a drop on the Notebook accepts.
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac"]
}

// MARK: - A transcript

struct VoiceMemoSegment: Equatable {
    var start: TimeInterval
    var text: String
}

/// The Markdown a memo is saved as, and how a page is read back as one.
enum VoiceMemoPage {

    static let markerPrefix = "<!-- grandline:voice-memo"

    struct Marker: Equatable {
        var id: String
        var duration: TimeInterval
    }

    /// "1:42".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "Memo · 25 Nov, 08:12".
    static func title(recordedAt: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM, HH:mm"
        return "Memo \u{00B7} \(f.string(from: recordedAt))"
    }

    static func markdown(title: String, marker: Marker, segments: [VoiceMemoSegment], source: String) -> String {
        var lines = ["# \(title)", "",
                     "\(markerPrefix) id=\(marker.id) duration=\(Int(marker.duration.rounded())) -->",
                     "",
                     "**Voice memo** \u{00B7} \(clock(marker.duration)) \u{00B7} \(source)", ""]
        if segments.isEmpty {
            lines.append("_Nothing was heard in this recording._")
        } else {
            for segment in segments { lines.append("[\(clock(segment.start))] \(segment.text)") }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The marker on a page, or nil for an ordinary page.
    static func marker(in content: String) -> Marker? {
        guard let range = content.range(of: markerPrefix) else { return nil }
        let tail = content[range.upperBound...].prefix { $0 != ">" }
        var id: String?
        var seconds: TimeInterval = 0
        for part in tail.split(separator: " ") {
            if part.hasPrefix("id=") { id = String(part.dropFirst(3)) }
            if part.hasPrefix("duration="), let value = Double(part.dropFirst(9)) { seconds = value }
        }
        guard let id, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return Marker(id: id, duration: seconds)
    }

    /// The transcript's lines, without their timestamps, for "Make a task
    /// from a line".
    static func transcriptLines(in content: String) -> [String] {
        content.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }

    /// A voice note appended to a task's notes.
    static func taskNote(segments: [VoiceMemoSegment], duration: TimeInterval, recordedAt: Date, id: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM, HH:mm"
        let text = segments.map(\.text).joined(separator: " ")
        return "\u{201C}\(text)\u{201D}\nVoice note \u{00B7} \(clock(duration)) \u{00B7} \(f.string(from: recordedAt)) \u{00B7} transcribed on this Mac [\(id)]"
    }
}

// MARK: - Transcribing a file

enum VoiceMemoTranscriber {

    /// Reads `url`, resamples it to Whisper's 16kHz mono, and transcribes it
    /// with timestamps. Off main; `progress` and `completion` come back on
    /// main. The error is phrased for the captain.
    static func transcribe(_ url: URL, progress: @escaping (Double) -> Void = { _ in },
                           completion: @escaping (Result<[VoiceMemoSegment], VoiceMemoError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = transcribeNow(url) { value in DispatchQueue.main.async { progress(value) } }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func samples(of url: URL, progress: (Double) -> Void = { _ in }) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let resampler = DictationAudioResampler()
        let chunk: AVAudioFrameCount = 32_768
        let total = max(1, Double(file.length))
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
            do { try file.read(into: buffer, frameCount: chunk) } catch { return nil }
            if buffer.frameLength == 0 { break }
            resampler.append(buffer)
            progress(0.4 * Double(file.framePosition) / total)
        }
        return resampler.samples
    }

    static func transcribeNow(_ url: URL, progress: (Double) -> Void = { _ in }) -> Result<[VoiceMemoSegment], VoiceMemoError> {
        guard let samples = samples(of: url, progress: progress) else { return .failure(.unreadable) }
        guard !samples.isEmpty else { return .success([]) }
        let modelPath = WhisperModelManager.shared.modelPathOnDisk
        guard FileManager.default.fileExists(atPath: modelPath) else { return .failure(.noModel) }
        guard let engine = WhisperCppEngine(modelPath: modelPath) else { return .failure(.modelDidNotLoad) }
        progress(0.5)
        let segments = engine.transcribeSegments(samples: samples) ?? []
        progress(1)
        return .success(segments.map { VoiceMemoSegment(start: $0.start, text: $0.text) })
    }
}

enum VoiceMemoError: Error, Equatable {
    case unreadable
    case noModel
    case modelDidNotLoad
    case microphoneDenied
    case recorderFailed

    var message: String {
        switch self {
        case .unreadable: return "That file could not be read as audio."
        case .noModel: return "The local Whisper model is not downloaded. Get it on the Dictation page; nothing is sent anywhere."
        case .modelDidNotLoad: return "The Whisper model would not load on this Mac."
        case .microphoneDenied: return "Microphone access is off for Grand Line in System Settings, Privacy, Microphone."
        case .recorderFailed: return "The recording could not start."
        }
    }
}

// MARK: - Recording

/// One memo being recorded to `voice-memos/<id>.m4a`.
class VoiceMemoRecorder {

    let id: String
    let url: URL
    let startedAt: Date
    private var recorder: AVAudioRecorder?

    init(id: String = VoiceMemoFiles.newID(), now: Date = Date()) {
        self.id = id
        url = VoiceMemoFiles.url(for: id)
        startedAt = now
    }

    func start() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else { throw VoiceMemoError.recorderFailed }
        self.recorder = recorder
    }

    /// Stops and answers how long it ran.
    func stop() -> TimeInterval {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        return duration
    }

    func discard() {
        recorder?.stop()
        recorder = nil
        try? FileManager.default.removeItem(at: url)
    }

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }
}

// MARK: - Whisper segments

extension WhisperCppEngine {

    struct Segment: Equatable {
        var start: TimeInterval
        var text: String
    }

    /// Like `transcribe`, but keeps each segment with its start time.
    func transcribeSegments(samples: [Float], language: String = "en") -> [Segment]? {
        guard let text = transcribe(samples: samples, initialPrompt: nil, language: language) else { return nil }
        let count = segmentCount()
        guard count > 0 else { return [Segment(start: 0, text: text)] }
        var out: [Segment] = []
        for i in 0..<count {
            let segment = self.segment(i)
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(Segment(start: segment.start, text: trimmed)) }
        }
        return out
    }
}
