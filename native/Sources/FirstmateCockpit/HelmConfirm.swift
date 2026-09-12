// Manjesh Grand Line - native macOS app.
//
// G3 of the UI modernization audit: the app's one *themed* confirm.
//
// The finding: 30 `NSAlert` sites, and "the stock alert (center-screen, system
// font, blue default button) is the strongest possible 'system chrome
// interrupting the theme' moment, and it happens on the app's most
// security-charged interactions."
//
// **The rule this migration follows, and the one thing to preserve if it is
// ever extended.** This is a safety-sensitive migration: every one of these
// dialogs is the last thing between a click and something irreversible. So the
// component is **blocking**, and it returns the same kind of answer an
// `NSAlert` did:
//
//     let go = HelmConfirm.confirm(title: …, body: …) == .confirm
//
// runs its own modal session and does not return until the captain has
// answered - identical control flow to `alert.runModal()`. That is deliberate
// and is what made 22 call sites a *type* change rather than a rewrite: no
// call site had to be restructured around a completion handler, so no call
// site had an opportunity to get its own safety logic wrong on the way.
//
// **What deliberately keeps the system alert**, decided site by site rather
// than by a blanket rule. The finding says to keep `NSAlert` "only where a
// truly modal system-level stop is the point", and names the AI-authored
// command gate as a candidate. The line drawn here is: **a command or a binary
// is about to execute outside this app's control, where the app cannot undo
// the consequence.**
//
//   - All four of `CommandRiskConfirmation`'s alerts (the disruptive gate, the
//     destructive gate, the multi-line refusal, the AI-authored gate). A real
//     shell command is about to run against real infrastructure. Keeping the
//     whole type untouched is also the safest possible outcome for the
//     highest-risk surface in the app - its own self-tests assert exactly one
//     definition of it exists.
//   - `ConsoleController+Herdr`'s restart: it terminates live panes in a
//     *different* program the captain runs outside Grand Line.
//   - `UpdatesController+AppRow`'s self-update: it replaces the running binary
//     and terminates. A themed panel belonging to a process that is about to
//     be replaced is the wrong object to be looking at.
//   - The two `beginSheetModal` sites (SRE Lead's limit notice, the incident
//     prompt). Those are already *sheets* attached to their window rather than
//     centre-screen alerts, so they are the least system-chrome-ish of the
//     thirty; converting them would also mean changing blocking semantics,
//     which is the one thing this migration will not do.
//
// Everything else migrates.
//
// **Button order is preserved exactly, per site.** The survey behind this
// found two competing conventions in the 30: `DestructiveConfirm` and the risk
// gates put Cancel first so Return cancels, while ten sites put the action
// first so Return performs it - including irreversible ones. That
// inconsistency is real and worth fixing, and fixing it *here* would be
// changing a safety gate's behaviour inside a restyle. So `confirmIsDefault`
// carries each site's existing answer unchanged, and the inconsistency is
// raised separately.

import AppKit

enum HelmConfirm {

    /// What the captain chose. Three cases because two of the migrated dialogs
    /// are genuinely three-way (a draft preview offering Copy / Save / Close,
    /// and the backup picker offering Local / GitHub / Cancel) - not because a
    /// confirm should normally have three buttons.
    enum Response {
        case confirm
        case cancel
        case extra
    }

    /// A third button, for the two dialogs that need one.
    ///
    /// `isEnabled` and `tooltip` exist for the backup picker's GitHub option,
    /// which is offered-but-disabled with an explanation when `gh` is not
    /// logged in - saying why it cannot be used is more useful than hiding it.
    struct ExtraButton {
        let title: String
        var isEnabled: Bool = true
        var tooltip: String?
        init(title: String, isEnabled: Bool = true, tooltip: String? = nil) {
            self.title = title
            self.isEnabled = isEnabled
            self.tooltip = tooltip
        }
    }

    /// Everything a confirm needs, as one value - so the test seam below can
    /// stand in for the whole dialog without a call site knowing.
    struct Request {
        var title: String
        var body: String
        var confirmTitle: String = "OK"
        var cancelTitle: String? = "Cancel"
        var extra: ExtraButton?
        var destructive: Bool = false
        /// Does Return activate the confirm button, or Cancel? Escape always
        /// cancels. See this file's header - each migrated site keeps the
        /// answer its `NSAlert` gave.
        var confirmIsDefault: Bool = true
        var symbol: String?
        var hue: HelmDomainHue = .blue
        /// Extra content between the body and the buttons - the incident
        /// prompt's field, the draft preview's text view.
        var accessory: NSView?
        /// The view inside the accessory that should hold focus when the
        /// dialog opens.
        var initialResponder: NSView?
    }

    #if FM_SELFTESTS
    /// Stands in for the whole dialog.
    ///
    /// A headless suite cannot answer a real modal session, and a self-test
    /// that could not reach these call sites would leave the app's safety
    /// gates - the most important thing in this migration - untested. The same
    /// seam `MultiHostSendExecutor.confirm` already uses, for the same reason.
    ///
    /// It receives the real `Request` the call site built, so a check can
    /// assert the *copy* as well as the outcome.
    static var responderForTests: ((Request) -> Response)?
    #endif

    // MARK: Entry points

    /// The two-button confirm. Blocking, like the `runModal()` it replaced.
    @discardableResult
    static func confirm(_ request: Request) -> Response {
        #if FM_SELFTESTS
        if let responderForTests { return responderForTests(request) }
        #endif
        return runModal(request)
    }

    /// Convenience for the common shape.
    @discardableResult
    static func confirm(title: String,
                        body: String,
                        confirmTitle: String,
                        cancelTitle: String = "Cancel",
                        destructive: Bool = false,
                        confirmIsDefault: Bool = true,
                        symbol: String? = nil,
                        hue: HelmDomainHue = .blue) -> Bool {
        var request = Request(title: title, body: body)
        request.confirmTitle = confirmTitle
        request.cancelTitle = cancelTitle
        request.destructive = destructive
        request.confirmIsDefault = confirmIsDefault
        request.symbol = symbol
        request.hue = hue
        return confirm(request) == .confirm
    }

    /// A one-button blocking acknowledgement - the nine `NSAlert`s that added
    /// no buttons at all and got AppKit's implicit "OK".
    ///
    /// Still blocking, for the same reason the confirms are: several of these
    /// fire mid-save and the code after them depends on the captain having
    /// seen the message before it continues.
    static func notice(title: String,
                       body: String,
                       symbol: String? = nil,
                       hue: HelmDomainHue = .blue) {
        var request = Request(title: title, body: body)
        request.confirmTitle = "OK"
        request.cancelTitle = nil
        request.symbol = symbol
        request.hue = hue
        _ = confirm(request)
    }

    /// An error, said in the app's own voice. `.rose` and a warning glyph, so
    /// the nine former `.critical`/`.warning` alerts keep their severity
    /// without the system's chrome.
    static func problem(title: String, body: String) {
        notice(title: title, body: body,
               symbol: "exclamationmark.triangle.fill", hue: .rose)
    }

    // MARK: The panel

    /// Build the real dialog view without running it - so a self-test can read
    /// the copy, the button titles and the default key off the thing the
    /// captain would actually see.
    static func makeContent(_ request: Request) -> HelmConfirmView {
        HelmConfirmView(request: request)
    }

    private static func runModal(_ request: Request) -> Response {
        let content = makeContent(request)
        let size = content.measuredSize()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = content
        panel.followHelmTheme()
        if let anchor = NSApp.keyWindow ?? NSApp.mainWindow {
            let frame = anchor.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                         y: frame.midY - size.height / 2))
        } else {
            panel.center()
        }

        var answer: Response = .cancel
        content.onAnswer = { response in
            answer = response
            NSApp.stopModal()
        }
        // The session has to be ended from the button handler above, never by
        // the panel closing on its own - a modal session left running is an
        // app that no longer responds to anything.
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return answer
    }
}

/// The dialog's content: an icon tile, a title, a body, an optional accessory,
/// and the buttons - `HelmFormSheet`'s language at dialog scale.
final class HelmConfirmView: NSView {

    static let width: CGFloat = 380

    private let request: HelmConfirm.Request
    private let tile = HelmGradientTile(size: .module)
    private let flatTile: IconTileView
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private var confirmButton: HelmButton?
    private var cancelButton: HelmButton?
    private var extraButton: HelmButton?
    private var escapeButton: NSButton?
    private var observation: ThemeObservation?

    var onAnswer: ((HelmConfirm.Response) -> Void)?

    init(request: HelmConfirm.Request) {
        self.request = request
        self.flatTile = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
    }

    private func build() {
        let symbol = request.symbol
            ?? (request.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
        // Exactly one tile is ever visible - the arrangement `HelmAccentRow`
        // and `HelmEmptyState` already use, so a theme change never rebuilds.
        tile.configure(symbol: symbol, hue: request.hue)
        tile.translatesAutoresizingMaskIntoConstraints = false
        flatTile.configure(symbol: symbol, tint: request.destructive ? .critical : .accent)
        flatTile.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = request.title
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 3
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.stringValue = request.body
        bodyLabel.isHidden = request.body.isEmpty
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        var buttons: [NSView] = []
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.append(spacer)

        if let extra = request.extra {
            let button = HelmButton(title: extra.title, variant: .secondary,
                                    target: self, action: #selector(extraClicked))
            button.isEnabled = extra.isEnabled
            button.toolTip = extra.tooltip
            extraButton = button
            buttons.append(button)
        }
        if let cancelTitle = request.cancelTitle {
            let button = HelmButton(title: cancelTitle, variant: .secondary,
                                    target: self, action: #selector(cancelClicked))
            cancelButton = button
            buttons.append(button)
        }
        let confirm = HelmButton(title: request.confirmTitle,
                                 variant: request.destructive ? .destructive : .primary,
                                 target: self, action: #selector(confirmClicked))
        if request.confirmIsDefault {
            confirm.keyEquivalent = "\r"
        } else if let cancelButton {
            // The site's own answer, preserved: Return means Cancel here. Both
            // safe keys doing the safe thing is the whole point of
            // `DestructiveConfirm`'s ordering, and this migration does not get
            // to change it in either direction.
            cancelButton.keyEquivalent = "\r"
        }
        confirmButton = confirm
        buttons.append(confirm)

        // **Escape needs its own button, and the reason is a real defect this
        // shipped for one test run.** An `NSButton` holds exactly one
        // `keyEquivalent`, so on a `confirmIsDefault: false` dialog - every
        // `DestructiveConfirm` and the credential-vault delete - giving Cancel
        // the Return key *overwrote* its Escape key, and Escape stopped
        // cancelling on precisely the dialogs where both safe keys doing the
        // safe thing is the whole point. An `NSAlert` never had that problem
        // because AppKit assigns Return and Escape independently.
        //
        // A zero-sized hidden button carries Escape instead.
        // `performKeyEquivalent:` reaches it regardless of first responder,
        // which is the same mechanism `HelmFormSheet`'s own footer relies on.
        if request.cancelTitle != nil {
            let escape = NSButton(title: "", target: self, action: #selector(cancelClicked))
            escape.keyEquivalent = "\u{1b}"
            escape.isHidden = true
            escape.translatesAutoresizingMaskIntoConstraints = false
            escapeButton = escape
            addSubview(escape)
            NSLayoutConstraint.activate([
                escape.widthAnchor.constraint(equalToConstant: 0),
                escape.heightAnchor.constraint(equalToConstant: 0),
            ])
        }

        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fill
        buttonRow.spacing = HelmMetrics.s2 + 2
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let textColumn = NSStackView(views: [titleLabel, bodyLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = HelmMetrics.s2 - 2
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.setHuggingPriority(.defaultLow, for: .horizontal)

        let headRow = NSStackView(views: [tile, flatTile, textColumn])
        headRow.orientation = .horizontal
        headRow.alignment = .top
        headRow.distribution = .fill
        headRow.spacing = HelmMetrics.s3
        headRow.translatesAutoresizingMaskIntoConstraints = false

        var column: [NSView] = [headRow]
        if let accessory = request.accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            column.append(accessory)
        }
        column.append(buttonRow)

        let stack = NSStackView(views: column)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s5),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s5),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s5),
            headRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        if let accessory = request.accessory {
            accessory.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // A minimum, not a fixed width: the draft preview's accessory is wider
        // than any confirm and must be allowed to set the dialog's size.
        widthAnchor.constraint(greaterThanOrEqualToConstant: Self.width).isActive = true

        applyTheme(ThemeManager.shared.theme)
    }

    /// The width the wrapping body actually gets, for a given panel width.
    ///
    /// **One definition, consulted by `applyTheme`, `layout()` and
    /// `measuredSize()` alike** - three copies of this arithmetic is how the
    /// measurement and the render came to disagree about how many lines the
    /// body needs (see `measuredSize()`).
    ///
    /// It reads the *visible* tile's side rather than a constant: exactly one
    /// of the two tiles is ever shown, and they are different sizes (30pt for
    /// the Daylight family's gradient tile, `tileBase` for the twelve legacy
    /// palettes' flat one), so a hardcoded `tileBase` over-reserved 4pt on
    /// every Daylight-family dialog - the safe direction, but still two
    /// answers to one question.
    private func bodyWidth(forPanelWidth width: CGFloat) -> CGFloat {
        let tileSide = tile.isHidden ? HelmMetrics.tileBase : HelmGradientTile.Size.module.side
        return max(200, width - HelmMetrics.s5 * 2 - tileSide - HelmMetrics.s3)
    }

    /// The size the panel should be - measured at the width the body will
    /// really wrap at.
    ///
    /// **`fittingSize` on its own is not a usable measurement for this view,
    /// and reading it directly is the defect this replaced.** The body is a
    /// wrapping label, so its height depends entirely on
    /// `preferredMaxLayoutWidth` - and until this view is in a window its
    /// `bounds.width` is 0, so both places that derive that width fall back to
    /// the 200pt floor. `runModal` measured there, sized the panel for a body
    /// wrapped at 200pt, mounted it at 380, and `layout()` then re-wrapped the
    /// body at ~286pt where it needs several fewer lines - with the panel's
    /// frame already fixed and never re-derived.
    ///
    /// Measured on the Updates page's firstmate sync dialog (the app's
    /// longest confirm body): **308pt measured against 244pt actually needed,
    /// i.e. 64pt - a quarter of the panel - of dead space below the buttons**,
    /// in every theme. That is the captain-reported "the UI is not clean".
    ///
    /// Two passes, because the width is itself derived: an accessory may be
    /// wider than `Self.width`, so the width has to be settled first and the
    /// height measured against it second.
    func measuredSize() -> NSSize {
        let width = max(Self.width, fittingSize.width)
        bodyLabel.preferredMaxLayoutWidth = bodyWidth(forPanelWidth: width)
        return NSSize(width: width, height: fittingSize.height)
    }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        layer?.cornerRadius = theme.isDaylight ? HelmMetrics.dSurface : HelmMetrics.rPanel
        layer?.masksToBounds = true
        // §6.10's language: a gradient tile on the Daylight family, the flat
        // tinted tile on the twelve - exactly one visible, never both.
        tile.isHidden = !theme.isDaylight
        flatTile.isHidden = theme.isDaylight
        tile.applyTheme(theme)
        flatTile.applyTheme(theme)
        titleLabel.font = HelmType.sectionTitle()
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        bodyLabel.font = HelmType.body()
        bodyLabel.textColor = HelmTheme.mutedInk(theme)
        bodyLabel.preferredMaxLayoutWidth = bodyWidth(forPanelWidth: bounds.width)
    }

    override func layout() {
        super.layout()
        // The body is a wrapping label in a column whose width is only known
        // after a pass - the same re-derivation `HelmEmptyState` does, and for
        // the same reason: an over-estimated `preferredMaxLayoutWidth` makes
        // AppKit lay the label out one line tall and draw the second outside
        // its own bounds.
        bodyLabel.preferredMaxLayoutWidth = bodyWidth(forPanelWidth: bounds.width)
    }

    @objc private func confirmClicked() { onAnswer?(.confirm) }
    @objc private func cancelClicked() { onAnswer?(.cancel) }
    @objc private func extraClicked() { onAnswer?(.extra) }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugBody: String { bodyLabel.stringValue }
    var debugButtonTitles: [String] {
        [extraButton, cancelButton, confirmButton].compactMap { $0?.title }
    }
    /// Which button Return activates - the property this migration promises
    /// not to change at any site.
    var debugDefaultButtonTitle: String? {
        [confirmButton, cancelButton].compactMap { $0 }.first { $0.keyEquivalent == "\r" }?.title
    }
    /// Whether Escape reaches Cancel - read off whichever control actually
    /// carries it, which is not always the visible Cancel button.
    var debugEscapeCancels: Bool {
        cancelButton?.keyEquivalent == "\u{1b}" || escapeButton?.keyEquivalent == "\u{1b}"
    }
    /// Fire Escape exactly as the key would.
    func debugPressEscape() { escapeButton?.performClick(nil) ?? cancelButton?.performClick(nil) }
    var debugConfirmVariant: HelmButton.Variant? { confirmButton?.variant }
    func debugClickConfirm() { confirmButton?.performClick(nil) }
    func debugClickCancel() { cancelButton?.performClick(nil) }
    #endif
}
