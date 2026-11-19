// Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for Dictation phase 2's pure data
// layer (fm/grandline-dictation-phase2) - `DictationStore`'s history/
// vocabulary persistence (real scratch files, never the captain's real
// `FM_DICTATION_DIR`) and `KeyChord`'s encode/decode + display-string
// logic. Same convention as `HostStoreSelfTest.swift`/`ShiftStoreSelfTest.swift`
// - drives the real store against a real temp directory, reloading via a
// fresh instance between steps to catch anything that only "worked" because
// of leftover in-memory state.
// `FM_RUN_DICTATION_DATA_TESTS=1 .build/debug/GrandLine`.

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

import Foundation

enum DictationDataSelfTest {
    static func run() -> Bool {
        var ok = true
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-dictation-data-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        setenv("FM_DICTATION_DIR", scratchDir.path, 1)
        defer { unsetenv("FM_DICTATION_DIR") }

        // 1. A fresh store (no files yet) starts empty.
        do {
            let store = DictationStore()
            check(store.history.isEmpty, "a fresh store should have no history", &ok)
            check(store.vocabulary.isEmpty, "a fresh store should have no vocabulary", &ok)
        }

        // 2. Recording history persists to disk and survives a reload via a
        //    separate store instance - newest entry first.
        do {
            let store = DictationStore()
            let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
            let secondDate = Date(timeIntervalSince1970: 1_700_000_100)
            store.recordHistory(text: "first thing said", durationSeconds: 3.2, date: firstDate)
            store.recordHistory(text: "second thing said", durationSeconds: 1.5, date: secondDate)

            let reloaded = DictationStore()
            check(reloaded.history.count == 2, "both recorded entries should survive a reload", &ok)
            check(reloaded.history.first?.text == "second thing said", "history should be newest-first", &ok)
            check(reloaded.history.last?.text == "first thing said", "the first entry should still be present", &ok)
            check(abs((reloaded.history.first?.durationSeconds ?? -1) - 1.5) < 0.001, "duration should round-trip exactly", &ok)
        }

        // 3. Vocabulary add/remove persists and survives a reload;
        //    case-insensitive duplicates are rejected, not appended twice.
        do {
            let store = DictationStore()
            store.addVocabularyWord("Kubernetes")
            store.addVocabularyWord("kubernetes") // case-insensitive duplicate
            store.addVocabularyWord("Manjesh")
            check(store.vocabulary.count == 2, "a case-insensitive duplicate must not be added twice", &ok)

            let reloaded = DictationStore()
            check(reloaded.vocabulary.sorted() == ["Kubernetes", "Manjesh"].sorted(), "vocabulary should survive a reload", &ok)

            reloaded.removeVocabularyWord("Kubernetes")
            check(reloaded.vocabulary == ["Manjesh"], "removing a word should leave the other one intact", &ok)

            let reloadedAgain = DictationStore()
            check(reloadedAgain.vocabulary == ["Manjesh"], "a removal should also survive a reload", &ok)
        }

        // 4. `KeyChord` round-trips through JSON exactly as
        //    `AppSettings.dictationShortcut` stores it.
        do {
            let combo = KeyChord(keyCode: 2, modifierFlagsRaw: NSEventModifierFlagsCommandShift, isModifierOnly: false)
            let data = try? JSONEncoder().encode(combo)
            check(data != nil, "a shortcut should encode to JSON", &ok)
            if let data, let decoded = try? JSONDecoder().decode(KeyChord.self, from: data) {
                check(decoded == combo, "a shortcut should decode back to an identical value", &ok)
            } else {
                check(false, "a shortcut should decode back from its own encoded JSON", &ok)
            }
        }

        // 5. Display strings for a few known combos - a modifier-only
        //    default (Right ⌥ Option) and a regular-key combo (⌘⇧D).
        do {
            check(KeyChord.dictationDefault.displayString == "Right ⌥", "the default shortcut should display as 'Right ⌥'", &ok)
            let combo = KeyChord(keyCode: 2, modifierFlagsRaw: NSEventModifierFlagsCommandShift, isModifierOnly: false)
            check(combo.displayString == "⇧⌘D", "⌘⇧D should display in the standard ⇧⌘ ordering", &ok)
        }

        // 6. Dic-1: the split card's words, every state, headless. The
        //    window-backed half is DictationStatusCardLayoutSelfTest.
        checkHeroWords(&ok)

        return ok
    }

    private static func heroWords(_ status: DictationStatus, whisper: Bool = true, cleanup: Bool = true,
                                   model: WhisperModelState = .ready, bytes: Int64? = nil, words: Int = 13,
                                   dictations: Int = 414) -> DictationHeroWords {
        DictationHeroWords.make(status: status, shortcutDisplay: "Right ⌥", localWhisperEnabled: whisper,
                                cleanupEnabled: cleanup, model: model, modelBytes: bytes, words: words,
                                dictations: dictations)
    }

    private static func checkHeroWords(_ ok: inout Bool) {
        let ready = heroWords(.ready, bytes: 547_000_000)
        check(ready.kicker == "Dictation · On device", "Dic-1: a ready kicker is \"\(ready.kicker)\"", &ok)
        check(ready.headline == "Ready. Hold Right ⌥ anywhere to dictate.", "Dic-1: the verdict is \"\(ready.headline)\"", &ok)
        check(ready.body == "Whisper large-v3-turbo on this Mac, cleanup on. 13 words in your vocabulary, 414 dictations kept here.",
              "Dic-1: the body is \"\(ready.body)\"", &ok)
        check(ready.tone == .accent && ready.action == .recheck, "Dic-1: a ready page is not the accent with Re-check", &ok)
        check(ready.ring.label == "\u{2713}" && ready.ring.fraction == 1 && !ready.ring.isDimmed,
              "Dic-1: a ready model's ring is \(ready.ring)", &ok)
        check(ready.ring.caption?.hasPrefix("Model ready · ") == true, "Dic-1: the ring's caption is \(ready.ring.caption ?? "none")", &ok)
        check(heroWords(.ready).ring.caption == "Model ready", "Dic-1: an unknown size is invented", &ok)

        // The four permission states: amber, Request Access for the right
        // permission, and never "On device".
        let asks: [(DictationStatus, String)] = [(.needsMicrophone, "Microphone"),
                                                 (.needsSpeechRecognition, "Speech Recognition"),
                                                 (.needsAccessibility, "Accessibility"), (.copiedOnly, "Accessibility")]
        for (status, permission) in asks {
            let words = heroWords(status)
            check(words.tone == .amber, "Dic-1: \(status) is not amber", &ok)
            check(words.action == .requestAccess(permission: permission), "Dic-1: \(status) asks \(words.action)", &ok)
            check(!words.kicker.hasSuffix("On device"), "Dic-1: \(status) claims \"\(words.kicker)\"", &ok)
            check(words.body == status.detail(shortcutDisplay: "Right ⌥"),
                  "Dic-1: \(status)'s body drops the status detail", &ok)
        }
        let off = heroWords(.systemDictationDisabled)
        check(off.tone == .amber && off.action == .recheck, "Dic-1: macOS Dictation off is not amber with Re-check", &ok)
        // Running states: the accent, no period after an ellipsis, and the
        // network-reaching cleanup never says On device.
        for status in [DictationStatus.recording, .transcribing, .cleaningUp] {
            let words = heroWords(status)
            check(words.tone == .accent && words.headline == status.title,
                  "Dic-1: \(status)'s verdict is \"\(words.headline)\"", &ok)
            check(!words.kicker.hasSuffix("On device"), "Dic-1: \(status) claims \"\(words.kicker)\"", &ok)
        }
        check(heroWords(.didNotCatchThat).headline == "Didn't catch that.", "Dic-1: a miss's verdict lacks its period", &ok)

        // The ring follows the model; the engine line follows it too.
        let downloading = heroWords(.ready, model: .downloading(progress: 0.42))
        check(downloading.ring.label == "42%" && abs(downloading.ring.fraction - 0.42) < 0.001,
              "Dic-1: a download's ring is \(downloading.ring)", &ok)
        check(downloading.body.hasPrefix("Apple Speech until the Whisper model finishes downloading, cleanup on."),
              "Dic-1: a download's body is \"\(downloading.body)\"", &ok)
        let absent = heroWords(.ready, model: .notDownloaded)
        check(absent.ring.isDimmed && absent.ring.fraction == 0 && absent.ring.label == "\u{2013}",
              "Dic-1: an absent model's ring is \(absent.ring)", &ok)
        let failed = heroWords(.ready, model: .failed("offline"))
        check(failed.ring.state == .warn && failed.ring.label == "!", "Dic-1: a failed download's ring is \(failed.ring)", &ok)
        let engineOff = heroWords(.ready, whisper: false, cleanup: false)
        check(engineOff.ring.isDimmed && engineOff.ring.label == "Off" && engineOff.ring.caption == "Apple Speech",
              "Dic-1: the engine off is \(engineOff.ring)", &ok)
        check(engineOff.body.hasPrefix("Apple’s on-device Speech, cleanup off."), "Dic-1: the engine off says \"\(engineOff.body)\"", &ok)

        // The library line: singulars and the empty library.
        check(DictationHeroWords.libraryLine(words: 1, dictations: 1) == "1 word in your vocabulary, 1 dictation kept here.",
              "Dic-1: singulars read \"\(DictationHeroWords.libraryLine(words: 1, dictations: 1))\"", &ok)
        check(DictationHeroWords.libraryLine(words: 0, dictations: 0)
                == "No words in your vocabulary yet, no dictations kept yet.",
              "Dic-1: an empty library reads \"\(DictationHeroWords.libraryLine(words: 0, dictations: 0))\"", &ok)
    }

    /// `.command.rawValue | .shift.rawValue`, spelled out as a plain
    /// constant here so this file has no `AppKit` import of its own (the
    /// rest of Dictation's pure-logic self-tests - this one included - avoid
    /// pulling in AppKit where `Foundation` alone suffices).
    private static let NSEventModifierFlagsCommandShift: UInt = (1 << 20) | (1 << 17)


}

#endif
