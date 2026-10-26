// Grand Line - native macOS app.
//
// `HostsController`'s floating-bar presentation (R2-ARCH-04): the page's own column with the keychain card, the stat strip's side panels, the detail column and the list rows the floating bar draws for hosts, keys and snippets.
//
// The floating bar is the classic layout, frozen by R2-ARCH-01: it gets
// fixes but no new features and no page redesigns. So the members only its
// presentation uses live here, moved verbatim out of `HostsController.swift`, and
// that file carries the presentation the sidebar layout draws. A member both
// layouts use stays there. Swift's `private` is file-scoped, so the few
// members this file and the main one share lost `private`; treat this pair
// as one type's private parts (GL-36). `ClassicPresentationSelfTest` fails if
// one of these members moves back.

import AppKit

extension HostsController {

    /// Row ids. The three WORKSPACE rows reuse `HostsTab`'s own raw values, so
    /// the sidebar and the tab strip are keyed by one vocabulary and a switch
    /// from either control resolves to the same `HostsTab` - that shared key is
    /// what makes them one mechanism rather than two controls that have to be
    /// remembered to agree.
    private static let activityRowID = "tools.activity"

    private static let commandsRowID = "tools.commands"

    func buildSidebar() {
        sidebar.appendHeader("Workspace")
        for tab in HostsTab.allCases {
            // UI1: `showsCount: false`. These rows used to carry a count badge
            // each, which - with the Workspace panel's inventory tiles two
            // columns over, the card header's own "Hosts (3)" and the drill
            // subtitle - made three the fourth statement of one number on one
            // screen. The count is stated once, by the panel whose subtitle is
            // literally "At-a-glance inventory"; these rows are navigation.
            sidebar.appendRow(id: tab.rawValue, symbol: Self.sidebarSymbol(for: tab),
                              title: tab.title, showsCount: false)
        }
        sidebar.appendSpacer()
        sidebar.appendHeader("Tools")
        // **Actions, not filters**: neither narrows the list below, so neither
        // may latch selected - a row that stayed lit would claim the list had
        // been filtered to something (`HelmPageSidebar.RowKind`).
        sidebar.appendRow(id: Self.activityRowID, symbol: "clock.arrow.circlepath",
                          title: "Activity", kind: .action, showsCount: false)
        sidebar.appendRow(id: Self.commandsRowID, symbol: "list.bullet.rectangle",
                          title: "Commands", kind: .action, showsCount: false)
        sidebar.select(activeTab.rawValue)

        sidebar.onSelect = { [weak self] id in
            guard let self else { return }
            switch id {
            case Self.activityRowID: self.onOpenActivity?()
            case Self.commandsRowID: self.onOpenCommands?()
            default:
                guard let tab = HostsTab(rawValue: id) else { return }
                self.select(tab: tab)
            }
        }

        userRow.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        userRow.onLogout = { [weak self] in self?.onLogout?() }

        let footer = NSStackView(views: [keychainCard, userRow])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = HelmMetrics.s2
        footer.translatesAutoresizingMaskIntoConstraints = false
        for row in [keychainCard, userRow] as [NSView] {
            row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        sidebar.setFooter(footer)
    }

    /// Each row takes the glyph its own card header already uses, so one
    /// concept is not drawn two ways a column apart.
    private static func sidebarSymbol(for tab: HostsTab) -> String {
        switch tab {
        case .hosts: return "server.rack"
        case .keys: return "key.fill"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The keychain card, from the same stores the lists render and the same
    /// biometry probe the Workspace panel reads - so the two columns either
    /// side of the page can never disagree within a frame.
    ///
    /// UI1: no `setCounts` any more. See `buildSidebar`.
    func refreshSidebar() {
        let hosts = hostStore.hosts
        keychainCard.setState(keys: keyStore.keys.count,
                              hostsOnManagedKeys: hosts.filter { $0.keyID != nil }.count,
                              hosts: hosts.count,
                              touchIDAvailable: CredentialVaultKeyStore.biometryAvailable)
    }

    func buildSidePanels() {
        // Each list reports its own selection; the detail panel re-fills from
        // whichever tab is showing, so a stale selection on a hidden tab can
        // never be what the panel displays.
        hostsList.onSelectRecord = { [weak self] _ in self?.refreshDetailPanel() }
        keysList.onSelectRecord = { [weak self] _ in self?.refreshDetailPanel() }
        snippetsList.onSelectRecord = { [weak self] _ in self?.refreshDetailPanel() }

        // Every one of these is a real, bound menu item in `main.swift` -
        // the brief's own rule, and why the reference's `⌘ ↵ Connect selected`
        // and `⌘ ⇧ P Run snippet` are absent rather than drawn inert.
        quickActionsPanel.setItems([
            .init(shortcut: "\u{2318}K", title: "Command palette") { [weak self] in
                self?.onOpenCommandPalette?()
            },
            .init(shortcut: "\u{2318}\u{2303}N", title: "Add host") { [weak self] in self?.newHost() },
            .init(shortcut: "\u{2318}\u{21E7}N", title: "New key") { [weak self] in self?.newKey() },
            .init(shortcut: "\u{2318}\u{2325}N", title: "New snippet") { [weak self] in self?.newSnippet() },
        ])

        sideStack.expansion.onToggle = { [weak self] isOn in
            self?.onSnippetExpansionToggled?(isOn)
            self?.refreshExpansionPanel()
        }
        sideStack.expansion.onRequestPermission = { [weak self] in
            self?.onRequestAccessibilityTrust?()
            self?.refreshExpansionPanel()
        }
    }

    func currentDetail() -> HostsDetailContent? {
        switch activeTab {
        case .hosts:
            guard let key = hostsList.selectedRecordKey,
                  let id = UUID(uuidString: key),
                  let host = hostStore.host(id: id) else { return nil }
            return detail(for: host)
        case .keys:
            guard let key = keysList.selectedRecordKey,
                  let id = UUID(uuidString: key),
                  let sshKey = keyStore.key(id: id) else { return nil }
            return detail(for: sshKey)
        case .snippets:
            guard let key = snippetsList.selectedRecordKey,
                  let id = UUID(uuidString: key),
                  let snippet = snippetStore.snippet(id: id) else { return nil }
            return detail(for: snippet)
        }
    }

    /// The reference's Environment / Endpoint / User / Credential list, read
    /// straight off the saved `Host` - nothing here is derived or invented.
    private func detail(for host: Host) -> HostsDetailContent {
        var fields: [HostsDetailContent.Field] = [
            .init("Environment", Self.roleKicker(for: host)),
            .init("Endpoint", host.port == 22 ? host.address : "\(host.address):\(host.port)", isCode: true),
            .init("User", host.username.isEmpty ? "\u{2014}" : host.username),
            .init("Credential", credentialName(for: host)),
        ]
        if let jump = host.jumpVia?.trimmingCharacters(in: .whitespacesAndNewlines), !jump.isEmpty {
            fields.append(.init("Jump via", jump))
        }
        if !host.portForwards.isEmpty {
            fields.append(.init("Forwards", "\(host.portForwards.count)"))
        }
        let session = liveSession?(host.id)
        if let session { fields.append(.init("Session", session.stateText)) }

        var actions: [HostsListSection.Action] = []
        if session != nil {
            actions.append(.init(title: "Switch", symbol: "arrow.right.circle.fill") { [weak self] in
                self?.onSwitchToSession?(host.id)
            })
        } else {
            actions.append(.init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.connect(host) })
        }
        actions.append(.init(title: "Edit\u{2026}", symbol: "pencil") { [weak self] in self?.onAddOrEdit?(host) })

        return HostsDetailContent(symbol: host.iconSymbol,
                                  tint: .accent,
                                  tintHex: host.accentHex,
                                  kicker: Self.roleKicker(for: host),
                                  title: host.label,
                                  subtitle: host.subtitle,
                                  fields: fields,
                                  actions: actions)
    }

    private func detail(for key: SSHKey) -> HostsDetailContent {
        let usedBy = hostStore.hosts.filter { $0.keyID == key.id }.count
        var fields: [HostsDetailContent.Field] = [
            .init("Type", key.type.displayName),
            .init("Fingerprint", key.fingerprint, isCode: true),
            .init("Passphrase", key.hasPassphrase ? "In Keychain" : "None"),
            .init("Used by", usedBy == 1 ? "1 host" : "\(usedBy) hosts"),
        ]
        if key.certificate?.isEmpty == false { fields.append(.init("Certificate", "Present")) }
        return HostsDetailContent(symbol: "key.fill",
                                  tint: key.type.tint,
                                  kicker: key.type.displayName,
                                  title: key.label,
                                  subtitle: "Private key material stays in the macOS Keychain.",
                                  fields: fields,
                                  actions: [
                                    .init(title: "Edit", symbol: "pencil") { [weak self] in
                                        self?.presentKeyEditor(for: key)
                                    },
                                    .init(title: "Copy key", symbol: "doc.on.doc") {
                                        copyToPasteboard(key.publicKey)
                                    },
                                  ])
    }

    private func detail(for snippet: Snippet) -> HostsDetailContent {
        let lines = snippet.command.split(separator: "\n", omittingEmptySubsequences: false).count
        var fields: [HostsDetailContent.Field] = [
            .init("Command", snippet.subtitle, isCode: true),
            .init("Lines", "\(lines)"),
        ]
        // F12. Stated as three separate readings rather than one sentence,
        // because they fail independently: a snippet can have a trigger and
        // be Console-only, or be system-wide with an exclusion that is why it
        // did not fire in the app the captain was just in.
        fields.append(.init("Trigger", snippet.triggerDisplay ?? "None", isCode: snippet.triggerDisplay != nil))
        if snippet.triggerDisplay != nil {
            fields.append(.init("Where", snippet.scope.title))
            if !snippet.excludedApps.isEmpty {
                fields.append(.init("Never in", snippet.excludedApps.joined(separator: ", ")))
            }
        }
        return HostsDetailContent(symbol: "chevron.left.forwardslash.chevron.right",
                                  tint: .info,
                                  kicker: snippet.triggerDisplay ?? "Snippet",
                                  title: snippet.label,
                                  subtitle: snippet.expandsSystemWide
                                      ? "Expands wherever you type it, and runs in a terminal tab."
                                      : "Sent to the active terminal tab, then Enter.",
                                  fields: fields,
                                  actions: [
                                    .init(title: "Run", symbol: "play.fill") { [weak self] in
                                        self?.onRunSnippet?(snippet)
                                    },
                                    .init(title: "Edit\u{2026}", symbol: "pencil") { [weak self] in
                                        self?.presentSnippetEditor(for: snippet)
                                    },
                                  ])
    }

    /// The permanent, non-deletable first row. It has no `Host` behind it, so
    /// it can only be connected to - no edit, duplicate or delete. Its glyph
    /// is `sailboat`, the mark this app already uses for itself (and not
    /// `anchor`, which is not an SF Symbol on macOS at all and so rendered as
    /// nothing for as long as this row existed - fixed in Phase 0).
    func pinnedItem() -> HostsListSection.Item {
        var item = HostsListSection.Item(content: .init(tint: .accent,
                                                        kicker: "Built-in",
                                                        title: "Firstmate",
                                                        meta: "Shell",
                                                        badgeSymbol: "sailboat"))
        item.primary = .init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.onConnectPinned?() }
        item.activate = { [weak self] in self?.onConnectPinned?() }
        return item
    }

    func hostItem(_ host: Host) -> HostsListSection.Item {
        var content = HelmAccentRow.Content(tint: .accent,
                                            kicker: Self.roleKicker(for: host),
                                            title: host.label,
                                            meta: host.subtitle,
                                            badgeSymbol: host.iconSymbol)
        // A host's accent is picked per host in the host editor, so it is a
        // literal hue rather than a semantic `HelmTint` - see
        // `HelmAccentRow.Content.tintHex`. Together with the role kicker
        // above, that is the prototype's "PREPROD / PROD / CI" row: the bar
        // and badge carry the captain's own colour for that host, the kicker
        // names the role.
        content.tintHex = host.accentHex
        // The first tag is the kicker now, so the chip only carries what the
        // kicker could not - "+2 more". A chip repeating the kicker was the
        // same signal twice.
        if host.tags.count > 1 {
            content.chipText = "+\(host.tags.count - 1) more"
        }
        // `fm/grandline-session-switcher`, item 1: a host that already has a
        // live session reads as connected and its headline action resumes that
        // session rather than looking identical to a fresh connect. The chip
        // carries it (`chipTint: .good`) rather than a new component or a
        // hand-coloured meta line - `ToolRowLayout.pill` behind it is the app's
        // one contrast-corrected chip, so this is legible in all 14 palettes
        // without this page picking a green of its own.
        let session = liveSession?(host.id)
        if let session {
            // Audit 2 §4.6: `stateText` rather than an unconditional
            // "Connected", so an F2-restored page the captain has not opened
            // yet says so instead of claiming a connection it does not have.
            content.chipText = session.stateText
            content.chipTint = .good
        }
        var item = HostsListSection.Item(content: content)
        item.recordKey = host.id.uuidString
        if session != nil {
            item.primary = .init(title: "Switch to session", symbol: "arrow.right.circle.fill") { [weak self] in
                self?.onSwitchToSession?(host.id)
            }
            item.activate = { [weak self] in self?.onSwitchToSession?(host.id) }
        } else {
            item.primary = .init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.connect(host) }
            item.activate = { [weak self] in self?.connect(host) }
        }
        var overflow: [HostsListSection.Action] = []
        if session != nil {
            // The one place a captain can end the session they are *currently
            // looking at* - the strip's own ✕ deliberately never appears on the
            // active pill, so a mis-click cannot close it (mockup callout c).
            overflow.append(.init(title: "End Session") { [weak self] in self?.onEndSession?(host.id) })
        }
        overflow += [
            .init(title: "Edit…") { [weak self] in self?.onAddOrEdit?(host) },
            .init(title: "Duplicate…") { [weak self] in self?.duplicate(host) },
            .init(title: "Delete") { [weak self] in self?.confirmDeleteHost(host) },
        ]
        item.overflow = overflow
        return item
    }

    func keyItem(_ key: SSHKey) -> HostsListSection.Item {
        var content = HelmAccentRow.Content(tint: key.type.tint,
                                            kicker: key.type.displayName,
                                            title: key.label,
                                            meta: key.fingerprint,
                                            badgeSymbol: "key.fill")
        content.metaIsCode = true
        if key.hasPassphrase { content.chipText = "Passphrase" }
        var item = HostsListSection.Item(content: content)
        item.recordKey = key.id.uuidString
        item.primary = .init(title: "Edit", symbol: "pencil") { [weak self] in self?.presentKeyEditor(for: key) }
        item.activate = { [weak self] in self?.presentKeyEditor(for: key) }
        item.overflow = [
            .init(title: "Copy Public Key") { copyToPasteboard(key.publicKey) },
            .init(title: "Delete") { [weak self] in self?.confirmDeleteKey(key) },
        ]
        return item
    }

    func snippetItem(_ snippet: Snippet) -> HostsListSection.Item {
        // F12: the trigger is this row's identity when it has one - it is what
        // the captain types and therefore what they look for. The chip carries
        // the scope, which is the one thing about a snippet that changes what
        // typing it does, and it is `.good` only when the snippet really will
        // fire elsewhere (GL-14: a Console-only snippet must not read like an
        // armed one).
        let trigger = snippet.triggerDisplay
        var content = HelmAccentRow.Content(tint: .info,
                                            kicker: trigger ?? "Snippet",
                                            title: snippet.label,
                                            meta: snippet.subtitle,
                                            badgeSymbol: "chevron.left.forwardslash.chevron.right")
        content.metaIsCode = true
        if trigger != nil {
            content.chipText = snippet.scope.chipText
            content.chipTint = snippet.expandsSystemWide ? .good : .neutral
        }
        var item = HostsListSection.Item(content: content)
        item.recordKey = snippet.id.uuidString
        item.primary = .init(title: "Run", symbol: "play.fill") { [weak self] in self?.onRunSnippet?(snippet) }
        item.activate = { [weak self] in self?.onRunSnippet?(snippet) }
        item.overflow = [
            .init(title: "Edit…") { [weak self] in self?.presentSnippetEditor(for: snippet) },
            .init(title: "Copy Command") { copyToPasteboard(snippet.command) },
            .init(title: "Delete") { [weak self] in self?.confirmDeleteSnippet(snippet) },
        ]
        return item
    }
}
