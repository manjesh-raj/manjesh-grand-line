// Grand Line - native macOS app.
//
// The app's one shortcut recorder (`fm/grand-line-terminal-shortcuts-settings`
// generalised it out of Dictation, which built it in phase 2,
// fm/grandline-dictation-phase2): a
// small, self-built `NSView` control - click it, press the desired key/
// modifier combo, it's captured and reported via `onChange`. Built directly
// rather than adding any external dependency, per the task brief - this app
// deliberately has zero remote SPM dependencies (`CLAUDE.md`'s vendoring
// conventions for `SwiftTerm`/`YamlSwift`), and a hotkey recorder is small
// enough to build directly.
//
// Telling a **modifier-only** combo (e.g. Right ⌥ Option alone) apart from a
// **regular-key + modifiers** combo (e.g. ⌘⇧D) while recording:
//   - `flagsChanged(with:)` fires for a bare modifier press/release. The
//     *first* modifier-down transition seen while recording is captured
//     (`pendingModifierKeyCode`/`pendingModifierFlags`) - a second modifier
//     added afterward is deliberately ignored (the first-pressed key wins;
//     see the header note below on why multi-modifier-only combos aren't
//     supported). If everything releases with no regular key pressed in
//     between, that's finalized as a modifier-only shortcut.
//   - `keyDown(with:)` fires for a regular key, carrying whatever modifiers
//     are held at that instant (`event.modifierFlags`) - finalized
//     immediately as a regular-key combo, overriding any pending
//     modifier-only state (a modifier held right before a regular key was
//     always "part of a combo," not a shortcut on its own).
//
// ## `Mode`, and why it is not a caller-side validation
//
// Dictation's trigger is *held*, so a bare modifier is the right shape for it,
// and a bare key with no modifiers is fine too. A Console command shortcut is
// neither: a modifier-only "split right" would fire every time the captain
// reached for ⌘, and an unmodified `W` would eat the letter they were typing
// into their shell. `.command` refuses both **while recording** rather than
// after - so the captain sees "Add ⌘, ⌥, ⌃ or ⇧" and presses again, instead
// of pressing a combo, watching it appear in the row, and finding out later
// that it was silently discarded or, worse, that it works and steals a
// keystroke from the shell.
//
// Deliberately out of scope: a modifier-only combo made of *two or more*
// modifier keys with no regular key (e.g. "hold ⌘ then ⇧, release both").
// `KeyChord.isModifierOnly` combos are single-key by construction -
// matching OpenSuperWhisper's own convention (Right ⌥ Option, one physical
// key) and every "hold to record" affordance a captain would realistically
// want. Recording two modifiers with no regular key still produces a usable
// result (the *first* modifier pressed wins, and any later modifier addition
// is silently dropped) rather than a broken one.

import AppKit

final class KeyChordRecorderView: NSView {

    /// What this recorder will accept.
    enum Mode {
        /// Anything: a held modifier on its own, or a regular key with or
        /// without modifiers. Dictation's hold-to-record trigger.
        case any
        /// A regular key carrying at least one of ⌘⌥⌃⇧ - the only shape a
        /// command shortcut may take. See the header.
        case command
    }

    private let label = NSTextField(labelWithString: "")
    private let mode: Mode
    /// Set when a keystroke was captured but refused by `mode`, so the label
    /// can say what is wrong instead of appearing to have done nothing.
    private var rejection: String?
    private var isRecording = false
    private var pendingModifierKeyCode: UInt16?
    private var pendingModifierFlags: NSEvent.ModifierFlags = []
    private var currentTheme: HelmTheme?

    var shortcut: KeyChord {
        didSet { updateLabel() }
    }
    /// Fired once a new combo is captured - never fired for a cancelled
    /// recording (Escape, or clicking away).
    var onChange: ((KeyChord) -> Void)?

    init(shortcut: KeyChord, mode: Mode = .any) {
        self.shortcut = shortcut
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        updateLabel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    private func beginRecording() {
        isRecording = true
        rejection = nil
        pendingModifierKeyCode = nil
        pendingModifierFlags = []
        updateLabel()
        refreshThemeAppearance()
    }

    private func cancelRecording() {
        isRecording = false
        rejection = nil
        pendingModifierKeyCode = nil
        updateLabel()
        refreshThemeAppearance()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Escape cancels without changing anything.
            cancelRecording()
            return
        }
        let mods = event.modifierFlags.intersection(KeyChord.relevantModifierMask)
        let chord = KeyChord(keyCode: event.keyCode, modifierFlagsRaw: mods.rawValue, isModifierOnly: false)
        guard accepts(chord) else {
            // Stay recording: the captain meant to set a shortcut, and the
            // useful next thing is for their second attempt to land.
            rejection = "Add ⌘, ⌥, ⌃ or ⇧"
            updateLabel()
            return
        }
        finalize(chord)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        let mods = event.modifierFlags.intersection(KeyChord.relevantModifierMask)
        if !mods.isEmpty, pendingModifierKeyCode == nil {
            pendingModifierKeyCode = event.keyCode
            pendingModifierFlags = mods
        } else if mods.isEmpty, let keyCode = pendingModifierKeyCode {
            let chord = KeyChord(keyCode: keyCode, modifierFlagsRaw: pendingModifierFlags.rawValue, isModifierOnly: true)
            guard accepts(chord) else {
                pendingModifierKeyCode = nil
                rejection = "Needs a key, not a modifier on its own"
                updateLabel()
                return
            }
            finalize(chord)
        }
    }

    /// Internal (not `private`) so a self-test can assert the refusal rule
    /// without synthesising events - the two capture paths above are one-line
    /// adapters over exactly this.
    func accepts(_ chord: KeyChord) -> Bool {
        switch mode {
        case .any: return true
        case .command: return !chord.isModifierOnly && chord.hasModifiers
        }
    }

    private func finalize(_ newShortcut: KeyChord) {
        isRecording = false
        rejection = nil
        pendingModifierKeyCode = nil
        shortcut = newShortcut
        onChange?(newShortcut)
        refreshThemeAppearance()
    }

    private func updateLabel() {
        guard isRecording else {
            label.stringValue = shortcut.displayString
            return
        }
        label.stringValue = rejection ?? "Press a key or combo… (Esc to cancel)"
    }

    func applyTheme(_ theme: HelmTheme) {
        currentTheme = theme
        refreshThemeAppearance()
    }

    private func refreshThemeAppearance() {
        guard let theme = currentTheme else { return }
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = HelmTheme.nsColor(isRecording ? theme.accentHex : theme.chromeLineHex).cgColor
        label.textColor = isRecording ? HelmTheme.nsColor(theme.accentHex) : HelmTheme.nsColor(theme.chromeInkHex)
    }
}
