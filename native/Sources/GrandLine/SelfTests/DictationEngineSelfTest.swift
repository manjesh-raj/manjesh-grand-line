// Grand Line - native macOS app.
//
// GL-29: permanent coverage for `DictationEngine`'s finish/race/timeout state
// machine - the review's own top-ranked untested subsystem, and for good
// reason: three real, captain-reported production bugs have shipped from this
// one method, and each was verified only by a temporary probe that was then
// reverted. Those probes are now these cases.
//
//   1. `fm/grandline-dictation-transcribe-hang-fix` - a *final* recognition
//      result whose text is empty (a real, reproduced `SFSpeechRecognizer`
//      quirk after trailing silence) meant the correct transcript, already
//      seen in a partial result, was thrown away and nothing was pasted.
//   2. `fm/grandline-dictation-stuck-transcribing-fix` - recognition finishing
//      *before* the hotkey is released left `isRecording` true, so the later
//      `stopRecording()` stomped the already-final status back to
//      "Transcribing…" forever.
//   3. `fm/grandline-dictation-long-utterance-status-race` - a fixed 13s hard
//      ceiling forced "Didn't catch that" on screen while a long utterance was
//      still genuinely being transcribed, and the real result that arrived
//      afterwards had to be able to supersede it.
//   4. `fm/grandline-dictation-autopaste-not-firing` - `pasteAtCursor` wrote
//      the pasteboard and then returned `Void`, silently, whenever
//      `AXIsProcessTrusted()` read false - a live-confirmed real state (a
//      read-only `lldb -p` attach to the captain's own running instance
//      during this task, per this file's own "Verifying native UI bugs"
//      convention, read `AXIsProcessTrusted() == 0` for a process System
//      Settings' Accessibility pane showed toggled *on* moments earlier).
//      `deliver(_:duration:)` then reported whatever
//      `DictationPermissions.currentStatus()` said, which the floating HUD
//      folded into the same "Pasted" success pill it shows for a real
//      paste - see `DictationHUD.swift` for that half's own coverage.
//
// Run: `FM_RUN_DICTATION_ENGINE_TESTS=1 .build/debug/GrandLine`
//
// Nothing here touches a microphone, the speech framework, or the network.
// Most cases never touch the pasteboard or the frontmost app either:
// `DictationEngine.pasteSinkForTests` intercepts delivery (see its doc
// comment - without it a run would type these fixtures into whatever window
// happened to be in front), and the state machine is driven through the same
// `finish`/`stopRecording` the real recognition callbacks call. Bug 4's own
// case is the one exception - it deliberately drives the real
// `pasteAtCursor`, with `DictationEngine.accessibilityTrustOverrideForTests`
// forced to `false` for its whole duration so the untrusted branch is what
// runs *regardless of this machine's real, live Accessibility trust* - the
// one thing that must never depend on override state is whether a real
// synthetic keystroke can fire, and forcing the gate closed is what
// guarantees it can't. Restores the real pasteboard's prior contents
// afterward, since this is the one case that touches it for real.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum DictationEngineSelfTest {

    static func run() -> Bool {
        // Guard rail: if this is ever set by shipping code, every case below
        // would pass while pasting nowhere. Assert the shape of the world
        // before trusting the results.
        guard DictationEngine.pasteSinkForTests == nil else {
            print("FAIL pasteSinkForTests was already set before the suite ran")
            return false
        }

        let cases: [(String, () -> String?)] = [
            ("emptyFinalResultFallsBackToTheBestPartialSeen", test_emptyFinalResultFallsBackToBestPartial),
            ("finishBeforeKeyReleaseIsNotStompedByStopRecording", test_finishBeforeKeyReleaseIsNotStomped),
            ("noTranscriptAtAllReportsDidNotCatchThat", test_noTranscriptReportsDidNotCatchThat),
            ("systemDictationDisabledIsItsOwnStatus", test_systemDictationDisabledIsDistinct),
            ("hardCeilingScalesWithCapturedAudio", test_hardCeilingScalesWithCapturedAudio),
            ("pasteSkipsSyntheticKeystrokeWhenUntrustedAndReportsCopiedOnly", test_pasteSkipsSyntheticKeystrokeWhenUntrusted),
            ("pasteGateOpensOnPostEventAccessAloneNotJustAXTrust", test_pasteGateOpensOnPostEventAccessAlone),
            ("anUntrustedSuiteNeverRaisesARealTCCPrompt", test_untrustedPasteNeverPromptsInTests),
            ("doubleFinishDeliversOnce", test_doubleFinishDeliversOnce),
            ("whisperEngineIsNotResidentUntilUsed", test_whisperNotResidentUntilUsed),
            ("whisperEngineIsReleasedAfterIdle", test_whisperReleasedAfterIdle),
            ("whisperEngineLifecycleIsNotIndefinite", test_whisperLifecycleSourceGuard),
            ("whisperEngineIsReleasedOnTerminate", test_whisperReleasedOnTerminate),
            ("cleanupPassCorrectsAVocabularyMisrecognition", test_cleanupCorrectsVocabularyMisrecognition),
            ("cleanupPassDoesNotOverCorrectAGenuineWord", test_cleanupDoesNotOverCorrectGenuineWord),
        ]

        var failures = 0
        for (name, testCase) in cases {
            var delivered: [String] = []
            DictationEngine.pasteSinkForTests = { delivered.append($0) }
            defer { DictationEngine.pasteSinkForTests = nil }
            _ = delivered
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
            DictationEngine.pasteSinkForTests = nil
        }

        if failures == 0 {
            print("DictationEngineSelfTest: all \(cases.count) cases passed")
            return true
        }
        print("DictationEngineSelfTest: \(failures) of \(cases.count) cases FAILED")
        return false
    }

    // MARK: Harness

    /// A live engine plus everything a case needs to observe it. `pasted` is
    /// what actually reached the captain's cursor; `statuses` is every status
    /// the UI (page card and floating HUD) would have shown, in order.
    private final class Harness {
        let engine = DictationEngine()
        var pasted: [String] = []
        var recorded: [(text: String, duration: TimeInterval)] = []
        var statuses: [(status: DictationStatus, isCeilingTimeout: Bool)] = []

        init(cleanupEnabled: Bool = false, vocabulary: [String] = []) {
            DictationEngine.pasteSinkForTests = { [weak self] in self?.pasted.append($0) }
            engine.onTranscript = { [weak self] text, duration in
                self?.recorded.append((text, duration))
            }
            engine.onStatusChanged = { [weak self] status, isCeiling in
                self?.statuses.append((status, isCeiling))
            }
            engine.cleanupEnabledProvider = { cleanupEnabled }
            engine.localWhisperEnabledProvider = { false }
            engine.vocabularyProvider = { vocabulary }
        }

        deinit { DictationEngine.pasteSinkForTests = nil }

        var lastStatus: DictationStatus? { statuses.last?.status }
    }

    // MARK: Cases

    /// Bug 1. The final result is empty; the correct text was only ever seen
    /// in a partial. Reverting `finish`'s `bestTranscriptSeen` fallback makes
    /// this fail with nothing delivered - which is precisely the shipped bug
    /// (the captain saw "Transcribing…" and then silence, with no paste).
    private static func test_emptyFinalResultFallsBackToBestPartial() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugNoteTranscriptForTests("restart the api deployment")
        h.engine.debugFinishForTests(text: "")

        guard h.pasted == ["restart the api deployment"] else {
            return "expected the partial transcript to be delivered, got \(h.pasted)"
        }
        guard h.recorded.count == 1, h.recorded[0].text == "restart the api deployment" else {
            return "history and paste disagree: \(h.recorded)"
        }
        guard h.lastStatus != .didNotCatchThat else {
            return "reported didNotCatchThat despite having a real transcript"
        }
        return nil
    }

    /// Bug 2. Recognition completes first, the hotkey is released after. The
    /// release must not reopen the transcribing state or re-arm a timeout.
    private static func test_finishBeforeKeyReleaseIsNotStomped() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugNoteTranscriptForTests("scale the deployment")
        // Recognition finishes while the key is still held.
        h.engine.debugFinishForTests(text: "scale the deployment")
        guard !h.engine.debugIsRecordingForTests else {
            return "finish() left isRecording true - stopRecording() will stomp the final status"
        }
        let statusAfterFinish = h.lastStatus

        // Now the captain lets go.
        h.engine.debugStopRecordingForTests()
        guard h.lastStatus == statusAfterFinish else {
            return "the key release changed the reported status to \(String(describing: h.lastStatus)) - the stuck-on-Transcribing bug"
        }
        guard h.lastStatus != .transcribing else {
            return "ended on .transcribing, which is the stuck state itself"
        }
        guard h.pasted == ["scale the deployment"] else { return "unexpected delivery: \(h.pasted)" }
        return nil
    }

    /// Genuine silence: nothing partial, nothing final. This is the one case
    /// that *should* say so, and it must not be reachable by the two above.
    private static func test_noTranscriptReportsDidNotCatchThat() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugFinishForTests(text: nil)
        guard h.pasted.isEmpty else { return "pasted \(h.pasted) for a silent recording" }
        guard h.lastStatus == .didNotCatchThat else {
            return "expected .didNotCatchThat, got \(String(describing: h.lastStatus))"
        }
        return nil
    }

    /// `fm/grandline-dictation-system-disabled-message`: the system setting
    /// being off is a different message from "didn't catch that", because the
    /// fix for it is different. Reverting that branch collapses the two.
    private static func test_systemDictationDisabledIsDistinct() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugNoteTranscriptForTests("this should not be delivered")
        h.engine.debugFinishForTests(text: nil, systemDictationDisabled: true)
        guard h.lastStatus == .systemDictationDisabled else {
            return "expected .systemDictationDisabled, got \(String(describing: h.lastStatus))"
        }
        guard h.pasted.isEmpty else {
            return "delivered \(h.pasted) even though recognition never really ran"
        }
        return nil
    }

    /// Bug 3's first half: the ceiling has to grow with how much audio was
    /// captured, or a long utterance is declared failed while it is still
    /// being transcribed. Restoring the old fixed constant makes the long
    /// case fail here.
    private static func test_hardCeilingScalesWithCapturedAudio() -> String? {
        let short = DictationEngine.debugHardCeilingDurationForTests(capturedAudioSeconds: 2)
        let long = DictationEngine.debugHardCeilingDurationForTests(capturedAudioSeconds: 49)
        guard short >= 13 else { return "short-utterance ceiling regressed to \(short)s (floor is 13s)" }
        guard long > short else {
            return "ceiling did not grow with captured audio (\(short)s for 2s of audio, \(long)s for 49s)"
        }
        guard long >= short + 40 else {
            return "ceiling grew by only \(long - short)s for 47s more audio - not enough to cover a real long utterance"
        }
        return nil
    }

    /// Bug 4. `pasteAtCursor` must skip the synthetic ⌘V (never call
    /// `CGEvent.post`) and report `.copiedOnly` - not `.ready` - the moment
    /// Accessibility trust reads false, and the pasteboard write must still
    /// happen regardless (a captain can always paste manually). Reverting
    /// `pasteAtCursor`'s `guard isAccessibilityTrustedForPaste() else { ... }`
    /// branch back to a bare `return` (this bug's actual shipped shape) makes
    /// `deliver` fall through to `report(DictationPermissions.currentStatus())`
    /// unconditionally, which this case would then catch as a `.copiedOnly`
    /// mismatch.
    private static func test_pasteSkipsSyntheticKeystrokeWhenUntrusted() -> String? {
        // This is the one case in this file that does not use
        // `pasteSinkForTests` - it drives the real `pasteAtCursor` on purpose,
        // so `accessibilityTrustOverrideForTests` (not the sink) is what has
        // to guarantee no real keystroke can fire, on any machine this runs on.
        DictationEngine.pasteSinkForTests = nil
        DictationEngine.accessibilityTrustOverrideForTests = false
        let priorClipboard = NSPasteboard.general.string(forType: .string)
        defer {
            DictationEngine.accessibilityTrustOverrideForTests = nil
            if let priorClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(priorClipboard, forType: .string)
            }
        }

        let fixture = "restart the api deployment (DictationEngineSelfTest fixture)"
        let outcome = DictationEngine.pasteAtCursor(fixture)
        guard outcome == .skippedNoTrust else {
            return "expected .skippedNoTrust with trust forced false, got \(outcome)"
        }
        guard NSPasteboard.general.string(forType: .string) == fixture else {
            return "the pasteboard write must still happen even when the synthetic paste is skipped"
        }

        let h = Harness()
        DictationEngine.pasteSinkForTests = nil
        defer { DictationEngine.pasteSinkForTests = nil }
        h.engine.debugBeginCaptureForTests()
        h.engine.debugNoteTranscriptForTests(fixture)
        h.engine.debugFinishForTests(text: fixture)
        guard h.lastStatus == .copiedOnly else {
            return "expected .copiedOnly after an untrusted paste, got \(String(describing: h.lastStatus)) - this is the exact misleading-status bug (status read as success with nothing typed anywhere)"
        }
        return nil
    }

    /// `fm/grand-line-dictation-autopaste-fix`. The gate that decides whether
    /// the synthetic \u{2318}V may be posted used to be `AXIsProcessTrusted()`
    /// alone, which is not the permission that governs posting an event -
    /// `CGPreflightPostEventAccess()` is. The case that matters is the one the
    /// old gate got wrong: post-event access true, AX trust false. Asserted
    /// against the pure rule rather than the live system reads, so it means
    /// the same thing on a CI runner that has never been trusted at all.
    ///
    /// Reverting `pasteGateIsOpen` to `axTrusted` alone (the shipped bug's own
    /// shape) fails this case by name on its second check.
    private static func test_pasteGateOpensOnPostEventAccessAlone() -> String? {
        // Discriminating power first: the four inputs must not all agree, or
        // every check below would pass vacuously.
        guard DictationEngine.pasteGateIsOpen(postEventAccess: false, axTrusted: false) == false else {
            return "the gate opened with neither permission - it can no longer refuse anything"
        }
        guard DictationEngine.pasteGateIsOpen(postEventAccess: true, axTrusted: false) else {
            return "the gate refused a process that macOS says may post events - this is the exact captain-reported bug (transcript copied, never pasted)"
        }
        guard DictationEngine.pasteGateIsOpen(postEventAccess: false, axTrusted: true) else {
            return "the gate stopped honouring AXIsProcessTrusted() - the old, still-valid half of the rule regressed"
        }
        guard DictationEngine.pasteGateIsOpen(postEventAccess: true, axTrusted: true) else {
            return "the gate refused a fully-permitted process"
        }
        return nil
    }

    /// The recovery path added by the same task calls `CGRequestPostEventAccess()`,
    /// which raises a real system permission dialog. A suite must never do
    /// that on the captain's own machine, so the forced-untrusted override has
    /// to short-circuit the request rather than merely making it fail.
    /// Deleting `requestPostEventAccessIfNotYetAsked()`'s
    /// `accessibilityTrustOverrideForTests != nil` early return makes the
    /// counter read 1 and fails this case.
    private static func test_untrustedPasteNeverPromptsInTests() -> String? {
        DictationEngine.pasteSinkForTests = nil
        DictationEngine.accessibilityTrustOverrideForTests = false
        DictationEngine.debugResetPostEventAccessRequestStateForTests()
        let priorClipboard = NSPasteboard.general.string(forType: .string)
        defer {
            DictationEngine.accessibilityTrustOverrideForTests = nil
            DictationEngine.debugResetPostEventAccessRequestStateForTests()
            if let priorClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(priorClipboard, forType: .string)
            }
        }

        let fixture = "scale the worker pool to six (DictationEngineSelfTest fixture)"
        let outcome = DictationEngine.pasteAtCursor(fixture)
        guard outcome == .skippedNoTrust else {
            return "expected .skippedNoTrust with the gate forced closed, got \(outcome)"
        }
        guard DictationEngine.postEventAccessRequestCountForTests == 0 else {
            return "a suite reached the real CGRequestPostEventAccess() \(DictationEngine.postEventAccessRequestCountForTests) time(s) - that raises a system dialog on the captain\'s machine"
        }
        guard NSPasteboard.general.string(forType: .string) == fixture else {
            return "the pasteboard write must still happen when the gate is closed"
        }
        return nil
    }

    // MARK: E2 - the local Whisper engine's lifetime
    //
    // The audit's second battery finding: creating a whisper context creates a
    // ggml Metal device whose residency keeper is an infinite `usleep(5ms)`
    // loop - 200 wake-ups a second for the life of the process, found in all
    // 3259 samples of a 5-second `sample` of the captain's real instance, and
    // matching Activity Monitor's 202 idle wake-ups exactly. It used to be
    // cached for the whole session, so one dictation started it forever.
    //
    // Nothing here needs the 547MB model: what must be true is that the engine
    // is absent until a dictation loads it and gone again once the ready key
    // has been idle. The model-backed half runs only when a real model is
    // pointed at via `FM_WHISPER_TEST_MODEL_PATH`, the same seam
    // `WhisperEngineSelfTest` already uses.

    private static func test_whisperNotResidentUntilUsed() -> String? {
        let h = Harness()
        guard !h.engine.isWhisperEngineResident else {
            return "a freshly constructed engine already holds a Whisper context (something pre-warms it)"
        }
        // A dictation that never opted into local Whisper must not load it.
        h.engine.debugBeginCaptureForTests()
        h.engine.debugFinishForTests(text: "apple speech only")
        guard !h.engine.isWhisperEngineResident else {
            return "an Apple-Speech-only dictation loaded the local Whisper engine"
        }
        // Releasing when nothing is loaded is a no-op, not a crash.
        h.engine.releaseWhisperEngine(reason: "self-test")
        return nil
    }

    private static func test_whisperReleasedAfterIdle() -> String? {
        guard DictationEngine.whisperIdleUnloadInterval > 0,
              DictationEngine.whisperIdleUnloadInterval <= 600 else {
            return "idle unload interval is \(DictationEngine.whisperIdleUnloadInterval)s - 0 defeats the cache, >600 is a background process by any reading"
        }
        guard let modelPath = ProcessInfo.processInfo.environment["FM_WHISPER_TEST_MODEL_PATH"],
              !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            print("  (skipping the model-backed half: FM_WHISPER_TEST_MODEL_PATH not set)")
            return nil
        }
        let h = Harness()
        guard h.engine.debugLoadWhisperEngineForTests(modelPath: modelPath) else {
            return "the real model at \(modelPath) failed to load, so residency could not be observed"
        }
        guard h.engine.isWhisperEngineResident else {
            return "a successful load did not report the engine as resident"
        }
        DictationEngine.whisperIdleUnloadIntervalOverrideForTests = 0.4
        defer { DictationEngine.whisperIdleUnloadIntervalOverrideForTests = nil }
        h.engine.debugScheduleWhisperIdleUnloadForTests()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        guard !h.engine.isWhisperEngineResident else {
            return "the engine was still resident after the idle window elapsed - the ggml waker never stops"
        }
        return nil
    }

    /// Source guard: the release is only real if something arms it on the one
    /// path that loads an engine. A behavioural check cannot see this without
    /// the 547MB model, and the failure mode (an engine that loads and is
    /// never scheduled for release) is exactly the shipped bug.
    private static func test_whisperLifecycleSourceGuard() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        let path = dir.appendingPathComponent("DictationEngine.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        guard text.contains("scheduleWhisperIdleUnload()") else {
            return "DictationEngine.swift no longer arms the idle release anywhere"
        }
        guard text.contains("self?.scheduleWhisperIdleUnload()") else {
            return "the local-Whisper completion path no longer arms the idle release - the engine would stay resident for the session again"
        }
        guard text.contains("cachedWhisperEngine = nil") else {
            return "nothing releases the cached engine, so `whisper_free`/`ggml_metal_rsets_free` never runs"
        }
        return nil
    }


    /// **Review bug B2.** The app aborted on quit whenever a Whisper context
    /// was still loaded: ggml keeps its Metal devices in a C++ static vector
    /// whose destructor runs inside `exit()`, past everything AppKit can hook,
    /// and `ggml_metal_device_free` asserts the residency set is empty.
    /// `GrandLine-2026-09-24-210949.ips` and `-2026-09-25-122236.ips` are both
    /// that abort, on the main thread, from `-[NSApplication terminate:]`.
    ///
    /// The check is a source guard **scoped to `applicationWillTerminate`'s own
    /// body**, not a file-wide grep: `releaseWhisperEngine` is called from
    /// three other places (the idle timer, the model-change path, this suite),
    /// so a grep over the file would stay green with the terminate call
    /// deleted - the exact "assert the helper, not the wiring" trap AGENTS.md
    /// warns about. A behavioural check cannot reach this at all: `NSApp` is
    /// nil in a headless suite, so `AppDelegate` cannot be constructed, and
    /// observing the abort needs a real 547MB model and a real process exit.
    /// The model-backed half below asserts the release itself does empty the
    /// context, which is the other half of the claim.
    private static func test_whisperReleasedOnTerminate() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        let path = dir.appendingPathComponent("main.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return "main.swift could not be read, so this guard checked nothing"
        }
        guard let start = text.range(of: "func applicationWillTerminate(") else {
            return "main.swift has no applicationWillTerminate - the flush point this depends on is gone"
        }
        // The body runs to the first line that closes it at the method's own
        // indentation, which in this file is four spaces.
        let after = text[start.upperBound...]
        guard let end = after.range(of: "\n    }\n") else {
            return "could not find the end of applicationWillTerminate"
        }
        let body = String(after[..<end.lowerBound])

        // Discriminating power first: the extracted body has to be the real
        // one, or every check below passes against an empty string.
        guard body.contains("console.shutdown()") else {
            return "the extracted applicationWillTerminate body does not look like the real one"
        }
        guard body.contains("releaseWhisperEngine(") else {
            return "applicationWillTerminate does not release the Whisper engine - ggml's static "
                + "destructor will ggml_abort inside exit() after any recent dictation (B2)"
        }
        guard body.contains("releaseWhisperEngine(reason: \"terminate\")") else {
            return "the terminate release is there but does not name its reason 'terminate', which is "
                + "what distinguishes it in the lifecycle log from the idle unload"
        }

        // The other half of the claim, where a real model is available: the
        // release genuinely empties the context that holds the residency sets.
        guard let modelPath = ProcessInfo.processInfo.environment["FM_WHISPER_TEST_MODEL_PATH"],
              !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            return nil
        }
        let h = Harness()
        guard h.engine.debugLoadWhisperEngineForTests(modelPath: modelPath) else {
            return "the real model at \(modelPath) failed to load, so the release could not be observed"
        }
        guard h.engine.isWhisperEngineResident else {
            return "a successful load did not report the engine as resident"
        }
        h.engine.releaseWhisperEngine(reason: "terminate")
        guard !h.engine.isWhisperEngineResident else {
            return "the terminate release left a Whisper context alive - exit() would still abort"
        }
        return nil
    }

    /// Belt and braces on `isFinishing`: two finishes (the real timeout firing
    /// alongside a real result, which is exactly how bug 2 was reached) must
    /// deliver once, not twice.
    private static func test_doubleFinishDeliversOnce() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugFinishForTests(text: "only once please")
        h.engine.debugFinishForTests(text: "only once please")
        guard h.pasted.count == 1 else { return "delivered \(h.pasted.count) times: \(h.pasted)" }
        guard h.recorded.count == 1 else { return "recorded \(h.recorded.count) history entries" }
        return nil
    }

    // MARK: Vocabulary-aware cleanup correction
    //
    // The captain's own reported bug: with "herdr" already in "Words I use
    // often" - and therefore already biasing live recognition via
    // `SFSpeechRecognitionRequest.contextualStrings` (see
    // `DictationEngine.beginCapture`) - a phrase like "an herdr session" still
    // reliably came out as "an older session," because that API has no
    // per-word weight knob to push a custom word's priority any higher.
    // `DictationCleanup`'s "Clean up my sentences" pass now also corrects a
    // plausible phonetic misrecognition of a vocabulary word using the whole
    // sentence's context - see `DictationCleanup.swift`'s header for the full
    // reasoning, including why this rides the existing toggle rather than a
    // second one.
    //
    // Unlike `DictationCleanupSelfTest.swift` (which exercises
    // `DictationCleanup` directly, in isolation), these two cases drive the
    // *real* `finish` -> `finishWithFinalText` -> `DictationCleanup.rewrite`
    // path through this engine's own `cleanupEnabledProvider`/
    // `vocabularyProvider` - proving the call site actually threads the
    // vocabulary list through, not just that `DictationCleanup` would use it
    // correctly if handed it. Confirmed live (this task's own regression
    // check, not asserted here): reverting `finishWithFinalText`'s
    // `vocabulary: vocabulary` argument passes every case in
    // `DictationCleanupSelfTest.swift` untouched and still fails here - that
    // file alone cannot see a dropped call-site argument.
    //
    // Real model behavior (does the correction genuinely happen; does the
    // model genuinely decline to over-correct a real "older") was verified
    // live against the real `claude` CLI with this exact prompt shape - see
    // this task's PR description for both transcripts. These cases use a
    // disposable fake `claude` (never the real CLI, never a real network
    // call) whose canned reply stands in for what the real model already
    // proved it does, so the *plumbing* between this engine and that pass
    // stays covered deterministically and without a live Claude dependency.

    /// Correction happens: the vocabulary list reaches the real prompt sent
    /// to `claude`, and the corrected result is what's actually pasted and
    /// recorded.
    ///
    /// Asserting the *outcome* alone would not actually prove the vocabulary
    /// was threaded through this engine's call site: a fake `claude` that
    /// ignores its own input and always prints the same canned reply passes
    /// this case's outcome check whether or not `vocabulary` ever reached
    /// `DictationCleanup.rewrite` at all (confirmed the hard way while
    /// writing this - a first draft asserted only the outcome and kept
    /// passing after deliberately dropping `vocabulary: vocabulary` from
    /// `finishWithFinalText`'s call site). The `argv.txt` check below, on the
    /// real prompt this engine actually sent, is what makes this a genuine
    /// wiring regression test rather than one that only proves
    /// `DictationCleanup` itself works correctly if handed a vocabulary list.
    private static func test_cleanupCorrectsVocabularyMisrecognition() -> String? {
        guard let script = writeFakeClaudeCapturingArgv(resultJSON: #"{"result": "Let's start a herdr session.", "is_error": false}"#) else {
            return "could not write the fake claude script"
        }
        let scriptDir = script.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: scriptDir) }
        DictationCleanup.claudePathOverrideForTests = script.path
        defer { DictationCleanup.claudePathOverrideForTests = nil }

        let h = Harness(cleanupEnabled: true, vocabulary: ["herdr"])
        h.engine.debugBeginCaptureForTests()
        h.engine.debugFinishForTests(text: "let's start an older session")
        waitUntil(timeout: 15) { h.lastStatus != .cleaningUp }

        guard h.pasted == ["Let's start a herdr session."] else {
            return "expected the vocabulary-corrected text to be delivered, got \(h.pasted)"
        }
        guard h.recorded.count == 1, h.recorded[0].text == "Let's start a herdr session." else {
            return "history should record the same corrected text that was pasted, got \(h.recorded)"
        }
        let sentArgv = (try? String(contentsOf: scriptDir.appendingPathComponent("argv.txt"), encoding: .utf8)) ?? ""
        guard sentArgv.contains("herdr") else {
            return "the vocabulary word never reached the real prompt this engine sent to claude - argv:\n\(sentArgv)"
        }
        return nil
    }

    /// No over-correction: a genuinely-meant word that superficially
    /// resembles a vocabulary entry must pass through unmodified, not get
    /// swapped for the vocabulary word just because it's on the list. The
    /// vocabulary list still reaches the real prompt either way (the model
    /// choosing not to correct is a *model* decision, not a code path that
    /// skips sending the vocabulary in the first place).
    private static func test_cleanupDoesNotOverCorrectGenuineWord() -> String? {
        let unmodified = "He's a bit older than expected for this position."
        guard let script = writeFakeClaudeCapturingArgv(resultJSON: #"{"result": "\#(unmodified)", "is_error": false}"#) else {
            return "could not write the fake claude script"
        }
        let scriptDir = script.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: scriptDir) }
        DictationCleanup.claudePathOverrideForTests = script.path
        defer { DictationCleanup.claudePathOverrideForTests = nil }

        let h = Harness(cleanupEnabled: true, vocabulary: ["herdr"])
        h.engine.debugBeginCaptureForTests()
        h.engine.debugFinishForTests(text: "he's a bit older than expected for this position")
        waitUntil(timeout: 15) { h.lastStatus != .cleaningUp }

        guard h.pasted == [unmodified] else {
            return "a genuinely-meant word should pass through unmodified, got \(h.pasted)"
        }
        let sentArgv = (try? String(contentsOf: scriptDir.appendingPathComponent("argv.txt"), encoding: .utf8)) ?? ""
        guard sentArgv.contains("herdr") else {
            return "the vocabulary list should still reach the sent prompt even when the model declines to correct - argv:\n\(sentArgv)"
        }
        return nil
    }

    /// A disposable fake `claude` executable (never the real CLI) that dumps
    /// its own real argv (the prompt travels as one argv element - see
    /// `ClaudeOneShot.swift`'s header) to a sibling `argv.txt` before printing
    /// one canned `claude -p ... --output-format json` reply - the same
    /// argv-capturing shape `DictationCleanupSelfTest.swift`'s
    /// `writeFakeClaudeCapturingArgv` uses, and for the identical reason: a
    /// fake script that only ever returns canned output cannot, on its own,
    /// prove what was actually sent to it. This file needed its own copy
    /// since that one is `private` to its own enum.
    private static func writeFakeClaudeCapturingArgv(resultJSON: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-dictation-engine-cleanup-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let path = dir.appendingPathComponent("claude")
        let escaped = (resultJSON + "\n").replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$(dirname "$0")/argv.txt"
        printf '%s' '\(escaped)'
        exit 0
        """
        guard (try? script.write(to: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// Pumps the main run loop (never blocks on a semaphore - see
    /// `DictationCleanupSelfTest.runRewriteSync`'s own doc comment for why:
    /// `DictationCleanup.rewrite`'s completion is dispatched via
    /// `DispatchQueue.main.async`, and this suite runs on the main thread
    /// before `NSApplication.run()` starts) until `condition` is true or
    /// `timeout` elapses.
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}

#endif
