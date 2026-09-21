// Manjesh Grand Line - native macOS app.
//
// "Which runners does this machine have?" - the reviewed F11 mockup's
// `Runners found` list, as a popover.
//
// ## Why a popover and not a sidebar
//
// The mockup draws this as a sidebar section under a list of snippets. This
// page has no such sidebar: its snippets are tab chips along the toolbar
// (`CodePreviewController`'s header explains why the chrome is AppKit and why
// the tabs are chips), so there is no column to add a section to. Building one
// would cost the editor ~180pt of width permanently, to show a list that
// answers a question asked once per machine.
//
// So the information is kept verbatim and the container changes: one row per
// runnable language, a signal dot, the interpreter's name and version, and
// `absent` where there is none - which is the mockup's own `ruby · absent`
// row. It is the same treatment `HelmRefreshPill`'s freshness detail gets:
// permanent where it is glanced at, one click away where it is consulted.
//
// GL-14 is the rule that decides what an absent row says. "This app cannot run
// Python" and "Python is not installed on this machine" are different
// sentences, and only the second one is true - so the row is present, marked
// absent, and names the interpreter that would have run it.

import AppKit

final class CodeRunnersPopoverView: NSView {

    /// Wide enough for the longest language name beside a version string
    /// without the popover resizing itself per machine.
    static let width: CGFloat = 320

    private let theme: HelmTheme

    init(runners: [(languageID: String, presence: CodeToolPresence)],
         currentLanguage: CodePreviewLanguage,
         formatter: CodeToolPresence?,
         theme: HelmTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(sectionLabel("RUNNERS ON THIS MACHINE"))
        for entry in runners {
            let name = CodePreviewLanguage.named(entry.languageID)?.displayName ?? entry.languageID
            stack.addArrangedSubview(row(title: name, presence: entry.presence))
        }

        stack.addArrangedSubview(spacerRow())
        stack.addArrangedSubview(sectionLabel("FORMATTER FOR \(currentLanguage.displayName.uppercased())"))
        if let formatter {
            stack.addArrangedSubview(row(title: formatter.tool.displayName, presence: formatter))
        } else {
            stack.addArrangedSubview(
                noteLabel(CodeRunner.noFormatterMessage(for: currentLanguage.id)))
        }

        stack.addArrangedSubview(spacerRow())
        // The sandbox is stated here as well as in the pane, because this is
        // the surface a captain opens *before* pressing Run for the first
        // time - which is when they would want to know what it does.
        stack.addArrangedSubview(noteLabel(Self.sandboxNote))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s3),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// What a run is actually confined to, in the words the file header and
    /// the PR use - one wording, so the three cannot drift apart.
    static let sandboxNote = """
        A run happens in a fresh temporary directory under \
        \(CodeSandbox.sandboxExecPath.split(separator: "/").last.map(String.init) ?? "sandbox-exec"), \
        with the network denied, writes denied outside that directory, your home directory \
        unreadable, none of this app's environment inherited, and a \
        \(Int(CodeRunner.wallClock))-second wall clock. It is not a virtual machine: reads \
        elsewhere on the disk still work, and the interpreter runs as you.
        """

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.kicker()
        label.textColor = HelmTheme.mutedInk(theme)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = HelmType.captionSmall()
        label.textColor = HelmTheme.mutedInk(theme)
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = Self.width - 2 * HelmMetrics.s3
        return label
    }

    private func spacerRow() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        // A real height, not a hugging priority: gotcha (12) - a bare `NSView`
        // has no intrinsic size, so a priority on it does nothing at all.
        view.heightAnchor.constraint(equalToConstant: HelmMetrics.s2).isActive = true
        return view
    }

    private func row(title: String, presence: CodeToolPresence) -> NSView {
        let dot = HelmSignalDot()
        dot.configure(tint: presence.isPresent ? .good : .neutral, theme: theme)

        let name = NSTextField(labelWithString: title)
        name.font = HelmType.body()
        name.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.required, for: .horizontal)

        let detail = NSTextField(labelWithString: Self.detail(for: presence))
        detail.font = HelmType.code()
        detail.textColor = HelmTheme.mutedInk(theme)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingHead

        let row = NSStackView(views: [dot, name, detail])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        // Gotcha (10): the distribution is set explicitly, and only the detail
        // column is allowed to flex - the default `.gravityAreas` has no
        // "who grows" rule at all, which is what makes a column of these rows
        // ragged.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.widthAnchor.constraint(equalToConstant: Self.width - 2 * HelmMetrics.s3).isActive = true
        return row
    }

    /// The right-hand column: a version where there is one, the honest
    /// alternative where there is not.
    static func detail(for presence: CodeToolPresence) -> String {
        guard presence.isPresent else { return "\(presence.tool.tool) \u{00B7} absent" }
        guard let version = presence.version else { return "\(presence.tool.tool) \u{00B7} installed" }
        return "\(presence.tool.tool) \(version)"
    }
}
