// Grand Line - native macOS app.
//
// `HelmModuleCard` - the home canvas widget (Daylight migration §6.1), plus
// the two gauges §6.8 gives it (`HelmRingGauge`, `HelmProgressBar`).
//
// **What this is, and what it is deliberately not.** A module is a *summary*
// surface: one number, one ring, two or three peek rows, or a paragraph.
// Never a table. §1's third rule ("low density with progressive disclosure")
// is the whole reason the canvas is worth having - the detail already exists
// one drill-in down, on a page that is better at showing it. If a module
// ever needs a fourth row, that is a signal it should be showing less, not
// that this component needs a scroll view.
//
// **Anatomy** (§6.1, top to bottom):
//   1. a 6pt gradient ribbon, h1->h2 left to right;
//   2. a header row: 30pt gradient tile, title + subtitle, trailing chip;
//   3. a body, one of five kinds (§6.1's four plus `.note`, the one-line
//      form three of the table's own modules ask for).
//
// **Two layers, not one, and that is load-bearing.** A layer with a shadow
// must not clip, and a card with a rounded fill must - so the outer view
// carries the shadow with `masksToBounds = false` and an explicit
// `shadowPath`, and the inner `HoverHighlightView` carries the fill, the
// border and the clip. This is the arrangement `HelmComposerCard` already
// proved in this codebase; see §2.5.
//
// **Why the inner view is a `HoverHighlightView`.** §6.1 asks for the whole
// card to be one click target announcing as a button. That component already
// derives a VoiceOver label from its own descendant labels, answers
// `.button`, draws a real focus ring and replays its own recognizer on a
// keyboard press (GL-16) - so putting the recognizer there gives the module
// every one of those for free rather than four overrides here.
//
// **Themes itself**, like `HelmCard`, `HelmButton` and `HelmGradientTile`: it
// owns its `ThemeManager` observation and unregisters in `deinit`. A page
// must not set its fonts, fills or borders - the next theme change
// overwrites them (this codebase's most-repeated bug class).

import AppKit

// MARK: - Chips

/// A module's trailing status chip (§6.7).
///
/// The four kinds are *states*, never identities: a chip says "this is fine"
/// / "this wants a look" / "this is wrong" / "here is a fact", and never
/// carries a domain hue. A hue on a chip would compete with the ribbon and
/// the tile, which are the two things that say *which area* this card is.
struct HelmModuleChip: Equatable {
    enum Kind: Equatable {
        case ok, warn, bad, mute

        /// The hex this kind resolves through `HelmContrast.tintedSurface`.
        /// Semantic theme slots, not Daylight literals, so the eleven
        /// fallback palettes render their own greens and ambers (§2.8).
        func hex(in theme: HelmTheme) -> String {
            switch self {
            case .ok: return theme.ansiHex[2]
            case .warn: return theme.ansiHex[3]
            case .bad: return theme.ansiHex[1]
            case .mute: return theme.chromeInkHex
            }
        }
    }

    let text: String
    let kind: Kind

    static func ok(_ text: String) -> HelmModuleChip { .init(text: text, kind: .ok) }
    static func warn(_ text: String) -> HelmModuleChip { .init(text: text, kind: .warn) }
    static func bad(_ text: String) -> HelmModuleChip { .init(text: text, kind: .bad) }
    static func mute(_ text: String) -> HelmModuleChip { .init(text: text, kind: .mute) }
}

/// One peek row's state dot (§6.1's "8pt filled circle").
enum HelmModuleRowState {
    case ok, warn, bad, idle

    func color(in theme: HelmTheme) -> NSColor {
        switch self {
        case .ok: return HelmTheme.nsColor(theme.ansiHex[2])
        case .warn: return HelmTheme.nsColor(theme.ansiHex[3])
        case .bad: return HelmTheme.nsColor(theme.ansiHex[1])
        case .idle: return HelmTheme.mutedInk(theme).withAlphaComponent(0.55)
        }
    }
}

/// One row of a `.peekRows` body: a state dot, a truncating line of text, and
/// a right-aligned mono value.
struct HelmModulePeekRow: Equatable {
    let state: HelmModuleRowState
    let text: String
    let value: String

    static func == (lhs: HelmModulePeekRow, rhs: HelmModulePeekRow) -> Bool {
        lhs.text == rhs.text && lhs.value == rhs.value
    }
}

// MARK: - The usage report body

/// A severity-coloured word on a `.usageReport` section's trailing edge -
/// "Comfortable", "Near cap", "No limits reported".
///
/// It is a *state*, exactly like `HelmModuleChip`: a section header says how
/// the readings below it are doing and never carries a domain hue. The text
/// is painted through `HelmContrast.legibleTintedText` rather than in the
/// raw state hue, because AGENTS.md's colour rules are explicit that a
/// `HelmTint` hue is safe as a fill and is **not** automatically safe as
/// text - which is the one thing the bars below may do and this label may
/// not.
struct HelmModuleUsageStatus: Equatable {
    let text: String
    let state: HelmModuleRowState
}

/// One row of a `.usageReport` section's aligned limit grid: a title, a
/// figure, a full-width bar, and a caption about when the window turns over.
///
/// **`value` is always a real reading or a stated gap, never a filled-in
/// zero** (GL-14): on a quota readout `0%` is a real and alarming value
/// rather than a synonym for "not reported". A row whose source carried
/// nothing passes `isGap: true` and `fill: nil`, which renders the phrase in
/// the muted caption face and draws no bar at all.
struct HelmModuleUsageRow: Equatable {
    let title: String
    let value: String
    /// 0...1 of the track to fill, or `nil` for a row with no track.
    let fill: Double?
    let state: HelmModuleRowState
    /// See the type's own note.
    let isGap: Bool
    /// The visible reset line - `QuotaWindow.resetsCompact`'s short form.
    let caption: String?
    /// The long form of `caption`, carried as the row's hover text and
    /// therefore as what VoiceOver reads. `nil` where there is genuinely
    /// nothing more to say; never a placeholder (GL-14).
    let detail: String?

    init(title: String, value: String, fill: Double?, state: HelmModuleRowState,
         isGap: Bool = false, caption: String? = nil, detail: String? = nil) {
        self.title = title
        self.value = value
        self.fill = fill
        self.state = state
        self.isGap = isGap
        self.caption = caption
        self.detail = detail
    }
}

/// A `.usageReport` section that leads with one money figure rather than a
/// list - the Claude card's extra-usage pool against its spend cap.
///
/// Every field but `amount` is independently optional, because the response
/// behind it genuinely is: `quota-axi` reports `extra_usage` with the
/// dollars and no `percentRemaining` at all on some accounts. A missing cap
/// renders the spend and says so in words, and draws **no** bar - a bar with
/// no ceiling is a picture of a number nobody sent.
struct HelmModuleUsageSpend: Equatable {
    let amount: String
    /// `of $140 cap`, or `spent, no cap set`.
    let against: String?
    /// `98%`, or `nil` when the response carried no percentage.
    let value: String?
    let fill: Double?
    let state: HelmModuleRowState
    /// `$2.38 left before the cap`.
    let footnote: String?
}

/// One section of a `.usageReport` body: a title, an optional status word,
/// and one of three content shapes.
struct HelmModuleUsageSection: Equatable {
    enum Content: Equatable {
        /// The aligned grid - one row per window.
        case limits([HelmModuleUsageRow])
        /// The money figure over its own bar.
        case spend(HelmModuleUsageSpend)
        /// GL-14's stated gap for a whole section, where there is nothing to
        /// list and pretending otherwise would mean drawing zeroes.
        case note(String)
    }

    let title: String
    let status: HelmModuleUsageStatus?
    let content: Content
}

// MARK: - The card

final class HelmModuleCard: NSView, NSGestureRecognizerDelegate {

    /// §6.1's body kinds. `.note` is the one-line form (the table asks for it
    /// by name on Log Analyzer, Tools and Settings) and `.paragraph` is the
    /// wide briefing variant's linked copy.
    enum Body {
        /// A big rounded numeral, an optional unit beside it, an optional
        /// one-line note under it.
        case metric(value: String, unit: String?, note: String?)
        /// Two or three summary rows. More than three is a table, and a
        /// table belongs on the drill page - `maxPeekRows` enforces it.
        case peekRows([HelmModulePeekRow])
        /// A 66pt ring beside a short title and note.
        case ring(value: Int, total: Int, title: String, note: String)
        /// A big numeral over a capsule progress bar.
        case progress(value: Int, total: Int, note: String)
        /// One wrapping line of copy.
        ///
        /// `maxLines` is 2 for every canvas module - a hub widget summarises
        /// rather than explains. Phase 4 slice 6's Tools landing grid is the
        /// one caller that needs more: its plates carry each tool's real
        /// one-sentence description, and two lines truncated most of them.
        /// The card's own `standardHeight` still bounds it (§6.1's body area
        /// is ~100pt, i.e. six caption lines), so this cannot silently
        /// overflow - `DaylightDrillPageSlice6SelfTest` measures the real
        /// need against the real area.
        case note(String, maxLines: Int = 2)
        /// The briefing's linked paragraph. Each clause carries its own
        /// navigation target; a clause with `.none` renders as plain text
        /// rather than as a link that goes nowhere.
        case paragraph([BriefingClause])
        /// The sectioned usage report the captain's mockup replaced the
        /// Claude card's `.statusStrip` with - a hairline-divided stack of
        /// titled sections, each carrying either an aligned grid of
        /// window rows or one money figure over its own bar.
        ///
        /// **Why this is a body kind rather than five more strip columns.**
        /// A strip is one dense row of figures, and its whole economy is
        /// that a reading costs about 74pt of width. This shape trades that
        /// for a full-width bar per window and a reset caption beside it,
        /// which is a taller card - deliberately, and with the captain's
        /// explicit "if it ends up a bit taller than today's, that is fine".
        /// `minimumHeight` is a floor rather than a fixed height (PF2), so
        /// the card simply grows and `HelmResponsiveGrid`'s `equalHeights`
        /// pulls its row up with it.
        ///
        /// `compact` is the narrow reflow, and it is the same decision
        /// `.statusStrip`'s `perRow` makes: at a width where the four
        /// aligned columns would leave the bar a stub, a limit row stacks
        /// into title + figure on one line, the bar across the full width
        /// under it, and the caption under that. Nothing is dropped - the
        /// card pays height instead of a reading, exactly as the strip
        /// already did when it wrapped. See
        /// `HomeCanvasController.claudeUsageIsCompact(forCardWidth:)`, which
        /// picks between them at the same span-2 threshold.
        case usageReport([HelmModuleUsageSection], compact: Bool)
        /// D3's layout-shaped placeholder, for a card whose real answer has
        /// not arrived yet.
        ///
        /// **Review #3's UI10.** The four Setup modules and Vault all render
        /// while `BackgroundSignalsPoller`'s first pass is in flight, and each
        /// filled its body with a sentence beginning "Checking" under an
        /// identical `Checking\u{2026}` chip. Side by side on the Engineering
        /// space that is a wall of five near-identical cards for the ~10s the
        /// first pass takes, and at a canvas column's width the distinct
        /// halves of those sentences truncate away, so what is left really is
        /// the same words five times.
        ///
        /// A skeleton is the loading language this app already speaks -
        /// Review, Overview, Updates and GitHub Sync all got one in D3 - and
        /// it says "not yet" by shape rather than by repeating a word. The
        /// cards stay distinguishable by the things that actually differ:
        /// title, subtitle and artwork.
        case skeleton(rows: Int = 2)
    }

    /// §6.1's "2-3 rows". A module that hands over more is showing a table on
    /// the canvas, which is exactly what the design forbids - the extras are
    /// dropped rather than rendered, and the count is what the card's
    /// accessibility label reports.
    static let maxPeekRows = 3

    /// The briefing paragraph's own cap, for the same reason `maxPeekRows`
    /// exists and enforced the same way (the caller truncates; the overflow is
    /// *reported*, never silently dropped - see `HomeCanvasController.
    /// fillBriefing`).
    ///
    /// **Why a cap survives the return of §6.1's wide card, and why the number
    /// went up.** PR #259 introduced this cap for a reason that no longer
    /// applies - the briefing had been narrowed to one column, where an
    /// unbounded paragraph would make its whole grid row as tall as the
    /// longest briefing of the day. The captain has since restored the wide
    /// (span-2) card, so that reason is gone; a *different* one replaces it.
    /// Every card now resolves to `standardHeight`, so a paragraph taller than
    /// the body area would be clipped by the card's own `masksToBounds` with
    /// nothing said about it. The cap is what keeps that from happening, and
    /// `DaylightModuleSelfTest.checkUniformCardHeight` measures a full-cap
    /// paragraph at a real span-2 width to prove the number fits.
    ///
    /// Five rather than three because double width fits roughly twice the copy
    /// per line - measured, not assumed, by that same case.
    ///
    /// Pairs with `maxNarrowBriefingClauses`: `packRows` degrades a span-2 card
    /// to one column in a single-column grid, and the cap has to follow it
    /// down or the paragraph overflows a card that is now half as wide.
    ///
    /// Clauses stay clauses rather than becoming peek rows because each one
    /// carries a real `BriefingTarget` - turning them into rows would throw
    /// the deep links away, which is the one thing on this card that does
    /// something.
    static let maxBriefingClauses = 5

    /// The same cap for a briefing card that `HelmResponsiveGrid.packRows` has
    /// degraded to a single column - a window narrow enough to fit only one
    /// module across.
    ///
    /// Two, not PR #259's three: that number was measured against a card whose
    /// height grew with its content, and this one's does not. Measured rather
    /// than reasoned - the self-test below caught three overflowing a
    /// one-column card by 16pt at GL-32's "Larger" scale, remembering that the
    /// caller appends an overflow line of its own on top of the cap.
    /// `HomeCanvasController.briefingClauseCap(forCardWidth:)` picks between
    /// the two from the width the grid actually built the card for, and
    /// `DaylightModuleSelfTest.checkUniformCardHeight` measures both at every
    /// text scale.
    static let maxNarrowBriefingClauses = 2

    /// An optional control in the header's trailing edge, right of the chip.
    ///
    /// **A module card is one click target** - `onOpen` fires from a
    /// recognizer on the whole surface - so a second, smaller target inside it
    /// needs gesture arbitration, and that is handled here rather than at each
    /// call site: AppKit defines no automatic exclusivity between an ancestor
    /// recognizer and a descendant control (the trap `SessionStripView`'s own
    /// arbitration already documents), so a click on this button would
    /// otherwise *also* open the card's destination. See
    /// `gestureRecognizer(_:shouldAttemptToRecognizeWith:)` below, which needs
    /// two rules rather than one.
    ///
    /// `nil` on every card but the Claude usage card, whose reading is a
    /// `quota-axi` subprocess the captain may want re-taken on demand rather
    /// than at the next refresh cycle - see
    /// `docs/history/07-fleet-and-notifications.md`.
    struct HeaderAction {
        let symbol: String
        /// The hover text, **and** what VoiceOver announces for the control.
        /// `HelmButton.accessibilityLabel()` returns an icon-only button's
        /// tooltip by design (GL-16 - the alternative is AppKit reading out
        /// the raw SF Symbol name), so there is deliberately no separate
        /// label here: a second string would lose to this one and read as
        /// wired when it was not. Write it as a label, not as a hint.
        let tooltip: String
        /// `true` while the work this control started is still in flight. The
        /// button is *disabled* rather than swapped for a spinner, which is
        /// the in-flight language Overview's own Refresh and
        /// `MorningBriefingCard`'s clock already speak.
        let isBusy: Bool
        let handler: () -> Void
    }

    struct Content {
        var title: String
        var subtitle: String
        var symbol: String
        var hue: HelmDomainHue
        var chip: HelmModuleChip?
        var body: Body
        /// A full-colour raster asset for the header tile, instead of
        /// `symbol`'s glyph on the hue gradient.
        ///
        /// `nil` for every card but one. `fm/polish-straw-hat-overview-card-
        /// and-voice-c8d3` added it for the Straw Hat Pirates card, whose
        /// whole point is being recognisable as *the crew* rather than as one
        /// more tinted tile - see `HelmGradientTile.configure(artwork:symbol:hue:)`
        /// for what changes in the tile and what deliberately does not.
        /// `symbol` stays required either way: it is the fallback if the asset
        /// fails to decode.
        var artwork: NSImage? = nil
        /// Hover text for the whole card.
        ///
        /// UI10: a `.skeleton` body says "not yet" without saying what is
        /// being waited on, and the per-card sentence that used to be the
        /// body is worth keeping somewhere. `nil` everywhere else, which is
        /// exactly what the card had before.
        var toolTip: String? = nil
        /// See `HeaderAction`. `nil` on every card that is only a link to its
        /// own page, which is all but one of them.
        var headerAction: HeaderAction? = nil
        /// One short caption under the chip, on the header's trailing edge -
        /// the Claude card's `Updated 2 min ago`.
        ///
        /// It belongs in the header rather than in the body because it is a
        /// fact about the *reading*, not about any one window: the whole
        /// card is that old. `nil` on every other card, which leaves the
        /// header exactly the shape it has always been - the label is an
        /// arranged subview of a stack, so hiding it removes it from layout
        /// rather than leaving a blank line (AGENTS.md gotcha (15)'s one
        /// case where `isHidden` really does mean "out of the layout").
        var headerCaption: String? = nil
    }

    // Geometry (§2.7, §2.6).
    static let ribbonHeight: CGFloat = 6

    /// C3: how tall and how present the hue ribbon is *at rest*, against
    /// `ribbonHeight`/full opacity when it blooms.
    ///
    /// The UI modernization audit
    /// (`data/grandline-ui-modernization-audit/report.md` §3C) measured the
    /// real cost of seven saturated 6pt ribbons on one canvas: "all 7 ribbons
    /// at once form a rainbow strip effect ... decoration, not signal - it
    /// competes with the one thing PRODUCT.md says should dominate (the
    /// needs-you state)". Its fix is to "quiet the ribbon at rest (2-3pt, 60%
    /// saturation ...), let it bloom on hover/attention".
    ///
    /// The hue itself is untouched - only its height and presence change - so
    /// this stays a pure rendering change and the domain-hue identity the
    /// canvas is built on still reads at a glance.
    static let ribbonRestHeight: CGFloat = 2
    static let ribbonRestOpacity: Float = 0.55
    static let ribbonBloomDuration: TimeInterval = 0.16
    static let headerInsetTop: CGFloat = 13
    static let horizontalInset: CGFloat = 16
    static let bodyInsetTop: CGFloat = 10
    static let bodyInsetBottom: CGFloat = 15
    /// §6.1's hover translate. Skipped under Reduce Motion - the shadow swap
    /// alone is acceptable motion, per that section's own note.
    static let hoverLift: CGFloat = 3
    static let hoverDuration: TimeInterval = 0.14

    /// C2's "scale 0.985 ... on mouse-down". The approved visual calls it
    /// "a 2% press compression", so 0.98 - the midpoint of the two, and the
    /// smallest compression that is still legible at a 176pt card's size.
    static let pressScale: CGFloat = 0.98

    /// **Every module card is exactly this tall, on every space.**
    ///
    /// The captain's own words on the number were "you can choose the best
    /// size", so here is the reasoning rather than just the value. Left to
    /// their natural heights the six body kinds resolve to visibly different
    /// cards - a `.note` is two lines and a `.progress` is a 34pt numeral over
    /// a bar over a note - which makes each grid row a different height and
    /// the hub read as ragged. One fixed height is what makes the canvas look
    /// like a grid.
    ///
    /// The number is the tallest realistic body plus the card's own chrome,
    /// with a little slack. `.progress` (numeral, bar, two-line note) is the
    /// body that sets the floor; `.peekRows` at its own `maxPeekRows` cap is
    /// close behind. Nothing is *sized* to this constant - each body keeps its
    /// natural height and is top-aligned, so a short one simply leaves room
    /// below it (see `rebuildBody`). `DaylightModuleSelfTest.
    /// checkUniformCardHeight` measures every body kind against the real body
    /// area and fails if any of them stops fitting.
    ///
    /// Safe to be a required constraint, unlike a *width*: this card lives
    /// inside the canvas's scroll view, whose document height is free, so a
    /// vertical constraint here cannot pressure the window's own size the way
    /// AGENTS.md gotcha (13) describes.
    ///
    /// Run through `HelmType.scaled` rather than left a literal, because every
    /// font inside the card is: at GL-32's "Larger" (x1.3) the tallest body
    /// grows past a fixed 176 and would be clipped. A card carries the scale
    /// it was *built* at - `applyTheme` re-themes a card but does not rebuild
    /// its body - which is GL-32's own documented remaining half, and is
    /// consistent either way: an existing card keeps both its old fonts and
    /// its old height, a card built after the change gets both new.
    static var standardHeight: CGFloat { HelmType.scaled(baseStandardHeight) }

    /// `standardHeight` before the chrome text scale, i.e. the measured
    /// number. Kept separate so the self-test can name what it measured.
    static let baseStandardHeight: CGFloat = 176

    /// **The floor a card never goes below** (full review #3's PF2).
    ///
    /// `standardHeight` used to be a required `==`, which made every card
    /// exactly as tall as the tallest body kind could ever need. That was the
    /// right call when the modules carried `.progress` numerals and
    /// three-row peeks; most of them now render one line, and the review
    /// measured the result - seven cards on the Overview canvas whose bodies
    /// were about 55% empty.
    ///
    /// So the card sizes to its content, with two things keeping the grid
    /// from going ragged:
    ///
    ///  - this floor, so a one-line card is still a *card* rather than a
    ///    strip - header, body and insets with room to breathe, and enough
    ///    that the gradient tile and the ribbon still read as artwork; and
    ///  - `HelmResponsiveGrid`'s `equalHeights`, which makes every card in a
    ///    row match the tallest in that row. Uniformity moves from "the whole
    ///    canvas" to "each row", which is what a grid actually needs to look
    ///    like a grid.
    ///
    /// The number is the chrome (ribbon + header inset + tile row + body
    /// inset) plus a two-line body, which is the tallest of the *short*
    /// bodies - so a `.note`, the most common kind now, sits exactly at this
    /// floor and every taller kind grows past it on its own.
    static var minimumHeight: CGFloat { HelmType.scaled(baseMinimumHeight) }

    /// `minimumHeight` before the chrome text scale - see `baseStandardHeight`.
    static let baseMinimumHeight: CGFloat = 124

    /// Fired on click (and on a VoiceOver/keyboard press, via
    /// `HoverHighlightView`'s own press replay).
    var onOpen: (() -> Void)?
    /// Fired when a link inside a `.paragraph` body is clicked, with that
    /// clause's own target.
    var onFollowLink: ((BriefingTarget) -> Void)?

    private let card = HoverHighlightView()
    private let ribbon = CAGradientLayer()
    private let tile = HelmGradientTile(size: .module)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chipView = NSView()
    private let chipLabel = NSTextField(labelWithString: "")
    /// `Content.headerCaption`. Built with the rest of the chrome and hidden
    /// when the content carries none, exactly like `chipView`.
    private let headerCaptionLabel = NSTextField(labelWithString: "")
    private let bodyContainer = NSView()
    /// `Content.headerAction`'s control. Built once with the rest of the
    /// chrome and hidden when the content carries no action, exactly like
    /// `chipView` - the header row's shape is stable and only its contents
    /// change.
    private let actionButton = HelmPageToolbar.iconButton(
        symbol: "arrow.clockwise", tooltip: "", target: nil, action: nil)
    private var headerActionHandler: (() -> Void)?

    private var content: Content?
    private var themeToken: ThemeObservation?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var reduceMotionObserver: NSObjectProtocol?

    /// Rebuilt per `configure` - the body is the one part of the card whose
    /// *shape* changes with its content, so it is torn down rather than
    /// mutated. Every other subview is built once here and only re-themed.
    private var bodyViews: [NSView] = []
    private var paragraphView: BriefingParagraphView?
    private var ringGauge: HelmRingGauge?
    private var progressBar: HelmProgressBar?
    private var peekDots: [(dot: NSView, state: HelmModuleRowState)] = []
    private var peekSeparators: [NSView] = []

    // `.usageReport`'s own views, kept for `applyTheme` and for the anatomy.
    // Separate arrays rather than reusing the strip's: a suite asserting the
    // new body must not be able to pass on a leftover strip view, and the
    // two bodies paint their figures differently (a limit row's percentage
    // takes the severity ink where a strip column's figure never does).
    private var usageSectionTitles: [NSTextField] = []
    private var usageStatusLabels: [(label: NSTextField, state: HelmModuleRowState)] = []
    private var usageRowTitles: [NSTextField] = []
    private var usageValues: [(label: NSTextField, state: HelmModuleRowState, isGap: Bool)] = []
    private var usageCaptions: [NSTextField] = []
    private var usageTracks: [(bed: NSView, fill: NSView, state: HelmModuleRowState)] = []
    private var usageDividers: [NSView] = []
    /// Each limit row's own cell, in render order - the view carrying
    /// `HelmModuleUsageRow.detail`'s tooltip and, through AppKit's own
    /// derivation, its VoiceOver help. Read back by the anatomy for the
    /// reason `stripCells` is: the string reaching the model says nothing
    /// about whether anything was wired to it.
    private var usageRowCells: [NSView] = []
    private var peekTextLabels: [NSTextField] = []
    private var peekValueLabels: [NSTextField] = []
    private var noteLabels: [NSTextField] = []
    /// UI10: the `.skeleton` body's list, so `applyTheme` can re-tint its bars
    /// the way every other body kind's views are re-tinted.
    private var skeletonList: HelmSkeletonList?
    private var metricLabels: [NSTextField] = []
    private var unitLabels: [NSTextField] = []

    #if FM_SELFTESTS
    /// `fm/grandline-daylight-shell-regressions`: a live-instance counter
    /// (incremented in `init`, decremented in `deinit`), independent of
    /// `ThemeManager.observerCountForTests` - direct evidence of whether
    /// cards from *every* rebuild cycle over a long, repeated session
    /// actually deallocate, rather than inferring it from one proxy signal.
    static var debugLiveInstanceCount = 0
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildChrome()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // GL-16: toggling Reduce Motion takes effect immediately rather than
        // at the next hover.
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyHoverState(animated: false) }
        #if FM_SELFTESTS
        Self.debugLiveInstanceCount += 1
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
        }
        #if FM_SELFTESTS
        Self.debugLiveInstanceCount -= 1
        #endif
    }

    // MARK: Build

    private func buildChrome() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The shadow host must not clip, or it casts nothing (§2.5).
        layer?.masksToBounds = false

        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = HelmMetrics.dModule
        card.wantsLayer = true
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        let cardClick = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        // Gesture arbitration for `Content.headerAction` - see that type. The
        // delegate declines a click that landed on a real control inside the
        // card, which is the only thing standing between a header button press
        // and the card's own navigation.
        cardClick.delegate = self
        card.addGestureRecognizer(cardClick)
        // C2: a module card is the canonical "press me" surface on the hub,
        // so it opts into the shared press compression. `HoverHighlightView`
        // composes it with the hover lift this class hands it through
        // `baseTransform`.
        card.pressScale = Self.pressScale
        addSubview(card)

        card.layer?.addSublayer(ribbon)
        ribbon.startPoint = HelmDomainHue.ribbonStart
        ribbon.endPoint = HelmDomainHue.ribbonEnd

        titleLabel.font = HelmType.moduleTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = HelmType.captionSmall()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (13)/(14): a label's own >500 compression
        // resistance is a real width floor on every ancestor up to the
        // window. The text column is the one thing in this card that must
        // yield first.
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12): the *stack*-level priority APIs, not the
        // content ones, which are no-ops on a view with no intrinsic size.
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        chipLabel.font = HelmType.chip()
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chipView.wantsLayer = true
        chipView.translatesAutoresizingMaskIntoConstraints = false
        chipView.addSubview(chipLabel)
        chipView.setContentHuggingPriority(.required, for: .horizontal)
        chipView.setContentCompressionResistancePriority(.required, for: .horizontal)

        headerCaptionLabel.font = HelmType.captionSmall()
        headerCaptionLabel.lineBreakMode = .byTruncatingTail
        headerCaptionLabel.translatesAutoresizingMaskIntoConstraints = false
        headerCaptionLabel.isHidden = true
        // gotcha (13): `.defaultLow`, unlike the chip beside it. The chip is
        // a fixed word the card must not truncate; this is a caption about
        // freshness, and a label that will not yield is a width floor on
        // every ancestor up to the window (`AppShellBodyWidthSelfTest`'s own
        // finding, from this card's note label).
        headerCaptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The chip and the caption stack, right-aligned, with the refresh
        // button beside them - the mockup's header shape. An empty caption
        // is `isHidden`, which for an *arranged* subview really does take it
        // out of the layout, so a card with no caption renders the chip at
        // exactly the height it always had.
        let statusStack = NSStackView(views: [chipView, headerCaptionLabel])
        statusStack.orientation = .vertical
        statusStack.alignment = .trailing
        statusStack.spacing = 3
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (12): the *stack*-level APIs. Hugging required so the stack
        // never absorbs the header's slack (that is the text column's job);
        // clipping resistance left low so the stack itself is not a floor -
        // the chip inside carries the one required minimum here, exactly as
        // it did when it sat in the header row directly.
        statusStack.setHuggingPriority(.required, for: .horizontal)
        statusStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        actionButton.target = self
        actionButton.action = #selector(headerActionTapped)
        actionButton.isHidden = true
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [tile, textStack, statusStack, actionButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = HelmMetrics.s3
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (12)+(13), and the reason this is not merely tidiness: an
        // `NSStackView` resists clipping below its arranged subviews' own
        // minimums at `.defaultHigh` (750) by default, which is above
        // `NSLayoutPriorityWindowSizeStayPut` (500) - so a stack inside a
        // module card is a *window* floor unless it is told to yield. The
        // labels inside already yield; the stack holding them did not.
        // See `compressibleStack` for the rest of them.
        headerRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        headerRow.setHuggingPriority(.defaultLow, for: .horizontal)

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(headerRow)
        card.addSubview(bodyContainer)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            // PF2: a **floor**, not a fixed height. See `minimumHeight` and
            // `standardHeight` for the reasoning, and
            // `HelmResponsiveGrid`'s `equalHeights` for the other half - the
            // one that keeps a row uniform now that a card can be shorter
            // than its neighbour. A required *height* is safe here where a
            // required width would not be (AGENTS.md gotcha (13)): this card
            // lives inside a scroll view whose document height is free.
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),

            chipLabel.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: 10),
            chipLabel.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -10),
            chipLabel.topAnchor.constraint(equalTo: chipView.topAnchor, constant: 3),
            chipLabel.bottomAnchor.constraint(equalTo: chipView.bottomAnchor, constant: -3),

            headerRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.horizontalInset),
            headerRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.horizontalInset),
            headerRow.topAnchor.constraint(equalTo: card.topAnchor,
                                           constant: Self.ribbonHeight + Self.headerInsetTop),

            bodyContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.horizontalInset),
            bodyContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.horizontalInset),
            bodyContainer.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: Self.bodyInsetTop),
            bodyContainer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.bodyInsetBottom),
        ])
    }

    // MARK: Configure

    func configure(_ content: Content) {
        self.content = content
        if let artwork = content.artwork {
            tile.configure(artwork: artwork, symbol: content.symbol, hue: content.hue)
        } else {
            tile.configure(symbol: content.symbol, hue: content.hue)
        }
        titleLabel.stringValue = content.title
        subtitleLabel.stringValue = content.subtitle
        // On the card view itself, not only on the inner surface: the whole
        // module is the hover target a captain aims at.
        toolTip = content.toolTip
        card.toolTip = content.toolTip

        if let chip = content.chip {
            chipView.isHidden = false
            chipLabel.stringValue = chip.text
        } else {
            chipView.isHidden = true
            chipLabel.stringValue = ""
        }

        if let caption = content.headerCaption, !caption.isEmpty {
            headerCaptionLabel.isHidden = false
            headerCaptionLabel.stringValue = caption
        } else {
            headerCaptionLabel.isHidden = true
            headerCaptionLabel.stringValue = ""
        }

        if let action = content.headerAction {
            actionButton.isHidden = false
            actionButton.symbolName = action.symbol
            actionButton.toolTip = action.tooltip
            actionButton.isEnabled = !action.isBusy
            headerActionHandler = action.handler
        } else {
            actionButton.isHidden = true
            headerActionHandler = nil
        }

        rebuildBody(content.body)

        // GL-16: §6.1's own label spec - "<title>, <subtitle>, <chip text>".
        // Set explicitly rather than left to `HoverHighlightView`'s
        // descendant-label derivation, because a body full of numerals would
        // otherwise be read out before the title.
        var spoken = [content.title, content.subtitle]
        if let chip = content.chip { spoken.append(chip.text) }
        // The freshness caption is part of the reading, not chrome: "Updated
        // 2 min ago" is what tells a captain whether the figures below are
        // worth acting on, so VoiceOver gets it in the same breath.
        if let caption = content.headerCaption, !caption.isEmpty { spoken.append(caption) }
        card.accessibilityLabelOverride = spoken.filter { !$0.isEmpty }.joined(separator: ", ")

        applyTheme(ThemeManager.shared.theme)
    }

    private func rebuildBody(_ body: Body) {
        for view in bodyViews { view.removeFromSuperview() }
        bodyViews.removeAll()
        paragraphView = nil
        skeletonList = nil
        ringGauge = nil
        progressBar = nil
        peekDots.removeAll()
        peekSeparators.removeAll()
        usageSectionTitles.removeAll()
        usageStatusLabels.removeAll()
        usageRowTitles.removeAll()
        usageValues.removeAll()
        usageCaptions.removeAll()
        usageTracks.removeAll()
        usageDividers.removeAll()
        usageRowCells.removeAll()
        peekTextLabels.removeAll()
        peekValueLabels.removeAll()
        noteLabels.removeAll()
        metricLabels.removeAll()
        unitLabels.removeAll()

        let content: NSView
        switch body {
        case let .metric(value, unit, note):
            content = buildMetric(value: value, unit: unit, note: note)
        case let .peekRows(rows):
            content = buildPeekRows(Array(rows.prefix(Self.maxPeekRows)))
        case let .ring(value, total, title, note):
            content = buildRing(value: value, total: total, title: title, note: note)
        case let .progress(value, total, note):
            content = buildProgress(value: value, total: total, note: note)
        case let .note(text, maxLines):
            content = buildNote(text, maxLines: maxLines)
        case let .paragraph(clauses):
            content = buildParagraph(clauses)
        case let .usageReport(sections, compact):
            content = buildUsageReport(sections, compact: compact)
        case let .skeleton(rows):
            content = buildSkeleton(rows: rows)
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(content)
        bodyViews.append(content)
        // Still `<=`, and PF2 made it **required** where it used to be
        // `.defaultHigh`.
        //
        // `<=` is what lets one card height work across six body kinds of
        // different natural sizes: the body keeps its own height, sits at the
        // top of the area, and a short one leaves the slack below it rather
        // than being stretched to fill it (`.fill` on a vertical stack would
        // otherwise pull a two-line note apart). That is unchanged, and it is
        // also what lets a row stretch a short card to match its tallest
        // neighbour for free - the slack simply grows.
        //
        // It is required now because the reason it was not is gone. It used
        // to be the constraint AppKit should break if a body outgrew a card
        // whose height was *fixed*; there is no fixed height any more, so a
        // body that needs more room gets it by making its own card taller.
        // Required therefore turns "should not clip" into "cannot clip",
        // which is the one guarantee this card owes its content.
        let bodyBottom = content.bottomAnchor.constraint(lessThanOrEqualTo: bodyContainer.bottomAnchor)

        // PF2's second half, and the pair above is deliberate: `<=` required
        // says the body **cannot** be clipped, and this `==` at 250 says the
        // area should nonetheless hug it. Together they mean "as tall as the
        // content, and never shorter".
        //
        // It is expressed here, on the body, rather than as a preferred
        // height on the card, because a card-level height constant has to
        // out-argue every stack inside the card about how compressible it is
        // - which it loses, and the measured result was a peek list squashed
        // into a 49pt area it needed 86pt for. This constraint has nothing to
        // argue with: it only asks the area to stop where its content does.
        //
        // **Priority 1**, and that is not a rounding of "low" - it has to lose
        // to literally everything, and 250 (`.defaultLow`) was measured doing
        // real damage.
        //
        // The bodies are built from stacks and labels whose *vertical*
        // clipping and compression resistances are not uniformly high, so a
        // 250 hug already outranked some of them: a three-row peek list
        // rendered into a 68pt area it needed 86pt for, clipped, with no
        // "unable to simultaneously satisfy" logged - because nothing was
        // unsatisfiable, the hug simply won. At priority 1 the hug can only
        // ever be the tie-breaker it is meant to be: it decides the card's
        // height when nothing else has an opinion, and yields the moment
        // anything does.
        let bodyHug = content.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
        bodyHug.priority = NSLayoutConstraint.Priority(1)

        NSLayoutConstraint.activate([
            bodyHug,
            content.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            // `<=`, not `==`, and that is what makes one fixed card height
            // work across six body kinds of different natural sizes: the body
            // keeps its own height, sits at the top of the area, and a short
            // one leaves the slack below it rather than being stretched to
            // fill it (`.fill` on a vertical stack would otherwise pull a
            // two-line note apart). `.defaultHigh` rather than required so
            // that if a body ever *did* outgrow the area, this is the
            // constraint AppKit breaks - not `standardHeight`, and not a
            // label's own height - which keeps the failure to one card
            // instead of deforming the row. Nothing should reach that state:
            // every body kind is capped at the content layer (`maxPeekRows`,
            // `maxBriefingClauses`, `noteLabel`'s two lines) and
            // `DaylightModuleSelfTest.checkUniformCardHeight` measures all of
            // them against the real area.
            bodyBottom,
        ])
    }

    private func metricLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.moduleMetric()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metricLabels.append(label)
        return label
    }

    private func noteLabel(_ text: String, maxLines: Int = 2) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = HelmType.caption()
        label.isSelectable = false
        label.maximumNumberOfLines = max(1, maxLines)
        // **`.byWordWrapping`, not `.byTruncatingTail`** - the other half of
        // review #3's B7, and the half no wrap width could have fixed.
        // `.byTruncatingTail` *is* the single-line mode: it tells the cell to
        // lay the whole string out on one line and put an ellipsis at the end,
        // so `maximumNumberOfLines = 2` had nothing to count. Measured on a
        // real 300pt card, a 97-character note still rendered one line and
        // used 15pt of a 101pt body. With wrapping on, `maximumNumberOfLines`
        // is what bounds it and AppKit ellipsises the *last* line, which is
        // the behaviour the property was set for.
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabels.append(label)
        return label
    }

    private func buildMetric(value: String, unit: String?, note: String?) -> NSView {
        let number = metricLabel(value)
        var row: [NSView] = [number]
        if let unit, !unit.isEmpty {
            let unitLabel = NSTextField(labelWithString: unit)
            unitLabel.font = HelmType.metricUnit()
            unitLabel.translatesAutoresizingMaskIntoConstraints = false
            unitLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            unitLabels.append(unitLabel)
            row.append(unitLabel)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.append(spacer)

        let metricRow = compressibleStack(NSStackView(views: row))
        metricRow.orientation = .horizontal
        metricRow.alignment = .lastBaseline
        metricRow.spacing = HelmMetrics.s1 + 2
        metricRow.distribution = .fill
        metricRow.translatesAutoresizingMaskIntoConstraints = false

        var stacked: [NSView] = [metricRow]
        if let note, !note.isEmpty { stacked.append(noteLabel(note)) }
        return verticalStack(stacked, spacing: HelmMetrics.s1 + 2)
    }

    private func buildPeekRows(_ rows: [HelmModulePeekRow]) -> NSView {
        var stacked: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSView()
                separator.wantsLayer = true
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                peekSeparators.append(separator)
                stacked.append(separator)
            }

            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.setContentHuggingPriority(.required, for: .horizontal)
            dot.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            peekDots.append((dot, row.state))

            let text = NSTextField(labelWithString: row.text)
            text.font = HelmType.caption()
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            peekTextLabels.append(text)

            let value = NSTextField(labelWithString: row.value)
            value.font = HelmType.code()
            value.alignment = .right
            value.translatesAutoresizingMaskIntoConstraints = false
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.setContentHuggingPriority(.required, for: .horizontal)
            peekValueLabels.append(value)

            let peek = compressibleStack(NSStackView(views: [dot, text, value]))
            peek.orientation = .horizontal
            peek.alignment = .centerY
            peek.spacing = HelmMetrics.s2
            peek.distribution = .fill
            peek.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
            peek.translatesAutoresizingMaskIntoConstraints = false
            stacked.append(peek)
        }
        if stacked.isEmpty { stacked = [noteLabel("Nothing to show yet.")] }
        return verticalStack(stacked, spacing: 0)
    }

    // MARK: The usage report body

    /// A capsule track with a fractional fill, at one of the report's two
    /// weights - 6pt under a limit row, 8pt under the spend figure.
    ///
    /// The fill is a *fraction of the bed*, never a baked width, so it
    /// follows the card's real width at every window size - the same shape
    /// the peek list's own dot already uses, and at `contentTie` (499) for
    /// gotcha (13)'s reason.
    private func makeUsageTrack(fill: Double, state: HelmModuleRowState, height: CGFloat) -> NSView {
        let bed = NSView()
        bed.wantsLayer = true
        bed.layer?.cornerRadius = HelmMetrics.capsuleRadius(forHeight: height)
        bed.translatesAutoresizingMaskIntoConstraints = false
        bed.heightAnchor.constraint(equalToConstant: height).isActive = true
        // A bare `NSView` has no intrinsic size, so no content-priority API
        // can make it hold a width (gotcha (12)) - this floor has to be a
        // real constraint. At `contentTie` it can still never reach the
        // window as a floor (gotcha (13)), which means an extremely narrow
        // card loses the bar rather than refusing to be narrow.
        let floor = bed.widthAnchor.constraint(greaterThanOrEqualToConstant: 40)
        floor.priority = HelmDaylightPriority.contentTie
        floor.isActive = true

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = HelmMetrics.capsuleRadius(forHeight: height)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bed.addSubview(bar)
        let fraction = bar.widthAnchor.constraint(
            equalTo: bed.widthAnchor,
            multiplier: max(0.0001, min(1, CGFloat(fill))))
        fraction.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            fraction,
            bar.leadingAnchor.constraint(equalTo: bed.leadingAnchor),
            bar.topAnchor.constraint(equalTo: bed.topAnchor),
            bar.bottomAnchor.constraint(equalTo: bed.bottomAnchor),
        ])
        usageTracks.append((bed, bar, state))
        return bed
    }

    private func makeUsageDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        usageDividers.append(divider)
        return divider
    }

    /// A section's header: the title, and the severity word on its trailing
    /// edge. The word is a *label*, not a pill - the header pill above it is
    /// the card's one badge, and a second capsule here competes with it.
    private func makeUsageSectionHeader(_ section: HelmModuleUsageSection) -> NSView {
        let title = NSTextField(labelWithString: section.title)
        title.font = HelmType.rowTitle()
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usageSectionTitles.append(title)

        var views: [NSView] = [title]
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        views.append(spacer)

        if let status = section.status {
            let label = NSTextField(labelWithString: status.text)
            label.font = HelmType.chip()
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            usageStatusLabels.append((label, status.state))
            views.append(label)
        }

        let row = compressibleStack(NSStackView(views: views))
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = HelmMetrics.s3
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// A limit row's title and figure, which are the two things that stay
    /// side by side in **both** layouts.
    private func makeUsageRowLabels(_ row: HelmModuleUsageRow) -> (title: NSTextField, value: NSTextField) {
        let title = NSTextField(labelWithString: row.title)
        title.font = HelmType.caption()
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Hugging, so the column never absorbs the row's slack - the bar is
        // the one thing that should grow. A *leaf* view with a real
        // intrinsic size, so unlike gotcha (12)'s stacks the content API is
        // the right one here.
        //
        // **`columnHug`, never `.required` and never `contentTie`** - that
        // type's own note has the two measurements. The short version: a
        // content hugging priority is a width *ceiling*, and this card ties
        // its body to its own width with a required equality, so a label
        // hugging hard enough caps the whole card.
        title.setContentHuggingPriority(HelmDaylightPriority.columnHug, for: .horizontal)
        usageRowTitles.append(title)

        let value = NSTextField(labelWithString: row.value)
        // Tabular digits: the figures sit in one column across rows, and
        // proportional digits make a column of percentages ripple.
        value.font = row.isGap ? HelmType.caption() : HelmType.metric(12, weight: .semibold)
        value.alignment = .right
        value.lineBreakMode = .byTruncatingTail
        value.translatesAutoresizingMaskIntoConstraints = false
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.setContentHuggingPriority(HelmDaylightPriority.columnHug, for: .horizontal)
        usageValues.append((value, row.state, row.isGap))

        return (title, value)
    }

    private func makeUsageCaption(_ text: String, detail: String?) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.captionSmall()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(HelmDaylightPriority.columnHug, for: .horizontal)
        // GL-16: what VoiceOver reads is the *full* sentence, so the short
        // painted form costs nothing.
        label.setAccessibilityLabel(detail ?? text)
        usageCaptions.append(label)
        return label
    }

    /// The four-column grid, where the bars line up across rows.
    ///
    /// **`NSGridView`, not nested stacks** - AGENTS.md gotcha (2)'s tool, and
    /// the alignment requirement is exactly what it is for: three of the four
    /// columns are content-sized and the bar column is the one left
    /// unconstrained, so it absorbs every point of slack and the bars start
    /// and end at the same x on every row. Gotcha (2)'s own warning is the
    /// other direction of this - a grid where the *wrong* column is left
    /// unconstrained grows a gap instead - so the grid's own width is pinned
    /// to its container below, giving the fill column a definite total.
    private func buildUsageLimitsGrid(_ rows: [HelmModuleUsageRow]) -> NSView {
        let grid = NSGridView(numberOfColumns: 4, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = HelmMetrics.s3
        grid.yPlacement = .center
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 3).xPlacement = .trailing

        for row in rows {
            let labels = makeUsageRowLabels(row)
            // A row with no reading draws no bar at all (GL-14): an empty
            // track beside three filled ones reads as "0%", which on a quota
            // card is a real value rather than a synonym for "unknown".
            let bar: NSView = row.fill.map { makeUsageTrack(fill: $0, state: row.state, height: 6) }
                ?? NSGridCell.emptyContentView
            let caption: NSView = row.caption.map { makeUsageCaption($0, detail: row.detail) }
                ?? NSGridCell.emptyContentView
            let gridRow = grid.addRow(with: [labels.title, labels.value, bar, caption])
            // The row's own hover text, carrying the long form of the reset
            // instant - and AppKit derives the accessibility help from it,
            // so the pointer and VoiceOver get the same string by
            // construction rather than by two call sites agreeing.
            if let detail = row.detail {
                for index in 0..<gridRow.numberOfCells {
                    gridRow.cell(at: index).contentView?.toolTip = detail
                }
            }
            usageRowCells.append(labels.title)
        }
        return grid
    }

    /// The compact reflow: title and figure on one line, the bar across the
    /// full width under them, the reset caption under that.
    ///
    /// The same trade `.statusStrip`'s wrap makes - height instead of a
    /// reading - and it mirrors the mockup's own `@media (max-width: 560px)`
    /// rule rather than inventing a second narrow language.
    private func buildUsageLimitsStack(_ rows: [HelmModuleUsageRow]) -> NSView {
        var stacked: [NSView] = []
        for row in rows {
            let labels = makeUsageRowLabels(row)
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            let line = compressibleStack(NSStackView(views: [labels.title, spacer, labels.value]))
            line.orientation = .horizontal
            line.alignment = .firstBaseline
            line.spacing = HelmMetrics.s2
            line.distribution = .fill
            line.translatesAutoresizingMaskIntoConstraints = false

            var cellViews: [NSView] = [line]
            if let fill = row.fill {
                cellViews.append(makeUsageTrack(fill: fill, state: row.state, height: 6))
            }
            if let caption = row.caption {
                cellViews.append(makeUsageCaption(caption, detail: row.detail))
            }
            let cell = verticalStack(cellViews, spacing: HelmMetrics.s1)
            cell.alignment = .leading
            cell.toolTip = row.detail
            usageRowCells.append(cell)
            stacked.append(cell)
        }
        let column = verticalStack(stacked, spacing: HelmMetrics.s2 + 2)
        column.alignment = .leading
        return column
    }

    /// The money figure, its cap, its percentage, its bar and its footnote.
    private func buildUsageSpend(_ spend: HelmModuleUsageSpend) -> NSView {
        let amount = NSTextField(labelWithString: spend.amount)
        amount.font = HelmType.metric(20, weight: .semibold)
        amount.lineBreakMode = .byTruncatingTail
        amount.translatesAutoresizingMaskIntoConstraints = false
        amount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // `metricLabels` rather than an array of its own: this *is* the
        // body's one big number, which is what that array means - and it
        // puts the figure in `Anatomy.metricTexts` where every other body
        // kind's headline number already is.
        metricLabels.append(amount)

        var top: [NSView] = [amount]
        if let against = spend.against, !against.isEmpty {
            top.append(makeUsageCaptionLine(against))
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        top.append(spacer)
        if let value = spend.value {
            let pct = NSTextField(labelWithString: value)
            pct.font = HelmType.metric(12, weight: .semibold)
            pct.alignment = .right
            pct.translatesAutoresizingMaskIntoConstraints = false
            pct.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pct.setContentHuggingPriority(HelmDaylightPriority.columnHug, for: .horizontal)
            usageValues.append((pct, spend.state, false))
            top.append(pct)
        }

        let topRow = compressibleStack(NSStackView(views: top))
        topRow.orientation = .horizontal
        topRow.alignment = .firstBaseline
        topRow.spacing = HelmMetrics.s1 + 2
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false

        var stacked: [NSView] = [topRow]
        if let fill = spend.fill {
            stacked.append(makeUsageTrack(fill: fill, state: spend.state, height: 8))
        }
        if let footnote = spend.footnote, !footnote.isEmpty {
            stacked.append(makeUsageCaption(footnote, detail: nil))
        }
        let column = verticalStack(stacked, spacing: HelmMetrics.s1 + 2)
        column.alignment = .leading
        return column
    }

    /// The muted `of $140 cap` beside the spend figure - a caption that is
    /// part of a baseline-aligned row rather than a line of its own, so it
    /// keeps its own hugging rather than taking `makeUsageCaption`'s.
    private func makeUsageCaptionLine(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.caption()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usageCaptions.append(label)
        return label
    }

    private func buildUsageReport(_ sections: [HelmModuleUsageSection], compact: Bool) -> NSView {
        guard !sections.isEmpty else { return noteLabel("Nothing to show yet.") }

        // The divider the mockup draws between the header and the first
        // section. It belongs to the body rather than to the chrome so a
        // card with any other body keeps the header it has always had.
        var stacked: [NSView] = [makeUsageDivider()]
        for (index, section) in sections.enumerated() {
            if index > 0 { stacked.append(makeUsageDivider()) }
            stacked.append(makeUsageSectionHeader(section))
            switch section.content {
            case let .limits(rows):
                stacked.append(compact ? buildUsageLimitsStack(rows) : buildUsageLimitsGrid(rows))
            case let .spend(spend):
                stacked.append(buildUsageSpend(spend))
            case let .note(text):
                stacked.append(noteLabel(text))
            }
        }

        // `verticalStack` already pins each row leading-required /
        // trailing-at-`contentTie`, which is what gives the grid a definite
        // total for its fill column to absorb (gotcha (2)'s second half) -
        // no extra width tie is needed here, and a second one would only be
        // another chance to set a floor.
        let column = verticalStack(stacked, spacing: HelmMetrics.s2 + 2)
        column.alignment = .leading
        return column
    }

    private func buildRing(value: Int, total: Int, title: String, note: String) -> NSView {
        let ring = HelmRingGauge()
        ring.configure(value: value, total: total)
        ringGauge = ring

        let titleField = NSTextField(labelWithString: title)
        titleField.font = HelmType.rowTitle()
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metricLabels.append(titleField)

        // B9 (`data/grand-line-e2e-audit/report.md`): three lines, not the
        // default two. A `.ring` body spends `HelmRingGauge.side` (66pt) of
        // the card's width on the gauge, so its note column is much narrower
        // than a plain `.note` body's - which is why Overview's Health module
        // truncated mid-word ("Everything that has reported i...") while the
        // card still had vertical room. Three caption lines are still shorter
        // than the 66pt gauge beside them, so the row does not grow.
        let text = verticalStack([titleField, noteLabel(note, maxLines: 3)], spacing: 2)
        text.alignment = .leading

        let row = compressibleStack(NSStackView(views: [ring, text]))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func buildProgress(value: Int, total: Int, note: String) -> NSView {
        let number = metricLabel(total > 0 ? "\(value)/\(total)" : "\(value)")
        let bar = HelmProgressBar()
        bar.configure(fraction: total > 0 ? Double(value) / Double(total) : 0)
        progressBar = bar
        return verticalStack([number, bar, noteLabel(note)], spacing: HelmMetrics.s2)
    }

    private func buildNote(_ text: String, maxLines: Int = 2) -> NSView {
        verticalStack([noteLabel(text, maxLines: maxLines)], spacing: 0)
    }

    /// UI10's placeholder body. `HelmSkeletonList` owns the bars, the shimmer
    /// and the Reduce-Motion gating, so this is only the placement.
    private func buildSkeleton(rows: Int) -> NSView {
        let list = HelmSkeletonList(rows: rows)
        list.applyTheme(ThemeManager.shared.theme)
        skeletonList = list
        return verticalStack([list], spacing: 0)
    }

    private func buildParagraph(_ clauses: [BriefingClause]) -> NSView {
        let paragraph = BriefingParagraphView()
        paragraph.onActivate = { [weak self] target in self?.onFollowLink?(target) }
        // `MorningBriefingLocal.statSeparator` is what the deterministic
        // half's fragments join with; the AI half returns whole sentences, so
        // a space is right there. Reusing `MorningBriefingCard`'s own view
        // means the briefing reads identically on the canvas and on Overview.
        paragraph.render(clauses, separator: " ", theme: ThemeManager.shared.theme)
        paragraphView = paragraph
        return verticalStack([paragraph], spacing: 0)
    }

    /// Every horizontal stack inside a card must yield rather than act as a
    /// width floor.
    ///
    /// A card is laid out into whatever column the grid hands it, and the grid
    /// row is `.fillEqually` - so one card refusing to compress does not cap
    /// the window by its own width, it caps it by *column count times* its own
    /// width. That is how a single card with a long note produced a 1135.5pt
    /// floor on every destination at once (`.homeCanvas` is eagerly mounted,
    /// so its constraints are live whichever page is showing - gotcha (11)),
    /// caught by `AppShellBodyWidthSelfTest`.
    ///
    /// Note this is the *stack*-level API: `setContentCompressionResistance-
    /// Priority` is a no-op on a view with no intrinsic content size, which an
    /// `NSStackView` does not have (gotcha (12)).
    /// Horizontally compressible (gotcha (13)'s rule - a body that will not
    /// yield sideways is a window-width floor) and **vertically
    /// incompressible** (PF2).
    ///
    /// The vertical half is not symmetry for its own sake. A card is
    /// content-sized now, and a grid row ties its cards to the row's height
    /// so they all match the tallest - a required tie, which will happily win
    /// against a 750 clipping resistance and squash a taller card's body to
    /// match a shorter neighbour. Measured: a three-row peek list settled at
    /// 124pt beside a one-line note instead of pulling the note up to its own
    /// 143pt. Required here means the tie can only ever resolve upward, which
    /// is the only direction that shows everyone's content.
    private func compressibleStack(_ stack: NSStackView) -> NSStackView {
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.setClippingResistancePriority(.required, for: .vertical)
        return stack
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // PF2: **vertically** incompressible, which horizontally it
        // deliberately is not.
        //
        // The horizontal `.defaultLow` above is gotcha (13)'s rule - a stack
        // resists clipping at 750, above `NSLayoutPriorityWindowSizeStayPut`,
        // so a body that would not yield horizontally is a window-width
        // floor. None of that applies to height: this card lives in a scroll
        // view whose document height is free.
        //
        // Measured, and the reason this line exists: with the default here, a
        // grid row's equal-height tie settled on the *shortest* card and
        // squashed the taller one's body to fit, rather than stretching the
        // short ones up. A body that cannot be squashed is what makes the tie
        // resolve to the tallest card, which is the only answer that shows
        // all of everyone's content.
        stack.setClippingResistancePriority(.required, for: .vertical)
        for view in views {
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            let trailing = view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            // 499, never required: this chain runs all the way up to the
            // window through the canvas's grid, and a required tie here would
            // let a card's own content set a window-width floor (gotcha #13).
            trailing.priority = HelmDaylightPriority.contentTie
            trailing.isActive = true
        }
        return stack
    }

    // MARK: Hover (§6.1)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyHoverState(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyHoverState(animated: true)
    }

    /// C3: the ribbon's height and presence, from one place.
    ///
    /// Blooms to its full 6pt when the card is hovered, and - deliberately -
    /// also whenever the card's own chip says the card is *bad*. That is the
    /// finding's own carve-out ("a card whose chip is `.critical` may keep a
    /// loud edge - color as signal, not as wallpaper"): quieting the ribbon
    /// is about stopping seven equal-weight hues competing, not about hiding
    /// the one card that needs the captain.
    private func applyRibbonGeometry(animated: Bool) {
        let bloomed = isHovering || content?.chip?.kind == .bad
        let height = bloomed ? Self.ribbonHeight : Self.ribbonRestHeight
        let opacity: Float = bloomed ? 1 : Self.ribbonRestOpacity
        let frame = CGRect(x: 0, y: card.bounds.height - height,
                           width: card.bounds.width, height: height)

        guard animated, !HelmMotion.isReduced else {
            // A standalone (non-view-backed) `CALayer` animates `frame` and
            // `opacity` implicitly, so "instant" has to be asked for.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ribbon.frame = frame
            ribbon.opacity = opacity
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.ribbonBloomDuration)
        ribbon.frame = frame
        ribbon.opacity = opacity
        CATransaction.commit()
    }

    private func applyHoverState(animated: Bool) {
        let theme = ThemeManager.shared.theme
        applyShadow(theme, raised: isHovering)
        // §6.1: the shadow swap always happens; the 3pt translate is skipped
        // under Reduce Motion, which that section explicitly allows.
        let allowMotion = !HelmMotion.isReduced
        // AppKit's y grows upward in an unflipped view, so lifting a card is a
        // *positive* translate.
        let lift: CGFloat = (isHovering && allowMotion) ? Self.hoverLift : 0
        // C2: the lift is handed to the card's own `baseTransform` rather than
        // written straight onto `card.layer.transform`, because the press
        // compression now writes that same property. `HoverHighlightView` is
        // the single owner and composes the two, so a card pressed while
        // hovered reads as lifted *and* compressed instead of one state
        // silently cancelling the other.
        HelmMotion.animate(animated && allowMotion, duration: Self.hoverDuration) {
            card.baseTransform = CATransform3DMakeTranslation(0, lift, 0)
        }
        // C3: the ribbon blooms with the hover instead of sitting loud at
        // rest - see `applyRibbonGeometry`.
        applyRibbonGeometry(animated: animated && allowMotion)
    }

    #if FM_SELFTESTS
    /// Drives the real hover path (`applyHoverState`) so a self-test can
    /// measure the resulting transform in both Reduce Motion states.
    func debugSetHovering(_ hovering: Bool, animated: Bool = false) {
        isHovering = hovering
        applyHoverState(animated: animated)
    }

    /// The hover transform actually applied to the card's own layer.
    var debugCardTransform: CATransform3D { card.layer?.transform ?? CATransform3DIdentity }

    /// The card's inner activatable view, so the accessibility suite can
    /// assert the role/label/press contract on the thing that carries it.
    var debugCardHitView: HoverHighlightView { card }
    #endif

    // MARK: Layout and theme

    #if FM_SELFTESTS
    /// How many times `layout()` has actually run for this card instance -
    /// `AppShellBodyWidthSelfTest.test_moduleCardLayoutRunsOnceForOneRequest`'s
    /// evidence that a single logical layout request settles rather than
    /// re-triggering itself (a real, if not-yet-observed, mechanism for
    /// sustained CPU - see that test's own doc comment).
    var debugLayoutCallCount = 0
    #endif

    override func layout() {
        super.layout()
        #if FM_SELFTESTS
        debugLayoutCallCount += 1
        #endif
        // A standalone sublayer's `frame` change animates implicitly, so a
        // window resize would slide the ribbon into place behind the card's
        // own instant relayout - see `HelmMotion`'s header, finding 2.
        // C3: one writer of the ribbon's geometry, so a layout pass and a
        // hover bloom can never disagree about how tall it currently is.
        // Always instant here - a window resize must not slide the ribbon
        // behind the card's own relayout.
        applyRibbonGeometry(animated: false)
        applyNoteWrapWidth()
        applyShadow(ThemeManager.shared.theme, raised: isHovering)
    }

    /// Give every wrapping note label the width it will really be laid out at.
    ///
    /// **Derived from this view's own `bounds`, never from `bodyContainer`'s** -
    /// review #3's B7. A view's `layout()` runs *before* its descendants get
    /// their frames, so reading `bodyContainer.bounds.width` there returns 0 on
    /// the first pass; a `preferredMaxLayoutWidth` of 0 means "no wrap width",
    /// the label takes its single-line intrinsic height, and nothing marks this
    /// card dirty again afterwards (`layoutSubtreeIfNeeded` only descends into
    /// views already flagged `needsLayout`). Measured on a real 300pt card: the
    /// wrap width stayed 0, every note rendered as **one truncated line**, and
    /// the body used 15pt of its 101pt area - which is the ~90pt of empty card
    /// under a cut-off sentence the finding describes, on every Tools plate and
    /// every Daylight-family canvas card.
    ///
    /// This view's own width *is* known when its `layout()` runs (its parent
    /// set the frame), and the body's width is a fixed inset off it - the same
    /// "re-derive from a geometry you already have" shape
    /// `HealthCardView.layoutDidChange` and `SettingsController
    /// .layoutDidChangeWidths` use.
    ///
    /// Only assigned on a real change: `preferredMaxLayoutWidth` invalidates
    /// the label's intrinsic size, which schedules another pass, and writing
    /// the same value every pass would keep scheduling them.
    private func applyNoteWrapWidth() {
        let available = bounds.width - Self.horizontalInset * 2
        guard available > 0 else { return }
        for label in noteLabels where abs(label.preferredMaxLayoutWidth - available) > 0.5 {
            label.preferredMaxLayoutWidth = available
            label.invalidateIntrinsicContentSize()
        }
    }

    private func applyShadow(_ theme: HelmTheme, raised: Bool) {
        guard let layer else { return }
        let shadow = HelmCard.elevation(for: theme, level: raised ? .raised : .resting)
        layer.shadowColor = (shadow.shadowColor ?? .black).cgColor
        layer.shadowOpacity = Float(shadow.shadowColor?.alphaComponent ?? 0.1)
        layer.shadowRadius = shadow.shadowBlurRadius
        layer.shadowOffset = CGSize(width: shadow.shadowOffset.width, height: shadow.shadowOffset.height)
        layer.shadowPath = CGPath(roundedRect: bounds,
                                  cornerWidth: HelmMetrics.dModule,
                                  cornerHeight: HelmMetrics.dModule,
                                  transform: nil)
    }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        card.normalColor = surface
        card.hoverColor = surface
        card.layer?.backgroundColor = surface.cgColor
        card.layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor

        let pair = (content?.hue ?? .blue).pair(in: theme)
        HelmMotion.withoutImplicitAnimation {
            ribbon.colors = [pair.h1.cgColor, pair.h2.cgColor]
        }
        // C3: re-read the rest/bloom state here too. `configure` routes
        // through this method, so a card whose chip just became `.bad` picks
        // up its loud edge without waiting for a hover or a layout pass.
        applyRibbonGeometry(animated: false)

        titleLabel.font = HelmType.moduleTitle()
        titleLabel.textColor = ink
        subtitleLabel.font = HelmType.captionSmall()
        subtitleLabel.textColor = muted

        if let chip = content?.chip {
            ToolRowLayout.pill(text: chip.text, colorHex: chip.kind.hex(in: theme),
                               into: chipView, label: chipLabel, theme: theme)
            chipLabel.font = HelmType.chip()
        }

        for label in metricLabels { label.textColor = ink }
        for label in unitLabels { label.textColor = muted }
        for label in noteLabels { label.textColor = muted }
        skeletonList?.applyTheme(theme)
        for label in peekTextLabels { label.textColor = ink }
        for label in peekValueLabels { label.textColor = muted }
        for separator in peekSeparators {
            separator.layer?.backgroundColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.5).cgColor
        }
        for (dot, state) in peekDots { dot.layer?.backgroundColor = state.color(in: theme).cgColor }

        headerCaptionLabel.font = HelmType.captionSmall()
        headerCaptionLabel.textColor = muted

        // `.usageReport`. The colour rule that runs through all of it:
        // AGENTS.md's "a `HelmTint` hue is safe as a fill and is NOT
        // automatically safe as text". The bars are fills and take the state
        // hue raw; every *word* that carries a severity goes through
        // `HelmContrast.legibleTintedText` against the card's own surface,
        // which is what keeps the amber and green readable on the fifteen
        // light palettes rather than only on the dark ones.
        for label in usageSectionTitles { label.textColor = ink }
        for (label, state) in usageStatusLabels {
            label.font = HelmType.chip()
            label.textColor = usageSeverityInk(state, theme: theme, surface: surface,
                                               neutral: muted, tintOK: true)
        }
        for label in usageRowTitles { label.textColor = ink }
        for (label, state, isGap) in usageValues {
            // A stated gap is muted, a comfortable reading is plain page
            // ink, and only a genuine warning is tinted - so the one
            // coloured figure on the card is the one worth looking at.
            label.textColor = isGap
                ? muted
                : usageSeverityInk(state, theme: theme, surface: surface,
                                   neutral: ink, tintOK: false)
        }
        for label in usageCaptions { label.textColor = muted }
        for (bed, fill, state) in usageTracks {
            bed.layer?.backgroundColor = (theme.isDaylight
                ? HelmTheme.nsColor(theme.daylightTokens.inset)
                : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6)).cgColor
            fill.layer?.backgroundColor = state.color(in: theme).cgColor
        }
        for divider in usageDividers {
            divider.layer?.backgroundColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.5).cgColor
        }

        ringGauge?.applyTheme(theme, hue: content?.hue ?? .green)
        progressBar?.applyTheme(theme, hue: content?.hue ?? .amber)
        paragraphView?.applyTheme(theme)
        applyShadow(theme, raised: isHovering)
    }

    /// The one place `.usageReport` turns a `HelmModuleRowState` into **text**
    /// colour.
    ///
    /// `HelmModuleRowState.color(in:)` is a *fill* hue and AGENTS.md's colour
    /// rules forbid using one as text unmodified, so every severity word on
    /// this body resolves through `HelmContrast.legibleTintedText` against
    /// the card's own surface - which raises an amber that clears 4.5:1 on a
    /// light palette and leaves an already-legible hue alone on a dark one.
    /// `.idle` never resolves to a hue at all: it is "no severity", and
    /// `neutral` is what the caller wants said instead (page ink for a
    /// figure, muted for a status word).
    ///
    /// `tintOK` is the one place the two callers genuinely differ. A section's
    /// **status word** is a verdict, so "Comfortable" earns the green that
    /// makes it readable at a glance. A **figure** is a reading, and tinting
    /// every comfortable percentage green would leave the card with no
    /// colour left to mean "look at this" - so a figure stays page ink until
    /// it is genuinely a warning.
    private func usageSeverityInk(_ state: HelmModuleRowState,
                                  theme: HelmTheme,
                                  surface: NSColor,
                                  neutral: NSColor,
                                  tintOK: Bool) -> NSColor {
        switch state {
        case .idle: return neutral
        case .ok:
            guard tintOK else { return neutral }
            return HelmContrast.legibleTintedText(tintHex: theme.ansiHex[2], over: surface, theme: theme)
        case .warn:
            return HelmContrast.legibleTintedText(tintHex: theme.ansiHex[3], over: surface, theme: theme)
        case .bad:
            return HelmContrast.legibleTintedText(tintHex: theme.ansiHex[1], over: surface, theme: theme)
        }
    }

    @objc private func cardClicked() { onOpen?() }

    @objc private func headerActionTapped() { headerActionHandler?() }

    // MARK: Gesture arbitration

    /// Declines a card click that landed on a real control inside the card -
    /// today, `Content.headerAction`'s button.
    ///
    /// Two rules, because one of them is not enough and the gap is a real
    /// defect rather than a theoretical one.
    ///
    /// The **hit-test** rule is `SessionStripView`'s, and for its reasons:
    /// written against `NSControl` generally rather than "is this the action
    /// button", so a future control added to a card is covered the day it
    /// lands, and `action != nil` is what separates a view that does
    /// something of its own when clicked from a control class that happens to
    /// be drawing text (the card's own title and subtitle are `NSTextField`s,
    /// which are actionless `NSControl`s - declining for those would stop most
    /// of the card's surface from navigating).
    ///
    /// The **frame** rule covers what the first one cannot see: AppKit does
    /// not hit-test a *disabled* control, so while the header action is in its
    /// in-flight state the hit lands on the card behind it and the press
    /// navigates away - measured, not reasoned. A control that is visibly
    /// there and deliberately inert must swallow its own clicks.
    func gestureRecognizer(_ recognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let container = recognizer.view else { return true }
        let point = container.convert(event.locationInWindow, from: nil)
        if !actionButton.isHidden,
           actionButton.convert(actionButton.bounds, to: container).contains(point) {
            return false
        }
        // The hit-test half is `HelmGestureArbitration`'s - this file held one
        // of the two hand-rolled copies of it.
        return HelmGestureArbitration.shouldRecognize(recognizer, with: event)
    }

    // MARK: Probe / self-test surface

    struct Anatomy {
        let hasRibbon: Bool
        let ribbonHeight: CGFloat
        let ribbonStopCount: Int
        let cornerRadius: CGFloat
        let cardClipsToBounds: Bool
        let shadowHostClipsToBounds: Bool
        let borderWidth: CGFloat
        let hasTile: Bool
        /// Whether the tile is rendering a raster asset rather than an SF
        /// Symbol glyph. `hasTile` cannot say: a resolved symbol is an image
        /// too, so a check written against it passes for either.
        let tileHasArtwork: Bool
        let title: String
        let subtitle: String
        let chipText: String?
        let isCardActivatable: Bool
        let accessibilityLabel: String?
        let peekRowCount: Int
        /// `Content.headerCaption` as the header actually painted it - the
        /// string, and whether the label is in the hierarchy and not hidden.
        /// `nil` on a card that carries no caption, which is every card but
        /// the Claude usage one.
        let headerCaption: (text: String, isPainted: Bool)?
        /// The `.usageReport` body's sections, in render order: the title as
        /// drawn and the status word beside it.
        let usageSections: [(title: String, status: String?)]
        /// The `.usageReport` body's limit rows, in render order - the title,
        /// the figure and whether it is a stated gap. The spend section's own
        /// figure is not a limit row and is read through `metricTexts`.
        let usageRows: [(title: String, value: String, isGap: Bool)]
        /// Each `.usageReport` row's hover affordance, read back from the
        /// **real view** rather than from the model, for the reason
        /// `usageRowAffordances` gives: the string reaching the struct
        /// says nothing about whether anything was wired to it.
        let usageRowAffordances: [(toolTip: String?, help: String?)]
        /// Each painted caption on the `.usageReport` body, in render order -
        /// the string, whether it is really in the hierarchy, and whether it
        /// truncated at the width it actually got. A reset line rendering as
        /// `Resets Sun 21...` is a defect the string alone cannot show.
        let usageCaptions: [(text: String, isPainted: Bool, isTruncated: Bool)]
        /// Every `.usageReport` bar, as actually painted and laid out: the
        /// fill's own layer colour, how much of its bed it covers after a
        /// real layout pass, and the bed's own width. The last of the three
        /// is what proves the bars line up - a grid whose fill column
        /// absorbed nothing leaves every bed at its 40pt floor.
        let usageTrackFills: [(color: NSColor?, fraction: CGFloat, bedWidth: CGFloat)]
        /// Every `.usageReport` severity word's painted colour, in render
        /// order. The state-to-colour decision only becomes a colour when
        /// `applyTheme` writes it, so nothing derived from the model can see
        /// a word that was left page ink on a critical reading.
        let usageStatusColors: [NSColor?]
        /// Every `note`-styled line the body rendered, in order. Enough to
        /// tell a loading state from real content without exposing the body
        /// enum itself.
        let noteTexts: [String]
        /// How many lines each note label **actually renders**, at the width
        /// it actually has.
        ///
        /// Review #3's B7: the note label was `.byTruncatingTail`, which *is*
        /// the single-line mode - it lays the whole string out on one line and
        /// ellipsises it - so `maximumNumberOfLines` had nothing to count and
        /// a long description rendered one line inside a body sized for
        /// several. Nothing derived from `maximumNumberOfLines`, from
        /// `fittingSize` or from the body's height can see that; only the real
        /// line count can.
        let noteRenderedLineCounts: [Int]
        /// Every big-number / metric-styled line the body rendered.
        let metricTexts: [String]
        /// The height the card actually resolved to - `standardHeight` in
        /// every case, which is the whole point of the constant.
        let cardHeight: CGFloat
        /// The body area this card gives its content, after the ribbon,
        /// header and both body insets.
        let bodyAreaHeight: CGFloat
        /// What the body actually needs. Greater than `bodyAreaHeight` means
        /// this body kind has outgrown `standardHeight` and would be clipped.
        let bodyContentHeight: CGFloat
        /// Whether the body is D3's loading placeholder.
        ///
        /// Review #3's UI10: the warming state stopped being a chip plus a
        /// sentence, so `chipText`/`noteTexts` can no longer tell a loading
        /// card from a finished one. This can.
        let showsSkeleton: Bool
        /// The card's hover text - where UI10 moved the "what is being
        /// checked" sentence the body used to carry.
        let toolTip: String?
        /// `Content.headerAction`'s control as built, or `nil` when the
        /// content carried none.
        /// `announcedLabel` is read back from the control rather than from
        /// the content, so a suite sees what VoiceOver would actually get.
        let headerAction: (symbol: String?, tooltip: String?,
                           announcedLabel: String?, isEnabled: Bool)?
    }

    /// C2/C3: the inner `HoverHighlightView` (which owns the transform) and
    /// the ribbon's live geometry, so the rest/bloom state is read off the
    /// real layer rather than recomputed by the test.
    var debugCardView: HoverHighlightView { card }
    var debugRibbonGeometry: (height: CGFloat, opacity: Float, stopCount: Int) {
        (ribbon.frame.height, ribbon.opacity, ribbon.colors?.count ?? 0)
    }
    /// Drives hover without synthesizing a real mouse event.
    func debugSetHovering(_ hovering: Bool) {
        isHovering = hovering
        applyHoverState(animated: false)
    }

    /// Lay `label`'s own attributed string out in a container of its own real
    /// width and count the line fragments.
    ///
    /// Deliberately mirrors the label's `lineBreakMode` and
    /// `maximumNumberOfLines` rather than assuming either: the whole point is
    /// that a `.byTruncatingTail` label answers 1 here however many lines its
    /// maximum allows.
    private static func renderedLineCount(of label: NSTextField) -> Int {
        let width = label.bounds.width
        guard width > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: label.attributedStringValue)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = label.lineBreakMode
        container.maximumNumberOfLines = label.maximumNumberOfLines
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var lines = 0
        var glyph = 0
        while glyph < manager.numberOfGlyphs {
            var effective = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            guard effective.length > 0 else { break }
            glyph = NSMaxRange(effective)
            lines += 1
        }
        return lines
    }

    var anatomyForTests: Anatomy {
        Anatomy(hasRibbon: ribbon.superlayer != nil,
                ribbonHeight: Self.ribbonHeight,
                ribbonStopCount: ribbon.colors?.count ?? 0,
                cornerRadius: card.layer?.cornerRadius ?? 0,
                cardClipsToBounds: card.layer?.masksToBounds ?? false,
                shadowHostClipsToBounds: layer?.masksToBounds ?? true,
                borderWidth: card.layer?.borderWidth ?? 0,
                hasTile: tile.geometryForTests.hasImage,
                tileHasArtwork: tile.geometryForTests.hasArtwork,
                title: titleLabel.stringValue,
                subtitle: subtitleLabel.stringValue,
                chipText: chipView.isHidden ? nil : chipLabel.stringValue,
                isCardActivatable: card.isActivatable,
                accessibilityLabel: card.accessibilityLabelOverride,
                peekRowCount: peekTextLabels.count,
                headerCaption: headerCaptionLabel.isHidden ? nil
                    : (headerCaptionLabel.stringValue,
                       headerCaptionLabel.window != nil
                           && !headerCaptionLabel.isHiddenOrHasHiddenAncestor),
                usageSections: usageSectionTitles.enumerated().map { index, label in
                    (label.stringValue,
                     index < usageStatusLabels.count ? usageStatusLabels[index].label.stringValue : nil)
                },
                usageRows: zip(usageRowTitles, usageValues).map {
                    ($0.stringValue, $1.label.stringValue, $1.isGap)
                },
                usageRowAffordances: usageRowCells.map {
                    ($0.toolTip, $0.accessibilityHelp())
                },
                usageCaptions: usageCaptions.map { label in
                    (label.stringValue,
                     label.window != nil && !label.isHiddenOrHasHiddenAncestor,
                     label.fittingSize.width > label.frame.width + 0.5)
                },
                usageTrackFills: usageTracks.map { entry in
                    let bed = entry.bed.frame.width
                    return (entry.fill.layer?.backgroundColor.map { NSColor(cgColor: $0) } ?? nil,
                            bed > 0 ? entry.fill.frame.width / bed : 0,
                            bed)
                },
                usageStatusColors: usageStatusLabels.map { $0.label.textColor },
                noteTexts: noteLabels.map(\.stringValue),
                noteRenderedLineCounts: noteLabels.map(Self.renderedLineCount(of:)),
                metricTexts: metricLabels.map(\.stringValue),
                cardHeight: frame.height,
                bodyAreaHeight: bodyContainer.frame.height,
                bodyContentHeight: bodyViews.first?.fittingSize.height ?? 0,
                showsSkeleton: skeletonList != nil,
                toolTip: toolTip,
                headerAction: actionButton.isHidden ? nil
                    : (actionButton.symbolName, actionButton.toolTip,
                       actionButton.accessibilityLabel(), actionButton.isEnabled))
    }

    /// Fires the card's real click path, exactly as a mouse click or a
    /// VoiceOver press would.
    @discardableResult
    func debugActivate() -> Bool { card.performPrimaryAction() }

    /// Fires `Content.headerAction`'s control through its real target/action
    /// path, exactly as a click would. `false` when there is no such control
    /// or it is disabled, so a suite cannot assert against a press that never
    /// happened.
    @discardableResult
    func debugActivateHeaderAction() -> Bool {
        guard !actionButton.isHidden, actionButton.isEnabled else { return false }
        actionButton.performClick(nil)
        return true
    }

    /// Whether the card's own click recognizer would decline a click landing
    /// at this point in the card's coordinate space - i.e. whether the header
    /// action is genuinely arbitrated away from `onOpen`.
    func debugCardClickWouldBeDeclined(at pointInCard: NSPoint) -> Bool {
        guard let window = card.window,
              let recognizer = card.gestureRecognizers.first else { return false }
        let inWindow = card.convert(pointInCard, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        return !gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: event)
    }

    /// Where the header action's control actually landed, in the card's own
    /// coordinate space - so a suite can aim the check above at the real
    /// button rather than at a guessed rectangle.
    var debugHeaderActionFrameInCard: NSRect? {
        actionButton.isHidden ? nil : actionButton.convert(actionButton.bounds, to: card)
    }
}

// MARK: - Priorities

/// The one place this migration's constraint priorities are named.
///
/// AGENTS.md gotcha (13), restated because Phase 2 introduces a *lot* of new
/// content chained up to `bodyContainer`: a window only holds its own size at
/// `NSLayoutPriorityWindowSizeStayPut` (500), so **any** content constraint
/// above 500 is a potential window-size cap. Everything the bar and the
/// canvas add that could otherwise set a width floor uses `contentTie`.
enum HelmDaylightPriority {
    /// Just under 500. High enough to beat a stack's own defaults, low enough
    /// that the window's own size always wins.
    static let contentTie = NSLayoutConstraint.Priority(499)

    /// One above `.defaultLow`, for a **content hugging** priority that only
    /// needs to break a tie between sibling columns.
    ///
    /// **Why not `contentTie`, which is the obvious choice** - and this cost
    /// a real round of measurement in
    /// `fm/grand-line-claude-usage-card-redesign`. A content hugging
    /// priority is a width *ceiling*, and a card's body is tied to the card
    /// by a required equality, so a label's "never wider than my text"
    /// travels straight up to the card's own width. At `.required` a span-2
    /// Claude card asked for 526pt resolved to **227pt**. At `contentTie` it
    /// resolved to **265pt** - better and still wrong, because the width
    /// tying the card to its column is *itself* at 499, and AGENTS.md gotcha
    /// (13) already records what two constraints at 499 do: they tie, and
    /// Auto Layout breaks the tie on its own.
    ///
    /// 251 cannot tie with anything this migration declares, and it is still
    /// above every stack's own 250 default - which is all a hug between
    /// columns ever needed to beat.
    static let columnHug = NSLayoutConstraint.Priority(251)
}

// MARK: - Gauges (§6.8)

/// A 66pt ring: an `inset` track and a hue-coloured value arc, starting at 12
/// o'clock and running clockwise, with a rounded-numeral centre label.
///
/// `CAShapeLayer` arcs rather than a conic gradient - §6.8 says so explicitly,
/// and a stroked path is both cheaper and exactly what the design shows.
final class HelmRingGauge: NSView {
    static let side: CGFloat = 66
    static let lineWidth: CGFloat = 7

    private let track = CAShapeLayer()
    private let value = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var fraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        for shape in [track, value] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        label.font = HelmType.rounded(HelmType.scaled(15), .heavy)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(value current: Int, total: Int) {
        fraction = total > 0 ? min(1, max(0, Double(current) / Double(total))) : 0
        label.stringValue = total > 0 ? "\(current)/\(total)" : "\u{2014}"
        needsLayout = true
    }

    /// F7's variant: the caller already knows both the arc and the words.
    ///
    /// A countdown is not an `N/M` count - the arc is "how much of the
    /// session has been served" while the label reads "how much is left", so
    /// the two genuinely come from different numbers and `configure(value:
    /// total:)` cannot express it. The label is also mono here, because a
    /// proportional `17:24` shifts sideways on every tick.
    func configure(fraction: Double, text: String, monospaced: Bool = false) {
        self.fraction = min(1, max(0, fraction))
        label.stringValue = text
        self.monospacedLabel = monospaced
        applyLabelFont()
        needsLayout = true
    }

    /// Set by `configure(fraction:text:monospaced:)`; re-read by
    /// `applyTheme`, which otherwise resets the font on every repaint.
    private var monospacedLabel = false

    /// The one place the centre label's font is chosen, so a theme change
    /// cannot silently drop back to the proportional face.
    private func applyLabelFont() {
        label.font = monospacedLabel
            ? .monospacedDigitSystemFont(ofSize: HelmType.scaled(15), weight: .heavy)
            : HelmType.rounded(HelmType.scaled(15), .heavy)
    }

    /// F7: the arc's own hue, overriding the `hue` `applyTheme` is handed.
    ///
    /// The ring is drawn inside a panel that already carries the focus
    /// feature's tint, and a `HelmDomainHue` cannot express a `HelmTint`.
    /// `nil` (the default) leaves every existing call site painting exactly
    /// what it always did.
    var valueColorOverride: NSColor? {
        didSet { if valueColorOverride != oldValue { value.strokeColor = valueColorOverride?.cgColor ?? value.strokeColor } }
    }

    override func layout() {
        super.layout()
        let inset = Self.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(rect.width, rect.height) / 2
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let full = CGMutablePath()
        full.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        track.path = full
        track.frame = bounds

        // 12 o'clock is +pi/2 in AppKit's unflipped space; clockwise on screen
        // means decreasing angle, which is `clockwise: true` here.
        let start = CGFloat.pi / 2
        let arc = CGMutablePath()
        if fraction > 0 {
            arc.addArc(center: centre, radius: radius,
                       startAngle: start,
                       endAngle: start - CGFloat(fraction) * .pi * 2,
                       clockwise: true)
        }
        value.path = arc
        value.frame = bounds
    }

    func applyTheme(_ theme: HelmTheme, hue: HelmDomainHue) {
        let trackColor = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6)
        track.strokeColor = trackColor.cgColor
        value.strokeColor = (valueColorOverride ?? hue.baseColor(in: theme)).cgColor
        applyLabelFont()
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
    }

    // MARK: Probe / self-test surface

    var fractionForTests: Double { fraction }
    var centreLabelForTests: String { label.stringValue }
}

/// §6.8's capsule progress bar: an `inset` track with a hue-gradient fill.
final class HelmProgressBar: NSView {
    static let height: CGFloat = 8

    /// G4: the width an inline "something is running" bar takes when it stands
    /// in for a spinner beside a label.
    ///
    /// A spinner is square and a bar is not, so a migrated site needs *a*
    /// width - and one shared value is what stops fifteen call sites each
    /// picking their own. Narrow on purpose: this sits inside a footer row or
    /// a status column, where a full-width track would read as a determinate
    /// download rather than as activity.
    static let inlineWidth: CGFloat = 54

    /// How long one pass of the indeterminate segment takes, end to end.
    static let indeterminateCycle: TimeInterval = 1.1
    /// How much of the track the moving segment covers.
    private static let segmentFraction: CGFloat = 0.36

    private let fill = CAGradientLayer()
    private var fraction: Double = 0
    private var indeterminate = false
    private var lastTheme: HelmTheme?
    private var lastHue: HelmDomainHue = .blue
    /// Only an `inlineActivity` bar observes: the canvas-card bars are themed
    /// by the card that owns them (which also chooses their hue per render),
    /// and a second observation there would fight that. A spinner's
    /// replacement has no such owner - it is dropped into thirteen footer rows
    /// and status columns whose pages never expected to theme a progress
    /// control, because `NSProgressIndicator` drew itself.
    private var observation: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        fill.startPoint = HelmDomainHue.ribbonStart
        fill.endPoint = HelmDomainHue.ribbonEnd
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// A short, inline, indeterminate bar - G4's replacement for a stock
    /// spinner. Starts hidden; `isRunning` drives both the motion and, when
    /// `hidesWhenStopped`, the visibility.
    static func inlineActivity(hue: HelmDomainHue = .blue,
                               width: CGFloat = HelmProgressBar.inlineWidth) -> HelmProgressBar {
        let bar = HelmProgressBar()
        bar.indeterminate = true
        bar.lastHue = hue
        bar.widthAnchor.constraint(equalToConstant: width).isActive = true
        bar.setContentHuggingPriority(.required, for: .horizontal)
        bar.setContentCompressionResistancePriority(.required, for: .horizontal)
        bar.isHidden = true
        bar.setAccessibilityRole(.progressIndicator)
        bar.setAccessibilityLabel("Working")
        bar.observation = ThemeManager.shared.observe { [weak bar] theme in
            bar?.applyTheme(theme, hue: hue)
        }
        return bar
    }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
    }

    #if FM_SELFTESTS
    /// What the bar is really showing, read off its own state - a check that
    /// re-derives the fraction agrees with itself forever.
    var debugFraction: Double { fraction }
    #endif

    func configure(fraction: Double) {
        indeterminate = false
        self.fraction = min(1, max(0, fraction))
        refreshAnimation()
        needsLayout = true
    }

    /// G4: `NSProgressIndicator`'s own verb, so a migrated call site is a type
    /// change rather than a rewrite.
    var isRunning: Bool = false {
        didSet {
            guard isRunning != oldValue else { return }
            if hidesWhenStopped { isHidden = !isRunning }
            refreshAnimation()
        }
    }

    /// Mirrors `NSProgressIndicator.isDisplayedWhenStopped` inverted, which is
    /// what most of the migrated sites were already using.
    var hidesWhenStopped = true

    func startAnimation() { isRunning = true }
    func stopAnimation() { isRunning = false }

    override func layout() {
        super.layout()
        // `HelmMetrics.dCapsule` is a sentinel, never a real corner - clamp to
        // half the shorter side, which is what makes a capsule a capsule.
        layer?.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        if indeterminate {
            fill.frame = CGRect(x: 0, y: 0,
                                width: bounds.width * Self.segmentFraction,
                                height: bounds.height)
            refreshAnimation()
        } else {
            fill.frame = CGRect(x: 0, y: 0,
                                width: bounds.width * CGFloat(fraction), height: bounds.height)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // GL-13: an animation on an off-window view is a wake-up nobody can
        // see. The same discipline `HelmSkeletonRow`'s shimmer already keeps.
        refreshAnimation()
    }

    /// The sliding segment. Suppressed when there is nothing to say (not
    /// running, determinate, off-window) and under Reduce Motion - where the
    /// bar still *shows*, parked at the start of the track, so "something is
    /// happening" survives even though the motion does not.
    private func refreshAnimation() {
        let shouldRun = indeterminate && isRunning && window != nil
            && !isHidden && !HelmMotion.isReduced && bounds.width > 1
        guard shouldRun else {
            fill.removeAnimation(forKey: "indeterminate")
            return
        }
        let travel = bounds.width * (1 + Self.segmentFraction)
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = -bounds.width * Self.segmentFraction
        slide.toValue = travel - bounds.width * Self.segmentFraction
        slide.duration = Self.indeterminateCycle
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.removeAnimation(forKey: "indeterminate")
        fill.add(slide, forKey: "indeterminate")
    }

    func applyTheme(_ theme: HelmTheme, hue: HelmDomainHue) {
        lastTheme = theme
        lastHue = hue
        layer?.backgroundColor = (theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6)).cgColor
        let pair = hue.pair(in: theme)
        HelmMotion.withoutImplicitAnimation {
            fill.colors = [pair.h1.cgColor, pair.h2.cgColor]
        }
    }

    /// Re-theme with whatever hue this bar already had - what an inline
    /// activity bar's owner calls from its own theme pass, since the hue was
    /// chosen once at construction.
    func applyTheme(_ theme: HelmTheme) { applyTheme(theme, hue: lastHue) }

    var fractionForTests: Double { fraction }
    #if FM_SELFTESTS
    var debugIsIndeterminate: Bool { indeterminate }
    var debugIsSliding: Bool { fill.animation(forKey: "indeterminate") != nil }
    #endif
}
