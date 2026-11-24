// Grand Line - native macOS app.
//
// fm/grandline-dictation-visual-feedback-hud: a captain-reported real
// usability gap - Dictation gave NO visual feedback anywhere except its own
// rail page (`DictationController.swift`'s Status card). Since the whole
// point of Dictation is dictating into whatever app currently has focus
// (never Grand Line's own window), there was no way to tell whether holding
// the shortcut actually started listening, was still transcribing, or
// failed, short of specifically navigating to the Dictation page first -
// which defeats the point. This file adds a small floating HUD, matching the
// reference UX of OpenSuperWhisper/Apple's own built-in dictation (a
// transient on-screen indicator), without copying either verbatim.
//
// Reuses the exact status-broadcast plumbing that already exists rather than
// inventing a second one: `DictationEngine.onStatusChanged` (wired in
// `main.swift`) already fires on every real transition the engine drives
// (recording, transcribing, cleaningUp, didNotCatchThat, and the final
// `DictationPermissions.currentStatus()` recompute after a successful
// paste/permission check) - `main.swift` now fans that single callback out
// to both `AppShellController.setDictationEngineStatus` (the existing
// Dictation-page status card) and `DictationHUDController.handle(_:)` (this
// file), rather than the HUD reading a second, parallel status source.
//
// `wasActive` is the one piece of state this controller needs beyond
// `DictationStatus` itself: the *same* underlying status value
// (`.ready`/`.needsMicrophone`/etc.) is reported both when a dictation
// completes successfully (`DictationEngine.deliver` re-reads
// `DictationPermissions.currentStatus()` after pasting) and whenever the
// Dictation page's own manual permission-request buttons succeed/fail - the
// engine has no distinct "success" status of its own (see
// `DictationStatus.swift`'s doc comment: there are exactly the four states
// the task brief describes, plus `.recording`). Gating on "did this
// controller actually see a real `.recording` state first, with no
// completion in between" is what tells the two apart without adding a fifth
// engine-level status: a permission-button click on the Dictation page never
// reports `.recording`/`.transcribing` first, so `wasActive` stays `false`
// and the HUD correctly never appears for it.
//
// Window shape: a plain, borderless `NSPanel` with `.nonactivatingPanel` in
// its style mask, `level = .floating`, and `ignoresMouseEvents = true` - the
// task brief's own suggested shape for "must not steal keyboard focus from
// whatever app the captain is actually typing into." A `.nonactivatingPanel`
// can be ordered front via `orderFrontRegardless()` without the owning app
// (Grand Line) ever becoming active and without the panel ever becoming the
// key window, so the app being dictated into keeps its own key
// window/first-responder status throughout - verified live, see this file's
// PR description for how.
//
// Position is a fixed, unobtrusive location (bottom-center of the screen
// currently under the mouse, falling back to `NSScreen.main`) - cursor-
// position tracking (Apple's own dictation HUD tracks the actual text caret
// via Accessibility) is explicitly out of scope for this pass, per the task
// brief.
//
// ## DH-2: the HUD is themed now, and why that reverses review #3 section 7
//
// This HUD used to be deliberately NOT theme-aware. It floats over other
// apps' windows, not over Grand Line's own chrome, so a fixed "system HUD"
// look was meant to read correctly against any background. Review #3 section
// 7 then found that a flat dark fill rendered in Dusk's own tones, and made
// the pill an `NSVisualEffectView` (`.hudWindow` material, `.behindWindow`
// blending, pinned `.vibrantDark`), translucent over whatever was behind it.
//
// The captain then picked DH-2 Hero pill on the hero restyle board
// (`data/grandline-hero-restyle-designs-scout/`, stage `stage-hud`), and the
// premise both of those rested on no longer holds. That premise was that
// legibility depends on what is behind the pill, so the pill must adapt to
// it. The hero pill does not depend on what is behind it at all: it is
// opaque, it paints the Dictation hero gradient (`HelmHeroColumn.palette(for:
// in:)` on `DictationController.heroTone`, the Dic-1 panel's two tones), and
// its white words clear 4.5:1 against the gradient's own lighter stop in every
// theme (`OverlaysModernizationSelfTest` measures it). What separates it from
// whatever is underneath is a window shadow and a white hairline, which hold
// over a light document and a dark editor alike. So it now follows the theme
// like everything else in the app (`ThemeManager.shared.observe`, with the
// appearance forced to the ink's), and it reads as Grand Line over any app,
// which was the mismatch the audit named: half system, half app.
//
// The pill is the Dic-1 panel in miniature. A glass glyph tile, a constant
// kicker ("Dictation · Grand Line", `DictationHeroWords.hudKicker`) that says
// whose pill this is, the state's own words as the headline
// (`DictationHUDVisualState.text`, unchanged), and a level meter while
// listening or a sweep while transcribing. It is the accent while dictation
// is going right, and the theme's amber for "Copied" and the failures, where
// the old HUD's orange was. It grew from 44pt to 52pt for the kicker, and its
// width follows its words.
//
// The meter and the sweep are Core Animation loops on the render server, and
// they hold still under Reduce Motion. They replace H3's variable-colour
// waveform, which stepped a symbol's frames on a 0.14s main-thread timer.
// Neither is wired to the microphone: like the waveform before them, they
// show that something is happening rather than measure it.
//
// Unchanged: the non-activating, never-key, click-through panel, its
// bottom-centre position on the screen under the mouse, the auto-hide delays
// (1.1s, 2.2s, 1.8s), and one VoiceOver announcement per new state.
import AppKit

enum DictationHUDVisualState: Equatable {
    case listening
    case transcribing
    case cleaningUp
    case success
    /// A dictation finished and the transcript reached the pasteboard, but
    /// the automatic ⌘V was never posted (see `DictationStatus.copiedOnly`
    /// and `DictationEngine.PasteOutcome`). Fixed
    /// `fm/grandline-dictation-autopaste-not-firing`: this state used to be
    /// folded into `.success` below (the HUD's `handle(_:)` grouped
    /// `.needsAccessibility` with `.ready`), so a captain who watched only
    /// the floating HUD saw "Pasted" every single time, including every time
    /// the paste had just silently failed - the exact misleading-status bug
    /// reported.
    case copiedOnly
    case failure(String)

    /// The glyph in the glass tile. DH-2 draws line glyphs, as the board
    /// does: a filled circle glyph inside a glass circle read as a white disc.
    var symbol: String {
        switch self {
        case .listening: return "waveform"
        case .transcribing: return "ellipsis"
        case .cleaningUp: return "sparkles"
        case .success: return "checkmark"
        case .copiedOnly: return "clipboard"
        case .failure: return "questionmark.circle"
        }
    }

    var text: String {
        switch self {
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .cleaningUp: return "Cleaning up…"
        case .success: return "Pasted"
        case .copiedOnly: return "Copied - press \u{2318}V to paste"
        case .failure(let message): return message
        }
    }

    /// `nil` means "stays on screen until the next state change" (listening/
    /// transcribing/cleaningUp are all in-progress states with no fixed
    /// duration - they end when the engine reports the next real
    /// transition, not on a timer).
    var autoHideDelay: TimeInterval? {
        switch self {
        case .listening, .transcribing, .cleaningUp: return nil
        case .success: return 1.1
        // Longer than `.success`'s flash and `.failure`'s - this one asks
        // the captain to actually do something (press ⌘V) rather than just
        // announcing an outcome, so it needs enough time to be read.
        case .copiedOnly: return 2.2
        case .failure: return 1.8
        }
    }
}

final class DictationHUDController {
    private var panel: NSPanel?
    private var pill: NSView!
    private var surface: HelmHeroSurface!
    private var glyphTile: NSView!
    private var iconView: NSImageView!
    private var kickerLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var meter: DictationHUDMeter!
    private var sweep: DictationHUDSweep!

    private var hideWorkItem: DispatchWorkItem?

    /// What the HUD is currently showing, so a live Reduce Motion change can
    /// re-decide the meter and the sweep without a state change of its own.
    private var currentState: DictationHUDVisualState?
    /// The state the pill was last painted for. Unlike `currentState` it
    /// survives the fade-out, so a theme change while the pill leaves keeps
    /// its tone.
    private var paintedState: DictationHUDVisualState = .listening
    private var reduceMotionObserver: NSObjectProtocol?
    /// DH-2: the pill follows the theme. Kept, because a HUD can be released
    /// before the app quits (every suite builds its own).
    private var themeObservation: ThemeObservation?

    init() {
        // P7: on `NSWorkspace`'s notification center, which is where macOS
        // posts this - registered on the default center it never fired.
        reduceMotionObserver = HelmDisplayAccessibility.observeChanges { [weak self] in
            self?.applyLiveAnimation()
        }
        // Fires at once, before the panel exists, and does nothing then:
        // `ensurePanel` paints the pill itself once it has built it
        // (`ThemeManager.swift`'s checklist, item 4).
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.applyTheme(theme)
        }
    }

    deinit {
        if let reduceMotionObserver {
            HelmDisplayAccessibility.stopObserving(reduceMotionObserver)
        }
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
        }
    }

    /// Set the moment a real `.recording` status is seen, cleared the moment
    /// a terminal status (success or `.didNotCatchThat`) is handled - see
    /// this file's header for why this is what distinguishes "a dictation
    /// just finished" from "a permission button was just clicked."
    private var wasActive = false

    /// The one entry point - fed every `DictationStatus` the engine reports,
    /// exactly like `AppShellController.setDictationEngineStatus` already is.
    ///
    /// `isCeilingTimeout` (fm/grandline-dictation-long-utterance-status-race)
    /// is `true` only for the one `.didNotCatchThat` the engine's hard-ceiling
    /// watchdog forces when it gives up waiting - see
    /// `DictationEngine.report(_:isCeilingTimeout:)`'s doc comment. The real
    /// pipeline keeps running in the background regardless of that forced
    /// display and will report the true outcome once it completes, so
    /// `wasActive` is deliberately left `true` in that one case instead of
    /// being cleared like a genuine terminal status would - live-reproduced
    /// (real mic, real long utterance, local Whisper engine, Metal disabled
    /// to force slower-than-usual transcription) that clearing it here
    /// silently discarded the later, real, successful completion: the HUD
    /// showed "Didn't catch that" and then nothing, even though the
    /// transcript was pasted and recorded to history moments later. Any
    /// later status - success or a genuine failure - still correctly
    /// supersedes this tentative display and clears `wasActive` for real,
    /// exactly like today. The one accepted trade-off: if this specific
    /// dictation attempt truly never completes (not just slow - genuinely
    /// hung), `wasActive` stays `true` until the next `.recording`, so an
    /// unrelated permission-button click on the Dictation page in that
    /// narrow window could show one spurious "Pasted" flash - judged a far
    /// smaller cosmetic risk than the bug this fixes, and a case the
    /// existing hard ceiling already treats as "give up and show something,"
    /// not "recover cleanly."
    func handle(_ status: DictationStatus, isCeilingTimeout: Bool = false) {
        switch status {
        case .recording:
            wasActive = true
            present(.listening)
        case .transcribing:
            guard wasActive else { return }
            present(.transcribing)
        case .cleaningUp:
            guard wasActive else { return }
            present(.cleaningUp)
        case .didNotCatchThat:
            guard wasActive else { return }
            if !isCeilingTimeout {
                wasActive = false
            }
            present(.failure("Didn't catch that"))
        case .systemDictationDisabled:
            guard wasActive else { return }
            wasActive = false
            present(.failure("System Dictation is off"))
        case .ready:
            guard wasActive else { return }
            wasActive = false
            present(.success)
        // `.needsMicrophone`/`.needsSpeechRecognition` are unreachable here in
        // practice - `.recording` can't be entered without both already
        // granted - but they're grouped with `.copiedOnly` rather than
        // `.success` defensively, since neither means "pasted" either.
        // `.needsAccessibility`/`.copiedOnly` are the real, reachable case
        // this fixes: the transcript reached the clipboard but the
        // synthetic ⌘V was never posted (`DictationEngine.PasteOutcome`).
        case .needsMicrophone, .needsSpeechRecognition, .needsAccessibility, .copiedOnly:
            guard wasActive else { return }
            wasActive = false
            present(.copiedOnly)
        }
    }

    private func present(_ state: DictationHUDVisualState) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        let panel = ensurePanel()
        iconView.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.glyphPointSize, weight: .semibold))
        titleLabel.stringValue = state.text
        let isNewState = currentState?.text != state.text
        currentState = state
        paintedState = state
        // The meter only while listening, the sweep only while transcribing.
        // Set before the pill is measured, because each changes its width.
        meter.isHidden = state != .listening
        sweep.isHidden = state != .transcribing
        applyTheme(ThemeManager.shared.theme)
        applyLiveAnimation()

        // A2: this panel is borderless, `ignoresMouseEvents`, and deliberately
        // never key - so nothing about it reaches VoiceOver on its own, and a
        // captain using one got no "Listening…" / "Pasted" / "Didn't catch
        // that" at all while a sighted captain got all three. An announcement
        // is the right shape precisely *because* the panel must not take key
        // status; it needs no focus and steals none.
        //
        // Only on a genuine state change, so a re-presented identical state
        // (which happens while a long transcription is still running) does not
        // repeat itself in the captain's ear.
        if isNewState {
            NSAccessibility.post(element: NSApp as Any,
                                 notification: .announcementRequested,
                                 userInfo: [.announcement: state.text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }

        sizePanel(panel)
        positionPanel(panel)
        let wasVisible = panel.isVisible
        panel.alphaValue = wasVisible ? panel.alphaValue : 0
        panel.orderFrontRegardless()
        // H3: "a spring pop-in". Only on a genuine appearance - a state change
        // on an already-visible HUD swaps its words, and re-popping it every
        // time would turn a two-second overlay into a jittery one.
        if !wasVisible, !HelmMotion.isReduced, let content = panel.contentView {
            content.wantsLayer = true
            if let layer = content.layer {
                HelmMotion.withoutActions {
                    layer.transform = HelmMotion.centredScale(Self.popInScale, of: layer)
                }
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = HelmMotion.springDuration
                ctx.timingFunction = HelmMotion.spring()
                panel.animator().alphaValue = 1
                // The pop is a layer `transform`, which `allowsImplicitAnimation`
                // does not animate on a view-backed layer (measured, P1 of the
                // polish report).
                HelmMotion.animateLayers(duration: HelmMotion.springDuration,
                                         timing: HelmMotion.spring(), on: [content.layer]) {
                    content.layer?.transform = CATransform3DIdentity
                }
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = HelmMotion.stateDuration
                panel.animator().alphaValue = 1
            }
        }

        if let delay = state.autoHideDelay {
            let workItem = DispatchWorkItem { [weak self] in self?.dismiss() }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        currentState = nil
        applyLiveAnimation()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = HelmMotion.moveDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    // MARK: Window construction

    /// DH-2's pill: 52pt for the kicker over the headline (the old HUD was
    /// 44pt), as wide as its words.
    static let pillHeight: CGFloat = 52
    static let glyphTileSide: CGFloat = 36
    static let glyphPointSize: CGFloat = 15
    static let headlineSize: CGFloat = 14
    static let leadingInset: CGFloat = 8
    static let trailingInset: CGFloat = 16
    static let spacing: CGFloat = 10
    /// The board's 6pt margin before the meter or the sweep.
    static let liveGap: CGFloat = 6
    /// The white hairline that separates the pill from a dark editor behind
    /// it. Kept at the old HUD's strength, which was measured against a light
    /// document.
    static let hairlineAlpha: CGFloat = 0.22

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let height = Self.pillHeight
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        // The window's own shadow follows the capsule's alpha, and it is the
        // shadow every floating panel over another app has.
        newPanel.hasShadow = true
        newPanel.level = .floating
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.alphaValue = 0

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: height))
        content.wantsLayer = true

        let pillView = NSView()
        pillView.wantsLayer = true
        pillView.translatesAutoresizingMaskIntoConstraints = false
        self.pill = pillView

        // The Dictation hero gradient, clipped to the capsule. The capsule
        // glow (`HelmHeroSurface` 1.3.0): the card's 220pt glow washed the
        // right of a 52pt pill grey.
        let surface = HelmHeroSurface()
        surface.glowShape = .capsule
        surface.layer?.cornerRadius = height / 2
        surface.layer?.borderWidth = 1
        pillView.addSubview(surface)
        self.surface = surface

        let tile = NSView()
        tile.wantsLayer = true
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.layer?.cornerRadius = Self.glyphTileSide / 2
        tile.layer?.borderWidth = 1
        self.glyphTile = tile

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        tile.addSubview(icon)
        self.iconView = icon

        let kicker = NSTextField(labelWithString: "")
        kicker.translatesAutoresizingMaskIntoConstraints = false
        self.kickerLabel = kicker

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel = label

        let words = NSStackView(views: [kicker, label])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        words.translatesAutoresizingMaskIntoConstraints = false

        let meter = DictationHUDMeter()
        self.meter = meter
        let sweep = DictationHUDSweep()
        self.sweep = sweep

        let stack = NSStackView(views: [tile, words, meter, sweep])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Self.spacing
        stack.setCustomSpacing(Self.spacing + Self.liveGap, after: words)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [tile, meter, sweep] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        pillView.addSubview(stack)
        content.addSubview(pillView)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: pillView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: pillView.trailingAnchor),
            surface.topAnchor.constraint(equalTo: pillView.topAnchor),
            surface.bottomAnchor.constraint(equalTo: pillView.bottomAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.glyphTileSide),
            tile.heightAnchor.constraint(equalToConstant: Self.glyphTileSide),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: Self.leadingInset),
            stack.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -Self.trailingInset),
            stack.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
            pillView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pillView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pillView.topAnchor.constraint(equalTo: content.topAnchor),
            pillView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        newPanel.contentView = content
        self.panel = newPanel
        applyTheme(ThemeManager.shared.theme)
        return newPanel
    }

    /// Paint the pill in `theme`, in the tone of the state it shows.
    ///
    /// `ThemeManager.swift`'s checklist: the appearance is forced too, to the
    /// ink's, as every hero surface does - a white-ink gradient is a dark
    /// surface, so anything resolving a system colour on it takes the dark
    /// one, whatever the OS is set to.
    private func applyTheme(_ theme: HelmTheme) {
        guard panel != nil else { return }
        let tone = DictationController.heroTone(DictationHeroWords.hudTone(paintedState), in: theme)
        let palette = HelmHeroColumn.palette(for: tone, in: theme)
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        let darkInk = HelmContrast.relativeLuminance(palette.ink) < 0.5
        panel?.contentView?.appearance = NSAppearance(named: darkInk ? .aqua : .darkAqua)
        surface.layer?.borderColor = ink.withAlphaComponent(
            HelmDisplayAccessibility.edgeAlpha(Self.hairlineAlpha)).cgColor
        glyphTile.layer?.backgroundColor = ink.withAlphaComponent(PopoverHeroHeader.glassFillAlpha).cgColor
        glyphTile.layer?.borderColor = ink.withAlphaComponent(PopoverHeroHeader.glassBorderAlpha).cgColor
        iconView.contentTintColor = ink
        // Read again on every pass, so the interface text size reaches a HUD
        // built before it changed.
        kickerLabel.attributedStringValue = NSAttributedString(
            string: DictationHeroWords.hudKicker.uppercased(),
            attributes: HelmType.kickerAttributes(color: ink.withAlphaComponent(HelmHeroColumn.quietInkAlpha)))
        titleLabel.font = HelmType.rounded(HelmType.scaled(Self.headlineSize), .bold)
        titleLabel.textColor = ink
        meter.applyInk(ink)
        sweep.applyInk(ink)
        if let panel, panel.isVisible {
            sizePanel(panel)
            positionPanel(panel)
        }
    }

    /// As wide as the pill's words, at the pill's height.
    private func sizePanel(_ panel: NSPanel) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let width = ceil(pill.fittingSize.width)
        if abs(panel.frame.width - width) > 0.5 || abs(panel.frame.height - Self.pillHeight) > 0.5 {
            panel.setContentSize(NSSize(width: width, height: Self.pillHeight))
            content.layoutSubtreeIfNeeded()
            panel.invalidateShadow()
        }
    }

    /// Bottom-center of whichever screen currently has the mouse cursor
    /// (falling back to `NSScreen.main`) - a captain dictating on a
    /// secondary display should see the HUD there, not only on the main one.
    /// Fixed position, not cursor-tracked (out of scope for this pass, see
    /// this file's header).
    private func positionPanel(_ panel: NSPanel) {
        #if FM_SELFTESTS
        // A suite drives the real panel through the real `present`, and a
        // panel at the bottom centre of the screen is on the captain's
        // display (the stray-window class `OffScreenProbeWindow.swift`
        // closed for every other suite). A borderless panel is not
        // constrained to a screen, so parking it holds.
        if ProcessMode.current == .selfTest {
            panel.setFrameOrigin(OffScreenProbe.parkedOrigin)
            return
        }
        #endif
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 56
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: The meter and the sweep

    static let popInScale: CGFloat = 0.88

    /// GL-16: the HUD's two loops appear unprompted over whatever app the
    /// captain is dictating into, so Reduce Motion holds both still. The
    /// meter keeps its bars and the sweep its arc, so nothing is lost but the
    /// movement.
    ///
    /// Driven from one place so the live
    /// `accessibilityDisplayOptionsDidChangeNotification` observer and a state
    /// change both reach the same decision - the same shape
    /// `IconRailController.applyMarkAnimation` used.
    private func applyLiveAnimation() {
        guard panel != nil else { return }
        let moving = !HelmMotion.isReduced
        meter.setAnimating(currentState == .listening && moving)
        sweep.setAnimating(currentState == .transcribing && moving)
    }

    #if FM_SELFTESTS
    /// Whether the level meter is moving.
    var debugIsAnimatingMeter: Bool { meter?.isAnimating ?? false }
    /// Whether the transcribing sweep is turning.
    var debugIsAnimatingSweep: Bool { sweep?.isAnimating ?? false }
    var debugMeter: DictationHUDMeter? { meter }
    var debugSweep: DictationHUDSweep? { sweep }

    /// The capsule, so a suite can measure the hero pill. Building the panel
    /// is what creates it, so a caller must have driven a state first.
    var debugPill: NSView? { pill }
    var debugSurface: HelmHeroSurface? { surface }
    var debugGlyphTile: NSView? { glyphTile }
    var debugIconView: NSImageView? { iconView }
    var debugPanel: NSPanel? { panel }

    /// `fm/grandline-dictation-autopaste-not-firing`: the actual painted
    /// title text - the surface a captain watching only this floating HUD
    /// actually reads. `debugCurrentState`'s own `.text` would assert the
    /// same string this label was *set from*, which cannot catch a rendering
    /// bug between `present(_:)` computing the state and the label actually
    /// showing it; reading `titleLabel.stringValue` back asserts what was
    /// painted, not what was computed (this file's own AGENTS.md
    /// convention).
    var debugTitleText: String? { titleLabel?.stringValue }
    var debugTitleLabel: NSTextField? { titleLabel }
    /// DH-2: the kicker as painted, in capitals.
    var debugKickerText: String? { kickerLabel?.stringValue }
    var debugKickerLabel: NSTextField? { kickerLabel }
    var debugCurrentState: DictationHUDVisualState? { currentState }
    #endif
}

// MARK: - DH-2's live marks

/// The level meter while listening: seven bars in the ink, each rising and
/// falling on its own phase, as the board draws them. A Core Animation loop
/// on the render server, so listening costs the main thread nothing.
///
/// Under Reduce Motion the bars hold the board's still pattern, alternately
/// 12pt and 7pt.
final class DictationHUDMeter: NSView {

    static let barCount = 7
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 2.5
    static let height: CGFloat = 22
    /// A bar's two heights while moving, and its two still heights.
    static let lowBar: CGFloat = 5
    static let highBar: CGFloat = 20
    static let stillTall: CGFloat = 12
    static let stillShort: CGFloat = 7
    static let barAlpha: CGFloat = 0.9
    /// The board's period, an ambient loop.
    static let meterLoopDuration: TimeInterval = 0.9
    /// Each bar's place in that period, the board's own delays.
    static let phases: [TimeInterval] = [0, 0.2, 0.45, 0.1, 0.6, 0.3, 0.75]
    static let animationKey = "dictationHUD.meter"

    private var bars: [CALayer] = []
    private(set) var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)
        for _ in 0..<Self.barCount {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        let width = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barGap
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyInk(_ ink: NSColor) {
        HelmMotion.withoutActions {
            for bar in bars { bar.backgroundColor = ink.withAlphaComponent(Self.barAlpha).cgColor }
        }
    }

    override func layout() {
        super.layout()
        HelmMotion.withoutActions {
            for (index, bar) in bars.enumerated() {
                let still = index.isMultiple(of: 2) ? Self.stillTall : Self.stillShort
                bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: still)
                bar.position = CGPoint(x: CGFloat(index) * (Self.barWidth + Self.barGap) + Self.barWidth / 2,
                                       y: bounds.midY)
            }
        }
    }

    /// Start or stop the bars. Stopped, they hold the still pattern.
    func setAnimating(_ on: Bool) {
        guard on != isAnimating else { return }
        isAnimating = on
        guard on else {
            for bar in bars { bar.removeAnimation(forKey: Self.animationKey) }
            return
        }
        let now = CACurrentMediaTime()
        for (index, bar) in bars.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
            animation.values = [Self.lowBar, Self.highBar, Self.lowBar]
            animation.keyTimes = [0, 0.5, 1]
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut),
                                         CAMediaTimingFunction(name: .easeInEaseOut)]
            animation.duration = Self.meterLoopDuration
            animation.repeatCount = .infinity
            // A negative start puts each bar part-way through its loop at
            // once, as the board's negative delays do.
            animation.beginTime = now - Self.phases[index % Self.phases.count]
            bar.add(animation, forKey: Self.animationKey)
        }
    }

    #if FM_SELFTESTS
    var debugBars: [CALayer] { bars }
    #endif
}

/// The sweep while transcribing: a quarter arc turning on a faint ring, as
/// the board draws it. Under Reduce Motion it holds still, with the arc at
/// three quarters so it still reads as a ring that is working rather than as
/// a gap.
final class DictationHUDSweep: NSView {

    static let side: CGFloat = 22
    static let lineWidth: CGFloat = 2.5
    static let trackAlpha: CGFloat = 0.3
    static let movingArc: CGFloat = 0.25
    static let stillArc: CGFloat = 0.75
    /// The board's period, an ambient loop.
    static let sweepLoopDuration: TimeInterval = 0.9
    static let animationKey = "dictationHUD.sweep"

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private(set) var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)
        for ring in [track, arc] {
            ring.fillColor = nil
            ring.lineWidth = Self.lineWidth
            ring.lineCap = .round
            layer?.addSublayer(ring)
        }
        arc.strokeEnd = Self.stillArc
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyInk(_ ink: NSColor) {
        HelmMotion.withoutActions {
            track.strokeColor = ink.withAlphaComponent(Self.trackAlpha).cgColor
            arc.strokeColor = ink.cgColor
        }
    }

    override func layout() {
        super.layout()
        let inset = Self.lineWidth / 2
        let path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        HelmMotion.withoutActions {
            for ring in [track, arc] {
                ring.bounds = bounds
                ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
                ring.path = path
            }
        }
    }

    func setAnimating(_ on: Bool) {
        guard on != isAnimating else { return }
        isAnimating = on
        HelmMotion.withoutActions { arc.strokeEnd = on ? Self.movingArc : Self.stillArc }
        guard on else {
            arc.removeAnimation(forKey: Self.animationKey)
            return
        }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = -2 * Double.pi
        animation.duration = Self.sweepLoopDuration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        arc.add(animation, forKey: Self.animationKey)
    }

    #if FM_SELFTESTS
    var debugArc: CAShapeLayer { arc }
    #endif
}
