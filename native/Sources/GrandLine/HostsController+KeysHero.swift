// Grand Line - native macOS app.
//
// Connections' hero column on the Keys tab.
//
// C-4 put a `HelmHeroColumn` beside the host cards. The column is the page's,
// not the Hosts tab's, so before this it went on talking about live sessions
// and hosts online while the Keys tab showed. Now it speaks for the tab that
// is showing: on Keys it says whether Touch ID is ready and how many keys
// there are, its ring is the keys some host signs in with, its Recent list is
// the keys a host connected with most recently (each with a Copy pill), and
// in Quick connect's place is a way to add a key. The Keys, Snippets and
// Groups figures at its foot are the same on both tabs.
//
// Every action the column runs is the page's own - `copyToPasteboard`,
// `openNewKey` - so nothing here can copy or add a key differently from a
// card, a row or the toolbar's New Key.

import AppKit

/// What Connections' hero column says on the Keys tab, from the stores. A
/// pure value, asserted headless (`PageHeroColumnsSelfTest`).
struct KeysHeroWords: Equatable {

    struct Key: Equatable {
        let label: String
        /// Saved hosts that sign in with this key.
        let hostCount: Int
        let lastUsedAt: Date?
    }

    let headline: String
    let body: String
    /// Keys at least one saved host uses over saved keys, or `nil` with no
    /// saved key, or a `keys.json` that could not be read (GL-14).
    let ring: (inUse: Int, total: Int)?
    let ringCaption: String
    /// The column dims while the saved keys could not be read.
    let isDimmed: Bool

    static func == (a: KeysHeroWords, b: KeysHeroWords) -> Bool {
        a.headline == b.headline && a.body == b.body && a.ring?.inUse == b.ring?.inUse
            && a.ring?.total == b.ring?.total && a.ringCaption == b.ringCaption && a.isDimmed == b.isDimmed
    }

    static func make(keysReadable: Bool, keys: [Key], hostsWithAKey: Int, biometryAvailable: Bool,
                     now: Date = Date()) -> KeysHeroWords {
        guard keysReadable else {
            return KeysHeroWords(
                headline: "Saved keys could not be read.",
                body: "Your keys file is still on disk, and the private keys are still in the Keychain.",
                ring: nil, ringCaption: "", isDimmed: true)
        }
        guard !keys.isEmpty else {
            return KeysHeroWords(
                headline: "No saved keys yet.",
                body: "Generate a key, or import a PEM or OpenSSH one. Private key material stays in the macOS Keychain.",
                ring: nil, ringCaption: "", isDimmed: false)
        }
        let count = keys.count == 1 ? "1 key" : "\(keys.count) keys"
        let headline = biometryAvailable ? "Touch ID ready, \(count)." : "\(count.prefix(1).uppercased() + count.dropFirst()) in the Keychain."
        var body: String
        let used = keys.compactMap { key in key.lastUsedAt.map { (label: key.label, at: $0) } }
        if let last = used.max(by: { $0.at < $1.at }) {
            body = "\(last.label) was used \(HostsController.relativeText(last.at, now: now))."
        } else {
            body = "No host has connected with a key yet."
        }
        let unused = keys.filter { $0.hostCount == 0 }.count
        switch unused {
        case 0: break
        case 1: body += keys.count == 1 ? " No host uses it yet." : " 1 key is not used by any host."
        default: body += unused == keys.count ? " No host uses them yet." : " \(unused) keys are not used by any host."
        }
        let hosts = hostsWithAKey == 1 ? "1 host signs in with one" : "\(hostsWithAKey) hosts sign in with one"
        return KeysHeroWords(
            headline: headline, body: body,
            ring: (keys.count - unused, keys.count),
            ringCaption: "keys in use\n\(hosts)",
            isDimmed: false)
    }
}

extension HostsController {

    /// The column's three keys, as it has three hosts.
    static let heroRecentKeyLimit = 3

    /// Fill the column for the Keys tab. `renderHeroColumn` hands over to
    /// this while Keys shows.
    func renderKeysHeroColumn(_ column: HelmHeroColumn) {
        let keys = keyStore.keys
        let hosts = hostStore.hosts
        let words = KeysHeroWords.make(
            keysReadable: keyStore.loadStatus == .clean,
            keys: keys.map { key in
                .init(label: key.label, hostCount: hosts.filter { $0.keyID == key.id }.count, lastUsedAt: key.lastUsedAt)
            },
            hostsWithAKey: hosts.filter { host in host.keyID.map { keyStore.key(id: $0) != nil } ?? false }.count,
            biometryAvailable: CredentialVaultKeyStore.biometryAvailable)
        let ring = words.ring.map { ring in
            HelmHeroColumn.Ring(fraction: ring.total > 0 ? Double(ring.inUse) / Double(ring.total) : 0,
                                label: "\(ring.inUse)/\(ring.total)", caption: words.ringCaption,
                                spoken: "\(ring.inUse) of \(ring.total) saved keys used by a host", state: .ok)
        }
        // D-03: once an expiry check has run, the hero leads with it.
        let expiry = expiryHeroWords()
        let header = HelmHeroColumn.Header(symbol: "key.fill", kicker: "Keys",
                                           headline: expiry?.headline ?? words.headline,
                                           body: expiry?.body ?? words.body, ring: expiry?.ring ?? ring)

        heroRecentRuns = []
        func pill(title: String, symbol: String, toolTip: String, run: @escaping () -> Void) -> HelmButton {
            let button = HelmButton(title: title, variant: .secondary, size: .small, symbol: symbol,
                                    target: self, action: #selector(heroRecentTapped(_:)))
            heroRecentRuns.append(run)
            button.tag = heroRecentRuns.count - 1
            button.toolTip = toolTip
            button.setAccessibilityLabel(toolTip)
            return button
        }
        let recent = Self.recentKeys(keys, limit: Self.heroRecentKeyLimit)
        var recentRows: [NSView] = recent.map { key in
            let copy = pill(title: "", symbol: "doc.on.doc", toolTip: "Copy \(key.label)'s public key") {
                copyToPasteboard(key.publicKey)
            }
            return HelmHeroRow(leading: .symbol("key.fill"), title: key.label,
                               subtitle: Self.lastUsedText(key.lastUsedAt),
                               trailing: copy)
        }
        if recentRows.isEmpty {
            recentRows = [HelmHeroRow(leading: .symbol("clock"), title: "Nothing yet",
                                      subtitle: "Keys used to connect show here.")]
        }
        // Quick connect's place: the two commonest ways in from K2's menu,
        // each straight to its form.
        let generate = pill(title: "Generate", symbol: "wand.and.stars", toolTip: "Generate an Ed25519 key") { [weak self] in
            self?.openNewKey(preset: .generate(.ed25519))
        }
        let importKey = pill(title: "Import", symbol: "doc.badge.plus", toolTip: "Import a key file") { [weak self] in
            self?.openNewKey(preset: .importFile)
        }
        let addRow = NSStackView(views: [generate, importKey])
        addRow.orientation = .horizontal
        addRow.spacing = HelmMetrics.s2
        addRow.distribution = .fillEqually
        addRow.setAccessibilityLabel("Add a key")

        column.configure(
            header: header,
            sections: (expiryHeroRows().isEmpty ? [] : [
                HelmHeroColumn.Section(title: "Next to expire", trailing: nil, views: expiryHeroRows()),
            ]) + [
                .init(title: "Recent keys", trailing: recent.isEmpty ? nil : "\(recent.count)", views: recentRows),
                .init(title: "Add a key", trailing: nil, views: [addRow]),
            ],
            foot: [heroFootFigures()],
            tone: HelmModuleCard.HeroTone(colour: .themeAccent, isDimmed: words.isDimmed))
    }
}
