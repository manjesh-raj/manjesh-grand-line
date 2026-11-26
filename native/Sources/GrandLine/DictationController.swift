// Grand Line - native macOS app.
//
// The "Dictation" rail destination. Phase 1 (fm/grandline-dictation-mvp)
// shipped a deliberately minimal page - real permission status and the fixed
// Right ⌥ Option shortcut, nothing else. Phase 2
// (fm/grandline-dictation-phase2) adds the three things phase 1 explicitly
// deferred: a transcription history list, a personal vocabulary editor, and
// a real shortcut recorder replacing the fixed combo. Phase 3
// (fm/grandline-dictation-phase3) adds the "Clean up my sentences" toggle -
// see `CLAUDE.md`'s "Dictation" section for the full phase split (all three
// originally-planned phases are now complete).
// Follows the same "hide, don't rebuild" body-child convention every other
// destination uses (`AppShellController`), and the same Settings-styled card
// layout `VaultController`/`HelmCard` already established rather than
// inventing new visual language.
//
// Status is read fresh from `DictationPermissions` on every `viewWillAppear`
// (matching `VaultController`/`ReviewController`'s own "refresh on appear,
// no polling" convention - PRODUCT.md's "quiet until it matters") and again
// live whenever the shared `DictationEngine` reports a state change while
// this page happens to be visible, so a captain watching this page while
// dictating sees "Recording…"/"Transcribing…" for real, not a static label.
// History/vocabulary are similarly re-read from `DictationStore` on every
// appear and on every `DictationStore.observe` notification (a dictation
// completed while this page happens to be open updates the list live).
//
// **Dic-1 (fm/grand-line-dictation-dic1).** The page-redesign board's split
// card replaces the four control cards. The gradient half
// (`HelmHeroSplitCard`'s panel) is the old Status card: the verdict, a line
// about the engine and the library, the local model as the ring, and Request
// Access or Re-check permissions as its pill - amber while a permission is
// missing. The card's own half holds the four controls as `SettingsRow`s: the
// shortcut recorder and its reset, Clean up my sentences, Use local Whisper
// engine, and the model row with its action and its "⋯" menu. Words I use
// often and Recent Dictations sit side by side under it, one above the other
// on a narrow page. Every control and every action is the one the cards had;
// only where they sit changed. The panel's words are `DictationHeroWords`.

import AppKit

final class DictationController: NSViewController, DaylightDrillActions {

    private let store: DictationStore

    /// S03: the page frame - scroll, flipped document, gutter and the
    /// first-content line.
    private let scaffold = HelmPageScaffold(spacing: 20, bottomInset: 28)
    private var scroll: NSScrollView { scaffold.scrollView }
    private var contentStack: NSStackView { scaffold.stack }

    /// §6.4's action cluster - this page's one page-level action. The in-page
    /// header row that used to hold it (a subtitle line plus this button) is
    /// gone: the drill header states the destination and its live numbers, so
    /// a second copy a row below it was exactly the duplication §6.4 removes.
    /// UXP-08: the app's one labelled Refresh, not a bare glyph.
    private let refreshButton = HelmButton.refresh()

    /// Dic-1: the split card - the verdict on the gradient, the controls
    /// beside it on the card's own surface.
    private let heroCard = HelmHeroSplitCard()
    /// "CONTROLS", over the rows on the card's own surface.
    private let controlsTitle = NSTextField(labelWithString: "Controls")
    private var controlRows: [SettingsRow] = []
    private var controlRules: [NSView] = []
    /// The panel's two pills. Request Access while a permission is missing
    /// (the one the old Status card's button asked for), Re-check permissions
    /// otherwise - the page's own Refresh.
    private let statusActionButton = HelmButton(title: "Request Access", variant: .secondary, size: .small)
    private let recheckButton = HelmButton(title: "Re-check permissions", variant: .secondary, size: .small,
                                           symbol: "arrow.clockwise")
    private var heroWords: DictationHeroWords?

    private let shortcutRecorder: KeyChordRecorderView
    private let shortcutResetButton = HelmButton(title: "", variant: .secondary)

    /// UI-53 / UI-61: the app's own toggle, never a stock `NSSwitch`.
    private let cleanupSwitch = HelmToggle()
    private let localWhisperSwitch = HelmToggle()
    private var modelRow: SettingsRow!
    // "Ready" in a dot and a word, beside the model's action while the model
    // is on disk.
    /// UI-32: the kit's status pill, which states its own width (no more
    /// B10 workaround on the label).
    private let modelReadyPill = HelmStatusPill(style: .dotWord)
    private let modelActionButton = HelmButton(title: "", variant: .primary)
    /// R2-UX-04: the sidebar layout's toolbar primary - the model row's
    /// action while it is the page's main one (Download Model, Retry
    /// Download), so it is not a filled button inside a card.
    private let toolbarModelButton = HelmButton(title: "Download Model", variant: .primary, symbol: "arrow.down.circle")
    /// GL-35: 547MB is not a footprint to strand. Only shown while the model
    /// is actually on disk. UI-53: a quiet "⋯" whose menu holds Delete Model…,
    /// which still asks through `HelmConfirm` - not a destructive button at
    /// the same weight as Re-download.
    private let modelDeleteButton = HelmButton(symbol: "ellipsis", variant: .quiet)
    private let modelProgressBar = HelmProgressBar()
    private var modelState: WhisperModelState = .notDownloaded

    /// Words I use often and Recent Dictations: side by side on a wide page,
    /// one above the other on a narrow one. A plain view with two constraint
    /// sets rather than a stack that flips its orientation: measured, a stack
    /// flipped vertical and back left both cards stretched to the taller
    /// one's height, the Words well a tall empty box.
    private let libraryRow = NSView()
    private var librarySideBySide: [NSLayoutConstraint] = []
    private var libraryStacked: [NSLayoutConstraint] = []
    private(set) var libraryIsStacked = false
    /// Two columns need this much width each.
    static let libraryColumnMinWidth: CGFloat = 400
    static let libraryGap: CGFloat = HelmMetrics.s4

    private let vocabularyPanel = HelmCard()
    /// S15: every card's header is `HelmSectionHeader(size: .card)` - a 26pt
    /// tile, a title, a subtitle, the count in a badge and the card's one
    /// action in the trailing slot.
    private let vocabularyHeader = HelmSectionHeader(size: .card)
    private let historyHeader = HelmSectionHeader(size: .card)
    private let explainerLabel = NSTextField(wrappingLabelWithString: "")
    private var vocabularyColumn = NSStackView()
    /// §6.9's chips-in-a-well, and the headline instance of the audit's D2:
    /// this was a raw-ish field with a separate chip flow and an "Add" button
    /// beside it - three controls for one idea, and the pattern
    /// `HelmChipInput`'s own doc comment names as the second thing it
    /// replaces. Tokens now live *inside* the well, Return commits, and
    /// Backspace on an empty editor pops the last one.
    private let vocabularyInput = HelmChipInput(placeholder: "Add a word or phrase, then press Return")

    private let historyPanel = HelmCard()
    private let historyListView = DictationHistoryListView()
    private let historyListScroll = NSScrollView()

    private var status: DictationStatus = DictationPermissions.currentStatus()
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var hasLoadedOnce = false

    /// Forwarded to `AppShellController` -> the app delegate, which is what
    /// actually owns the live `DictationHotkey` instance - this controller
    /// only edits the persisted preference and reports the change, matching
    /// how `SettingsController.onFontSizeStep` forwards rather than owning
    /// the live console it affects.
    var onShortcutChanged: ((KeyChord) -> Void)?

    /// Fired when the "Use local Whisper engine" toggle changes, so whoever
    /// owns the live `DictationEngine` can drop a resident engine the moment
    /// the captain switches it off - see
    /// `DictationEngine.whisperIdleUnloadInterval` (E2) for why a resident
    /// engine is not free. Same forward-don't-own convention as
    /// `onShortcutChanged` above.
    var onLocalWhisperEnabledChanged: ((Bool) -> Void)?

    init(store: DictationStore) {
        self.store = store
        self.shortcutRecorder = KeyChordRecorderView(shortcut: AppSettings.shared.dictationShortcut)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        root.wantsLayer = true
        view = root

        buildDrillActions()
        buildHeroCard()
        _ = buildVocabularySection()
        _ = buildHistorySection()
        buildLibraryRow()

        scaffold.install(in: root)
        for block in [heroCard, libraryRow] as [NSView] {
            scaffold.addContent(block)
        }

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            // The panel's amber is the theme's own, so its tone is re-read.
            if self?.heroWords != nil { self?.renderHero() }
            self?.applyTheme()
        }

        // A dictation completed (or a vocabulary edit made) while this page
        // happens to be visible should show up immediately, not only on the
        // next `viewWillAppear` - matches `HostStore.observe`'s "list of
        // closures" convention for the same reason.
        store.observe { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.renderHistory()
            self.renderVocabulary()
        }

        // fm/grandline-dictation-whisper-engine: live download progress -
        // `WhisperModelManager.observe` fires immediately with the current
        // state (matching `DictationStore.observe`'s convention) and again
        // on every state change, so the progress bar/status text update in
        // real time while a download is in flight and this page is visible.
        WhisperModelManager.shared.observe { [weak self] state in
            guard let self, self.isViewLoaded else { return }
            self.modelState = state
            self.renderLocalWhisperSection()
        }

        // UI-53: the first paint is a real render. Before this, a page drawn
        // before `viewWillAppear` showed the Status card's unfilled chrome -
        // an empty tile, no title and an untitled accent button, which read
        // as a stray toggle (UI-49's class of defect).
        cleanupSwitch.isOn = AppSettings.shared.dictationCleanupEnabled
        localWhisperSwitch.isOn = AppSettings.shared.dictationLocalWhisperEnabled
        render()

        // P-03 of the 2026-11-25 review: the sidebar is the only layout, so
        // the page builds its sidebar presentation as part of loading.
        buildSidebarPresentation()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        hasLoadedOnce = true
        // T5: Settings > Shortcuts can rebind the trigger too, so the
        // recorder re-reads the stored chord rather than trusting its own.
        shortcutRecorder.shortcut = AppSettings.shared.dictationShortcut
        view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        refresh()
        renderHistory()
        renderVocabulary()
    }

    /// Keeps every wrapping description sized to the width its row really
    /// has, rather than a constant guessed at construction.
    ///
    /// The captain-reported "text cramped to the first half of the card, with
    /// a big empty gap before the toggle" bug, and review bug B10's one word
    /// per line, are both this: a wrapping label's intrinsic width comes from
    /// its `preferredMaxLayoutWidth`, so it has to be fed a width it does not
    /// itself decide (gotcha (22)). The control rows are `SettingsRow`s, whose
    /// `relayoutDescription` derives it from the row's own resolved width
    /// minus its control; the Words card's explainer is derived from its
    /// column, which is tied to the card. The panel wraps its own words.
    ///
    /// A text column never wraps narrower than this, whatever the arithmetic
    /// says - `SettingsRow.relayoutDescription`'s own floor, and for the same
    /// reason: a column narrow enough to break words mid-word is worse than
    /// one that overflows its row slightly.
    private static let detailMinimumWidth: CGFloat = 180

    override func viewDidLayout() {
        super.viewDidLayout()
        // The rows live inside the scroll view's document, which this pass
        // has not laid out yet: on a live resize (measured, 1512 -> 1100)
        // they still held the old width here, the derived wrap widths stayed
        // wide, and nothing called this again, so the sentences were cut off
        // at their cards' bottoms. Settle the document first so the rows read
        // their real widths.
        scroll.documentView?.layoutSubtreeIfNeeded()
        var changed = layoutLibraryRow()
        for row in controlRows where row.bounds.width > 0 {
            let before = row.descriptionLabel?.preferredMaxLayoutWidth
            row.relayoutDescription(cardWidth: row.bounds.width)
            if row.descriptionLabel?.preferredMaxLayoutWidth != before { changed = true }
        }
        if vocabularyColumn.bounds.width > 0 {
            let available = max(Self.detailMinimumWidth, floor(vocabularyColumn.bounds.width))
            if abs(explainerLabel.preferredMaxLayoutWidth - available) > 0.5 {
                explainerLabel.preferredMaxLayoutWidth = available
                explainerLabel.invalidateIntrinsicContentSize()
                changed = true
            }
        }
        // A new wrap width changes the label's height after the pass that
        // measured it, so one follow-up pass settles the cards' heights. It
        // converges because the widths are derived from the rows, which these
        // labels do not decide (gotcha 22).
        if changed, !relayoutScheduled {
            relayoutScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.relayoutScheduled = false
                self.view.needsLayout = true
                self.view.layoutSubtreeIfNeeded()
            }
        }
    }
    private var relayoutScheduled = false

    /// Two columns when both cards get `libraryColumnMinWidth`, one above the
    /// other otherwise. Returns whether it switched.
    private func layoutLibraryRow() -> Bool {
        let width = libraryRow.bounds.width
        guard width > 0 else { return false }
        let columns = HelmResponsiveGrid.columns(containerWidth: width, minItemWidth: Self.libraryColumnMinWidth,
                                                 spacing: Self.libraryGap)
        let stack = columns < 2
        guard stack != libraryIsStacked else { return false }
        libraryIsStacked = stack
        NSLayoutConstraint.deactivate(stack ? librarySideBySide : libraryStacked)
        NSLayoutConstraint.activate(stack ? libraryStacked : librarySideBySide)
        return true
    }

    /// Re-reads real permission state and re-renders. Called on every page
    /// visit, after the captain returns from a system permission dialog
    /// (there is no completion callback for "the user closed System
    /// Settings," so re-checking on next appear is the same honest approach
    /// `SudoTouchIDController`/`VaultController` already use for their own
    /// OS-level checks), and after `setEngineStatus` reports a change.
    func refresh() {
        cleanupSwitch.isOn = AppSettings.shared.dictationCleanupEnabled
        localWhisperSwitch.isOn = AppSettings.shared.dictationLocalWhisperEnabled
        WhisperModelManager.shared.refreshState()
        setStatus(DictationPermissions.currentStatus())
    }

    /// Called by the app delegate whenever the shared `DictationEngine`
    /// reports a status change (e.g. recording started/stopped) - keeps this
    /// page truthful in real time while it's visible. A no-op while the page
    /// isn't loaded yet.
    func setEngineStatus(_ status: DictationStatus) {
        guard isViewLoaded else { return }
        setStatus(status)
    }

    private func setStatus(_ status: DictationStatus) {
        self.status = status
        render()
        // The status is the first clause of the drill header's live subtitle.
        onDrillSubtitleChanged?()
    }

    // MARK: Building the static chrome

    /// Prepares the one view §6.4's action cluster shows for this page. There
    /// is no in-page header row any more - see `refreshButton`'s own comment.
    private func buildDrillActions() {
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Re-check Dictation permissions"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: Drill header (Daylight §6.4)

    /// Set by `AppShellController`; called whenever this page's live numbers
    /// change. Never writes to the header itself.
    var onDrillSubtitleChanged: (() -> Void)?

    var drillHeaderActions: [NSView] { [refreshButton] }

    /// §6.4's live subtitle, built from what this page already knows - the
    /// engine status it is handed and the two store counts it already renders
    /// as card-header numbers. No new reads, and a permission still missing
    /// says so rather than being rounded up to "Ready".
    var drillHeaderSubtitle: String? {
        let words = store.vocabulary.count
        let dictations = store.history.count
        var parts = [status.title]
        parts.append(words == 1 ? "1 word" : "\(words) words")
        parts.append(dictations == 1 ? "1 dictation" : "\(dictations) dictations")
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Dic-1's split card. The panel is filled by `renderHero`; the card's
    /// own half is built once here - the four controls as `SettingsRow`s,
    /// hairline-separated like a Settings group, under a "CONTROLS" kicker.
    private func buildHeroCard() {
        heroCard.panel.setAccessibilityLabel("Dictation status")
        heroCard.onStackedChange = { [weak self] _ in self?.view.needsLayout = true }

        statusActionButton.target = self
        statusActionButton.action = #selector(statusActionTapped)
        recheckButton.target = self
        recheckButton.action = #selector(refreshTapped)
        recheckButton.toolTip = "Re-check Dictation permissions"

        shortcutRecorder.onChange = { [weak self] newShortcut in
            self?.shortcutChanged(newShortcut)
        }
        shortcutResetButton.title = "Reset to Right ⌥ Option"
        shortcutResetButton.controlSize = .small
        shortcutResetButton.target = self
        shortcutResetButton.action = #selector(resetShortcutTapped)
        let shortcutControl = NSStackView(views: [shortcutRecorder, shortcutResetButton])
        shortcutControl.orientation = .horizontal
        shortcutControl.alignment = .centerY
        shortcutControl.spacing = HelmMetrics.s2

        cleanupSwitch.target = self
        cleanupSwitch.action = #selector(cleanupToggled)
        localWhisperSwitch.target = self
        localWhisperSwitch.action = #selector(localWhisperToggled)

        // G4: the app's own bar rather than the stock determinate one.
        modelProgressBar.isHidden = true
        modelProgressBar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        modelReadyPill.isHidden = true
        modelActionButton.controlSize = .small
        modelActionButton.target = self
        modelActionButton.action = #selector(modelActionTapped)
        modelDeleteButton.controlSize = .small
        modelDeleteButton.target = self
        modelDeleteButton.action = #selector(modelMoreTapped(_:))
        modelDeleteButton.toolTip = "More model actions"
        modelDeleteButton.setAccessibilityLabel("More model actions")
        modelDeleteButton.isHidden = true
        let modelControl = NSStackView(views: [modelProgressBar, modelReadyPill, modelActionButton, modelDeleteButton])
        modelControl.orientation = .horizontal
        modelControl.alignment = .centerY
        modelControl.spacing = HelmMetrics.s2

        let shortcutRow = SettingsRow(
            title: "Shortcut",
            description: "Hold it to talk, let go to paste. Click the field, then hold the key or combo you want.",
            control: shortcutControl)
        let cleanupRow = SettingsRow(
            title: "Clean up my sentences",
            description: "Rewrites each dictation into a well-formed sentence before pasting. "
                + AITransparency.willSendToClaude("each transcript") + ", unless it looks like it holds a secret.",
            control: cleanupSwitch)
        // This same pass also corrects a misheard word against "Words I use
        // often" below, using the rest of the sentence for context - see
        // `DictationCleanup.swift`'s header for why that rides on this toggle
        // rather than a second one.
        cleanupRow.descriptionLabel?.toolTip = "Also checks the transcript against \"Words I use often\" below and fixes a likely misrecognition of one of those words, using the rest of the sentence as context."
        let localWhisperRow = SettingsRow(
            title: "Use local Whisper engine",
            description: "whisper.cpp large-v3-turbo, Metal-accelerated, fully offline once downloaded.",
            control: localWhisperSwitch)
        // The model is the engine's, so its row sits under the toggle as a
        // dependent one - indented, but never dimmed: the model downloads
        // whether or not the engine is on, as it always has.
        modelRow = SettingsRow(title: "Whisper model", description: "Model not downloaded",
                               control: modelControl, isSubRow: true)
        controlRows = [shortcutRow, cleanupRow, localWhisperRow, modelRow]

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in controlRows.enumerated() {
            if index > 0 {
                // A Settings group's hairline: inset to where the row's own
                // label starts.
                let rule = NSView()
                rule.wantsLayer = true
                rule.translatesAutoresizingMaskIntoConstraints = false
                rows.addArrangedSubview(rule)
                NSLayoutConstraint.activate([
                    rule.heightAnchor.constraint(equalToConstant: 1),
                    rule.leadingAnchor.constraint(equalTo: rows.leadingAnchor, constant: row.separatorInset
                        + (row.isSubRow ? SettingsRow.Metrics.subIndent : 0)),
                    rule.trailingAnchor.constraint(equalTo: rows.trailingAnchor,
                                                   constant: -SettingsRow.Metrics.insetH),
                ])
                controlRules.append(rule)
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        controlsTitle.translatesAutoresizingMaskIntoConstraints = false
        let detail = heroCard.detail
        detail.addSubview(controlsTitle)
        detail.addSubview(rows)
        // The rows carry their own 14pt padding, so the stack sits that much
        // outside the title's inset and the row labels line up under it.
        let inset = HelmMetrics.s4
        NSLayoutConstraint.activate([
            controlsTitle.topAnchor.constraint(equalTo: detail.topAnchor, constant: inset),
            controlsTitle.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: inset + HelmMetrics.s1),
            rows.topAnchor.constraint(equalTo: controlsTitle.bottomAnchor, constant: HelmMetrics.s1),
            rows.leadingAnchor.constraint(equalTo: detail.leadingAnchor,
                                          constant: inset + HelmMetrics.s1 - SettingsRow.Metrics.insetH),
            rows.trailingAnchor.constraint(equalTo: detail.trailingAnchor,
                                           constant: -(inset + HelmMetrics.s1 - SettingsRow.Metrics.insetH)),
            rows.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -HelmMetrics.s2),
        ])
    }

    private func buildVocabularySection() -> NSView {
        vocabularyHeader.configure(leading: .tile(symbol: "text.quote", tint: .good), title: "Words I use often",
                                   subline: "A hint on your next recording")
        vocabularyPanel.setHeader(vocabularyHeader)

        // Tightened to the reviewed prototype's terser card-head phrasing -
        // the per-engine nuance (Apple's per-phrase hint vs. Whisper's
        // softer whole-list nudge) is still available on hover via the
        // label's own tooltip.
        explainerLabel.stringValue = "Biases recognition toward your own vocabulary - added here, it's used as a hint on your next recording."
        explainerLabel.toolTip = "This is a soft nudge, not a guarantee: Apple's on-device recognizer treats each phrase individually, while the local Whisper engine (if enabled) treats the whole list as a softer style hint. Turning on \"Clean up my sentences\" above adds a second pass over the finished sentence that can catch and correct a misheard word against this list even when the live nudge didn't."
        explainerLabel.font = HelmType.caption()
        explainerLabel.preferredMaxLayoutWidth = 520
        explainerLabel.translatesAutoresizingMaskIntoConstraints = false

        // One control instead of three. `onTokensChanged` hands back the whole
        // list, so this diffs it against the store rather than being handed a
        // delta - which is what keeps `addVocabularyWord`'s case-insensitive
        // dedup and the GL-33 undo toast on removal exactly as they were.
        vocabularyInput.domainHue = RailDestination.dictation.domainHue
        vocabularyInput.onTokensChanged = { [weak self] tokens in
            self?.applyVocabularyTokens(tokens)
        }
        vocabularyInput.translatesAutoresizingMaskIntoConstraints = false

        vocabularyColumn = NSStackView(views: [explainerLabel, vocabularyInput])
        vocabularyColumn.orientation = .vertical
        vocabularyColumn.alignment = .leading
        vocabularyColumn.spacing = 10
        vocabularyColumn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vocabularyInput.widthAnchor.constraint(equalTo: vocabularyColumn.widthAnchor),
        ])

        vocabularyPanel.setBody(vocabularyColumn, insets: HelmCard.contentInsets)
        return vocabularyPanel
    }

    /// `NSTableView.intercellSpacing`'s vertical component, as set by
    /// `DictationHistoryListView` - named here so the scroll height below and
    /// that setting cannot drift apart.
    private static let tableRowGap: CGFloat = 2

    /// The history list's own scroll height - four §6.5 row cards plus their
    /// gaps, beside the Words card (Dic-1; it was three when the list had the
    /// page's width to itself). Re-derived on every theme re-fire (GL-32)
    /// rather than captured once, since `rowHeight` follows the chrome text
    /// scale now.
    private var historyScrollHeight: NSLayoutConstraint!

    static let historyVisibleRows = 4

    private static func historyScrollHeight() -> CGFloat {
        let rows = CGFloat(historyVisibleRows)
        return DictationHistoryListView.rowHeight * rows + tableRowGap * rows
    }

    private func buildHistorySection() -> NSView {
        historyHeader.configure(leading: .tile(symbol: "clock.arrow.circlepath", tint: .neutral),
                                title: "Recent Dictations", subline: "What you said lately, kept on this Mac")
        historyPanel.setHeader(historyHeader)

        // GL-35: a single entry can be removed, not only "clear everything".
        historyListView.onDeleteEntry = { [weak self] entry in
            guard let self else { return }
            self.store.removeHistoryEntry(date: entry.date, text: entry.text)
            self.renderHistory()
            if let container = self.view.window?.contentView {
                Toast.showUndo(in: container, message: "Deleted transcription") { [weak self] in
                    guard let self else { return }
                    self.store.restoreHistoryEntry(entry)
                    self.renderHistory()
                }
            }
        }
        historyListScroll.documentView = historyListView.tableView
        historyListScroll.hasVerticalScroller = true
        historyListScroll.hasHorizontalScroller = false
        historyListScroll.borderType = .noBorder
        historyListScroll.drawsBackground = false
        historyListScroll.translatesAutoresizingMaskIntoConstraints = false
        // Sized so whole §6.5 row cards are visible before scrolling. The 220
        // this replaces showed ~4.8 of the 46pt label rows the cards replaced;
        // keeping it would have shown 2.8 cards, i.e. a clipped third row that
        // reads as a rendering bug rather than as "scroll for more".
        // GL-32 (audit §6.1): stored and re-derived on every theme re-fire,
        // because the row height it is built from now grows with the chrome
        // text scale - a constant captured once here would show 2.3 cards at
        // "Larger", i.e. the clipped-third-row look this height exists to
        // avoid.
        historyScrollHeight = historyListScroll.heightAnchor.constraint(
            equalToConstant: Self.historyScrollHeight())
        historyScrollHeight.isActive = true

        historyPanel.setBody(historyListScroll)
        return historyPanel
    }

    /// Words I use often beside Recent Dictations. Starts side by side;
    /// `layoutLibraryRow` stacks them on a narrow page. Side by side the two
    /// are equal widths, each its own height from the top, and the row as
    /// tall as the taller. Every text column inside yields, so the pair is
    /// never a window-width floor (gotcha (13)).
    private func buildLibraryRow() {
        libraryRow.translatesAutoresizingMaskIntoConstraints = false
        let words = vocabularyPanel
        let recent = historyPanel
        for card in [words, recent] {
            card.translatesAutoresizingMaskIntoConstraints = false
            libraryRow.addSubview(card)
        }
        let gap = Self.libraryGap
        NSLayoutConstraint.activate([
            words.leadingAnchor.constraint(equalTo: libraryRow.leadingAnchor),
            words.topAnchor.constraint(equalTo: libraryRow.topAnchor),
            recent.trailingAnchor.constraint(equalTo: libraryRow.trailingAnchor),
        ])
        librarySideBySide = [
            recent.topAnchor.constraint(equalTo: libraryRow.topAnchor),
            recent.leadingAnchor.constraint(equalTo: words.trailingAnchor, constant: gap),
            words.widthAnchor.constraint(equalTo: recent.widthAnchor),
            libraryRow.bottomAnchor.constraint(greaterThanOrEqualTo: words.bottomAnchor),
            libraryRow.bottomAnchor.constraint(greaterThanOrEqualTo: recent.bottomAnchor),
        ]
        // As short as the taller card allows, under every content priority.
        let hug = libraryRow.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = NSLayoutConstraint.Priority(240)
        librarySideBySide.append(hug)
        libraryStacked = [
            words.trailingAnchor.constraint(equalTo: libraryRow.trailingAnchor),
            recent.leadingAnchor.constraint(equalTo: libraryRow.leadingAnchor),
            recent.topAnchor.constraint(equalTo: words.bottomAnchor, constant: gap),
            libraryRow.bottomAnchor.constraint(equalTo: recent.bottomAnchor),
        ]
        NSLayoutConstraint.activate(librarySideBySide)
    }

    // MARK: Rendering

    private func render() {
        // UXP-16: "Reset to Right ⌥ Option" only when there is something to
        // reset - it used to show while the chord already was the default.
        shortcutResetButton.isHidden = shortcutRecorder.shortcut == .dictationDefault
        renderHero()
        applyActionEmphasis()
        applyTheme()
    }

    /// The panel, from the page's whole state: the permission status, the
    /// shortcut, the two toggles, the model and the two counts. Called
    /// whenever any of them changes, and on a theme change for the amber.
    private func renderHero() {
        let words = DictationHeroWords.make(
            status: status, shortcutDisplay: shortcutRecorder.shortcut.displayString,
            localWhisperEnabled: localWhisperSwitch.isOn, cleanupEnabled: cleanupSwitch.isOn,
            model: modelState, modelBytes: WhisperModelManager.shared.downloadedByteCount,
            words: store.vocabulary.count, dictations: store.history.count)
        heroWords = words
        let foot: HelmButton
        switch words.action {
        case .requestAccess(let permission):
            statusActionButton.toolTip = "Request \(permission) Access"
            statusActionButton.setAccessibilityLabel("Request \(permission) Access")
            statusActionButton.isHidden = false
            foot = statusActionButton
        case .recheck:
            statusActionButton.isHidden = true
            foot = recheckButton
        }
        heroCard.panel.configure(header: .init(symbol: "mic.fill", kicker: words.kicker, headline: words.headline,
                                               body: words.body, ring: words.ring),
                                 sections: [], foot: [foot], tone: heroTone(words.tone))
    }

    private func heroTone(_ tone: DictationHeroWords.Tone) -> HelmModuleCard.HeroTone {
        Self.heroTone(tone, in: theme)
    }

    /// The board's one second tone: the theme's own amber while the captain
    /// has to grant something, the accent otherwise. Static so the floating
    /// HUD (DH-2) paints the same two tones from the same rule.
    static func heroTone(_ tone: DictationHeroWords.Tone, in theme: HelmTheme) -> HelmModuleCard.HeroTone {
        switch tone {
        case .accent:
            return HelmModuleCard.HeroTone(colour: .themeAccent)
        case .amber:
            let rgb = HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[3]))
            return HelmModuleCard.HeroTone(colour: .fixed(red: rgb.0, green: rgb.1, blue: rgb.2))
        }
    }

    private func applyTheme() {
        // G4: the shared bar carries its own theme + hue, handed over from the
        // page's own theme pass rather than observed independently.
        modelProgressBar.applyTheme(ThemeManager.shared.theme,
                                    hue: RailDestination.dictation.domainHue)

        // GL-32 (audit §6.1): the history rows grow with the chrome text
        // scale, so the box that shows four of them has to follow.
        historyScrollHeight?.constant = Self.historyScrollHeight()
        // Bug fix (fm/grandline-dictation-global-hotkey-and-theme-fixes):
        // the root view had `wantsLayer = true` (`loadView`) but this method
        // never gave that layer an explicit background color, unlike every
        // other full-size destination (`VaultController`/`FleetController`/
        // etc. - see AGENTS.md's AppKit gotcha #8). With no background set,
        // the layer stayed transparent and whatever sat behind it in the
        // window showed through as visible seams between the panels' own
        // explicitly-themed `chromeBackgroundHex` fills - a captain
        // screenshot showed this as a mismatched brown/maroon color between
        // cards. Setting it here, matching every sibling page.
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        heroCard.applyTheme(theme)
        controlsTitle.attributedStringValue = NSAttributedString(
            string: "Controls".uppercased(), attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        for row in controlRows { row.applyTheme(theme) }
        for rule in controlRules { rule.layer?.backgroundColor = HelmFlatList.hairRowColor(theme).cgColor }
        vocabularyPanel.applyTheme(theme)
        historyPanel.applyTheme(theme)
        cleanupSwitch.applyTheme(theme)
        localWhisperSwitch.applyTheme(theme)
        shortcutRecorder.applyTheme(theme)
        modelReadyPill.configure(text: "Ready", tint: .good, theme: theme)
        // `HelmChipInput` carries its own `ThemeManager` observation (and its
        // own focus registration) - this call only keeps it right if it was
        // built between two theme changes.
        vocabularyInput.applyTheme(theme)
        for header in [vocabularyHeader, historyHeader] {
            header.applyTheme(theme)
        }
        historyListView.applyTheme(theme)
    }

    /// Renders the model download/status row from `modelState` - called
    /// immediately on `WhisperModelManager.observe` registration and on
    /// every subsequent state change while this page is visible.
    private func renderLocalWhisperSection() {
        let detail: String
        switch modelState {
        case .notDownloaded:
            detail = "Not downloaded yet, about 547 MB. Until it is, dictation uses Apple Speech."
            modelReadyPill.isHidden = true
            modelProgressBar.isHidden = true
            modelActionButton.title = "Download Model"
            modelActionIsMain = true
            modelActionButton.isEnabled = true
            modelDeleteButton.isHidden = true
        case .downloading(let progress):
            detail = "Downloading\u{2026} \(Int(progress * 100))%"
            modelReadyPill.isHidden = true
            modelProgressBar.isHidden = false
            modelProgressBar.configure(fraction: progress)
            modelActionButton.title = "Cancel"
            modelActionIsMain = false
            modelActionButton.isEnabled = true
            modelDeleteButton.isHidden = true
        case .ready:
            let size = WhisperModelManager.shared.downloadedByteCount
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            detail = "large-v3-turbo" + (size.map { ", \($0) on this Mac." } ?? " on this Mac.")
            modelReadyPill.isHidden = false
            modelProgressBar.isHidden = true
            // UI-53: the model is already here, so re-fetching it is not the
            // card's main action.
            modelActionButton.title = "Re-download"
            modelActionIsMain = false
            modelActionButton.isEnabled = true
            modelDeleteButton.isHidden = false
        case .failed(let message):
            detail = "Download failed: \(message)"
            modelReadyPill.isHidden = true
            modelProgressBar.isHidden = true
            modelActionButton.title = "Retry Download"
            modelActionIsMain = true
            modelActionButton.isEnabled = true
            // A failed *download* leaves nothing on disk; a failed delete does
            // - so this follows the file, not the state's name.
            modelDeleteButton.isHidden = WhisperModelManager.shared.downloadedByteCount == nil
        }
        modelRow.descriptionLabel?.stringValue = detail
        modelRow.descriptionLabel?.toolTip = detail
        view.needsLayout = true
        renderHero()
        applyActionEmphasis()
        applyTheme()
    }

    /// Whether the model row's button is that card's main action - Download
    /// or Retry, as opposed to Cancel or Re-download.
    private var modelActionIsMain = false

    /// UXP-08: one primary on the page. A missing permission blocks
    /// dictation outright, so while the panel asks for one, its Request Access
    /// pill is the call to action and the model download steps down to
    /// secondary. Found
    /// by CI's window-backed lane, on a runner with neither the permission
    /// nor the model: two filled buttons at once.
    private func applyActionEmphasis() {
        let permissionMissing: Bool
        if case .requestAccess? = heroWords?.action { permissionMissing = true } else { permissionMissing = false }
        let variant: HelmButton.Variant = modelActionIsMain && !permissionMissing ? .primary : .secondary
        if modelActionButton.variant != variant { modelActionButton.variant = variant }
        // R2-UX-04: the main action is the toolbar's, and the card's own
        // button steps out while the toolbar carries it.
        let inToolbar = variant == .primary
        toolbarModelButton.title = modelActionButton.title
        if toolbarModelButton.isHidden == inToolbar { toolbarModelButton.isHidden = !inToolbar }
        modelActionButton.isHidden = inToolbar
    }

    /// Re-reads `store.vocabulary` and re-seeds the well's tokens - called on
    /// every appear and on every `DictationStore.observe` notification,
    /// matching the file header's "no stale list" guarantee.
    ///
    /// `setTokens` only rebuilds the chips; it never touches the editor, so a
    /// word half-typed when a store notification lands is not lost. And it
    /// does not fire `onTokensChanged`, so the store -> observe -> render ->
    /// setTokens path cannot loop back into a write.
    private func renderVocabulary() {
        let words = store.vocabulary
        vocabularyHeader.configure(leading: .tile(symbol: "text.quote", tint: .good), title: "Words I use often",
                                   count: "\(words.count)", subline: "A hint on your next recording")
        vocabularyInput.setTokens(words)
        renderHero()
        onDrillSubtitleChanged?()
    }

    /// Diffs the well's token list against the store and applies the
    /// difference, rather than overwriting the store with the list.
    ///
    /// That is what preserves both behaviours this control inherited: an added
    /// word still goes through `addVocabularyWord`'s own case-insensitive
    /// dedup, and a removed one still offers the GL-33 undo the review named
    /// specifically (this delete used to have no confirmation and no way
    /// back). A wholesale overwrite would have silently dropped both.
    private func applyVocabularyTokens(_ tokens: [String]) {
        let existing = store.vocabulary
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

        for word in tokens where !existing.contains(where: { same($0, word) }) {
            store.addVocabularyWord(word)
        }
        for word in existing where !tokens.contains(where: { same($0, word) }) {
            store.removeVocabularyWord(word)
            if let container = view.window?.contentView {
                Toast.showUndo(in: container, message: "Removed \u{201C}\(word)\u{201D}") { [weak self] in
                    self?.store.addVocabularyWord(word)
                }
            }
        }
    }

    /// Re-reads `store.history` (already newest-first from `DictationStore`)
    /// and reloads the table - see `renderVocabulary` for when this runs.
    private func renderHistory() {
        historyHeader.configure(leading: .tile(symbol: "clock.arrow.circlepath", tint: .neutral),
                                title: "Recent Dictations", count: "\(store.history.count)",
                                subline: "What you said lately, kept on this Mac")
        historyListView.setEntries(store.history)
        renderHero()
        onDrillSubtitleChanged?()
    }

    // MARK: Actions

    @objc private func refreshTapped() {
        refresh()
    }

    private func shortcutChanged(_ newShortcut: KeyChord) {
        AppSettings.shared.dictationShortcut = newShortcut
        onShortcutChanged?(newShortcut)
        render()
    }

    #if FM_SELFTESTS
    /// UXP-16: the reset button and the words well, as drawn.
    var debugShortcutResetIsShowing: Bool { !shortcutResetButton.isHidden }
    var debugVocabularyPlaceholder: String { vocabularyInput.debugDrawnPlaceholder }
    func debugSetShortcut(_ chord: KeyChord) {
        shortcutRecorder.shortcut = chord
        shortcutChanged(chord)
    }
    #endif

    @objc private func resetShortcutTapped() {
        shortcutRecorder.shortcut = .dictationDefault
        shortcutChanged(.dictationDefault)
    }

    @objc private func cleanupToggled() {
        AppSettings.shared.dictationCleanupEnabled = cleanupSwitch.isOn
        renderHero()
    }

    @objc private func localWhisperToggled() {
        let enabled = localWhisperSwitch.isOn
        AppSettings.shared.dictationLocalWhisperEnabled = enabled
        onLocalWhisperEnabledChanged?(enabled)
        renderHero()
    }

    /// The one download/cancel/retry button for the model row - its exact
    /// action depends on `modelState`, matching `statusActionTapped`'s own
    /// "one button, state decides what it does" shape above.
    @objc private func modelActionTapped() {
        switch modelState {
        case .notDownloaded, .failed:
            WhisperModelManager.shared.startDownload()
        case .downloading:
            WhisperModelManager.shared.cancelDownload()
        case .ready:
            WhisperModelManager.shared.startDownload()
        }
    }

    /// GL-35. Confirmed, because it is a ~547MB re-download to undo and this
    /// app's convention is that a destructive action asks first.
    #if FM_SELFTESTS
    /// G3: drive the real model-delete confirmation.
    func debugModelDeleteTapped() { modelDeleteTapped() }
    #endif

    /// The "⋯" menu. One item today; a menu rather than a direct click so a
    /// 547MB delete is two deliberate steps (the menu, then `HelmConfirm`).
    @objc private func modelMoreTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let delete = NSMenuItem(title: "Delete Model\u{2026}", action: #selector(modelDeleteTapped), keyEquivalent: "")
        delete.target = self
        delete.withSymbol("trash")
        menu.addItem(delete)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + HelmMetrics.s1), in: sender)
    }

    @objc private func modelDeleteTapped() {
        let bytes = WhisperModelManager.shared.downloadedByteCount
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "the downloaded model"
        // G3: themed. This site put Delete first, so Return deletes - kept
        // exactly, because changing which key completes a destructive action
        // is a behaviour change, not a restyle.
        guard HelmConfirm.confirm(
            title: "Delete the local Whisper model?",
            body: "This frees \(size). Dictation falls back to Apple's Speech framework, "
                + "and you can download the model again at any time.",
            confirmTitle: "Delete",
            destructive: true,
            symbol: "trash.fill",
            hue: .rose) else { return }
        if WhisperModelManager.shared.deleteDownloadedModel(),
           let container = view.window?.contentView {
            Toast.show(in: container, message: "Local Whisper model deleted")
        }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// D2's headline instance is a *page* behaviour, not a component one - the
    /// suite drives the real well on the real page and checks the real store.
    var debugVocabularyInput: HelmChipInput { vocabularyInput }
    var debugHistoryList: DictationHistoryListView { historyListView }
    func debugSetStatus(_ status: DictationStatus) { setStatus(status) }
    /// UXP-08: put the model row into a state, as `WhisperModelManager`'s
    /// observation would.
    func debugSetModelState(_ state: WhisperModelState) {
        modelState = state
        renderLocalWhisperSection()
    }
    /// Set the two toggles for a render, without writing the preferences.
    func debugSetToggles(cleanup: Bool, localWhisper: Bool) {
        cleanupSwitch.isOn = cleanup
        localWhisperSwitch.isOn = localWhisper
        renderHero()
    }
    var debugModelActionVariant: HelmButton.Variant { modelActionButton.variant }
    func debugRenderVocabulary() { renderVocabulary() }
    /// The chip's rendered frame - review #3's B10 is a *width*, and the
    /// property that was wrong (`setContentHuggingPriority` on a view with no
    /// intrinsic size) reads as correct from the outside.
    var debugModelReadyPillFrame: NSRect { modelReadyPill.frame }
    /// Dic-1: the split card, its words, and the rows on its own surface.
    var debugHeroCard: HelmHeroSplitCard { heroCard }
    var debugHeroWords: DictationHeroWords? { heroWords }
    var debugControlRows: [SettingsRow] { controlRows }
    var debugModelRow: SettingsRow { modelRow }
    var debugLibraryRow: NSView { libraryRow }
    var debugVocabularyCard: HelmCard { vocabularyPanel }
    var debugHistoryCard: HelmCard { historyPanel }
    var debugStatusActionButton: HelmButton { statusActionButton }
    var debugRecheckButton: HelmButton { recheckButton }
    var debugShortcutRecorder: KeyChordRecorderView { shortcutRecorder }
    var debugCleanupSwitch: HelmToggle { cleanupSwitch }
    var debugLocalWhisperSwitch: HelmToggle { localWhisperSwitch }
    var debugModelActionButton: HelmButton { modelActionButton }
    var debugModelDeleteButton: HelmButton { modelDeleteButton }
    var debugModelProgressBar: HelmProgressBar { modelProgressBar }
    /// The floor the description re-wrap applies, so the suite asserts
    /// against the real number rather than re-declaring it.
    static var debugDetailMinimumWidth: CGFloat { detailMinimumWidth }
    #endif

    /// Requests each permission directly via `DictationPermissions`' static
    /// system calls the first time it's genuinely needed - there's no
    /// engine/hotkey instance state involved in a permission *request*
    /// (unlike actually recording), so this page doesn't need anything
    /// forwarded from the app delegate to do it. Re-reads real status
    /// afterward either way (a denial still needs to be reflected honestly).
    @objc private func statusActionTapped() {
        switch status {
        case .needsMicrophone:
            DictationPermissions.requestMicrophone { [weak self] _ in self?.refresh() }
        case .needsSpeechRecognition:
            DictationPermissions.requestSpeechRecognition { [weak self] _ in self?.refresh() }
        case .needsAccessibility, .copiedOnly:
            DictationPermissions.requestAccessibility()
            // No completion callback exists for the Accessibility prompt -
            // the captain has to grant it in System Settings and come back;
            // `viewWillAppear`'s own refresh (on next visit) is what catches
            // a grant made while this page wasn't frontmost. Re-check now
            // too, in case it was already granted (a no-op prompt).
            refresh()
        case .ready, .recording, .transcribing, .cleaningUp, .didNotCatchThat, .systemDictationDisabled:
            break
        }
    }
}

// R2-UX-04: the model download, when it is what the page is for right now,
// is the toolbar's far-right filled button in the sidebar layout.
extension DictationController: WorkspacePrimaryActionProviding {
    func buildSidebarPresentation() {
        toolbarModelButton.target = self
        toolbarModelButton.action = #selector(modelActionTapped)
        toolbarModelButton.toolTip = "Download the local speech model (about 547MB) to this Mac"
        toolbarModelButton.isHidden = true
        applyActionEmphasis()
    }

    var workspacePrimaryAction: NSView? { toolbarModelButton }
}

#if FM_SELFTESTS
extension DictationController {
    var debugToolbarModelButton: HelmButton { toolbarModelButton }
    var debugCardModelButtonIsHidden: Bool { modelActionButton.isHidden }
}
#endif
