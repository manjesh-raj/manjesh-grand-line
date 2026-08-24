// Manjesh Grand Line - native macOS app.
//
// Daylight **Phase 4, slice 1**'s own suite: the shared drill-page components
// (§6.4-6.14) and the two destinations §7 puts first, Tasks and Review.
//
// What each case is actually protecting, and why it is worth a test rather
// than a read-through:
//
//   1. **The drill header's action cluster really carries the page's own
//      actions** (§6.4). The seam is a protocol conformance, and a missing
//      conformance is invisible - the header simply renders with an empty
//      trailing slot, which looks like a design choice rather than a bug.
//      This also pins the *identity* of the views: Review's Refresh has to be
//      the same instance `refresh()` disables, not a copy.
//   2. **Both migrated pages dropped their in-page hero** (§6.4: "the old
//      in-page hero titles ... disappear"). Checked by walking the real view
//      tree for a title-sized label, because the failure mode is a duplicate
//      title one row apart - the exact defect the audit found on Review and
//      Docs before, and the reason §6.4 says it twice.
//   3. **Daylight's card / button / chip / well recipes resolve to §6.5-6.9's
//      tokens**, and every other palette is untouched. The second half is the
//      point: a "restyle the card" change that quietly moves all thirteen
//      themes is a regression for the twelve captains not on Daylight.
//   4. **Tasks' board is Today | Follow-ups as a two-column row, with
//      Projects as its own full-width section below it** (fm/grandline-
//      tasks-projects-width-fix, correcting slice 1's original "Follow-ups +
//      Projects share the right column" reading once a live captain
//      screenshot showed that squeezed Projects' own multi-card grid into
//      half the page - the shape the captain describes and wants back), and
//      the project *detail* is still full-page. Both pairings are easy to
//      break the same way: the obvious implementation nests Projects (or its
//      detail) inside a column, which caps it at that column's width instead
//      of the whole page.
//   5. **`HelmChipInput`'s three interactions** - Return commits, a trailing
//      comma commits, Backspace on an empty editor pops. The third is new
//      capability, and the first two are behaviour the task editor already
//      had and must not lose in the migration.
//   6. **Review's merge gate is untouched.** §7 says "gated exactly as
//      today", and this slice moved that row's badge, its dot and its button
//      hue - so the gate gets re-asserted here rather than assumed. (The
//      dedicated `ReviewPRRowButtonLayoutSelfTest` covers the geometry.)
//   7. **No new window-width floor.** Every constraint this slice added sits
//      inside `bodyContainer`; AGENTS.md gotcha (13) is this codebase's most
//      expensive recurring bug and a two-column board is a prime site for it.
//      `AppShellBodyWidthSelfTest` is the broad sweep; this is the local one.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_DRILL_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightDrillPageSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkDrillHeaderActions, checkHeroTitlesAreGone,
                      checkDaylightCardRecipe, checkDaylightButtonRecipe,
                      checkDaylightChipAndWell, checkGaugesAreShared,
                      checkTasksBoardLayout, checkChipInputInteractions,
                      checkReviewRowGateAndDot, checkNoWindowWidthFloor] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightDrillPageSelfTest: all checks passed"
                    : "DaylightDrillPageSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    /// A scratch `FM_SHIFT_DIR` so nothing here can reach the captain's real
    /// git-synced Shift data (the convention every Shift suite follows).
    private static func scratchShiftStore() -> ShiftStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daylight-drill-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        setenv("FM_SHIFT_DIR", dir.path, 1)
        return ShiftStore()
    }

    private static func mount(_ controller: NSViewController, width: CGFloat = 1200) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 820)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// Every label in a view tree at or above a point size, so a check can ask
    /// "is there still a hero-sized title on this page" without knowing which
    /// property held it.
    private static func labels(in view: NSView, atLeast points: CGFloat) -> [NSTextField] {
        var found: [NSTextField] = []
        if let label = view as? NSTextField, (label.font?.pointSize ?? 0) >= points,
           !label.stringValue.isEmpty, !label.isHidden {
            found.append(label)
        }
        for sub in view.subviews { found += labels(in: sub, atLeast: points) }
        return found
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        return HelmContrast.ratio(a, b) < 1.01
    }

    // MARK: 1. The drill header's action cluster (§6.4)

    private static func checkDrillHeaderActions(_ ok: inout Bool) {
        print("\n-- drill header actions (§6.4) --")
        let review = ReviewController()
        let window = mount(review)
        defer { _ = window }

        let header = HelmDrillHeader()
        header.configure(title: "Review", subtitle: "", symbol: RailDestination.review.symbol,
                         hue: RailDestination.review.domainHue)
        header.setActions(review.drillHeaderActions)

        guard !review.drillHeaderActions.isEmpty else {
            print("  FAIL Review offers no drill-header actions - its Refresh never moved")
            ok = false
            return
        }
        // Identity, not just count: a copy would render but never disable
        // itself while a fetch is in flight.
        guard header.actionsForTests.count == review.drillHeaderActions.count,
              zip(header.actionsForTests, review.drillHeaderActions).allSatisfy({ $0 === $1 }) else {
            print("  FAIL the header is not showing Review's own action views")
            ok = false
            return
        }
        // Clearing has to actually clear - otherwise navigating from a
        // migrated page to an unmigrated one leaves the previous page's
        // buttons in the header.
        header.setActions([])
        guard header.actionsForTests.isEmpty else {
            print("  FAIL setActions([]) left \(header.actionsForTests.count) view(s) behind")
            ok = false
            return
        }

        // The live subtitle: a page that has not fetched yet must not claim a
        // confident zero (GL-14's rule).
        guard let subtitle = review.drillHeaderSubtitle, !subtitle.isEmpty else {
            print("  FAIL Review has no live drill subtitle")
            ok = false
            return
        }
        guard !subtitle.contains("0 open") else {
            print("  FAIL pre-fetch subtitle reports a confident zero: \(subtitle)")
            ok = false
            return
        }

        let shift = ShiftController(store: scratchShiftStore(),
                                    commandLibraryStore: CommandLibraryStore())
        let shiftWindow = mount(shift)
        defer { _ = shiftWindow }
        guard let shiftSubtitle = shift.drillHeaderSubtitle, shiftSubtitle.contains("open") else {
            print("  FAIL Tasks has no live drill subtitle (\(shift.drillHeaderSubtitle ?? "nil"))")
            ok = false
            return
        }
        print("  OK - Review: \"\(subtitle)\" + \(review.drillHeaderActions.count) action(s); Tasks: \"\(shiftSubtitle)\"")
    }

    // MARK: 2. The in-page heroes are gone (§6.4)

    private static func checkHeroTitlesAreGone(_ ok: inout Bool) {
        print("\n-- in-page hero titles (§6.4: the drill header IS the name) --")
        // The drill header's own title is 26pt, so anything at or above 20pt
        // *inside a page body* is a second title competing with it.
        let heroFloor: CGFloat = 20

        let review = ReviewController()
        let reviewWindow = mount(review)
        defer { _ = reviewWindow }
        let reviewHeroes = labels(in: review.view, atLeast: heroFloor)
        if !reviewHeroes.isEmpty {
            print("  FAIL Review still renders \(reviewHeroes.count) hero-sized label(s): "
                  + reviewHeroes.map { "\"\($0.stringValue)\" @\(fmt($0.font?.pointSize ?? 0))" }.joined(separator: ", "))
            ok = false
        }

        let shift = ShiftController(store: scratchShiftStore(),
                                    commandLibraryStore: CommandLibraryStore())
        let shiftWindow = mount(shift)
        defer { _ = shiftWindow }
        let shiftHeroes = labels(in: shift.view, atLeast: heroFloor)
        if !shiftHeroes.isEmpty {
            print("  FAIL Tasks still renders \(shiftHeroes.count) hero-sized label(s): "
                  + shiftHeroes.map { "\"\($0.stringValue)\" @\(fmt($0.font?.pointSize ?? 0))" }.joined(separator: ", "))
            ok = false
        }
        if ok { print("  OK - neither page carries a label at or above \(fmt(heroFloor))pt") }
    }

    // MARK: 3a. §6.5's card recipe

    private static func checkDaylightCardRecipe(_ ok: inout Bool) {
        print("\n-- HelmCard under Daylight (§6.5: radius 20, card fill, hair border, resting shadow) --")
        for theme in HelmTheme.allThemes {
            let card = HelmCard()
            card.setHeader(symbol: "checklist", title: "A card")
            card.applyTheme(theme)
            var problems: [String] = []
            let wantRadius = theme.isDaylight ? HelmMetrics.dModule : HelmMetrics.rCard
            if abs((card.layer?.cornerRadius ?? -1) - wantRadius) > 0.01 {
                problems.append("radius \(fmt(card.layer?.cornerRadius ?? -1)), want \(fmt(wantRadius))")
            }
            if !sameColor(card.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) },
                          HelmTheme.nsColor(theme.chromeBackgroundHex)) {
                problems.append("fill is not the card surface")
            }
            // The shadow is the half that must NOT leak into the other twelve
            // palettes: every existing card in this app is flat on purpose.
            let opacity = card.layer?.shadowOpacity ?? 0
            if theme.isDaylight, opacity <= 0 { problems.append("no resting shadow") }
            if !theme.isDaylight, opacity > 0 { problems.append("shadow \(opacity) leaked into a non-Daylight theme") }
            if !problems.isEmpty {
                print("  FAIL \(theme.id): \(problems.joined(separator: ", "))")
                ok = false
            }
        }
        if ok { print("  OK - radius 20 + a resting shadow under Daylight only, card fill in all \(HelmTheme.allThemes.count)") }
    }

    // MARK: 3b. §6.6's button recipe

    private static func checkDaylightButtonRecipe(_ ok: inout Bool) {
        print("\n-- HelmButton under Daylight (§6.6) --")
        let daylight = HelmTheme.allThemes.first { $0.isDaylight }
        guard let daylight else {
            print("  FAIL no daylight theme in HelmTheme.allThemes")
            ok = false
            return
        }

        // A primary with no hue is still the theme accent - which is what
        // `HelmContrastSelfTest.checkButtonVariants` asserts for every theme,
        // and what keeps every existing primary button unchanged.
        let plain = HelmButton.palette(variant: .primary, tint: nil, theme: daylight)
        if !sameColor(plain.fill, HelmTheme.nsColor(daylight.accentHex)) {
            print("  FAIL an un-hued .primary is not accentHex")
            ok = false
        }

        // A hued primary takes the domain hue, and its label still clears the
        // text floor on it - §2.4 lists four hues whose raw h1 cannot carry
        // white, so this is the check that the correction is actually applied.
        for hue in HelmDomainHue.allCases {
            let p = HelmButton.palette(variant: .primary, tint: nil, theme: daylight, domainHue: hue)
            // The fill is the hue *as §2.4 corrects it*, which for four of the
            // seven is a darkened value - that correction is the whole point,
            // so comparing against the raw `h1` would assert the bug.
            if !sameColor(p.fill, DaylightPalette.primaryButtonFill(for: hue, theme: daylight)) {
                print("  FAIL .primary(\(hue.rawValue)) is not filled with its corrected hue")
                ok = false
            }
            // §2.4's table, restated: where it names a value, that is what
            // renders. This is what catches a "simplification" that replaces
            // the hand-picked hexes with a derivation that drifts off them.
            if let tabled = DaylightPalette.primaryButtonFills.first(where: { $0.hue == hue })?.corrected,
               !sameColor(p.fill, HelmTheme.nsColor(tabled)) {
                print("  FAIL .primary(\(hue.rawValue)) fill is not §2.4's tabled \(tabled)")
                ok = false
            }
            let ratio = HelmContrast.ratio(p.label, p.fill)
            if ratio < HelmContrast.textTarget - 0.01 {
                print("  FAIL .primary(\(hue.rawValue)) label on its own fill: \(String(format: "%.2f", ratio)):1")
                ok = false
            }
        }

        // Soft / ghost / destructive resolve to §6.6's own tokens.
        let soft = HelmButton.palette(variant: .secondary, tint: nil, theme: daylight)
        if !sameColor(soft.fill, HelmTheme.nsColor(DaylightPalette.inset)) {
            print("  FAIL .secondary fill is not `inset`")
            ok = false
        }
        let ghost = HelmButton.palette(variant: .quiet, tint: nil, theme: daylight)
        if ghost.fill.alphaComponent > 0.01 {
            print("  FAIL .quiet paints a fill (\(ghost.fill))")
            ok = false
        }
        let destructive = HelmButton.palette(variant: .destructive, tint: nil, theme: daylight)
        if HelmContrast.ratio(destructive.label, destructive.fill) < HelmContrast.textTarget - 0.01 {
            print("  FAIL .destructive label on its own wash is below the floor")
            ok = false
        }

        // Capsule, and only under Daylight.
        let capsule = HelmButton.cornerRadius(for: daylight, height: 28)
        if abs(capsule - 14) > 0.01 {
            print("  FAIL a 28pt Daylight button rounds to \(fmt(capsule)), not a capsule's 14")
            ok = false
        }
        for theme in HelmTheme.allThemes where !theme.isDaylight {
            if abs(HelmButton.cornerRadius(for: theme, height: 28) - HelmMetrics.rControl) > 0.01 {
                print("  FAIL \(theme.id) button radius moved off rControl")
                ok = false
            }
        }
        if ok { print("  OK - hued primary + soft/ghost/destructive tokens, capsule under Daylight only") }
    }

    // MARK: 3c. §6.7's chip and §6.9's well

    private static func checkDaylightChipAndWell(_ ok: inout Bool) {
        print("\n-- chip (§6.7) + well (§6.9) under Daylight --")
        guard let daylight = HelmTheme.allThemes.first(where: { $0.isDaylight }) else {
            print("  FAIL no daylight theme")
            ok = false
            return
        }

        // The chip: capsule + bold label. Colours still come from
        // `HelmContrast.tintedSurface`, which `checkPills` already sweeps -
        // this is the geometry/weight half only.
        let pill = NSView()
        let label = NSTextField(labelWithString: "")
        ToolRowLayout.pill(text: "Ready to merge", colorHex: DaylightPalette.ok,
                           into: pill, label: label, theme: daylight)
        let chipRadius = pill.layer?.cornerRadius ?? -1
        if chipRadius < 9.5 {
            print("  FAIL Daylight chip radius \(fmt(chipRadius)) is not a capsule")
            ok = false
        }
        if label.font?.fontDescriptor.symbolicTraits.contains(.bold) != true {
            print("  FAIL Daylight chip label is not bold")
            ok = false
        }

        // The same call in a non-Daylight theme keeps the old radius, so the
        // twelve palettes' chips are byte-identical.
        if let other = HelmTheme.allThemes.first(where: { !$0.isDaylight }) {
            let pill2 = NSView()
            ToolRowLayout.pill(text: "x", colorHex: other.ansiHex[2], into: pill2,
                               label: NSTextField(labelWithString: ""), theme: other)
            if abs((pill2.layer?.cornerRadius ?? -1) - 9) > 0.01 {
                print("  FAIL \(other.id) chip radius moved off 9")
                ok = false
            }
        }

        // The well: `dWell` radius, `inset` fill, and a focused well that
        // flips to `card` with the *page's* hue on its border - §6.9's
        // non-negotiable focused state.
        let field = HelmTextField(placeholder: "Something")
        field.applyTheme(daylight)
        let resting = HelmField.geometry(of: field.chromeView)
        if abs(resting.radius - HelmMetrics.dWell) > 0.01 {
            print("  FAIL Daylight well radius \(fmt(resting.radius)), want \(fmt(HelmMetrics.dWell))")
            ok = false
        }
        if !sameColor(resting.fill, HelmTheme.nsColor(DaylightPalette.inset)) {
            print("  FAIL Daylight well fill is not `inset`")
            ok = false
        }

        let host = NSView()
        let chrome = NSView()
        host.addSubview(chrome)
        HelmField.makeSunken(chrome)
        HelmInputSurface.apply(chrome: chrome, shadowHost: host, theme: daylight,
                               focused: true, hue: .rose)
        let focused = HelmInputSurface.focusGeometry(chrome: chrome, shadowHost: host)
        if abs(focused.borderWidth - HelmInputSurface.focusBorderWidth) > 0.01 {
            print("  FAIL a focused well's border is \(fmt(focused.borderWidth))")
            ok = false
        }
        if !sameColor(chrome.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) },
                      HelmTheme.nsColor(DaylightPalette.card)) {
            print("  FAIL a focused Daylight well did not flip its fill to `card`")
            ok = false
        }
        let hueBase = HelmDomainHue.rose.baseColor(in: daylight)
        if let border = focused.borderColor,
           HelmContrast.ratio(border.withAlphaComponent(1), hueBase) > 1.01 {
            print("  FAIL a focused well's border is not the hue it was handed")
            ok = false
        }
        if abs(Double(focused.shadowOpacity) - 0.15) > 0.001 {
            print("  FAIL Daylight focus ring opacity \(focused.shadowOpacity), want §6.9's 0.15")
            ok = false
        }
        if ok { print("  OK - capsule bold chip, dWell/inset well, focused well = card + hue border + 15% ring") }
    }

    // MARK: 3d. §6.8's gauges are the shared ones

    private static func checkGaugesAreShared(_ ok: inout Bool) {
        print("\n-- gauges (§6.8) --")
        guard let daylight = HelmTheme.allThemes.first(where: { $0.isDaylight }) else {
            print("  FAIL no daylight theme"); ok = false; return
        }
        // Phase 2 already built both; the slice's job was to make the app's
        // one hand-rolled bar (Shift's project card) use the shared one rather
        // than adding a second recipe. Assert the recipe, and assert the
        // project card really renders it.
        let bar = HelmProgressBar()
        bar.configure(fraction: 0.5)
        bar.applyTheme(daylight, hue: .violet)
        bar.frame = NSRect(x: 0, y: 0, width: 200, height: HelmProgressBar.height)
        bar.layoutSubtreeIfNeeded()
        if abs(bar.frame.height - 8) > 0.01 {
            print("  FAIL progress bar is \(fmt(bar.frame.height))pt tall, want §6.8's 8")
            ok = false
        }
        if abs((bar.layer?.cornerRadius ?? -1) - bar.frame.height / 2) > 0.01 {
            print("  FAIL progress bar track is not a capsule")
            ok = false
        }

        let ring = HelmRingGauge()
        ring.configure(value: 4, total: 5)
        ring.applyTheme(daylight, hue: .green)
        if abs(HelmRingGauge.side - 66) > 0.01 || abs(HelmRingGauge.lineWidth - 7) > 0.01 {
            print("  FAIL ring is \(fmt(HelmRingGauge.side))/\(fmt(HelmRingGauge.lineWidth)), want 66/7")
            ok = false
        }
        if ring.centreLabelForTests != "4/5" {
            print("  FAIL ring centre label is \"\(ring.centreLabelForTests)\"")
            ok = false
        }

        // The project card: one shared bar, no private track left behind.
        let store = scratchShiftStore()
        var project = ShiftProject.fresh()
        project.name = "A project"
        let card = ShiftProjectCardView()
        card.configure(project: project, completed: 1, total: 4, theme: daylight)
        _ = store
        func hasProgressBar(_ view: NSView) -> Bool {
            if view is HelmProgressBar { return true }
            return view.subviews.contains(where: hasProgressBar)
        }
        if !hasProgressBar(card) {
            print("  FAIL a project card does not render the shared HelmProgressBar")
            ok = false
        }
        if ok { print("  OK - 8pt capsule bar / 66pt 7pt ring, and the project card uses the shared bar") }
    }

    // MARK: 4. Tasks' board layout (§7, corrected per the captain's own ask)

    /// Today/Follow-ups are a two-column row; Projects is its own full-width
    /// section below that row - not a third item squeezed into the
    /// Follow-ups column. This is the regression `fm/grandline-tasks-
    /// projects-width-fix` exists to catch: the tempting "obvious"
    /// implementation nests Projects inside whichever column Follow-ups is
    /// in (exactly what slice 1 originally shipped, per §7's literal text),
    /// which is indistinguishable from a bug once real project cards are
    /// squeezed into half the page.
    private static func checkTasksBoardLayout(_ ok: inout Bool) {
        print("\n-- Tasks board: Today | Follow-ups row, Projects full-width below --")
        let shift = ShiftController(store: scratchShiftStore(),
                                    commandLibraryStore: CommandLibraryStore())
        let window = mount(shift)
        defer { _ = window }
        shift.view.layoutSubtreeIfNeeded()

        let geometry = shift.debugBoardGeometry()
        guard let tasks = geometry.tasks, let followUps = geometry.followUps,
              let projects = geometry.projects else {
            print("  FAIL one of the three panels is not laid out: \(geometry)")
            ok = false
            return
        }
        // Today and Follow-ups are still a two-column row: Today on the left.
        if tasks.minX >= followUps.minX - 1 {
            print("  FAIL Today (minX \(fmt(tasks.minX))) is not left of Follow-ups (minX \(fmt(followUps.minX)))")
            ok = false
        }
        if abs(tasks.width - followUps.width) > 1 {
            print("  FAIL the two columns are not equal width (\(fmt(tasks.width)) vs \(fmt(followUps.width)))")
            ok = false
        }
        // Projects spans the full page width, not just the Follow-ups
        // column's width - this is the exact regression this test exists to
        // catch (Projects narrowed to `followUps.width` reads as "confined to
        // the right half of the page", the captain's own description).
        if abs(projects.width - geometry.contentWidth) > 2 {
            print("  FAIL Projects is \(fmt(projects.width)) wide, not the full "
                  + "\(fmt(geometry.contentWidth)) page content width - it looks confined to a column")
            ok = false
        }
        // Projects starts at the page's own left edge (Today's left edge),
        // not at Follow-ups' left edge - i.e. it is not a right-column member.
        if abs(projects.minX - tasks.minX) > 1 {
            print("  FAIL Projects' left edge (\(fmt(projects.minX))) is not the page's left edge "
                  + "(\(fmt(tasks.minX))) - it reads as confined to the right column")
            ok = false
        }
        // Same unflipped space every AppKit layout check in this repo uses:
        // "below" means a smaller maxY.
        if projects.maxY >= followUps.maxY - 1 || projects.maxY >= tasks.maxY - 1 {
            print("  FAIL Projects is not below the Today/Follow-ups row")
            ok = false
        }

        // And the project detail is still the whole page, not confined to a
        // column either.
        shift.debugOpenFirstProjectDetail()
        shift.view.layoutSubtreeIfNeeded()
        let detail = shift.debugBoardGeometry()
        if let detailFrame = detail.detail, detailFrame.width < geometry.contentWidth - 2 {
            print("  FAIL the project detail is \(fmt(detailFrame.width)) wide inside a "
                  + "\(fmt(geometry.contentWidth)) page - it should take the whole page")
            ok = false
        }
        if detail.tasks != nil || detail.followUps != nil || detail.projects != nil {
            print("  FAIL the board is still visible behind the project detail")
            ok = false
        }
        if ok {
            print("  OK - Today/Follow-ups at x \(fmt(tasks.minX)) / \(fmt(followUps.minX)), "
                  + "Projects full-width below at x \(fmt(projects.minX)), detail full-width")
        }
    }

    // MARK: 5. HelmChipInput's interactions (§6.9)

    private static func checkChipInputInteractions(_ ok: inout Bool) {
        print("\n-- HelmChipInput: Return / comma / Backspace (§6.9) --")
        let input = HelmChipInput(placeholder: "Add a tag")
        var lastReported: [String] = []
        input.onTokensChanged = { lastReported = $0 }

        input.debugType("kubernetes")
        input.debugPressReturn()
        guard input.tokens == ["kubernetes"], input.chipCountForTests == 1 else {
            print("  FAIL Return did not commit (\(input.tokens), \(input.chipCountForTests) chips)")
            ok = false
            return
        }
        guard input.editorTextForTests.isEmpty else {
            print("  FAIL the editor still holds \"\(input.editorTextForTests)\" after a commit")
            ok = false
            return
        }

        // A trailing comma commits, which is the interaction the pattern this
        // replaced already had.
        input.debugType("prod,")
        guard input.tokens == ["kubernetes", "prod"] else {
            print("  FAIL a trailing comma did not commit (\(input.tokens))")
            ok = false
            return
        }

        // Case-insensitive dedup, also carried over.
        input.debugType("PROD")
        input.debugPressReturn()
        guard input.tokens == ["kubernetes", "prod"] else {
            print("  FAIL a duplicate tag was committed (\(input.tokens))")
            ok = false
            return
        }

        // Backspace on an empty editor pops - the new capability.
        input.debugPressBackspace()
        guard input.tokens == ["kubernetes"] else {
            print("  FAIL Backspace on an empty editor did not pop (\(input.tokens))")
            ok = false
            return
        }
        // ... and with text in the editor it must NOT pop, or a captain
        // correcting a typo silently loses a tag.
        input.debugType("stag")
        input.debugPressBackspace()
        guard input.tokens == ["kubernetes"] else {
            print("  FAIL Backspace popped a token while the editor had text")
            ok = false
            return
        }
        guard lastReported == input.tokens else {
            print("  FAIL onTokensChanged last reported \(lastReported), tokens are \(input.tokens)")
            ok = false
            return
        }

        // Nothing typed-but-uncommitted is lost on save.
        input.commitPendingText()
        guard input.tokens == ["kubernetes", "stag"] else {
            print("  FAIL commitPendingText dropped the pending text (\(input.tokens))")
            ok = false
            return
        }
        print("  OK - Return, comma, dedup, Backspace-pops-only-when-empty, pending text committed")
    }

    // MARK: 6. Review's row: the gate is unchanged, plus §7's dot

    private static func checkReviewRowGateAndDot(_ ok: inout Bool) {
        print("\n-- Review rows: merge gate unchanged + §7's dot --")
        let review = ReviewController()
        let window = mount(review)
        defer { _ = window }

        func pr(_ checks: String, taskID: String?) -> MergedPR {
            MergedPR(source: taskID != nil ? "work" : "forge", taskID: taskID,
                     repo: "manjesh-raj/repo", url: "https://github.com/manjesh-raj/repo/pull/1",
                     number: 1, title: "A change", checks: checks, forge: "github")
        }
        // §7: "Merge = green primary, gated exactly as today" - green checks
        // AND a task id, never one or the other.
        let cases: [(MergedPR, Bool, String)] = [
            (pr("green", taskID: "t-1"), true, "green + task id"),
            (pr("green", taskID: nil), false, "green, no task id"),
            (pr("red", taskID: "t-1"), false, "red + task id"),
            (pr("pending", taskID: "t-1"), false, "pending + task id"),
            (pr("", taskID: "t-1"), false, "no checks + task id"),
        ]
        for (row, wantMerge, label) in cases {
            review.debugRender([row])
            review.view.layoutSubtreeIfNeeded()
            guard let state = review.debugGitHubRowButtonState(at: 0) else {
                print("  FAIL \(label): no row rendered")
                ok = false
                continue
            }
            if state.mergeHidden == wantMerge {
                print("  FAIL \(label): merge \(state.mergeHidden ? "hidden" : "shown"), want the opposite")
                ok = false
            }
        }

        // And the dot really is in the badge's place.
        review.debugRender([pr("green", taskID: "t-1")])
        review.view.layoutSubtreeIfNeeded()
        func hasDot(_ view: NSView) -> Bool {
            if view is HelmSignalDot { return true }
            return view.subviews.contains(where: hasDot)
        }
        if !hasDot(review.view) {
            print("  FAIL no HelmSignalDot in a rendered Review row")
            ok = false
        }
        if ok { print("  OK - the gate holds in all \(cases.count) states, and the row carries a dot") }
    }

    // MARK: 7. No new window-width floor (gotcha (13))

    private static func checkNoWindowWidthFloor(_ ok: inout Bool) {
        print("\n-- no new window-width floor (AGENTS.md gotcha (13)) --")
        // A two-column board plus a chip well plus a progress bar is exactly
        // the shape that has capped this app's window five separate times.
        //
        // **A measured pre-existing floor, recorded so nobody re-derives it:**
        // `.shift` cannot shrink below ~956pt, and that floor is entirely
        // `CommandLibraryPageView`'s (the DevOps Commands tab) - confirmed by
        // measuring the page with that one arranged subview withheld, where
        // the floor vanishes and the page tracks a 700pt window exactly. It is
        // the same floor F9's own fix history documents for this destination
        // (`.shift` stuck at 1049 once), it is untouched by this slice, and it
        // sits below the 1016pt `bodyContainer` width that
        // `AppShellBodyWidthSelfTest`'s narrowest real case (1100pt window)
        // asks for - which is why that suite stays green.
        //
        // So the sweep runs down to the app's own narrowest tested width for
        // both pages, and Review - which this slice restyled end to end and
        // which has no such pane - is additionally swept to 760.
        let shift = ShiftController(store: scratchShiftStore(),
                                    commandLibraryStore: CommandLibraryStore())
        let review = ReviewController()

        func floor(of controller: NSViewController, widths: [CGFloat], label: String) {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.contentView = host
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: host.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            (controller as? ReviewController)?.debugRender([])
            for width in widths {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 800), display: true)
                host.layoutSubtreeIfNeeded()
                if abs(host.bounds.width - width) > 1 {
                    print("  FAIL \(label): asked for \(fmt(width)), resolved to \(fmt(host.bounds.width))")
                    ok = false
                }
            }
        }

        floor(of: shift, widths: [1400, 1200, 1100], label: "Tasks")
        floor(of: review, widths: [1400, 1200, 1100, 900, 760], label: "Review")
        if ok { print("  OK - Tasks tracks a real window to 1100pt, Review to 760pt") }
    }
}

#endif
