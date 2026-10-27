// Grand Line - native macOS app.
//
// The first-run welcome sheet - review #3's UX13.
//
// The finding: "There is no first-run experience beyond GL-31's 'land on Setup
// when unconfigured'. A second user (or the captain on a new Mac) sees a lock
// screen demanding an Automic Vault secret with a shell command to run."
//
// Three steps, which is the finding's own shape: theme -> what this app is ->
// the lock.
//
// # One honest departure from the finding's wording
//
// It asks for "set your password / skip lock" as step three. **This app cannot
// set that password**, and a step that pretended to would be worse than the
// lock screen it replaces. The app lock is backed by Automic Vault - a
// separate tool with its own keychain, reached by shelling out - which is
// precisely *why* the lock screen shows a shell command, and why
// `LockScreenController`'s own `.noPasswordConfigured` copy says "run this in
// a terminal […] then relaunch".
//
// So step three **explains** the lock, hands over the exact command on a
// copyable well (the same `VaultSource.appPasswordSetupCommand` the lock
// screen itself shows, never a second copy of the string), and lets the
// captain skip. What that fixes is the real complaint - the command arrives
// with context, at a moment the captain chose, rather than as the first thing
// a new Mac shows them.
//
// # Shown once
//
// Gated on `AppSettings.hasSeenWelcome`, set when the sheet is dismissed by
// any route. A captain who closes it has decided; re-asking would be the
// opposite of respecting that.

import AppKit

final class WelcomeSheetController: NSViewController {
    /// P3: a controller built per presentation stores its token and
    /// unobserves, or it leaks a closure into `ThemeManager.observers`.
    private var themeObservation: ThemeObservation?

    /// Raised when the sheet closes, however it closed.
    var onFinish: (() -> Void)?

    private enum Step: Int, CaseIterable {
        case theme
        /// R2-UX-01 (b): the first-run choice of profile. The sidebar
        /// layout's only - the floating bar has no modules to hide.
        case profile
        case tour
        case lock

        var title: String {
            switch self {
            case .theme: return "Pick a look"
            case .profile: return "How will you use Grand Line?"
            case .tour: return "What this is"
            case .lock: return "Locking the app"
            }
        }

        /// The steps a layout shows, in order.
        static func steps(for layout: WorkspaceLayout) -> [Step] {
            layout == .sidebar ? allCases : allCases.filter { $0 != .profile }
        }

        var blurb: String {
            switch self {
            case .theme:
                return "Grand Line ships seven themes, each with a light and a dark look. Pick one now - it "
                    + "applies as you click, and you can change it any time from \(PlaceName.of(.settings)) "
                    + "\u{203A} Appearance. The terminal's own colours are on the Terminal page."
            case .profile:
                return "Pick the modules your sidebar starts with. You can show or hide any of them later in "
                    + "\(PlaceName.of(.settings)) \u{203A} Appearance, and nothing you hide is deleted."
            case .tour:
                // R2-UX-02: the sidebar layout has one map, the sidebar, so
                // its tour describes that and not the floating bar's spaces.
                if PlaceName.layout == .sidebar {
                    return "The sidebar on the left is the whole app: Home, then every module in four groups - "
                        + "Work, Observe, Workbench and Machine.\n\n"
                        + "A module with several pages shows them as tabs at the top of the window, "
                        + "and Back and Forward walk the pages you have opened.\n\n"
                        + "\u{2318}1 to \u{2318}9 open the first nine items in the sidebar, \u{21E7}\u{2318}[ and \u{21E7}\u{2318}] "
                        + "move between a module's tabs, and \u{2318}K searches for a page, a note, a task or a command."
                }
                return "The app is five spaces, and the bar at the top switches between them.\n\n"
                    + "Overview is the hub - what needs you right now.\n"
                    + "Command is the console, your tasks and the merge queue.\n"
                    + "Operations is hosts, logs, health and schedules.\n"
                    + "Stores is your shelf: docs, the vault, notes, code and tools.\n"
                    + "Engineering is setup and this machine's settings.\n\n"
                    + "Press \u{2318}\u{21E7}D at any time to see every page at once, or \u{2318}K to search."
            case .lock:
                // R2-UX-01: the lock is an opt-in, so this step says how to
                // turn it on rather than implying it is already waiting.
                return "Grand Line opens without a password. To have it lock when you step away, "
                    + "save a password in Automic Vault's keychain with this command, then turn on "
                    + "\u{201c}Require a password to open Grand Line\u{201d} in \(PlaceName.of(.settings)) \u{203A} Security.\n\n"
                    + "Skipping is fine. The app works exactly the same; it just will not lock."
            }
        }
    }

    private let steps = Step.steps(for: PlaceName.layout)
    private var stepIndex = 0
    private var step: Step { steps[stepIndex] }

    private let titleLabel = NSTextField(labelWithString: "")
    private let blurbLabel = NSTextField(wrappingLabelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let bodyContainer = NSView()
    private let backButton = HelmButton(title: "Back", variant: .secondary)
    private let nextButton = HelmButton(title: "Next", variant: .primary)
    private let skipButton = HelmButton(title: "Skip", variant: .quiet)

    private let themeGrid = NSStackView()
    private var themeButtons: [HelmButton] = []
    private let profileStack = NSStackView()
    private var profileButtons: [(profile: WorkspaceProfile, button: HelmButton)] = []
    private let commandWell = NSTextField(labelWithString: "")
    private let commandCopyButton = HelmButton(title: "Copy", variant: .secondary, symbol: "doc.on.doc")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 430))
        view = root

        titleLabel.font = HelmType.pageTitle()
        blurbLabel.font = HelmType.body()
        stepLabel.font = HelmType.kicker()

        backButton.target = self
        backButton.action = #selector(backTapped)
        nextButton.target = self
        nextButton.action = #selector(nextTapped)
        nextButton.keyEquivalent = "\r"
        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.keyEquivalent = "\u{1b}"

        buildThemeGrid()
        buildProfileChoice()
        buildCommandWell()

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        for child in [themeGrid, profileStack, commandWell, commandCopyButton] as [NSView] {
            bodyContainer.addSubview(child)
        }
        NSLayoutConstraint.activate([
            profileStack.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            profileStack.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            profileStack.topAnchor.constraint(equalTo: bodyContainer.topAnchor),

            themeGrid.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            themeGrid.trailingAnchor.constraint(lessThanOrEqualTo: bodyContainer.trailingAnchor),
            themeGrid.topAnchor.constraint(equalTo: bodyContainer.topAnchor),

            commandWell.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            commandWell.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            commandWell.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            commandCopyButton.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            commandCopyButton.topAnchor.constraint(equalTo: commandWell.bottomAnchor, constant: HelmMetrics.s2),
        ])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [skipButton, spacer, backButton, nextButton])
        footer.orientation = .horizontal
        footer.spacing = HelmMetrics.s2
        footer.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [stepLabel, titleLabel, blurbLabel, bodyContainer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.translatesAutoresizingMaskIntoConstraints = false
        blurbLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        bodyContainer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        root.addSubview(column)
        root.addSubview(footer)
        let gutter = HelmMetrics.s5
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: gutter),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gutter),
            footer.topAnchor.constraint(greaterThanOrEqualTo: column.bottomAnchor, constant: HelmMetrics.s4),
        ])

        themeObservation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        render()
    }

    // MARK: Steps

    private func render() {
        stepLabel.stringValue = "STEP \(stepIndex + 1) OF \(steps.count)"
        titleLabel.stringValue = step.title
        blurbLabel.stringValue = step.blurb
        themeGrid.isHidden = step != .theme
        profileStack.isHidden = step != .profile
        commandWell.isHidden = step != .lock
        commandCopyButton.isHidden = step != .lock
        backButton.isHidden = stepIndex == 0
        nextButton.title = stepIndex == steps.count - 1 ? "Get started" : "Next"
        // On the last step, "Skip" would mean the same thing as the primary
        // action, and two buttons for one outcome is worse than one.
        skipButton.isHidden = stepIndex == steps.count - 1
        applyTheme(ThemeManager.shared.theme)
    }

    @objc private func nextTapped() {
        guard stepIndex + 1 < steps.count else {
            finish()
            return
        }
        stepIndex += 1
        render()
    }

    @objc private func backTapped() {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
        render()
    }

    @objc private func skipTapped() { finish() }

    /// However it closed, it closed. Marking it seen on *every* exit is the
    /// point: a captain who dismissed this has decided, and re-asking on the
    /// next launch would be the app overruling them.
    private func finish() {
        AppSettings.shared.hasSeenWelcome = true
        onFinish?()
        dismiss(self)
    }

    // MARK: Step bodies

    private func buildThemeGrid() {
        themeGrid.orientation = .vertical
        themeGrid.alignment = .leading
        themeGrid.spacing = HelmMetrics.s2
        themeGrid.translatesAutoresizingMaskIntoConstraints = false
        // The app's seven families, four to a row, each in the register the
        // app is in. Applied on click rather than on finish: a theme picker
        // that does not show you the theme is a list of words, and this app
        // already applies a theme instantly everywhere.
        let families = AppThemeFamily.allCases
        for chunk in stride(from: 0, to: families.count, by: 4) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = HelmMetrics.s2
            for family in families[chunk..<min(chunk + 4, families.count)] {
                let button = HelmButton(title: family.title, variant: .secondary, size: .small,
                                        target: self, action: #selector(themePicked(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(family.rawValue)
                themeButtons.append(button)
                row.addArrangedSubview(button)
            }
            themeGrid.addArrangedSubview(row)
        }
    }

    @objc private func themePicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let family = AppThemeFamily(rawValue: id) else { return }
        ThemeManager.shared.setTheme(family.register(ThemeManager.shared.theme.mode))
        render()
    }

    /// R2-UX-01 (b): one button per profile with its one-line summary under
    /// it. The choice applies on click, like the theme step's, and the install
    /// already started on Personal (`AppSettings.settleFirstLaunch`), so
    /// skipping keeps that.
    private func buildProfileChoice() {
        profileStack.orientation = .vertical
        profileStack.alignment = .leading
        profileStack.spacing = HelmMetrics.s3
        profileStack.translatesAutoresizingMaskIntoConstraints = false
        for profile in WorkspaceProfile.allCases {
            let button = HelmButton(title: profile.title, variant: .secondary,
                                    target: self, action: #selector(profilePicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(profile.rawValue)
            let caption = NSTextField(wrappingLabelWithString: profile.summary)
            caption.font = HelmType.caption()
            caption.identifier = NSUserInterfaceItemIdentifier("caption")
            let row = NSStackView(views: [button, caption])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = HelmMetrics.s1
            profileStack.addArrangedSubview(row)
            caption.widthAnchor.constraint(equalTo: profileStack.widthAnchor).isActive = true
            profileButtons.append((profile, button))
        }
    }

    @objc private func profilePicked(_ sender: NSButton) {
        guard let profile = sender.identifier.flatMap({ WorkspaceProfile(rawValue: $0.rawValue) }) else { return }
        AppSettings.shared.setProfile(profile)
        render()
    }

    private func buildCommandWell() {
        // The same string the lock screen shows, read from the same place -
        // a second copy is how the sheet and the lock screen would come to
        // disagree about what to run.
        commandWell.stringValue = VaultSource.appPasswordSetupCommand
        commandWell.font = HelmType.code()
        commandWell.isSelectable = true
        commandWell.lineBreakMode = .byTruncatingMiddle
        commandWell.translatesAutoresizingMaskIntoConstraints = false
        HelmField.makeSunken(commandWell)
        commandCopyButton.target = self
        commandCopyButton.action = #selector(copyCommandTapped)
        commandCopyButton.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func copyCommandTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(VaultSource.appPasswordSetupCommand, forType: .string)
        // GL-30 / UX14: a transient confirmation, on the surface that
        // produced it.
        Feedback.report("Copied", kind: .done, persistence: .transient, in: view)
    }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        blurbLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        stepLabel.textColor = HelmField.mutedInk(theme)
        commandWell.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        HelmField.applySunken(to: commandWell, theme: theme)
        // The chosen palette reads as chosen.
        for button in themeButtons {
            button.variant = button.identifier?.rawValue == theme.app?.family.rawValue ? .primary : .secondary
        }
        let chosen = WorkspaceProfile.matching(AppSettings.shared.hiddenModules)
        for (profile, button) in profileButtons { button.variant = profile == chosen ? .primary : .secondary }
        for case let row as NSStackView in profileStack.arrangedSubviews {
            for case let caption as NSTextField in row.arrangedSubviews { caption.textColor = HelmField.mutedInk(theme) }
        }
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    #if FM_SELFTESTS
    var debugStepIndex: Int { stepIndex }
    static var debugStepCount: Int { Step.steps(for: PlaceName.layout).count }
    var debugStepTitle: String { step.title }
    var debugProfileChoiceIsHidden: Bool { profileStack.isHidden }
    /// Pick a profile through its button's own target and action.
    func debugPickProfile(_ profile: WorkspaceProfile) {
        profileButtons.first { $0.profile == profile }?.button.performClick(nil)
    }
    func debugNext() { nextTapped() }
    func debugBack() { backTapped() }
    func debugSkip() { skipTapped() }
    var debugNextButtonTitle: String { nextButton.title }
    var debugBackIsHidden: Bool { backButton.isHidden }
    var debugCommandWellIsHidden: Bool { commandWell.isHidden }
    var debugThemeGridIsHidden: Bool { themeGrid.isHidden }
    #endif
}
