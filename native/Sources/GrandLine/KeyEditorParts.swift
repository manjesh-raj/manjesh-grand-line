// Grand Line - native macOS app.
//
// Key-1 of the Console / Add Host / Add Key board: the key form asks how the
// key is being added before it asks anything else, and offers a third way in
// beside Generate and Import - a key pair that is already in ~/.ssh.
//
//   - `KeyPathChoices`: the three ways in, as rows the form's mode follows.
//   - `SSHKeyDirectoryScan`: what is in ~/.ssh. It reads only the `.pub`
//     files, and only lists a pair whose private file sits beside it. The
//     private file is read later, when one is picked, through the same
//     verification Import uses. Nothing here touches the Keychain, and
//     reading a folder in the home directory needs no privacy grant, so the
//     list can never raise a prompt.

import AppKit
import CryptoKit

// MARK: - KeyPathChoices

final class KeyPathChoices: NSView {
    enum Path: String, CaseIterable {
        case generate
        case importKey = "import"
        case existing
    }

    var onSelect: ((Path) -> Void)?
    private(set) var selected: Path = .generate
    private var rows: [(path: Path, view: HoverHighlightView, icon: NSImageView, iconBox: NSView,
                        title: NSTextField, detail: NSTextField, badge: NSTextField?)] = []
    private var observation: ThemeObservation?

    static func words(for path: Path) -> (title: String, detail: String, symbol: String, isNew: Bool) {
        switch path {
        case .generate:
            return ("Generate a new key", "Ed25519 by default, made on this Mac with ssh-keygen.", "wand.and.stars", false)
        case .importKey:
            return ("Import a key file or paste one", "PEM or OpenSSH. Drop a file, choose one, or paste it.",
                    "square.and.arrow.down", false)
        case .existing:
            return ("Use a key from ~/.ssh", "Pick one of the key pairs already on this Mac.", "folder", true)
        }
    }

    init(paths: [Path] = Path.allCases) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1 + 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for path in paths {
            let words = Self.words(for: path)
            let row = HoverHighlightView()
            row.wantsLayer = true
            row.translatesAutoresizingMaskIntoConstraints = false
            row.identifier = NSUserInterfaceItemIdentifier("key-path-\(path.rawValue)")
            let iconBox = NSView()
            iconBox.wantsLayer = true
            iconBox.layer?.cornerRadius = 8
            iconBox.translatesAutoresizingMaskIntoConstraints = false
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: words.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: HelmType.scaled(13), weight: .medium))
            icon.translatesAutoresizingMaskIntoConstraints = false
            iconBox.addSubview(icon)
            let title = NSTextField(labelWithString: words.title)
            title.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detail = NSTextField(wrappingLabelWithString: words.detail)
            detail.font = HelmType.caption()
            detail.maximumNumberOfLines = 2
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 0
            text.translatesAutoresizingMaskIntoConstraints = false
            var badge: NSTextField?
            var views: [NSView] = [iconBox, text]
            if words.isNew {
                let label = NSTextField(labelWithString: "NEW")
                label.font = .systemFont(ofSize: HelmType.scaled(9), weight: .heavy)
                label.wantsLayer = true
                label.setContentHuggingPriority(.required, for: .horizontal)
                label.setContentCompressionResistancePriority(.required, for: .horizontal)
                views.append(label)
                badge = label
            }
            let line = NSStackView(views: views)
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = HelmMetrics.s2 + 2
            line.distribution = .fill
            line.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(line)
            NSLayoutConstraint.activate([
                iconBox.widthAnchor.constraint(equalToConstant: 30),
                iconBox.heightAnchor.constraint(equalToConstant: 30),
                icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
                line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                line.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
                line.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9),
                // The detail wraps against the row's own width less the icon,
                // the gaps and the badge - never against its own resolved
                // width (AGENTS.md gotcha (22)).
                detail.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, constant: -90),
            ])
            detail.preferredMaxLayoutWidth = HelmFormSheet.width
            row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:))))
            row.accessibilityRoleOverride = .radioButton
            row.accessibilityLabelOverride = words.title
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append((path, row, icon, iconBox, title, detail, badge))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("How to add the key")
        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
    }

    override func layout() {
        super.layout()
        for row in rows {
            let width = max(120, row.view.bounds.width - 90)
            guard abs(row.detail.preferredMaxLayoutWidth - width) > 0.5 else { continue }
            row.detail.preferredMaxLayoutWidth = width
            row.detail.invalidateIntrinsicContentSize()
        }
    }

    func select(_ path: Path) {
        selected = path
        applyTheme(ThemeManager.shared.theme)
    }

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let row = rows.first(where: { $0.view === sender.view }) else { return }
        select(row.path)
        onSelect?(row.path)
    }

    func applyTheme(_ theme: HelmTheme) {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let fill = HelmField.fill(theme, surface: .raised)
        for row in rows {
            let chosen = row.path == selected
            row.view.normalColor = fill
            row.view.hoverColor = fill.hoverShifted(by: 0.06, forMode: theme.mode)
            row.view.cornerRadius = HelmMetrics.rCard
            row.view.layer?.borderWidth = chosen ? 1.5 : 1
            row.view.layer?.borderColor = (chosen ? accent : HelmField.border(theme, surface: .raised)).cgColor
            row.view.accessibilityValueOverride = chosen ? "selected" : "not selected"
            row.iconBox.layer?.backgroundColor = (chosen ? accent : accent.withAlphaComponent(0.12)).cgColor
            row.icon.contentTintColor = chosen ? HelmContrast.legibleGlyph(over: accent) : accent
            row.title.textColor = HelmField.ink(theme, surface: .raised)
            row.detail.textColor = HelmField.mutedInk(theme, surface: .raised)
            row.badge?.textColor = accent
        }
    }

    #if FM_SELFTESTS
    func debugClick(_ path: Path) {
        _ = rows.first { $0.path == path }?.view.performPrimaryAction()
    }
    var debugTitles: [String] { rows.map(\.title.stringValue) }
    #endif
}

// MARK: - SSHKeyDirectoryScan

/// One key pair found in a folder: a private key with its `.pub` beside it.
struct LocalKeyPair: Equatable {
    let name: String
    let privateKeyURL: URL
    /// "Ed25519", "RSA", "ECDSA" or the raw algorithm name.
    let typeName: String
    /// `SHA256:` and the base64 digest, as `ssh-keygen -l` prints it.
    let fingerprint: String
    let comment: String
}

enum SSHKeyDirectoryScan {
    /// Where the "From ~/.ssh" path looks. `FM_SSH_DIR` moves it (the probe
    /// and the self-tests point it at a fixture folder); a scratch-redirected
    /// process that did not set it looks under its scratch root, so a probe
    /// can never list the real folder's key names.
    static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["FM_SSH_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if AppPaths.isScratchRedirected(environment) {
            return AppPaths.dataRoot(environment: environment).appendingPathComponent("ssh", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Every pair in `directory`, by name. A `.pub` with no private file
    /// beside it, or one that does not parse as a public key line, is left
    /// out. `nil` when the folder could not be read at all, which is not the
    /// same as an empty folder (GL-21).
    static func scan(_ directory: URL, fileManager: FileManager = .default) -> [LocalKeyPair]? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
        var pairs: [LocalKeyPair] = []
        for name in names.sorted() where name.hasSuffix(".pub") {
            let base = String(name.dropLast(4))
            let privateURL = directory.appendingPathComponent(base)
            var isDirectory: ObjCBool = false
            guard !base.isEmpty, fileManager.fileExists(atPath: privateURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let line = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
                  let parsed = parsePublicKeyLine(line) else { continue }
            pairs.append(LocalKeyPair(name: base, privateKeyURL: privateURL, typeName: displayType(parsed.algorithm),
                                      fingerprint: fingerprint(of: parsed.blob), comment: parsed.comment))
        }
        return pairs
    }

    /// `<algorithm> <base64 blob> [comment]`, the one line a `.pub` holds.
    static func parsePublicKeyLine(_ text: String) -> (algorithm: String, blob: Data, comment: String)? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 2, let blob = Data(base64Encoded: fields[1]), !blob.isEmpty else { return nil }
        return (fields[0], blob, fields.count > 2 ? fields[2] : "")
    }

    static func fingerprint(of blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static func displayType(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": return SSHKeyType.ed25519.displayName
        case "ssh-rsa": return SSHKeyType.rsa.displayName
        case let name where name.hasPrefix("ecdsa-"): return "ECDSA"
        case let name where name.hasPrefix("sk-"): return "Security key"
        default: return algorithm
        }
    }
}
