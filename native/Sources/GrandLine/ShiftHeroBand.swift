// Grand Line - native macOS app.
//
// Tasks as T-4 on the page-redesign board (`data/grand-line-page-redesign-
// mockups/`), the captain's pick: "Slim band, then every lane wears its own
// band". Sidebar layout only; the floating bar's Tasks page is unchanged.
//
// Two views, both painted with `HelmHeroSurface` and its one palette rule:
//
//   - `ShiftTasksHeroBand`: the page's hero, shrunk to a slim band over the
//     filter row - the kicker and the day's verdict, Due today / Overdue /
//     Follow-ups / Done in 7 days as inline figures, and a small ring of the
//     week's done work. It is short on purpose, so the board starts about
//     where it did before the band existed.
//   - `ShiftLaneHeroBand`: each board lane's header as a toned band - the
//     accent for Backlog, slate for In Progress, green for Done and amber for
//     Follow-ups - with the lane's count as a big number, a detail line and a
//     ghost "+" that adds to that lane. The task cards under it stay quiet.
//
// **Words come from `ShiftHeroWords`**, which is pure, so the verdicts and the
// lanes' detail lines are asserted headless (`TasksSecretsHeroSelfTest`).
//
// **One colour rule.** Each tone is a colour handed to `HelmHeroSurface`'s
// quiet-ink palette, the one the hero column uses, so the ink and the 85% ink
// of a detail line clear the text floor on every theme - including the light
// amber and green tones, which deepen until they do.

import AppKit

// MARK: - The words

enum ShiftHeroWords {

    struct Band: Equatable {
        let kicker: String
        let headline: String
        /// Due today, overdue, follow-ups, done in the last seven days -
        /// `nil` while the store could not be read (GL-14).
        let figures: (open: Int, due: Int, overdue: Int, followUps: Int, done: Int)?
        /// Done this week out of everything open or done this week.
        let ring: (done: Int, total: Int)?
        let isDimmed: Bool

        static func == (a: Band, b: Band) -> Bool {
            a.kicker == b.kicker && a.headline == b.headline && a.isDimmed == b.isDimmed
                && a.figures?.open == b.figures?.open
                && a.figures?.due == b.figures?.due && a.figures?.overdue == b.figures?.overdue
                && a.figures?.followUps == b.figures?.followUps && a.figures?.done == b.figures?.done
                && a.ring?.done == b.ring?.done && a.ring?.total == b.ring?.total
        }
    }

    static let kickerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    /// The band for the page's counts. `summary` is `nil` for a store that
    /// failed to read, which is never drawn as zeroes.
    static func band(summary: ShiftStore.Summary?, doneLastWeek: Int, now: Date = DayRollover.now()) -> Band {
        let kicker = "Tasks \u{00B7} \(kickerFormatter.string(from: now))"
        guard let summary else {
            return Band(kicker: kicker, headline: "Your tasks could not be read.", figures: nil, ring: nil,
                        isDimmed: true)
        }
        let needs = summary.dueToday + summary.overdue
        let headline: String
        if needs == 1 {
            headline = "1 thing needs you today."
        } else if needs > 1 {
            headline = "\(needs) things need you today."
        } else if summary.followUps > 0 {
            headline = summary.followUps == 1 ? "Only a follow-up is waiting." : "Only follow-ups are waiting."
        } else if summary.open > 0 {
            headline = "Nothing is due today."
        } else {
            headline = "Nothing on the board."
        }
        let total = summary.open + doneLastWeek
        return Band(kicker: kicker, headline: headline,
                    figures: (summary.open, summary.dueToday, summary.overdue, summary.followUps, doneLastWeek),
                    ring: total > 0 ? (doneLastWeek, total) : nil, isDimmed: false)
    }

    /// A lane's detail line: what in it is late or due, from each item's due
    /// day and time. "1 overdue · 1 due today", then "2 due tomorrow", then
    /// "Nothing due soon" - or `empty` for a lane with nothing in it.
    static func laneDetail(dues: [(date: String?, time: String?)], empty: String, now: Date = DayRollover.now(),
                           calendar: Calendar = .current) -> String {
        guard !dues.isEmpty else { return empty }
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return "" }
        var overdue = 0, dueToday = 0, dueTomorrow = 0
        for due in dues {
            guard let day = due.date.flatMap(ShiftDateFormatting.date(from:)) else { continue }
            if ShiftDue.isOverdue(date: due.date, time: due.time, now: now, calendar: calendar) {
                overdue += 1
            } else if calendar.isDate(day, inSameDayAs: today) {
                dueToday += 1
            } else if calendar.isDate(day, inSameDayAs: tomorrow) {
                dueTomorrow += 1
            }
        }
        var parts: [String] = []
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if dueToday > 0 { parts.append("\(dueToday) due today") }
        if parts.isEmpty, dueTomorrow > 0 { parts.append("\(dueTomorrow) due tomorrow") }
        return parts.isEmpty ? "Nothing due soon" : parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - The tones

/// A lane band's colour: the board's accent, slate, green and amber. The
/// three that are not the accent come from the theme's own terminal slots,
/// so a palette's green and amber are the ones its lanes wear.
enum ShiftLaneTone: Equatable {
    case accent, slate, green, amber

    /// A cool grey-blue: the In Progress lane's colour in every theme, since
    /// no palette slot is a neutral that reads as a colour.
    static let slateHex = "#5B6B82"

    func accent(in theme: HelmTheme) -> (Double, Double, Double) {
        let hex: String
        switch self {
        case .accent: hex = theme.heroAccentHex
        case .slate: hex = Self.slateHex
        case .green: hex = theme.ansiHex[2]
        case .amber: hex = theme.ansiHex[3]
        }
        return HelmContrast.components(HelmTheme.nsColor(hex))
    }

    /// The tone's palette, deepened so its second lines clear the text floor
    /// at `ShiftLaneHeroBand.detailAlpha` too.
    func palette(in theme: HelmTheme) -> HelmHeroSurface.Palette {
        HelmHeroSurface.palette(accent: accent(in: theme), quietInk: Double(ShiftLaneHeroBand.detailAlpha))
    }
}

// MARK: - The slim band

/// The page's hero, and since Tf-2 (the five-screen redesign board,
/// `data/grandline-page-redesign-options/`) also the page's filters.
///
/// The captain picked "The hero's figures are the filters": the grey count
/// line above the band and the filter row under it both said what the band's
/// figures already said, so the line is gone and the row's controls live in
/// the band. Its four figures are buttons - All open, Due today and Overdue
/// pick the scope, drawn solid in the ink while they are on, and Follow-ups
/// jumps to the Follow-ups card when the board is not already showing them as
/// a lane. Under a hairline, Smart views and the project and sort menus sit
/// as glass pills. Every count appears exactly once on the page.
///
/// The band holds no state of its own: `ShiftController` tells it which scope
/// is on and what the menus say (`setFilters`), and hears every choice back
/// through the callbacks, so the selection has one owner.
final class ShiftTasksHeroBand: NSView {

    static let cornerRadius: CGFloat = 14
    static let ringSide: CGFloat = 44
    static let headlineSize: CGFloat = 20
    static let insets = NSEdgeInsets(top: 14, left: 22, bottom: 12, right: 22)
    /// The verdict keeps at least this much beside the figures before they
    /// drop to a row of their own under it.
    static let wordsMinimumWidth: CGFloat = 220
    static let figureGap: CGFloat = HelmMetrics.s2

    /// The scope ids the figures and Smart views carry - `ShiftTaskScope`'s
    /// raw values, so the controller maps them back without a second table.
    static let figureScopes = ["all", "due_today", "overdue"]
    static let smartViewScopes = ["my_priorities", "recently_updated"]

    /// A scope was picked: a figure, or a Smart view (picking the one that is
    /// on goes back to All tasks).
    var onSelectScope: ((String) -> Void)?
    /// The Follow-ups figure was clicked, when it jumps anywhere.
    var onFollowUps: (() -> Void)?
    /// The project and sort menus, shown from the pill that was clicked.
    var onShowProjectMenu: ((NSView) -> Void)?
    var onShowSortMenu: ((NSView) -> Void)?

    private let surface = HelmHeroSurface()
    private let tile = NSView()
    private let glyph = NSImageView()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(labelWithString: "")
    private let text = NSStackView()
    private let figureRow = NSStackView()
    private let allFigure = ShiftHeroFigureButton(caption: "All open")
    private let dueFigure = ShiftHeroFigureButton(caption: "Due today")
    private let overdueFigure = ShiftHeroFigureButton(caption: "Overdue")
    private let followUpsFigure = ShiftHeroFigureButton(caption: "Follow-ups")
    private let ring = HelmRingGauge(side: ShiftTasksHeroBand.ringSide)
    private let ringCaption = NSTextField(labelWithString: "done, 7 days")
    /// The ring over its caption. A plain view rather than a stack: the
    /// caption is wider than the ring, and the column has to be as wide as
    /// the wider of the two.
    private let ringColumn = NSView()
    private let topRow = NSStackView()
    private let divider = NSView()
    private let smartLabel = NSTextField(labelWithString: "")
    private lazy var prioritiesPill = HelmButton(title: "My priorities", variant: .secondary, size: .small,
                                                 symbol: "bolt", target: self, action: #selector(prioritiesTapped))
    private lazy var recentPill = HelmButton(title: "Recently updated", variant: .secondary, size: .small,
                                             symbol: "clock.arrow.circlepath", target: self,
                                             action: #selector(recentTapped))
    private lazy var projectPill = HelmButton(title: "All projects", variant: .secondary, size: .small,
                                              symbol: "chevron.down", target: self, action: #selector(projectTapped))
    private lazy var sortPill = HelmButton(title: "Due date", variant: .secondary, size: .small,
                                           symbol: "chevron.down", target: self, action: #selector(sortTapped))
    private let filterRow = NSStackView()
    private let column = NSStackView()
    private var words = ShiftHeroWords.band(summary: nil, doneLastWeek: 0)
    private var scope = "all"
    private var projectFiltered = false
    /// Whether the figures sit on a row of their own under the words.
    private(set) var figuresStacked = false
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        addSubview(surface)

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 6
        tile.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = HelmSymbol.image("checkmark", pointSize: 11, weight: .bold)
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        kickerLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.font = .systemFont(ofSize: HelmType.scaled(Self.headlineSize), weight: .bold)
        headlineLabel.lineBreakMode = .byTruncatingTail
        for label in [kickerLabel, headlineLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setAccessibilityElement(false)
        }
        let kickerRow = NSStackView(views: [tile, kickerLabel])
        kickerRow.orientation = .horizontal
        kickerRow.spacing = HelmMetrics.s2
        kickerRow.alignment = .centerY
        for view in [kickerRow, headlineLabel] { text.addArrangedSubview(view) }
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s1
        for stack in [kickerRow, text] {
            stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
            stack.setHuggingPriority(.defaultLow, for: .horizontal)
        }

        // The figures: three scopes and the Follow-ups jump.
        allFigure.setAction { [weak self] in self?.onSelectScope?("all") }
        dueFigure.setAction { [weak self] in self?.onSelectScope?("due_today") }
        overdueFigure.setAction { [weak self] in self?.onSelectScope?("overdue") }
        allFigure.toolTip = "Show every open task"
        dueFigure.toolTip = "Show the tasks due today"
        overdueFigure.toolTip = "Show the overdue tasks"
        for figure in [allFigure, dueFigure, overdueFigure, followUpsFigure] { figureRow.addArrangedSubview(figure) }
        figureRow.orientation = .horizontal
        figureRow.spacing = Self.figureGap
        figureRow.alignment = .centerY
        figureRow.setAccessibilityElement(true)
        figureRow.setAccessibilityRole(.group)
        figureRow.setAccessibilityLabel("Which tasks to show")
        // Gotcha (12): a stack's own priorities. The figures keep their width.
        figureRow.setHuggingPriority(.required, for: .horizontal)
        figureRow.setClippingResistancePriority(.required, for: .horizontal)

        ringCaption.font = .systemFont(ofSize: HelmType.scaled(10.5), weight: .medium)
        ringCaption.setAccessibilityElement(false)
        // The caption is wider than the ring, so it - not the ring - sets the
        // column's width (gotcha (5)); otherwise it overhangs the band's edge.
        ringCaption.setContentCompressionResistancePriority(.required, for: .horizontal)
        ringCaption.setContentHuggingPriority(.required, for: .horizontal)
        ringColumn.translatesAutoresizingMaskIntoConstraints = false
        for view in [ring, ringCaption] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            ringColumn.addSubview(view)
        }
        // Above the words' own hugging, so the words take the band's slack,
        // and inside gotcha (13)'s 251-499 band so it never holds the window.
        let hug = ringColumn.widthAnchor.constraint(equalToConstant: 0)
        hug.priority = NSLayoutConstraint.Priority(300)
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: ringColumn.topAnchor),
            ring.centerXAnchor.constraint(equalTo: ringColumn.centerXAnchor),
            ringCaption.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: HelmMetrics.s1),
            ringCaption.centerXAnchor.constraint(equalTo: ringColumn.centerXAnchor),
            ringCaption.bottomAnchor.constraint(equalTo: ringColumn.bottomAnchor),
            ringColumn.widthAnchor.constraint(greaterThanOrEqualTo: ring.widthAnchor),
            ringColumn.widthAnchor.constraint(greaterThanOrEqualTo: ringCaption.widthAnchor),
            hug,
        ])

        for view in [text, figureRow, ringColumn] { topRow.addArrangedSubview(view) }
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = HelmMetrics.s5
        topRow.distribution = .fill
        topRow.detachesHiddenViews = true
        topRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        topRow.setHuggingPriority(.defaultLow, for: .horizontal)

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        smartLabel.setContentHuggingPriority(.required, for: .horizontal)
        smartLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        smartLabel.setAccessibilityElement(false)
        projectPill.symbolTrailing = true
        sortPill.symbolTrailing = true
        prioritiesPill.toolTip = "Show the tasks you marked high priority"
        recentPill.toolTip = "Show the tasks changed in the last week"
        projectPill.toolTip = "Show one project's tasks"
        sortPill.toolTip = "Sort the lanes and the list"
        projectPill.setAccessibilityLabel("Project")
        sortPill.setAccessibilityLabel("Sort tasks by")
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacerWidth = spacer.widthAnchor.constraint(equalToConstant: 0)
        spacerWidth.priority = .defaultLow
        spacerWidth.isActive = true
        for view in [smartLabel, prioritiesPill, recentPill, spacer, projectPill, sortPill] as [NSView] {
            filterRow.addArrangedSubview(view)
        }
        for pill in [prioritiesPill, recentPill, projectPill, sortPill] {
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = HelmMetrics.s2
        filterRow.distribution = .fill
        filterRow.detachesHiddenViews = true
        filterRow.setCustomSpacing(HelmMetrics.s3, after: smartLabel)
        filterRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        filterRow.setHuggingPriority(.defaultLow, for: .horizontal)

        for view in [topRow, divider, filterRow] { column.addArrangedSubview(view) }
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        let insets = Self.insets
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            tile.widthAnchor.constraint(equalToConstant: 20),
            tile.heightAnchor.constraint(equalToConstant: 20),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            column.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            topRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            divider.widthAnchor.constraint(equalTo: column.widthAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            filterRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        configure(words)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    func configure(_ words: ShiftHeroWords.Band) {
        self.words = words
        kickerLabel.stringValue = words.kicker.uppercased()
        headlineLabel.stringValue = words.headline
        // GL-14: a store that could not be read draws no counts, never zero.
        let figures = words.figures
        allFigure.configure(count: figures.map { "\($0.open)" } ?? "\u{2013}")
        dueFigure.configure(count: figures.map { "\($0.due)" } ?? "\u{2013}")
        overdueFigure.configure(count: figures.map { "\($0.overdue)" } ?? "\u{2013}")
        followUpsFigure.configure(count: figures.map { "\($0.followUps)" } ?? "\u{2013}")
        if let ring = words.ring {
            self.ring.configure(fraction: Double(ring.done) / Double(max(1, ring.total)), text: "\(ring.done)")
            self.ring.setSpokenLabel("\(ring.done) of \(ring.total) done in the last 7 days")
        }
        ringColumn.isHidden = words.ring == nil
        setAccessibilityLabel("\(words.kicker). \(words.headline)")
        applyTheme(theme)
        needsLayout = true
    }

    /// What the filters say: the scope that is on, the project menu's title
    /// (and whether a project is picked), the sort menu's title - `nil` where
    /// the view has no sort - and whether Follow-ups jumps anywhere.
    func setFilters(scope: String, projectTitle: String, projectFiltered: Bool, sortTitle: String?,
                    followUpsJumps: Bool) {
        self.scope = scope
        self.projectFiltered = projectFiltered
        projectPill.title = projectTitle
        sortPill.isHidden = sortTitle == nil
        if let sortTitle { sortPill.title = sortTitle }
        followUpsFigure.setAction(followUpsJumps ? { [weak self] in self?.onFollowUps?() } : nil)
        followUpsFigure.toolTip = followUpsJumps ? "Go to the Follow-ups card" : nil
        applySelection()
        needsLayout = true
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let accent = HelmContrast.components(HelmTheme.nsColor(theme.heroAccentHex))
        let palette = HelmHeroSurface.palette(accent: words.isDimmed ? HelmHeroSurface.dimmed(accent) : accent,
                                              quietInk: 0.85)
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        let quiet = ink.withAlphaComponent(0.85)
        // A white-ink hero is a dark surface, so the pills' focus rings and
        // any system colour they resolve are the dark appearance's.
        appearance = NSAppearance(named: HelmContrast.relativeLuminance(palette.ink) < 0.5 ? .aqua : .darkAqua)
        tile.layer?.backgroundColor = ink.withAlphaComponent(HelmHeroColumn.tileFillAlpha).cgColor
        glyph.contentTintColor = ink
        kickerLabel.attributedStringValue = NSAttributedString(
            string: kickerLabel.stringValue, attributes: HelmType.kickerAttributes(color: quiet))
        headlineLabel.textColor = ink
        smartLabel.attributedStringValue = NSAttributedString(
            string: "SMART VIEWS", attributes: HelmType.kickerAttributes(color: quiet))
        ringCaption.textColor = quiet
        divider.layer?.backgroundColor = ink.withAlphaComponent(0.18).cgColor
        let wash = HelmHeroCard.tileWash(for: palette)
        let hover = HelmHeroCard.tileWash(for: palette, hovered: true)
        let deep = Self.deepStop(of: palette)
        for figure in [allFigure, dueFigure, overdueFigure, followUpsFigure] {
            figure.apply(ink: ink, fill: HelmContrast.color(wash.rgb).withAlphaComponent(wash.alpha),
                         hoverFill: HelmContrast.color(hover.rgb).withAlphaComponent(hover.alpha), selectedLabel: deep)
        }
        for pill in [prioritiesPill, recentPill, projectPill, sortPill] { pill.heroInk = ink }
        ring.trackColorOverride = ink.withAlphaComponent(0.25)
        ring.labelColorOverride = ink
        ring.valueColorOverride = ink
        ring.applyTheme(theme, hue: .blue)
        applySelection()
    }

    /// The hero's deeper stop: what a solid-ink control's label is drawn in.
    static func deepStop(of palette: HelmHeroSurface.Palette) -> NSColor {
        let start = HelmContrast.relativeLuminance(palette.start)
        let end = HelmContrast.relativeLuminance(palette.end)
        return HelmContrast.color(start < end ? palette.start : palette.end)
    }

    private func applySelection() {
        allFigure.isSelected = scope == "all"
        dueFigure.isSelected = scope == "due_today"
        overdueFigure.isSelected = scope == "overdue"
        followUpsFigure.isSelected = false
        let accent = HelmContrast.components(HelmTheme.nsColor(theme.heroAccentHex))
        let palette = HelmHeroSurface.palette(accent: words.isDimmed ? HelmHeroSurface.dimmed(accent) : accent,
                                              quietInk: 0.85)
        let deep = Self.deepStop(of: palette)
        prioritiesPill.heroSelection = scope == "my_priorities" ? deep : nil
        recentPill.heroSelection = scope == "recently_updated" ? deep : nil
        projectPill.heroSelection = projectFiltered ? deep : nil
        prioritiesPill.setAccessibilityValue(scope == "my_priorities" ? "selected" : nil)
        recentPill.setAccessibilityValue(scope == "recently_updated" ? "selected" : nil)
    }

    override func layout() {
        super.layout()
        applyWidthRules()
    }

    /// The figures are the page's filters, so they never leave the band: when
    /// the verdict, the figures and the ring do not fit on one line, the ring
    /// steps out first and then the figures drop to a row of their own under
    /// the words. The Smart views label is the first thing the pills' row
    /// gives up.
    private func applyWidthRules() {
        let available = bounds.width - Self.insets.left - Self.insets.right
        guard available > 0 else { return }
        let gap = topRow.spacing
        let figures = figureRow.fittingSize.width
        let ringWidth = words.ring == nil ? 0 : ringColumn.fittingSize.width + gap
        let wordsWidth = Self.wordsMinimumWidth + gap
        let stack = wordsWidth + figures > available
        let needed = stack ? Self.wordsMinimumWidth + ringWidth : wordsWidth + figures + ringWidth
        let showsRing = words.ring != nil && needed <= available
        if stack != figuresStacked {
            figuresStacked = stack
            if stack {
                topRow.removeArrangedSubview(figureRow)
                column.insertArrangedSubview(figureRow, at: 1)
            } else {
                column.removeArrangedSubview(figureRow)
                topRow.insertArrangedSubview(figureRow, at: 1)
            }
        }
        if ringColumn.isHidden == showsRing { ringColumn.isHidden = !showsRing }
        let pills = [prioritiesPill, recentPill, projectPill, sortPill].filter { !$0.isHidden }
        let pillsWidth = pills.reduce(0) { $0 + $1.fittingSize.width } + CGFloat(pills.count) * filterRow.spacing
        let showsLabel = pillsWidth + smartLabel.fittingSize.width + HelmMetrics.s3 <= available
        if smartLabel.isHidden == showsLabel { smartLabel.isHidden = !showsLabel }
    }

    @objc private func prioritiesTapped() { onSelectScope?(scope == "my_priorities" ? "all" : "my_priorities") }
    @objc private func recentTapped() { onSelectScope?(scope == "recently_updated" ? "all" : "recently_updated") }
    @objc private func projectTapped() { onShowProjectMenu?(projectPill) }
    @objc private func sortTapped() { onShowSortMenu?(sortPill) }

    #if FM_SELFTESTS
    var debugHeadline: String { headlineLabel.stringValue }
    var debugKicker: String { kickerLabel.stringValue }
    var debugFigureButtons: [ShiftHeroFigureButton] { [allFigure, dueFigure, overdueFigure, followUpsFigure] }
    var debugFigureCaptions: [String] { debugFigureButtons.map(\.caption) }
    var debugSelectedFigure: String? { debugFigureButtons.first(where: \.isSelected)?.caption }
    var debugRing: HelmRingGauge? { ringColumn.isHidden ? nil : ring }
    var debugPalette: HelmHeroSurface.Palette? { surface.palette }
    var debugHeadlineColor: NSColor? { headlineLabel.textColor }
    var debugPills: (priorities: HelmButton, recent: HelmButton, project: HelmButton, sort: HelmButton) {
        (prioritiesPill, recentPill, projectPill, sortPill)
    }
    var debugSmartLabelShown: Bool { !smartLabel.isHidden }
    var debugFiguresInTopRow: Bool { topRow.arrangedSubviews.contains(figureRow) }
    #endif
}

/// One of the band's figures as a button (Tf-2): a big count over its
/// caption on a frosted well, drawn solid in the hero's ink while it is the
/// filter that is on. A figure with no action is a plain figure - the
/// Follow-ups count while the board already shows them as a lane - and
/// `HoverHighlightView` then leaves it out of VoiceOver's buttons and the key
/// loop, as it does any view that does nothing when pressed.
final class ShiftHeroFigureButton: HoverHighlightView {

    static let minWidth: CGFloat = 92
    static let countSize: CGFloat = 22
    static let padding = NSEdgeInsets(top: 8, left: 13, bottom: 9, right: 13)

    let caption: String
    var isSelected = false {
        didSet { if isSelected != oldValue { restyle() } }
    }

    private let countLabel = NSTextField(labelWithString: "0")
    private let captionLabel = NSTextField(labelWithString: "")
    private var action: (() -> Void)?
    private var recognizer: NSClickGestureRecognizer?
    private var ink: NSColor = .white
    private var fill: NSColor = .clear
    private var hoverFill: NSColor = .clear
    private var selectedLabel: NSColor = .black

    init(caption: String) {
        self.caption = caption
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = 12
        layer?.borderWidth = 1
        captionLabel.stringValue = caption
        countLabel.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(Self.countSize), weight: .bold)
        captionLabel.font = .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
        for label in [countLabel, captionLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byClipping
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(label)
        }
        let p = Self.padding
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.left),
            countLabel.topAnchor.constraint(equalTo: topAnchor, constant: p.top),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.left),
            captionLabel.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 2),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p.bottom),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -p.right),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -p.right),
        ])
        // Gotcha (12): a plain view has no intrinsic size, so hugging on it
        // does nothing and a row of figures takes the band's slack. This one
        // reports its words' own width, and holds to it.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityValueOverride()
    }

    /// The wider of the count and the caption, inside the padding, never
    /// narrower than `minWidth` so the four figures read as one set.
    override var intrinsicContentSize: NSSize {
        let words = max(countLabel.intrinsicContentSize.width, captionLabel.intrinsicContentSize.width)
        return NSSize(width: max(Self.minWidth, ceil(words) + Self.padding.left + Self.padding.right),
                      height: NSView.noIntrinsicMetric)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The click, or `nil` for a plain figure.
    func setAction(_ action: (() -> Void)?) {
        self.action = action
        if action == nil {
            if let recognizer { removeGestureRecognizer(recognizer) }
            recognizer = nil
            pressScale = 1
        } else if recognizer == nil {
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
            addGestureRecognizer(click)
            recognizer = click
            pressScale = 0.97
        }
        restyle()
    }

    @objc private func clicked() { action?() }

    func configure(count: String) {
        countLabel.stringValue = count
        invalidateIntrinsicContentSize()
        accessibilityLabelOverride = "\(caption), \(count)"
    }

    func apply(ink: NSColor, fill: NSColor, hoverFill: NSColor, selectedLabel: NSColor) {
        self.ink = ink
        self.fill = fill
        self.hoverFill = hoverFill
        self.selectedLabel = selectedLabel
        restyle()
    }

    private func setAccessibilityValueOverride() {
        accessibilityValueOverride = isSelected ? "selected" : nil
    }

    private func restyle() {
        let text = isSelected ? selectedLabel : ink
        normalColor = isSelected ? ink : fill
        hoverColor = isSelected ? ink.withAlphaComponent(0.92) : (isActivatable ? hoverFill : fill)
        layer?.borderColor = (isSelected ? ink : ink.withAlphaComponent(0.18)).cgColor
        countLabel.textColor = text
        captionLabel.textColor = isSelected ? text : ink.withAlphaComponent(0.9)
        setAccessibilityValueOverride()
    }

    #if FM_SELFTESTS
    var debugCount: String { countLabel.stringValue }
    var debugCountColor: NSColor? { countLabel.textColor }
    var debugFillColor: NSColor { normalColor }
    var debugIsActivatable: Bool { isActivatable }
    #endif
}

// MARK: - A lane's band

final class ShiftLaneHeroBand: NSView {

    static let countSize: CGFloat = 24
    /// The detail line's share of the ink, the board's 0.88 rounded down to
    /// the palette's tested step.
    static let detailAlpha: CGFloat = 0.85
    static let insets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 12)

    let tone: ShiftLaneTone
    private let surface = HelmHeroSurface()
    private let countLabel = NSTextField(labelWithString: "0")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// The lane's ghost "+", or none for the Done lane.
    let addButton: HelmButton?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    init(tone: ShiftLaneTone, title: String, addTooltip: String?, target: AnyObject?, action: Selector?) {
        self.tone = tone
        if let addTooltip {
            let button = HelmButton(title: "", variant: .secondary, size: .small, symbol: "plus",
                                    target: target, action: action)
            button.toolTip = addTooltip
            button.setAccessibilityLabel(addTooltip)
            addButton = button
        } else {
            addButton = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        countLabel.font = HelmType.rounded(HelmType.scaled(Self.countSize), .bold)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.stringValue = title.uppercased()
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(11), weight: .semibold)
        detailLabel.font = .systemFont(ofSize: HelmType.scaled(11.5))
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        for label in [countLabel, titleLabel, detailLabel] { label.setAccessibilityElement(false) }
        let words = NSStackView(views: [titleLabel, detailLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = HelmMetrics.s0
        words.setClippingResistancePriority(.defaultLow, for: .horizontal)
        words.setHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [countLabel, words]
        if let addButton {
            addButton.setContentHuggingPriority(.required, for: .horizontal)
            addButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(addButton)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2 + 2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)
        let insets = Self.insets
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            row.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    func configure(count: Int, detail: String) {
        countLabel.stringValue = "\(count)"
        detailLabel.stringValue = detail
        setAccessibilityLabel("\(titleLabel.stringValue.capitalized), \(count). \(detail)")
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let palette = tone.palette(in: theme)
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        countLabel.textColor = ink
        titleLabel.attributedStringValue = NSAttributedString(
            string: titleLabel.stringValue, attributes: HelmType.kickerAttributes(color: ink.withAlphaComponent(0.85)))
        detailLabel.textColor = ink.withAlphaComponent(Self.detailAlpha)
        addButton?.heroInk = ink
    }

    #if FM_SELFTESTS
    var debugCount: String { countLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugPalette: HelmHeroSurface.Palette? { surface.palette }
    var debugInkLabels: [NSTextField] { [countLabel, detailLabel] }
    #endif
}
