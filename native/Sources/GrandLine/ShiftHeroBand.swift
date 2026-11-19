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
        let figures: (due: Int, overdue: Int, followUps: Int, done: Int)?
        /// Done this week out of everything open or done this week.
        let ring: (done: Int, total: Int)?
        let isDimmed: Bool

        static func == (a: Band, b: Band) -> Bool {
            a.kicker == b.kicker && a.headline == b.headline && a.isDimmed == b.isDimmed
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
    static func band(summary: ShiftStore.Summary?, doneLastWeek: Int, now: Date = Date()) -> Band {
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
                    figures: (summary.dueToday, summary.overdue, summary.followUps, doneLastWeek),
                    ring: total > 0 ? (doneLastWeek, total) : nil, isDimmed: false)
    }

    /// A lane's detail line: what in it is late or due, from each item's due
    /// day and time. "1 overdue · 1 due today", then "2 due tomorrow", then
    /// "Nothing due soon" - or `empty` for a lane with nothing in it.
    static func laneDetail(dues: [(date: String?, time: String?)], empty: String, now: Date = Date(),
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
        case .accent: hex = theme.accentHex
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

final class ShiftTasksHeroBand: NSView {

    static let cornerRadius: CGFloat = 14
    static let ringSide: CGFloat = 44
    static let figureSize: CGFloat = 22
    static let headlineSize: CGFloat = 20
    static let insets = NSEdgeInsets(top: 14, left: 22, bottom: 14, right: 22)
    /// Below these widths the figures, then the ring, step out: the verdict
    /// is the one thing the band always says.
    static let figuresMinimumWidth: CGFloat = 760
    static let ringMinimumWidth: CGFloat = 460

    private let surface = HelmHeroSurface()
    private let tile = NSView()
    private let glyph = NSImageView()
    private let kickerLabel = NSTextField(labelWithString: "")
    private let headlineLabel = NSTextField(labelWithString: "")
    private let figures = HelmKPIStrip(density: .inline)
    private let ring = HelmRingGauge(side: ShiftTasksHeroBand.ringSide)
    private var words = ShiftHeroWords.band(summary: nil, doneLastWeek: 0)
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
        let text = NSStackView(views: [kickerRow, headlineLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s1
        for stack in [kickerRow, text] {
            stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
            stack.setHuggingPriority(.defaultLow, for: .horizontal)
        }

        figures.figureSize = Self.figureSize
        figures.setContentHuggingPriority(.required, for: .horizontal)
        figures.setAccessibilityLabel("Today's figures")
        ring.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [text, figures, ring])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s5
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        // The words take the slack; the figures and the ring keep their own
        // width (gotchas (10) and (12)).
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)

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
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            row.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
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
        if let figures = words.figures {
            self.figures.configure([
                .count(figures.due, caption: "Due today"),
                .count(figures.overdue, caption: "Overdue"),
                .count(figures.followUps, caption: "Follow-ups"),
                .count(figures.done, caption: "Done, 7 days"),
            ], theme: theme)
        } else {
            self.figures.configure(["Due today", "Overdue", "Follow-ups", "Done, 7 days"].map {
                HelmKPIStrip.Item(.unread, caption: $0)
            }, theme: theme)
        }
        if let ring = words.ring {
            self.ring.configure(fraction: Double(ring.done) / Double(max(1, ring.total)), text: "")
            self.ring.setSpokenLabel("\(ring.done) of \(ring.total) done in the last 7 days")
        }
        setAccessibilityLabel("\(words.kicker). \(words.headline)")
        applyWidthRules()
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let accent = HelmContrast.components(HelmTheme.nsColor(theme.accentHex))
        let palette = HelmHeroSurface.palette(accent: words.isDimmed ? HelmHeroSurface.dimmed(accent) : accent,
                                              quietInk: 0.85)
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        tile.layer?.backgroundColor = ink.withAlphaComponent(HelmHeroColumn.tileFillAlpha).cgColor
        glyph.contentTintColor = ink
        kickerLabel.attributedStringValue = NSAttributedString(
            string: kickerLabel.stringValue, attributes: HelmType.kickerAttributes(color: ink.withAlphaComponent(0.85)))
        headlineLabel.textColor = ink
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

    private func applyWidthRules() {
        let width = bounds.width
        guard width > 0 else { return }
        let showsFigures = words.figures != nil && width >= Self.figuresMinimumWidth
        let showsRing = words.ring != nil && width >= Self.ringMinimumWidth
        if figures.isHidden == showsFigures { figures.isHidden = !showsFigures }
        if ring.isHidden == showsRing { ring.isHidden = !showsRing }
    }

    #if FM_SELFTESTS
    var debugHeadline: String { headlineLabel.stringValue }
    var debugKicker: String { kickerLabel.stringValue }
    var debugFigures: HelmKPIStrip? { figures.isHidden ? nil : figures }
    var debugRing: HelmRingGauge? { ring.isHidden ? nil : ring }
    var debugPalette: HelmHeroSurface.Palette? { surface.palette }
    var debugHeadlineColor: NSColor? { headlineLabel.textColor }
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
        words.spacing = 1
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
