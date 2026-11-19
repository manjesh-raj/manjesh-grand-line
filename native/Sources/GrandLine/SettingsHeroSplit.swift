// Grand Line - native macOS app.
//
// Settings' split cards: Set-2 on the second page-redesign board, "Split card
// at the top of the page". Sidebar layout only; the floating bar's Settings
// keeps its hero header.
//
// The settings list stays as it is. Each of the nine pages opens with a
// `HelmHeroSplitCard`: on the gradient, what the page has set right now in
// words (Appearance: "Graphite Dark is showing.", with a preview of the theme
// family), and on the card's own half the page's main choices as the very
// same `SettingsRow`s the page always had, moved out of their sections. The
// rest of the page follows as before. Nothing is rebuilt and no control is
// copied: a row the card holds is the row, with its action and its place in
// `refreshFromSettings`.
//
// **One colour.** Every panel is the theme's accent, as Automic Vault's and
// Dictation's split cards are, so Appearance's panel is the theme that is
// showing. Amber is the one second tone, for a page that needs the captain
// (capture without Accessibility, a shortcut clash), and a reading that is
// not there (App Intents on a copy that publishes none) dims (GL-14).
//
// The words are pure (`SettingsHeroWords`), so `SettingsHeroSplitSelfTest`
// asserts every page's states headless; `SettingsController` owns the
// controls and hands the words over.

import AppKit

// MARK: - The words

/// What one Settings page's panel says.
struct SettingsHeroWords: Equatable {

    enum Tone: Equatable { case accent, amber, dimmed }

    let headline: String
    let body: String?
    let tone: Tone

    /// The tone as the panel's colour in `theme`.
    func heroTone(in theme: HelmTheme) -> HelmModuleCard.HeroTone {
        switch tone {
        case .accent: return HelmModuleCard.HeroTone(colour: .themeAccent)
        case .dimmed: return HelmModuleCard.HeroTone(colour: .themeAccent, isDimmed: true)
        case .amber:
            let rgb = HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[3]))
            return HelmModuleCard.HeroTone(colour: .fixed(red: rgb.0, green: rgb.1, blue: rgb.2))
        }
    }

    /// "Settings · Appearance".
    static func kicker(_ title: String) -> String { "Settings \u{00B7} \(title)" }

    // MARK: Appearance

    /// The page's own "Graphite Dark is showing." line, then the other three
    /// choices on the card and what the terminal paints in.
    static func appearance(themeName: String, isDark: Bool, followsSystem: Bool, layout: WorkspaceLayout,
                           layoutTakesEffectLater: Bool, density: HelmDensity, profile: WorkspaceProfile?,
                           terminal: String) -> SettingsHeroWords {
        let mode = followsSystem
            ? "Following macOS, \(isDark ? "dark" : "light") right now"
            : "\(isDark ? "Dark" : "Light") appearance"
        let layoutName = layout == .sidebar ? "sidebar" : "floating bar"
        let layoutPart = layoutTakesEffectLater
            ? "the \(layoutName) layout from the next launch"
            : "the \(layoutName) layout"
        let profilePart = profile.map { "the \($0.title) profile" } ?? "a custom sidebar"
        let body = "\(mode), \(layoutPart), \(density.title.lowercased()) rows and \(profilePart). "
            + "Terminal: \(terminal)."
        return SettingsHeroWords(headline: "\(themeName) is showing.", body: body, tone: .accent)
    }

    // MARK: Terminal

    static func terminal(scheme: String, fontSize: Int, scrollbackRows: Int, workingDirectory: String?,
                         reconnects: Bool, trimsBackground: Bool, backgroundRows: Int) -> SettingsHeroWords {
        let start = (workingDirectory?.isEmpty ?? true) ? "your home folder" : workingDirectory!
        let reconnect = reconnects ? " and reconnect on their own." : ". A dropped connection waits for \u{2318}R."
        let background = trimsBackground
            ? "Tabs left in the background keep their last \(grouped(backgroundRows)) rows."
            : "Tabs left in the background keep their whole history."
        return SettingsHeroWords(
            headline: "\(scheme), \(fontSize) pt, \(grouped(scrollbackRows)) rows.",
            body: "New Shell and Firstmate tabs start in \(start)\(reconnect) \(background)",
            tone: .accent)
    }

    // MARK: Shortcuts

    static func shortcuts(total: Int, changed: Int, conflicts: Int) -> SettingsHeroWords {
        let changedPart = changed == 0 ? "none changed" : "\(changed) changed"
        let conflictPart: String
        switch conflicts {
        case 0: conflictPart = "no conflicts"
        case 1: conflictPart = "1 conflict"
        default: conflictPart = "\(conflicts) conflicts"
        }
        let body = conflicts > 0
            ? "Two bindings on the same keys means one of them never fires. Show Conflicts lists them, and recording a new chord fixes it."
            : "The terminal's tab, split and pane chords, the capture chord and the dictation key are recorded here. Everything else is set by the menu."
        return SettingsHeroWords(headline: "\(total) shortcuts, \(changedPart), \(conflictPart).", body: body,
                                 tone: conflicts > 0 ? .amber : .accent)
    }

    // MARK: Capture

    static func capture(chord: String, accessibilityGranted: Bool, clipboardHistory: Bool) -> SettingsHeroWords {
        let clipboard = clipboardHistory
            ? "The clipboard history is on, encrypted on this Mac."
            : "The clipboard history is off, so nothing reads the clipboard."
        if accessibilityGranted {
            return SettingsHeroWords(
                headline: "\(chord) works from any app.",
                body: "Accessibility is granted, so the chord reaches Grand Line from anywhere. \(clipboard)",
                tone: .accent)
        }
        return SettingsHeroWords(
            headline: "\(chord) only works while Grand Line is in front.",
            body: "Grant Accessibility below and it works from any app, with no relaunch. \(clipboard)",
            tone: .amber)
    }

    // MARK: Menu Bar

    static func menuBar(compactMode: Bool, hidesDockIcon: Bool, separateIcons: Bool,
                        globalChord: String) -> SettingsHeroWords {
        if compactMode {
            return SettingsHeroWords(
                headline: "Grand Line lives in the menu bar.",
                body: (hidesDockIcon ? "The Dock icon is hidden. " : "The Dock icon stays. ")
                    + "Tasks, notes, the vault and the crew are in the status item's popover, and \(globalChord) opens it from anywhere.",
                tone: .accent)
        }
        if separateIcons {
            return SettingsHeroWords(
                headline: "Window mode, with three menu-bar icons.",
                body: "Tasks, the vault and the crew each have an icon of their own. \(globalChord) brings the window forward from anywhere.",
                tone: .accent)
        }
        return SettingsHeroWords(
            headline: "Window mode, with one menu-bar icon.",
            body: "Tasks, the vault and the crew are its Today, Vault and Crew tabs. \(globalChord) brings the window forward from anywhere.",
            tone: .accent)
    }

    // MARK: Briefings

    static func briefings(enabled: Bool, place: String) -> SettingsHeroWords {
        if enabled {
            return SettingsHeroWords(
                headline: "A briefing opens \(place) each morning.",
                body: "One short generated paragraph over your fleet, PR queue, due tasks and drift, on the first visit each day. It uses your own claude login, one call a day.",
                tone: .accent)
        }
        return SettingsHeroWords(headline: "No morning briefing.",
                                 body: "\(place) opens without the generated paragraph, and nothing is sent to claude for it.",
                                 tone: .accent)
    }

    // MARK: App Intents & Shortcuts

    /// Whether this copy of the app publishes its intents
    /// (`SettingsController.intentRegistration()`).
    enum IntentRegistration: Equatable {
        case registered
        /// A `swift build` binary, which has no bundle to publish from.
        case unbundled
        /// A bundle without `Metadata.appintents`.
        case noMetadata
    }

    static func intents(titles: [String], registration: IntentRegistration, statusText: String) -> SettingsHeroWords {
        let count = titles.count
        let actions = count == 1 ? "1 action" : "\(count) actions"
        switch registration {
        case .registered:
            return SettingsHeroWords(headline: "\(actions) registered with the system.",
                                     body: "\(listed(titles)) appear in Shortcuts, Spotlight and Siri under \u{201C}Grand Line\u{201D}.",
                                     tone: .accent)
        case .unbundled, .noMetadata:
            // GL-14: a list of actions this copy does not publish is not
            // "available", so the panel dims and says why in full.
            return SettingsHeroWords(headline: "\(actions), not registered on this copy.", body: statusText,
                                     tone: .dimmed)
        }
    }

    // MARK: Security

    static func security(lockEnabled: Bool, idle: String, session: String, sudo: SudoTouchIDStatus,
                         vaultPlace: String) -> SettingsHeroWords {
        let lock = lockEnabled ? "Locks after \(idle) idle." : "No app lock."
        let sudoPart: String?
        switch sudo {
        case .enabled, .enabledNixDarwin, .enabledInSudoFile: sudoPart = "Touch ID for sudo is on."
        case .notEnabled, .notEnabledNixDarwin: sudoPart = "Touch ID for sudo is off."
        case .checking, .pamNotConfigured, .checkFailed: sudoPart = nil
        }
        let vault = "The vault keeps its own lock, changed from \(vaultPlace)."
        let body = lockEnabled
            ? "Grand Line asks for its password when it opens, after \(idle) with no input and \(session) after the last unlock. \(vault)"
            : "Grand Line opens without a password. Turned on, it locks after \(idle) idle. \(vault)"
        return SettingsHeroWords(headline: [lock, sudoPart].compactMap { $0 }.joined(separator: " "), body: body,
                                 tone: .accent)
    }

    // MARK: Backup & Restore

    static func backup(lastExport: BackupExportRecord?, hosts: Int, snippets: Int,
                       now: Date = Date(), calendar: Calendar = .current) -> SettingsHeroWords {
        let holds = "A backup holds \(plural(hosts, "host")), \(plural(snippets, "snippet")), your tasks, notebook and stickies, and the sealed vault. Private SSH key material never leaves the Keychain."
        guard let lastExport else {
            return SettingsHeroWords(headline: "No backup exported from this Mac yet.", body: holds, tone: .accent)
        }
        let size = SettingsController.byteText(lastExport.bytes)
        return SettingsHeroWords(headline: "Last export \(day(lastExport.date, now: now, calendar: calendar)), \(size).",
                                 body: "Saved to \(lastExport.destination). \(holds)", tone: .accent)
    }

    /// "today", "yesterday", "12 Nov", or "12 Nov 2025" from another year.
    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "d MMM" : "d MMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: Pieces

    static func grouped(_ number: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: number), number: .decimal)
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// "New Task, New Note and Ask the Crew".
    static func listed(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

// MARK: - The card

/// One Settings page's split card, and the notes that follow it.
///
/// The panel is a `HelmHeroSplitCard`'s, in its `.panel` layout. The detail
/// holds either the page's rows (a `SettingsRowList`, flush like a group's)
/// or one view of the page's own (Backup's inventory) under a small title.
/// Below the card, in the page's muted caption, go the notes the moved rows'
/// sections used to carry, so nothing a section said is lost.
final class SettingsHeroSplitView: NSView {

    /// The prototype's panel width beside the rows.
    static let panelWidth: CGFloat = 400
    /// Below this the panel goes across the top and the rows under it. A
    /// row with a three-way segmented control and a two-line description
    /// needs about 440pt beside the panel.
    static let stackedBelow: CGFloat = 840
    /// The rows' inset inside the detail, so their labels sit 22pt in, the
    /// prototype's native padding (a row carries 14pt of its own).
    static let rowInset: CGFloat = 22 - SettingsRow.Metrics.insetH

    let card = HelmHeroSplitCard(panelWidth: SettingsHeroSplitView.panelWidth,
                                 stackedBelow: SettingsHeroSplitView.stackedBelow)
    /// The rows on the card, when the detail is rows.
    let list: SettingsRowList?
    private let symbol: String
    private let kicker: String
    private let detailTitle = NSTextField(labelWithString: "")
    private let notesStack = NSStackView()
    private(set) var noteLabels: [NSTextField] = []
    private(set) var words = SettingsHeroWords(headline: "", body: nil, tone: .accent)
    private var accessoryTile: SettingsThemePreviewTile?
    private var theme: HelmTheme = ThemeManager.shared.theme
    /// What the panel was last filled with, so a refresh that changes
    /// nothing does not rebuild it (a page refreshes its card from layout
    /// callbacks too).
    private var lastFill: (words: SettingsHeroWords, pills: [ObjectIdentifier], preview: SettingsThemePreviewTile.Content?,
                           theme: String)?

    /// Lines a description on the card shows, the rest in its hover text -
    /// the prototype's one-line descriptions, with room for a second so a
    /// row's point still reads beside a wide control.
    static let descriptionLines = 2

    /// A card whose detail is `rows`.
    convenience init(symbol: String, kicker: String, rows: [SettingsRow], notes: [String]) {
        for row in rows {
            guard let label = row.descriptionLabel else { continue }
            label.maximumNumberOfLines = Self.descriptionLines
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.toolTip = label.stringValue
        }
        let list = SettingsRowList(rows: rows)
        self.init(symbol: symbol, kicker: kicker, detail: list, list: list, title: nil, notes: notes)
    }

    /// A card whose detail is the page's own `view`, under `title`.
    convenience init(symbol: String, kicker: String, detail view: NSView, title: String, notes: [String]) {
        self.init(symbol: symbol, kicker: kicker, detail: view, list: nil, title: title, notes: notes)
    }

    private init(symbol: String, kicker: String, detail content: NSView, list: SettingsRowList?, title: String?,
                 notes: [String]) {
        self.symbol = symbol
        self.kicker = kicker
        self.list = list
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let detail = card.detail
        content.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(content)
        var constraints = [
            content.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: Self.rowInset),
            content.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -Self.rowInset),
            content.bottomAnchor.constraint(lessThanOrEqualTo: detail.bottomAnchor, constant: -HelmMetrics.s2),
        ]
        if let title {
            detailTitle.stringValue = title.uppercased()
            detailTitle.setAccessibilityLabel(title)
            detailTitle.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(detailTitle)
            constraints += [
                detailTitle.topAnchor.constraint(equalTo: detail.topAnchor, constant: HelmMetrics.s4),
                detailTitle.leadingAnchor.constraint(equalTo: detail.leadingAnchor,
                                                     constant: Self.rowInset + SettingsRow.Metrics.insetH),
                content.topAnchor.constraint(equalTo: detailTitle.bottomAnchor, constant: HelmMetrics.s1),
            ]
        } else {
            constraints.append(content.topAnchor.constraint(equalTo: detail.topAnchor, constant: HelmMetrics.s2))
        }
        NSLayoutConstraint.activate(constraints)

        notesStack.orientation = .vertical
        notesStack.alignment = .leading
        notesStack.spacing = HelmMetrics.s1
        notesStack.translatesAutoresizingMaskIntoConstraints = false
        for note in notes where !note.isEmpty {
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = HelmType.caption()
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            noteLabels.append(label)
            notesStack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: notesStack.widthAnchor).isActive = true
        }
        notesStack.isHidden = noteLabels.isEmpty

        // The same gap a section keeps between its card and its foot.
        let column = NSStackView(views: [card, notesStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2 - 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: column.widthAnchor),
            notesStack.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Fill the panel. `pills` are the page's own buttons, which take the
    /// hero's ink there. `preview` draws Appearance's theme family where the
    /// ring would be.
    func configure(_ words: SettingsHeroWords, pills: [NSView], preview: SettingsThemePreviewTile.Content? = nil,
                   theme: HelmTheme) {
        let pillIDs = pills.map(ObjectIdentifier.init)
        if let lastFill, lastFill.words == words, lastFill.pills == pillIDs, lastFill.preview == preview,
           lastFill.theme == theme.id {
            return
        }
        lastFill = (words, pillIDs, preview, theme.id)
        self.words = words
        self.theme = theme
        var accessory: HelmHeroColumn.Accessory?
        if let preview {
            let tile = accessoryTile ?? SettingsThemePreviewTile()
            accessoryTile = tile
            tile.configure(preview)
            accessory = HelmHeroColumn.Accessory(view: tile, caption: preview.caption, spoken: preview.spoken)
        }
        card.panel.configure(header: .init(symbol: symbol, kicker: kicker, headline: words.headline,
                                           body: words.body, ring: nil),
                             sections: [], foot: pills, tone: words.heroTone(in: theme), accessory: accessory)
        card.panel.setAccessibilityLabel([kicker, words.headline, words.body].compactMap { $0 }
            .joined(separator: ". "))
        applyTheme(theme)
    }

    /// Whether the panel sits across the top at this card width.
    static func isStacked(cardWidth: CGFloat) -> Bool { cardWidth < stackedBelow }

    /// The width the rows' descriptions wrap against on a card `width` wide.
    static func rowListWidth(cardWidth: CGFloat) -> CGFloat {
        (isStacked(cardWidth: cardWidth) ? cardWidth : cardWidth - panelWidth) - rowInset * 2
    }

    /// Gotcha (22): wrap against widths the labels do not decide - the
    /// page's, less the panel when it sits beside the rows.
    func relayout(cardWidth: CGFloat) {
        list?.relayoutDescriptions(cardWidth: Self.rowListWidth(cardWidth: cardWidth))
        for label in noteLabels where abs(label.preferredMaxLayoutWidth - cardWidth) > 0.5 {
            label.preferredMaxLayoutWidth = cardWidth
            label.invalidateIntrinsicContentSize()
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        list?.applyTheme(theme)
        detailTitle.attributedStringValue = NSAttributedString(
            string: detailTitle.stringValue, attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        for label in noteLabels { label.textColor = HelmTheme.mutedInk(theme) }
        accessoryTile?.applyInk(card.panel.ink)
    }

    #if FM_SELFTESTS
    var debugPreviewTile: SettingsThemePreviewTile? { accessoryTile }
    #endif
}

// MARK: - Appearance's preview

/// Appearance's preview of the theme family on the gradient: the light
/// register on the left and the dark one on the right, each its own ground
/// with a card and an accent line, and the half that is showing ringed in
/// the ink. Drawn from the registers' tokens, so it is the palette rather
/// than a picture of one.
final class SettingsThemePreviewTile: NSView {

    struct Content: Equatable {
        let light: HelmTheme
        let dark: HelmTheme
        let showingDark: Bool
        /// "Graphite · Dark".
        let caption: String
        let spoken: String

        static func == (a: Content, b: Content) -> Bool {
            a.light.id == b.light.id && a.dark.id == b.dark.id && a.showingDark == b.showingDark
                && a.caption == b.caption && a.spoken == b.spoken
        }
    }

    static let size = NSSize(width: 76, height: 52)
    static let cornerRadius: CGFloat = 9

    private let halves = [NSView(), NSView()]
    private let cards = [NSView(), NSView()]
    private let accents = [NSView(), NSView()]
    private let marker = NSView()
    private(set) var content: Content?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        let halfWidth = Self.size.width / 2
        for index in 0..<2 {
            let half = halves[index]
            half.wantsLayer = true
            half.translatesAutoresizingMaskIntoConstraints = false
            addSubview(half)
            for piece in [cards[index], accents[index]] {
                piece.wantsLayer = true
                piece.layer?.cornerRadius = HelmMetrics.s0
                piece.translatesAutoresizingMaskIntoConstraints = false
                half.addSubview(piece)
            }
            NSLayoutConstraint.activate([
                half.topAnchor.constraint(equalTo: topAnchor),
                half.bottomAnchor.constraint(equalTo: bottomAnchor),
                half.widthAnchor.constraint(equalToConstant: halfWidth),
                half.leadingAnchor.constraint(equalTo: leadingAnchor, constant: halfWidth * CGFloat(index)),
                cards[index].leadingAnchor.constraint(equalTo: half.leadingAnchor, constant: HelmMetrics.s2),
                cards[index].trailingAnchor.constraint(equalTo: half.trailingAnchor, constant: -HelmMetrics.s2),
                cards[index].topAnchor.constraint(equalTo: half.topAnchor, constant: HelmMetrics.s2),
                cards[index].heightAnchor.constraint(equalToConstant: 20),
                accents[index].leadingAnchor.constraint(equalTo: half.leadingAnchor, constant: HelmMetrics.s2),
                accents[index].widthAnchor.constraint(equalToConstant: 16),
                accents[index].heightAnchor.constraint(equalToConstant: 4),
                accents[index].bottomAnchor.constraint(equalTo: half.bottomAnchor, constant: -HelmMetrics.s2),
            ])
        }
        // The half that is showing: an inset ring in the ink.
        marker.wantsLayer = true
        marker.layer?.borderWidth = 2
        marker.layer?.cornerRadius = Self.cornerRadius - 3
        marker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marker)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            marker.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            marker.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            marker.widthAnchor.constraint(equalToConstant: halfWidth - 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var markerLeading: NSLayoutConstraint?

    func configure(_ content: Content) {
        self.content = content
        for (index, register) in [content.light, content.dark].enumerated() {
            halves[index].layer?.backgroundColor = HelmTheme.nsColor(register.backgroundHex).cgColor
            cards[index].layer?.backgroundColor = HelmTheme.nsColor(register.chromeBackgroundHex).cgColor
            accents[index].layer?.backgroundColor = HelmTheme.nsColor(register.accentHex).cgColor
        }
        markerLeading?.isActive = false
        markerLeading = marker.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                        constant: content.showingDark ? Self.size.width / 2 + 1 : 2)
        markerLeading?.isActive = true
    }

    /// The tile's edge and the showing half's ring take the hero's ink.
    func applyInk(_ ink: NSColor) {
        layer?.borderColor = ink.withAlphaComponent(0.5).cgColor
        marker.layer?.borderColor = ink.cgColor
    }

    #if FM_SELFTESTS
    var debugMarkerFrame: NSRect { marker.frame }
    var debugHalfColours: [CGColor?] { halves.map { $0.layer?.backgroundColor } }
    #endif
}
