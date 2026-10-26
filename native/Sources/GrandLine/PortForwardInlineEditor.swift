// Grand Line - native macOS app.
//
// A host's port-forwarding rules, listed and edited inline (H6 of the
// captain's Termius-style plan). In the side panel the host form is the
// whole editor, so the rules are edited where they are listed rather than in
// a second pop-up. The floating bar's host window keeps
// `PortForwardingController`'s sheet.
//
// The panel is 320pt wide, so a rule is two lines rather than the sheet's
// one: the kind and a remove button, then where it listens and where it goes.
// "Listens on" takes `port` or `bind:port`, "Goes to" takes `host:port`, the
// same two halves `PortForwardRule.summary` reads back. A Dynamic (SOCKS)
// rule has no destination, so its second field steps out.
//
// Nothing here validates: the host form checks every rule on Save, with the
// sheet's own words, so a half-typed rule is never refused mid-keystroke.

import AppKit

final class PortForwardInlineEditor: NSView, NSTextFieldDelegate {

    /// Any rule changed, was added or was removed.
    var onChange: (() -> Void)?

    private let rowsStack = NSStackView()
    private var rows: [PortForwardInlineRow] = []
    private lazy var addButton = HelmButton(title: "Add Forward", variant: .secondary, size: .small,
                                            symbol: "plus", target: self, action: #selector(addClicked))

    init(rules: [PortForwardRule]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = HelmMetrics.s2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [rowsStack, addButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for rule in rules { addRow(rule) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The rules as typed, in order. A field that does not parse reads as 0
    /// or empty, which Save then refuses with its reason.
    var rules: [PortForwardRule] { rows.map(\.rule) }

    private func addRow(_ rule: PortForwardRule) {
        let row = PortForwardInlineRow(rule: rule)
        row.onChange = { [weak self] in self?.onChange?() }
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            self.rows.removeAll { $0 === row }
            self.rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            self.onChange?()
        }
        rows.append(row)
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    @objc private func addClicked() {
        addRow(PortForwardRule())
        onChange?()
        window?.makeFirstResponder(rows.last?.listenField)
    }

    // MARK: Parsing

    /// `"8080"` or `"127.0.0.1:8080"` (or `[::1]:8080`) as a bind address
    /// and a port. A port that does not parse is 0.
    static func parseListen(_ text: String) -> (bind: String, port: Int) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let colon = t.lastIndex(of: ":") else { return ("", Int(t) ?? 0) }
        return (String(t[..<colon]), Int(t[t.index(after: colon)...]) ?? 0)
    }

    /// `"localhost:80"` as a host and a port.
    static func parseDestination(_ text: String) -> (host: String, port: Int) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let colon = t.lastIndex(of: ":") else { return (t, 0) }
        return (String(t[..<colon]), Int(t[t.index(after: colon)...]) ?? 0)
    }

    #if FM_SELFTESTS
    var debugRows: [PortForwardInlineRow] { rows }
    var debugAddButton: HelmButton { addButton }
    #endif
}

/// One rule: the kind and a remove button, then "Listens on" and "Goes to".
final class PortForwardInlineRow: NSView, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    var onRemove: (() -> Void)?

    private let id: UUID
    private let kindPopup = HelmPopUpButton()
    let listenField = HelmTextField(placeholder: "8080 or 127.0.0.1:8080")
    let destinationField = HelmTextField(placeholder: "localhost:80")
    private lazy var removeButton = HelmButton(symbol: "minus.circle", variant: .quiet, size: .small,
                                               target: self, action: #selector(removeClicked))

    init(rule: PortForwardRule) {
        id = rule.id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for kind in PortForwardRule.Kind.allCases { kindPopup.addItem(withTitle: kind.displayName) }
        kindPopup.selectItem(at: PortForwardRule.Kind.allCases.firstIndex(of: rule.kind) ?? 0)
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        kindPopup.setAccessibilityLabel("Forward kind")
        listenField.stringValue = rule.bindAddress.isEmpty ? String(rule.listenPort) : "\(rule.bindAddress):\(rule.listenPort)"
        destinationField.stringValue = rule.destHost.isEmpty ? "" : "\(rule.destHost):\(rule.destPort)"
        listenField.setAccessibilityLabel("Listens on")
        destinationField.setAccessibilityLabel("Goes to")
        listenField.delegate = self
        destinationField.delegate = self
        removeButton.toolTip = "Remove this forward"
        removeButton.setAccessibilityLabel("Remove this forward")

        let head = NSStackView(views: [kindPopup, removeButton])
        head.orientation = .horizontal
        head.distribution = .fill
        head.spacing = HelmMetrics.s2
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        let fields = NSStackView(views: [listenField, destinationField])
        fields.orientation = .horizontal
        fields.distribution = .fillEqually
        fields.spacing = HelmMetrics.s2
        let stack = NSStackView(views: [head, fields])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        for view in [head, fields, stack] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fields.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        applyKind()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var kind: PortForwardRule.Kind {
        PortForwardRule.Kind.allCases[max(0, kindPopup.indexOfSelectedItem)]
    }

    var rule: PortForwardRule {
        var rule = PortForwardRule()
        rule.id = id
        rule.kind = kind
        let listen = PortForwardInlineEditor.parseListen(listenField.stringValue)
        rule.bindAddress = listen.bind
        rule.listenPort = listen.port
        if kind != .dynamic {
            let destination = PortForwardInlineEditor.parseDestination(destinationField.stringValue)
            rule.destHost = destination.host
            rule.destPort = destination.port
        }
        return rule
    }

    private func applyKind() {
        destinationField.isHidden = kind == .dynamic
    }

    @objc private func kindChanged() {
        applyKind()
        onChange?()
    }

    @objc private func removeClicked() { onRemove?() }

    func controlTextDidChange(_ obj: Notification) { onChange?() }

    #if FM_SELFTESTS
    var debugKindPopup: HelmPopUpButton { kindPopup }
    var debugRemoveButton: HelmButton { removeButton }
    #endif
}
