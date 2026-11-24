// Grand Line - native macOS app.
//
// CR-1 Crew band: the AppKit half that every Crew tab's band shares.
// `CrewHeroWords` says what a band says, and this turns one of its `Band`s
// into the kit's `HelmHeroColumn` in `.band`, so Needs you and In flight
// (`FleetController`) and Review (`ReviewController`) draw their bands one
// way: the same strip of figures, the same tone, pill and ring mapping, and
// the same clock in their kickers.
//
// Nothing here owns a band. Each page keeps its own `HelmHeroColumn`, its own
// foot controls and its own signature guard, because what a band's foot holds
// (Open Setup, Show folder path, the figures) is the page's to wire.

import AppKit

enum CrewBand {

    /// A band's time of day - "11:24 AM" - the clock Needs you's summary line
    /// has always used.
    static func time(_ date: Date) -> String { FleetController.needsYouTimeFormatter.string(from: date) }

    /// The band's strip of figures: an inline `HelmKPIStrip` in the hero ink.
    ///
    /// The strip keeps its figures' own width at the band's leading edge
    /// rather than spreading them over the whole band. A zero is a maximum,
    /// never a floor, so it can neither widen the band nor the window (gotcha
    /// (13)). It sits at the fitting-size level, under every priority the
    /// strip's own stacks and columns hold (250 to 252), so it only packs them
    /// and never decides a width they care about.
    static func figureStrip() -> HelmKPIStrip {
        let strip = HelmKPIStrip(density: .inline)
        let hug = strip.widthAnchor.constraint(equalToConstant: 0)
        hug.priority = .fittingSizeCompression
        hug.isActive = true
        return strip
    }

    /// `figures` as the strip's items. A figure that is not known is a dash
    /// (GL-14), a zero is quiet, and Ready to merge on In flight is the one
    /// figure that is a button, into Review.
    static func items(_ figures: [CrewHeroWords.Figure]) -> [HelmKPIStrip.Item] {
        figures.map { figure in
            HelmKPIStrip.Item(figure.value.map { .value($0) } ?? .unread, caption: figure.caption,
                              emphasis: figure.value == "0" ? .quiet : .normal,
                              isAction: figure.opensReview,
                              toolTip: figure.opensReview ? "View in \(PlaceName.short(.review))" : nil)
        }
    }

    /// The watcher's state as the band's glass pill.
    static func status(_ status: CrewHeroWords.Status?) -> HelmHeroColumn.Status? {
        status.map { status in
            let tint: HelmTint?
            switch status.state {
            case .good: tint = .good
            case .warn: tint = .warn
            case .idle: tint = nil
            }
            return HelmHeroColumn.Status(text: status.text, tint: tint)
        }
    }

    /// Review's ready-over-open ring at the band's top right, its arc in the
    /// ink: a count, not a verdict, so it takes no state hue.
    static func ring(_ ring: CrewHeroWords.Ring?) -> HelmHeroColumn.Ring? {
        ring.map {
            HelmHeroColumn.Ring(fraction: $0.fraction, label: $0.label, caption: $0.caption, spoken: $0.spoken,
                                state: .ok)
        }
    }

    /// Draw `words` on `band`: the theme's accent, or the accent dimmed for a
    /// reading that failed, with `bandViews` between the words and the foot
    /// and a hairline above a foot that has anything in it.
    static func configure(_ band: HelmHeroColumn, words: CrewHeroWords.Band, foot: [NSView],
                          bandViews: [NSView] = []) {
        band.configure(header: .init(symbol: words.symbol, kicker: words.kicker, headline: words.headline,
                                     body: words.body, ring: ring(words.ring), status: status(words.status)),
                       sections: [], foot: foot,
                       tone: .init(colour: .themeAccent, isDimmed: words.tone == .dimmed),
                       bandViews: bandViews, footRule: !foot.isEmpty)
    }
}
