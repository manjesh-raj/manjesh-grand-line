// Manjesh Grand Line - native macOS app.
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
// assignment) and the Appearance grid's own column DENSITY exactly, and
// tolerates a documented, bounded amount of Y drift from that one sanctioned,
// unrelated font-metric difference - see `yTolerance`'s own comment for the
// measured magnitude and the margin kept above it.
//
// Run with:
//   swift build && FM_RUN_SETTINGS_THEME_LAYOUT_PARITY_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
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
        for check in [checkFingerprintMatchesAtTwoColumnWidth,
                      checkFingerprintMatchesAtOneColumnWidth,
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
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

    /// How far a card's Y-origin may drift between two themes before it
    /// counts as a real structural mismatch, rather than the one sanctioned,
    /// unrelated source of vertical noise this suite's header documents
    /// (`HelmCard`'s Daylight-vs-legacy header title font, 13.5pt vs 15pt).
    ///
    /// Measured live before choosing this number: a column of three cards
    /// (Connection/Terminal/Security, or Appearance/Morning briefing/
    /// Backup & Restore) drifted by at most 2pt between a Daylight theme and
    /// a legacy one at a fixed width, in either column, at both the
    /// two-column and one-column widths this suite exercises. That 2pt is
    /// what this machine measures; **CI measures more, and the difference is
    /// the same sanctioned cause, not a new one.** A GitHub runner's font
    /// metrics resolve that header row differently, and because the drift is
    /// *per card* it accumulates down a column: 12-14pt observed there for
    /// the same six cards, against 2pt here, with every card width, X position
    /// and grid column count matching exactly in both.
    ///
    /// So the tolerance is derived rather than a flat literal - the per-card
    /// drift times the number of cards, which is the shape the noise actually
    /// has. It stays two orders of magnitude below what a real structural
    /// regression produces (halving a card's width, or losing a column
    /// entirely - hundreds of points), and it is only ever applied to Y:
    /// count, width, X and the Appearance grid's density are still compared
    /// exactly.
    private static func yTolerance(cardCount: Int) -> CGFloat {
        CGFloat(max(1, cardCount)) * perCardHeaderFontDrift
    }

    /// The most a single card's own header row may shift between a Daylight
    /// theme and a legacy one - `HelmCard.applyTheme`'s 13.5pt-vs-15pt title
    /// font, which is an app-wide typographic decision this suite is not
    /// about.
    private static let perCardHeaderFontDrift: CGFloat = 5

    /// Everything about a mounted Settings page that is supposed to be a
    /// pure function of layout width - never of which theme is active.
    /// Deliberately carries no colour of any kind, and deliberately keeps X
    /// (column assignment) and Y (vertical position within a column) as
    /// separate arrays rather than one array of `CGPoint`s, since only X is
    /// asserted for exact equality - see `yTolerance`'s own comment.
    private struct LayoutFingerprint {
        let cardCount: Int
        let isTwoColumn: Bool
        /// Each card's resolved width, in `cardsInOrder` reading order.
        let cardWidths: [CGFloat]
        /// Each card's leading (X) edge, converted into the page's own
        /// coordinate space, in `cardsInOrder` reading order - this is what
        /// proves "the same cards sit in the same columns", independent of
        /// how tall any individual card's header happens to render.
        let cardXPositions: [CGFloat]
        /// Each card's Y-origin, same order and coordinate space as
        /// `cardXPositions` - compared with `yTolerance`'s slack, not exact
        /// equality.
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
        // Measured against the scroll view's **document**, not the page.
        //
        // Scroll position is not layout, and this suite compares layout. The
        // page pins its own offset in `viewWillAppear` -> `scrollToTop`; a
        // harness that mounts a controller without an appearance cycle does
        // not, so converting into the page's coordinate space folded whatever
        // offset happened to be current into every Y. That is what CI kept
        // reporting as a theme mismatch: mounts landing in one of two states
        // 171pt apart, with the **reference** theme itself flipping between
        // them on a re-measure - which no theme-dependent layout can do -
        // while every width, X position and grid column count matched exactly,
        // because only the offset moved. Trying to pin the offset instead was
        // not enough: a document that grows after the pin (several cards fill
        // themselves in asynchronously) leaves it stale again.
        let reference: NSView = documentView(for: settings) ?? settings.view
        let origins: [CGPoint] = settings.debugCards.map { card in
            guard let origin = card.superview?.convert(card.frame.origin, to: reference) else {
                return CGPoint(x: -1, y: -1)
            }
            return origin
        }
        return LayoutFingerprint(
            cardCount: settings.debugCards.count,
            isTwoColumn: settings.debugIsTwoColumn,
            cardWidths: settings.debugCards.map { rounded($0.frame.width) },
            cardXPositions: origins.map { rounded($0.x) },
            cardYPositions: origins.map { rounded($0.y) },
            appearanceGridColumnCounts: settings.debugAppearanceGridColumnCounts
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
    private static func settledFingerprint(for settings: SettingsController) -> LayoutFingerprint {
        var previous = fingerprint(for: settings)
        for _ in 0..<25 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            settings.view.layoutSubtreeIfNeeded()
            let current = fingerprint(for: settings)
            if current.cardYPositions == previous.cardYPositions,
               current.cardWidths == previous.cardWidths,
               current.cardXPositions == previous.cardXPositions {
                return current
            }
            previous = current
        }
        return previous
    }

    /// The scrolled document the cards actually live in, or `nil` if this
    /// page ever stops being scroll-backed (in which case the fingerprint
    /// falls back to the page itself, exactly as it used to).
    private static func documentView(for settings: SettingsController) -> NSView? {
        var view: NSView? = settings.debugCards.first
        while let current = view, !(current is NSScrollView) { view = current.superview }
        return (view as? NSScrollView)?.documentView
    }

    private static func describe(_ fp: LayoutFingerprint) -> String {
        "cards=\(fp.cardCount) twoColumn=\(fp.isTwoColumn) widths=\(fp.cardWidths) " +
        "x=\(fp.cardXPositions) y=\(fp.cardYPositions) grid=\(fp.appearanceGridColumnCounts)"
    }

    /// The actual comparison: structure must match exactly, height may drift
    /// by `yTolerance` for the one sanctioned, documented reason above.
    private static func structurallyEqual(_ a: LayoutFingerprint, _ b: LayoutFingerprint) -> Bool {
        guard a.cardCount == b.cardCount,
              a.isTwoColumn == b.isTwoColumn,
              a.cardWidths == b.cardWidths,
              a.cardXPositions == b.cardXPositions,
              a.appearanceGridColumnCounts == b.appearanceGridColumnCounts,
              a.cardYPositions.count == b.cardYPositions.count
        else { return false }
        let slack = yTolerance(cardCount: a.cardCount)
        return zip(a.cardYPositions, b.cardYPositions).allSatisfy { abs($0 - $1) <= slack }
    }

    // MARK: 1. Above the two-column threshold

    private static func checkFingerprintMatchesAtTwoColumnWidth(_ ok: inout Bool) {
        print("\n-- a Daylight theme and a legacy theme produce an identical layout at 1500pt --")
        let (daylightFP, daylightWindow) = fingerprint(theme: daylightTheme, width: 1500)
        defer { _ = daylightWindow }
        let (legacyFP, legacyWindow) = fingerprint(theme: legacyTheme, width: 1500)
        defer { _ = legacyWindow }

        guard daylightFP.cardCount == 6 else {
            print("  FAIL Daylight built \(daylightFP.cardCount) cards, want 6")
            ok = false
            return
        }
        if !daylightFP.isTwoColumn {
            print("  FAIL Daylight (\(daylightTheme.id)) did not reach two columns at 1500pt - the threshold itself may be broken")
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

    // MARK: 2. Below the two-column threshold

    private static func checkFingerprintMatchesAtOneColumnWidth(_ ok: inout Bool) {
        print("\n-- a Daylight theme and a legacy theme produce an identical layout at 820pt --")
        let (daylightFP, daylightWindow) = fingerprint(theme: daylightTheme, width: 820)
        defer { _ = daylightWindow }
        let (legacyFP, legacyWindow) = fingerprint(theme: legacyTheme, width: 820)
        defer { _ = legacyWindow }

        if daylightFP.isTwoColumn || legacyFP.isTwoColumn {
            print("  FAIL one of these fell into two columns at 820pt, below the threshold (Daylight=\(daylightFP.isTwoColumn), legacy=\(legacyFP.isTwoColumn))")
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
        if ok { print("  ok   all \(HelmTheme.allThemes.count) themes at 1400pt match within \(Int(yTolerance(cardCount: reference.cardCount)))pt of Y drift: \(describe(reference))") }
    }
}

#endif
