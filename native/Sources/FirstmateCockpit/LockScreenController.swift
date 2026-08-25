// Manjesh Grand Line - native macOS app.
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
import AppKit

final class LockScreenController: NSViewController {

    enum ContentState {
        case locked(subtitle: String)
        case noPasswordConfigured
        /// `av` itself isn't installed on this Mac at all - distinct from
        /// `.noPasswordConfigured` (av installed, no secret saved yet): the
        /// "run av save..." instruction is actively wrong here since there's
        /// no `av` to run. Shows a real "Install Automic Vault" action
        /// instead (`onInstallAutomicVault`).
        case avUnavailable
        /// `av` is on PATH but its background approval service (the
        /// "Automic Vault" menu-bar app) isn't reachable yet - the password
        /// secret may already exist, `av` just can't confirm it right now.
        /// `AppShellController` retries the underlying check on a timer
        /// while this state is showing; this screen just displays it.
        case serviceNotRunning
        /// `av list` failed (or timed out) for a reason that isn't the
        /// specific `.serviceNotRunning` marker text - e.g. the approval
        /// helper being transiently unresponsive right after a long
        /// sleep/wake (`fm/grandline-vault-wake-recheck-fix`, live-
        /// confirmed: a suspended helper process makes `av list` hang
        /// indefinitely). The password secret may well already exist here
        /// too; `AppShellController` retries on the same cadence as
        /// `.serviceNotRunning` - this screen just displays it.
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

    /// Fired when the captain clicks "Install Automic Vault" on the
    /// `.avUnavailable` state - the caller runs the real Homebrew-cask
    /// install (`VaultSource.updateInstall()`, the same mechanism the
    /// Updates/Vault pages already use for this catalog entry) on a
    /// background queue and calls back with the outcome; this controller
    /// only shows install progress/result text, it knows nothing about
    /// `UpdatesSource`/`DependencyCatalog`.
    var onInstallAutomicVault: ((@escaping (Bool, String) -> Void) -> Void)?

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

    // MARK: Card

    /// The un-clipped shadow host. §2.5: a layer with a shadow must not clip,
    /// and a rounded fill must - so the card is the two-layer arrangement
    /// `HelmComposerCard` already proved here, with `shadowPath` resynced on
    /// every layout pass.
    private let cardShadowHost = NSView()
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

    // MARK: Content

    private let titleLabel = NSTextField(labelWithString: "Welcome back, Manjesh")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    /// The empty-state placeholder reads as masked dots rather than the word
    /// "Password" - it's rendered by `SunkenFieldTheming.applyPlaceholder` as a
    /// plain string in `HelmField.mutedInk`, so a literal bullet run is all
    /// that's needed; it's still only shown while empty and still replaced the
    /// instant typing starts, same as any other placeholder in this app.
    private let passwordField = HelmSecureTextField(placeholder: "•••••••••")
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

    // `.avUnavailable`-only UI: a distinct message plus a real install
    // action - see `onInstallAutomicVault` above.
    private let avMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = HelmButton(title: "Install Automic Vault", variant: .primary)
    private let installStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let avUnavailableStack = NSStackView()

    /// The two "retrying, nothing to type yet" states show a spinner instead
    /// of a form, because there is nothing useful the captain can do yet.
    private let waitingSpinner = NSProgressIndicator()
    private let waitingStack = NSStackView()
    private let waitingLabel = NSTextField(labelWithString: "")

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
            contentStack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -30),
            boatImageView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            boatImageView.topAnchor.constraint(greaterThanOrEqualTo: cardShadowHost.bottomAnchor,
                                               constant: HelmMetrics.s5),
        ])
        let onTheWater = boatImageView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -78)
        onTheWater.priority = NSLayoutConstraint.Priority(250)
        let stayOnScreen = boatImageView.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor,
                                                                constant: -8)
        stayOnScreen.priority = NSLayoutConstraint.Priority(400)
        NSLayoutConstraint.activate([onTheWater, stayOnScreen])

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
        root.layer?.addSublayer(backWaveLayer)
        root.layer?.addSublayer(waveLayer)

        let config = NSImage.SymbolConfiguration(pointSize: 38, weight: .regular)
        boatImageView.image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Manjesh Grand Line")?
            .withSymbolConfiguration(config)
        boatImageView.wantsLayer = true
        boatImageView.translatesAutoresizingMaskIntoConstraints = false
        boatImageView.widthAnchor.constraint(equalToConstant: 52).isActive = true
        boatImageView.heightAnchor.constraint(equalToConstant: 52).isActive = true
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
        formStack.addArrangedSubview(passwordField)
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

        installButton.target = self
        installButton.action = #selector(installTapped)
        installButton.translatesAutoresizingMaskIntoConstraints = false

        installStatusLabel.font = HelmType.caption()
        installStatusLabel.alignment = .center
        installStatusLabel.maximumNumberOfLines = 4
        installStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        avUnavailableStack.orientation = .vertical
        avUnavailableStack.alignment = .centerX
        avUnavailableStack.spacing = HelmMetrics.s3
        avUnavailableStack.translatesAutoresizingMaskIntoConstraints = false
        avUnavailableStack.addArrangedSubview(avMessageLabel)
        avUnavailableStack.addArrangedSubview(installButton)
        avUnavailableStack.addArrangedSubview(installStatusLabel)
        avUnavailableStack.isHidden = true

        waitingSpinner.style = .spinning
        waitingSpinner.controlSize = .small
        waitingSpinner.isIndeterminate = true
        waitingSpinner.translatesAutoresizingMaskIntoConstraints = false
        waitingLabel.font = HelmType.caption()
        waitingLabel.translatesAutoresizingMaskIntoConstraints = false
        waitingStack.orientation = .horizontal
        waitingStack.alignment = .centerY
        waitingStack.spacing = HelmMetrics.s2
        waitingStack.translatesAutoresizingMaskIntoConstraints = false
        waitingStack.addArrangedSubview(waitingSpinner)
        waitingStack.addArrangedSubview(waitingLabel)
        waitingStack.isHidden = true

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

        let body = NSStackView(views: [
            markTile, titleLabel, subtitleLabel, formStack, errorLabel,
            messageLabel, setupCommandStack, avUnavailableStack, waitingStack, footerStack,
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
            installStatusLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            formStack.widthAnchor.constraint(equalTo: body.widthAnchor),
            passwordField.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            unlockButton.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            setupCommandStack.widthAnchor.constraint(equalTo: body.widthAnchor),
            avUnavailableStack.widthAnchor.constraint(equalTo: body.widthAnchor),
            installButton.widthAnchor.constraint(equalTo: avUnavailableStack.widthAnchor),
            footerStack.widthAnchor.constraint(equalTo: body.widthAnchor),
            footerDivider.widthAnchor.constraint(equalTo: footerStack.widthAnchor),
        ])
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
        let sea = HelmDomainHue.teal.pair(in: theme)
        let sky = HelmDomainHue.blue.pair(in: theme)
        let isDark = theme.mode == .dark

        if isDark {
            // Night harbour: a deep sky reading down into the theme's own
            // ground, a cool moon, and a sea that all but dissolves into the
            // horizon. Every value is a blend of real tokens - there is no
            // second hand-tuned palette here, which is the whole point.
            return SceneColors(
                skyTop: Self.blend(sky.h1, into: ground, fraction: 0.34),
                skyMid: Self.blend(sky.h1, into: ground, fraction: 0.11),
                ground: ground,
                wave: Self.blend(sea.h1, into: ground, fraction: 0.5),
                backWave: Self.blend(sea.h1, into: ground, fraction: 0.28),
                boat: HelmTheme.nsColor(theme.chromeInkHex),
                celestial: sky.h2,
                celestialGlow: sky.h2.withAlphaComponent(0.35),
                star: HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.85),
                isDarkRegister: true
            )
        }
        // Daylight harbour: a soft blue zenith fading into the theme's own warm
        // paper at the horizon, an amber sun, a turquoise sea.
        let sun = HelmDomainHue.amber.pair(in: theme)
        return SceneColors(
            skyTop: Self.blend(sky.h2, into: ground, fraction: 0.46),
            skyMid: Self.blend(sky.h2, into: ground, fraction: 0.13),
            ground: ground,
            wave: Self.blend(sea.h1, into: ground, fraction: 0.5),
            backWave: Self.blend(sea.h2, into: ground, fraction: 0.3),
            boat: Self.blend(sea.h1, into: HelmTheme.nsColor(theme.chromeInkHex), fraction: 0.55),
            celestial: sun.h2,
            celestialGlow: sun.h1.withAlphaComponent(0.4),
            star: .clear,
            isDarkRegister: false
        )
    }

    private func applyTheme(_ theme: HelmTheme) {
        let scene = sceneColors(for: theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)

        // Scene. Implicit CALayer animation is off for every one of these:
        // a standalone sublayer's property change animates by default (Phase 6
        // measured this on the gradient tiles), which would cross-fade the
        // whole sky on a theme switch - motion nobody designed.
        HelmMotion.withoutImplicitAnimation {
            view.layer?.backgroundColor = scene.ground.cgColor
            skyLayer.colors = [scene.skyTop, scene.skyMid, scene.ground].map(\.cgColor)
            waveLayer.fillColor = scene.wave.cgColor
            backWaveLayer.fillColor = scene.backWave.cgColor
            sunLayer.backgroundColor = scene.celestial.cgColor
            sunLayer.shadowColor = scene.celestialGlow.cgColor
            moonBiteLayer.backgroundColor = scene.skyTop.cgColor
            moonBiteLayer.isHidden = !scene.isDarkRegister
            for star in starLayers {
                star.backgroundColor = scene.star.cgColor
                star.isHidden = !scene.isDarkRegister
            }
        }
        boatImageView.contentTintColor = scene.boat

        // Card chrome. `applyCardSurface` is the app's one card fill/border, so
        // this gate cannot drift from the sheets it is meant to match; the
        // shadow is `HelmCard.elevation(.raised)`, §6.10's own level.
        HelmCard.applyCardSurface(to: card, theme: theme, cornerRadius: HelmMetrics.dModule)
        let shadow = HelmCard.elevation(for: theme, level: .raised)
        HelmMotion.withoutImplicitAnimation {
            cardShadowHost.layer?.shadowColor = (shadow.shadowColor ?? .black).cgColor
            cardShadowHost.layer?.shadowOpacity = 1
            cardShadowHost.layer?.shadowRadius = shadow.shadowBlurRadius
            cardShadowHost.layer?.shadowOffset = CGSize(width: shadow.shadowOffset.width,
                                                        height: shadow.shadowOffset.height)
        }
        applyRibbon(theme: theme)
        markTile.configure(symbol: currentSymbol, hue: currentHue)

        titleLabel.textColor = ink
        subtitleLabel.textColor = muted
        messageLabel.textColor = muted
        avMessageLabel.textColor = muted
        installStatusLabel.textColor = muted
        waitingLabel.textColor = muted
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
        installButton.domainHue = currentHue
        applyLayerGeometry()
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

            for layer in view.layer?.sublayers ?? [] where layer.value(forKey: "xFrac") != nil {
                let xFrac = layer.value(forKey: "xFrac") as? CGFloat ?? 0
                let yFrac = layer.value(forKey: "yFrac") as? CGFloat ?? 0
                let size = layer.bounds.width
                layer.position = CGPoint(x: bounds.width * xFrac, y: bounds.height * yFrac)
                layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            }
        }

        waveWidth = bounds.width * 2
        HelmMotion.withoutImplicitAnimation {
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
    private var reduceMotionObserver: Any?

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
        startAnimationsIfNeeded()
    }

    private func startAnimationsIfNeeded() {
        guard !animationsStarted, waveWidth > 0 else { return }
        animationsStarted = true

        // Observe live changes so toggling Reduce Motion while the lock screen
        // is up takes effect, rather than only on the next launch.
        if reduceMotionObserver == nil {
            reduceMotionObserver = NotificationCenter.default.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.applyMotionPreference()
            }
        }

        guard !Self.prefersReducedMotion else { return }
        addLoopingAnimations()
    }

    /// Adds or removes the looping decoration to match the current setting.
    private func applyMotionPreference() {
        if Self.prefersReducedMotion {
            boatImageView.layer?.removeAnimation(forKey: "bob")
            waveLayer.removeAnimation(forKey: "drift")
            backWaveLayer.removeAnimation(forKey: "drift")
        } else if animationsStarted, boatImageView.layer?.animation(forKey: "bob") == nil {
            addLoopingAnimations()
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
    }

    deinit {
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
        }
    }

    // MARK: - Content

    func apply(_ state: ContentState) {
        currentHue = state.hue
        currentSymbol = state.symbol

        // Defaults: every state below turns on only what it needs.
        formStack.isHidden = true
        errorLabel.isHidden = true
        messageLabel.isHidden = true
        setupCommandStack.isHidden = true
        avUnavailableStack.isHidden = true
        waitingStack.isHidden = true
        waitingSpinner.stopAnimation(nil)
        footerLeftLabel.stringValue = ""
        footerRightLabel.stringValue = ""

        switch state {
        case .locked(let subtitle):
            titleLabel.stringValue = "Welcome back, Manjesh"
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
            subtitleLabel.stringValue = "No app password is saved yet. Run this in a terminal (or set it from Automic Vault's own app), then relaunch."
            setupCommandStack.isHidden = false
            footerLeftLabel.stringValue = "The one screen where nothing else is reachable"

        case .avUnavailable:
            titleLabel.stringValue = "Automic Vault isn't installed"
            subtitleLabel.stringValue = "Grand Line keeps your app password in Automic Vault's keychain. Install it to continue."
            avUnavailableStack.isHidden = false
            avMessageLabel.stringValue = "Once it's installed, set a password with \u{201c}\(VaultSource.appPasswordSetupCommand)\u{201d} (or Automic Vault's own app) and relaunch Manjesh Grand Line."
            installButton.isEnabled = true
            installStatusLabel.stringValue = ""
            footerLeftLabel.stringValue = "Installs via Homebrew"

        case .serviceNotRunning:
            titleLabel.stringValue = "Waking Automic Vault"
            subtitleLabel.stringValue = "Its approval service isn't answering yet. Retrying - this usually clears in a few seconds."
            waitingStack.isHidden = false
            waitingLabel.stringValue = "Checking\u{2026}"
            waitingSpinner.startAnimation(nil)

        case .transientFailure:
            titleLabel.stringValue = "Couldn't reach the vault"
            subtitleLabel.stringValue = "The check timed out. Your password is probably fine - retrying."
            waitingStack.isHidden = false
            waitingLabel.stringValue = "Retrying\u{2026}"
            waitingSpinner.startAnimation(nil)
        }

        // The footer only earns its divider when it has something to say.
        footerStack.isHidden = footerLeftLabel.stringValue.isEmpty && footerRightLabel.stringValue.isEmpty
        // Re-derive everything the hue drives for the state just applied.
        applyTheme(ThemeManager.shared.theme)
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
        onAttempt(typed) { [weak self] success in
            guard let self else { return }
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
                self.passwordField.stringValue = ""
                self.errorLabel.stringValue = "That password didn't match. Try again."
                self.errorLabel.isHidden = false
                self.playUnlockFailureAnimation()
                self.view.window?.makeFirstResponder(self.passwordField)
            }
        }
    }

    @objc private func copySetupCommandTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(VaultSource.appPasswordSetupCommand, forType: .string)
        // `HelmButton` owns its own `attributedTitle` (`restyle()` rebuilds it
        // on every theme change), so the confirmation goes through `title`.
        copyCommandButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyCommandButton.title = "Copy"
        }
    }

    @objc private func installTapped() {
        guard let onInstallAutomicVault else { return }
        installButton.isEnabled = false
        installStatusLabel.stringValue = "Installing Automic Vault\u{2026}"
        onInstallAutomicVault { [weak self] success, message in
            guard let self else { return }
            self.installStatusLabel.stringValue = message
            // Leave the button disabled on success (the state itself will
            // move on to `.noPasswordConfigured`/`.serviceNotRunning` once
            // `AppShellController` re-checks); re-enable on failure so the
            // captain can retry without relaunching.
            self.installButton.isEnabled = !success
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

        CATransaction.commit()
    }
}

#if FM_SELFTESTS
extension LockScreenController {
    /// Probe surface for `LockScreenSelfTest`. Deliberately read-only: the
    /// suite drives the real `apply(_:)`/`applyTheme(_:)` paths and only reads
    /// resolved geometry and colour back out.
    var debugCard: NSView { card }
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
    var debugInstallButton: HelmButton { installButton }
    var debugCopyButton: HelmButton { copyCommandButton }
    var debugErrorLabel: NSTextField { errorLabel }
    var debugSetupCommandWell: NSStackView { setupCommandStack }
    var debugFormStack: NSStackView { formStack }
    var debugAvStack: NSStackView { avUnavailableStack }
    var debugWaitingStack: NSStackView { waitingStack }
    var debugFooterStack: NSStackView { footerStack }
    var debugBoat: NSImageView { boatImageView }
    var debugStarLayers: [CALayer] { starLayers }
    var debugMoonBite: CALayer { moonBiteLayer }
    var debugCurrentHue: HelmDomainHue { currentHue }

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
