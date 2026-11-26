// Grand Line - native macOS app.
//
// F-05 of full review 4: voice memos that become notes.
// Run with `FM_RUN_VOICE_MEMO_TESTS=1 .build/debug/GrandLine`.
//
// Headless, and it never opens the microphone: the recorder is a test double
// and the transcriber a fake, except for one case that reads a WAV file this
// suite writes, to check the audio really is read and resampled for
// Whisper. A real Whisper transcription runs only when the model is already
// on this Mac, and says so when it is skipped.
//
// What it pins:
//
//  - **The key**: Right ⌥ + ⇧ in either order, not Left ⌥, not with ⌘.
//  - **The page**: the marker round-trips, the transcript keeps its
//    timestamps, and a task note says it was transcribed on this Mac.
//  - **The flow**: a held key records and the HUD says so; letting go asks
//    where it goes; the Notebook page appears under Memos with the
//    transcript; a slip of the key is dropped; a task gets a voice note;
//    a dictation already started is discarded; the microphone being off and
//    the app being locked are both said or refused.
//  - **A dropped file** becomes a page that fills in when transcribed.
//  - **The strip**: a memo page whose audio is on another Mac says so.

#if FM_SELFTESTS

import AppKit
import AVFoundation

enum VoiceMemoSelfTest {

    static func run() -> Bool {
        var ok = true
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        let cases: [(String, () -> String?)] = [
            ("the key is Right Option + Shift", test_hotkey),
            ("the page marker and transcript", test_page),
            ("record, choose, file to the Notebook", test_flowNotebook),
            ("a slip of the key is dropped", test_shortPress),
            ("a voice note on a task", test_flowTask),
            ("microphone off and locked", test_permissionsAndLock),
            ("a dropped file becomes a page", test_import),
            ("audio is read and resampled for Whisper", test_samples),
            ("the strip without its audio", test_strip),
            ("Dictation yields the chord", test_dictationYields),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[voice-memo] \(name): \(failure)", &ok) } else { print("[voice-memo] PASS \(name)") }
        }
        print(ok ? "[voice-memo] ALL PASS" : "[voice-memo] FAILED")
        return ok
    }

    final class FakeRecorder: VoiceMemoRecorder {
        var duration: TimeInterval = 3
        var started = false
        var discarded = false
        override func start() throws {
            started = true
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fake".utf8).write(to: url)
        }
        override func stop() -> TimeInterval { duration }
        override func discard() { discarded = true; try? FileManager.default.removeItem(at: url) }
        override var elapsed: TimeInterval { 1 }
    }

    static let segments = [VoiceMemoSegment(start: 0, text: "Okay, three things for the 4.20 release."),
                           VoiceMemoSegment(start: 21, text: "Cut the branch Friday, not Saturday."),
                           VoiceMemoSegment(start: 80, text: "Renew the staging cert before any of this.")]

    static func withScratch<T>(_ body: (URL, NotebookStore, ShiftStore) -> T) -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-memo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = ["FM_NOTEBOOK_DIR", "FM_SHIFT_DIR", VoiceMemoFiles.directoryVariable].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("FM_NOTEBOOK_DIR", dir.appendingPathComponent("notebook").path, 1)
        setenv("FM_SHIFT_DIR", dir.appendingPathComponent("shift").path, 1)
        setenv(VoiceMemoFiles.directoryVariable, dir.appendingPathComponent("memos").path, 1)
        defer { for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
        return body(dir, NotebookStore(), ShiftStore())
    }

    static func controller(notebook: NotebookStore, shift: ShiftStore, recorder: FakeRecorder,
                           result: Result<[VoiceMemoSegment], VoiceMemoError> = .success(segments)) -> VoiceMemoController {
        let c = VoiceMemoController()
        c.notebookStore = { notebook }
        c.shiftStore = { shift }
        c.microphone = { .authorized }
        c.accessibilityTrusted = { true }
        c.makeRecorder = { recorder }
        c.transcribe = { _, progress, done in progress(0.5); DispatchQueue.main.async { done(result) } }
        return c
    }

    static func pump(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: Cases

    static func test_hotkey() -> String? {
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | VoiceMemoHotkey.rightOptionDeviceBit)
        let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        guard VoiceMemoHotkey.isChordDown(flags: right.union(.shift)) else { return "Right Option + Shift was not the chord" }
        guard !VoiceMemoHotkey.isChordDown(flags: left.union(.shift)) else { return "Left Option + Shift was the chord" }
        guard !VoiceMemoHotkey.isChordDown(flags: right) else { return "Right Option alone was the chord (that is Dictation)" }
        guard !VoiceMemoHotkey.isChordDown(flags: right.union([.shift, .command])) else { return "with Command it was the chord" }
        let hotkey = VoiceMemoHotkey()
        var events: [String] = []
        hotkey.onStart = { events.append("start") }
        hotkey.onStop = { events.append("stop") }
        // Shift first, then Right Option, then let go of Option.
        hotkey.update(flags: .shift)
        hotkey.update(flags: right.union(.shift))
        hotkey.update(flags: .shift)
        // Option first, then Shift, then let go of Shift.
        hotkey.update(flags: right)
        hotkey.update(flags: right.union(.shift))
        hotkey.update(flags: right)
        hotkey.update(flags: [])
        return events == ["start", "stop", "start", "stop"] ? nil : "events \(events)"
    }

    static func test_page() -> String? {
        let md = VoiceMemoPage.markdown(title: "Memo \u{00B7} 25 Nov, 08:12", marker: .init(id: "memo-20261125-081200-abcd", duration: 102),
                                        segments: segments, source: "transcribed on this Mac")
        guard let marker = VoiceMemoPage.marker(in: md), marker.id == "memo-20261125-081200-abcd", marker.duration == 102 else {
            return "the marker did not round-trip:\n\(md)"
        }
        guard md.contains("[0:21] Cut the branch Friday, not Saturday."), md.contains("**Voice memo** \u{00B7} 1:42") else {
            return "the transcript or header is wrong:\n\(md)"
        }
        guard VoiceMemoPage.transcriptLines(in: md) == segments.map(\.text) else { return "lines \(VoiceMemoPage.transcriptLines(in: md))" }
        guard VoiceMemoPage.marker(in: "\(VoiceMemoPage.markerPrefix) id=../../etc duration=3 -->") == nil else {
            return "a path in the id was accepted"
        }
        // The marker is syntax in the write view: hidden off the caret's line.
        let markerLine = "\(VoiceMemoPage.markerPrefix) id=memo-x duration=3 -->"
        guard NotebookLiveMarkdown.spans(in: markerLine).contains(where: { $0.kind == .mark && $0.range.length == (markerLine as NSString).length }) else {
            return "the write view would show the memo marker as text"
        }
        let note = VoiceMemoPage.taskNote(segments: segments, duration: 38, recordedAt: Date(), id: "memo-x")
        return note.contains("transcribed on this Mac") && note.hasPrefix("\u{201C}Okay") ? nil : "task note \(note)"
    }

    static func test_flowNotebook() -> String? {
        AppLockGate.shared.setLocked(false)
        return withScratch { _, notebook, shift in
            let recorder = FakeRecorder()
            let c = controller(notebook: notebook, shift: shift, recorder: recorder)
            var discarded = 0
            c.discardDictation = { discarded += 1 }
            var opened: String?
            c.openNotebookPage = { opened = $0 }
            c.keyDown()
            guard recorder.started, case .recording = c.hud.state else { return "holding the key did not record: \(String(describing: c.hud.state))" }
            guard discarded == 1 else { return "a dictation in flight was not discarded" }
            c.keyUp()
            guard c.hud.view.debugButtonTitles.first == "A new Notebook page" else {
                return "letting go offered \(c.hud.view.debugButtonTitles)"
            }
            c.hud.view.debugPress("A new Notebook page")
            pump()
            guard let id = opened, let page = notebook.page(id: id) else { return "no page was opened" }
            guard page.folder == "memos", VoiceMemoPage.marker(in: page.content)?.id == recorder.id,
                  page.content.contains("[1:20] Renew the staging cert before any of this.") else {
                return "the page is wrong (\(page.id)):\n\(page.content)"
            }
            return c.hud.view.debugDetail == "Saved to Notebook \u{203A} Memos" ? nil : "the HUD said \(c.hud.view.debugDetail)"
        }
    }

    static func test_shortPress() -> String? {
        AppLockGate.shared.setLocked(false)
        return withScratch { _, notebook, shift in
            let recorder = FakeRecorder()
            recorder.duration = 0.2
            let c = controller(notebook: notebook, shift: shift, recorder: recorder)
            c.keyDown()
            c.keyUp()
            pump(0.1)
            return recorder.discarded && notebook.listPages().isEmpty ? nil : "a 0.2s press was kept"
        }
    }

    static func test_flowTask() -> String? {
        AppLockGate.shared.setLocked(false)
        return withScratch { _, notebook, shift in
            var task = ShiftTask.fresh()
            task.title = "Rotate the CI deploy key"
            shift.addTask(task)
            let recorder = FakeRecorder()
            let c = controller(notebook: notebook, shift: shift, recorder: recorder)
            guard c.taskChoices().contains(where: { $0.id == task.id }) else { return "the task is not offered" }
            c.keyDown()
            c.keyUp()
            c.choose(.task(id: task.id, title: task.title))
            pump()
            guard let notes = shift.activeTasks.first(where: { $0.id == task.id })?.notes,
                  notes.contains("Voice note"), notes.contains("Cut the branch Friday") else {
                return "the task's notes: \(String(describing: shift.activeTasks.first { $0.id == task.id }?.notes))"
            }
            return notebook.listPages().isEmpty ? nil : "a task note also made a page"
        }
    }

    static func test_permissionsAndLock() -> String? {
        withScratch { _, notebook, shift in
            AppLockGate.shared.setLocked(false)
            let recorder = FakeRecorder()
            let c = controller(notebook: notebook, shift: shift, recorder: recorder)
            c.microphone = { .denied }
            c.keyDown()
            guard !recorder.started else { return "it recorded with the microphone off" }
            guard case .message(let text, let settings)? = c.hud.state, text == VoiceMemoError.microphoneDenied.message,
                  settings != nil, c.hud.view.debugButtonTitles == ["Open System Settings"] else {
                return "the microphone-off state is not said: \(String(describing: c.hud.state))"
            }
            c.microphone = { .authorized }
            c.accessibilityTrusted = { false }
            c.keyDown()
            guard c.hud.view.debugButtonTitles.contains("Allow Accessibility\u{2026}") else {
                return "no Accessibility hint while recording without the grant: \(c.hud.view.debugButtonTitles)"
            }
            c.discard()
            let locked = FakeRecorder()
            let c2 = controller(notebook: notebook, shift: shift, recorder: locked)
            AppLockGate.shared.setLocked(true)
            c2.keyDown()
            AppLockGate.shared.setLocked(false)
            return locked.started ? "it recorded while locked" : nil
        }
    }

    /// A one-second 440Hz tone as a 44.1kHz WAV.
    static func writeTone(to url: URL, seconds: Double = 1) -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44_100 * seconds)) else { return false }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) * 0.3 }
        return (try? file.write(from: buffer)) != nil
    }

    static func test_import() -> String? {
        AppLockGate.shared.setLocked(false)
        return withScratch { dir, notebook, shift in
            let wav = dir.appendingPathComponent("standup-recording.wav")
            guard writeTone(to: wav) else { return "could not write the fixture" }
            let c = controller(notebook: notebook, shift: shift, recorder: FakeRecorder())
            var finished = false
            guard let id = c.importAudio(wav, progress: { if $0 >= 1 { finished = true } }) else { return "the drop was refused" }
            guard notebook.page(id: id)?.content.contains("Transcribing on this Mac") == true else {
                return "the page did not appear at once with its progress"
            }
            let deadline = Date().addingTimeInterval(3)
            while !finished, Date() < deadline { pump(0.05) }
            guard let page = notebook.page(id: id), page.content.contains("[0:00] Okay, three things"),
                  let marker = VoiceMemoPage.marker(in: page.content),
                  FileManager.default.fileExists(atPath: VoiceMemoFiles.directory().appendingPathComponent("\(marker.id).wav").path) else {
                return "the page did not fill in, or the audio was not kept: \(notebook.page(id: id)?.content ?? "nil")"
            }
            return c.importAudio(dir.appendingPathComponent("notes.txt")) == nil ? nil : "a text file was taken as audio"
        }
    }

    static func test_samples() -> String? {
        withScratch { dir, _, _ in
            let wav = dir.appendingPathComponent("tone.wav")
            guard writeTone(to: wav, seconds: 2) else { return "could not write the fixture" }
            guard let samples = VoiceMemoTranscriber.samples(of: wav) else { return "the file was not read" }
            // 2s at Whisper's 16kHz, give or take the converter's edges.
            guard abs(samples.count - 32_000) < 1_600 else { return "\(samples.count) samples for 2s" }
            if FileManager.default.fileExists(atPath: WhisperModelManager.shared.modelPathOnDisk) {
                guard case .success = VoiceMemoTranscriber.transcribeNow(wav) else { return "a real transcription failed" }
            } else {
                print("[voice-memo] SKIP the real Whisper pass: the model is not on this Mac")
            }
            return nil
        }
    }

    static func test_strip() -> String? {
        withScratch { dir, _, _ in
            let strip = VoiceMemoStrip()
            strip.show(content: "# A page\n\nNo memo here.")
            guard strip.isHidden else { return "an ordinary page showed the strip" }
            let content = VoiceMemoPage.markdown(title: "Memo", marker: .init(id: "memo-elsewhere-0001", duration: 102),
                                                 segments: segments, source: "x")
            strip.show(content: content)
            guard !strip.isHidden, !strip.debugPlayEnabled, strip.debugFoot.contains("on the Mac that recorded it"),
                  strip.debugTime == "0:00 / 1:42" else {
                return "a memo with its audio elsewhere: hidden \(strip.isHidden), play \(strip.debugPlayEnabled), \(strip.debugFoot), \(strip.debugTime)"
            }
            let here = VoiceMemoFiles.directory().appendingPathComponent("memo-here-0001.wav")
            try? FileManager.default.createDirectory(at: here.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard writeTone(to: here) else { return "could not write the fixture" }
            strip.show(content: VoiceMemoPage.markdown(title: "Memo", marker: .init(id: "memo-here-0001", duration: 1),
                                                       segments: segments, source: "x"))
            return strip.debugPlayEnabled && strip.transcriptText.contains("Cut the branch") ? nil : "the audio on this Mac did not play"
        }
    }

    static func test_dictationYields() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { print("[voice-memo] SKIP guard"); return nil }
        let text = (try? String(contentsOf: dir.appendingPathComponent("AppComposition.swift"), encoding: .utf8)) ?? ""
        guard let onDown = text.range(of: "lazy var dictationHotkey = DictationHotkey("),
              text[onDown.upperBound...].prefix(3_000).contains("VoiceMemoHotkey.isChordDown(flags: NSEvent.modifierFlags)") else {
            return "Dictation's key no longer steps aside for Right Option + Shift"
        }
        return text.contains("memos.discardDictation = { [weak self] in self?.dictationEngine.discardRecording() }")
            ? nil : "a memo no longer discards a dictation already started"
    }
}

#endif
