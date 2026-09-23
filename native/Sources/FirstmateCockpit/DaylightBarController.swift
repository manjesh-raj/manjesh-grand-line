// Manjesh Grand Line - native macOS app.
//
// `DaylightBarController` - the floating top bar (migration §5.2, §6.3).
//
// **What it replaces.** Both `IconRailController` (an 84pt full-height icon
// rail) and `TopBarController` (a 52pt destination-title strip) are gone;
// this one 50pt floating bar is the whole navigation chrome. That is §5.1's
// "what dies" list, and it is the single largest structural change in the
// Daylight migration.
//
// **What it deliberately does NOT do.** It owns no destination state, no
// store, and no notion of what a space *means*. It draws five pills, reports
// which one was clicked, and hosts the bell and avatar popovers that already
// existed. `HomeCanvasController` owns the selected space; `AppShellController`
// owns navigation. That split is what keeps §5.3's rule true - "no store,
// poller or registry knows spaces exist".
//
// **The material, and the gotcha it is careful not to be** (UI modernization
// audit B1, `data/grandline-ui-modernization-audit/report.md` §3B).
//
// This bar shipped with a flat opaque fill and a comment explaining why: the
// prototype's bar is blurred glass, AGENTS.md gotcha (8) is this codebase's
// single most-repeated bug class, and §6.3 concluded "a solid fill with a
// shadow reads 95% the same. The blur in the prototype is a web nicety."
//
// That reasoning holds for exactly the material it was about. Gotcha (8) is a
// finding about **`.behindWindow`** vibrancy on a full-size root: that mode
// composites against the *desktop*, so a bar built with it renders whatever
// is behind the window rather than the theme. `.withinWindow` is a different
// mode that composites against **this window's own content**, which is the
// correct behaviour for chrome floating over a page - and the audit's own §6
// constraint list keeps gotcha (8) intact by name while asking for this one.
//
// So: `materialView` is an `NSVisualEffectView(.withinWindow)` behind the
// bar's rounded mask, **on the Daylight family only**. The twelve legacy
// palettes keep the byte-for-byte opaque fill they have always had - B1 says
// so explicitly ("their surfaces are already near-black; translucency buys
// little and risks the documented tint bugs"), and it is also what keeps this
// out of the contrast suite's way on the twelve palettes whose chrome/page
// tokens are furthest apart.
//
// **What it composites against today, stated rather than implied.**
// `AppShellController` still starts `bodyContainer` at
// `reservedTopHeight`, so a page's content does not yet slide *under* this
// bar - the material blends against the page ground this controller's own
// root paints. On the Daylight family that ground (`paper`) and the bar's own
// fill (`card`) are near neighbours by design, which is what keeps the bar's
// text contrast where `HelmContrastSelfTest` already measured it while the
// material still does its own luminance/vibrancy work. Making content
// genuinely scroll beneath the bar means starting `bodyContainer` at the
// window's top edge and insetting ~24 destinations, which no finding in §3B
// asks for; the material is correct now and correct then.
//
// **Window-size safety (AGENTS.md gotcha (13)).** A window only holds its own
// size at priority 500, so any content constraint above that is a window-width
// cap. This bar spans the full window width, which makes it the single most
// dangerous new surface in this phase for that class of bug: every label in it
// gets `.defaultLow` compression resistance, the search pill is the designated
// first thing to yield, and the one place a real floor could appear (the pill
// row) is tied at `HelmDaylightPriority.contentTie` (499).
// `DaylightModuleSelfTest.checkBarDoesNotCapWindow` measures that against a
// real window rather than trusting the reasoning.
//
// **The bar is the window's top edge now, and it carries the drill
// navigation** (UI modernization audit A1/A2,
// `data/grandline-ui-modernization-audit/report.md` §3A):
//
//   - A1: the window is `.fullSizeContentView` with a transparent, titleless
//     titlebar, so this bar sits `topMargin` from the window's own top edge
//     rather than below a 32pt system strip. The traffic lights land *on*
//     the bar, so `leadingContentInset` reserves room for them - see
//     `WindowChromeFusion`, which owns every measured number behind that.
//   - A2: on a drill page the leading area swaps the logo+wordmark for
//     `HelmDrillHeader`'s back-chevron + tile + title, and the page's own
//     action cluster joins the trailing side, immediately before the search
//     pill. **The space pills hide while that is showing**, because they do
//     not fit: measured on a real bar, the pills alone take 454pt at 1440
//     and the gap between them and the search pill is only 143pt, so there
//     is nowhere near enough room for a ~94pt leading cluster plus a page's
//     actions. Hiding them is also what Finder/Settings/App Store do - the
//     toolbar shows the drilled context, and the back button is the way out.
//     They are arranged subviews of `pillRow`, so hiding them collapses that
//     stack to nothing (AGENTS.md gotcha (11)'s own `NSStackView`
//     exemption) rather than leaving 454pt of invisible demand behind.
//   - A3: `setScrollEdgeActive` deepens the bar's own elevation and border
//     once the showing page is scrolled - see that method for why a
//     *floating rounded* bar expresses "hairline + slight material" as
//     depth rather than as a full-width rule under it.

import AppKit

final class DaylightBarController: NSViewController {

    // §6.3's geometry, exactly.
    static let height: CGFloat = 50
    static let topMargin: CGFloat = 14
    static let sideMargin: CGFloat = 22
    /// The gap between the bar's bottom edge and the body area beneath it -
    /// §2.7's spec states 20 ("Drill page: ... top margin under the bar 20"),
    /// but a captain screenshot flagged that as reading like leftover empty
    /// space above the drill header's back button/icon/title row rather than
    /// an intentional gap, so this is a deliberate, live-feedback-driven
    /// override of that written value (`fm/grandline-drill-header-title-
    /// truncation-fix`) - matching this codebase's own established
    /// convention of a captain's visual correction outranking a written spec
    /// number (see e.g. the rail's own several `AGENTS.md`-recorded
    /// overrides). `HelmMetrics.s3` is this app's existing "generous but
    /// tight" spacing token, reused here rather than a new literal.
    static let contentGap: CGFloat = HelmMetrics.s3

    /// Everything the shell needs to reserve above the body container.
    static var reservedTopHeight: CGFloat { topMargin + height + contentGap }

    /// §6.3's own stated floor: "the bar needs roughly 700pt to lay out".
    ///
    /// **Measured, and it is aspirational rather than real** - on a live bar
    /// the pill row and the search pill already overlap at 800pt, before any
    /// of the audit's changes. A2 does not make that worse: a drill page
    /// *frees* room (the 454pt pill row collapses, and the ~94pt leading
    /// cluster plus a page's actions are well under that), so the narrowest
    /// layout is still the canvas's, exactly as it was. Left at 700 because
    /// nothing this change does moved it, and re-deriving it is its own
    /// task - see `DaylightModuleSelfTest.checkBarDoesNotCapWindow`, which
    /// asserts the thing that actually matters: the bar never caps the
    /// window, at any width.
    static let comfortableWidth: CGFloat = 700

    /// The bar's own inner padding, before the traffic lights are accounted
    /// for.
    static let contentInset: CGFloat = 12

    /// How far the leading content starts from the bar's own leading edge.
    ///
    /// A1 puts the traffic lights on the bar, so this reserves the cluster's
    /// measured width (`WindowChromeFusion.trafficLightClusterWidth`, in
    /// *window* coordinates) minus the bar's own side margin. Falls back to
    /// the plain inset in full screen, where AppKit hides the cluster.
    var leadingContentInset: CGFloat {
        WindowChromeFusion.leadingInset(for: view.window, sideMargin: Self.sideMargin, plain: Self.contentInset)
    }

    /// Where `WindowChromeFusion` should put the traffic lights: centred on
    /// the bar's own vertical centre, and inset from its leading edge by the
    /// same padding any other leading content gets - so they read as set
    /// into the bar rather than straddling it.
    static var trafficLightCenterY: CGFloat { topMargin + height / 2 }
    static var trafficLightLeadingX: CGFloat {
        WindowChromeFusion.trafficLightLeadingX(sideMargin: sideMargin, plain: contentInset)
    }

    // MARK: Callbacks (forward, never own)

    /// A space pill was picked. `AppShellController` turns this into
    /// "navigate to the canvas, then filter" - this controller does not know
    /// what a canvas is.
    var onSelectSpace: ((DaylightSpace) -> Void)?
    /// The search pill / its ⌘K badge - forwarded exactly as
    /// `TopBarController.onSearchTapped` was.
    var onSearchTapped: (() -> Void)?
    /// The avatar popover's two rows. Unchanged behaviour, moved off the
    /// rail's avatar onto this bar's.
    var onSelectSettings: (() -> Void)?
    var onLogoutRequested: (() -> Void)?

    /// The bell keeps its own store, adapters and dedup logic untouched -
    /// only its trigger location moved.
    let notificationCenter = NotificationCenterController()

    private let bar = NSView()
    /// B1: the `.withinWindow` material behind the bar's own rounded mask.
    ///
    /// Hidden outright on the twelve legacy palettes, so those keep the exact
    /// opaque fill they always had - see this file's header for why that split
    /// is the finding's own, not a hedge.
    private let materialView = NSVisualEffectView()
    /// B1: how much of the bar's own `chromeBackgroundHex` sits on top of the
    /// material on the Daylight family.
    ///
    /// Not a guess at "how glassy should it look" - it is the number that lets
    /// the material read while keeping the bar's text contrast inside the
    /// margin `HelmContrastSelfTest` already measured against a fully opaque
    /// `chromeBackgroundHex`. The material composites against the page ground
    /// (`paper`), and on this family `paper` and `card` are near neighbours, so
    /// the worst case for any label on this bar is a fill somewhere on the
    /// short segment between them. `checkBarMaterial` measures that rather
    /// than trusting it.
    static let daylightFillAlpha: CGFloat = 0.72
    private let logoTile = HelmGradientTile(size: .logo)
    private let wordmark = NSTextField(labelWithString: "Grand Line")
    /// A2: the drill page's back-chevron + tile + title, in the leading area
    /// the wordmark otherwise occupies. Both live in `leadingGroup`, and
    /// exactly one is visible - see `setDrillContext`.
    private let drillNav = HelmDrillHeader()
    /// A2: the drill page's own action cluster, on the trailing side.
    /// Caller-owned views, exactly as `HelmDrillHeader.setActions` took them
    /// before the merge.
    private let drillActions = NSStackView()
    /// `drillActions.trailing == searchPill.leading - gap`, where the gap is
    /// 0 while the cluster is empty so the canvas's own chain is byte-for-byte
    /// what it was before A2.
    private var drillActionsGap: NSLayoutConstraint!
    /// The leading content's own distance from the bar's leading edge -
    /// re-read on every layout pass, because the traffic-light reservation
    /// depends on whether the window is in full screen.
    private var leadingInsetConstraint: NSLayoutConstraint!
    private let searchPill = DaylightSearchPill()

    // MARK: F7 - the focus timer chip

    /// F7's running-timer chip, between the drill actions and the search
    /// pill. Wrapped in a stack for exactly the reason `drillActions` is:
    /// hiding an *arranged* subview takes its width out of layout, while
    /// hiding an ordinary `NSView` leaves every constraint it had behind
    /// (AGENTS.md gotcha (11)) - so a bar with no timer running has to be
    /// byte-for-byte the bar that existed before F7.
    private let focusChipHost = NSStackView()
    private let focusChip = FocusTimerChip()
    /// `focusChipHost.trailing == searchPill.leading + <this>`: zero while
    /// nothing is running, so the search pill sits exactly where it always
    /// did - the same shape `drillActionsGap` already uses.
    private var focusChipGap: NSLayoutConstraint!
    /// Set by `attachFocusTimer`. `nil` until the shell hands the bar the
    /// app's one `FocusTimerController`, which is also why the chip starts
    /// hidden and the bar needs no timer to lay itself out.
    private weak var focusTimer: FocusTimerController?
    private var focusTimerToken: UUID?
    private var focusPopover: NSPopover?

    /// B6: the seven quick-access shortcuts collapse into this one menu below
    /// `quickAccessCollapseWidth`. Built always, shown only when collapsed.
    private let quickAccessOverflowButton = DaylightBarIconButton(
        symbol: "ellipsis",
        tooltip: "More destinations",
        accessibilityLabel: "More destinations")

    /// The bar width below which the quick-access row gives way to
    /// `quickAccessOverflowButton` - review #3's B6.
    ///
    /// Seven icon squares cost 7 x (34 + `s2`) = 294pt of a bar that also has
    /// to carry the drill cluster, the search pill, Recents, the theme toggle,
    /// the bell and the avatar. They are `.required`, so below about this
    /// width they were keeping their full size while the page's own *name*
    /// truncated beside them - the finding's own "the title is the only
    /// compressible thing in the row". Collapsing them buys back 260pt, which
    /// is more than the title ever needed.
    ///
    /// 1300, the finding's own figure: above it every shortcut fits with the
    /// title intact at its natural width, which is the common case on the
    /// captain's own 1512pt window.
    static let quickAccessCollapseWidth: CGFloat = 1300

    /// Whether the shortcuts are currently collapsed. Tracked so
    /// `viewDidLayout` only rebuilds on a real crossing.
    private var quickAccessCollapsed = false

    private var rowToOverflowGap: NSLayoutConstraint!
    private var quickAccessOverflowWidth: NSLayoutConstraint!
    /// The light/dark quick-toggle, moved here from Console's own toolbar
    /// (`fm/grandline-daylight-theme-toggle-relocate`) - it flips the whole
    /// app's theme, not just one page's, so it belongs on the app-wide bar
    /// rather than a per-destination toolbar. Sits between the search pill
    /// and the bell, matching the captain's own reviewed layout.
    private let themeToggleButton = DaylightThemeToggleButton()
    /// Quick-access jumps to destinations the captain reaches often
    /// (`fm/grandline-sticky-code-preview-polish` for the first two,
    /// `fm/grandline-tasks-quick-access-icon` for Tasks,
    /// `fm/poneglyph-own-destination-and-strawhat-toolbar-shortcut` for the
    /// last two). Every one of them remains a full destination in its own
    /// space - this is a shortcut, not a relocation - and they sit
    /// immediately before the theme toggle, matching the captain's own
    /// reviewed order: search -> Recents -> Sticky Board -> Code Preview ->
    /// Tasks -> Straw Hat Pirates -> Poneglyph -> Console -> theme -> bell ->
    /// avatar.
    ///
    /// A new icon **appends** to the trailing end of this group rather than
    /// being slotted in by topic, which is the convention Sticky Board and
    /// Code Preview already set: the group reads in the order the captain
    /// asked for each shortcut, and adding one never moves an icon a captain
    /// has already built muscle memory for.
    /// The row itself, as a stack of buttons rebuilt from
    /// `QuickAccessConfiguration` rather than seven `private let`s with a
    /// hand-written constraint chain between them - review #3's UX1/UX2. See
    /// `QuickAccessConfiguration.swift`'s header for why the captain owning
    /// this list replaces the old "append, never slot in by topic" rule rather
    /// than merely relaxing it.
    ///
    /// AGENTS.md gotcha (12): the *stack*-level priority APIs are the ones
    /// that bite on a view with no intrinsic content size, so the row holds
    /// its width with `setHuggingPriority`/`setClippingResistancePriority`
    /// and never with the content-priority pair.
    private let quickAccessRow = NSStackView()
    /// The buttons currently in `quickAccessRow`, in visual order - rebuilt
    /// wholesale by `rebuildQuickAccessRow()`, never mutated in place.
    private var quickAccessRowButtons: [DaylightDestinationButton] = []
    /// The pinned list this bar last drew. Owned here only as a cache of what
    /// is on screen; `AppSettings.quickAccess` is the store of record and
    /// `setQuickAccess(_:)` is the one way in.
    private var quickAccess = QuickAccessConfiguration()
    /// The "Recents" dropdown (`fm/grandline-recents-navigation`) - a captain
    /// review of four back/forward-style approaches chose this one. It first
    /// shipped right after the space pills (never next to the logo the
    /// reviewed mockup originally showed it beside), then the captain
    /// corrected that placement a second time (`fm/grandline-recents-
    /// position-and-codepreview-theme`): sitting right after Engineering
    /// "doesn't make much sense" as a stray extra space pill, so it now sits
    /// on the *other* side of the search field, grouped with the Sticky
    /// Board/Code Preview quick-access icons - search -> Recents -> Sticky
    /// Board -> Code Preview -> theme -> bell -> avatar. The bar owns only
    /// the button and the popover chrome, never what a `RecentDestinations`
    /// is - see `RecentDestinationsPopover.swift`'s own header for the
    /// forward-don't-own wiring.
    let recentDestinations = RecentDestinationsController()
    /// F3: the ⌘⇧V clipboard history, sitting immediately after Recents.
    ///
    /// Placed by this bar's own stated convention for a control that is *not*
    /// a destination shortcut (the theme toggle, Recents): a fixed-size icon
    /// square with a plain required gap on both sides, which needs no
    /// window-cap protection of its own (gotcha 13) because its width is
    /// `DaylightBarIconButton.side` and never moves. It belongs beside Recents
    /// rather than in the quick-access row because it opens a panel rather
    /// than navigating anywhere.
    let clipboardHistory = ClipboardHistoryController()
    /// Forwarded, never owned - the bar has no idea what a destination *is*,
    /// exactly as it has no idea what a space means (`onSelectSpace`).
    var onSelectDestination: ((RailDestination) -> Void)?
    private let avatar = HoverTrackingButton()
    private let avatarGradient = CAGradientLayer()
    /// B5: a borderless `HelmBarPanel`, like the bell's and Recents' - see
    /// that type's header. Built lazily because it hosts a view controller and
    /// this one is constructed before `loadView`.
    private var avatarPanel: HelmBarPanel?

    private var pills: [SpacePill] = []
    private var selectedSpace: DaylightSpace = .overview
    private var themeToken: ThemeObservation?
    /// Built in `loadView`; held so `setDrillContext` can swap which of its
    /// two arranged subviews is showing.
    private var leadingGroup: NSStackView!
    /// Held so the space pills can be collapsed on a drill page.
    private var pillRow: NSStackView!
    /// A3's state, so a theme change re-applies the right elevation.
    private var scrollEdgeActive = false

    /// A2: the drill cluster's back chevron was clicked. Forwarded, never
    /// owned - the bar has no idea what "home" is, exactly as it has no idea
    /// what a space means (`onSelectSpace`).
    var onDrillBack: (() -> Void)?

    private struct SpacePill {
        let space: DaylightSpace
        let container: HoverHighlightView
        let label: NSTextField
    }

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: Self.height + Self.topMargin))
        root.wantsLayer = true
        view = root

        bar.wantsLayer = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        // The shadow host must not clip (§2.5). The bar has no children that
        // need clipping - every pill rounds its own layer - so unlike
        // `HelmModuleCard` this needs no second layer.
        bar.layer?.masksToBounds = false
        bar.layer?.cornerRadius = HelmMetrics.dBar
        bar.layer?.borderWidth = 1
        root.addSubview(bar)

        // B1. Added first, so it sits behind every control the bar carries.
        // `bar` itself must not clip (it is the shadow host), so the material
        // carries its own rounded mask - the same two-layer arrangement
        // `HelmComposerCard`/`HelmModuleCard` already use for "a shadow
        // outside, a clip inside".
        materialView.blendingMode = .withinWindow
        // `.headerView`, where B1's own text says ".hudWindow-ish". That
        // "-ish" is doing real work: `.hudWindow` is the material for HUD
        // *panels*, which macOS renders dark by convention, and this bar is
        // light on the flagship theme. `.headerView` is the documented
        // semantic for a bar across the top of a window - which is exactly
        // what this is - and resolves light in `.aqua` and dark in
        // `.darkAqua`, matching the family split the bar already forces
        // through `followHelmTheme`.
        //
        // Stated because it could not be checked by eye:
        // `NSVisualEffectView` is composited by the window server, so
        // `cacheDisplay` (this repo's screenshot substitute) captures a flat
        // placeholder for it, and launching a real build is forbidden here -
        // the captain's own instance shares this bundle identity. So the
        // material is chosen by semantics and the *risk* is bounded by
        // measurement instead: see `daylightFillAlpha`, and
        // `BarNavigationModernizationSelfTest`'s contrast check, which holds
        // for any blend of `card` and `paper` this material can produce.
        materialView.material = .headerView
        // `.active`, not the default `.followsWindowActiveState`: this is
        // window chrome, and chrome that goes flat the moment the captain
        // clicks another app reads as broken rather than as inactive.
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = HelmMetrics.dBar
        materialView.layer?.masksToBounds = true
        materialView.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(materialView)
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: bar.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])

        logoTile.configure(symbol: "sailboat.fill", hue: .blue)
        wordmark.font = HelmType.rounded(HelmType.scaled(14.5), .heavy)
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        wordmark.lineBreakMode = .byTruncatingTail
        wordmark.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let logoRow = NSStackView(views: [logoTile, wordmark])
        logoRow.orientation = .horizontal
        logoRow.alignment = .centerY
        logoRow.spacing = HelmMetrics.s2
        logoRow.distribution = .fill
        logoRow.translatesAutoresizingMaskIntoConstraints = false
        logoRow.setHuggingPriority(.required, for: .horizontal)

        // A2: the wordmark and the drill cluster are two arranged subviews of
        // one stack, so whichever is hidden leaves layout entirely rather
        // than holding its width (AGENTS.md gotcha (11)'s `NSStackView`
        // exemption) - which is what lets one leading anchor serve both.
        drillNav.onBack = { [weak self] in self?.onDrillBack?() }
        drillNav.isHidden = true
        let leadingGroup = NSStackView(views: [logoRow, drillNav])
        leadingGroup.orientation = .horizontal
        leadingGroup.alignment = .centerY
        leadingGroup.spacing = 0
        leadingGroup.distribution = .fill
        leadingGroup.translatesAutoresizingMaskIntoConstraints = false
        leadingGroup.setHuggingPriority(.required, for: .horizontal)
        self.leadingGroup = leadingGroup

        drillActions.orientation = .horizontal
        drillActions.alignment = .centerY
        drillActions.spacing = HelmMetrics.s2
        drillActions.distribution = .fill
        drillActions.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12): the *stack*-level APIs are the ones that
        // bite on a view with no intrinsic content size.
        drillActions.setHuggingPriority(.required, for: .horizontal)
        drillActions.setClippingResistancePriority(.required, for: .horizontal)

        let pillRow = buildPillRow()
        self.pillRow = pillRow

        searchPill.translatesAutoresizingMaskIntoConstraints = false
        searchPill.onClick = { [weak self] in self?.onSearchTapped?() }
        // §6.3: "give the search pill `.defaultLow` compression so it yields
        // before pills". This is the one control on the bar that is allowed
        // to shrink, and saying so here is what keeps a narrow window from
        // truncating the navigation instead.
        searchPill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchPill.setContentHuggingPriority(.defaultLow, for: .horizontal)

        themeToggleButton.target = self
        themeToggleButton.action = #selector(themeToggleClicked)
        quickAccessOverflowButton.target = self
        quickAccessOverflowButton.action = #selector(quickAccessOverflowClicked)
        quickAccessOverflowButton.isHidden = true

        quickAccessRow.orientation = .horizontal
        quickAccessRow.spacing = HelmMetrics.s2
        quickAccessRow.distribution = .fill
        quickAccessRow.translatesAutoresizingMaskIntoConstraints = false
        quickAccessRow.setHuggingPriority(.required, for: .horizontal)
        quickAccessRow.setClippingResistancePriority(.required, for: .horizontal)

        focusChipHost.orientation = .horizontal
        focusChipHost.alignment = .centerY
        focusChipHost.spacing = 0
        focusChipHost.translatesAutoresizingMaskIntoConstraints = false
        focusChipHost.setHuggingPriority(.required, for: .horizontal)
        focusChipHost.setClippingResistancePriority(.required, for: .horizontal)
        focusChipHost.addArrangedSubview(focusChip)
        focusChip.isHidden = true
        // `HoverHighlightView` reads its primary action off a real click
        // recognizer (`performPrimaryAction`, which is also what makes the
        // chip keyboard-activatable under GL-16), so the click is wired
        // that way rather than as a button target.
        focusChip.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(focusChipClicked)))
        registerFocusPopoverWithLockGate()

        buildAvatar()

        bar.addSubview(leadingGroup)
        bar.addSubview(pillRow)
        bar.addSubview(drillActions)
        bar.addSubview(focusChipHost)
        bar.addSubview(searchPill)
        bar.addSubview(recentDestinations.button)
        bar.addSubview(clipboardHistory.button)
        bar.addSubview(quickAccessRow)
        bar.addSubview(quickAccessOverflowButton)
        bar.addSubview(themeToggleButton)
        bar.addSubview(notificationCenter.bell)
        bar.addSubview(avatar)

        let inset = Self.contentInset

        // The horizontal chain is deliberately *not* one stack: the pills sit
        // just after the logo (leading-anchored), the trailing cluster is
        // trailing-anchored, and the gap between them is an inequality - so a
        // narrow window compresses the gap to nothing before anything is asked
        // to truncate, and nothing here can push the window wider.
        //
        // The Recents button now sits *inside* the trailing cluster - right
        // after the search pill, right before the Sticky Board icon - rather
        // than between the pills and the search pill: a fixed-size control
        // with a plain required constant gap on both sides (it needs no
        // window-cap protection of its own, since its own width is fixed at
        // `DaylightBarIconButton.side`, matching the sticky-board/code-preview
        // icons it now sits beside). The one compressible joint is the gap
        // between the pills and the search pill, unchanged in kind - still
        // exactly one squeeze point in the whole chain, per AGENTS.md gotcha
        // (13).
        //
        // A2 inserts the drill action cluster at the *leading* end of that
        // trailing chain, so the one compressible joint is now measured to
        // `drillActions` rather than to the search pill. With no actions the
        // stack has zero width and `drillActionsGap` is 0, which puts the
        // search pill exactly where it has always been.
        let pillsToSearch = drillActions.leadingAnchor.constraint(
            greaterThanOrEqualTo: pillRow.trailingAnchor, constant: HelmMetrics.s3)
        pillsToSearch.priority = HelmDaylightPriority.contentTie
        // F7 slots its chip between the two. With nothing running the host
        // stack has zero width and `focusChipGap` is 0, so `drillActions`
        // still ends exactly at the search pill's leading edge.
        drillActionsGap = drillActions.trailingAnchor.constraint(
            equalTo: focusChipHost.leadingAnchor, constant: 0)
        focusChipGap = focusChipHost.trailingAnchor.constraint(
            equalTo: searchPill.leadingAnchor, constant: 0)
        // Starts at the reserved value, not the plain one: `viewDidLayout`
        // is what adjusts it, and the first pass can run before the view is
        // in a window - reserving is the safe direction there (too much room
        // is invisible; too little puts content under the traffic lights).
        leadingInsetConstraint = leadingGroup.leadingAnchor.constraint(
            equalTo: bar.leadingAnchor,
            constant: WindowChromeFusion.reservedLeadingInset(plain: inset))

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.sideMargin),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.sideMargin),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.topMargin),
            bar.heightAnchor.constraint(equalToConstant: Self.height),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            leadingInsetConstraint,
            leadingGroup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            pillRow.leadingAnchor.constraint(equalTo: leadingGroup.trailingAnchor, constant: HelmMetrics.s5),
            pillRow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            pillsToSearch,
            drillActionsGap,
            drillActions.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            focusChipGap,
            focusChipHost.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            searchPill.trailingAnchor.constraint(equalTo: recentDestinations.button.leadingAnchor, constant: -HelmMetrics.s2),
            searchPill.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            recentDestinations.button.trailingAnchor.constraint(equalTo: clipboardHistory.button.leadingAnchor, constant: -HelmMetrics.s2),
            recentDestinations.button.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            clipboardHistory.button.trailingAnchor.constraint(equalTo: quickAccessRow.leadingAnchor, constant: -HelmMetrics.s2),
            clipboardHistory.button.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            recentDestinations.button.widthAnchor.constraint(equalToConstant: DaylightBarIconButton.side),
            recentDestinations.button.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),

            quickAccessRow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            quickAccessRow.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),

            quickAccessOverflowButton.trailingAnchor.constraint(equalTo: themeToggleButton.leadingAnchor, constant: -HelmMetrics.s2),
            quickAccessOverflowButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            quickAccessOverflowButton.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),

            themeToggleButton.trailingAnchor.constraint(equalTo: notificationCenter.bell.leadingAnchor, constant: -HelmMetrics.s2),
            themeToggleButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            themeToggleButton.widthAnchor.constraint(equalToConstant: DaylightThemeToggleButton.side),
            themeToggleButton.heightAnchor.constraint(equalToConstant: DaylightThemeToggleButton.side),

            notificationCenter.bell.trailingAnchor.constraint(equalTo: avatar.leadingAnchor, constant: -HelmMetrics.s2),
            notificationCenter.bell.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            notificationCenter.bell.widthAnchor.constraint(equalToConstant: NotificationBellButton.controlWidth),
            notificationCenter.bell.heightAnchor.constraint(equalToConstant: NotificationBellButton.iconSize),

            avatar.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -inset),
            avatar.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 34),
            avatar.heightAnchor.constraint(equalToConstant: 34),
        ])

        // B6 (and now UX2's cap): the row's gap in front of the overflow
        // button closes with it, and the overflow button's own width goes to
        // zero when there is nothing for it to show.
        //
        // **`isHidden` alone reclaims nothing** - an ordinary hidden `NSView`
        // keeps every constraint it had, gotcha (11) - which is why the width
        // is driven rather than only the visibility. The row itself is an
        // `NSStackView`, so its *arranged* subviews genuinely do leave layout
        // when hidden (the one place that distinction works in our favour),
        // and the row collapses to zero width on its own once every button in
        // it is hidden.
        rowToOverflowGap = quickAccessRow.trailingAnchor.constraint(
            equalTo: quickAccessOverflowButton.leadingAnchor, constant: -HelmMetrics.s2)
        rowToOverflowGap.isActive = true
        quickAccessOverflowWidth = quickAccessOverflowButton.widthAnchor.constraint(equalToConstant: 0)
        quickAccessOverflowWidth.isActive = true
        setQuickAccess(AppSettings.shared.quickAccess)

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // `ThemeManager.observe` fires synchronously at registration, which
        // for this controller is before `avatarGradient` has a frame - the
        // `refreshTheme()` convention (AGENTS.md's ThemeManager checklist,
        // item 8) is what makes the first paint correct anyway.
        applyTheme(ThemeManager.shared.theme)
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let focusTimerToken { focusTimer?.unobserve(focusTimerToken) }
    }

    // MARK: F7 - the focus timer chip

    /// Hand the bar the app's one `FocusTimerController`.
    ///
    /// Called by `AppShellController` after both exist. The bar forwards and
    /// never owns (this file's own convention): it observes the timer to
    /// know when to repaint, and every button in the popover acts on the
    /// controller directly.
    /// GL-09 / §5.1(b): a popover left open when the app lock fires stays
    /// readable and interactive *above* the overlay, so every popover in
    /// this app registers itself to be closed on the way in. This one names
    /// the captain's current task, which is exactly the kind of thing the
    /// lock exists to hide.
    private func registerFocusPopoverWithLockGate() {
        AppLockGate.shared.registerLockDismissiblePopover { [weak self] in self?.focusPopover }
    }

    func attachFocusTimer(_ timer: FocusTimerController) {
        if let focusTimerToken, let previous = focusTimer { previous.unobserve(focusTimerToken) }
        focusTimer = timer
        focusTimerToken = timer.observe { [weak self] in self?.renderFocusChip() }
        renderFocusChip()
    }

    /// Repaint the chip from the live session, and take it off the bar
    /// entirely when nothing is running.
    private func renderFocusChip() {
        guard let session = focusTimer?.session else {
            focusChip.isHidden = true
            focusChipGap.constant = 0
            // The popover is about a session that no longer exists.
            focusPopover?.performClose(nil)
            focusPopover = nil
            return
        }
        focusChip.isHidden = false
        focusChipGap.constant = -HelmMetrics.s3
        // Read through the controller, never off a `Date()` of this view's
        // own - see `FocusTimerController.fraction` for why.
        focusChip.configure(fraction: focusTimer?.fraction ?? 0,
                            countdown: focusTimer?.countdownText ?? "0:00",
                            title: session.taskTitle,
                            paused: focusTimer?.isPaused ?? false)
        focusChip.applyTheme(ThemeManager.shared.theme)
    }

    @objc private func focusChipClicked() {
        guard let focusTimer, focusTimer.isRunning else { return }
        if let focusPopover, focusPopover.isShown {
            focusPopover.performClose(nil)
            self.focusPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        // The popover's own chrome resolves system semantic colours, so it
        // needs the theme's light/dark mode forced on it the same way every
        // other themed surface in this app does (ThemeManager's checklist
        // item 2) - otherwise a Dusk app pops a white panel under System
        // Light.
        popover.appearance = NSAppearance(
            named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        popover.contentViewController = FocusTimerPanelController(timer: focusTimer)
        popover.show(relativeTo: focusChip.bounds, of: focusChip, preferredEdge: .maxY)
        focusPopover = popover
    }

    #if FM_SELFTESTS
    /// F7's probe surface: the chip itself, so a windowed suite can read its
    /// rendered text and its real `isHidden`/frame rather than re-deriving
    /// them from the timer it is supposed to be showing.
    var debugFocusChip: FocusTimerChip { focusChip }
    var debugFocusChipIsVisible: Bool { !focusChip.isHidden }
    /// The chip's *host stack*, which is what actually gives (and gives
    /// back) width on the bar - a hidden arranged subview keeps its own
    /// stale frame, so the chip's own width proves nothing.
    var debugFocusChipHostWidth: CGFloat { focusChipHost.frame.width }
    func debugClickFocusChip() { focusChipClicked() }
    var debugFocusPopoverIsShown: Bool { focusPopover?.isShown ?? false }
    var debugFocusPanel: FocusTimerPanelController? {
        focusPopover?.contentViewController as? FocusTimerPanelController
    }
    #endif

    // MARK: A2 - the drill navigation

    /// Point the bar's leading area at a drill page, or hand it `nil` for the
    /// canvas (where the wordmark comes back and the space pills return).
    ///
    /// The pills hide on a drill page because they do not fit beside a
    /// leading cluster and an action cluster - see this file's header for the
    /// measurement. They are arranged subviews, so hiding them genuinely
    /// removes their 454pt from layout.
    func setDrillContext(_ context: DrillContext?) {
        // The shell adds `bar.view` to its root long before it ever
        // navigates, so this is defence in depth rather than a live path -
        // but the leading group and the pill row are implicitly unwrapped,
        // and a crash in the window's own chrome is not a good way to find
        // out that some future caller reordered that.
        guard isViewLoaded else { return }
        guard let context else {
            drillNav.isHidden = true
            logoRow?.isHidden = false
            setPillsHidden(false)
            setDrillActions([])
            return
        }
        drillNav.configure(title: context.title, subtitle: context.subtitle,
                           symbol: context.symbol, hue: context.hue, artwork: context.artwork)
        drillNav.isHidden = false
        logoRow?.isHidden = true
        setPillsHidden(true)
    }

    /// Hand the bar this page's own actions, or `[]` to clear them.
    ///
    /// The views are **caller-owned**, exactly as `HelmDrillHeader.setActions`
    /// took them before A2: a page keeps its own Refresh button, its own sync
    /// pill, and the state on them that it already manages.
    func setDrillActions(_ views: [NSView]) {
        guard isViewLoaded else { return }
        drillActions.arrangedSubviews.forEach {
            drillActions.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for view in views {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            drillActions.addArrangedSubview(view)
        }
        drillActions.isHidden = views.isEmpty
        // Zero gap while empty, so the canvas's chain is exactly what it was
        // before the cluster existed.
        drillActionsGap.constant = views.isEmpty ? 0 : -HelmMetrics.s3
    }

    /// The five space pills are arranged subviews, so hiding each one takes
    /// its width out of `pillRow` entirely - hiding the *stack* would not
    /// (an ordinary hidden `NSView` keeps its constraints).
    private func setPillsHidden(_ hidden: Bool) {
        for pill in pills { pill.container.isHidden = hidden }
    }

    /// The leading area's logo row, for the swap in `setDrillContext`.
    private var logoRow: NSView? { leadingGroup?.arrangedSubviews.first }

    // MARK: A3 - the scroll edge

    /// The showing page has scrolled off its own top edge (or come back to
    /// it). Deepens the bar's elevation and firms up its border, so it reads
    /// as chrome floating over moving content.
    ///
    /// **Why depth rather than a rule under the bar.** A3 asks for "a
    /// hairline + slight material once scrolled". That recipe assumes a
    /// full-width strip whose bottom edge is the chrome/content boundary;
    /// this bar is a rounded, inset, *floating* card with a 12pt gap beneath
    /// it, so a full-width hairline under it would draw a line attached to
    /// nothing. The same two signals expressed for this shape are the border
    /// it already has (the hairline) going to full strength, and
    /// `HelmCard.elevation`'s own second level (the material) - §2.5 defines
    /// exactly two, and this is what the raised one is for. That also keeps
    /// the per-theme split the audit asks for without a special case: the
    /// elevation helper already resolves Daylight/Dusk separately from the
    /// twelve legacy palettes.
    func setScrollEdgeActive(_ active: Bool) {
        guard isViewLoaded, active != scrollEdgeActive else { return }
        scrollEdgeActive = active
        applyScrollEdge(ThemeManager.shared.theme, animated: true)
    }

    private func applyScrollEdge(_ theme: HelmTheme, animated: Bool) {
        guard let layer = bar.layer else { return }
        let shadow = HelmCard.elevation(for: theme, level: scrollEdgeActive ? .raised : .resting)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        // The per-family split the audit asks for, and it falls out of the
        // palettes rather than being special-cased: Daylight/Dusk already
        // draw this border at full strength (their card and page grounds can
        // be the same colour, so the border is the only thing separating
        // them), which leaves them no headroom - there, depth alone carries
        // the signal. The twelve legacy palettes rest at 0.6, so on those the
        // hairline firms up as well.
        let restingAlpha: CGFloat = theme.isDaylight ? 1.0 : 0.6
        let borderColor = line.withAlphaComponent(scrollEdgeActive ? 1.0 : restingAlpha).cgColor
        let opacity = Float(shadow.shadowColor?.alphaComponent ?? 0.1)

        let apply = {
            layer.shadowColor = (shadow.shadowColor ?? .black).cgColor
            layer.shadowOpacity = opacity
            layer.shadowRadius = shadow.shadowBlurRadius
            layer.shadowOffset = CGSize(width: shadow.shadowOffset.width, height: shadow.shadowOffset.height)
            layer.borderColor = borderColor
        }
        // A state change is worth easing; a theme change is not (it is
        // already a whole-app repaint), and Reduce Motion wants the end
        // state immediately either way.
        guard animated, !HelmMotion.isReduced else {
            HelmMotion.withoutImplicitAnimation(apply)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            apply()
        }
    }

    /// Everything the shell knows about the page the bar is naming.
    struct DrillContext {
        let title: String
        let subtitle: String
        let symbol: String
        let hue: HelmDomainHue
        let artwork: NSImage?
    }

    /// B4: the narrowest a space pill's label may be squeezed. Enough for a
    /// truncated word plus its ellipsis - the point is that every pill stays
    /// readable *as a pill*, not that any one of them keeps its full title.
    static let pillLabelMinWidth: CGFloat = 28

    /// B4: see the call site. Between `DaylightSearchPill.preferredWidthPriority`
    /// (400) and `NSLayoutPriorityWindowSizeStayPut` (500).
    static let pillLabelCompressionPriority = NSLayoutConstraint.Priority(450)

    private func buildPillRow() -> NSStackView {
        var views: [NSView] = []
        for space in DaylightSpace.allCases {
            let container = HoverHighlightView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.identifier = NSUserInterfaceItemIdentifier(space.rawValue)

            let label = NSTextField(labelWithString: space.title)
            label.font = HelmType.rounded(HelmType.scaled(12.5), .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            // B4: above `DaylightSearchPill.preferredWidthPriority` (400) so
            // the search pill gives up its preferred 230pt *before* any
            // navigation label starts truncating, and below
            // `NSLayoutPriorityWindowSizeStayPut` (500) so none of this can
            // ever widen the window (AGENTS.md gotcha (13)). It was
            // `.defaultLow` (250), which is what let the search pill keep its
            // full width while a pill label collapsed to 4pt.
            label.setContentCompressionResistancePriority(Self.pillLabelCompressionPriority, for: .horizontal)
            container.addSubview(label)
            // B4 (`data/grand-line-e2e-audit/report.md`): a floor, so a narrow
            // window truncates every pill a little instead of erasing one.
            //
            // All five labels sat at `.defaultLow` with no minimum and no
            // fairness, so when the bar ran out of room Auto Layout's own
            // tie-breaking dumped almost the whole deficit on one of them:
            // measured at a 900pt window, `engineering`'s label was **4.0pt
            // wide** while the other three kept 60-70pt, and the *selected*
            // pill rendered as a wide ink capsule with no legible text at all.
            // Reproduced at 1100pt too - a perfectly ordinary width for this
            // app, whose own default launch frame used to be 1220.
            //
            // 499, never higher: `NSLayoutPriorityWindowSizeStayPut` is 500,
            // and this bar spans the full window (AGENTS.md gotcha (13)).
            let floor = label.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.pillLabelMinWidth)
            floor.priority = HelmDaylightPriority.contentTie
            floor.isActive = true
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 15),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -15),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
            container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pillClicked(_:))))
            // §6.3: radio-button semantics with arrow-key movement, reusing
            // exactly the pattern `HelmSegmentedTabs` already established
            // (GL-16) rather than a second one.
            container.accessibilityRoleOverride = .radioButton
            container.accessibilityLabelOverride = space.title
            container.onKeyDown = { [weak self] event in
                self?.handleArrowKey(event, from: space) ?? false
            }
            pills.append(SpacePill(space: space, container: container, label: label))
            views.append(container)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.required, for: .horizontal)
        // §8 Phase 6: the pills are individually `.radioButton`s (above), but
        // VoiceOver only announces "1 of 5" and offers group navigation once
        // something declares itself the *group* they belong to. Without this
        // the five pills read as five unrelated buttons that happen to sit
        // together, which is a materially different thing from a one-of-five
        // choice. Set on the container rather than by giving each pill a
        // `linkedUIElements` list, because the container is the thing that
        // actually owns which of them is selected.
        row.setAccessibilityRole(.radioGroup)
        row.setAccessibilityLabel("Spaces")
        row.setAccessibilityElement(true)
        return row
    }

    /// The bar's own focusable controls, in the order the keyboard should
    /// reach them - the first half of §8 Phase 6's `bar -> canvas -> content`
    /// key loop, which `AppShellController.updateKeyViewLoop()` chains into
    /// whatever is showing below.
    ///
    /// Reading order, not view order: `loadView` anchors the pills from the
    /// leading edge and the trailing cluster from the trailing edge, so the
    /// two groups are separate constraint chains and nothing in the view
    /// hierarchy states their relative order.
    var keyViewChain: [NSView] {
        // A2: on a drill page the way out is the first thing the keyboard
        // should reach. `filter` below drops it on the canvas, where the
        // whole cluster is hidden.
        var chain: [NSView] = [drillNav.backButtonForKeyLoop]
        chain += pills.map { $0.container }
        chain.append(searchPill)
        chain.append(recentDestinations.button)
        chain += quickAccessRowButtons
        chain.append(quickAccessOverflowButton)
        chain.append(themeToggleButton)
        chain.append(notificationCenter.bell)
        chain.append(avatar)
        return chain.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// Every plain icon square on this bar, in visual order. `notificationCenter.bell`
    /// is deliberately not here - it is a `NotificationBellButton`, which owns
    /// its own badge geometry and its own `applyTheme`.
    private var iconSquares: [DaylightBarIconButton] {
        [recentDestinations.button] + quickAccessRowButtons
            + [quickAccessOverflowButton, themeToggleButton]
    }

    // MARK: The configurable shortcut row (UX1/UX2)

    /// Point the bar at a pinned list. The one way the row changes.
    ///
    /// Idempotent and safe before the view is loaded (the initial call is made
    /// from `loadView` itself, and `AppShellController` calls it again whenever
    /// the captain pins or unpins from the overlay).
    func setQuickAccess(_ configuration: QuickAccessConfiguration) {
        quickAccess = configuration
        guard isViewLoaded else { return }
        rebuildQuickAccessRow()
    }

    /// The pinned list the bar is currently drawing - what the overlay's
    /// context menu reads to decide whether it says "Pin" or "Unpin".
    var quickAccessConfiguration: QuickAccessConfiguration { quickAccess }

    /// Rebuild the row wholesale.
    ///
    /// Wholesale rather than diffed on purpose: the row is at most six
    /// buttons, rebuilding it is imperceptible, and a diff would be a second
    /// place for the row's order to be decided. `NSStackView` removes an
    /// arranged subview's constraints with it, so there is nothing of the old
    /// row left to fight the new one.
    private func rebuildQuickAccessRow() {
        for button in quickAccessRowButtons {
            quickAccessRow.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        quickAccessRowButtons = quickAccess.visible.map { destination in
            let button = DaylightDestinationButton(destination: destination)
            button.target = self
            button.action = #selector(destinationButtonClicked(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: DaylightBarIconButton.side),
                button.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),
            ])
            quickAccessRow.addArrangedSubview(button)
            return button
        }
        applyQuickAccessVisibility()
        // The row's buttons are new views, so the theme they were built
        // without has to be handed to them - `ThemeManager.observe`'s closure
        // already ran for this controller long before this rebuild.
        applyTheme(ThemeManager.shared.theme)
    }

    /// Whether the overflow button has anything to show right now: the
    /// captain's overflow pins while the row is expanded, or the whole row
    /// while it is collapsed.
    private var overflowDestinations: [RailDestination] {
        quickAccessCollapsed ? quickAccess.pinned : quickAccess.overflow
    }

    /// Apply the current collapsed/expanded state to the views.
    ///
    /// Split out of `setQuickAccessCollapsed` so a *rebuild* lands in the
    /// right state too - a row rebuilt while the window is narrow used to come
    /// back expanded, which is the bug this separation exists to make
    /// impossible.
    private func applyQuickAccessVisibility() {
        for button in quickAccessRowButtons { button.isHidden = quickAccessCollapsed }
        let destinations = overflowDestinations
        let showsOverflow = !destinations.isEmpty
        quickAccessOverflowButton.isHidden = !showsOverflow
        quickAccessOverflowWidth.constant = showsOverflow ? DaylightBarIconButton.side : 0
        // GL-16: the button navigates straight to a lone overflowing
        // destination (see `quickAccessOverflowClicked`), so it has to say so.
        // "More destinations" on a control that opens exactly one page is a
        // label that describes the mechanism rather than the outcome, and it
        // is the only thing VoiceOver has to go on.
        let label = destinations.count == 1 ? destinations[0].title : "More destinations"
        quickAccessOverflowButton.toolTip = label
        quickAccessOverflowButton.setAccessibilityLabel(label)
        // ...and it has to *look* like it too. A control that navigates
        // straight to one page is an ordinary shortcut button, so it draws
        // that destination's own icon rather than the generic ellipsis - the
        // ellipsis is a promise of a menu, and on this branch there is none.
        // Taken from the same `RailDestination.symbol`/`.domainHue` pair
        // `DaylightDestinationButton` is built from, so Hosts' icon here and
        // Hosts' icon anywhere else in the app are one rendering, not two.
        let direct = destinations.count == 1 ? destinations[0] : nil
        quickAccessOverflowButton.applyGlyph(symbol: direct?.symbol ?? "ellipsis",
                                             hue: direct?.domainHue,
                                             tileTint: direct.flatMap(DaylightBarIconButton.tileTintOverride))
        // The gap belongs between two *visible* things. With the row collapsed
        // it has zero width of its own, and with no overflow button there is
        // nothing on the other side of the gap.
        rowToOverflowGap.constant = (quickAccessCollapsed || !showsOverflow) ? 0 : -HelmMetrics.s2
    }

    /// Collapse the shortcut row into `quickAccessOverflowButton`, or put it
    /// back - review #3's B6.
    ///
    /// The buttons are `NSStackView` arranged subviews now, so hiding them
    /// genuinely removes their width from layout - the one case where gotcha
    /// (11)'s "a hidden view keeps its constraints" does not apply, and the
    /// reason this no longer drives a width constraint per button.
    private func setQuickAccessCollapsed(_ collapsed: Bool) {
        guard collapsed != quickAccessCollapsed else { return }
        quickAccessCollapsed = collapsed
        applyQuickAccessVisibility()
    }

    /// The overflow button's click - a menu of the destinations the bar is not
    /// drawing as icons, in the captain's own order, reaching the same
    /// `onSelectDestination` a real icon does.
    ///
    /// A shortcut that changed what it did depending on the window's width
    /// would be worse than no shortcut, which is why a collapsed bar lists the
    /// *whole* pinned row here rather than only its overflow tail.
    ///
    /// **One overflowing destination navigates straight to it, with no menu.**
    /// A menu whose only row is the thing the captain already pointed at
    /// charges two clicks for one decision, and it is the common case rather
    /// than an edge one: the default row pins seven against UX2's cap of six,
    /// so a captain who never opens the overlay meets a one-row menu every
    /// time. The branch reads the count at *click* time rather than assuming
    /// what overflows - a narrow window collapses the whole pinned row into
    /// here, and that genuinely is a menu.
    @objc private func quickAccessOverflowClicked() {
        if let only = quickAccessOverflowDirectDestination {
            onSelectDestination?(only)
            return
        }
        let menu = quickAccessMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: quickAccessOverflowButton.bounds.height + 4),
                   in: quickAccessOverflowButton)
    }

    /// The destination a click would navigate straight to, or `nil` when it
    /// would put a menu up instead.
    ///
    /// One property rather than the test asking the same question a second
    /// way, because a check that re-derived "is there exactly one?" for itself
    /// would assert nothing about what the click actually does.
    ///
    /// A suite drives the real `performClick` on the single-destination
    /// branch, which is the stronger evidence and covers the button's wiring
    /// too. It cannot on the other one: that branch calls `NSMenu.popUp`,
    /// which blocks on a tracking loop nothing headless can dismiss - so the
    /// menu branch is asserted through this property plus the menu's own
    /// contents.
    private var quickAccessOverflowDirectDestination: RailDestination? {
        let destinations = overflowDestinations
        return destinations.count == 1 ? destinations[0] : nil
    }

    private func quickAccessMenu() -> NSMenu {
        let menu = NSMenu()
        for destination in overflowDestinations {
            let item = NSMenuItem(title: destination.title,
                                  action: #selector(quickAccessMenuPicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.image = HelmSymbol.image(destination.symbol, pointSize: 13, weight: .medium)
            item.representedObject = destination.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func quickAccessMenuPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let destination = RailDestination(rawValue: raw) else { return }
        onSelectDestination?(destination)
    }

    /// B2's "active": light the shortcut for the destination the captain is
    /// actually looking at, and only that one.
    ///
    /// Forwarded from `AppShellController` on every navigation - the bar is
    /// told which destination is showing, exactly as it is told which space is
    /// selected (`setSelectedSpace`), and owns neither piece of state itself.
    /// `nil` clears every one, which is what a host page (not a
    /// `RailDestination` at all) and any destination with no shortcut get.
    func setActiveDestination(_ destination: RailDestination?) {
        guard isViewLoaded else { return }
        for button in iconSquares {
            let isActive = (button as? DaylightDestinationButton)?.destination == destination
            button.setActiveDestination(destination != nil && isActive)
        }
    }

    private func buildAvatar() {
        avatar.title = ""
        avatar.isBordered = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = HelmMetrics.dTileLarge
        avatar.layer?.masksToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.target = self
        avatar.action = #selector(avatarClicked)
        avatar.toolTip = "Account"
        avatar.attributedTitle = NSAttributedString(string: "M", attributes: [
            .font: HelmType.rounded(HelmType.scaled(11), .heavy),
            .foregroundColor: NSColor.white,
        ])
        avatarGradient.startPoint = HelmDomainHue.tileStart
        avatarGradient.endPoint = HelmDomainHue.tileEnd
        avatarGradient.cornerRadius = HelmMetrics.dTileLarge
        // Below the title, which AppKit draws in the button's own layer.
        avatar.layer?.insertSublayer(avatarGradient, at: 0)

        let panelContent = AvatarLogoutPopoverController()
        panelContent.onSettings = { [weak self] in
            self?.avatarPanel?.close()
            self?.onSelectSettings?()
        }
        panelContent.onLogout = { [weak self] in
            self?.avatarPanel?.close()
            self?.logoutClicked()
        }
        // B5: the panel registers itself with the lock gate and follows the
        // theme on its own - see `HelmBarPanel`.
        avatarPanel = HelmBarPanel(content: panelContent)
    }

    // MARK: Selection

    /// Moves the selected pill without firing `onSelectSpace` - for a
    /// selection that came from somewhere else (a `⌘N` shortcut the canvas
    /// handled, or the shell restoring the last space on a back-navigation).
    func setSelectedSpace(_ space: DaylightSpace) {
        selectedSpace = space
        applyTheme(ThemeManager.shared.theme)
    }

    var selectedSpaceForTests: DaylightSpace { selectedSpace }

    @objc private func pillClicked(_ sender: NSClickGestureRecognizer) {
        guard let raw = sender.view?.identifier?.rawValue,
              let space = DaylightSpace(rawValue: raw) else { return }
        setSelectedSpace(space)
        onSelectSpace?(space)
    }

    private func handleArrowKey(_ event: NSEvent, from space: DaylightSpace) -> Bool {
        let step: Int
        switch Int(event.keyCode) {
        case 123, 126: step = -1   // left, up
        case 124, 125: step = 1    // right, down
        default: return false
        }
        guard let index = pills.firstIndex(where: { $0.space == space }) else { return false }
        let next = index + step
        guard pills.indices.contains(next) else { return true }
        let target = pills[next]
        setSelectedSpace(target.space)
        onSelectSpace?(target.space)
        view.window?.makeFirstResponder(target.container)
        return true
    }

    /// Test-only entry to `handleArrowKey`, which takes a real `NSEvent` -
    /// lets a self-test drive real arrow-key pill navigation without
    /// depending on the rest of `NSEvent`'s construction surface. Matches
    /// this file's existing `debugPills()`/`selectedSpaceForTests` convention
    /// of a plain, always-compiled test accessor (this app has no `@testable`
    /// import story - see AGENTS.md's GL-27 note).
    func handleArrowKeyForTests(keyCode: UInt16, from space: DaylightSpace) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
        ) else { return false }
        return handleArrowKey(event, from: space)
    }

    // MARK: Avatar

    @objc private func avatarClicked() {
        guard let avatarPanel else { return }
        if avatarPanel.isShown {
            avatarPanel.close()
        } else {
            (avatarPanel.content as? AvatarLogoutPopoverController)?
                .applyTheme(ThemeManager.shared.theme)
            avatarPanel.show(under: avatar)
        }
    }

    /// Unchanged from the rail's own Logout: one confirmation, same copy.
    /// `fm/grandline-avatar-menu-and-setup-guide` collapsed this from two
    /// alerts to one after live captain feedback; that decision stands.
    #if FM_SELFTESTS
    /// G3: drive the real logout confirmation.
    func debugLogoutClicked() { logoutClicked() }
    #endif

    /// Ask for the logout confirmation and, if it is accepted, log out.
    ///
    /// Exposed so a second affordance (the Hosts sidebar's user row) reaches
    /// the **same** single confirmation - one definition of the copy, the
    /// destructiveness and the Return mapping, rather than a near-copy that
    /// drifts.
    func requestLogout() { logoutClicked() }

    private func logoutClicked() {
        // G3: themed; Return still logs out, as it did here.
        guard HelmConfirm.confirm(
            title: "Log out of Manjesh Grand Line?",
            body: "This locks the app immediately. You'll need your Grand Line password to get back in. Your terminal sessions keep running in the background.",
            confirmTitle: "Log Out",
            destructive: true,
            symbol: "lock.fill",
            hue: .rose) else { return }
        onLogoutRequested?()
    }

    /// The exact call Console's own toolbar button used to make - the quick
    /// flip within a theme's own light/dark family pair (`pairId`), never
    /// the full 13-theme picker (`ThemeMenu.swift`/Settings' Appearance
    /// grid). `applyTheme()` runs via the `observe` callback registered in
    /// `loadView`, so nothing else is needed here.
    @objc private func destinationButtonClicked(_ sender: NSButton) {
        guard let button = sender as? DaylightDestinationButton else { return }
        onSelectDestination?(button.destination)
    }

    @objc private func themeToggleClicked() {
        ThemeManager.shared.toggle()
    }

    // MARK: Theme

    override func viewDidLayout() {
        super.viewDidLayout()
        avatarGradient.frame = avatar.bounds
        bar.layer?.shadowPath = CGPath(roundedRect: bar.bounds,
                                       cornerWidth: HelmMetrics.dBar,
                                       cornerHeight: HelmMetrics.dBar,
                                       transform: nil)
        // A1: full screen hides the traffic lights, so the reservation has
        // to be re-read rather than set once - see `leadingContentInset`.
        let wantedInset = leadingContentInset
        if abs(leadingInsetConstraint.constant - wantedInset) > 0.01 {
            leadingInsetConstraint.constant = wantedInset
        }
        // B6: the shortcut row gives way below `quickAccessCollapseWidth`.
        // Measured off the bar's own width rather than the window's, because
        // the bar is what the row has to fit inside.
        if bar.bounds.width > 0 {
            setQuickAccessCollapsed(bar.bounds.width < Self.quickAccessCollapseWidth)
        }
    }

    private func applyTheme(_ theme: HelmTheme) {
        // `ThemeManager.swift`'s checklist item 2, which every other
        // destination in this app already follows - this bar was the one
        // exception. Its layer-backed fills and every label's colour are
        // literal `HelmTheme` hexes, so they tracked the theme correctly
        // regardless; what had no guarantee of its own was `materialView` (an
        // `NSVisualEffectView`, shown only on the Daylight family) and any
        // other AppKit-owned chrome inside this subtree (a popped `NSMenu`,
        // a search field's cursor) - those resolve against the OS's actual
        // light/dark setting rather than this window's forced appearance
        // unless the view carrying them is *itself* told, the same class of
        // "half-themed" bug this codebase has hit for Sticky Board, Code
        // Preview and Whiteboard. A captain running macOS in System Light
        // with a dark Helm theme selected (Dusk, the daily theme since
        // `fm/grandline-theme-motion-web-islands-modernization`) is exactly
        // the condition that exposes it: everything else stays dark, and
        // this bar's material renders light.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)

        focusChip.applyTheme(theme)

        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        // The bar floats on the page ground, so the root behind it paints the
        // ground itself - a transparent root would let the window's own
        // backing show through (AGENTS.md gotcha (8)'s other half).
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        // B1: on the Daylight family the fill is a tint *over* the material;
        // on the twelve legacy palettes the material is not there at all and
        // this is the same opaque fill it has always been.
        materialView.isHidden = !theme.isDaylight
        bar.layer?.backgroundColor = theme.isDaylight
            ? surface.withAlphaComponent(Self.daylightFillAlpha).cgColor
            : surface.cgColor
        // A3: the border and the elevation both depend on whether the
        // showing page is scrolled, so one method owns them - otherwise a
        // theme change would silently reset the bar to its resting depth
        // while the page underneath is still scrolled.
        applyScrollEdge(theme, animated: false)

        wordmark.font = HelmType.rounded(HelmType.scaled(14.5), .heavy)
        wordmark.textColor = ink

        // §6.3: selected = white on `ink` (measured 14.08:1 on Daylight);
        // idle = `muted` on nothing; hover = `ink` on `inset`.
        let selectedFill = ink
        let selectedInk = HelmContrast.legible(HelmTheme.nsColor(theme.chromeBackgroundHex), over: selectedFill)
        let hoverFill = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : line.withAlphaComponent(0.35)
        for pill in pills {
            let isSelected = pill.space == selectedSpace
            pill.container.cornerRadius = pill.container.bounds.height > 0
                ? pill.container.bounds.height / 2
                : 14
            pill.container.normalColor = isSelected ? selectedFill : .clear
            pill.container.hoverColor = isSelected ? selectedFill : hoverFill
            pill.container.accessibilityValueOverride = isSelected ? "selected" : "not selected"
            pill.label.font = HelmType.rounded(HelmType.scaled(12.5), .semibold)
            pill.label.textColor = isSelected ? selectedInk : muted
        }

        searchPill.applyTheme(theme)
        // B2: every icon square resolves its own rest/hover/active colours
        // from the theme now, rather than being handed one flat set here -
        // that is what lets a shortcut light up in its destination's own hue
        // without this method knowing which hue that is.
        for button in iconSquares { button.applyTheme(theme) }
        notificationCenter.bell.applyTheme(ink: muted, line: line, surface: theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset) : surface)

        let avatarPair = (h1: HelmDomainHue.amber.pair(in: theme).h2,
                          h2: HelmDomainHue.rose.pair(in: theme).h2)
        HelmMotion.withoutImplicitAnimation {
            avatarGradient.colors = [avatarPair.h1.cgColor, avatarPair.h2.cgColor]
        }
        avatar.attributedTitle = NSAttributedString(string: "M", attributes: [
            .font: HelmType.rounded(HelmType.scaled(11), .heavy),
            .foregroundColor: HelmContrast.legibleGlyph(over: avatarPair.h1, target: HelmContrast.textTarget),
        ])
    }

    // MARK: Probe / self-test surface

    struct Geometry {
        let barFrame: NSRect
        let cornerRadius: CGFloat
        /// B1: a **rendering** material, i.e. one that is actually visible.
        /// The view exists on every theme; it is hidden on the twelve legacy
        /// palettes, and a hidden material is not one the captain can see.
        let usesVisualEffect: Bool
        /// Every blending mode any visual effect view in this bar's subtree
        /// is set to, visible or not. `checkBarMaterial` asserts
        /// `.behindWindow` never appears here - that, and not "no material at
        /// all", is what AGENTS.md gotcha (8) is actually a finding about.
        let visualEffectBlendingModes: [NSVisualEffectView.BlendingMode]
        /// The bar fill's own alpha. 1 on the legacy palettes (byte-for-byte
        /// what it always was), `daylightFillAlpha` on the Daylight family, so
        /// the material below it reads.
        let fillAlpha: CGFloat
        let pillCount: Int
        let selected: String
        let shadowOpacity: Float
    }

    var geometryForTests: Geometry {
        Geometry(barFrame: bar.frame,
                 cornerRadius: bar.layer?.cornerRadius ?? 0,
                 usesVisualEffect: containsVisibleVisualEffectView(view),
                 visualEffectBlendingModes: visualEffectBlendingModes(view),
                 fillAlpha: bar.layer?.backgroundColor?.alpha ?? 0,
                 pillCount: pills.count,
                 selected: selectedSpace.rawValue,
                 shadowOpacity: bar.layer?.shadowOpacity ?? 0)
    }

    private func containsVisibleVisualEffectView(_ root: NSView) -> Bool {
        if root is NSVisualEffectView, !root.isHiddenOrHasHiddenAncestor { return true }
        return root.subviews.contains { containsVisibleVisualEffectView($0) }
    }

    private func visualEffectBlendingModes(_ root: NSView) -> [NSVisualEffectView.BlendingMode] {
        var out: [NSVisualEffectView.BlendingMode] = []
        if let effect = root as? NSVisualEffectView { out.append(effect.blendingMode) }
        for sub in root.subviews { out += visualEffectBlendingModes(sub) }
        return out
    }

    /// The pill views, so a test can drive a real click/press through the
    /// same recognizer a captain's mouse would.
    /// The bar's quick-access destination icons, in visual order
    /// (leading -> trailing).
    func debugDestinationButtons() -> [DaylightDestinationButton] { quickAccessRowButtons }

    func debugThemeToggleButton() -> DaylightThemeToggleButton { themeToggleButton }

    // GL-27: these two are guarded, unlike the older accessors above them.
    // That is not inconsistency for its own sake - they reach into
    // `debugPanel` on the two panel controllers, which *is* guarded, so an
    // unguarded accessor here fails the release build outright. Which is
    // exactly how this was found.
    #if FM_SELFTESTS
    /// B2: every plain icon square on the bar, in visual order. Reads the same
    /// `iconSquares` the theming and the active-state push do, so a suite
    /// cannot assert against a list that has drifted from the real one.
    func debugIconSquares() -> [DaylightBarIconButton] { iconSquares }

    /// B5: the bar's three dropdown panels, by name. The avatar's is built in
    /// `buildAvatar`, so this is `nil`-safe rather than force-unwrapped.
    func debugBarPanels() -> [(String, HelmBarPanel)] {
        var out: [(String, HelmBarPanel)] = [
            ("notifications", notificationCenter.debugPanel),
            ("recents", recentDestinations.debugPanel),
            ("clipboard", clipboardHistory.debugPanel),
        ]
        if let avatarPanel { out.append(("avatar", avatarPanel)) }
        return out
    }
    #endif

    func debugSearchPill() -> NSView { searchPill }

    /// B6's three seams: the drill title's rendered width, the overflow button
    /// itself, and the menu it pops - built by the same method the click uses,
    /// so a test drives the real items rather than a copy of the list.
    ///
    /// GL-27: guarded, because `HelmDrillHeader.debugTitleWidth` is - a
    /// `debug*` hook left in a production file keeps shipping, which is the
    /// gap that phase's own sweep closed for `ConsoleController`.
    #if FM_SELFTESTS
    func debugDrillTitleWidth() -> CGFloat { drillNav.debugTitleWidth }
    func debugQuickAccessOverflowButton() -> DaylightBarIconButton { quickAccessOverflowButton }
    func debugQuickAccessOverflowMenu() -> NSMenu { quickAccessMenu() }
    /// The branch the overflow button's click will take - the destination it
    /// navigates straight to, or `nil` when it pops the menu.
    ///
    /// Reads the *same* property `quickAccessOverflowClicked` branches on, so
    /// this cannot agree with a test while disagreeing with the click.
    /// `debugQuickAccessOverflowMenu` alone cannot cover this: it builds the
    /// menu unconditionally, and so passes just as happily when no click ever
    /// pops one.
    func debugQuickAccessOverflowClickTarget() -> RailDestination? {
        quickAccessOverflowDirectDestination
    }
    /// The row itself, so a suite can measure the width UX2's collapse
    /// reclaims - the buttons are arranged subviews now, so their own frames
    /// are not where that shows up.
    func debugQuickAccessRow() -> NSView { quickAccessRow }
    #endif

    /// Re-themes this instance directly, bypassing `ThemeManager.setTheme` -
    /// which persists to the real `UserDefaults` domain this process shares
    /// with the captain's own app. AGENTS.md records several suites that
    /// leaked a theme this way and made unrelated ones fail.
    func applyThemeForTests(_ theme: HelmTheme) { applyTheme(theme) }

    func debugPills() -> [HoverHighlightView] { pills.map { $0.container } }

    /// B4: every pill's label frame, in bar coordinates, so a test can measure
    /// what a narrow window actually did to them.
    func debugPillLabelWidths() -> [(space: DaylightSpace, width: CGFloat)] {
        pills.map { ($0.space, $0.label.frame.width) }
    }

    /// The highest constraint priority anywhere in the bar's own subtree that
    /// could act on width. `checkBarDoesNotCapWindow` asserts nothing here
    /// exceeds `NSLayoutPriorityWindowSizeStayPut`.
    /// Every width constraint in the bar's own subtree that is **not** a
    /// fixed size on a fixed-size control, as `(description, priority)`.
    ///
    /// The exemption is not a loophole: a required `width == 34` on the bell
    /// or the avatar cannot widen the window, because those controls sum to a
    /// tiny fraction of the bar and the chain between them is built from
    /// inequalities. What *can* cap a window is a required constraint tying a
    /// flexible view's width to its own content or to the bar - and those are
    /// exactly what this reports.
    func debugWidthConstraints() -> [(String, Float)] {
        var out: [(String, Float)] = []
        func walk(_ v: NSView) {
            // A control whose own outer width is already pinned to a constant
            // (the bell, the avatar, a gradient tile) is not a window floor,
            // and neither is anything *inside* it - the bell's badge zone and
            // its icon square are chrome laid out within a 63pt button. Skip
            // the whole subtree rather than exempting each internal constraint,
            // which would otherwise mean this check re-litigating
            // `NotificationBellButton`'s private layout.
            //
            // A2 adds `HelmDrillHeader` for exactly the same reason: its own
            // width constraints are a 34pt back button and a 30pt tile, and
            // the one flexible thing in it (the title) carries `.defaultLow`
            // compression resistance, so the cluster is content-sized and
            // yields before the window does. Re-litigating its private
            // layout here would be the same mistake.
            //
            // F7's chip is the same case again, and qualifies on the same
            // test the drill header states: its own width constraints are a
            // 14pt countdown ring and a `<= 190` cap on the task title (a
            // cap is a maximum and can never be a floor), and the one
            // flexible thing in it - that title - carries `contentTie` (499)
            // compression resistance, so the chip is content-sized and
            // yields before the window does. `FocusTimerViewSelfTest`
            // asserts that behaviourally, on a real window actually shrunk
            // with the chip on the bar, so this exemption is not a blind
            // spot: a source skip and a behavioural check catch different
            // things, and this trap needs both.
            if v is NSButton || v is HelmGradientTile || v is HelmDrillHeader
                || v is FocusTimerChip { return }
            for c in v.constraints where c.firstAttribute == .width || c.secondAttribute == .width {
                out.append((String(describing: c), c.priority.rawValue))
            }
            v.subviews.forEach(walk)
        }
        for subview in bar.subviews { walk(subview) }
        for c in bar.constraints where c.firstAttribute == .width || c.secondAttribute == .width {
            out.append((String(describing: c), c.priority.rawValue))
        }
        return out
    }

    func debugMaxWidthConstraintPriority() -> Float {
        debugWidthConstraints().map(\.1).max() ?? 0
    }

    // MARK: A1/A2/A3 probe surface

    /// The drill cluster itself, so a suite can read the real title the bar
    /// is showing rather than the one the shell believes it set.
    var drillNavForTests: HelmDrillHeader { drillNav }
    var drillNavIsHiddenForTests: Bool { drillNav.isHiddenOrHasHiddenAncestor }
    var drillActionsForTests: [NSView] { drillActions.arrangedSubviews }
    var pillsAreHiddenForTests: Bool { pills.allSatisfy { $0.container.isHiddenOrHasHiddenAncestor } }
    var wordmarkIsHiddenForTests: Bool { wordmark.isHiddenOrHasHiddenAncestor }
    var scrollEdgeActiveForTests: Bool { scrollEdgeActive }
    var barLayerForTests: CALayer? { bar.layer }
    var leadingContentInsetForTests: CGFloat { leadingInsetConstraint.constant }
    /// The leading cluster's real frame in the bar's own coordinates, for a
    /// collision check against the traffic-light span.
    var leadingGroupFrameForTests: NSRect { leadingGroup?.frame ?? .zero }
    var barFrameInViewForTests: NSRect { bar.frame }
}

// MARK: - The search pill (§6.3)

/// Capsule, `inset` fill, `hair` border, magnifier + placeholder + a `⌘K` chip.
///
/// A `HoverHighlightView` for the same reason `PillButton` was (GL-16): the
/// role, label, focus ring and Return/Space activation all come from that one
/// component rather than four overrides here.
final class DaylightSearchPill: HoverHighlightView {
    /// B4: below `HelmDaylightPriority.contentTie` (499), which is where the
    /// space pills' own label floor sits - so this control gives up its
    /// preferred width first. Still well under
    /// `NSLayoutPriorityWindowSizeStayPut` (500).
    static let preferredWidthPriority = NSLayoutConstraint.Priority(400)

    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "Search anything\u{2026}")
    private let badge = NSTextField(labelWithString: "\u{2318}K")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1

        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: HelmType.scaled(12))
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        badge.font = .monospacedSystemFont(ofSize: HelmType.scaled(10), weight: .medium)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = HelmMetrics.rChip
        badge.layer?.borderWidth = 1
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, label, badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // 499, never required: this is the one bar control designed to shrink,
        // so its own preferred width must never be able to widen the window.
        //
        // B4: and it now sits *below* the space pills' own label floor (499),
        // so a narrow window takes width off this pill - the one element with
        // real slack, 230pt down to 92 - before it starts truncating the
        // navigation. Before this, both were 499 and the tie-break gave the
        // search pill its full ~350pt while a pill label collapsed to 4pt.
        let preferred = widthAnchor.constraint(equalToConstant: 230)
        preferred.priority = Self.preferredWidthPriority
        // The floor stays at 499 - a search pill compressed past this stops
        // being a control at all.
        let floor = widthAnchor.constraint(greaterThanOrEqualToConstant: 92)
        floor.priority = HelmDaylightPriority.contentTie

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            preferred,
            floor,
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        accessibilityLabelOverride = "Search anything, Command K"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    func applyTheme(_ theme: HelmTheme) {
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let fill = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.backgroundHex)
        normalColor = fill
        hoverColor = line.withAlphaComponent(theme.isDaylight ? 0.45 : 0.3)
        layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor
        iconView.contentTintColor = muted
        label.font = .systemFont(ofSize: HelmType.scaled(12))
        // §2.4: placeholder-weight copy uses `muted`, never `faint` - `faint`
        // measures 2.04:1 and is decorative only.
        label.textColor = muted
        badge.font = .monospacedSystemFont(ofSize: HelmType.scaled(10), weight: .medium)
        badge.textColor = muted
        badge.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        badge.layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor
    }
}

// MARK: - The theme toggle (moved from Console's own toolbar)

/// A bordered 34x34 icon square - the exact same visible chrome as
/// `NotificationBellButton`'s own icon square (`iconBackground`: radius 9,
/// `chromeBackgroundHex` fill, `chromeLineHex` @ 0.5 border), so the two
/// square icon buttons on this bar read as one visual language rather than
/// two different button recipes sitting side by side.
///
/// Moved here from Console's per-tab toolbar
/// (`fm/grandline-daylight-theme-toggle-relocate`): the light/dark flip is
/// an app-wide preference (it calls `ThemeManager.shared.toggle()`, the
/// same quick within-family flip Console's button always called - never the
/// full 13-theme picker, which stays on `ThemeMenu.swift`/Settings'
/// Appearance grid), so it belongs on the app-wide floating bar rather than
/// a per-destination toolbar that only exists on Console.
/// The bar's plain icon-square button: a bordered, theme-filled 34x34 tile
/// with one SF Symbol centred in it.
///
/// This started life as `DaylightThemeToggleButton`'s own body and was lifted
/// into a base class when `fm/grandline-sticky-code-preview-polish` added the
/// Sticky Board / Code Preview quick-access icons - three near-identical
/// copies of the same chrome is how this app ends up with the "five card
/// recipes"/"two icon-button languages" findings its own UI audit spent a
/// phase undoing. `NotificationBellButton` deliberately stays separate: it
/// carries a badge, so it owns the badge's own geometry.
///
/// **B2 (UI modernization audit §3B): one icon language at rest, state on
/// hover and on the page you are looking at.**
///
/// The audit called this row "the noisiest thing in the app" - three icon
/// languages side by side (grey SF Symbol squares, five saturated raster app
/// icons carrying their own dark backgrounds, a gradient disc), reading "like
/// a browser extension row". Its preferred fix, option (a), is what this
/// implements: **one** language for every square, and the full-colour raster
/// artwork reserved for the destination pages themselves, where it still
/// renders on the drill header's tile and on the Overview canvas card
/// (`RailDestination.drillHeaderArtwork`, untouched).
///
/// **`fm/grandline-topbar-icon-tiles` changed what that one language is.**
/// B2 made it a monochrome symbol at rest; the captain asked for the coloured
/// tile #458 had just given Settings' nav rows, for the same reason that fix
/// records - a column (or a row) of same-coloured glyphs is something you
/// read, and one of coloured tiles is something you scan. That is a change of
/// *colour*, not of language: still one geometry, one radius, one recipe, no
/// raster artwork. `restyleAsTile` carries it and its own comment carries the
/// reasoning; `restyleAsPlainSquare` is the pre-tile rendering, kept for the
/// controls that have no destination and so no honest hue.
///
/// **Which hue, and how it resolves per palette, is `tileHex(for:in:)`** -
/// including why the resolution differs between the Daylight family and the
/// other 24 palettes, and what that costs. Read that before changing a
/// colour here.
class DaylightBarIconButton: NSButton {
    /// Matches `NotificationBellButton.iconSize` exactly - B2's "the History
    /// and theme buttons should match the bell's square" is true by
    /// construction, and stayed true when the bell shed its outboard badge
    /// zone (see `NotificationBellButton`).
    static let side: CGFloat = NotificationBellButton.iconSize

    /// Resting glyph alpha. The icon row is chrome: it should recede until
    /// the captain is either pointing at it or on the page it opens.
    static let restingGlyphAlpha: CGFloat = 0.7

    /// The hover ladder, one step deeper than the shared resting
    /// `HelmContrast.tileWashSteps` ([0.16, 0.13, 0.11, 0.09, 0.07, 0.05]),
    /// and the active ladder one deeper again. Same shape as the shared one -
    /// a descending list of wash fractions, taken from the front, the first
    /// that clears the 3:1 floor winning - so a hue with no headroom lands on
    /// the same faint wash in all three states rather than on an illegible
    /// one. Every value was checked against all 26 palettes x 7 hues by
    /// `DaylightBarIconTileSelfTest.checkEveryPaletteTilesLegibly`.
    static let hoverTileWashSteps: [CGFloat] = [0.26, 0.22, 0.18, 0.14, 0.11, 0.08]
    static let activeTileWashSteps: [CGFloat] = [0.38, 0.32, 0.26, 0.20, 0.16, 0.12]

    /// The hue a destination shortcut's tile is washed in.
    ///
    /// **The mapping is not new** - `RailDestination.domainHue` is this app's
    /// existing per-destination identity table (Daylight §2.2's "Owns"
    /// column), and this is only its resolution against a palette. Blue for
    /// the reading destinations (Docs, Notebook, Runbooks, Fleet), teal for
    /// the running systems (Console, Hosts, Log Analyzer, Kubernetes, the
    /// Kanban), rose for Tasks and Dictation, violet for the AI surfaces
    /// (Straw Hat Pirates, Poneglyph, Whiteboard, Schedules), amber for Setup
    /// and Sticky Board, green for the merge queue and the Reading List,
    /// slate for Settings and Tools. Inventing a second table here is exactly
    /// how a bar icon and the page it opens come to disagree about a colour.
    ///
    /// One destination does not take its domain hue here, and it is a
    /// deliberate exception rather than a second table:
    /// `tileTintOverride(for:)` gives Console the tint Settings' own Terminal
    /// row carries. That function's comment is the reasoning.
    ///
    /// **The per-family split matches `UnifiedSearch`'s destination tile
    /// exactly**, which is the app's other place that draws a `RailDestination`
    /// as a colour tile: the §2.2 identity hue on the Daylight family, the
    /// palette's own corresponding `HelmTint` slot on the other 24. That split
    /// is load-bearing, not a convenience. `identityHex` alone resolves to
    /// `HelmTint.neutral` off Daylight, and neutral *is* `chromeInkHex` - so
    /// washing it as a tinted surface produces the near-black chip AGENTS.md
    /// warns about, eleven times in a row, on 24 of the 26 palettes.
    ///
    /// The cost is recorded rather than hidden: `fallbackTint` maps rose onto
    /// `.critical` and amber onto `.warn`, which is a *semantic* slot, and
    /// `RecentDestinationsPopover.makeRow` names routing an identity through
    /// it as a defect. That objection is about an accent **bar** - one red
    /// edge among grey ones on a benign list reads as an alarm. It does not
    /// transfer to this row, where every shortcut carries a tile and the set
    /// therefore reads as a categorical palette: nothing here is the one
    /// coloured thing among neutral siblings, which is the whole mechanism by
    /// which a hue comes to be read as a signal.
    static func tileHex(for hue: HelmDomainHue, in theme: HelmTheme) -> String {
        theme.isDaylight ? hue.identityHex(in: theme) : hue.fallbackTint.hex(in: theme)
    }

    /// The one destination whose bar tile is **not** a wash of its own
    /// `domainHue`.
    ///
    /// `fm/grandline-topbar-terminal-icon-color`: Console owns teal, because
    /// §2.2 gives that hue to the running-systems area as a whole (Console,
    /// Hosts, Log Analyzer, Kubernetes). The captain asked for the top bar's
    /// terminal shortcut to carry the same dark-slate tile Settings' own
    /// Terminal row draws, so the app's two "this is the terminal" tiles read
    /// as one thing rather than as two unrelated colours.
    ///
    /// It returns `SettingsController.Category.terminal`'s **own** tint rather
    /// than a second copy of it: that is where the choice and its reasoning
    /// live (`.neutral` deliberately, against AGENTS.md's general warning off
    /// it), and a literal hex here would be off-palette in twenty-five of the
    /// twenty-six themes. `DaylightBarIconTileSelfTest` asserts the two are
    /// the same value, so a future edit to either side fails by name instead
    /// of silently reopening the gap this closed.
    ///
    /// **The override resolves unbranched**, which is the point: a tint is
    /// `HelmTint.neutral.hex(in:)` on all 26 palettes, exactly as
    /// `IconTileView` resolves Settings' tile. That is deliberately not
    /// `tileHex`'s Daylight/non-Daylight split - the split exists so a §2.2
    /// *identity* hue survives on a palette that has no such table, and this
    /// is a borrowed tint rather than an identity. Expressing it as
    /// `HelmDomainHue.slate` instead would agree with Settings on the 24
    /// fallback palettes and diverge on the Daylight family itself
    /// (`8B8677`, a warm slate against Settings' cool one) - which is the
    /// family the captain is looking at.
    static func tileTintOverride(for destination: RailDestination) -> HelmTint? {
        destination == .console ? SettingsController.Category.terminal.tint : nil
    }

    /// The hue a destination's bar tile is washed in, override included.
    ///
    /// The entry point every caller that *has* a `RailDestination` should
    /// reach for - the hue-only overload above is the resolution step alone,
    /// and cannot see an override keyed on the destination.
    static func tileHex(for destination: RailDestination, in theme: HelmTheme) -> String {
        if let tint = tileTintOverride(for: destination) { return tint.hex(in: theme) }
        return tileHex(for: destination.domainHue, in: theme)
    }

    private let iconBackground = NSView()
    private let iconImageView = NSImageView()
    /// The glyph currently drawn, and the hue it lights up in.
    ///
    /// `var` rather than `let` because the quick-access overflow button is one
    /// control with two identities - a generic ellipsis when it opens a menu,
    /// and the destination's own shortcut icon when it navigates straight to a
    /// lone overflowing page. See `applyGlyph(symbol:hue:)`.
    private var symbolName: String
    /// The hue this button takes on hover/active, or `nil` for a control that
    /// is not a destination shortcut (the theme toggle, Recents) and so has
    /// no domain of its own - those brighten to plain ink instead.
    private var hue: HelmDomainHue?
    /// A tint that replaces `hue` for this button's tile, or `nil` to wash the
    /// domain hue as usual. See `tileTintOverride(for:)` - `hue` is left
    /// intact either way, because it is still this destination's identity
    /// everywhere else in the app.
    private var tileTint: HelmTint?

    private var hoverArea: NSTrackingArea?
    private var isHovering = false
    /// Set by the bar when this button's own destination is the one showing.
    private(set) var isActiveDestination = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(symbol: String, tooltip: String, accessibilityLabel: String, hue: HelmDomainHue? = nil,
         tileTint: HelmTint? = nil) {
        self.symbolName = symbol
        self.hue = hue
        self.tileTint = tileTint
        super.init(frame: .zero)
        title = ""
        isBordered = false
        image = nil
        toolTip = tooltip
        setAccessibilityLabel(accessibilityLabel)
        translatesAutoresizingMaskIntoConstraints = false

        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 9
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        // Decorative only - clicks are handled by the button itself, exactly
        // as `NotificationBellButton.iconBackground` is.
        addSubview(iconBackground)

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        // A symbol name that does not resolve returns nil and renders as an
        // invisible button with no error anywhere - this app has shipped that
        // exact bug before (the Hosts list's "anchor", which is not an SF
        // Symbol at all). Every caller's symbol is a `RailDestination.symbol`
        // already rendering elsewhere in the app, and
        // `DaylightModuleSelfTest.checkBarDestinationIcons` asserts each one
        // resolves.
        loadGlyphImage()
        iconImageView.imageScaling = .scaleProportionallyDown
        addSubview(iconImageView)

        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: Self.side),
            iconBackground.heightAnchor.constraint(equalToConstant: Self.side),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func loadGlyphImage() {
        iconImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    }

    /// Swap the glyph this button draws, and the hue it lights up in.
    ///
    /// One button with two identities, rather than two buttons swapped in and
    /// out: the quick-access overflow control draws the generic ellipsis while
    /// it opens a menu, and the destination's **own** shortcut icon while it
    /// navigates straight to a lone overflowing page. Both arguments come from
    /// the same `RailDestination.symbol` / `.domainHue` pair a real
    /// `DaylightDestinationButton` is built from, so the two renderings of one
    /// destination cannot drift - which is the whole reason this takes a
    /// symbol and a hue rather than a ready-made image. `tileTint` travels
    /// with them for the same reason - it is the destination's own
    /// `tileTintOverride(for:)`, not a colour this call site chose.
    func applyGlyph(symbol: String, hue: HelmDomainHue?, tileTint: HelmTint? = nil) {
        guard symbol != symbolName || hue != self.hue || tileTint != self.tileTint else { return }
        symbolName = symbol
        self.hue = hue
        self.tileTint = tileTint
        loadGlyphImage()
        restyle()
    }

    // MARK: Hover (B2)

    /// `NSButton` has no built-in hover callback, so this is the same tracking
    /// area `HoverTrackingButton` installs - inlined rather than inherited
    /// because that class exists to *forward* hover to a caller, and this one
    /// consumes it itself.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// **`super` is load-bearing, not politeness.** `NSControl` drives its own
    /// press tracking through `mouseEntered`/`mouseExited`
    /// (`-[NSControl(_NSTracking) gestureRecognizerTrackingAction:]` ->
    /// `_pressGRActionCellBased:`), so an override that swallows them leaves
    /// that state machine able to send this control's action on a *later*
    /// enter/exit/move - i.e. **a bare hover activates the button**.
    ///
    /// That shipped, and it was the captain's long-running "light/dark keeps
    /// changing by itself" report, four fix attempts deep: this class is
    /// `DaylightThemeToggleButton`'s superclass, so sweeping the mouse across
    /// the bar silently flipped the whole app between Dusk and Daylight.
    /// Captured on the real running app - `themeToggleClicked` firing with
    /// `NSApp.currentEvent` a `mouseEntered` and no click count at all.
    /// `AppKitAuditSelfTest.test_hoverNeverActivatesAControl` is the guard.
    ///
    /// Note this is the *opposite* of `HoverHighlightView`'s rule, which must
    /// never override `mouseDown`/`mouseUp` at all: that class is an `NSView`,
    /// whose hover hooks are documented no-ops, and its overrides would steal a
    /// nested button's click. Here the control needs the call to reach it.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        restyle()
    }

    /// The bar calls this on every navigation so the shortcut for the page the
    /// captain is looking at reads as the current one - B2's "active" half.
    func setActiveDestination(_ active: Bool) {
        guard active != isActiveDestination else { return }
        isActiveDestination = active
        restyle()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        restyle()
    }

    private func restyle() {
        guard let hue else {
            restyleAsPlainSquare()
            return
        }
        restyleAsTile(hue: hue)
    }

    /// The pre-tile rendering, kept verbatim for a control that is **not** a
    /// destination shortcut: the theme toggle, Recents, the clipboard history
    /// and the overflow button while it is drawing its generic ellipsis.
    ///
    /// None of those has a domain of its own, so there is no honest colour to
    /// put behind them - see `tileHex(for:in:)`. They stay the quiet chrome
    /// square they always were, which is also what keeps the coloured tiles
    /// beside them reading as "these are places you can go".
    private func restyleAsPlainSquare() {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeBackgroundHex)

        iconImageView.contentTintColor = (isHovering || isActiveDestination)
            ? ink
            : muted.withAlphaComponent(Self.restingGlyphAlpha)
        iconBackground.layer?.backgroundColor = surface.cgColor
        iconBackground.layer?.borderWidth = 1
        iconBackground.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
    }

    /// `fm/grandline-topbar-icon-tiles`: a destination shortcut is a coloured
    /// **tile** at rest, the same treatment #458 gave Settings' nav rows.
    ///
    /// **This reverses half of B2 on the captain's own instruction, and the
    /// half it reverses is narrower than it looks.** B2's finding was that the
    /// row carried *three icon languages* at once - grey symbol squares, five
    /// saturated raster app icons with their own dark backgrounds, and a
    /// gradient disc - "like a browser extension row". That is still fixed:
    /// there is exactly one language here, one geometry, one radius, one
    /// recipe, and the raster artwork stays on the destination pages. What
    /// changes is that the single language is now coloured rather than grey,
    /// which is what makes eleven squares *scannable* instead of a row you
    /// have to read - the identical argument `HelmPageSidebar.RowIndicator`'s
    /// `.tile` case records for a column of eight.
    ///
    /// **The wash, and why there are three ladders.** Every state is
    /// `HelmContrast.tintedSurface` over this button's own hue, which is the
    /// one recipe `IconTileView` uses - so the fill and the glyph on it are
    /// contrast-corrected to the 3:1 non-text floor by the shared helper
    /// rather than by a second copy of the maths. State is then the *depth* of
    /// that wash: resting at the shared `tileWashSteps`, hover and active at
    /// progressively stronger ladders, each independently corrected. The
    /// alternative - one fill, lightened on hover - cannot promise the floor,
    /// because lightening a fill moves it toward the glyph on a dark palette
    /// and away from it on a light one.
    ///
    /// Note the fill now moves under the pointer, which the pre-tile comment
    /// here deliberately avoided ("a background that appeared under the
    /// pointer would make the whole row twitch"). That reasoning applied to a
    /// background *appearing*; a tile that is already there deepening by one
    /// step is the ordinary hover response every other tinted surface in this
    /// app gives.
    private func restyleAsTile(hue: HelmDomainHue) {
        let hex = tileTint?.hex(in: theme) ?? Self.tileHex(for: hue, in: theme)
        let steps: [CGFloat]
        let borderAlpha: CGFloat
        if isActiveDestination {
            steps = Self.activeTileWashSteps
            borderAlpha = 0.75
        } else if isHovering {
            steps = Self.hoverTileWashSteps
            borderAlpha = 0.45
        } else {
            steps = HelmContrast.tileWashSteps
            borderAlpha = 0.2
        }
        let resolved = HelmContrast.tintedSurface(tintHex: hex,
                                                  theme: theme,
                                                  target: HelmContrast.nonTextTarget,
                                                  washSteps: steps)
        iconImageView.contentTintColor = resolved.foreground
        iconBackground.layer?.backgroundColor = resolved.fill.cgColor
        iconBackground.layer?.borderWidth = 1
        iconBackground.layer?.borderColor = HelmTheme.nsColor(hex).withAlphaComponent(borderAlpha).cgColor
    }

    #if FM_SELFTESTS
    var debugHasIcon: Bool { iconImageView.image != nil }
    var debugIconBackground: NSView { iconBackground }
    var debugSymbolName: String { symbolName }
    var debugGlyphImage: NSImage? { iconImageView.image }
    var debugGlyphColor: NSColor? { iconImageView.contentTintColor }
    var debugIsHovering: Bool { isHovering }
    func debugSetHovering(_ hovering: Bool) {
        isHovering = hovering
        restyle()
    }
    #endif
}

final class DaylightThemeToggleButton: DaylightBarIconButton {
    init() {
        super.init(symbol: "circle.lefthalf.filled",
                   tooltip: "Toggle Light/Dark (⌘⌥T)",
                   accessibilityLabel: "Toggle Light/Dark")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// A one-click jump to a destination, sitting in the bar next to the theme
/// toggle (`fm/grandline-sticky-code-preview-polish`).
///
/// The captain asked for Sticky Board and Code Preview first, then Tasks
/// (`fm/grandline-tasks-quick-access-icon`), then Straw Hat Pirates and
/// Poneglyph (`fm/poneglyph-own-destination-and-strawhat-toolbar-shortcut`).
/// Every one of them stays a full destination in its own space; this is purely
/// a shortcut for pages reached often enough that a space switch plus a card
/// click is friction. The glyph is each destination's **own**
/// `RailDestination.symbol` rather than new iconography, so the bar icon and
/// the page it opens can never drift apart.
///
/// **B2 moved the raster artwork off this button**, and that reverses one
/// earlier decision on purpose rather than by accident.
/// `fm/strawhat-toolbar-shortcut-use-jolly-roger-icon-69c3` gave this button
/// `RailDestination.drillHeaderArtwork`, because Straw Hat Pirates' bar icon
/// was falling back to a generic `person.3.fill` while its own drill header
/// and canvas card rendered the crew's Jolly Roger. The audit looked at the
/// finished row and found the opposite problem one level up: five saturated
/// raster tiles, each with its own dark background, sitting between grey
/// symbol squares and a gradient disc - "the noisiest thing in the app". Its
/// §3B B2 names the Jolly Roger among the five it wants quietened, and the
/// captain approved that fix, so the artwork now lives only where it reads as
/// identity rather than as noise: the destination's own page and its canvas
/// card, both of which still take it from the same
/// `RailDestination.drillHeaderArtwork` this button used to. The bar icon and
/// the page therefore still cannot drift - they are two renderings of one
/// `RailDestination`, which was that fix's actual requirement.
final class DaylightDestinationButton: DaylightBarIconButton {
    let destination: RailDestination

    init(destination: RailDestination) {
        self.destination = destination
        super.init(symbol: destination.symbol,
                   tooltip: "Open \(destination.title)",
                   accessibilityLabel: destination.title,
                   hue: destination.domainHue,
                   tileTint: DaylightBarIconButton.tileTintOverride(for: destination))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - Hover tracking (moved from the rail)

/// An `NSButton` that reports mouse enter/exit - `NSButton` has no built-in
/// hover callback. Moved verbatim from `IconRailController.swift` when the
/// rail's visible surface was removed; the avatar is its only remaining user.
final class HoverTrackingButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    // `super` for the same reason `DaylightBarIconButton`'s does: an
    // `NSControl` starved of its hover hooks can fire its action on a hover.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

// MARK: - The avatar popover (moved from the rail)

/// Settings above a divider above Logout - an identity/account menu, not a
/// general dumping ground for destinations. Moved verbatim from
/// `IconRailController.swift`; only its host changed.
final class AvatarLogoutPopoverController: NSViewController {
    private let settingsRow = HoverHighlightView()
    private let settingsIcon = NSImageView()
    private let settingsLabel = NSTextField(labelWithString: "Settings")
    private let divider = NSView()
    private let logoutRow = HoverHighlightView()
    private let logoutIcon = NSImageView()
    private let logoutLabel = NSTextField(labelWithString: "Logout")

    var onSettings: (() -> Void)?
    var onLogout: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 172, height: 89))
        root.wantsLayer = true
        view = root

        settingsIcon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        settingsIcon.translatesAutoresizingMaskIntoConstraints = false
        settingsLabel.font = .systemFont(ofSize: HelmType.scaled(13), weight: .medium)
        settingsLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsRow.translatesAutoresizingMaskIntoConstraints = false
        settingsRow.addSubview(settingsIcon)
        settingsRow.addSubview(settingsLabel)
        root.addSubview(settingsRow)
        settingsRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(settingsRowClicked)))
        settingsRow.accessibilityLabelOverride = "Settings"

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        logoutIcon.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: "Logout")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        logoutIcon.translatesAutoresizingMaskIntoConstraints = false
        logoutLabel.font = .systemFont(ofSize: HelmType.scaled(13), weight: .medium)
        logoutLabel.translatesAutoresizingMaskIntoConstraints = false
        logoutRow.translatesAutoresizingMaskIntoConstraints = false
        logoutRow.addSubview(logoutIcon)
        logoutRow.addSubview(logoutLabel)
        root.addSubview(logoutRow)
        logoutRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(logoutRowClicked)))
        logoutRow.accessibilityLabelOverride = "Logout"

        NSLayoutConstraint.activate([
            settingsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            settingsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            settingsRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            settingsRow.heightAnchor.constraint(equalToConstant: 32),

            settingsIcon.leadingAnchor.constraint(equalTo: settingsRow.leadingAnchor, constant: 10),
            settingsIcon.centerYAnchor.constraint(equalTo: settingsRow.centerYAnchor),
            settingsIcon.widthAnchor.constraint(equalToConstant: 16),

            settingsLabel.leadingAnchor.constraint(equalTo: settingsIcon.trailingAnchor, constant: 8),
            settingsLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsRow.trailingAnchor, constant: -10),
            settingsLabel.centerYAnchor.constraint(equalTo: settingsRow.centerYAnchor),

            divider.topAnchor.constraint(equalTo: settingsRow.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            divider.heightAnchor.constraint(equalToConstant: 1),

            logoutRow.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            logoutRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            logoutRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            logoutRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            logoutRow.heightAnchor.constraint(equalToConstant: 32),

            logoutIcon.leadingAnchor.constraint(equalTo: logoutRow.leadingAnchor, constant: 10),
            logoutIcon.centerYAnchor.constraint(equalTo: logoutRow.centerYAnchor),
            logoutIcon.widthAnchor.constraint(equalToConstant: 16),

            logoutLabel.leadingAnchor.constraint(equalTo: logoutIcon.trailingAnchor, constant: 8),
            logoutLabel.trailingAnchor.constraint(lessThanOrEqualTo: logoutRow.trailingAnchor, constant: -10),
            logoutLabel.centerYAnchor.constraint(equalTo: logoutRow.centerYAnchor),
        ])

        settingsRow.cornerRadius = HelmMetrics.rControl
        logoutRow.cornerRadius = HelmMetrics.rControl
        applyTheme(ThemeManager.shared.theme)
    }

    @objc private func settingsRowClicked() { onSettings?() }
    @objc private func logoutRowClicked() { onLogout?() }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        divider.layer?.backgroundColor = line.cgColor
        settingsIcon.contentTintColor = ink
        settingsLabel.textColor = ink
        settingsRow.normalColor = .clear
        settingsRow.hoverColor = line.withAlphaComponent(0.5)
        // Red, as a destructive-ish action - routed through the contrast
        // correction rather than painted raw (audit §5.7).
        logoutIcon.contentTintColor = HelmContrast.legibleTintedText(
            tintHex: theme.ansiHex[1], over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
        logoutLabel.textColor = ink
        logoutRow.normalColor = .clear
        logoutRow.hoverColor = line.withAlphaComponent(0.5)
    }
}
