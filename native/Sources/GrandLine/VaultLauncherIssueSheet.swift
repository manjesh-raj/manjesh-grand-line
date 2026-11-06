// Grand Line - native macOS app.
//
// What `av doctor --json` said about one launcher, shown on the Secrets page
// (the Automic Vault half). The page used to keep only the issue count, so a
// "1 issue found" row had nothing behind it and the captain had to run
// `av doctor` in a terminal to learn what was wrong.
//
// Everything here is metadata Automic Vault reported about a launcher - a
// kind, a sentence, two paths and its own fix steps. Never a secret value.
//
// **Nothing on this sheet runs a command.** The fix steps carry `av harden`,
// which writes a launcher, so they are shown and copied and nothing else: the
// captain pastes them into a terminal they opened. Re-check is the one action,
// and it is `av doctor <tool> --json`, the read-only call that is safe to run
// unattended (`VaultSource.recheckTool`).

import AppKit

final class VaultLauncherIssueSheetController: NSViewController {
    private var themeObservation: ThemeObservation?

    private let tool: VaultTool
    var onRecheck: (() -> Void)?

    private var wells: [NSView] = []
    private var copyButtons: [HelmButton] = []

    init(tool: VaultTool) {
        self.tool = tool
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        view = root
        let theme = ThemeManager.shared.theme
        root.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)

        let title = NSTextField(labelWithString: "\(tool.name) - what the doctor found")
        title.font = .systemFont(ofSize: HelmType.scaled(14), weight: .semibold)

        let sections: [NSView] = tool.issues.isEmpty
            ? [wrapping("Automic Vault reported \(tool.status.label.lowercased()) for this launcher but gave no detail. Run \u{201c}av doctor \(tool.name)\u{201d} in a terminal to read it.",
                        font: HelmType.body(), muted: false)]
            : tool.issues.map(issueSection)

        let close = HelmButton(title: "Close", variant: .secondary, target: self, action: #selector(closeTapped))
        close.keyEquivalent = "\u{1b}"
        let recheck = HelmButton(title: "Re-check", variant: .primary, target: self, action: #selector(recheckTapped))
        recheck.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spacer, close, recheck])
        bottom.orientation = .horizontal
        bottom.spacing = HelmMetrics.s3

        let stack = NSStackView(views: [title] + sections + [bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for section in sections { section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            for well in self?.wells ?? [] { HelmField.applySunken(to: well, theme: theme) }
        }
    }

    private func issueSection(_ issue: VaultToolIssue) -> NSView {
        let theme = ThemeManager.shared.theme
        let kind = NSTextField(labelWithString: issue.kind)
        kind.font = HelmType.code()
        kind.textColor = HelmTheme.mutedInk(theme)
        kind.isSelectable = true

        var views: [NSView] = [kind]
        if !issue.message.isEmpty { views.append(wrapping(issue.message, font: HelmType.body(), muted: false)) }
        for (label, path) in [("Launcher", issue.stubPath), ("Recorded target", issue.targetPath)] {
            guard let path else { continue }
            views.append(wrapping("\(label): \(path)", font: HelmType.code(), muted: true))
        }
        if !issue.remediation.isEmpty {
            views.append(wrapping(issue.remediation, font: HelmType.body(), muted: true))
        }
        for command in issue.commands { views.append(commandWell(command)) }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        for view in views where view !== kind { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func wrapping(_ text: String, font: NSFont, muted: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.isSelectable = true
        label.textColor = muted ? HelmTheme.mutedInk(ThemeManager.shared.theme) : HelmField.ink(ThemeManager.shared.theme)
        label.preferredMaxLayoutWidth = 480
        return label
    }

    /// The one sunken code recipe, with a Copy button. Copy is a plain
    /// pasteboard write: a fix command is not a secret, and this is the same
    /// treatment the lock screen gives `av save`.
    private func commandWell(_ command: String) -> NSView {
        let label = NSTextField(labelWithString: command)
        label.font = HelmType.code()
        label.textColor = HelmField.ink(ThemeManager.shared.theme)
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let button = HelmButton(title: "Copy", variant: .secondary, size: .small, target: self, action: #selector(copyTapped(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(command)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyButtons.append(button)

        let well = NSStackView(views: [label, button])
        HelmField.makeSunken(well)
        well.orientation = .horizontal
        well.alignment = .centerY
        well.spacing = HelmMetrics.s2
        well.distribution = .fill
        well.edgeInsets = NSEdgeInsets(top: 8, left: 13, bottom: 8, right: 9)
        HelmField.applySunken(to: well, theme: ThemeManager.shared.theme)
        wells.append(well)
        return well
    }

    @objc private func copyTapped(_ sender: HelmButton) {
        guard let command = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak sender] in sender?.title = "Copy" }
    }

    @objc private func recheckTapped() {
        onRecheck?()
        dismiss(self)
    }

    @objc private func closeTapped() { dismiss(self) }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    // MARK: Test seams

    #if FM_SELFTESTS
    var debugCommandTexts: [String] { tool.issues.flatMap(\.commands) }
    func debugClickCopy(at index: Int) { copyButtons[index].performClick(nil) }
    func debugClickRecheck() { onRecheck?() }
    #endif
}
