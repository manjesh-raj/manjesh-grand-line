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
    /// Tasks -> Straw Hat Pirates -> Poneglyph -> theme -> bell -> avatar.
    ///
    /// A new icon **appends** to the trailing end of this group rather than
    /// being slotted in by topic, which is the convention Sticky Board and
    /// Code Preview already set: the group reads in the order the captain
    /// asked for each shortcut, and adding one never moves an icon a captain
    /// has already built muscle memory for.
    private let stickyBoardButton = DaylightDestinationButton(destination: .stickyBoard)
    private let codePreviewButton = DaylightDestinationButton(destination: .codePreview)
    private let tasksButton = DaylightDestinationButton(destination: .shift)
    /// The captain asked for two more, in the same message: one-click jumps
    /// to the Straw Hat Pirates crew chat and to Poneglyph (his own personal
    /// credential vault) - both reached often enough from elsewhere that a
    /// space switch plus a card click is friction, matching every other icon
    /// in this group. Straw Hat Pirates sits first (the more central, daily
    /// feature); Poneglyph sits right before the theme toggle.
    private let strawHatButton = DaylightDestinationButton(destination: .strawHat)
    private let poneglyphButton = DaylightDestinationButton(destination: .poneglyph)
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

        for button in [stickyBoardButton, codePreviewButton, tasksButton, strawHatButton, poneglyphButton] {
            button.target = self
            button.action = #selector(destinationButtonClicked(_:))
        }

        buildAvatar()

        bar.addSubview(leadingGroup)
        bar.addSubview(pillRow)
        bar.addSubview(drillActions)
        bar.addSubview(searchPill)
        bar.addSubview(recentDestinations.button)
        bar.addSubview(stickyBoardButton)
        bar.addSubview(codePreviewButton)
        bar.addSubview(tasksButton)
        bar.addSubview(strawHatButton)
        bar.addSubview(poneglyphButton)
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
        drillActionsGap = drillActions.trailingAnchor.constraint(
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
            searchPill.trailingAnchor.constraint(equalTo: recentDestinations.button.leadingAnchor, constant: -HelmMetrics.s2),
            searchPill.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            recentDestinations.button.trailingAnchor.constraint(equalTo: stickyBoardButton.leadingAnchor, constant: -HelmMetrics.s2),
            recentDestinations.button.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            recentDestinations.button.widthAnchor.constraint(equalToConstant: DaylightBarIconButton.side),
            recentDestinations.button.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),

            stickyBoardButton.trailingAnchor.constraint(equalTo: codePreviewButton.leadingAnchor, constant: -HelmMetrics.s2),
            stickyBoardButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stickyBoardButton.widthAnchor.constraint(equalToConstant: DaylightBarIconButton.side),
            stickyBoardButton.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),

            codePreviewButton.trailingAnchor.constraint(equalTo: tasksButton.leadingAnchor, constant: -HelmMetrics.s2),
            codePreviewButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            codePreviewButton.widthAnchor.constraint(equalToConstant: DaylightBarIconButton.side),
            codePreviewButton.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),

            tasksButton.trailingAnchor.constraint(equalTo: strawHatButton.leadingAnchor, constant: -HelmMetrics.s2),
            tasksButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            tasksButton.widthAnchor.constraint(equalToConstant: DaylightBarIconButton.side),
            tasksButton.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),

            strawHatButton.trailingAnchor.constraint(equalTo: poneglyphButton.leadingAnchor, constant: -HelmMetrics.s2),
            strawHatButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            strawHatButton.widthAnchor.constraint(equalToConstant: DaylightBarIconButton.side),
            strawHatButton.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),

            poneglyphButton.trailingAnchor.constraint(equalTo: themeToggleButton.leadingAnchor, constant: -HelmMetrics.s2),
            poneglyphButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            poneglyphButton.widthAnchor.constraint(equalToConstant: DaylightBarIconButton.side),
            poneglyphButton.heightAnchor.constraint(equalToConstant: DaylightBarIconButton.side),

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

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // `ThemeManager.observe` fires synchronously at registration, which
        // for this controller is before `avatarGradient` has a frame - the
        // `refreshTheme()` convention (AGENTS.md's ThemeManager checklist,
        // item 8) is what makes the first paint correct anyway.
        applyTheme(ThemeManager.shared.theme)
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

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
        chain.append(stickyBoardButton)
        chain.append(codePreviewButton)
        chain.append(tasksButton)
        chain.append(strawHatButton)
        chain.append(poneglyphButton)
        chain.append(themeToggleButton)
        chain.append(notificationCenter.bell)
        chain.append(avatar)
        return chain.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// Every plain icon square on this bar, in visual order. `notificationCenter.bell`
    /// is deliberately not here - it is a `NotificationBellButton`, which owns
    /// its own badge geometry and its own `applyTheme`.
    private var iconSquares: [DaylightBarIconButton] {
        [recentDestinations.button, stickyBoardButton, codePreviewButton,
         tasksButton, strawHatButton, poneglyphButton, themeToggleButton]
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
    func debugDestinationButtons() -> [DaylightDestinationButton] {
        [stickyBoardButton, codePreviewButton, tasksButton, strawHatButton, poneglyphButton]
    }

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
        ]
        if let avatarPanel { out.append(("avatar", avatarPanel)) }
        return out
    }
    #endif

    func debugSearchPill() -> NSView { searchPill }

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
            if v is NSButton || v is HelmGradientTile || v is HelmDrillHeader { return }
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
/// implements: every shortcut is a **monochrome SF Symbol** at rest, and the
/// full-colour artwork is reserved for the destination pages themselves,
/// where it still renders on the drill header's tile and on the Overview
/// canvas card (`RailDestination.drillHeaderArtwork`, untouched).
///
/// **The hue is `HelmDomainHue.identityHex(in:)`, not `baseColor(in:)`**, and
/// that choice is this app's own existing rule rather than a new one. On the
/// Daylight family the two agree. On the twelve legacy palettes `baseColor`
/// resolves through `fallbackTint`, which is a *semantic* slot - so hovering
/// the Tasks icon (`.rose` -> `.critical`) would turn it red, and the icon
/// would be making a claim about Tasks rather than identifying it. That is
/// exactly the defect `identityHex` was written for. The cost is that hue
/// differentiation lands only where the design language it belongs to lives;
/// the twelve still get a real state response (muted at rest, full ink on
/// hover/active), which is the half B2 is actually about.
class DaylightBarIconButton: NSButton {
    /// Matches `NotificationBellButton.iconSize` exactly - B2's "the History
    /// and theme buttons should match the bell's square" is true by
    /// construction, and stayed true when the bell shed its outboard badge
    /// zone (see `NotificationBellButton`).
    static let side: CGFloat = NotificationBellButton.iconSize

    /// Resting glyph alpha. The icon row is chrome: it should recede until
    /// the captain is either pointing at it or on the page it opens.
    static let restingGlyphAlpha: CGFloat = 0.7

    /// How much of the active shortcut's own hue is washed into its tile.
    ///
    /// Flattened with `HelmContrast.mix` rather than set as a translucent
    /// layer colour, and that is deliberate: `mix` is a straight sRGB blend,
    /// which is what alpha compositing over an opaque backdrop actually does,
    /// whereas `NSColor.blended(withFraction:of:)` converts both operands into
    /// a *calibrated* space first and drifts from it. This codebase has been
    /// bitten by that difference before (see the segmented-tabs correction in
    /// AGENTS.md).
    static let activeWashFraction: Double = 0.16

    private let iconBackground = NSView()
    private let iconImageView = NSImageView()
    private let symbolName: String
    /// The hue this button takes on hover/active, or `nil` for a control that
    /// is not a destination shortcut (the theme toggle, Recents) and so has
    /// no domain of its own - those brighten to plain ink instead.
    private let hue: HelmDomainHue?

    private var hoverArea: NSTrackingArea?
    private var isHovering = false
    /// Set by the bar when this button's own destination is the one showing.
    private(set) var isActiveDestination = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(symbol: String, tooltip: String, accessibilityLabel: String, hue: HelmDomainHue? = nil) {
        self.symbolName = symbol
        self.hue = hue
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
        iconImageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
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
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : HelmTheme.nsColor(theme.chromeBackgroundHex)

        let lit = isHovering || isActiveDestination
        let accent = hue.map { HelmTheme.nsColor($0.identityHex(in: theme)) } ?? ink
        let glyph = lit ? accent : muted.withAlphaComponent(Self.restingGlyphAlpha)

        // The active shortcut also carries a faint wash of its own hue, so
        // "this is the page you are on" survives the captain's cursor leaving
        // the bar. Hover alone is a glyph change only - a background that
        // appeared under the pointer would make the whole row twitch as it
        // crosses.
        let fill = isActiveDestination
            ? HelmContrast.color(HelmContrast.mix(HelmContrast.components(accent),
                                                  HelmContrast.components(surface),
                                                  Self.activeWashFraction))
            : surface

        iconImageView.contentTintColor = glyph
        iconBackground.layer?.backgroundColor = fill.cgColor
        iconBackground.layer?.borderWidth = 1
        iconBackground.layer?.borderColor = (isActiveDestination ? accent.withAlphaComponent(0.5) : line.withAlphaComponent(0.5)).cgColor
    }

    #if FM_SELFTESTS
    var debugHasIcon: Bool { iconImageView.image != nil }
    var debugIconBackground: NSView { iconBackground }
    var debugSymbolName: String { symbolName }
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
                   hue: destination.domainHue)
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
