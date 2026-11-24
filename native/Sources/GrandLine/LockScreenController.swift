// Grand Line - native macOS app.
//
// The app-level lock screen: the "Daylight Harbour" gate
// (`fm/grandline-home-login-redesign-plan`).
//
// # Why this file was rewritten
//
// The seven-phase Daylight migration deliberately excluded this screen twice,
// in writing - the spec's own must-NOT-change list says "The lock screen's
// bespoke scene (`LockScreenController`) - out of scope", and the earlier full
// UI audit reached the same call ("Lock screen is a deliberate scene - keep").
// That decision outlived its reason: by the end of Phase 6 this was the only
// full-window surface in the app with *zero* design-system usage - measured,
// `grep -c "isDaylight\|HelmCard\|HelmButton\|HelmType\|HelmMetrics"` returned
// 28 for `BootstrapController`, 7 for `HomeCanvasController` and 0 for this
// file - while being the first thing seen on every single launch.
//
// The captain reviewed a design proposal
// (`data/grandline-home-login-redesign-plan/report.md`) and chose Direction A,
// "Daylight Harbour": keep the sailing scene, rebuild it out of tokens, and
// turn the loose hand-rolled form into a real floating card.
//
// # What that means concretely
//
// - Every colour is theme-derived. There is not one `NSColor(calibratedRed:)`
//   literal left in this file; the previous version had eleven, plus a second
//   hand-tuned palette for dark mode. Dark now resolves through
//   `DaylightTokens.dusk` like every other Daylight surface.
// - The form is a `HelmCard`-recipe card (radius `dModule`, `hair` border,
//   `HelmCard.elevation(.raised)`, a 6pt domain-gradient ribbon across the
//   top) - §6.10's editor-sheet recipe, which is what buys the coherence.
// - The password field is `HelmSecureTextField`, so it inherits Phase 0's
//   first-responder focus ring (the D1 fix) and themed selection for free.
// - Both buttons are `HelmButton`. The previous ones painted a literal
//   `rgb(0.20, 0.48, 0.92)` that was not even the theme accent.
// - Type goes through `HelmType`, so GL-32's chrome-text-scale setting reaches
//   this screen for the first time.
//
// # The one deliberate deviation from the approved mockup
//
// The mockup drew a small `lock.fill` glyph inside the password well. It is
// not built, and that is a decision rather than an omission: `HelmSecureTextField`
// owns its own chrome, and the only ways to get a glyph inside it were to fork
// a second secure-field component or to hand-roll a well around a raw
// `NSSecureTextField` - which `checkNoRawTextInputs` bans outright, and which
// would re-split the input taxonomy Phase 0 spent a whole phase unifying. The
// well is the app's one secure input, unmodified. The gate's identity is
// carried by the gradient mark above it instead.
//
// # What did NOT change (and must not)
//
// This is presentation only. Every one of the following is byte-for-byte what
// it was, and each is load-bearing for a reason recorded at its own site:
//
// - The auth flow. This controller still only collects a password and reports
//   it via `onAttempt`; `AppShellController` still verifies it on a background
//   queue through `VaultSource.verifyAppPassword`, which shells out to Automic
//   Vault with the typed candidate passed by *environment variable* so it never
//   appears in `ps`. There is no `LAContext`/Touch ID path on this screen and
//   never was - that is SSH key unlock (`KeychainKeyStore`), a different
//   mechanism entirely.
// - The six `ContentState` cases and their distinct semantics.
//   `.serviceNotRunning` / `.transientFailure` stay separate from
//   `.noPasswordConfigured`: conflating them is exactly the bug
//   `fm/grandline-vault-wake-recheck-fix` closed.
// - `onUnlockAnimationFinished` is still what hides the overlay, not
//   `onAttempt`'s own completion - see `submitTapped`.
// - Reduce Motion gating: the bob and the wave drift are gated, the success
//   sail-away deliberately is not (it carries the `CATransaction` completion
//   block that actually lifts the overlay).
// - GL-31's copyable setup command row.
//
// # One structural change worth knowing
//
// The sky gradient used to *be* `root.layer`. That is why this screen could
// never be screenshotted: `bitmapImageRepForCachingDisplay`/`cacheDisplay`
// render a view whose root layer is a `CAGradientLayer` as blank white, which
// the full UI audit hit and recorded ("Not verifiable by off-screen capture ...
// Assessed from source only"). The sky is a *sublayer* of a plain
// `wantsLayer` root now, exactly like every other Daylight surface - so this
// screen is visible to the off-screen render probe for the first time, and
// `FM_RUN_LOCK_SCREEN_TESTS` uses that to verify its own work.
//
// # L-2: the lighthouse (`fm/grandline-login-lamp-design-scout`)
//
// The captain picked board design L-2 with the Going Merry and card style C-4
// "Open sea". The scene is a blue hour (the light register's own sky taken
// toward its ink), a lighthouse on a cliff whose lamp is the gate's light,
// sea fog, and the Going Merry riding the swell.
//
// - **The card is not there until the lamp is lit.** `.locked` starts dark;
//   every other state starts lit, because those cards carry setup commands,
//   Check again and the Touch ID fallback, and none of that may hide behind a
//   lamp. Reduce Motion and VoiceOver start lit too.
// - **Typing always works.** The field is first responder from the first
//   frame, exactly as `focusPasswordField()` has always made it; the card is
//   hidden by alpha (never `isHidden`, which would move first responder off
//   it) and refuses clicks while dark. A local key-down monitor lights the
//   lamp on the first key and hands the event on untouched.
// - **Tap the lighthouse** to light it, and tap it again to put it out while
//   the field is empty. Return and the in-field arrow submit as Unlock did.
// - C-4 Open sea applies to `.locked` only: no card surface, a round avatar,
//   and the password as a pill on the scene with an arrow inside it. The
//   setup states keep the card exactly as before.
// - The success flourish is still one `CATransaction` whose completion fires
//   `onUnlockAnimationFinished`; day breaking and the beams fading ride in it.
import AppKit

final class LockScreenController: NSViewController {

    enum ContentState {
        case locked(subtitle: String)
        case noPasswordConfigured
        /// `av` itself isn't installed on this Mac at all - distinct from
        /// `.noPasswordConfigured` (av installed, no secret saved yet): the
        /// "run av save..." instruction is actively wrong here since there's
        /// no `av` to run. Shows the Homebrew install command in the copyable
        /// well instead, and never runs it (R2-SEC-06).
        case avUnavailable
        /// `av` is on PATH but its background approval service (the
        /// "Automic Vault" menu-bar app) isn't reachable yet - the password
        /// secret may already exist, `av` just can't confirm it right now.
        /// Check again re-runs the underlying check; nothing retries it on a
        /// timer (`fm/grand-line-vault-no-launch-prompt`).
        case serviceNotRunning
        /// `av list` failed (or timed out) for a reason that isn't the
        /// specific `.serviceNotRunning` marker text - e.g. the approval
        /// helper being transiently unresponsive right after a long
        /// sleep/wake (`fm/grandline-vault-wake-recheck-fix`, live-
        /// confirmed: a suspended helper process makes `av list` hang
        /// indefinitely). The password secret may well already exist here
        /// too, and a denied approval dialog lands here as well. Check
        /// again re-runs the check, as for `.serviceNotRunning`.
        case transientFailure

        /// The domain hue this state's ribbon, mark and primary action take.
        ///
        /// Captain's call, delegated to the design proposal's own
        /// recommendation: the resting/locked states take blue (the app's own
        /// logo pair, and the hue §2.2 gives to generic gates and default
        /// focus), while the two states that are really *setup* instructions
        /// take amber - Setup's own hue - so the gate borrows Setup's colour
        /// exactly when it is telling the captain to go do setup.
        var hue: HelmDomainHue {
            switch self {
            case .noPasswordConfigured, .avUnavailable: return .amber
            case .locked, .serviceNotRunning, .transientFailure: return .blue
            }
        }

        /// The mark tile's glyph. Every symbol here is verified to resolve in
        /// `LockScreenSelfTest` - `NSImage(systemSymbolName:)` returns nil
        /// silently, and this app has shipped an invisible icon that way
        /// before (the `anchor` incident).
        var symbol: String {
            switch self {
            case .locked, .serviceNotRunning, .transientFailure: return "sailboat.fill"
            case .noPasswordConfigured: return "flag.fill"
            case .avUnavailable: return "arrow.down.circle.fill"
            }
        }
    }

    /// `(typed password, completion(success))` - the caller verifies on a
    /// background queue and calls `completion` back on the main thread.
    var onAttempt: ((String, @escaping (Bool) -> Void) -> Void)?

    /// **UX issue X1.** Fired when the captain uses the local fallback on a
    /// screen where Automic Vault cannot be reached. The caller runs the
    /// real `LAContext` challenge off the main thread (GL-25) and calls back
    /// on main with whether the device owner actually authenticated.
    ///
    /// A separate callback from `onAttempt` rather than a magic password,
    /// because they are different authentications with different failure
    /// text - and because a cancel here must read as "you cancelled", not
    /// as "that password didn't match".
    var onLocalAuthAttempt: ((@escaping (Bool) -> Void) -> Void)?

    /// Whether this Mac can authenticate its owner at all. Injected rather
    /// than read here so a suite can drive both branches without a Mac that
    /// has (or lacks) Touch ID, and so this controller keeps knowing nothing
    /// about `LocalAuthentication`.
    var localAuthAvailable: () -> Bool = { false }

    /// R2-UX-01: "Check again" on the two setup states, which used to end in
    /// "then relaunch". The caller runs the same availability check a new
    /// lock screen runs.
    var onCheckAgain: (() -> Void)?

    /// Fired once the success animation (below) has actually finished
    /// playing - `AppShellController` hides the overlay and records the
    /// unlock from here, not from `onAttempt`'s own completion, so the
    /// flourish plays fully visible instead of running on a view that's
    /// already been hidden out from under it.
    var onUnlockAnimationFinished: (() -> Void)?

    // MARK: Geometry

    /// The gate card's fixed content width. Widened from the original 352pt
    /// (captain feedback: the card read as cramped) - still narrower than
    /// `HelmFormSheet.width` (520), since this card's content is a title, one
    /// field and one button, not a multi-section form.
    static let cardWidth: CGFloat = 420
    /// §6.10's ribbon weight, shared with `HelmFormSheet`.
    private static let ribbonHeight: CGFloat = 6
    /// Grown alongside `cardWidth` so the wider card doesn't read as flat -
    /// `HelmMetrics.s5`, one step up the spacing scale from the original 20pt.
    private static let cardPadding: CGFloat = HelmMetrics.s5

    // MARK: Scene

    private let boatImageView = NSImageView()
    private let waveLayer = CAShapeLayer()
    /// A second, paler swell drawn behind and slightly above the first. One
    /// wave at this scale reads as a flat wedge; two give the sea a horizon.
    private let backWaveLayer = CAShapeLayer()
    /// H4: "two subtle gradients (sky, sea)". The sky was already one; the sea
    /// was a flat fill, which is the "hard-edged color bands read as clip-art"
    /// half of the finding.
    ///
    /// A `CAShapeLayer` cannot carry a gradient fill, so each swell becomes
    /// the **mask** of a gradient layer. The drift animation is unchanged and
    /// still runs on the shape layer: a mask's own `position` still moves the
    /// visible shape within its host, so parallax survives the change.
    private let seaGradient = CAGradientLayer()
    private let backSeaGradient = CAGradientLayer()
    private var waveWidth: CGFloat = 0
    /// The sky. A **sublayer** of a plain `wantsLayer` root, never the root
    /// layer itself - see this file's header for why that one detail is what
    /// makes this screen screenshottable.
    private let skyLayer = CAGradientLayer()
    private var starLayers: [CALayer] = []
    private let sunLayer = CALayer()
    /// Punched out of `sunLayer` in the dark register to read as a crescent
    /// moon rather than a blue sun. Hidden in light mode.
    private let moonBiteLayer = CALayer()

    // MARK: Lighthouse (board design L-2)

    /// The lighthouse, its lens, the fog and the flash. Owns layers only.
    private let lighthouse = LockLighthouseScene()
    /// Day breaking on unlock in the light register: today's sky and sun,
    /// faded in over the dusk.
    private let daySkyLayer = CAGradientLayer()
    private let daySunLayer = CALayer()
    /// The tower's tap target: light the lamp, or with the field empty, put it out.
    private let lighthouseHotspot = SceneHotspotView()
    /// Whether the lamp is on, which is whether the gate's card is showing.
    private(set) var isLit = true
    private var keyMonitor: Any?
    /// The colours the current scene resolved to, for the success flourish.
    private var currentScene: SceneColors?

    // MARK: Card

    /// The un-clipped shadow host. §2.5: a layer with a shadow must not clip,
    /// and a rounded fill must - so the card is the two-layer arrangement
    /// `HelmComposerCard` already proved here, with `shadowPath` resynced on
    /// every layout pass.
    private let cardShadowHost = GateHostView()
    /// The clipped content layer - this is the view that carries the fill,
    /// border and corner radius.
    private let card = NSView()
    /// B6 (`data/grand-line-e2e-audit/report.md`): the ribbon syncs its own
    /// layer's frame from its own `layout()`, rather than depending on
    /// `viewDidLayout` -> `applyLayerGeometry` having run at a moment when
    /// this view already had bounds.
    ///
    /// It did not, on first presentation: the audit's probe read
    /// `ribbonLayer.frame = (0,0,0,0)` on a fully laid-out 1220x720 first
    /// presentation and `(0,0,420,6)` only after a resize, so the lock screen
    /// - the first thing seen on every launch - opened with its domain ribbon
    /// simply missing. `layout()` is called whenever a view's own bounds
    /// resolve, which is exactly the condition this needs and is not
    /// something a caller has to remember to re-trigger.
    private let ribbonView = GradientHostView()
    private var ribbonLayer: CAGradientLayer { ribbonView.gradient }
    private let markTile = HelmGradientTile(size: .hero)
    /// C-4 Open sea: the round avatar that stands in for the mark tile on `.locked`.
    private let avatar = OpenSeaAvatarView()
    /// C-4 Open sea: the arrow inside the password pill. Return still submits.
    private let arrowButton = HelmIconButton(symbol: "arrow.right", label: "Unlock")
    private var formFullWidth: NSLayoutConstraint?
    private var formOpenWidth: NSLayoutConstraint?
    /// Whether the gate draws as C-4 Open sea (no card) - `.locked` only.
    private var openStyle = false

    // MARK: Content

    private let titleLabel = NSTextField(labelWithString: LockScreenController.greeting())
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    /// **Review defect U17.** The placeholder used to be a run of nine
    /// bullets, on the theory that masked dots are what a password field
    /// looks like. They are - which is the problem: a secure field showing
    /// dots is a secure field with something *in* it, so the first thing the
    /// app shows on launch read as a pre-filled password sitting behind an
    /// Unlock button, and the natural first move is to clear a field that is
    /// already empty.
    ///
    /// A placeholder's job is to say what the empty field is for, and the
    /// one thing dots cannot say is "empty". The word can.
    private let passwordField = HelmSecureTextField(placeholder: "Password")
    /// H4's un-clipped host for the field's focus glow - see where it is wired.
    private let passwordWell = NSView()
    private let unlockButton = HelmButton(title: "Unlock", variant: .primary)
    private let formStack = NSStackView()
    /// Shown only after a rejected password. Previously the failure was
    /// signalled by the shake alone, with no words at all.
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// GL-31: the first-run instruction used to be prose containing a command
    /// the captain had to retype by hand, on the one screen in the app where
    /// nothing else is reachable. The command renders as a real code well
    /// with a Copy button beside it.
    private let setupCommandLabel = NSTextField(labelWithString: VaultSource.appPasswordSetupCommand)
    private let copyCommandButton = HelmButton(title: "Copy", variant: .secondary, size: .small)
    private let setupCommandStack = NSStackView()
    /// The command the well shows and Copy copies: the app-password setup
    /// line, or on `.avUnavailable` the Homebrew install line.
    private var shownSetupCommand = VaultSource.appPasswordSetupCommand

    // `.avUnavailable`-only UI: a distinct message above the command well.
    //
    // R2-SEC-06: this state used to carry an "Install Automic Vault" button
    // that ran `brew install --cask` straight from here. The one screen whose
    // purpose is to require a credential offered a machine-changing,
    // network-reaching action to whoever was standing at it. It shows the
    // command instead, in the same copyable well as the password setup line,
    // and the captain runs it themselves.
    private let avMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let avUnavailableStack = NSStackView()

    /// R2-UX-01: the way forward from both setup states, without quitting.
    private let checkAgainButton = HelmButton(title: "Check again", variant: .secondary)

    /// The two "Automic Vault did not answer" states show a still clock and a
    /// line instead of a form. It used to be a moving spinner, back when
    /// these states retried on a timer; nothing is in flight now, so nothing
    /// moves (`fm/grand-line-vault-no-launch-prompt`).
    private let waitingGlyph = NSImageView()
    private let waitingStack = NSStackView()
    private let waitingLabel = NSTextField(labelWithString: "")

    /// X1: the way out of the retry loop. Shown only in the two states that
    /// are waiting on Automic Vault, and only when this Mac can actually
    /// answer the challenge.
    private let localAuthStack = NSStackView()
    private let localAuthButton = HelmButton(title: "Unlock with Touch ID or your Mac password",
                                             variant: .secondary)
    private let localAuthNote = NSTextField(wrappingLabelWithString:
        "Automic Vault holds this app's own password. While it is unreachable, "
        + "macOS can vouch for you instead.")

    // §6.10's footer: a hairline, then a caption line.
    private let footerDivider = NSView()
    private let footerLeftLabel = NSTextField(labelWithString: "")
    private let footerRightLabel = NSTextField(labelWithString: "")
    private let footerStack = NSStackView()

    private var contentStack = NSStackView()

    /// The hue currently driving the ribbon, mark and primary button. Held so
    /// a theme change can re-derive them without the caller re-applying state.
    private var currentHue: HelmDomainHue = .blue
    private var currentSymbol: String = "sailboat.fill"

    override func loadView() {
        // A plain layer-backed root with a real background - NOT a
        // `CAGradientLayer` assigned as `root.layer`, which is what made this
        // screen invisible to every render probe. The fill is set per theme in
        // `applyTheme`; `wantsLayer` here is what guarantees `root.layer`
        // exists by the time the theme observer fires (this codebase's
        // most-repeated gotcha - see `ThemeManager.swift`'s checklist).
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1220, height: 720))
        root.wantsLayer = true
        view = root

        buildScene(in: root)
        buildCard()

        contentStack = NSStackView(views: [cardShadowHost])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)
        root.addSubview(boatImageView)

        // The boat sails on the sea, below the gate - but it is positioned by
        // Auto Layout, never by a fixed fraction of the window's height. That
        // fraction WAS this file's first draft, and a captain screenshot on a
        // real, much taller window caught it landing squarely on top of the
        // password field: a height fraction and an Auto-Layout-centred card
        // are two independent systems with no reason to agree at every size.
        //
        // The arrangement below cannot reproduce that, and the priorities are
        // the reason. Only the anti-overlap constraint is required, and it
        // relates two subviews to each other rather than to the window, so it
        // can never cap the window's size (gotcha (13)). The two that pull the
        // boat down to the waterline both sit *below*
        // `NSLayoutPriorityWindowSizeStayPut` (500), so on a window too short
        // for both the boat simply rides up and the card stays intact.
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            // 40pt higher than the original -30, so the gate clears the Going
            // Merry's flag by the board's 86pt (captain's call, round 4).
            contentStack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -70),
            boatImageView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            boatImageView.topAnchor.constraint(greaterThanOrEqualTo: cardShadowHost.bottomAnchor,
                                               constant: HelmMetrics.s5),
        ])
        let onTheWater = boatImageView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -76)
        onTheWater.priority = NSLayoutConstraint.Priority(250)
        let stayOnScreen = boatImageView.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor,
                                                                constant: -8)
        stayOnScreen.priority = NSLayoutConstraint.Priority(400)
        NSLayoutConstraint.activate([onTheWater, stayOnScreen])

        // The tower's tap target sits over the drawing; its frame follows the
        // scene in `layoutSceneLayers`.
        root.addSubview(lighthouseHotspot)
        lighthouseHotspot.onClick = { [weak self] in self?.toggleLamp() }

        // Follow the app's active Helm theme, live - see `ThemeManager.swift`'s
        // header checklist. Registered last, after every view above exists, so
        // the synchronous first firing has a fully-built tree to paint; this
        // controller is a permanent, app-lifetime singleton owned by
        // `AppShellController`, so the returned token can be discarded per that
        // file's own convention for such observers.
        ThemeManager.shared.observe { [weak self] theme in
            self?.applyTheme(theme)
        }
    }

    // MARK: - Construction

    private func buildScene(in root: NSView) {
        skyLayer.locations = [0, 0.55, 1]
        skyLayer.startPoint = CGPoint(x: 0.5, y: 1)
        skyLayer.endPoint = CGPoint(x: 0.5, y: 0)
        root.layer?.addSublayer(skyLayer)

        // A handful of small, fixed-position stars (dark register only) -
        // deterministic rather than randomized so this view renders identically
        // on every launch and every render probe. Always built, hidden in the
        // light register via `applyTheme` rather than added/removed, so there's
        // never a frame with neither stars nor a sun.
        let starPositions: [(CGFloat, CGFloat, CGFloat)] = [
            (0.08, 0.85, 1.4), (0.15, 0.72, 1.0), (0.22, 0.90, 1.6), (0.30, 0.65, 1.1),
            (0.38, 0.88, 1.3), (0.46, 0.70, 1.0), (0.55, 0.92, 1.5), (0.63, 0.78, 1.1),
            (0.70, 0.60, 1.3), (0.78, 0.87, 1.0), (0.85, 0.73, 1.6), (0.92, 0.83, 1.2),
            (0.12, 0.55, 1.0), (0.35, 0.45, 1.2), (0.58, 0.50, 1.0), (0.80, 0.48, 1.3),
        ]
        for (xFrac, yFrac, radius) in starPositions {
            let star = CALayer()
            star.cornerRadius = radius / 2
            star.frame = NSRect(x: 0, y: 0, width: radius, height: radius)
            star.setValue(xFrac, forKey: "xFrac")
            star.setValue(yFrac, forKey: "yFrac")
            root.layer?.addSublayer(star)
            starLayers.append(star)
        }

        // Sun (light) / moon (dark) - same xFrac/yFrac positioning convention
        // as the stars above. `moonBiteLayer` is a same-coloured disc offset
        // over it, punching the crescent out against the sky; it is filled with
        // the sky's own top colour in `applyTheme`, so it reads as absence
        // rather than as a second object.
        sunLayer.cornerRadius = 44
        sunLayer.frame = NSRect(x: 0, y: 0, width: 88, height: 88)
        sunLayer.shadowOpacity = 0.75
        sunLayer.shadowRadius = 28
        sunLayer.shadowOffset = .zero
        sunLayer.setValue(CGFloat(0.78), forKey: "xFrac")
        sunLayer.setValue(CGFloat(0.82), forKey: "yFrac")
        moonBiteLayer.cornerRadius = 36
        moonBiteLayer.frame = NSRect(x: 26, y: 18, width: 72, height: 72)
        sunLayer.addSublayer(moonBiteLayer)
        root.layer?.addSublayer(sunLayer)

        // Wave: a smooth swell near the bottom, drawn twice as wide as the
        // view and drifted horizontally in a seamless loop. Two layers - the
        // paler one behind - because a single wedge does not read as water.
        // H4: each swell is now a gradient masked by its own shape, so the
        // sea has depth rather than a flat band. The shape layers still carry
        // the drift; only what fills them changed.
        for (gradient, mask) in [(backSeaGradient, backWaveLayer), (seaGradient, waveLayer)] {
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.mask = mask
            root.layer?.addSublayer(gradient)
        }

        // L-2: the Going Merry, at the board's 80% (about 110pt). Its image is
        // drawn per theme in `applyTheme`, darkened for dusk and night.
        boatImageView.imageScaling = .scaleProportionallyUpOrDown
        boatImageView.setAccessibilityLabel("Going Merry")
        boatImageView.wantsLayer = true
        boatImageView.translatesAutoresizingMaskIntoConstraints = false
        boatImageView.widthAnchor.constraint(equalToConstant: 110).isActive = true
        boatImageView.heightAnchor.constraint(equalToConstant: 96).isActive = true

        // L-2: day breaking over the dusk on unlock, and the lighthouse
        // between the back swell and the front one.
        daySkyLayer.locations = [0, 0.55, 1]
        daySkyLayer.startPoint = CGPoint(x: 0.5, y: 1)
        daySkyLayer.endPoint = CGPoint(x: 0.5, y: 0)
        daySkyLayer.opacity = 0
        root.layer?.insertSublayer(daySkyLayer, above: skyLayer)
        daySunLayer.cornerRadius = 44
        daySunLayer.frame = NSRect(x: 0, y: 0, width: 88, height: 88)
        daySunLayer.shadowOpacity = 0.75
        daySunLayer.shadowRadius = 28
        daySunLayer.shadowOffset = .zero
        daySunLayer.opacity = 0
        daySunLayer.setValue(CGFloat(0.78), forKey: "xFrac")
        daySunLayer.setValue(CGFloat(0.82), forKey: "yFrac")
        root.layer?.insertSublayer(daySunLayer, above: sunLayer)
        if let rootLayer = root.layer {
            lighthouse.install(in: rootLayer, aboveBackSea: backSeaGradient, belowFrontSea: seaGradient)
        }
    }

    private func buildCard() {
        // Outer: shadow only, never clipped (§2.5).
        cardShadowHost.wantsLayer = true
        cardShadowHost.layer?.masksToBounds = false
        cardShadowHost.translatesAutoresizingMaskIntoConstraints = false

        // Inner: fill, border, radius - and it clips, which is why the shadow
        // cannot live here.
        card.wantsLayer = true
        card.layer?.masksToBounds = true
        card.layer?.cornerRadius = HelmMetrics.dModule
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        cardShadowHost.addSubview(card)

        ribbonView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(ribbonView)

        markTile.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = HelmType.rounded(HelmType.scaled(20), .heavy)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = HelmType.body()
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // The app's one secure input. It brings the §6.9 well (inset fill,
        // radius `dWell`, `muted` placeholder) plus Phase 0's first-responder
        // focus ring and themed selection with it - none of which the
        // hand-rolled pill this replaces had.
        passwordField.target = self
        passwordField.action = #selector(submitTapped)

        unlockButton.target = self
        unlockButton.action = #selector(submitTapped)
        unlockButton.keyEquivalent = "\r"
        unlockButton.translatesAutoresizingMaskIntoConstraints = false

        formStack.orientation = .vertical
        formStack.alignment = .centerX
        formStack.spacing = HelmMetrics.s3
        formStack.translatesAutoresizingMaskIntoConstraints = false
        // H4: "the unlock field given the composer-card focus glow". A sunken
        // well clips, and a clipped layer casts no shadow outside its bounds -
        // so the glow needs an un-clipped host around the field. The same
        // two-layer arrangement `HelmComposerCard` documented first.
        passwordWell.translatesAutoresizingMaskIntoConstraints = false
        passwordWell.addSubview(passwordField)
        NSLayoutConstraint.activate([
            passwordField.leadingAnchor.constraint(equalTo: passwordWell.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: passwordWell.trailingAnchor),
            passwordField.topAnchor.constraint(equalTo: passwordWell.topAnchor),
            passwordField.bottomAnchor.constraint(equalTo: passwordWell.bottomAnchor),
        ])
        passwordField.glowHost = passwordWell
        // C-4: the arrow inside the pill, shown on `.locked` only.
        arrowButton.target = self
        arrowButton.action = #selector(submitTapped)
        arrowButton.isHidden = true
        passwordWell.addSubview(arrowButton)
        NSLayoutConstraint.activate([
            arrowButton.trailingAnchor.constraint(equalTo: passwordWell.trailingAnchor, constant: -4),
            arrowButton.centerYAnchor.constraint(equalTo: passwordWell.centerYAnchor),
        ])
        formStack.addArrangedSubview(passwordWell)
        formStack.addArrangedSubview(unlockButton)

        errorLabel.font = HelmType.caption()
        errorLabel.alignment = .center
        errorLabel.maximumNumberOfLines = 2
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true

        messageLabel.font = HelmType.body()
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 5
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isHidden = true

        setupCommandLabel.font = HelmType.code()
        setupCommandLabel.isSelectable = true
        setupCommandLabel.lineBreakMode = .byTruncatingMiddle
        setupCommandLabel.translatesAutoresizingMaskIntoConstraints = false
        setupCommandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyCommandButton.target = self
        copyCommandButton.action = #selector(copySetupCommandTapped)
        copyCommandButton.setContentHuggingPriority(.required, for: .horizontal)
        copyCommandButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // A code well, not a bespoke tinted box: `HelmField.makeSunken` is the
        // one sunken recipe, and `applySunken` recolours it per theme.
        HelmField.makeSunken(setupCommandStack)
        setupCommandStack.orientation = .horizontal
        setupCommandStack.alignment = .centerY
        setupCommandStack.spacing = HelmMetrics.s2
        setupCommandStack.distribution = .fill
        setupCommandStack.edgeInsets = NSEdgeInsets(top: 8, left: 13, bottom: 8, right: 9)
        setupCommandStack.translatesAutoresizingMaskIntoConstraints = false
        setupCommandStack.addArrangedSubview(setupCommandLabel)
        setupCommandStack.addArrangedSubview(copyCommandButton)
        setupCommandStack.isHidden = true

        avMessageLabel.font = HelmType.body()
        avMessageLabel.alignment = .center
        avMessageLabel.maximumNumberOfLines = 6
        avMessageLabel.translatesAutoresizingMaskIntoConstraints = false



        avUnavailableStack.orientation = .vertical
        avUnavailableStack.alignment = .centerX
        avUnavailableStack.spacing = HelmMetrics.s3
        avUnavailableStack.translatesAutoresizingMaskIntoConstraints = false
        avUnavailableStack.addArrangedSubview(avMessageLabel)
        avUnavailableStack.isHidden = true

        checkAgainButton.target = self
        checkAgainButton.action = #selector(checkAgainTapped)
        checkAgainButton.translatesAutoresizingMaskIntoConstraints = false
        checkAgainButton.isHidden = true

        waitingLabel.font = HelmType.caption()
        waitingLabel.translatesAutoresizingMaskIntoConstraints = false
        waitingStack.orientation = .horizontal
        waitingStack.alignment = .centerY
        waitingStack.spacing = HelmMetrics.s2
        waitingStack.translatesAutoresizingMaskIntoConstraints = false
        waitingGlyph.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        waitingGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: HelmType.scaled(12), weight: .regular)
        waitingGlyph.translatesAutoresizingMaskIntoConstraints = false
        waitingStack.addArrangedSubview(waitingGlyph)
        waitingStack.addArrangedSubview(waitingLabel)
        waitingStack.isHidden = true

        // X1: the escape from the retry loop.
        localAuthButton.target = self
        localAuthButton.action = #selector(localAuthTapped)
        localAuthButton.translatesAutoresizingMaskIntoConstraints = false
        localAuthNote.font = HelmType.caption()
        localAuthNote.alignment = .center
        localAuthNote.preferredMaxLayoutWidth = 320
        localAuthNote.translatesAutoresizingMaskIntoConstraints = false
        localAuthStack.orientation = .vertical
        localAuthStack.alignment = .centerX
        localAuthStack.spacing = HelmMetrics.s2
        localAuthStack.translatesAutoresizingMaskIntoConstraints = false
        localAuthStack.addArrangedSubview(localAuthNote)
        localAuthStack.addArrangedSubview(localAuthButton)
        localAuthStack.isHidden = true

        footerDivider.wantsLayer = true
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footerDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        footerLeftLabel.font = HelmType.caption()
        footerRightLabel.font = HelmType.code()
        footerLeftLabel.translatesAutoresizingMaskIntoConstraints = false
        footerRightLabel.translatesAutoresizingMaskIntoConstraints = false
        footerRightLabel.setContentHuggingPriority(.required, for: .horizontal)
        let footerRow = NSStackView(views: [footerLeftLabel, footerRightLabel])
        footerRow.orientation = .horizontal
        footerRow.distribution = .fill
        footerRow.alignment = .centerY
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerLeftLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = HelmMetrics.s3
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.addArrangedSubview(footerDivider)
        footerStack.addArrangedSubview(footerRow)

        avatar.isHidden = true
        let body = NSStackView(views: [
            markTile, avatar, titleLabel, subtitleLabel, formStack, errorLabel,
            messageLabel, setupCommandStack, avUnavailableStack, checkAgainButton, waitingStack, localAuthStack,
            footerStack,
        ])
        body.orientation = .vertical
        body.alignment = .centerX
        body.spacing = HelmMetrics.s4
        body.setCustomSpacing(HelmMetrics.s2, after: titleLabel)
        body.setCustomSpacing(HelmMetrics.s5, after: subtitleLabel)
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)

        let pad = Self.cardPadding
        NSLayoutConstraint.activate([
            cardShadowHost.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            card.leadingAnchor.constraint(equalTo: cardShadowHost.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: cardShadowHost.trailingAnchor),
            card.topAnchor.constraint(equalTo: cardShadowHost.topAnchor),
            card.bottomAnchor.constraint(equalTo: cardShadowHost.bottomAnchor),

            ribbonView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            ribbonView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            ribbonView.topAnchor.constraint(equalTo: card.topAnchor),
            ribbonView.heightAnchor.constraint(equalToConstant: Self.ribbonHeight),

            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            body.topAnchor.constraint(equalTo: ribbonView.bottomAnchor, constant: pad),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),

            // Everything that can wrap is pinned to the body's own width, so a
            // long message grows the card downward rather than sideways.
            subtitleLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            avMessageLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            passwordWell.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            unlockButton.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            setupCommandStack.widthAnchor.constraint(equalTo: body.widthAnchor),
            avUnavailableStack.widthAnchor.constraint(equalTo: body.widthAnchor),
            checkAgainButton.widthAnchor.constraint(equalTo: body.widthAnchor),
            footerStack.widthAnchor.constraint(equalTo: body.widthAnchor),
            footerDivider.widthAnchor.constraint(equalTo: footerStack.widthAnchor),
        ])
        // The form fills the card, except as C-4's 250pt pill on the scene.
        formFullWidth = formStack.widthAnchor.constraint(equalTo: body.widthAnchor)
        formOpenWidth = formStack.widthAnchor.constraint(equalToConstant: 250)
        formFullWidth?.isActive = true
    }

    // MARK: - Theme

    /// Every colour on this screen, resolved from `theme` alone.
    ///
    /// Deliberately theme-derived rather than register-branched: the 12
    /// pre-Daylight palettes are still selectable (§2.8 keeps
    /// `HelmTheme.allThemes` intact until Dusk can replace them all), so a
    /// captain on `gruvbox-light` has to get a legible gate too. The card,
    /// well, buttons and type all resolve through the shared components, which
    /// already branch internally; only the *scene* needs its own resolution,
    /// and it builds from `HelmDomainHue` pairs (which fall back to the
    /// theme's own `HelmTint` slots off Daylight) over the theme's own ground.
    private struct SceneColors {
        let skyTop: NSColor
        let skyMid: NSColor
        let ground: NSColor
        let wave: NSColor
        let backWave: NSColor
        let boat: NSColor
        let celestial: NSColor
        let celestialGlow: NSColor
        let star: NSColor
        let isDarkRegister: Bool
        /// L-2: the lighthouse, its beam and the fog.
        let lighthouse: LockLighthouseScene.Palette
        /// How much the Going Merry is darkened for this light.
        let boatDim: CGFloat
        /// L-2, light register: today's day sky, which breaks over the dusk on unlock.
        let day: DayColors?
    }

    private struct DayColors {
        let skyTop: NSColor
        let skyMid: NSColor
        let ground: NSColor
        let wave: NSColor
        let backWave: NSColor
        let sun: NSColor
        let sunGlow: NSColor
    }

    /// `a` moved toward `b` by `t` (0 keeps `a`), in straight sRGB.
    private static func toward(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        blend(b, into: a, fraction: Double(t))
    }

    /// A straight sRGB mix of `hue` into `ground`.
    ///
    /// `HelmContrast.mix`, never `NSColor.blended(withFraction:of:)`: that one
    /// converts both operands into a *calibrated* space first, so its result
    /// drifts from the straight-sRGB composite alpha compositing actually
    /// performs - a lesson this codebase has already recorded twice (the
    /// segmented-tabs correction and the §6.5 signal wash).
    private static func blend(_ hue: NSColor, into ground: NSColor, fraction: Double) -> NSColor {
        HelmContrast.color(HelmContrast.mix(HelmContrast.components(hue),
                                            HelmContrast.components(ground),
                                            fraction))
    }

    private func sceneColors(for theme: HelmTheme) -> SceneColors {
        let ground = HelmTheme.nsColor(theme.backgroundHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let light = HelmField.sceneLight(theme)
        let sea = HelmDomainHue.teal.pair(in: theme)
        let sky = HelmDomainHue.blue.pair(in: theme)
        let amber = HelmDomainHue.amber.pair(in: theme)
        let isDark = theme.mode == .dark
        // The lamp's warm light, shared by the beam, the halo and the glass.
        let warm = Self.toward(amber.h2, light, 0.3)
        let warmLight = Self.toward(amber.h2, light, 0.62)

        if isDark {
            // Night harbour: a deep sky reading down into the theme's own
            // ground, a cool moon, and a sea that all but dissolves into the
            // horizon. Every value is a blend of real tokens - there is no
            // second hand-tuned palette here, which is the whole point.
            let skyTop = Self.blend(sky.h1, into: ground, fraction: 0.34)
            let rock = Self.toward(ground, ink, 0.06)
            let iron = Self.toward(ground, ink, 0.25)
            let tower = Self.toward(ink, ground, 0.22)
            return SceneColors(
                skyTop: skyTop,
                skyMid: Self.blend(sky.h1, into: ground, fraction: 0.11),
                ground: ground,
                wave: Self.blend(sea.h1, into: ground, fraction: 0.5),
                backWave: Self.blend(sea.h1, into: ground, fraction: 0.28),
                boat: ink,
                celestial: sky.h2,
                celestialGlow: sky.h2.withAlphaComponent(0.35),
                star: ink.withAlphaComponent(0.85),
                isDarkRegister: true,
                lighthouse: LockLighthouseScene.Palette(
                    art: LighthouseArt.Palette(rock: rock, rockEdge: light.withAlphaComponent(0.05), tower: tower,
                                               towerLine: Self.toward(tower, ground, 0.35),
                                               band: Self.toward(sky.h1, ground, 0.35), iron: iron,
                                               darkGlass: Self.toward(iron, tower, 0.3)),
                    warm: warm, warmLight: warmLight, fog: Self.toward(ground, ink, 0.2)),
                boatDim: 0.26,
                day: nil
            )
        }
        // The day this dusk breaks into: today's Daylight harbour, a soft blue
        // zenith fading into the theme's own warm paper, an amber sun and a
        // turquoise sea.
        let day = DayColors(
            skyTop: Self.blend(sky.h2, into: ground, fraction: 0.46),
            skyMid: Self.blend(sky.h2, into: ground, fraction: 0.13),
            ground: ground,
            wave: Self.blend(sea.h1, into: ground, fraction: 0.5),
            backWave: Self.blend(sea.h2, into: ground, fraction: 0.3),
            sun: amber.h2,
            sunGlow: amber.h1.withAlphaComponent(0.4))
        // L-2's blue hour: that same day taken toward the theme's ink.
        let skyTop = Self.toward(day.skyTop, ink, 0.83)
        let skyMid = Self.toward(day.skyMid, ink, 0.66)
        let iron = Self.toward(ground, ink, 0.88)
        let tower = Self.toward(light, skyMid, 0.2)
        return SceneColors(
            skyTop: skyTop,
            skyMid: skyMid,
            ground: Self.toward(ground, ink, 0.45),
            wave: Self.toward(day.wave, ink, 0.5),
            backWave: Self.toward(day.backWave, ink, 0.42),
            boat: Self.blend(sea.h1, into: ink, fraction: 0.55),
            // A setting sun: the theme's amber pulled toward its red.
            celestial: Self.toward(amber.h1, HelmTheme.nsColor(theme.ansiHex[1]), 0.32),
            celestialGlow: Self.toward(amber.h1, HelmTheme.nsColor(theme.ansiHex[1]), 0.4).withAlphaComponent(0.34),
            star: .clear,
            isDarkRegister: false,
            lighthouse: LockLighthouseScene.Palette(
                art: LighthouseArt.Palette(rock: Self.toward(skyTop, ink, 0.4), rockEdge: light.withAlphaComponent(0.07),
                                           tower: tower, towerLine: Self.toward(tower, skyMid, 0.45),
                                           band: sky.h1, iron: iron, darkGlass: Self.toward(iron, tower, 0.3)),
                warm: warm, warmLight: warmLight, fog: Self.toward(light, skyMid, 0.28)),
            boatDim: 0.16,
            day: day
        )
    }

    private func applyTheme(_ theme: HelmTheme) {
        let scene = sceneColors(for: theme)
        currentScene = scene
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)

        // Scene. Implicit CALayer animation is off for every one of these:
        // a standalone sublayer's property change animates by default (Phase 6
        // measured this on the gradient tiles), which would cross-fade the
        // whole sky on a theme switch - motion nobody designed.
        HelmMotion.withoutImplicitAnimation {
            view.layer?.backgroundColor = scene.ground.cgColor
            skyLayer.colors = [scene.skyTop, scene.skyMid, scene.ground].map(\.cgColor)
            // A mask's own colour is irrelevant - only its alpha is read -
            // so the fill has to be opaque or the gradient shows through
            // nothing at all.
            waveLayer.fillColor = NSColor.black.cgColor
            backWaveLayer.fillColor = NSColor.black.cgColor
            // H4's sea gradient: the wave's own colour at the crest, deepening
            // toward the bottom of the screen. `ground` is where the sky
            // already ends, so blending toward it is what keeps the sea
            // reading as one body of water rather than a pasted band.
            seaGradient.colors = [scene.wave,
                                  Self.blend(scene.wave, into: scene.ground, fraction: 0.45)]
                .map(\.cgColor)
            backSeaGradient.colors = [scene.backWave,
                                      Self.blend(scene.backWave, into: scene.ground, fraction: 0.45)]
                .map(\.cgColor)
            sunLayer.backgroundColor = scene.celestial.cgColor
            sunLayer.shadowColor = scene.celestialGlow.cgColor
            moonBiteLayer.backgroundColor = scene.skyTop.cgColor
            moonBiteLayer.isHidden = !scene.isDarkRegister
            // L-2: by dusk the sun is setting on the left horizon; at night
            // the moon keeps its place.
            sunLayer.setValue(CGFloat(scene.isDarkRegister ? 0.78 : 0.19), forKey: "xFrac")
            sunLayer.setValue(scene.isDarkRegister ? nil : CGFloat(124), forKey: "yPts")
            if let day = scene.day {
                daySkyLayer.colors = [day.skyTop, day.skyMid, day.ground].map(\.cgColor)
                daySunLayer.backgroundColor = day.sun.cgColor
                daySunLayer.shadowColor = day.sunGlow.cgColor
            }
            for star in starLayers {
                star.backgroundColor = scene.star.cgColor
                star.isHidden = !scene.isDarkRegister
            }
        }
        boatImageView.image = GoingMerryArt.image(size: NSSize(width: 110, height: 96), dim: scene.boatDim)
        lighthouse.applyPalette(scene.lighthouse)

        // Card chrome. `applyCardSurface` is the app's one card fill/border, so
        // this gate cannot drift from the sheets it is meant to match; the
        // shadow is `HelmCard.elevation(.raised)`, §6.10's own level.
        HelmCard.applyCardSurface(to: card, theme: theme, cornerRadius: HelmMetrics.dModule)
        HelmMotion.withoutImplicitAnimation {
            if let host = cardShadowHost.layer {
                HelmCard.applyElevation(.raised, to: host, theme: theme, path: host.shadowPath)
            }
        }
        applyRibbon(theme: theme)
        markTile.configure(symbol: currentSymbol, hue: currentHue)

        titleLabel.textColor = ink
        subtitleLabel.textColor = muted
        messageLabel.textColor = muted
        avMessageLabel.textColor = muted
        waitingLabel.textColor = muted
        waitingGlyph.contentTintColor = muted
        localAuthNote.textColor = muted
        footerLeftLabel.textColor = muted
        footerRightLabel.textColor = muted
        setupCommandLabel.textColor = HelmField.ink(theme)
        footerDivider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor

        // §2.4: a raw semantic hue used as its own label fails the text floor.
        // `legible` is what turns `bad` into #BC4142 on Daylight's card and
        // #E07272 on Dusk's, and does the equivalent on the other eleven.
        errorLabel.textColor = HelmContrast.legible(
            HelmTheme.nsColor(theme.ansiHex[1]),
            over: HelmTheme.nsColor(theme.chromeBackgroundHex)
        )

        HelmField.applySunken(to: setupCommandStack, theme: theme)
        passwordField.applyTheme(theme)
        // The well's focus ring takes this state's hue, per §6.9.
        passwordField.domainHue = currentHue
        // A `HelmButton`'s `domainHue` re-points its `.primary` fill on every
        // theme, so it is set here (from the state) rather than at construction -
        // and the corrected fill is `DaylightPalette.primaryButtonFill`'s job,
        // not a literal: white on the raw amber measures 3.27:1.
        unlockButton.domainHue = currentHue
        applyOpenStyle(theme, scene: scene)
        applyLayerGeometry()
    }

    /// C-4 Open sea for `.locked`: no card surface, a round avatar, the
    /// password as a pill on the scene, and light type that reads on the dusk.
    /// Every other state keeps the card exactly as `applyCardSurface` drew it.
    private func applyOpenStyle(_ theme: HelmTheme, scene: SceneColors) {
        let open = openStyle
        markTile.isHidden = open
        avatar.isHidden = !open
        ribbonView.isHidden = open
        unlockButton.isHidden = open
        arrowButton.isHidden = !open
        if open { footerStack.isHidden = true }
        formFullWidth?.isActive = !open
        formOpenWidth?.isActive = open
        passwordField.wellSurface = open ? .scene(onDark: true) : .inset
        passwordField.trailingAccessoryWidth = open ? 30 : 0
        passwordField.applyTheme(theme)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = HelmTheme.nsColor(theme.mode == .dark ? theme.backgroundHex : theme.chromeInkHex).withAlphaComponent(0.6)
        titleLabel.shadow = open ? shadow : nil
        subtitleLabel.shadow = open ? shadow : nil
        guard open else { return }
        let light = HelmField.sceneLight(theme)
        HelmMotion.withoutImplicitAnimation {
            card.layer?.backgroundColor = NSColor.clear.cgColor
            card.layer?.borderWidth = 0
            cardShadowHost.layer?.shadowOpacity = 0
        }
        titleLabel.textColor = light
        subtitleLabel.textColor = light.withAlphaComponent(0.84)
        // The theme's red, lifted toward the scene's light, and then as far
        // as the text floor needs against the sky the form floats on. The
        // light register's blue hour is a mid tone, where the plain lift
        // measured 2.24:1 (`LockScreenSelfTest.checkCorrectedContrast`).
        errorLabel.textColor = HelmContrast.legible(Self.toward(HelmTheme.nsColor(theme.ansiHex[1]), light, 0.45),
                                                    over: scene.skyMid)
        avatar.configure(theme: theme, hue: currentHue)
        arrowButton.style = .circle(side: 26, fill: light.withAlphaComponent(0.92), glyph: scene.skyTop, border: nil)
    }

    private func applyRibbon(theme: HelmTheme) {
        let pair = currentHue.pair(in: theme)
        HelmMotion.withoutImplicitAnimation {
            ribbonLayer.colors = [pair.h1.cgColor, pair.h2.cgColor]
            ribbonLayer.startPoint = HelmDomainHue.ribbonStart
            ribbonLayer.endPoint = HelmDomainHue.ribbonEnd
        }
    }

    // MARK: - Layout

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutSceneLayers()
        applyLayerGeometry()
    }

    /// Frames for the layers Auto Layout does not own. Kept out of
    /// `layoutSceneLayers` so `applyTheme` can call it too - a theme change can
    /// alter a shadow's radius, and `shadowPath` has to be resynced with it.
    private func applyLayerGeometry() {
        HelmMotion.withoutImplicitAnimation {
            ribbonLayer.frame = ribbonView.bounds
            let cardBounds = cardShadowHost.bounds
            if cardBounds.width > 0, cardBounds.height > 0 {
                cardShadowHost.layer?.shadowPath = CGPath(
                    roundedRect: cardBounds,
                    cornerWidth: HelmMetrics.dModule,
                    cornerHeight: HelmMetrics.dModule,
                    transform: nil
                )
            }
        }
    }

    private func layoutSceneLayers() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        HelmMotion.withoutImplicitAnimation {
            skyLayer.frame = bounds

            daySkyLayer.frame = bounds
            for layer in view.layer?.sublayers ?? [] where layer.value(forKey: "xFrac") != nil {
                let xFrac = layer.value(forKey: "xFrac") as? CGFloat ?? 0
                let yFrac = layer.value(forKey: "yFrac") as? CGFloat ?? 0
                let size = layer.bounds.width
                // `yPts` pins a layer to the horizon instead (L-2's setting sun).
                let y = (layer.value(forKey: "yPts") as? CGFloat) ?? bounds.height * yFrac
                layer.position = CGPoint(x: bounds.width * xFrac, y: y)
                layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            }
        }

        lighthouse.layout(bounds: bounds)
        lighthouseHotspot.frame = lighthouse.hotspot

        waveWidth = bounds.width * 2
        HelmMotion.withoutImplicitAnimation {
            // The gradient hosts span the view; the swell shapes drift inside
            // them as masks, which is what keeps the parallax working.
            seaGradient.frame = bounds
            backSeaGradient.frame = bounds
            waveLayer.path = Self.swellPath(width: waveWidth, height: 96, crest: 18)
            waveLayer.bounds = CGRect(x: 0, y: 0, width: waveWidth, height: 96)
            waveLayer.position = .zero
            waveLayer.anchorPoint = .zero
            backWaveLayer.path = Self.swellPath(width: waveWidth, height: 128, crest: 13)
            backWaveLayer.bounds = CGRect(x: 0, y: 0, width: waveWidth, height: 128)
            backWaveLayer.position = .zero
            backWaveLayer.anchorPoint = .zero
        }

        startAnimationsIfNeeded()
    }

    /// A smooth, seamlessly-tiling swell: four quadratic arcs across `width`,
    /// oscillating `crest` points either side of `height`.
    ///
    /// Deliberately curves rather than the straight-line zigzag this file used
    /// to draw - at the sea's real on-screen size that read as a row of
    /// triangles, which the old near-black night palette hid and Daylight's
    /// pale one does not.
    private static func swellPath(width: CGFloat, height: CGFloat, crest: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: height))
        let arcs = 4
        let arcWidth = width / CGFloat(arcs)
        for i in 0..<arcs {
            let startX = CGFloat(i) * arcWidth
            let controlY = height + (i % 2 == 0 ? crest : -crest)
            path.addQuadCurve(to: CGPoint(x: startX + arcWidth, y: height),
                              control: CGPoint(x: startX + arcWidth / 2, y: controlY))
        }
        path.addLine(to: CGPoint(x: width, y: 0))
        path.closeSubpath()
        return path
    }

    private var animationsStarted = false
    private var reduceMotionObserver: NSObjectProtocol?

    /// GL-16: the two animations below (the boat's bob and the wave's drift)
    /// loop forever, and this screen is *mandatory* - a captain who has turned
    /// on Reduce Motion cannot dismiss it or navigate away from it, so ignoring
    /// that setting here is worse than anywhere else in the app. Both are
    /// purely decorative: with them off the scene renders as a still
    /// illustration and every function of the screen (typing a password,
    /// submitting, reading the state text) is unchanged.
    ///
    /// The failure shake and the success sail-away are deliberately left
    /// alone: they are brief, non-looping, and the success one carries the
    /// `CATransaction` completion block that actually unlocks the app - a
    /// change there risks a state where the password is accepted and the
    /// overlay never lifts.
    private static var prefersReducedMotion: Bool {
        HelmMotion.isReduced
    }

    /// E4 (`data/grand-line-e2e-audit/report.md`): stop the looping
    /// decoration, called from `AppShellController.hideLock` on unlock.
    ///
    /// The three infinite animations used to be added exactly once and never
    /// removed - `animationsStarted` latched true and only a Reduce Motion
    /// toggle could take them off - so after the first unlock they stayed
    /// attached to hidden layers for the rest of the session, costing
    /// render-server bookkeeping forever for something nobody can see. And
    /// while the app *is* locked with the display awake (a Mac left locked
    /// overnight), the scene composites continuously by design; that half is
    /// the lock screen's job, but it must end the moment the overlay does.
    ///
    /// Clearing the latch is what makes `startAnimationsIfNeeded()` honest:
    /// the next `showLock` genuinely restarts them, rather than relying on
    /// animations that happened to still be attached.
    func stopAnimations() {
        removeKeyMonitor()
        lighthouse.stopAll()
        guard animationsStarted else { return }
        animationsStarted = false
        boatImageView.layer?.removeAnimation(forKey: "bob")
        waveLayer.removeAnimation(forKey: "drift")
        backWaveLayer.removeAnimation(forKey: "drift")
    }

    /// E4: re-add them when the scene comes back up. `viewDidLayout` also
    /// calls `startAnimationsIfNeeded()`, but a re-lock does not necessarily
    /// re-lay-out an already-sized overlay, so `showLock` says so explicitly.
    func restartAnimationsIfNeeded() {
        installKeyMonitor()
        startAnimationsIfNeeded()
    }

    private func startAnimationsIfNeeded() {
        // H2: `viewDidLayout` calls this unconditionally, and the lock view is
        // permanently mounted and merely hidden after an unlock - a hidden
        // `NSView` still participates fully in layout (gotcha 11). Once E4
        // started clearing the `animationsStarted` latch on unlock, the first
        // window resize afterwards re-attached all three infinite animations to
        // hidden layers for the rest of the session, undoing exactly the
        // render-server cost E4 removed. `showLock` unhides the view before it
        // calls `restartAnimationsIfNeeded()`, so the visible path is unaffected.
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        guard !animationsStarted, waveWidth > 0 else { return }
        animationsStarted = true

        // Observe live changes so toggling Reduce Motion while the lock screen
        // is up takes effect, rather than only on the next launch.
        if reduceMotionObserver == nil {
            // P7: on `NSWorkspace`'s notification center, which is where
            // macOS posts this - registered on the default center it never
            // fired.
            reduceMotionObserver = HelmDisplayAccessibility.observeChanges { [weak self] in
                self?.applyMotionPreference()
            }
        }

        installKeyMonitor()
        guard !Self.prefersReducedMotion else { return }
        addLoopingAnimations()
    }

    /// Adds or removes the looping decoration to match the current setting.
    private func applyMotionPreference() {
        if Self.prefersReducedMotion {
            boatImageView.layer?.removeAnimation(forKey: "bob")
            waveLayer.removeAnimation(forKey: "drift")
            backWaveLayer.removeAnimation(forKey: "drift")
            lighthouse.stopAll()
            if isLit { lighthouse.showLit(reducedMotion: true) }
        } else if animationsStarted, boatImageView.layer?.animation(forKey: "bob") == nil {
            addLoopingAnimations()
            if isLit { lighthouse.showLit(reducedMotion: false) }
        }
    }

    private func addLoopingAnimations() {
        let bob = CAKeyframeAnimation(keyPath: "transform")
        var transforms: [CATransform3D] = []
        for step in 0...8 {
            let t = CGFloat(step) / 8
            let offset = sin(t * .pi * 2) * 6
            let rotation = sin(t * .pi * 2) * 0.03
            var transform = CATransform3DMakeTranslation(0, offset, 0)
            transform = CATransform3DRotate(transform, rotation, 0, 0, 1)
            transforms.append(transform)
        }
        bob.values = transforms
        bob.duration = 3.4
        bob.repeatCount = .infinity
        bob.calculationMode = .cubic
        boatImageView.layer?.add(bob, forKey: "bob")

        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = 0
        drift.toValue = -(waveWidth / 2)
        drift.duration = 14
        drift.repeatCount = .infinity
        drift.isRemovedOnCompletion = false
        drift.fillMode = .forwards
        waveLayer.add(drift, forKey: "drift")

        let backDrift = CABasicAnimation(keyPath: "position.x")
        backDrift.fromValue = 0
        backDrift.toValue = -(waveWidth / 2)
        backDrift.duration = 22
        backDrift.repeatCount = .infinity
        backDrift.isRemovedOnCompletion = false
        backDrift.fillMode = .forwards
        backWaveLayer.add(backDrift, forKey: "drift")

        lighthouse.startDrift(reducedMotion: false)
    }

    #if FM_SELFTESTS
    struct DebugSceneLayers {
        let skyStops: Int
        let seaStops: Int
        let backSeaStops: Int
        let celestialGlowRadius: CGFloat
        let driftDurations: [Double]
    }

    /// The scene read off its real layers after a real layout pass.
    var debugSceneLayers: DebugSceneLayers {
        DebugSceneLayers(
            skyStops: (skyLayer.colors as? [CGColor])?.count ?? 0,
            seaStops: (seaGradient.colors as? [CGColor])?.count ?? 0,
            backSeaStops: (backSeaGradient.colors as? [CGColor])?.count ?? 0,
            celestialGlowRadius: sunLayer.shadowOpacity > 0 ? sunLayer.shadowRadius : 0,
            driftDurations: [waveLayer, backWaveLayer]
                .compactMap { $0.animation(forKey: "drift")?.duration })
    }

    var debugPasswordFieldHasGlowHost: Bool { passwordField.glowHost != nil }

    /// Review defect U17: what the empty password field actually shows.
    /// Read off the control so a check cannot pass against a constant that
    /// is no longer the one the field was built with.
    /// `SunkenFieldTheming` writes a `placeholderAttributedString` (it has
    /// to, to carry the theme's muted ink), which leaves `placeholderString`
    /// nil - so a check reading only the plain property would see "no
    /// placeholder" whatever the field shows.
    var debugPasswordPlaceholder: String {
        passwordField.placeholderAttributedString?.string ?? passwordField.placeholderString ?? ""
    }
    #endif

    deinit {
        if let reduceMotionObserver {
            HelmDisplayAccessibility.stopObserving(reduceMotionObserver)
        }
    }

    // MARK: - Content

    /// R2-UX-01 (c): "Welcome back, Manjesh" was the captain's own words,
    /// and on anyone else's Mac it named the wrong person. The name is the
    /// first word of this Mac account's full name - Manjesh, on the captain's
    /// - and a Mac with no full name gets the greeting without one.
    static func greeting(fullName: String = NSFullUserName()) -> String {
        let first = fullName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Welcome back" : "Welcome back, \(first)"
    }

    func apply(_ state: ContentState) {
        currentHue = state.hue
        currentSymbol = state.symbol
        if case .locked = state { openStyle = true } else { openStyle = false }
        resetFlourish()

        // Defaults: every state below turns on only what it needs.
        formStack.isHidden = true
        errorLabel.isHidden = true
        messageLabel.isHidden = true
        setupCommandStack.isHidden = true
        avUnavailableStack.isHidden = true
        checkAgainButton.isHidden = true
        waitingStack.isHidden = true
        localAuthStack.isHidden = true
        localAuthButton.isEnabled = true
        footerLeftLabel.stringValue = ""
        footerRightLabel.stringValue = ""

        switch state {
        case .locked(let subtitle):
            titleLabel.stringValue = Self.greeting()
            subtitleLabel.stringValue = subtitle
            formStack.isHidden = false
            passwordField.stringValue = ""
            passwordField.isEnabled = true
            unlockButton.isEnabled = true
            footerLeftLabel.stringValue = "Automic Vault"
            footerRightLabel.stringValue = "\u{21A9} to unlock"
            // This same controller instance is reused for every lock, so a
            // previous success animation's boat position/opacity needs
            // resetting - otherwise the *next* lock screen would show a
            // half-faded, sailed-off boat instead of the normal scene.
            boatImageView.layer?.removeAnimation(forKey: "sailAway")
            boatImageView.layer?.removeAnimation(forKey: "fadeAway")
            boatImageView.layer?.opacity = 1

        case .noPasswordConfigured:
            titleLabel.stringValue = "First run"
            // Vault-tab wording deliberately doesn't offer it as a first-setup
            // option here either - the Vault tab lives behind this same lock
            // screen, so it's only ever reachable to rotate an already-set
            // password, never to set the first one. See `setup-guide.md`.
            // GL-31: the command itself lives in the copyable well below, so
            // the prose can just say what to do with it.
            subtitleLabel.stringValue = "The app lock is on, and no app password is saved yet. Run this in a terminal (or set it from Automic Vault's own app), then choose Check again."
            showSetupCommand(VaultSource.appPasswordSetupCommand)
            checkAgainButton.isHidden = onCheckAgain == nil
            footerLeftLabel.stringValue = "The one screen where nothing else is reachable"

        case .avUnavailable:
            titleLabel.stringValue = "Automic Vault isn't installed"
            subtitleLabel.stringValue = "Grand Line keeps your app password in Automic Vault's keychain. Install it to continue."
            avUnavailableStack.isHidden = false
            avMessageLabel.stringValue = "Install it by running this in a terminal. Then set a password with \u{201c}\(VaultSource.appPasswordSetupCommand)\u{201d} (or Automic Vault's own app), and choose Check again."
            showSetupCommand(VaultSource.installCommand)
            checkAgainButton.isHidden = onCheckAgain == nil
            footerLeftLabel.stringValue = "Nothing is installed from this screen"

        // Neither waiting state retries on its own any more
        // (`fm/grand-line-vault-no-launch-prompt`): the check is `av list`,
        // and asking it again unprompted can put Automic Vault's approval
        // dialog back on screen. So the spinner stays still and Check again
        // is the way forward.
        case .serviceNotRunning:
            titleLabel.stringValue = "Waking Automic Vault"
            subtitleLabel.stringValue = "Its approval service isn't answering yet. This usually clears in a few seconds - then choose Check again."
            waitingStack.isHidden = false
            waitingLabel.stringValue = "Waiting for Automic Vault"
            checkAgainButton.isHidden = onCheckAgain == nil
            showLocalAuthIfAvailable()

        case .transientFailure:
            titleLabel.stringValue = "Couldn't reach the vault"
            subtitleLabel.stringValue = "Automic Vault didn't answer, or the request was denied. Your password is probably fine - choose Check again to ask once more."
            waitingStack.isHidden = false
            waitingLabel.stringValue = "Not checked again until you ask"
            checkAgainButton.isHidden = onCheckAgain == nil
            showLocalAuthIfAvailable()
        }

        // The footer only earns its divider when it has something to say.
        footerStack.isHidden = footerLeftLabel.stringValue.isEmpty && footerRightLabel.stringValue.isEmpty
        // Re-derive everything the hue drives for the state just applied.
        applyTheme(ThemeManager.shared.theme)
        // L-2: only `.locked` starts dark. The other states carry setup
        // commands, Check again and the Touch ID fallback, so they are lit.
        setLit(!openStyle || Self.startsLit)
    }

    /// Focuses the password field - called every time the overlay becomes
    /// visible so a captain can start typing immediately with no extra
    /// click, matching how every other sheet/form in this app auto-focuses
    /// its first field.
    func focusPasswordField() {
        view.window?.makeFirstResponder(passwordField)
    }

    @objc private func submitTapped() {
        let typed = passwordField.stringValue
        guard !typed.isEmpty, let onAttempt else { return }
        errorLabel.isHidden = true
        passwordField.isEnabled = false
        unlockButton.isEnabled = false
        arrowButton.isEnabled = false
        if !isLit { light(.key) }
        // The lens turns faster while Automic Vault checks.
        lighthouse.setTurnSpeed(2.2)
        onAttempt(typed) { [weak self] success in
            guard let self else { return }
            self.lighthouse.setTurnSpeed(1)
            if success {
                // Deliberately NOT re-enabling the field/button or hiding
                // the overlay here - `playUnlockSuccessAnimation` plays out
                // fully first, and `onUnlockAnimationFinished` (not this
                // callback) is what actually tells `AppShellController` to
                // hide the lock screen.
                self.playUnlockSuccessAnimation()
            } else {
                self.passwordField.isEnabled = true
                self.unlockButton.isEnabled = true
                self.arrowButton.isEnabled = true
                self.passwordField.stringValue = ""
                self.errorLabel.stringValue = "That password didn't match. Try again."
                self.errorLabel.isHidden = false
                self.playUnlockFailureAnimation()
                if !HelmMotion.isReduced { self.lighthouse.foghorn() }
                self.view.window?.makeFirstResponder(self.passwordField)
            }
        }
    }

    /// **UX issue X1.** The two states above are the retry loop the review
    /// got stuck in: Automic Vault is unreachable, the password check cannot
    /// run, and every other surface in the app is behind this screen. The
    /// backoff's own comment admitted it - "the lock screen has nothing else
    /// useful to show and the captain cannot get past it any other way".
    ///
    /// There is something else useful to show. macOS can authenticate the
    /// device owner without Automic Vault, and that is a real second door
    /// rather than a weaker one: Touch ID, or failing that the login
    /// password the Mac itself is protected by.
    ///
    /// **Shown only when the challenge can actually be answered.** A dead
    /// button on the one screen nothing else is reachable from is worse than
    /// no button, so a Mac that cannot authenticate its owner keeps the
    /// retry loop and this stays hidden.
    ///
    /// **Not offered on the other three states**, and that is the GL-09
    /// line: `.locked` has a working password field (no dead end to escape),
    /// and `.noPasswordConfigured`/`.avUnavailable` are setup instructions
    /// rather than failures - a machine that has never had an app password
    /// set must not be unlockable by anyone who can wake its screen, because
    /// there is no app-level secret to have known in the first place.
    private func showLocalAuthIfAvailable() {
        guard onLocalAuthAttempt != nil, localAuthAvailable() else { return }
        localAuthStack.isHidden = false
    }

    @objc private func localAuthTapped() {
        guard let onLocalAuthAttempt else { return }
        errorLabel.isHidden = true
        localAuthButton.isEnabled = false
        onLocalAuthAttempt { [weak self] success in
            guard let self else { return }
            if success {
                // The same path a correct password takes - the animation
                // plays out and `onUnlockAnimationFinished` is what lifts
                // the overlay, never this callback (see `submitTapped`).
                self.playUnlockSuccessAnimation()
            } else {
                // GL-25's rule in its own words: a cancel aborts, it never
                // falls through to something weaker. It also must not read
                // as a wrong password - the captain typed nothing.
                self.localAuthButton.isEnabled = true
                self.errorLabel.stringValue = "macOS didn't confirm it was you. Grand Line is still locked."
                self.errorLabel.isHidden = false
                self.playUnlockFailureAnimation()
            }
        }
    }

    @objc private func checkAgainTapped() {
        onCheckAgain?()
    }

    private func showSetupCommand(_ command: String) {
        shownSetupCommand = command
        setupCommandLabel.stringValue = command
        setupCommandStack.isHidden = false
    }

    @objc private func copySetupCommandTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shownSetupCommand, forType: .string)
        // `HelmButton` owns its own `attributedTitle` (`restyle()` rebuilds it
        // on every theme change), so the confirmation goes through `title`.
        copyCommandButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyCommandButton.title = "Copy"
        }
    }

    /// A calmer alternative to a harsh red flash, per the approved design: a
    /// small horizontal shake on the password well, paired with a quick
    /// distressed rock on the boat itself (captain ask: a distinct animation
    /// for success vs. failure, not just the field).
    private func playUnlockFailureAnimation() {
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        let base = passwordField.layer?.position.x ?? 0
        shake.values = [base, base - 8, base + 8, base - 5, base + 5, base]
        shake.duration = 0.36
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        passwordField.layer?.add(shake, forKey: "shake")

        let rock = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rock.values = [0, -0.09, 0.09, -0.05, 0.05, 0]
        rock.duration = 0.36
        rock.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        boatImageView.layer?.add(rock, forKey: "distress")
    }

    /// The success flourish: the boat sails off to the right and fades,
    /// as if departing now that the gate's open - a deliberately different
    /// shape of motion than the failure rock above, not just the same
    /// animation with different numbers. `onUnlockAnimationFinished` fires
    /// once this completes, which is what actually tells the app shell to
    /// hide the overlay (see `submitTapped`'s header comment on why that
    /// can't happen any earlier).
    private func playUnlockSuccessAnimation() {
        let duration = 0.55
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.onUnlockAnimationFinished?()
        }

        let sail = CABasicAnimation(keyPath: "position.x")
        let baseX = boatImageView.layer?.position.x ?? 0
        sail.fromValue = baseX
        sail.toValue = baseX + 90
        sail.duration = duration
        sail.timingFunction = CAMediaTimingFunction(name: .easeIn)
        sail.fillMode = .forwards
        sail.isRemovedOnCompletion = false
        boatImageView.layer?.add(sail, forKey: "sailAway")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        boatImageView.layer?.add(fade, forKey: "fadeAway")

        // L-2, in the same transaction so the completion still waits for it:
        // one last flash, the card lifting away, and in the light register the
        // day breaking - today's sky, sea and sun - as the beams fade.
        lighthouse.lastFlash()
        let lift = CABasicAnimation(keyPath: "opacity")
        lift.fromValue = 1
        lift.toValue = 0
        lift.duration = 0.34
        lift.beginTime = CACurrentMediaTime() + 0.18
        lift.fillMode = .both
        lift.isRemovedOnCompletion = false
        cardShadowHost.layer?.add(lift, forKey: "flourish")
        if let day = currentScene?.day {
            func hold(_ layer: CALayer, _ key: String, to value: Any, from: Any?, duration: CFTimeInterval, delay: CFTimeInterval) {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = from
                a.toValue = value
                a.duration = duration
                a.beginTime = CACurrentMediaTime() + delay
                a.fillMode = .both
                a.isRemovedOnCompletion = false
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(a, forKey: "flourish")
            }
            hold(daySkyLayer, "opacity", to: 1, from: 0, duration: 0.6, delay: 0.1)
            hold(daySunLayer, "opacity", to: 1, from: 0, duration: 0.5, delay: 0.18)
            hold(sunLayer, "opacity", to: 0, from: 1, duration: 0.36, delay: 0.1)
            hold(seaGradient, "colors", to: [day.wave, Self.blend(day.wave, into: day.ground, fraction: 0.45)].map(\.cgColor),
                 from: seaGradient.colors, duration: 0.6, delay: 0.05)
            hold(backSeaGradient, "colors", to: [day.backWave, Self.blend(day.backWave, into: day.ground, fraction: 0.45)].map(\.cgColor),
                 from: backSeaGradient.colors, duration: 0.6, delay: 0.05)
            lighthouse.fadeOutForDay(duration: 0.4, delay: 0.26)
        }

        CATransaction.commit()
    }

    /// Clears what a success flourish left holding its end state, so the next
    /// lock opens on the normal dusk.
    private func resetFlourish() {
        for layer in [daySkyLayer, daySunLayer, sunLayer, seaGradient, backSeaGradient] as [CALayer] {
            layer.removeAnimation(forKey: "flourish")
        }
        cardShadowHost.layer?.removeAnimation(forKey: "flourish")
        view.layer?.opacity = 1
    }

    // MARK: - The lamp (board design L-2)

    enum LightSource { case pointer, key }

    /// Reduce Motion and VoiceOver start lit: there is no gate to work out
    /// and nothing to pull.
    private static var startsLit: Bool { HelmMotion.isReduced || NSWorkspace.shared.isVoiceOverEnabled }

    /// "Tap again to dim" never throws away a half-typed password or
    /// interrupts a check.
    private var canDim: Bool {
        isLit && openStyle && passwordField.stringValue.isEmpty && passwordField.isEnabled && !HelmMotion.isReduced
    }

    /// The lit or dark scene at once, with no animation.
    private func setLit(_ lit: Bool) {
        isLit = lit
        cardShadowHost.layer?.removeAnimation(forKey: "reveal")
        cardShadowHost.layer?.mask = nil
        cardShadowHost.alphaValue = lit ? 1 : 0
        cardShadowHost.isInert = !lit
        if lit { lighthouse.showLit(reducedMotion: Self.prefersReducedMotion) } else { lighthouse.showUnlit() }
    }

    /// Lights the lamp. From the pointer the lens spins up and the first beam
    /// paints the card in as it reaches it; from a key everything is quick,
    /// because whoever is typing is already halfway through a password.
    func light(_ source: LightSource) {
        guard !isLit, openStyle else { return }
        isLit = true
        cardShadowHost.isInert = false
        let reduced = Self.prefersReducedMotion
        lighthouse.light(reducedMotion: reduced, spinUp: source == .pointer && !reduced,
                         fadeVeil: source == .key ? 0.3 : 0.9)
        if source == .pointer && !reduced {
            revealByBeam()
        } else {
            fadeCard(show: true, duration: 0.22)
        }
    }

    /// Puts the lamp out again (tap the lighthouse with the field empty).
    func dim() {
        guard canDim else { return }
        isLit = false
        cardShadowHost.isInert = true
        fadeCard(show: false, duration: 0.3)
        lighthouse.dim()
    }

    private func toggleLamp() {
        if isLit { dim() } else { light(.pointer) }
        focusPasswordField()
    }

    private func fadeCard(show: Bool, duration: CFTimeInterval) {
        cardShadowHost.layer?.mask = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            cardShadowHost.animator().alphaValue = show ? 1 : 0
        }
    }

    /// The card appears where the first beam has been: a mask edge that
    /// follows the beam's tip leftwards across the card during the spun-up
    /// first quarter turn. The mask comes off the moment the card is whole,
    /// because a masked host would clip anything drawn past its bounds.
    private func revealByBeam() {
        guard let host = cardShadowHost.layer, host.bounds.width > 0 else { fadeCard(show: true, duration: 0.22); return }
        let pad: CGFloat = 40
        let mask = CAGradientLayer()
        mask.frame = host.bounds.insetBy(dx: -pad, dy: -pad)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        let originX = cardShadowHost.convert(NSPoint(x: -pad, y: 0), to: view).x
        let width = mask.frame.width
        let quarter = LockLighthouseScene.revolution / 4 / 2.1
        let steps = 24
        var values: [[NSNumber]] = []
        for k in 0...steps {
            let phi = Double.pi / 2 * Double(k) / Double(steps)
            let tip = lighthouse.lamp.x - LockLighthouseScene.beamLength * CGFloat(sin(phi))
            let u = Double((tip - originX) / width)
            values.append([NSNumber(value: min(1.2, u - 0.08)), NSNumber(value: min(1.3, u))])
        }
        mask.locations = values.last
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.isLit else { return }
            self.cardShadowHost.layer?.mask = nil
        }
        let sweep = CAKeyframeAnimation(keyPath: "locations")
        sweep.values = values
        sweep.duration = quarter
        sweep.calculationMode = .linear
        mask.add(sweep, forKey: "reveal")
        host.mask = mask
        cardShadowHost.alphaValue = 1
        CATransaction.commit()
    }

    /// The first key lights the lamp. A local monitor, so it needs no
    /// Accessibility grant; it returns every event unchanged, so the field
    /// editor still receives every key, Return and Tab included.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, event.window === self.view.window { self.noteKeyDown() }
            return event
        }
    }

    /// What a key in this window does: lights the lamp, unless the overlay is down.
    private func noteKeyDown() {
        guard !view.isHiddenOrHasHiddenAncestor else { return }
        light(.key)
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

#if FM_SELFTESTS
extension LockScreenController {
    /// Probe surface for `LockScreenSelfTest`. Deliberately read-only: the
    /// suite drives the real `apply(_:)`/`applyTheme(_:)` paths and only reads
    /// resolved geometry and colour back out.
    var debugCard: NSView { card }
    /// R2-UX-01's way forward from the two setup states, or nil while hidden.
    var debugCheckAgainButton: HelmButton? { checkAgainButton.isHidden ? nil : checkAgainButton }
    var debugCardShadowHost: NSView { cardShadowHost }
    var debugRibbonLayer: CAGradientLayer { ribbonLayer }
    var debugRibbonViewFrame: NSRect { ribbonView.frame }
    var debugSkyLayer: CAGradientLayer { skyLayer }
    /// E4: whether the looping decoration is currently attached, so a suite
    /// can prove `hideLock` genuinely detaches it instead of only hiding the
    /// view it lives on.
    var debugLoopingAnimationsAttached: Bool {
        boatImageView.layer?.animation(forKey: "bob") != nil
            || waveLayer.animation(forKey: "drift") != nil
            || backWaveLayer.animation(forKey: "drift") != nil
    }
    var debugMarkTile: HelmGradientTile { markTile }
    var debugTitle: NSTextField { titleLabel }
    var debugSubtitle: NSTextField { subtitleLabel }
    var debugPasswordField: HelmSecureTextField { passwordField }
    var debugUnlockButton: HelmButton { unlockButton }
    var debugSetupCommand: String { setupCommandLabel.stringValue }
    var debugCopyButton: HelmButton { copyCommandButton }
    var debugErrorLabel: NSTextField { errorLabel }
    var debugSetupCommandWell: NSStackView { setupCommandStack }
    var debugFormStack: NSStackView { formStack }
    var debugAvStack: NSStackView { avUnavailableStack }
    var debugWaitingStack: NSStackView { waitingStack }
    /// X1: the local fallback's own chrome and button, so a suite can assert
    /// which states offer it and drive the real control.
    var debugLocalAuthStack: NSStackView { localAuthStack }
    var debugLocalAuthButton: HelmButton { localAuthButton }
    var debugFooterStack: NSStackView { footerStack }
    var debugBoat: NSImageView { boatImageView }
    var debugStarLayers: [CALayer] { starLayers }
    var debugMoonBite: CALayer { moonBiteLayer }
    var debugCurrentHue: HelmDomainHue { currentHue }

    // L-2 probes. Read-only views onto the lamp, plus the two entry points a
    // real event takes (the tower's click and the first key), so a check can
    // drive the wiring rather than the helper behind it.
    var debugIsLit: Bool { isLit }
    var debugCardHostAlpha: CGFloat { cardShadowHost.alphaValue }
    var debugCardHostInert: Bool { cardShadowHost.isInert }
    var debugCardHostIsHidden: Bool { cardShadowHost.isHidden }
    var debugOpenStyle: Bool { openStyle }
    var debugAvatarShown: Bool { !avatar.isHidden }
    var debugArrowShown: Bool { !arrowButton.isHidden }
    var debugUnlockShown: Bool { !unlockButton.isHidden }
    var debugMarkTileShown: Bool { !markTile.isHidden }
    var debugArrowButton: HelmIconButton { arrowButton }
    var debugLighthouse: LockLighthouseScene { lighthouse }
    var debugHotspot: NSView { lighthouseHotspot }
    var debugKeyMonitorInstalled: Bool { keyMonitor != nil }
    var debugBoatImageSize: NSSize { boatImageView.frame.size }
    var debugDaySky: CAGradientLayer { daySkyLayer }
    func debugClickLighthouse() { lighthouseHotspot.debugClick() }
    /// The key monitor's own handler, so the check goes through what a key does.
    func debugKeyDown() { noteKeyDown() }

    /// Drives the rejected-password branch without needing a real `av`
    /// subprocess - `submitTapped`'s own failure path, verbatim.
    func debugSimulateFailedAttempt() {
        errorLabel.stringValue = "That password didn't match. Try again."
        errorLabel.isHidden = false
        playUnlockFailureAnimation()
    }
}
#endif

/// B6: a view whose only job is to keep a gradient sublayer the size of its
/// own bounds.
///
/// A `CAGradientLayer` added as a *sublayer* has no autoresizing relationship
/// to its host view - somebody has to set its frame, and doing that from an
/// ancestor's `viewDidLayout` is a bet that the ancestor lays out at a moment
/// when this view's own bounds are already resolved. On the lock screen's
/// first presentation that bet lost. Owning the sync here makes it structural.
private final class GradientHostView: NSView {
    let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // Never animated: a standalone sublayer's frame change carries Core
        // Animation's default ~0.25s implicit animation, which on a resize
        // slides the ribbon behind the card's own instant relayout (the
        // finding `HelmMotion.withoutImplicitAnimation` exists for).
        HelmMotion.withoutImplicitAnimation { gradient.frame = bounds }
    }
}

/// The gate card's shadow host. While the lamp is out it is transparent and
/// refuses clicks; it is never `isHidden`, because hiding the view that holds
/// the first responder moves first responder elsewhere, and typing-first is
/// the one rule this screen cannot break.
private final class GateHostView: NSView {
    var isInert = false
    override func hitTest(_ point: NSPoint) -> NSView? { isInert ? nil : super.hitTest(point) }
}

/// The lighthouse's tap target. It never takes first responder, so a click on
/// the tower leaves the password field focused.
private final class SceneHotspotView: NSView {
    var onClick: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Lighthouse" }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    #if FM_SELFTESTS
    func debugClick() { onClick?() }
    #endif
}

/// C-4 Open sea's avatar: the app's mark as a round, ringed tile.
private final class OpenSeaAvatarView: NSView {
    static let side: CGFloat = 76
    private let gradient = CAGradientLayer()
    private let glyph = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = false
        layer?.cornerRadius = Self.side / 2
        layer?.borderWidth = 3
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 15
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        gradient.cornerRadius = Self.side / 2
        gradient.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        HelmMotion.withoutImplicitAnimation { gradient.frame = bounds }
    }

    func configure(theme: HelmTheme, hue: HelmDomainHue) {
        let pair = hue.pair(in: theme)
        let light = HelmField.sceneLight(theme)
        HelmMotion.withoutImplicitAnimation {
            gradient.colors = [pair.h1.cgColor, pair.h2.cgColor]
            layer?.borderColor = light.withAlphaComponent(0.55).cgColor
            layer?.shadowColor = HelmTheme.nsColor(theme.mode == .dark ? theme.backgroundHex : theme.chromeInkHex).cgColor
        }
        glyph.image = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .regular))
        glyph.contentTintColor = light
    }
}
