// Manjesh Grand Line - native macOS app.
//
// **Poneglyph** - the captain's personal credential vault. Its own standalone
// destination (`DestinationSlotID.poneglyph`), reachable from its Stores card
// - not a Setup sub-page any more, see below.
//
// **History, so the naming doesn't read as arbitrary.** This page originally
// took over Automic Vault's `.vault` destination and was labeled "Vault"
// itself (`fm/implement-grand-line-secrets-vault-poneg-ad`) - Automic Vault's
// own hardening panel moved under Setup at the same time, renamed
// **Poneglyph**, his own naming call: *"Since we are using lot of the ship and
// one piece theme, I would suggest the name of the application or the feature
// instead of tool hardening as 'Poneglyph.'"* After seeing the two live, the
// captain judged that backwards - Automic Vault is the vault he already relies
// on daily, so `fm/swap-vault-poneglyph-naming-in-grand-lin-1f` gave it back
// the `.vault` destination and the "Vault" label (see `VaultController.swift`'s
// header), and this page took the "Poneglyph" name in its place, moving under
// Setup as its fifth tab (`SetupContainerController`/`SetupTab.poneglyph`, at
// the time). It shared that container's one slot with
// Updates/Bootstrap/Automation/GitHub Sync for a while - which meant opening
// it from its Stores card showed a page titled "Setup" with all four of those
// pages' tab strip above it, reading as though the credential vault were part
// of Engineering's setup pipeline rather than the fully separate feature it
// is. `fm/poneglyph-own-destination-and-strawhat-toolbar-shortcut` gave it its
// own destination slot instead (see `DestinationRegistry.swift`), the same
// standalone shape `.strawHat` already has - `SetupTab.poneglyph` no longer
// exists. Nor does the container: `fm/grandline-separate-setup-destinations`
// made the identical move for the four pages left behind, so
// `SetupContainerController` and `SetupTab` are both gone and every one of
// those five destinations now shows its own title. Automic Vault's actual job (gating what a CLI tool may do with a
// credential) is genuinely useful and unchanged throughout; what it is not, by
// its own written architecture decision, is a retrieval-based password
// manager, which is what this page is. Two very different things that have
// spent this app's history trading names, never behaviour.
//
// **The page has exactly two states**, and which one shows is decided by what
// is on disk rather than by a flag: the unlock/setup gate
// (`CredentialVaultUnlockView`) or the list. There is no third "empty" state -
// an unlocked vault with no credentials shows the list's own empty row, so "add
// your first credential" sits where every later credential will.
//
// **The master password is independent from the app lock**, by the captain's
// second decision: *"Let us have different passwords for the vault as well as
// the application password."* Two keys, neither derived from the other. The
// app's own lock (`LockScreenController`) still gates the whole window; this
// gates this page.
//
// **Auto-lock.** One `Timer`, one idle check, driven by `VaultSettings`. It
// re-locks on idle, on the app locking, and on quit - and deliberately does NOT
// re-lock merely because the captain navigated to another destination: a vault
// that closed itself every time he looked at Console would be unusable, and the
// whole-app lock already covers walking away.

import AppKit
import LocalAuthentication

final class CredentialVaultController: NSViewController, DaylightDrillActions {

    // MARK: State

    private let store: CredentialVaultStore
    private let list = CredentialVaultListSection()
    private let unlockView = CredentialVaultUnlockView()
    private let searchField = HelmSearchField(placeholder: "Search titles, accounts and tags")
    private let sidebar = CredentialVaultSidebar()
    private let inspector = CredentialVaultInspectorView()
    private let clipboardPill = NSView()
    private let clipboardLabel = NSTextField(labelWithString: "")
    private let addButton = HelmButton(title: "Add credential", variant: .primary, symbol: "plus")
    private let lockButton = HelmButton(title: "Lock", variant: .secondary, symbol: "lock.fill")
    private let settingsButton = HelmButton(title: "", variant: .quiet, symbol: "gearshape")
    /// F17. Its own header action rather than a row inside Settings: the
    /// recovery key is the answer to "what if I forget the master password",
    /// and a captain who is worried about that is not going to find it three
    /// clicks inside a preferences sheet. Same reasoning the mockup's own
    /// note gives for pairing it with import.
    private let recoveryButton = HelmButton(title: "", variant: .quiet, symbol: "shield.lefthalf.filled")

    private var listContainer: NSView!
    /// The credential the inspector is showing, if any. Survives a re-render
    /// (a store change, a theme change, a search) so the panel does not empty
    /// itself under the captain while they are reading it.
    private var selectedID: String?
    private var themeObservation: ThemeObservation?

    private var query = ""
    /// Which sidebar collection is showing. F16 widened this from a
    /// `CredentialCategory?` to `CredentialVaultSidebar.Selection`, which
    /// carries the kind axis as well - see that type.
    private var collectionFilter: CredentialVaultSidebar.Selection = .all
    /// Which rows currently have their value on screen. Keyed by credential id
    /// so the state survives a `reloadData` - which happens on every store
    /// change, including one caused by a *different* row's copy.
    private var revealedIDs: Set<String> = []

    private var autoLockTimer: Timer?
    /// F16's 1Hz subscription, held so it can be dropped when the page goes
    /// off screen.
    private var totpObservation: UUID?
    private var lastInteraction = Date()

    /// The credential this page most recently opened a detail sheet for, so a
    /// store change can refresh it. Kept weak-by-id rather than by reference:
    /// the record is a value type and the store's copy is the truth.

    override init(nibName: String?, bundle: Bundle?) {
        // GL-23, and F21's reason for moving it: the vault store lives on
        // `GrandLineServices` rather than here, so the Copy Credential App
        // Intent reaches the *unlocked* store this page is showing rather than
        // a second, permanently-locked instance of its own. This destination
        // mounts lazily (GL-37), so the store also has to outlive any one
        // mounting of it - which a property on this controller could not do.
        self.store = GrandLineServices.shared.vault
        super.init(nibName: nibName, bundle: bundle)
    }

    convenience init() { self.init(nibName: nil, bundle: nil) }

    /// An injected store, for self-tests - never reaches the production git
    /// sync when handed a scratch root.
    init(store: CredentialVaultStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        autoLockTimer?.invalidate()
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    // MARK: Drill header (Daylight §6.4)

    var onDrillSubtitleChanged: (() -> Void)?

    var drillHeaderSubtitle: String? {
        guard store.isUnlocked else {
            switch store.loadState() {
            case .absent: return "Not set up yet"
            case .unreadable: return "Unavailable"
            case .present: return "Locked"
            }
        }
        let total = store.credentials.count
        let shown = filteredCredentials().count
        let base = total == 1 ? "1 credential" : "\(total) credentials"
        let scoped = shown == total ? base : "\(shown) of \(base)"
        // The sync state matters here - it is the portability promise, and the
        // one thing a captain would want to know at a glance without opening
        // settings.
        guard let sync = store.gitSync else { return "\(scoped) \u{00B7} local only" }
        switch sync.status {
        case .synced: return "\(scoped) \u{00B7} backed up"
        case .localChanges, .syncing: return "\(scoped) \u{00B7} backing up\u{2026}"
        case .failed: return "\(scoped) \u{00B7} backup failed"
        }
    }

    /// Add is the page's own action and belongs in the header cluster; Lock and
    /// Settings sit beside it because both are page-level and neither has a
    /// home in the list below. All three are hidden while locked - there is
    /// nothing to add to, lock, or configure behind the gate.
    var drillHeaderActions: [NSView] { [recoveryButton, settingsButton, lockButton, addButton] }

    // MARK: Layout

    override func loadView() {
        // A plain, layer-backed, theme-filled root - never an
        // `NSVisualEffectView` for a full-size destination (AGENTS.md gotcha
        // #8).
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1136, height: 660))
        root.wantsLayer = true
        view = root

        buildListContainer()
        unlockView.onCreate = { [weak self] password in self?.createVault(password) }
        unlockView.onUnlock = { [weak self] password in self?.attemptUnlock(password) }
        unlockView.onUnlockWithTouchID = { [weak self] in self?.attemptTouchIDUnlock() }
        unlockView.onUnlockWithRecoveryKey = { [weak self] code in self?.attemptRecoveryUnlock(code) }

        for child in [unlockView, listContainer!] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                child.topAnchor.constraint(equalTo: root.topAnchor),
                child.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }

        addButton.target = self
        addButton.action = #selector(addTapped)
        // `fm/swap-vault-poneglyph-naming-in-grand-lin-1f`: this page lives at
        // `.poneglyph` now, not `.vault` - the hue belongs to the area a
        // destination sits in (§2.2), so it follows the move.
        addButton.domainHue = RailDestination.poneglyph.domainHue
        lockButton.target = self
        lockButton.action = #selector(lockTapped)
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = "Poneglyph settings and audit log"
        recoveryButton.target = self
        recoveryButton.action = #selector(recoveryTapped)
        recoveryButton.toolTip = "Recovery key and CSV import"

        store.onChange = { [weak self] in self?.render() }
        CredentialVaultClipboard.shared.onCountdown = { [weak self] remaining in
            self?.renderClipboardCountdown(remaining)
        }

        // Registered last, and `refreshTheme`-style re-applied at the end -
        // `ThemeManager.observe` fires synchronously at registration, which for
        // a page whose subviews are built above is fine, but the second call is
        // what covers anything built after it (this codebase's most-repeated
        // bug class - see `HelmFormSheet`'s own note).
        themeObservation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        applyTheme(ThemeManager.shared.theme)
        registerWithAppLockGate()
        render()
    }

    /// The page is three columns: a fixed nav sidebar, the credential list, and
    /// a permanent inspector - the captain's reference mockup's own shape.
    ///
    /// **Why three columns is itself the fix for "cramped".** Measured on the
    /// shipped build before this change, the list was one full-width card, so a
    /// row's text sat at the far left and its tag and actions at the far right
    /// with roughly a thousand points of nothing between them, while the detail
    /// it opened was a ~190pt column inside a centred sheet. Giving navigation
    /// and detail columns of their own leaves the list a column it can actually
    /// fill, and gives the detail a fixed, generous width instead of a dialog's.
    ///
    /// **Window-floor discipline** (gotchas (13)/(14)): the two fixed columns
    /// are small and required; the list is the flexible one and carries only a
    /// 499-priority minimum, below `NSLayoutPriorityWindowSizeStayPut`, so this
    /// page can never stop the window shrinking. `AppShellBodyWidthSelfTest`
    /// sweeps every destination for exactly that.
    private func buildListContainer() {
        let container = NSView()
        listContainer = container

        list.onSelectRow = { [weak self] id in self?.selectCredential(id: id) }
        list.onReorder = { [weak self] draggedID, beforeID in self?.reorderCredential(id: draggedID, before: beforeID) }

        sidebar.onSelect = { [weak self] selection in
            guard let self else { return }
            self.collectionFilter = selection
            self.noteInteraction()
            self.render()
            self.list.scrollToTop()
        }

        searchField.onTextChanged = { [weak self] text in
            guard let self else { return }
            self.query = text
            self.noteInteraction()
            self.render()
            self.list.scrollToTop()
        }
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // The clipboard countdown. Hidden unless a copy is pending, which is
        // the "quiet until it matters" rule `PRODUCT.md` states - a permanent
        // "nothing copied" pill would be noise.
        clipboardPill.wantsLayer = true
        clipboardPill.translatesAutoresizingMaskIntoConstraints = false
        clipboardLabel.font = HelmType.chip()
        clipboardLabel.translatesAutoresizingMaskIntoConstraints = false
        clipboardPill.addSubview(clipboardLabel)
        NSLayoutConstraint.activate([
            clipboardLabel.leadingAnchor.constraint(equalTo: clipboardPill.leadingAnchor, constant: HelmMetrics.s2),
            clipboardLabel.trailingAnchor.constraint(equalTo: clipboardPill.trailingAnchor, constant: -HelmMetrics.s2),
            clipboardLabel.centerYAnchor.constraint(equalTo: clipboardPill.centerYAnchor),
            clipboardPill.heightAnchor.constraint(equalToConstant: 22),
        ])
        let clearNowButton = HelmButton(title: "Clear now", variant: .quiet, size: .small,
                                        target: self, action: #selector(clearClipboardNow))
        clearNowButton.setContentHuggingPriority(.required, for: .horizontal)

        let filterRow = NSStackView(views: [searchField, clipboardPill, clearNowButton])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = HelmMetrics.s3
        // AGENTS.md gotcha #10: at the default `.gravityAreas` no hugging
        // priority is honoured at all, so the search field would not take the
        // slack and the pill would drift with sibling content.
        filterRow.distribution = .fill
        clipboardPill.setContentHuggingPriority(.required, for: .horizontal)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filterRow.translatesAutoresizingMaskIntoConstraints = false
        // The countdown pill and its Clear-now button are one unit, shown and
        // hidden together - a "Clear now" button with no countdown beside it
        // would be offering to clear a clipboard this app did not write.
        clipboardPillGroup = [clipboardPill, clearNowButton]
        clipboardPillGroup.forEach { $0.isHidden = true }

        wireInspector()

        list.card.translatesAutoresizingMaskIntoConstraints = false
        for child in [sidebar, filterRow, list.card, inspector] as [NSView] {
            container.addSubview(child)
        }

        let gutter = HelmMetrics.pageGutter
        let column = HelmMetrics.s5
        let listMinimum = list.card.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.listMinimumWidth)
        listMinimum.priority = HelmDaylightPriority.contentTie
        let inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: CredentialVaultInspectorView.Metrics.width)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: gutter),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s4),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -gutter),

            // The search row sits over the list column only, not over the
            // sidebar - searching scopes the list, and a field spanning the nav
            // would imply it searched that too.
            filterRow.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: column),
            filterRow.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -column),
            filterRow.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s4),

            list.card.leadingAnchor.constraint(equalTo: filterRow.leadingAnchor),
            list.card.trailingAnchor.constraint(equalTo: filterRow.trailingAnchor),
            list.card.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: HelmMetrics.s3),
            list.card.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -gutter),
            listMinimum,

            inspector.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -gutter),
            inspector.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.s4),
            inspector.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -gutter),
            inspectorWidth,
        ])
    }

    /// The narrowest the credential column is allowed to get before the window
    /// itself has to give. Held *below* `NSLayoutPriorityWindowSizeStayPut` so
    /// it can never become a window-width floor.
    static let listMinimumWidth: CGFloat = 300

    /// Every callback the inspector needs. The gate, the audit event and the
    /// clipboard all stay on the page - the panel only ever asks.
    private func wireInspector() {
        inspector.onEdit = { [weak self] credential in self?.presentEditor(editing: credential) }
        inspector.onDelete = { [weak self] credential in self?.confirmDelete(id: credential.id) }
        inspector.onCopy = { [weak self] credential in self?.copyValue(id: credential.id) }
        inspector.onCopyAccount = { [weak self] credential in self?.copyAccount(id: credential.id) }
        inspector.onClose = { [weak self] in
            self?.selectedID = nil
            self?.render()
        }
        inspector.onReveal = { [weak self] credential, completion in
            guard let self else { return completion(false) }
            // Defence in depth, kept verbatim from the sheet this panel
            // replaces: the panel holds its own copy of the credential, so one
            // that somehow outlives a lock must still refuse to put the value
            // on screen. `clearInspector()` is the other half; neither alone is
            // enough (see `CredentialVaultInspector.swift`'s header).
            guard self.store.isUnlocked else { return completion(false) }
            self.noteInteraction()
            self.gateForReveal(credential) { allowed in
                if allowed { self.store.recordReveal(id: credential.id) }
                completion(allowed)
            }
        }
    }

    private var clipboardPillGroup: [NSView] = []

    static let allTabID = CredentialVaultSidebar.allRowID

    // MARK: Appearance

    override func viewDidAppear() {
        super.viewDidAppear()
        noteInteraction()
        startAutoLockTimer()
        render()
        startTOTPTicker()
        if !store.isUnlocked { unlockView.focusPasswordField() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // GL-13/§3.2: a timer that only matters while this page is the thing on
        // screen must not keep waking the process from a hidden destination.
        // The vault stays unlocked - see this file's header on why navigating
        // away is not a lock trigger - so re-locking on idle resumes the next
        // time the page is looked at.
        autoLockTimer?.invalidate()
        autoLockTimer = nil
        // GL-13, same reasoning: nobody can see a countdown on a hidden
        // page, and the ticker stops itself once its last observer leaves.
        stopTOTPTicker()
    }

    // MARK: F16 - the live 2FA countdown

    /// One subscription for the whole list, not one per row. Each tick
    /// updates the visible rows in place (`tickTOTP`) rather than reloading
    /// the table, which would drop the selection and the scroll position
    /// once a second.
    private func startTOTPTicker() {
        guard totpObservation == nil else { return }
        totpObservation = TOTPTicker.shared.observe { [weak self] in
            guard let self, self.store.isUnlocked else { return }
            self.list.tickTOTP(now: TOTPTicker.shared.now)
        }
    }

    private func stopTOTPTicker() {
        TOTPTicker.shared.unobserve(totpObservation)
        totpObservation = nil
    }

    // MARK: Render

    private func render() {
        let unlocked = store.isUnlocked
        listContainer.isHidden = !unlocked
        unlockView.isHidden = unlocked
        for action in drillHeaderActions { action.isHidden = !unlocked }

        if unlocked {
            renderSidebar()
            renderList()
            renderInspector()
        } else {
            // Nothing selected survives the gate - the panel holds a decrypted
            // credential, so a locked page must not be one back-navigation away
            // from showing it again.
            clearInspector()
            switch store.loadState() {
            case .absent:
                unlockView.setMode(.create)
            case .present:
                unlockView.setMode(.unlock(touchIDAvailable: store.settings.touchIDUnlockEnabled
                                           || CredentialVaultKeyStore.hasStoredKey,
                                           recoveryAvailable: store.recoveryKeyExistsOnDisk))
            case .unreadable(let reason, let backupPath):
                unlockView.setMode(.unreadable(reason: reason, backupPath: backupPath))
            }
        }
        onDrillSubtitleChanged?()
    }

    /// The sidebar's counts are scoped by the *search*, not by the category -
    /// each row says how many matches that collection holds right now, which is
    /// what makes it navigation rather than a second copy of the filter chips.
    private func renderSidebar() {
        sidebar.setCounts(matching: store.credentials.filter { $0.matches(query) })
        sidebar.select(collectionFilter)
    }

    /// Show whatever is selected, or the panel's own empty state.
    ///
    /// A credential that has been deleted, or filtered out of the list by a
    /// search the captain has since typed, drops the selection rather than
    /// leaving the panel showing a record they can no longer see beside it.
    private func renderInspector() {
        guard let selectedID,
              let credential = store.credential(id: selectedID),
              filteredCredentials().contains(where: { $0.id == selectedID }) else {
            self.selectedID = nil
            inspector.clear()
            return
        }
        inspector.show(credential, auditEvents: store.auditLog.filter { $0.itemID == selectedID })
    }

    private func filteredCredentials() -> [VaultCredential] {
        store.credentials.filter { credential in
            collectionFilter.includes(credential) && credential.matches(query)
        }
    }

    private func renderList() {
        let matching = filteredCredentials()
        guard !matching.isEmpty else {
            let hasAny = !store.credentials.isEmpty
            list.setItems([.empty(
                symbol: hasAny ? "magnifyingglass" : "lock.shield",
                title: hasAny ? "No matches" : "Your vault is empty",
                body: hasAny
                    ? "Nothing here matches that search or category. Try a different one."
                    : "Add your first credential and it will be encrypted, backed up to your private config repo, and one click from your clipboard."
            )])
            return
        }

        // Grouped by category, in the enum's own order - which is the mockup's
        // order, and stable regardless of what the captain has stored.
        // Within a group, `VaultCredential.displayOrder` - the captain's own
        // manual position, not alphabetical - is the default: "I should be
        // able to sort anything irrespective of whether it's created first or
        // last."
        var items: [CredentialVaultListSection.Item] = []
        for category in CredentialCategory.allCases {
            let inCategory = matching.filter { $0.category == category }
                .sorted(by: VaultCredential.displayOrder)
            guard !inCategory.isEmpty else { continue }
            items.append(.group("\(category.title) \u{00B7} \(inCategory.count)"))
            items.append(contentsOf: inCategory.map(row(for:)))
        }
        list.setItems(items, selecting: selectedID)
    }

    private func row(for credential: VaultCredential) -> CredentialVaultListSection.Item {
        let revealed = revealedIDs.contains(credential.id)
        // No kicker: every row sits directly under a group header that already
        // names its category, so repeating it per row spent a whole text line
        // on a word the eye had just read. Dropping it is most of what makes
        // the row feel roomy at the same height - the reference's own row is
        // name over `account \u{00B7} meta`, with no third line.
        var content = HelmAccentRow.Content(tint: credential.category.tint,
                                            kicker: "",
                                            title: credential.title)
        content.badgeSymbol = credential.kind == .secureNote ? credential.kind.symbol : credential.category.symbol
        // The revealed value takes over the meta line, in code font - see
        // `CredentialVaultListSection.swift`'s header for why the value goes
        // here rather than in a third line.
        if credential.kind == .secureNote {
            // GL-14's instinct on a row: say what is there without showing
            // it. A line count is a fact about the note; its first line
            // would be its contents.
            let lines = credential.secret.isEmpty
                ? 0
                : credential.secret.split(separator: "\n", omittingEmptySubsequences: false).count
            content.meta = lines == 0
                ? "An empty note \u{00B7} encrypted with the vault key"
                : "\(lines) line\(lines == 1 ? "" : "s") \u{00B7} encrypted with the vault key"
            content.metaIsCode = false
        } else if revealed {
            content.meta = credential.secret.isEmpty ? "(no value stored)" : credential.secret
            content.metaIsCode = true
        } else {
            content.meta = Self.metaLine(for: credential)
            content.metaIsCode = false
        }
        if !credential.tags.isEmpty {
            content.chipText = credential.tags.first
            content.chipTint = .neutral
        }
        // Deliberately **not** `HelmAccentRow.Content.titleAccessorySymbol`.
        // That field renders inline beside the title inside `titleRow`, which
        // is only vertically centered against the title *line* - so it sat
        // visibly higher than this row's own reveal/copy/overflow icon
        // cluster, which is centered against the row's full height. It is
        // rendered by `CredentialVaultRecordView` in the same trailing icon
        // cluster as those buttons instead - see `Item.requiresTouchIDIndicator`.
        var item = CredentialVaultListSection.Item(content: content)
        item.credentialID = credential.id
        item.category = credential.category
        item.isRevealed = revealed
        item.requiresTouchIDIndicator = credential.requiresTouchIDToReveal
        item.totp = credential.totp
        let id = credential.id
        // F16: a secure note is prose, not a value to paste. It offers
        // neither Reveal (six lines will not fit on a row's meta line) nor
        // Copy (a break-glass procedure on the pasteboard is how it ends up
        // in a chat window) - it opens in the inspector, which is what the
        // mockup's own row shows.
        let isNote = credential.kind == .secureNote
        item.reveal = isNote ? nil : { [weak self] in self?.toggleReveal(id: id) }
        item.copy = isNote ? nil : { [weak self] in self?.copyValue(id: id) }
        if credential.totp != nil {
            item.copyCode = { [weak self] in self?.copyTOTPCode(id: id) }
        }
        // A single click selects the row, which is what fills the inspector;
        // a double click is the same action rather than a second one, so the
        // gesture a captain reaches for from the old sheet still works.
        item.activate = { [weak self] in self?.selectCredential(id: id) }
        item.overflow = [
            .init(title: "Show in inspector", symbol: "info.circle") { [weak self] in self?.selectCredential(id: id) },
            .init(title: "Edit\u{2026}", symbol: "pencil") { [weak self] in self?.openEditor(id: id) },
            .init(title: "Copy account", symbol: "person.crop.circle") { [weak self] in
                self?.copyAccount(id: id)
            },
            .init(title: "Delete\u{2026}", symbol: "trash") { [weak self] in self?.confirmDelete(id: id) },
        ]
        return item
    }

    private static func metaLine(for credential: VaultCredential) -> String {
        var parts: [String] = []
        if !credential.account.isEmpty { parts.append(credential.account) }
        if let used = credential.lastUsedAt {
            parts.append("used \(CredentialVaultFormat.relative(used))")
        } else {
            parts.append("never used")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func renderClipboardCountdown(_ remaining: Int?) {
        guard let remaining else {
            clipboardPillGroup.forEach { $0.isHidden = true }
            return
        }
        clipboardPillGroup.forEach { $0.isHidden = false }
        clipboardLabel.stringValue = "Clipboard clears in \(remaining)s"
        let theme = ThemeManager.shared.theme
        ToolRowLayout.pill(text: clipboardLabel.stringValue,
                           colorHex: HelmTint.warn.hex(in: theme),
                           into: clipboardPill,
                           label: clipboardLabel,
                           theme: theme)
    }

    // MARK: Unlock / lock

    private func createVault(_ password: String) {
        unlockView.setBusy(true)
        // `createVault` runs PBKDF2 synchronously, so it goes off the main
        // thread for the same reason `unlock` does - at 600k rounds this is
        // hundreds of milliseconds, which would visibly freeze the window.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.store.createVault(masterPassword: password)
            DispatchQueue.main.async {
                self.unlockView.setBusy(false)
                switch result {
                case .success:
                    self.unlockView.clearPasswordFields()
                    self.noteInteraction()
                    self.render()
                    Toast.show(in: self.view, message: "Poneglyph created")
                case .failure(let error):
                    self.unlockView.showMessage(error.localizedDescription)
                }
            }
        }
    }

    private func attemptUnlock(_ password: String) {
        unlockView.setBusy(true)
        store.unlock(masterPassword: password) { [weak self] outcome in
            guard let self else { return }
            self.unlockView.setBusy(false)
            self.handleUnlockOutcome(outcome)
        }
    }

    private func attemptTouchIDUnlock() {
        unlockView.setBusy(true)
        store.unlockWithTouchID { [weak self] outcome in
            guard let self else { return }
            self.unlockView.setBusy(false)
            self.handleUnlockOutcome(outcome)
        }
    }

    /// F17: the printed-key door.
    ///
    /// Shares `handleUnlockOutcome` with the other two, so an unlock is
    /// recorded, throttled and rendered identically however it happened -
    /// and then adds the one thing this door owes the captain: a prompt to
    /// choose a new master password, because they got in without knowing
    /// the old one and the vault must not be left openable only by a sheet
    /// of paper.
    private func attemptRecoveryUnlock(_ code: String) {
        unlockView.setBusy(true)
        store.unlockWithRecoveryKey(code) { [weak self] outcome in
            guard let self else { return }
            self.unlockView.setBusy(false)
            self.handleUnlockOutcome(outcome)
            guard case .unlocked = outcome else { return }
            self.promptForNewMasterPasswordAfterRecovery()
        }
    }

    /// After a recovery unlock, the old password is - by definition -
    /// unknown, and the recovery wrap the captain just used is still the
    /// only spare key. `HelmConfirm` states that, and the Settings sheet is
    /// where the change actually happens (one password-change UI, not two).
    private func promptForNewMasterPasswordAfterRecovery() {
        let change = HelmConfirm.confirm(
            title: "Set a new master password",
            body: "You unlocked this vault with a recovery key, so the old master password is still the one "
                + "on the vault and you do not know it. Choose a new one now - the recovery key you just used "
                + "stops working when you do, and Poneglyph will offer you a new one to print.",
            confirmTitle: "Change it now",
            cancelTitle: "Later",
            confirmIsDefault: true,
            symbol: "key.fill",
            hue: RailDestination.poneglyph.domainHue)
        guard change else { return }
        settingsTapped()
    }

    private func handleUnlockOutcome(_ outcome: VaultUnlockOutcome) {
        switch outcome {
        case .unlocked:
            unlockView.clearPasswordFields()
            unlockView.showMessage("")
            revealedIDs.removeAll()
            noteInteraction()
            render()
        case .wrongPassword(let remaining):
            unlockView.showMessage(remaining <= 2
                                   ? "That's not the right password. \(remaining) more \(remaining == 1 ? "try" : "tries") before a delay."
                                   : "That's not the right password.")
        case .throttled(let after):
            unlockView.showMessage("Too many attempts. Try again in \(Self.humanDelay(after)).")
        case .unreadable(let reason):
            unlockView.showMessage(reason)
            render()
        case .noVaultYet:
            render()
        case .failed(let message):
            unlockView.showMessage(message)
        case .staleTouchIDKey:
            // B17: says what actually happened and what to do about it, and
            // re-renders because the Touch ID button has to go - the store
            // removed the key that made it offerable, so leaving it on screen
            // would offer a second tap that cannot work either.
            unlockView.showMessage("The stored Touch ID key no longer matches this vault - unlock with your password.")
            render()
        }
    }

    private static func humanDelay(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        if whole < 60 { return "\(whole) seconds" }
        let minutes = whole / 60
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// UX1's "Lock Poneglyph" ⌘K verb - the page's own Lock button action,
    /// not a second copy, so a locked vault ends up in exactly the same state
    /// whichever way it was asked.
    func lockFromMenu() { lockTapped() }

    @objc private func lockTapped() {
        store.lock(reason: "manual")
        dismissOpenSheets()
        clearInspector()
        revealedIDs.removeAll()
        render()
        unlockView.focusPasswordField()
    }

    // MARK: Auto-lock

    private func startAutoLockTimer() {
        autoLockTimer?.invalidate()
        guard store.settings.autoLockSeconds > 0 else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.checkAutoLock() }
        // §3.4's rule: every repeating timer in this app sets a tolerance, so
        // its ticks can be batched rather than being hard wake-ups.
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        autoLockTimer = timer
    }

    private func checkAutoLock() {
        guard store.isUnlocked, store.settings.autoLockSeconds > 0 else { return }
        guard Date().timeIntervalSince(lastInteraction) >= TimeInterval(store.settings.autoLockSeconds) else { return }
        let minutes = store.settings.autoLockSeconds / 60
        store.lock(reason: "\(minutes) minute\(minutes == 1 ? "" : "s") idle")
        dismissOpenSheets()
        clearInspector()
        revealedIDs.removeAll()
        render()
    }

    /// Any deliberate action on this page counts as presence. Deliberately not
    /// wired to a global `NSEvent` monitor: this vault's idle clock is about
    /// *this page*, and the whole-app lock already watches for the captain
    /// walking away from the machine.
    private func noteInteraction() {
        lastInteraction = Date()
    }

    // MARK: Reveal / copy

    /// Reveal: on screen only. Never touches the clipboard - the captain's
    /// explicit split, so a screen-share never forces a value into view.
    private func toggleReveal(id: String) {
        noteInteraction()
        guard let credential = store.credential(id: id) else { return }
        if revealedIDs.contains(id) {
            revealedIDs.remove(id)
            render()
            return
        }
        gateForReveal(credential) { [weak self] allowed in
            guard let self, allowed else { return }
            self.revealedIDs.insert(id)
            self.store.recordReveal(id: id)
            self.render()
        }
    }

    /// Copy: clipboard only. Never puts the value on screen, which is the
    /// entire point of keeping the two actions separate.
    private func copyValue(id: String) {
        noteInteraction()
        guard let credential = store.credential(id: id) else { return }
        guard !credential.secret.isEmpty else {
            Toast.show(in: view, message: "That credential has no value stored")
            return
        }
        CredentialVaultClipboard.shared.copy(credential.secret,
                                             clearAfter: store.settings.clipboardClearSeconds)
        store.recordCopy(id: id)
        Toast.show(in: view, message: "Copied \u{2014} clears in \(store.settings.clipboardClearSeconds)s")
    }

    /// F16: copy the current 2FA code.
    ///
    /// Derived from `TOTPTicker.shared.now` - the same clock the row is
    /// drawing from - rather than a fresh `Date()`, so what lands on the
    /// clipboard is exactly the code the captain was looking at when they
    /// clicked. The code goes out concealed and on the same auto-clear timer
    /// as any other vault value, and it is audited as a copy: a 2FA code is
    /// a credential for the thirty seconds it lives.
    ///
    /// The clear timer is the *shorter* of the clipboard setting and the
    /// code's own remaining life, because a code that has already rotated is
    /// not a secret worth holding - and leaving it there invites pasting it
    /// after it stopped working.
    private func copyTOTPCode(id: String) {
        noteInteraction()
        guard let credential = store.credential(id: id), let config = credential.totp else { return }
        let now = TOTPTicker.shared.now
        guard let code = TOTP.code(config, at: now) else {
            Toast.show(in: view, message: "That credential's 2FA seed is not readable \u{2014} edit it to fix")
            return
        }
        let remaining = TOTP.secondsRemaining(config, at: now)
        CredentialVaultClipboard.shared.copy(code, clearAfter: min(store.settings.clipboardClearSeconds, remaining))
        store.recordCopy(id: id)
        Toast.show(in: view, message: "Copied the 2FA code \u{2014} it changes in \(remaining)s")
    }

    /// F16's menu-bar popover asks the page for its rows rather than
    /// holding a store of its own.
    ///
    /// GL-23 is the reason: `CredentialVaultStore` caches, so there must be
    /// exactly one - two instances would hold two copies of the decrypted
    /// set and race each other's writes. The menu bar therefore follows the
    /// same forward-don't-own convention every other out-of-window surface
    /// in this app uses (`AppShellController.askCrewFromMenuBar` is the
    /// worked example).
    var quickCodeEntries: [PoneglyphQuickCode] {
        guard store.isUnlocked else { return [] }
        return store.credentials
            .filter { $0.totp != nil }
            .sorted(by: VaultCredential.displayOrder)
            .map { PoneglyphQuickCode(id: $0.id, title: $0.title, account: $0.account, totp: $0.totp!) }
    }

    var isVaultUnlocked: Bool { store.isUnlocked }

    /// Copy a code from outside the window. Same clipboard writer, same
    /// auto-clear and the same `copied` audit event as the in-window row -
    /// a code copied from the menu bar is exactly as much of a disclosure.
    @discardableResult
    func copyQuickCode(id: String) -> String? {
        guard store.isUnlocked, let credential = store.credential(id: id), let config = credential.totp else { return nil }
        let now = TOTPTicker.shared.now
        guard let code = TOTP.code(config, at: now) else { return nil }
        let remaining = TOTP.secondsRemaining(config, at: now)
        CredentialVaultClipboard.shared.copy(code, clearAfter: min(store.settings.clipboardClearSeconds, remaining))
        store.recordCopy(id: id)
        return code
    }

    /// The account is not a secret, so this needs no gate, no audit event and
    /// no clipboard timer - it is the "Copy Name"-shaped convenience the old
    /// panel had, kept because it is genuinely useful when filling a login form.
    ///
    /// It does still go out **concealed** (M2), even though it is not the
    /// secret half. An account is one half of a credential, and there is no
    /// upside to letting Universal Clipboard put the captain's production
    /// usernames on other devices or to letting a clipboard-history manager
    /// archive them. Routing it through `CredentialVaultClipboard`'s shared
    /// writer rather than touching `NSPasteboard` here is the point: one
    /// function being the only way this app puts credential material on a
    /// pasteboard is what stops the *next* copy path shipping unmarked, which
    /// is exactly how this one did.
    private func copyAccount(id: String) {
        noteInteraction()
        guard let credential = store.credential(id: id), !credential.account.isEmpty else {
            Toast.show(in: view, message: "No account recorded for that credential")
            return
        }
        CredentialVaultClipboard.writeConcealed(credential.account, to: NSPasteboard.general)
        Toast.show(in: view, message: "Copied the account")
    }

    /// The per-item Touch ID gate. Runs the challenge off the main thread (it
    /// blocks), and reports back on it.
    private func gateForReveal(_ credential: VaultCredential, completion: @escaping (Bool) -> Void) {
        guard credential.requiresTouchIDToReveal else {
            completion(true)
            return
        }
        guard CredentialVaultKeyStore.biometryAvailable else {
            // The gate cannot be satisfied on this Mac. Refusing outright would
            // make the item unreachable; saying so and proceeding is the honest
            // behaviour, and the vault password has already been entered.
            Toast.show(in: view, message: "No biometry on this Mac \u{2014} revealing without it")
            completion(true)
            return
        }
        let context = LAContextFactory.make(reason: "Reveal \u{201C}\(credential.title)\u{201D}")
        DispatchQueue.global(qos: .userInitiated).async {
            let allowed = LAContextFactory.evaluate(context)
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    @objc private func clearClipboardNow() {
        CredentialVaultClipboard.shared.clearNow()
    }

    // MARK: Sheets

    /// UX4: the File menu's contextual ⌘N on this page, and `⌘K`'s "New
    /// Credential" verb - the page's own "+ Add" action, not a second copy.
    ///
    /// The vault's own lock state still governs what happens next: `addTapped`
    /// is what a click on that button runs, so a locked vault refuses this
    /// exactly as it refuses the button.
    func newCredentialFromMenu() { addTapped() }

    @objc private func addTapped() {
        noteInteraction()
        presentEditor(editing: nil)
    }

    private func openEditor(id: String) {
        noteInteraction()
        guard let credential = store.credential(id: id) else { return }
        presentEditor(editing: credential)
    }

    /// F2: ⌥Space's ⌘4 landed here with a secret.
    ///
    /// Opens the ordinary Add sheet with only the secret field filled - see
    /// `CredentialVaultEditorController.capturedSecret` for why this is not a
    /// draft `VaultCredential` passed as `editing`, and
    /// `AppShellController.makeCaptureFiler` for why ⌘4 hands off at all
    /// rather than writing (the vault can be locked, and a captured line has
    /// no title).
    ///
    /// The lock is *not* checked here: the sheet is a form, not a disclosure,
    /// and `store.add` refuses on its own while locked with the error this
    /// page already reports. Opening it locked is what shows the captain the
    /// unlock screen behind it, which is the useful outcome.
    func presentCapturedCredential(secret: String) {
        noteInteraction()
        presentEditor(editing: nil, capturedSecret: secret)
    }

    private func presentEditor(editing credential: VaultCredential?, capturedSecret: String? = nil) {
        let editor = CredentialVaultEditorController(editing: credential,
                                                     capturedSecret: capturedSecret)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            let result = credential == nil ? self.store.add(saved) : self.store.update(saved)
            switch result {
            case .success:
                Toast.show(in: self.view, message: credential == nil ? "Credential added" : "Credential saved")
            case .failure(let error):
                self.reportVaultError(error)
            }
        }
        editor.onDelete = { [weak self] toDelete in
            self?.confirmDelete(id: toDelete.id)
        }
        // F16: a generated password is a secret from the moment it exists,
        // so copying one out of the sheet goes through the vault's own
        // concealed writer and its auto-clear - never a bare
        // `NSPasteboard.setString` inside the sheet.
        editor.onCopyGenerated = { [weak self] value in
            guard let self else { return }
            CredentialVaultClipboard.shared.copy(value, clearAfter: self.store.settings.clipboardClearSeconds)
            Toast.show(in: self.view,
                       message: "Copied the generated password \u{2014} clears in \(self.store.settings.clipboardClearSeconds)s")
        }
        presentAsSheet(editor)
    }

    /// Select a credential: the inspector shows it, and the list row it came
    /// from reads as selected. This replaced `openDetail(id:)`, which presented
    /// a sheet - see `CredentialVaultInspector.swift`'s header for why the
    /// detail stopped being a modal.
    private func selectCredential(id: String) {
        noteInteraction()
        guard store.credential(id: id) != nil else { return }
        selectedID = id
        render()
    }

    /// A drag within the list moved a credential to a new position inside its
    /// own category. `beforeID` is the *visible* neighbor it should now sit
    /// directly above, or nil to move it to the end - see
    /// `CredentialVaultListSection.onReorder`'s own doc comment for why the
    /// callback reports a neighbor rather than an absolute index: it lets
    /// this method splice the move into the credential's real, complete
    /// category list (`store.credentials`, not the possibly search-filtered
    /// `matching` this page renders), so a captain reordering while a search
    /// is active can never scramble a hidden credential's position.
    private func reorderCredential(id draggedID: String, before beforeID: String?) {
        noteInteraction()
        guard let dragged = store.credential(id: draggedID) else { return }
        var ordered = store.credentials
            .filter { $0.category == dragged.category }
            .sorted(by: VaultCredential.displayOrder)
            .map(\.id)
        ordered.removeAll { $0 == draggedID }
        if let beforeID, let index = ordered.firstIndex(of: beforeID) {
            ordered.insert(draggedID, at: index)
        } else {
            ordered.append(draggedID)
        }
        if case .failure(let error) = store.reorderCategory(dragged.category, orderedIDs: ordered) {
            reportVaultError(error)
        }
    }

    /// F17's sheet. Reachable only while unlocked, which is what
    /// `drillHeaderActions`' own hiding already enforces - enrolling a
    /// recovery key wraps the *session's* vault key, so there is nothing to
    /// wrap behind the gate.
    @objc private func recoveryTapped() {
        noteInteraction()
        guard store.isUnlocked else { return }
        let sheet = CredentialVaultRecoverySheetController(store: store)
        sheet.onCopyCode = { [weak self] code in
            guard let self else { return }
            // Through the vault's own concealed writer and auto-clear, like
            // every other secret this app copies - and deliberately on the
            // *short* side, since a recovery key on a clipboard is the one
            // string worth losing fastest.
            CredentialVaultClipboard.shared.copy(code, clearAfter: self.store.settings.clipboardClearSeconds)
            Toast.show(in: self.view,
                       message: "Copied \u{2014} paste it somewhere you trust, then print it")
        }
        sheet.onChanged = { [weak self] in self?.render() }
        presentAsSheet(sheet)
    }

    @objc private func settingsTapped() {
        noteInteraction()
        let settings = CredentialVaultSettingsController(
            settings: store.settings,
            auditEvents: store.auditLog,
            syncSummary: Self.syncSummary(store),
            touchIDAvailable: CredentialVaultKeyStore.biometryAvailable,
            unlockedViaRecoveryKey: store.unlockedViaRecoveryKey)
        settings.onSettingsChanged = { [weak self] updated in
            guard let self else { return }
            _ = self.store.updateSettings(updated)
            // A new auto-lock choice takes effect immediately rather than at
            // the next page visit.
            self.startAutoLockTimer()
        }
        settings.onSyncNow = { [weak self] in
            guard let self else { return }
            self.store.syncNow()
            Toast.show(in: self.view, message: "Backing up to your private config repo\u{2026}")
        }
        settings.onSetTouchIDUnlock = { [weak self] enabled, completion in
            guard let self else { return completion(.failure(CredentialVaultStoreError.locked)) }
            completion(enabled ? self.store.enableTouchIDUnlock() : self.store.disableTouchIDUnlock())
        }
        settings.onChangeMasterPassword = { [weak self] current, new, completion in
            guard let self else { return completion(.failure(CredentialVaultStoreError.locked)) }
            // Two PBKDF2 derivations, off the main thread - but that hop is the
            // *store's* to make, not this closure's, and the difference was a
            // real HIGH-severity defect. This used to be
            // `DispatchQueue.global { let r = store.changeMasterPassword(...) }`,
            // which put the store's own state mutation and its `onChange` -
            // i.e. `render()`, a full AppKit view rebuild - on a background
            // thread, racing the auto-lock timer's `lock()` on main over the
            // same key/file/audit-log state. `changeMasterPassword` takes a
            // completion now and owns the split itself (see its own doc
            // comment), so everything this page can observe happens on main.
            // F17: a session opened with the recovery key cannot prove the
            // old password, so it takes the store's own gated reset instead
            // - see `resetMasterPasswordAfterRecovery` for why that gate is
            // the whole security argument for it existing at all.
            if self.store.unlockedViaRecoveryKey {
                self.store.resetMasterPasswordAfterRecovery(newPassword: new, completion: completion)
            } else {
                self.store.changeMasterPassword(currentPassword: current, newPassword: new,
                                                completion: completion)
            }
        }
        presentAsSheet(settings)
    }

    private static func syncSummary(_ store: CredentialVaultStore) -> String {
        guard let sync = store.gitSync else {
            return "This vault is local to this Mac. It is not being backed up anywhere."
        }
        let location = "\(CredentialVaultGitSync.vaultSubpath)/\(CredentialVaultGitSync.vaultFileName) in your private config repo"
        switch sync.status {
        case .synced: return "Encrypted and backed up to \(location)."
        case .localChanges: return "Changes are waiting to be backed up to \(location)."
        case .syncing: return "Backing up to \(location)\u{2026}"
        case .failed(let why): return "Backup failed: \(why)"
        }
    }

    // MARK: Delete

    /// GL-30's rule: a modal for a decision that blocks something, then GL-33's
    /// undo toast for the recovery window. The report asks for both, and the
    /// mockup's own copy is used verbatim.
    private func confirmDelete(id: String) {
        guard let credential = store.credential(id: id) else { return }
        // G3: themed, with the key mapping unchanged. `confirmIsDefault:
        // false` is what keeps Return on Cancel - the same ordering
        // `CommandRiskConfirmation` uses for a destructive command, and the
        // reason this site chose it in the first place.
        guard HelmConfirm.confirm(
            title: "Delete \u{201C}\(credential.title)\u{201D}?",
            body: "The value cannot be recovered from Grand Line once this is removed. You'll have a few seconds to undo right after.",
            confirmTitle: "Delete",
            destructive: true,
            confirmIsDefault: false,
            symbol: "trash.fill",
            hue: .rose) else { return }

        switch store.delete(id: id) {
        case .success(let removed):
            revealedIDs.remove(id)
            Toast.showUndo(in: view, message: "Deleted \u{201C}\(removed.title)\u{201D}") { [weak self] in
                guard let self else { return }
                if case .failure(let error) = self.store.restore(removed) {
                    self.reportVaultError(error)
                }
            }
        case .failure(let error):
            reportVaultError(error)
        }
    }

    private func reportVaultError(_ error: Error) {
        // G3: themed, still blocking - the caller's own flow continues after
        // it and depends on the captain having read it.
        HelmConfirm.problem(title: "Couldn't update the vault",
                            body: error.localizedDescription)
    }

    // MARK: Lifecycle

    /// Read-only access for the shell's canvas closure - never for mutating.
    /// The Home canvas card asks this page for the vault's state rather than
    /// building a store of its own, which would reach the production git sync
    /// on every hub render (`DaylightModuleSelfTest.checkCanvasConstructsNoStores`).
    var credentialStore: CredentialVaultStore { store }

    /// Called by the shell on quit and when the whole app locks.
    func lockForAppLock() {
        // Deliberately *before* the `isUnlocked` guard below. A sheet can
        // outlive the vault's own lock - the auto-lock timer or the Lock button
        // can have locked the store while a detail sheet was up - so returning
        // early on an already-locked store would be exactly the case that
        // leaves a plaintext secret floating over the app's lock screen.
        dismissOpenSheets()
        // Deliberately outside the `isUnlocked` guard below, for the same
        // reason the dismissal is: the vault's own lock can already have fired
        // (auto-lock, or the Lock button) while the panel was still holding the
        // plaintext it was handed before that, so returning early on an
        // already-locked store is exactly the case worth covering.
        clearInspector()
        guard store.isUnlocked else { return }
        store.lock(reason: "app locked")
        revealedIDs.removeAll()
        render()
    }

    /// Quit-time: flush the debounced backup so a credential added seconds
    /// before quitting is still pushed.
    func shutdown() {
        store.flushForTermination()
    }

    // MARK: Locking the page down
    //
    // Both of this page's remaining sheets (editor, settings) are
    // `presentAsSheet` child *windows*, layered above the app's own lock
    // overlay - the overlay is only a subview of the main window, so a sheet
    // renders on top of it. That is H2: locking cleared the key and re-rendered
    // the page behind a sheet that was still holding the decrypted credential.
    //
    // The detail used to be a third sheet, and was the worst of the three for
    // exactly that reason - it captured the plaintext at construction and
    // toggled masked/plaintext display of it with no reference to vault state.
    // It is a panel inside the page now (`CredentialVaultInspectorView`), so
    // there is no window left to dismiss; what it needs instead is emptying,
    // which is `clearInspector()` below.

    /// Dismiss every sheet this page has up. Called from all three lock paths
    /// and from the app-lock gate.
    ///
    /// `dismiss(_:)` rather than ordering the sheet's window out: a sheet is a
    /// *presentation*, and ordering its window out behind AppKit's back leaves
    /// `presentedViewControllers` believing it is still up - the same class of
    /// mistake `AppLockGate.registerLockDismissiblePopover` documents for an
    /// `NSPopover`'s own `isShown`.
    ///
    /// Iterated over a snapshot because `dismiss` mutates the array it reads.
    private func dismissOpenSheets() {
        let open = presentedViewControllers ?? []
        guard !open.isEmpty else { return }
        AppLog.keychain.info("credential vault: dismissing \(open.count, privacy: .public) open sheet(s) on lock")
        for presented in open { dismiss(presented) }
    }

    /// Drop the selection and everything the panel is holding.
    ///
    /// This is the panel's half of what `dismissOpenSheets` does for the two
    /// remaining sheets. A panel needs no dismissal - it is a subview of this
    /// page, so the app's lock overlay already covers it, which is precisely
    /// why the detail moved out of a sheet - but it *does* need emptying: the
    /// point of locking is that the decrypted value leaves memory and the
    /// screen, not that something is drawn over it.
    private func clearInspector() {
        selectedID = nil
        inspector.clear()
    }

    /// The gate registration for the sheets, and why it is `observe` rather
    /// than `registerSecondaryWindow`.
    ///
    /// Those two registrations take a window or an `NSPopover` and dismiss it
    /// *for* the caller, with `orderOut`/`performClose`. Neither is correct for
    /// a sheet: `orderOut` on a sheet's window is the stale-presentation bug
    /// above, and a sheet is not an `NSPopover`. What a sheet needs is its
    /// presenter's own `dismiss(_:)`, so this page registers the *action*
    /// instead - which is a real `AppLockGate` registration either way, and the
    /// gate is the one place that knows the app has locked.
    ///
    /// Belt as well as braces: `AppShellController.showLock` already calls
    /// `lockForAppLock()`, which dismisses. This covers any future path that
    /// sets the gate without going through that method, and costs nothing when
    /// there is no sheet up. `observe` fires synchronously at registration
    /// (with the gate's own locked-at-launch default), which dismisses the zero
    /// sheets a just-built page has.
    private func registerWithAppLockGate() {
        AppLockGate.shared.observe { [weak self] locked in
            guard locked else { return }
            self?.dismissOpenSheets()
            self?.clearInspector()
        }
    }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        // Every full-size destination forces its own root appearance - without
        // it, scroller chrome, menus and the shared field editor resolve
        // against the OS's light/dark rather than the Helm theme's
        // (`DestinationMountingSelfTest.everyDestinationForcesItsOwnAppearance`).
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        list.applyTheme(theme)
        sidebar.applyTheme(theme)
        inspector.applyTheme(theme)
        unlockView.applyTheme(theme)
        clipboardLabel.font = HelmType.chip()
        if !clipboardPill.isHidden {
            renderClipboardCountdown(CredentialVaultClipboard.shared.secondsRemaining)
        }
    }

    #if FM_SELFTESTS
    var debugStore: CredentialVaultStore { store }
    var debugList: CredentialVaultListSection { list }
    var debugUnlockView: CredentialVaultUnlockView { unlockView }
    var debugSearchField: HelmSearchField { searchField }
    var debugSidebar: CredentialVaultSidebar { sidebar }
    var debugInspector: CredentialVaultInspectorView { inspector }
    var debugSelectedID: String? { selectedID }
    var debugAddButton: HelmButton { addButton }
    var debugLockButton: HelmButton { lockButton }
    var debugSettingsButton: HelmButton { settingsButton }
    var debugIsListShowing: Bool { !listContainer.isHidden }
    var debugIsUnlockShowing: Bool { !unlockView.isHidden }
    var debugRevealedIDs: Set<String> { revealedIDs }
    var debugClipboardPillVisible: Bool { !clipboardPill.isHidden }
    func debugRender() { render() }
    func debugSetQuery(_ text: String) { query = text; render() }
    /// Kept taking a raw *category* id, which is what every existing suite
    /// passes - F16's wider selection gets its own accessor beside it rather
    /// than churning those call sites.
    func debugSelectCategory(_ id: String) {
        collectionFilter = CredentialCategory(rawValue: id).map { .category($0) } ?? .all
        render()
    }
    func debugSelectCollection(_ selection: CredentialVaultSidebar.Selection) {
        collectionFilter = selection
        render()
    }
    func debugToggleReveal(id: String) { toggleReveal(id: id) }
    func debugCopyValue(id: String) { copyValue(id: id) }
    func debugSetLastInteraction(_ date: Date) { lastInteraction = date }
    func debugCheckAutoLock() { checkAutoLock() }
    func debugStartAutoLockTimer() { startAutoLockTimer() }
    var debugAutoLockTimerRunning: Bool { autoLockTimer?.isValid == true }
    func debugMakeRow(for credential: VaultCredential) -> CredentialVaultListSection.Item { row(for: credential) }
    /// How many sheets this page currently has presented - the only way a
    /// suite can assert "the lock actually dismissed the detail sheet" without
    /// reaching into AppKit's presentation bookkeeping itself.
    var debugPresentedSheetCount: Int { (presentedViewControllers ?? []).count }
    /// The presented detail sheet, if one is up - so a suite can drive its real
    /// Reveal button and check what it does once the vault is locked.
    func debugSelectCredential(id: String) { selectCredential(id: id) }
    func debugLockTapped() { lockTapped() }
    #endif
}

// MARK: - Touch ID challenge

/// The per-item reveal gate's `LAContext` plumbing, kept out of the controller
/// so the blocking call has one home.
///
/// Deliberately **not** `CredentialVaultKeyStore.loadKey`: that reads the stored
/// *key* and is about unlocking the vault. This is a bare presence challenge on
/// an already-unlocked vault - the report's phase-4 "per-item require Touch ID
/// to reveal" - so there is nothing to read and nothing to store.
enum LAContextFactory {
    static func make(reason: String) -> LAContext {
        let context = LAContext()
        context.localizedReason = reason
        return context
    }

    /// Blocks, so callers dispatch it off the main thread - the same
    /// `dispatchPrecondition` reasoning `KeychainKeyStore.authenticate` records
    /// (GL-25: on the main thread this freezes every window in the app).
    static func evaluate(_ context: LAContext) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let policy: LAPolicy = CredentialVaultKeyStore.biometryAvailable
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        var allowed = false
        let semaphore = DispatchSemaphore(value: 0)
        context.evaluatePolicy(policy, localizedReason: context.localizedReason) { success, _ in
            allowed = success
            semaphore.signal()
        }
        semaphore.wait()
        return allowed
    }
}
