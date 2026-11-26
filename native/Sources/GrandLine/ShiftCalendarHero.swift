// Grand Line - native macOS app.
//
// The Calendar as Cal-8 on the second page-redesign board
// (`data/grand-line-page-redesign-mockups-2/`), the captain's pick: "The
// month card wears the hero". Sidebar layout only, as T-4 is; the floating
// bar's calendar keeps the page's own header.
//
// Two native heads, each drawn over the calendar's web page and fused to the
// top of the card under it:
//
//   - `ShiftCalendarHeroHead`: the month card's head. The kicker, the period
//     as the headline with the previous and next arrows and Today as ghost
//     pills beside it, This week / Overdue / Follow-ups / Unscheduled as
//     inline figures, a small ring of the open tasks that have a date, and -
//     in the month grid - the weekday names in the ink, over the grid's own
//     columns.
//   - `ShiftCalendarTrayHead`: the Unscheduled panel's head, T-4's lane band
//     (`ShiftLaneHeroBand`) in amber with the count as a big number and the
//     fold button. Folded, it is a cap as narrow as the strip, with the count
//     and the button that opens it again.
//
// The page keeps the grid and the tray and loses its own header
// (`html.gl-hero` in `task-calendar.css`). `ShiftCalendarView` tells it how
// tall each head is (`setHeads`), and the page leaves exactly that much of
// each card's top to it, so a head and its card are one surface with the seam
// on a whole point. Where each head sits comes from the page's own fixed
// geometry (`TaskCalendarController.cardInsets`, the tray's width, the gap
// between them), and `ShiftCalendarViewSelfTest` reads the page's own
// rectangles back to hold the two together.
//
// **Cf-4 (the five-screen redesign board, `data/grandline-page-redesign-
// options/`).** The Tasks page's filter row no longer sits above the
// calendar. The month card's head carries it instead, as three glass menus on
// its top edge: "Showing All tasks", "in All projects" and "Colour by", each
// drawn solid while it narrows what the calendar shows. The page's grey
// caption line went with the row, so the one fact it held that no figure
// says - how many of the period's dates are a repeat rule's, not yet tasks -
// joins the kicker.
//
// Both heads are painted with `HelmHeroSurface` and the palette rule T-4's
// bands use, so the calendar's heads and the Tasks board's match. The words
// come from `ShiftCalendarHeroWords`, which is pure, so the title, the
// figures and the ring are asserted headless (`ShiftCalendarSelfTest`).

import AppKit

// MARK: - The words

enum ShiftCalendarHeroWords {

    struct Figures: Equatable {
        /// Open tasks and pending follow-ups dated in today's week.
        let thisWeek: Int
        let overdue: Int
        let followUps: Int
        let unscheduled: Int
    }

    /// The open tasks that have a date, out of every open task.
    struct Ring: Equatable {
        let dated: Int
        let open: Int
    }

    struct Head: Equatable {
        let kicker: String
        let title: String
        let figures: Figures
        /// `nil` when nothing is open, which is no fraction at all.
        let ring: Ring?
        /// F-01: the Mac's meetings this week and today's free time, when
        /// the calendars are shown. `nil` keeps the head as it was.
        var meetings: Meetings? = nil
    }

    /// F-01: what the head says about the Mac's own calendars.
    struct Meetings: Equatable {
        let thisWeek: Int
        let freeToday: TimeInterval
    }

    /// The head for what the calendar holds. `summary` is the Tasks page's
    /// own counts, so the head's Overdue and Follow-ups say what the Board's
    /// band does; without it the tray's records stand in, as they do for the
    /// caption (`ShiftCalendarView.subtitle`).
    static func head(scale: ShiftCalendarScale, focusedDay: String?, range: (start: String, end: String)?,
                     tasks: [ShiftTask], followUps: [ShiftFollowUp], tray: ShiftCalendarTray,
                     summary: ShiftStore.Summary?, now: Date = DayRollover.now(), calendar: Calendar = .current,
                     locale: Locale = .current, meetings: Meetings? = nil) -> Head {
        let kicker = "Calendar \u{00B7} \(ShiftHeroWords.kickerFormatter.string(from: now))"
        let open = tasks.filter { $0.status != .completed && $0.status != .cancelled }
        let pending = followUps.filter { $0.status == .pending }
        var thisWeek = 0
        if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            func inWeek(_ day: String?) -> Bool {
                guard let date = day.flatMap(ShiftDateFormatting.date(from:)) else { return false }
                return date >= week.start && date < week.end
            }
            thisWeek = open.filter { inWeek($0.dueDate) }.count + pending.filter { inWeek($0.followUpAt) }.count
        }
        let figures = Figures(
            thisWeek: thisWeek,
            overdue: summary?.overdue ?? tray.overdue.filter { $0.kind == .task }.count,
            followUps: summary?.followUps ?? pending.count,
            unscheduled: tray.unscheduledCount)
        let ring = tray.openTasks > 0
            ? Ring(dated: max(0, tray.openTasks - tray.unscheduledCount), open: tray.openTasks) : nil
        return Head(kicker: kicker,
                    title: title(scale: scale, focusedDay: focusedDay, range: range, now: now,
                                 calendar: calendar, locale: locale),
                    figures: figures, ring: ring, meetings: meetings)
    }

    /// The period on screen, as the page's own header used to name it: the
    /// month for the month grid and the agenda ("November 2026"), the week's
    /// range ("Nov 15 – 21, 2026") and the day ("Thursday, November 19,
    /// 2026"). The focused day is the page's own (its range report's `date`);
    /// a month grid's range spans the weeks either side, so it never names
    /// the month.
    static func title(scale: ShiftCalendarScale, focusedDay: String?, range: (start: String, end: String)?,
                      now: Date = DayRollover.now(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let focus = focusedDay.flatMap(ShiftDateFormatting.date(from:)) ?? now
        func formatter(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        switch scale {
        case .month, .agenda:
            return formatter("MMMMyyyy").string(from: focus)
        case .day:
            return formatter("EEEEMMMMdyyyy").string(from: focus)
        case .week:
            let start = range.flatMap { ShiftDateFormatting.date(from: $0.start) }
                ?? ShiftCalendarModel.weekStart(of: focus, calendar: calendar)
            let end = range.flatMap { ShiftDateFormatting.date(from: $0.end) }
                ?? calendar.date(byAdding: .day, value: 6, to: start) ?? start
            let interval = DateIntervalFormatter()
            interval.calendar = calendar
            interval.timeZone = calendar.timeZone
            interval.locale = locale
            interval.dateTemplate = "MMMdyyyy"
            return interval.string(from: start, to: end)
        }
    }

    /// What the arrows step by, for their tooltips.
    static func unit(of scale: ShiftCalendarScale) -> String {
        switch scale {
        case .month, .agenda: return "month"
        case .week: return "week"
        case .day: return "day"
        }
    }

    /// The tray head's second line.
    static func trayDetail(unscheduled: Int) -> String {
        unscheduled > 0 ? "no date yet \u{00B7} drag onto a day" : "every open task has a date"
    }
}

// MARK: - The month card's head

final class ShiftCalendarHeroHead: NSView {

    /// The page's card radius (`--gl-radius-card`), so the head's top
    /// corners are the card's.
    static let cornerRadius: CGFloat = 16
    static let insets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
    static let titleSize: CGFloat = 20
    static let figureSize: CGFloat = 22
    static let ringSide: CGFloat = 44
    static let weekdayGap: CGFloat = 10
    static let weekdayHeight: CGFloat = 15
    /// Between Cf-4's menus and the title row under them.
    static let menuGap: CGFloat = HelmMetrics.s2
    /// The ink's share for the kicker, the ring's caption and the weekday
    /// names, which the palette is deepened to carry (T-4's 0.85).
    static let quietInkAlpha: CGFloat = 0.85
    /// From the card's edge to the grid's first column: the card's 1pt
    /// border and its 16pt padding (`task-calendar.css`'s `.gl-card`).
    static let gridInset: CGFloat = 17
    /// From a column's edge to its day number: the cell's padding and its
    /// header's (`.sx__month-grid-day`, `.sx__month-grid-day__header`).
    static let dayNumberInset: CGFloat = 13

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onToday: (() -> Void)?
    /// Cf-4's menus, shown from the pill that was clicked.
    var onShowScopeMenu: ((NSView) -> Void)?
    var onShowProjectMenu: ((NSView) -> Void)?
    var onShowColourMenu: ((NSView) -> Void)?

    /// What Cf-4's three menus say. `nil` draws no menus at all.
    struct Filters: Equatable {
        /// "All tasks", "Due today" and so on, with its count when it has one.
        var scope: String
        var scopeNarrows: Bool
        var project: String
        var projectNarrows: Bool
        var colour: String
    }

    /// How many of the period's dates are a repeat rule's, not yet tasks -
    /// the caption's clause the head says now (Cf-4). UI-05 of full review 4:
    /// said on the quiet line under the title as "4 upcoming repeats". The
    /// kicker said "4 repeat dates not yet created", which is how the store
    /// works rather than what the captain sees, and wrapped it to two lines.
    var repeatDates = 0 {
        didSet { if repeatDates != oldValue { applyRepeats(); updateHeight() } }
    }

    /// "4 upcoming repeats", or nil for none.
    static func repeatsLine(_ count: Int) -> String? {
        count > 0 ? "\(count) upcoming repeat\(count == 1 ? "" : "s")" : nil
    }

    /// The head's height changed: the page has to leave a new amount of the
    /// card to it.
    var onHeightChange: (() -> Void)?

    private let surface = HelmHeroSurface()
    private let tile = NSView()
    private let glyph = NSImageView()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    /// UI-05: the quiet line under the title.
    private let repeatsLabel = NSTextField(labelWithString: "")
    private lazy var previousButton = HelmButton(title: "", variant: .secondary, size: .small,
                                                 symbol: "chevron.left", target: self,
                                                 action: #selector(previousTapped))
    private lazy var nextButton = HelmButton(title: "", variant: .secondary, size: .small,
                                             symbol: "chevron.right", target: self, action: #selector(nextTapped))
    private lazy var todayButton = HelmButton(title: "Today", variant: .secondary, size: .small,
                                              target: self, action: #selector(todayTapped))
    private let figures = HelmKPIStrip(density: .inline)
    private let ring = HelmRingGauge(side: ShiftCalendarHeroHead.ringSide)
    private let ringCaption = NSTextField(labelWithString: "dated")
    private let ringColumn = NSStackView()
    private let titleRow = NSStackView()
    private let topRow = NSStackView()
    private lazy var scopeMenuButton = HelmButton(title: "Showing All tasks", variant: .secondary, size: .small,
                                                  symbol: "chevron.down", target: self,
                                                  action: #selector(scopeMenuTapped))
    private lazy var projectMenuButton = HelmButton(title: "in All projects", variant: .secondary, size: .small,
                                                    symbol: "chevron.down", target: self,
                                                    action: #selector(projectMenuTapped))
    private lazy var colourMenuButton = HelmButton(title: "Colour by Priority", variant: .secondary, size: .small,
                                                   symbol: "chevron.down", target: self,
                                                   action: #selector(colourMenuTapped))
    /// F-01: the Mac's calendars - ask, pick, or say access is off.
    private(set) lazy var calendarsMenuButton = HelmButton(title: "Show my calendars", variant: .secondary, size: .small,
                                                           symbol: "chevron.down", target: self,
                                                           action: #selector(calendarsMenuTapped))
    var onShowCalendarsMenu: ((NSView) -> Void)?
    private let menuRow = NSStackView()
    private var topRowUnderMenus: NSLayoutConstraint!
    private var topRowAtTop: NSLayoutConstraint!
    private(set) var filters: Filters?
    private let weekdayRow = ShiftCalendarWeekdayRow()
    private var height: NSLayoutConstraint!
    private(set) var words: ShiftCalendarHeroWords.Head?
    private var scale: ShiftCalendarScale = .month
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.cornerRadius
        // The top two only: the bottom edge is the card's top.
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        addSubview(surface)

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 6
        tile.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = HelmSymbol.image("calendar", pointSize: 11, weight: .semibold)
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        kickerLabel.lineBreakMode = .byTruncatingTail
        kickerLabel.font = .systemFont(ofSize: HelmType.scaled(11), weight: .semibold)
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(Self.titleSize), weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        // The words give way first, and only they (gotcha (5)).
        for label in [kickerLabel, titleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setAccessibilityElement(false)
        }
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        for button in [previousButton, nextButton, todayButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        previousButton.setAccessibilityLabel("Previous")
        nextButton.setAccessibilityLabel("Next")
        todayButton.toolTip = "Show today"

        let kickerRow = NSStackView(views: [tile, kickerLabel])
        kickerRow.orientation = .horizontal
        kickerRow.spacing = HelmMetrics.s2
        kickerRow.alignment = .centerY
        for view in [titleLabel, previousButton, nextButton, todayButton] { titleRow.addArrangedSubview(view) }
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = HelmMetrics.s2 + 2
        titleRow.setCustomSpacing(HelmMetrics.s3, after: titleLabel)
        // Hugs, so the pills sit beside the title rather than at the far
        // edge of the words' column (gotcha (12): stack-level priorities).
        titleRow.setHuggingPriority(.defaultHigh, for: .horizontal)
        titleRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        repeatsLabel.font = .systemFont(ofSize: HelmType.scaled(12), weight: .medium)
        repeatsLabel.lineBreakMode = .byTruncatingTail
        repeatsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        repeatsLabel.setAccessibilityElement(false)
        repeatsLabel.isHidden = true
        let text = NSStackView(views: [kickerRow, titleRow, repeatsLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s1
        text.detachesHiddenViews = true
        for stack in [kickerRow, text] {
            stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
            stack.setHuggingPriority(.defaultLow, for: .horizontal)
        }

        figures.figureSize = Self.figureSize
        figures.setContentHuggingPriority(.required, for: .horizontal)
        figures.setAccessibilityLabel("The calendar's figures")
        ringCaption.font = .systemFont(ofSize: HelmType.scaled(10.5), weight: .medium)
        ringCaption.setAccessibilityElement(false)
        ringColumn.orientation = .vertical
        ringColumn.alignment = .centerX
        ringColumn.spacing = HelmMetrics.s1
        for view in [ring, ringCaption] { ringColumn.addArrangedSubview(view) }
        ringColumn.setHuggingPriority(.required, for: .horizontal)

        for view in [text, figures, ringColumn] { topRow.addArrangedSubview(view) }
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = HelmMetrics.s5
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        topRow.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(topRow)
        addSubview(weekdayRow)

        for button in [scopeMenuButton, projectMenuButton, colourMenuButton, calendarsMenuButton] {
            button.symbolTrailing = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            menuRow.addArrangedSubview(button)
        }
        scopeMenuButton.toolTip = "Which tasks the calendar shows"
        projectMenuButton.toolTip = "Show one project's tasks"
        colourMenuButton.toolTip = "What a task chip's colour says"
        scopeMenuButton.setAccessibilityLabel("Which tasks to show")
        projectMenuButton.setAccessibilityLabel("Project")
        colourMenuButton.setAccessibilityLabel("Colour calendar chips by")
        calendarsMenuButton.toolTip = "Show the calendars already on this Mac, read-only"
        calendarsMenuButton.setAccessibilityLabel("Calendars from this Mac")
        menuRow.orientation = .horizontal
        menuRow.alignment = .centerY
        menuRow.spacing = HelmMetrics.s2
        menuRow.translatesAutoresizingMaskIntoConstraints = false
        menuRow.setHuggingPriority(.required, for: .horizontal)
        menuRow.isHidden = true
        addSubview(menuRow)

        let insets = Self.insets
        height = heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            tile.widthAnchor.constraint(equalToConstant: 20),
            tile.heightAnchor.constraint(equalToConstant: 20),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            // Cf-4: the menus sit on the head's top edge, right-aligned over
            // the figures, and the title row starts under them.
            menuRow.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            menuRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            // The weekday names span the head, because their columns are the
            // grid's, measured from the card's edge.
            weekdayRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            weekdayRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            weekdayRow.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: Self.weekdayGap),
            weekdayRow.heightAnchor.constraint(equalToConstant: Self.weekdayHeight),
            height,
        ])
        // Gotcha (13): kept off the head's left edge below the window's own
        // priority, so a narrow head clips the menus rather than growing the
        // window.
        let menusClearLeft = menuRow.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: insets.left)
        menusClearLeft.priority = NSLayoutConstraint.Priority(450)
        menusClearLeft.isActive = true
        topRowAtTop = topRow.topAnchor.constraint(equalTo: topAnchor, constant: insets.top)
        topRowUnderMenus = topRow.topAnchor.constraint(equalTo: menuRow.bottomAnchor, constant: Self.menuGap)
        topRowAtTop.isActive = true
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        setWeekdays(calendar: .current)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// The weekday names, from the captain's first weekday - the same
    /// calendar the page is configured with
    /// (`ShiftCalendarPayload.scheduleXFirstDayOfWeek`).
    func setWeekdays(calendar: Calendar) {
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.count == 7 else { return }
        let first = max(0, min(6, calendar.firstWeekday - 1))
        weekdayRow.names = (0..<7).map { symbols[(first + $0) % 7] }
        applyTheme(theme)
    }

    func configure(_ words: ShiftCalendarHeroWords.Head, scale: ShiftCalendarScale) {
        guard words != self.words || scale != self.scale else { return }
        self.words = words
        self.scale = scale
        titleLabel.stringValue = words.title
        let figures = words.figures
        if let meetings = words.meetings {
            // F-01: with the Mac's calendars shown, the meetings and the free
            // time take the follow-up and unscheduled tiles' places.
            self.figures.configure([
                .count(figures.thisWeek, caption: "Tasks this week"),
                .count(meetings.thisWeek, caption: "Meetings"),
                .count(figures.overdue, caption: "Overdue"),
                .figure(MacCalendarRules.duration(meetings.freeToday), caption: "Free today"),
            ], theme: theme)
        } else {
            self.figures.configure([
                .count(figures.thisWeek, caption: "This week"),
                .count(figures.overdue, caption: "Overdue"),
                .count(figures.followUps, caption: "Follow-ups"),
                .count(figures.unscheduled, caption: "Unscheduled"),
            ], theme: theme)
        }
        if let ring = words.ring {
            self.ring.configure(fraction: Double(ring.dated) / Double(max(1, ring.open)),
                                text: "\(ring.dated)/\(ring.open)")
            self.ring.setSpokenLabel("\(ring.dated) of \(ring.open) open tasks have a date")
        }
        let unit = ShiftCalendarHeroWords.unit(of: scale)
        previousButton.toolTip = "Previous \(unit)"
        nextButton.toolTip = "Next \(unit)"
        previousButton.setAccessibilityLabel("Previous \(unit)")
        nextButton.setAccessibilityLabel("Next \(unit)")
        // The week and day views draw their own date axis; the month grid's
        // weekday names are this head's.
        weekdayRow.isHidden = scale != .month
        applyKicker()
        applyRepeats()
        applyTheme(theme)
        applyWidthRules()
        updateHeight()
    }

    /// The kicker: the page and the date, one line.
    private func applyKicker() {
        let kicker = words?.kicker ?? ""
        kickerLabel.stringValue = kicker.uppercased()
        let palette = HelmHeroSurface.palette(accent: HelmContrast.components(HelmTheme.nsColor(theme.heroAccentHex)),
                                              quietInk: Double(Self.quietInkAlpha))
        let quiet = HelmContrast.color(palette.ink).withAlphaComponent(Self.quietInkAlpha)
        kickerLabel.attributedStringValue = NSAttributedString(
            string: kickerLabel.stringValue, attributes: HelmType.kickerAttributes(color: quiet))
    }

    /// The quiet line, and the words VoiceOver reads for the head.
    private func applyRepeats() {
        let line = Self.repeatsLine(repeatDates)
        repeatsLabel.stringValue = line ?? ""
        repeatsLabel.isHidden = line == nil
        if let words {
            setAccessibilityLabel(["\(words.kicker). \(words.title)", line].compactMap { $0 }.joined(separator: ". "))
        }
    }

    /// Cf-4: what the three menus say, or `nil` for none.
    func setFilters(_ filters: Filters?) {
        guard filters != self.filters else { return }
        self.filters = filters
        let shows = filters != nil
        menuRow.isHidden = !shows
        topRowAtTop.isActive = !shows
        topRowUnderMenus.isActive = shows
        if let filters {
            scopeMenuButton.title = "Showing \(filters.scope)"
            projectMenuButton.title = "in \(filters.project)"
            colourMenuButton.title = "Colour by \(filters.colour)"
        }
        applyTheme(theme)
        updateHeight()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let accent = HelmContrast.components(HelmTheme.nsColor(theme.heroAccentHex))
        let palette = HelmHeroSurface.palette(accent: accent, quietInk: Double(Self.quietInkAlpha))
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        // A white-ink hero is a dark surface, so the pills' focus rings and
        // any system colour they resolve are the dark appearance's
        // (`HelmHeroColumn.applyTheme`).
        appearance = NSAppearance(named: HelmContrast.relativeLuminance(palette.ink) < 0.5 ? .aqua : .darkAqua)
        let quiet = ink.withAlphaComponent(Self.quietInkAlpha)
        tile.layer?.backgroundColor = ink.withAlphaComponent(HelmHeroColumn.tileFillAlpha).cgColor
        glyph.contentTintColor = ink
        kickerLabel.attributedStringValue = NSAttributedString(
            string: kickerLabel.stringValue, attributes: HelmType.kickerAttributes(color: quiet))
        titleLabel.textColor = ink
        repeatsLabel.textColor = quiet
        ringCaption.textColor = quiet
        weekdayRow.color = quiet
        for button in [previousButton, nextButton, todayButton] { button.heroInk = ink }
        // A menu that narrows what the calendar shows is drawn solid, so a
        // filter that is on can be seen from across the room.
        let darker = HelmContrast.relativeLuminance(palette.start) < HelmContrast.relativeLuminance(palette.end)
            ? palette.start : palette.end
        let deep = HelmContrast.color(darker)
        for button in [scopeMenuButton, projectMenuButton, colourMenuButton, calendarsMenuButton] { button.heroInk = ink }
        scopeMenuButton.heroSelection = filters?.scopeNarrows == true ? deep : nil
        projectMenuButton.heroSelection = filters?.projectNarrows == true ? deep : nil
        figures.heroInk = ink
        figures.applyTheme(theme)
        ring.trackColorOverride = ink.withAlphaComponent(0.25)
        ring.labelColorOverride = ink
        ring.valueColorOverride = ink
        ring.applyTheme(theme, hue: .blue)
    }

    override func layout() {
        super.layout()
        applyWidthRules()
    }

    /// The figures step out first and the ring after them, when the title
    /// and its pills would otherwise be squeezed - T-4's order. Measured
    /// from what each piece needs at this width, so a long week range gives
    /// way sooner than a short month.
    private func applyWidthRules() {
        let available = bounds.width - Self.insets.left - Self.insets.right
        guard available > 0, let words else { return }
        let gap = HelmMetrics.s5
        let title = titleRow.fittingSize.width
        let ringWidth = words.ring == nil ? 0 : ringColumn.fittingSize.width + gap
        let figuresWidth = figures.fittingSize.width + gap
        let showsRing = words.ring != nil && title + ringWidth <= available
        let showsFigures = title + figuresWidth + (showsRing ? ringWidth : 0) <= available
        var changed = false
        if ringColumn.isHidden == showsRing { ringColumn.isHidden = !showsRing; changed = true }
        if figures.isHidden == showsFigures { figures.isHidden = !showsFigures; changed = true }
        if changed { updateHeight() }
    }

    /// The head's height: its rows' own, on a whole point, so the page's
    /// card starts exactly where the head ends.
    private func updateHeight() {
        var total = Self.insets.top + topRow.fittingSize.height + Self.insets.bottom
        if !menuRow.isHidden { total += menuRow.fittingSize.height + Self.menuGap }
        if !weekdayRow.isHidden { total += Self.weekdayGap + Self.weekdayHeight }
        let whole = ceil(total)
        guard height.constant != whole else { return }
        height.constant = whole
        onHeightChange?()
    }

    /// What the page leaves of the card's top.
    var headHeight: CGFloat { height.constant }

    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func todayTapped() { onToday?() }
    @objc private func scopeMenuTapped() { onShowScopeMenu?(scopeMenuButton) }
    @objc private func projectMenuTapped() { onShowProjectMenu?(projectMenuButton) }
    @objc private func colourMenuTapped() { onShowColourMenu?(colourMenuButton) }
    @objc private func calendarsMenuTapped() { onShowCalendarsMenu?(calendarsMenuButton) }

    /// F-01: "Calendars: Work, Personal", "Show my calendars" or "Calendars off".
    func setCalendarsTitle(_ title: String) {
        guard calendarsMenuButton.title != title else { return }
        calendarsMenuButton.title = title
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugKicker: String { kickerLabel.stringValue }
    /// UI-05: the quiet line under the title, or nil while it is hidden.
    var debugRepeatsLine: String? { repeatsLabel.isHiddenOrHasHiddenAncestor ? nil : repeatsLabel.stringValue }
    var debugFigures: HelmKPIStrip? { figures.isHidden ? nil : figures }
    var debugRing: HelmRingGauge? { ringColumn.isHidden || words?.ring == nil ? nil : ring }
    var debugPalette: HelmHeroSurface.Palette? { surface.palette }
    var debugButtons: (previous: HelmButton, next: HelmButton, today: HelmButton) {
        (previousButton, nextButton, todayButton)
    }
    var debugWeekdayRow: ShiftCalendarWeekdayRow? { weekdayRow.isHidden ? nil : weekdayRow }
    var debugTitleLabel: NSTextField { titleLabel }
    var debugMenuButtons: (scope: HelmButton, project: HelmButton, colour: HelmButton)? {
        menuRow.isHidden ? nil : (scopeMenuButton, projectMenuButton, colourMenuButton)
    }
    var debugMenuRowFrameInHead: NSRect { menuRow.frame }
    var debugTopRowFrameInHead: NSRect { topRow.frame }
    #endif
}

/// The month grid's weekday names, each over its own column of the page's
/// grid. Laid out by hand, because the columns are the page's - a seventh of
/// the card's width inside its border and padding - and a stack would
/// distribute them by its own rules.
final class ShiftCalendarWeekdayRow: NSView {

    var names: [String] = [] {
        didSet {
            guard names != oldValue else { return }
            labels.forEach { $0.removeFromSuperview() }
            labels = names.map { name in
                let label = NSTextField(labelWithString: name)
                label.font = .systemFont(ofSize: HelmType.scaled(11), weight: .semibold)
                label.textColor = color
                label.lineBreakMode = .byClipping
                addSubview(label)
                return label
            }
            needsLayout = true
        }
    }

    var color: NSColor = .white {
        didSet { labels.forEach { $0.textColor = color } }
    }

    private(set) var labels: [NSTextField] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let inset = ShiftCalendarHeroHead.gridInset
        let column = max(0, (bounds.width - inset * 2) / 7)
        for (index, label) in labels.enumerated() {
            let size = label.fittingSize
            let x = inset + CGFloat(index) * column + ShiftCalendarHeroHead.dayNumberInset
            label.frame = NSRect(x: round(x), y: round((bounds.height - size.height) / 2),
                                 width: min(ceil(size.width), max(0, column - ShiftCalendarHeroHead.dayNumberInset)),
                                 height: ceil(size.height))
        }
    }
}

// MARK: - The tray's head

final class ShiftCalendarTrayHead: NSView {

    /// The tray's widths, open and folded (`task-calendar.css`'s `.gl-tray`).
    static let width: CGFloat = 264
    static let collapsedWidth: CGFloat = 44
    /// From the card to the tray (`.gl-layout`'s gap).
    static let gap: CGFloat = 14
    static let capInsets = NSEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
    static let capCountSize: CGFloat = 17

    /// The fold button: the tray asks to be folded, or opened.
    var onToggle: (() -> Void)?
    var onHeightChange: (() -> Void)?

    private let band: ShiftLaneHeroBand
    private let cap = HelmHeroSurface()
    private let capCount = NSTextField(labelWithString: "0")
    private lazy var capButton = HelmButton(title: "", variant: .secondary, size: .small,
                                            symbol: "arrow.left.to.line", target: self,
                                            action: #selector(toggleTapped))
    private let capStack = NSStackView()
    private var height: NSLayoutConstraint!
    private(set) var isCollapsed = false
    private(set) var count = 0
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        band = ShiftLaneHeroBand(tone: .amber, title: "Unscheduled", addTooltip: "Collapse Unscheduled",
                                 target: nil, action: nil)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = ShiftCalendarHeroHead.cornerRadius
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        // The lane band's ghost button is this head's fold button.
        band.addButton?.symbolName = "arrow.right.to.line"
        band.addButton?.target = self
        band.addButton?.action = #selector(toggleTapped)
        addSubview(band)

        cap.translatesAutoresizingMaskIntoConstraints = false
        capCount.font = HelmType.rounded(HelmType.scaled(Self.capCountSize), .bold)
        capCount.alignment = .center
        capCount.setAccessibilityElement(false)
        capButton.toolTip = "Expand Unscheduled"
        capButton.setAccessibilityLabel("Expand Unscheduled")
        capStack.orientation = .vertical
        capStack.alignment = .centerX
        capStack.spacing = HelmMetrics.s2
        capStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [capCount, capButton] { capStack.addArrangedSubview(view) }
        cap.addSubview(capStack)
        addSubview(cap)

        height = heightAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: leadingAnchor),
            band.trailingAnchor.constraint(equalTo: trailingAnchor),
            band.topAnchor.constraint(equalTo: topAnchor),
            band.bottomAnchor.constraint(equalTo: bottomAnchor),
            cap.leadingAnchor.constraint(equalTo: leadingAnchor),
            cap.trailingAnchor.constraint(equalTo: trailingAnchor),
            cap.topAnchor.constraint(equalTo: topAnchor),
            cap.bottomAnchor.constraint(equalTo: bottomAnchor),
            capStack.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            capStack.topAnchor.constraint(equalTo: cap.topAnchor, constant: Self.capInsets.top),
            height,
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        configure(count: 0, collapsed: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// The width the page's tray has, open or folded.
    var trayWidth: CGFloat { isCollapsed ? Self.collapsedWidth : Self.width }

    func configure(count: Int, collapsed: Bool) {
        self.count = count
        isCollapsed = collapsed
        band.configure(count: count, detail: ShiftCalendarHeroWords.trayDetail(unscheduled: count))
        capCount.stringValue = "\(count)"
        band.isHidden = collapsed
        cap.isHidden = !collapsed
        setAccessibilityLabel("Unscheduled, \(count)")
        updateHeight()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let palette = ShiftLaneTone.amber.palette(in: theme)
        cap.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        appearance = NSAppearance(named: HelmContrast.relativeLuminance(palette.ink) < 0.5 ? .aqua : .darkAqua)
        capCount.textColor = ink
        capButton.heroInk = ink
    }

    private func updateHeight() {
        let whole: CGFloat
        if isCollapsed {
            whole = ceil(Self.capInsets.top + capStack.fittingSize.height + Self.capInsets.bottom)
        } else {
            whole = ceil(band.fittingSize.height)
        }
        guard height.constant != whole else { return }
        height.constant = whole
        onHeightChange?()
    }

    /// What the page leaves of the tray's top.
    var headHeight: CGFloat { height.constant }

    @objc private func toggleTapped() { onToggle?() }

    #if FM_SELFTESTS
    var debugBand: ShiftLaneHeroBand { band }
    var debugToggleButton: HelmButton? { isCollapsed ? capButton : band.addButton }
    var debugCapCount: String { capCount.stringValue }
    var debugCapPalette: HelmHeroSurface.Palette? { cap.palette }
    #endif
}
