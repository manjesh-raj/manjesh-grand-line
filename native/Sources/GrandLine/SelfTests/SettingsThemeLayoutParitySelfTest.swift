// Grand Line - native macOS app.
//
// Regression coverage for a real, captain-reported structural bug on Settings:
// the page's whole LAYOUT - not just its colours - changed depending on which
// of the 14 themes was selected. Two screenshots at the same window size,
// "Daylight" selected vs. "Helm Light" selected, showed a materially
// different page: Daylight rendered Connection/Terminal/Security in a left
// column and Appearance/Morning briefing/Backup & Restore in a right one,
// with the Appearance card's own theme-picker grid at roughly half page
// width (small swatches, a partial third row); Helm Light rendered
// Appearance as a full-width card directly under Connection, with the same
// 14 themes laid out as a much larger 4-wide grid of big swatches, and
// Morning briefing / Backup & Restore reflowed elsewhere on the page.
//
// **Root cause.** `SettingsController.rebuildCardLayout()`'s two-column
// decision was `theme.isDaylight && contentColumnWidth() >= twoColumnMinWidth`
// - gated on the *active theme's family*, not on width alone. That single
// condition drove both halves of what the screenshots showed: the column
// count itself (one column vs. two), and - downstream of it -
// `rebuildAppearanceGrid()`'s own column density, since that grid's column
// count is `HelmResponsiveGrid.columns(containerWidth:...)` computed from
// `appearanceContainer.frame.width`, which is the *full* content width in
// one-column mode and *half* of it in two-column mode. Selecting a theme is
// supposed to change colours; this let it change the page's own structure.
//
// The gate dated to the original Daylight migration (Phase 4 slice 6,
// `fm/grandline-design-system-phase4-slice6`), on the reasoning that two
// columns was Daylight's own new arrangement and a "half-migrated" look on
// a legacy palette would be worse than no migration at all. That reasoning
// does not survive contact with a captain comparing the two side by side at
// the same window size: a page that reflows when only the *colour scheme*
// changes reads as broken, not as a deliberate per-palette design choice.
//
// **Fix**: `fm/grandline-settings-layout-theme-dependent-fix` dropped the
// `theme.isDaylight` condition from `rebuildCardLayout()` entirely - the
// two-column threshold is now a pure function of the container's real width,
// applied identically to every one of the 14 themes. The Appearance grid
// needed no change of its own: it already derived its column count purely
// from `appearanceContainer.frame.width`, so once that width stopped
// depending on which theme was active, the grid's density stopped too.
//
// **A real, separate, and deliberately UNCHANGED source of a few points of
// vertical noise, found while building this suite.** `HelmCard.applyTheme`
// (`HelmDesignSystem.swift`) sets `headerTitle?.font = theme.isDaylight ?
// HelmType.cardTitle() : HelmType.sectionTitle()` - Daylight's card headers
// render at 13.5pt, every other theme's at 15pt. That is a pre-existing,
// deliberate, app-WIDE typographic decision from the original Daylight
// migration (`HelmType`'s "type scale by role"), applied to every `HelmCard`
// in the entire application, not something introduced by - or specific to -
// the bug this task fixes. It shifts a card's own header row height by a
// point or two, which can nudge a card's Y-origin within its column by a
// handful of points once accumulated down a column of several cards. That is
// NOT what either screenshot showed (a two-column page becoming one-column,
// or a half-width theme grid becoming full-width) and fixing it would mean
// re-deriving the shared `HelmCard` typography used across dozens of
// unrelated pages - well outside this task's "pure layout-consistency fix"
// scope, and a real risk to a long-established, intentional design decision.
// So this suite asserts card COUNT, WIDTH, X-POSITION (i.e. column
// assignment), the ORDER of the cards within each column, and the Appearance
// grid's own column DENSITY - all exactly. It does NOT compare a card's
// absolute Y origin: that moves with the same sanctioned font-metric
// difference, and on a CI runner it also moved between two mounts of the *same*
// theme, so it never was a theme-parity property. See `structurallyEqual`'s own
// comment for the full account, and for why re-tightening it would only bring
// the false failures back.
//
// Run with:
//   swift build && FM_RUN_SETTINGS_THEME_LAYOUT_PARITY_TESTS=1 \
//     .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum SettingsThemeLayoutParitySelfTest {

    static func run() -> Bool {
        // A suite that changes the active theme MUST put it back - see
        // `Phase3PolishSelfTest.checkSuitesRestoreTheTheme`'s header for why
        // a theme left behind poisons every suite that runs after this one
        // in the same `run-all-tests.sh` pass.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        var allOK = true
        for check in [checkFingerprintMatchesAtWideWidth,
                      checkFingerprintMatchesAtNarrowWidth,
                      checkFingerprintMatchesAcrossAllThemes] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "SettingsThemeLayoutParitySelfTest: all checks passed"
                    : "SettingsThemeLayoutParitySelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static var daylightTheme: HelmTheme {
        HelmTheme.allThemes.first { $0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    private static var legacyTheme: HelmTheme {
        HelmTheme.allThemes.first { !$0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    /// Scratch store files, so nothing here can reach the captain's real data
    /// (the convention every store-backed suite in this repo follows).
    private static func scratchStores() -> (HostStore, SSHKeyStore, SnippetStore, DictationStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-theme-parity-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_DICTATION_DIR", dir.appendingPathComponent("dictation").path, 1)
        return (HostStore(), SSHKeyStore(), SnippetStore(), DictationStore())
    }

    private static func makeSettings() -> SettingsController {
        let (hosts, keys, snippets, dictation) = scratchStores()
        return SettingsController(hostStore: hosts, keyStore: keys,
                                  snippetStore: snippets, dictationStore: dictation)
    }

    private static func mount(_ controller: NSViewController, width: CGFloat) -> NSWindow {
        let window = OffScreenProbe.window(width: width, height: 900)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// Rounded to a tenth of a point - tight enough to catch a real
    /// structural difference (halved widths, a different column count, a
    /// shifted origin) while tolerant of ordinary Auto Layout sub-pixel
    /// rounding noise between two otherwise-identical layout passes.
    private static func rounded(_ v: CGFloat) -> CGFloat { (v * 10).rounded() / 10 }

    /// Everything about a mounted Settings page that is supposed to be a
    /// pure function of layout width - never of which theme is active.
    /// Deliberately carries no colour of any kind, and deliberately keeps X
    /// (column assignment) and Y (vertical position within a column) as
    /// separate arrays rather than one array of `CGPoint`s, since the two are
    /// asserted differently - see `structurallyEqual`'s own comment.
    private struct LayoutFingerprint {
        let cardCount: Int
        /// How many cards each category's detail pane mounted, in
        /// `Category.allCases` order. The sidebar redesign's structural
        /// claim: the page's navigation shape is the same on every theme.
        let paneSizes: [Int]
        /// Each card's resolved width, in `cardsInOrder` reading order.
        let cardWidths: [CGFloat]
        /// Each card's leading (X) edge, converted into the page's own
        /// coordinate space, in `cardsInOrder` reading order - this is what
        /// proves "the same cards sit in the same columns", independent of
        /// how tall any individual card's header happens to render.
        let cardXPositions: [CGFloat]
        /// Each card's Y-origin, same order and coordinate space as
        /// `cardXPositions`. Used only to derive each column's top-to-bottom
        /// card order, never compared as a value - see `structurallyEqual`.
        let cardYPositions: [CGFloat]
        /// The Appearance card's theme-picker grid: one entry per row, the
        /// column count `.fillEqually` divided that row into (dark-theme
        /// rows first, then light, per `rebuildAppearanceGrid`'s own
        /// grouping - see `debugAppearanceGridColumnCounts`'s header). This
        /// is the grid-density half of the reported bug: it used to be half
        /// as many columns wide on a legacy theme as on Daylight, at the
        /// exact same window width, because it derived its own width from
        /// whether the page had already split into two columns.
        let appearanceGridColumnCounts: [Int]
    }

    private static func fingerprint(for settings: SettingsController) -> LayoutFingerprint {
        // **Measured one category at a time**, because that is what the page
        // is now: a card is only laid out while its own pane is selected
        // (`fm/grandline-settings-page-sidebar-redesign` detaches the other
        // six categories rather than hiding them, per gotcha (15)). Sweeping
        // the sidebar here is what keeps every card measured, and it is also
        // the only way a suite can see that the panes themselves are
        // theme-independent.
        //
        // Geometry is read in each card's **own superview's** space - the
        // detail pane's stack. Scroll position is not layout, and this suite
        // compares layout: converting into the page's coordinate space folded
        // whatever offset happened to be current into every Y, which is what
        // CI kept reporting as a theme mismatch (mounts landing in one of two
        // states 171pt apart, with the *reference* theme flipping between
        // them on a re-measure - which no theme-dependent layout can do).
        var widths: [CGFloat] = []
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        var paneSizes: [Int] = []
        var gridColumns: [Int] = []
        for category in SettingsController.Category.allCases {
            settings.select(category)
            settings.view.layoutSubtreeIfNeeded()
            let mounted = settings.debugMountedGroupCards
            paneSizes.append(mounted.count)
            for card in mounted {
                widths.append(rounded(card.frame.width))
                xs.append(rounded(card.frame.origin.x))
                ys.append(rounded(card.frame.origin.y))
            }
            if category == .appearance { gridColumns = settings.debugAppearanceGridColumnCounts }
        }
        return LayoutFingerprint(
            cardCount: settings.debugGroupCards.count,
            paneSizes: paneSizes,
            cardWidths: widths,
            cardXPositions: xs,
            cardYPositions: ys,
            appearanceGridColumnCounts: gridColumns
        )
    }

    /// Mounts a fresh Settings page under `theme` at `width` and returns its
    /// fingerprint. The window is returned too, so the caller can keep it
    /// alive for the duration of the comparison (an unretained `NSWindow`
    /// can tear its content view down under the fingerprint it just produced).
    private static func fingerprint(theme: HelmTheme, width: CGFloat) -> (LayoutFingerprint, NSWindow) {
        ThemeManager.shared.setTheme(theme)
        let settings = makeSettings()
        let window = mount(settings, width: width)
        return (settledFingerprint(for: settings), window)
    }

    /// The fingerprint once the page has stopped changing height on its own.
    ///
    /// Several Settings cards finish filling themselves in *asynchronously* -
    /// the Security card's sudo status shells out, the Backup card reads its
    /// last-export state off disk - and each of those changes a card's height
    /// when it lands. Measuring immediately after `mount` therefore captures
    /// whichever of those had happened to complete by then, which depends on
    /// how much run-loop time this process happened to have taken since, not
    /// on the theme.
    ///
    /// That made this suite genuinely timing-dependent, and it showed: on a CI
    /// runner (where those subprocess-backed checks are slower) the first
    /// controller built in a case measured ~170pt taller than the next four,
    /// and then agreed again with the rest - a transient, not a layout
    /// difference. Settling first is what makes the comparison about the
    /// theme, which is the only thing this suite is meant to be about.
    /// How many consecutive identical reads count as settled.
    ///
    /// **One is not enough, and that is a lesson this repo has already paid
    /// for once** (`fm/grandline-audit2-e2e-fixes`, on the console's own
    /// settle): "two consecutive equal reads" cannot tell *settled* from
    /// *paused between two async updates*, and the gap between this page's
    /// staggered async fills - a `sudo` probe, a disk read - is comfortably
    /// wider than one poll interval on a loaded runner. This suite grew a
    /// seventh card in `fm/grand-line-terminal-shortcuts-settings`, i.e. more
    /// async work and a longer stagger, and CI reported exactly the shape a
    /// mid-flight read produces: two themes whose widths differ by a few
    /// points while every structural property matches.
    ///
    /// Strengthening the settle rather than loosening the comparison, on
    /// purpose: the width check is this suite's whole point.
    private static let stableReadsRequired = 5

    private static func settledFingerprint(for settings: SettingsController) -> LayoutFingerprint {
        var previous = fingerprint(for: settings)
        var stable = 0
        for _ in 0..<60 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            settings.view.layoutSubtreeIfNeeded()
            let current = fingerprint(for: settings)
            if current.cardYPositions == previous.cardYPositions,
               current.cardWidths == previous.cardWidths,
               current.cardXPositions == previous.cardXPositions {
                stable += 1
                if stable >= stableReadsRequired { return current }
            } else {
                stable = 0
            }
            previous = current
        }
        return previous
    }

    private static func describe(_ fp: LayoutFingerprint) -> String {
        "cards=\(fp.cardCount) panes=\(fp.paneSizes) widths=\(fp.cardWidths) " +
        "x=\(fp.cardXPositions) y=\(fp.cardYPositions) grid=\(fp.appearanceGridColumnCounts)"
    }

    /// The actual comparison.
    ///
    /// **Card count, width, column assignment (X) and the Appearance grid's
    /// density are compared exactly; a card's Y *origin* is not compared at
    /// all, only its order within its own column.** That narrowing is the
    /// conclusion of chasing this suite through four CI failures, and it is
    /// worth stating so nobody re-tightens it:
    ///
    ///  - The captain-reported bug this suite was written for (#286) was
    ///    *structural*: a two-column page becoming one-column, and a
    ///    half-width theme grid becoming full-width. Every part of that is
    ///    caught by count / width / X / grid density - confirmed by injection
    ///    (restoring the `theme.isDaylight` condition on the two-column
    ///    decision fails all three cases of this suite).
    ///  - A card's Y origin, by contrast, was never a theme-parity property in
    ///    practice. It moves with `HelmCard`'s own Daylight-vs-legacy header
    ///    title font (13.5pt vs 15pt - an app-wide typographic decision this
    ///    suite is explicitly not about, and which accumulates down a column),
    ///    and on a CI runner it also moved by ~171pt between two mounts **of
    ///    the same theme** - the reference theme flipping between two states on
    ///    a re-measure, which no theme-dependent layout can do. Neither a
    ///    tolerance nor pinning the scroll offset nor measuring in document
    ///    space closed that; all three left a number that says nothing about
    ///    the theme.
    ///
    /// Order within a column *is* asserted, because "the same cards in the same
    /// columns in the same reading order" is the structural claim, and unlike
    /// an absolute origin it is stable.
    private static func structurallyEqual(_ a: LayoutFingerprint, _ b: LayoutFingerprint) -> Bool {
        guard a.cardCount == b.cardCount,
              a.paneSizes == b.paneSizes,
              a.appearanceGridColumnCounts == b.appearanceGridColumnCounts,
              a.cardYPositions.count == b.cardYPositions.count,
              columnIndices(a) == columnIndices(b),
              widthShape(a) == widthShape(b),
              widthsAgreeWithinRunnerNoise(a, b)
        else { return false }
        return columnOrder(a) == columnOrder(b)
    }

    /// How wide the runner's own clip view is allowed to differ between two
    /// mounts, as a fraction of the wider card.
    ///
    /// **This is not a softening of what the suite catches**, and the number
    /// is chosen against the defect rather than against the noise. The bug
    /// this file exists for put a card at *half* the content width in one
    /// theme and the *full* width in the other, with the Appearance grid at a
    /// different column count - a 2x difference, and one that `paneSizes`,
    /// `columnIndices`, `widthShape` and the grid density each catch on their
    /// own, exactly, with no tolerance at all.
    ///
    /// What raw pixel equality additionally asserted was that both mounts
    /// happened to get the same **clip** width, which is not a property of the
    /// theme. Measured on a real CI runner (`fm/grand-line-terminal-shortcuts-
    /// settings`): the two themes' clip views came back 7pt apart out of 1500,
    /// so every card was 3pt narrower in one - while column assignment,
    /// ordering, card count and grid density all matched exactly. Measured
    /// locally, on the same code, both themes get a byte-identical clip width
    /// under *both* scroller regimes (overlay 1500/1500, legacy 1483/1483),
    /// which is what rules the scroller out as the theme-dependent part.
    private static let widthNoiseTolerance: CGFloat = 0.02

    private static func widthsAgreeWithinRunnerNoise(_ a: LayoutFingerprint, _ b: LayoutFingerprint) -> Bool {
        zip(a.cardWidths, b.cardWidths).allSatisfy { lhs, rhs in
            let wider = max(lhs, rhs)
            guard wider > 0 else { return lhs == rhs }
            return abs(lhs - rhs) / wider <= widthNoiseTolerance
        }
    }

    /// Which column each card is in, as an index rather than a raw X.
    ///
    /// The assignment is the structural fact - "Appearance is in the right
    /// column" - and it survives the whole page being a few points narrower.
    private static func columnIndices(_ fp: LayoutFingerprint) -> [Int] {
        let columns = Array(Set(fp.cardXPositions)).sorted()
        return fp.cardXPositions.map { columns.firstIndex(of: $0) ?? -1 }
    }

    /// Each card's width relative to the widest card on the page, to two
    /// decimals.
    ///
    /// This is the half-versus-full-width signal the original defect actually
    /// produced, stated in a form that does not care how wide the page is: a
    /// theme where every card matches reads `[1.0, 1.0, …]`, and one where a
    /// single card spans both columns reads `[0.5, …, 1.0, …]`.
    private static func widthShape(_ fp: LayoutFingerprint) -> [CGFloat] {
        guard let widest = fp.cardWidths.max(), widest > 0 else { return fp.cardWidths }
        return fp.cardWidths.map { ($0 / widest * 100).rounded() / 100 }
    }

    /// For each column (keyed by X), the card indices it holds, top to bottom.
    private static func columnOrder(_ fp: LayoutFingerprint) -> [Int: [Int]] {
        var byColumn: [Int: [(index: Int, y: CGFloat)]] = [:]
        for (index, column) in columnIndices(fp).enumerated() {
            byColumn[column, default: []].append((index, fp.cardYPositions[index]))
        }
        return byColumn.mapValues { entries in
            entries.sorted { $0.y < $1.y }.map(\.index)
        }
    }

    // MARK: 1. At a wide window

    private static func checkFingerprintMatchesAtWideWidth(_ ok: inout Bool) {
        print("\n-- a Daylight theme and a legacy theme produce an identical layout at 1500pt --")
        let (daylightFP, daylightWindow) = fingerprint(theme: daylightTheme, width: 1500)
        defer { _ = daylightWindow }
        let (legacyFP, legacyWindow) = fingerprint(theme: legacyTheme, width: 1500)
        defer { _ = legacyWindow }

        // Twelve since `fm/grandline-capture-global-hotkey-configurable` gave
        // universal capture's own chord a page, with a Shortcut card and a
        // System-wide access card. Ten since F21
        // (`fm/grandline-feature-f21-f24-intents-import-export`)
        // added the Shortcuts & Siri card; nine since F22
        // (`fm/grandline-feature-f22-menu-bar-mode`) added the
        // Compact mode card; eight since
        // `fm/grandline-feature-f20-daily-review-briefing` added Daily
        // review, and seven before that, since
        // `fm/grand-line-terminal-shortcuts-settings` added Terminal
        // Shortcuts. Kept as a literal for this check's own vacuity: "both
        // themes produced the same layout" means nothing if neither produced
        // a page - so the honest response to a card genuinely being added is
        // to move the literal and say which change moved it, not to relax it
        // into a `>=`.
        guard daylightFP.cardCount == 24 else {
            print("  FAIL Daylight built \(daylightFP.cardCount) cards, want 24")
            ok = false
            return
        }
        // Vacuity: "both themes produced the same panes" means nothing if
        // the panes were empty. Every category must have mounted at least
        // one card, and the seven must account for all ten.
        if daylightFP.paneSizes.contains(0) || daylightFP.paneSizes.reduce(0, +) != daylightFP.cardCount {
            print("  FAIL the panes do not partition the page's cards: \(daylightFP.paneSizes) over \(daylightFP.cardCount)")
            ok = false
        }
        if !structurallyEqual(daylightFP, legacyFP) {
            print("  FAIL layouts differ at 1500pt beyond the sanctioned header-font tolerance (only colours should ever differ):")
            print("    Daylight (\(daylightTheme.id)): \(describe(daylightFP))")
            print("    legacy   (\(legacyTheme.id)):   \(describe(legacyFP))")
            ok = false
        }
        if ok { print("  ok   \(daylightTheme.id) and \(legacyTheme.id) match: \(describe(daylightFP))") }
    }

    // MARK: 2. At a narrow window

    private static func checkFingerprintMatchesAtNarrowWidth(_ ok: inout Bool) {
        print("\n-- a Daylight theme and a legacy theme produce an identical layout at 820pt --")
        let (daylightFP, daylightWindow) = fingerprint(theme: daylightTheme, width: 820)
        defer { _ = daylightWindow }
        let (legacyFP, legacyWindow) = fingerprint(theme: legacyTheme, width: 820)
        defer { _ = legacyWindow }

        // The navigation shape does not change with the window's width
        // either - narrowing the page must not merge or drop a category.
        if daylightFP.paneSizes != legacyFP.paneSizes || daylightFP.paneSizes.contains(0) {
            print("  FAIL the panes differ or are empty at 820pt (Daylight=\(daylightFP.paneSizes), legacy=\(legacyFP.paneSizes))")
            ok = false
        }
        if !structurallyEqual(daylightFP, legacyFP) {
            print("  FAIL layouts differ at 820pt beyond the sanctioned header-font tolerance (only colours should ever differ):")
            print("    Daylight (\(daylightTheme.id)): \(describe(daylightFP))")
            print("    legacy   (\(legacyTheme.id)):   \(describe(legacyFP))")
            ok = false
        }
        if ok { print("  ok   \(daylightTheme.id) and \(legacyTheme.id) match: \(describe(daylightFP))") }
    }

    // MARK: 3. Every one of the 14 themes, not just the two representatives

    private static func checkFingerprintMatchesAcrossAllThemes(_ ok: inout Bool) {
        print("\n-- every theme resolves to the same layout structure at a fixed width --")
        guard let first = HelmTheme.allThemes.first else {
            print("  FAIL HelmTheme.allThemes is empty")
            ok = false
            return
        }
        let (reference, referenceWindow) = fingerprint(theme: first, width: 1400)
        defer { _ = referenceWindow }
        var mismatches: [String] = []
        var windows: [NSWindow] = []
        for theme in HelmTheme.allThemes.dropFirst() {
            let (fp, window) = fingerprint(theme: theme, width: 1400)
            windows.append(window)
            guard !structurallyEqual(reference, fp) else { continue }
            // Re-measure once, fresh, before calling it a mismatch.
            //
            // What this suite asserts is a pure function of theme and width,
            // so a real difference reproduces every time. Several Settings
            // cards, though, finish filling themselves in asynchronously (the
            // Security card's sudo status shells out; the Backup card reads
            // its last-export state off disk), and each changes a card's
            // height when it lands - so a page measured mid-settle reports a
            // height that has nothing to do with its theme. That was already
            // true before this pass; CI saw it as four consecutive themes
            // disagreeing by ~170pt in Y while every width, X and column count
            // matched exactly, and then agreeing again for the rest - a
            // transient, and not a shape any real layout difference takes.
            //
            // A second measurement costs one extra mount on the failing path
            // only, and turns "flaky" into "reproducible or not a finding".
            let (retry, retryWindow) = fingerprint(theme: theme, width: 1400)
            windows.append(retryWindow)
            let (referenceRetry, referenceRetryWindow) = fingerprint(theme: first, width: 1400)
            windows.append(referenceRetryWindow)
            if !structurallyEqual(referenceRetry, retry) {
                mismatches.append("\(theme.id): \(describe(retry)) [reference on re-measure: \(describe(referenceRetry))]")
            }
        }
        defer { _ = windows }
        if !mismatches.isEmpty {
            print("  FAIL \(mismatches.count) of \(HelmTheme.allThemes.count - 1) other themes disagree with \(first.id)'s layout:")
            for line in mismatches { print("    \(line)") }
            print("    reference (\(first.id)): \(describe(reference))")
            ok = false
        }
        if ok { print("  ok   all \(HelmTheme.allThemes.count) themes at 1400pt share one structure: \(describe(reference))") }
    }
}

#endif
