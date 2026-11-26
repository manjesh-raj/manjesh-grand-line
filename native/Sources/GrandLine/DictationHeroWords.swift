// Grand Line - native macOS app.
//
// What Dictation's split card says (Dic-1 on the page-redesign board). The
// gradient panel carries the verdict, a line about the engine and the
// library, the local Whisper model as its ring, and the one pill - Request
// Access while a permission is missing, Re-check permissions otherwise.
//
// Pure, so `DictationDataSelfTest` asserts every state headless. The page
// (`DictationController`) owns the controls and only hands these words to the
// panel.
//
// **DH-2, the floating HUD** (the hero restyle board,
// `data/grandline-hero-restyle-designs-scout/`). The HUD is the same panel in
// miniature: a constant kicker that says whose pill this is, since it floats
// over other apps, over the state's own words (`DictationHUDVisualState.text`,
// unchanged), in this panel's two tones. An earlier draft used this panel's
// kicker words ("Dictation · Listening" over "Listening…"), and the captain
// pointed out that it said "Listening" twice.

import Foundation

struct DictationHeroWords: Equatable {

    enum Tone: Equatable { case accent, amber }

    /// The panel's one pill.
    enum Action: Equatable {
        /// A permission is missing: the pill asks for it. `permission` names
        /// it for the hover text and VoiceOver.
        case requestAccess(permission: String)
        /// Everything is granted: the pill re-reads the permissions.
        case recheck
    }

    let kicker: String
    let headline: String
    let body: String
    let ring: HelmHeroColumn.Ring
    let tone: Tone
    let action: Action

    /// The model's approximate size, for the states where it is not on disk.
    static let approximateModelSize = "~547 MB"

    static func make(status: DictationStatus, shortcutDisplay: String, localWhisperEnabled: Bool,
                     cleanupEnabled: Bool, model: WhisperModelState, modelBytes: Int64?,
                     words: Int, dictations: Int) -> DictationHeroWords {
        let headline: String
        let body: String
        if status == .ready {
            headline = "Ready. " + status.detail(shortcutDisplay: shortcutDisplay)
            body = engineLine(localWhisperEnabled: localWhisperEnabled, cleanupEnabled: cleanupEnabled, model: model)
                + " " + libraryLine(words: words, dictations: dictations)
        } else {
            let title = status.title
            headline = title.hasSuffix("\u{2026}") ? title : title + "."
            body = status.detail(shortcutDisplay: shortcutDisplay)
        }
        return DictationHeroWords(kicker: "Dictation \u{00B7} " + kickerWord(status), headline: headline, body: body,
                                  ring: ring(localWhisperEnabled: localWhisperEnabled, model: model,
                                             modelBytes: modelBytes),
                                  tone: needsCaptain(status) ? .amber : .accent, action: action(status))
    }

    /// The kicker's second word. "On device" only once every permission is
    /// granted and nothing is running: `.cleaningUp` really does reach the
    /// network, so the claim would be false there.
    static func kickerWord(_ status: DictationStatus) -> String {
        switch status {
        case .ready: return "On device"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .cleaningUp: return "Cleaning up"
        case .didNotCatchThat: return "Try again"
        case .needsMicrophone, .needsSpeechRecognition, .needsAccessibility: return "Needs access"
        case .copiedOnly: return "Paste blocked"
        case .systemDictationDisabled: return "Off in macOS"
        }
    }

    /// Whether the captain has to do something before dictation works: the
    /// board's one reason to tone the panel amber.
    static func needsCaptain(_ status: DictationStatus) -> Bool {
        switch status {
        case .needsMicrophone, .needsSpeechRecognition, .needsAccessibility, .copiedOnly, .systemDictationDisabled:
            return true
        case .ready, .recording, .transcribing, .cleaningUp, .didNotCatchThat:
            return false
        }
    }

    /// The pill, and which permission Request Access asks for. A paste that
    /// was refused asks for Accessibility, the same as before it was ever
    /// granted (`statusActionTapped`).
    static func action(_ status: DictationStatus) -> Action {
        switch status {
        case .needsMicrophone: return .requestAccess(permission: "Microphone")
        case .needsSpeechRecognition: return .requestAccess(permission: "Speech Recognition")
        case .needsAccessibility, .copiedOnly: return .requestAccess(permission: "Accessibility")
        case .ready, .recording, .transcribing, .cleaningUp, .didNotCatchThat, .systemDictationDisabled:
            return .recheck
        }
    }

    /// Which engine transcribes, and whether cleanup runs after it. The local
    /// engine only counts once its model is here: until then dictation falls
    /// back to Apple's recognizer, and the line says so.
    static func engineLine(localWhisperEnabled: Bool, cleanupEnabled: Bool, model: WhisperModelState) -> String {
        let engine: String
        if !localWhisperEnabled {
            // UI-09: the ring names the engine now, so the line says the
            // optional local model is off - the ring's old "Off".
            return "Listening with Apple Speech" + (cleanupEnabled ? ", cleanup on." : ", cleanup off.")
                + " The local Whisper model is off."
        } else if case .ready = model {
            engine = "Whisper large-v3-turbo on this Mac"
        } else if case .downloading = model {
            engine = "Apple Speech until the Whisper model finishes downloading"
        } else {
            engine = "Apple Speech until the Whisper model is downloaded"
        }
        return engine + (cleanupEnabled ? ", cleanup on." : ", cleanup off.")
    }

    /// The vocabulary and the history, counted. GL-14 does not apply: both
    /// are local files read in full, so a zero really is none.
    static func libraryLine(words: Int, dictations: Int) -> String {
        let vocabulary: String
        switch words {
        case 0: vocabulary = "No words in your vocabulary yet"
        case 1: vocabulary = "1 word in your vocabulary"
        default: vocabulary = "\(words) words in your vocabulary"
        }
        let kept: String
        switch dictations {
        case 0: kept = "no dictations kept yet."
        case 1: kept = "1 dictation kept here."
        default: kept = "\(dictations) dictations kept here."
        }
        return vocabulary + ", " + kept
    }

    /// The engine that listens, as the ring: a microphone while Apple Speech
    /// does, and the local model's tick, or its percentage while it
    /// downloads, once Whisper is on. UI-09 of full review 4: with Whisper
    /// off the ring read "Off" beside a headline saying "Ready", and a
    /// first-time captain read it as dictation being off.
    static func ring(localWhisperEnabled: Bool, model: WhisperModelState, modelBytes: Int64?) -> HelmHeroColumn.Ring {
        let size = modelBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        if !localWhisperEnabled {
            return HelmHeroColumn.Ring(fraction: 1, label: "Apple Speech", caption: "Apple Speech",
                                       spoken: "Listening with Apple Speech. The local Whisper model is off.",
                                       state: .ok, symbol: "mic.fill")
        }
        switch model {
        case .ready:
            return HelmHeroColumn.Ring(fraction: 1, label: "\u{2713}",
                                       caption: size.map { "Model ready \u{00B7} \($0)" } ?? "Model ready",
                                       spoken: "Whisper model ready", state: .ok)
        case .downloading(let progress):
            let percent = Int(progress * 100)
            return HelmHeroColumn.Ring(fraction: progress, label: "\(percent)%", caption: "Downloading the model",
                                       spoken: "Whisper model downloading, \(percent) percent", state: .ok)
        case .notDownloaded:
            return HelmHeroColumn.Ring(fraction: 0, label: "\u{2013}",
                                       caption: "No model yet \u{00B7} \(approximateModelSize)",
                                       spoken: "Whisper model not downloaded", state: .idle, isDimmed: true)
        case .failed:
            return HelmHeroColumn.Ring(fraction: 0, label: "!", caption: "Download failed",
                                       spoken: "Whisper model download failed", state: .warn, isDimmed: true)
        }
    }

    // MARK: DH-2 - the floating HUD

    /// The HUD's kicker, the same in every state.
    static let hudKicker = "Dictation \u{00B7} Grand Line"

    /// The HUD's tone: the accent while dictation is going right, and the
    /// theme's amber where today's HUD was orange - a paste that only reached
    /// the clipboard, and the two failures. Each failure's headline is
    /// complete on its own ("Didn't catch that"), and the amber says it is one.
    static func hudTone(_ state: DictationHUDVisualState) -> Tone {
        switch state {
        case .listening, .transcribing, .cleaningUp, .success: return .accent
        case .copiedOnly, .failure: return .amber
        }
    }
}
