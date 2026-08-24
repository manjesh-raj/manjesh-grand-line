// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for this app's colour-contrast floors,
// added by `fm/grandline-design-audit-phase0` so the three contrast defects
// that phase fixed (the full-app UI audit's §5.7 shared pill, §5.3 system
// text colours, and §7 item 7's `HelmTheme.mutedInk` constant) cannot
// silently regress the next time a theme or a `HelmTint` is added.
// `fm/grandline-design-system-phase2` added `HelmButton`'s two checks (every
// variant's label against its own fill, and a source guard against the stock
// bezel coming back) for the same reason.
// `FM_RUN_CONTRAST_TESTS=1 .build/debug/FirstmateCockpit`.
//
// It is the audit's own probe made permanent: the same WCAG maths
// (`HelmContrast`, itself the same sRGB -> linear -> 0.2126R + 0.7152G +
// 0.0722B formula `HelmTheme.swift`'s header and the vendored
// `Dimming.swift` document) run over every real `HelmTheme.allThemes`
// palette rather than the handful the original report sampled.
//
// Pure logic - no window, no view tree, no timing. The rendering half (that
// a real pill/tile on a real page actually paints these colours) is verified
// with a temporary off-screen-render probe per this repo's "Verifying native
// UI bugs without a real screenshot" convention, not here.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

/// `HelmButton.Variant`'s cases with the one fact the contrast sweep needs
/// that the enum itself does not carry: whether the variant paints a fill of
/// its own (so its label is scored against that) or is transparent (so its
/// label is scored against the surfaces it can sit on).
private enum HelmButtonVariantsUnderTest {
    static let all: [(variant: HelmButton.Variant, name: String, paintsFill: Bool)] = [
        (.primary, "primary", true),
        (.secondary, "secondary", true),
        (.quiet, "quiet", false),
        (.destructive, "destructive", true),
    ]
}

enum HelmContrastSelfTest {
    /// Every hue a tinted component can be given, by the name it reads as in
    /// the audit's own tables.
    private static let hues: [(String, (HelmTheme) -> String)] = [
        ("red", { $0.ansiHex[1] }),
        ("green", { $0.ansiHex[2] }),
        ("amber", { $0.ansiHex[3] }),
        ("blue", { $0.ansiHex[4] }),
        ("violet", { $0.ansiHex[5] }),
        ("accent", { $0.accentHex }),
        ("neutral", { $0.chromeInkHex }),
    ]

    static func run() -> Bool {
        var ok = true
        print("== Helm contrast self-test: \(HelmTheme.allThemes.count) themes x \(hues.count) hues ==")
        checkPills(&ok)
        checkIconTiles(&ok)
        checkMutedInk(&ok)
        checkNoSystemTextColors(&ok)
        checkButtonVariants(&ok)
        checkNoStockBezels(&ok)
        checkAccentRowRecipe(&ok)
        checkNoHandRolledKickers(&ok)
        checkStatusColumnAligned(&ok)
        checkStatTileRecipe(&ok)
        checkEmptyStateRecipe(&ok)
        checkSegmentedTabsRecipe(&ok)
        checkFieldRecipe(&ok)
        checkNoReDerivedFieldChrome(&ok)
        checkNoRawTextInputs(&ok)
        checkPageToolbarRecipe(&ok)
        checkResponsiveGrid(&ok)
        checkPageTitleVoice(&ok)
        checkRowDoesNotResizeWindow(&ok)
        checkSetupFlyoutTintsAreDistinct(&ok)
        checkConsoleCardChromeGeometry(&ok)
        checkDaylightPalette(&ok)
        checkDuskPalette(&ok)
        checkDaylightDomainHues(&ok)
        checkDaylightRadiiScale(&ok)
        checkDaylightElevation(&ok)
        checkDaylightTypeRoles(&ok)
        checkGradientTileRecipe(&ok)
        checkTextSelectionContrast(&ok)
        print(ok ? "== contrast: PASS ==" : "== contrast: FAIL ==")
        return ok
    }

    // MARK: Text selection - normal *and* selected text, every theme

    /// `fm/grandline-text-selection-contrast-audit`.
    ///
    /// The captain reported selected text in the Console rendering as a muted
    /// dark red on a dark blue block in light mode - both dark, effectively
    /// illegible. Two mechanisms draw selected text in this app and they are
    /// genuinely separate, so both are swept here:
    ///
    /// 1. **The terminal.** SwiftTerm pairs `selectedTextBackgroundColor` with
    ///    `selectedTextForegroundColor` and `HelmTheme.apply(to:)` fills both
    ///    from `selectionHex`/`selectionTextHex`. That pairing is what makes
    ///    the terminal's selection measurable, so the vendored override is
    ///    guarded as source too - a SwiftTerm re-sync that dropped it would
    ///    leave every selected run in its own ANSI colour on the selection
    ///    fill, which is exactly the reported shape and which no colour value
    ///    in this file could detect.
    ///
    /// 2. **`HelmSelection`** - every `NSTextView` this app owns, and (through
    ///    the shared field editor) every *selectable* `NSTextField`. Its fill
    ///    is opaque for the reason its own doc comment measures: a translucent
    ///    wash's effective colour depends on the surface underneath, and on
    ///    Daylight no single foreground clears the floor against both a light
    ///    field and §6.13's dark terminal card.
    ///
    /// Normal (unselected) text is swept alongside, because "legible when
    /// selected" is only half of what the captain asked for - and that half is
    /// what caught `solarized-light`'s shipped `base00`/`base3` body pairing
    /// at 4.13:1.
    private static func checkTextSelectionContrast(_ ok: inout Bool) {
        print("\n-- text selection (terminal + UI), normal and selected, every theme --")

        for theme in HelmTheme.allThemes {
            let fg = HelmTheme.nsColor(theme.foregroundHex)
            let bg = HelmTheme.nsColor(theme.backgroundHex)
            let selFill = HelmTheme.nsColor(theme.selectionHex)
            let selInk = HelmTheme.nsColor(theme.selectionTextHex)

            let normal = HelmContrast.ratio(fg, bg)
            let selected = HelmContrast.ratio(selInk, selFill)
            // A highlight nobody can see is not a highlight. Same floor the UI
            // side uses, and deliberately not WCAG's 3:1 non-text bar - see
            // `HelmSelection.minimumSurfaceSeparation`.
            let visible = HelmContrast.ratio(selFill, bg)

            if normal < HelmContrast.textTarget {
                print(String(format: "  FAIL %@: normal terminal text %.2f on its background (floor %.2f)",
                             theme.id, normal, HelmContrast.textTarget))
                ok = false
            }
            if selected < HelmContrast.textTarget {
                print(String(format: "  FAIL %@: selected terminal text %.2f on the selection fill (floor %.2f)",
                             theme.id, selected, HelmContrast.textTarget))
                ok = false
            }
            if visible < HelmSelection.minimumSurfaceSeparation {
                print(String(format: "  FAIL %@: terminal selection fill %.2f from the terminal background (floor %.2f)",
                             theme.id, visible, HelmSelection.minimumSurfaceSeparation))
                ok = false
            }
            print(String(format: "  %-18@ terminal  normal %.2f  selected %.2f  fill-vs-bg %.2f",
                         theme.id as NSString, normal, selected, visible))
        }

        for theme in HelmTheme.allThemes {
            let resolved = HelmSelection.resolve(theme)
            let fill = resolved.background
            let ink = resolved.foreground

            // Opaque by contract: the whole point of the fix is that the drawn
            // colour - and therefore the measured pair - does not depend on
            // whatever is underneath.
            if (fill.usingColorSpace(.sRGB)?.alphaComponent ?? 0) < 0.999 {
                print("  FAIL \(theme.id): UI selection fill is translucent - the pair is not measurable")
                ok = false
            }
            if fill == NSColor.selectedTextBackgroundColor {
                print("  FAIL \(theme.id): UI selection is the system colour, not the theme's")
                ok = false
            }

            let selected = HelmContrast.ratio(ink, fill)
            if selected < HelmContrast.textTarget {
                print(String(format: "  FAIL %@: selected UI text %.2f on the selection fill (floor %.2f)",
                             theme.id, selected, HelmContrast.textTarget))
                ok = false
            }
            var worstSurface = Double.greatestFiniteMagnitude
            for surface in HelmSelection.surfaces(theme) {
                worstSurface = min(worstSurface, HelmContrast.ratio(fill, surface))
            }
            if worstSurface < HelmSelection.minimumSurfaceSeparation {
                print(String(format: "  FAIL %@: UI selection fill %.2f from the surface under it (floor %.2f)",
                             theme.id, worstSurface, HelmSelection.minimumSurfaceSeparation))
                ok = false
            }
            print(String(format: "  %-18@ UI        selected %.2f  fill-vs-surface %.2f  wash %.2f",
                         theme.id as NSString, selected, worstSurface, Double(resolved.washAlpha)))
        }

        checkEveryTextViewIsThemed(&ok)
        checkVendoredTerminalPairsSelection(&ok)
    }

    /// Source guard: an app-owned `NSTextView` left on AppKit's own selection
    /// paints `NSColor.selectedTextBackgroundColor` behind the run **and sets
    /// no foreground at all**, so the text keeps whatever colour it already
    /// had. That is unbounded by construction, and is how a maroon severity
    /// run ends up on a dark blue block. Before this audit only 3 of the ~13
    /// app-owned text views reached `HelmSelection`.
    private static func checkEveryTextViewIsThemed(_ ok: inout Bool) {
        guard let files = SelfTestSources.appSourceFiles() else {
            print("  SKIP - sources not present next to this binary")
            return
        }
        // `HelmForm.swift` and `HelmInput.swift` are where the mechanism
        // lives; both already apply it (and `HelmInput` names the token in
        // prose in order to define it).
        let exempt: Set<String> = ["HelmInput.swift"]
        var offenders: [String] = []
        for file in files where !exempt.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let makesTextView = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .contains { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return !t.hasPrefix("//") && t.contains("NSTextView(")
                }
            if makesTextView && !text.contains("HelmSelection") {
                offenders.append(file.lastPathComponent)
            }
        }
        if offenders.isEmpty {
            print("  OK - every file creating an NSTextView applies HelmSelection")
        } else {
            for o in offenders { print("  FAIL \(o): creates an NSTextView but never calls HelmSelection.apply") }
            ok = false
        }
    }

    /// The terminal's measured pair is only real while SwiftTerm actually
    /// overrides a selected run's foreground. This is vendored source, so a
    /// re-sync is the realistic way it disappears - and it would disappear
    /// silently, since every colour value in this file would keep passing.
    private static func checkVendoredTerminalPairsSelection(_ ok: inout Bool) {
        guard let root = SelfTestSources.appSourceDirectory() else {
            print("  SKIP - sources not present next to this binary")
            return
        }
        let file = root
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // native/
            .appendingPathComponent("Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            print("  SKIP - vendored AppleTerminalView.swift not found at \(file.path)")
            return
        }
        let pairsBackground = text.contains("mutable[.selectionBackgroundColor] = selectedTextBackgroundColor")
        let pairsForeground = text.contains("mutable[.foregroundColor] = selectedTextForegroundColor")
        if pairsBackground && pairsForeground {
            print("  OK - vendored SwiftTerm still pairs the selected run's foreground with selectedTextForegroundColor")
        } else {
            print("  FAIL - vendored SwiftTerm no longer overrides a selected run's colours "
                  + "(background: \(pairsBackground), foreground: \(pairsForeground)); "
                  + "selected terminal text would keep its own ANSI colour on the selection fill")
            ok = false
        }
    }

    // MARK: Setup flyout - one hue per destination

    /// `fm/grandline-sre-lead-and-setup-icons`: every Setup flyout row passed
    /// a hardcoded `.accent`, so Updates / Bootstrap / Automation / GitHub
    /// Sync all rendered the identical tile and the flyout read as one
    /// undifferentiated block (measured in a real render: all four glyphs
    /// sampled `rgb(165,218,229)` in `helm-dark`). Each now carries its own
    /// `RailDestination.flyoutTint`.
    ///
    /// This asserts the *mapping*, not the pixels - the four rows must resolve
    /// to four different `HelmTint` cases, so a future edit that collapses
    /// them back onto one shared tint fails the build rather than silently
    /// restoring the bug. Deliberately not asserting four distinct resolved
    /// hexes: `.accent` genuinely equals a neighbouring slot in 3 of the 12
    /// palettes (tokyo-night-dark/-light's blue, rose-pine-main's magenta),
    /// a known and documented trade-off recorded on `flyoutTint` itself.
    private static func checkSetupFlyoutTintsAreDistinct(_ ok: inout Bool) {
        print("\n-- setup flyout (one tint per destination) --")
        let rows: [RailDestination] = [.updates, .bootstrap, .automation, .githubSync]
        let tints = rows.map { $0.flyoutTint }
        let names = tints.map { String(describing: $0) }
        if Set(names).count != rows.count {
            print("  FAIL setup flyout rows share a tint: \(zip(rows.map { $0.title }, names).map { "\($0)=\($1)" })")
            ok = false
        } else {
            print("  OK - \(zip(rows.map { $0.title }, names).map { "\($0)=\($1)" }.joined(separator: ", "))")
        }

        // Every one of those hues must still clear the icon-tile floor in
        // every palette - `checkIconTiles` already sweeps all seven tints, so
        // this only guards that the four rows use tints that sweep covers.
        for theme in HelmTheme.allThemes {
            for (row, tint) in zip(rows, tints) {
                let hex = tint.hex(in: theme)
                if hex.isEmpty {
                    print("  FAIL \(theme.id) \(row.title): tint resolved to an empty hex")
                    ok = false
                }
            }
        }
    }

    // MARK: Console's SRE-Lead-active card chrome

    /// `fm/grandline-sre-lead-app-feel`: with SRE Lead up, Console draws the
    /// terminal as a card beside the SRE Lead panel. The card's whole reason
    /// for being drawable at all is that the terminal never moves - the card's
    /// leading/top/bottom edges have to land exactly on the terminal's own
    /// permanent inset, or the border floats in the padding (a gap) or sits
    /// over live text (clipping the first column).
    ///
    /// So this asserts the geometry contract rather than any colour: the drawn
    /// card lines up with `ConsoleController.terminalInset` on the three real
    /// edges, the two panels are separated by exactly one `HelmMetrics.s3`
    /// gap of workspace floor, and both panels sit the same distance from the
    /// window edge. Theme-independent by nature, so it runs once - the fill,
    /// border and elevation it uses are `HelmCard`'s own tokens, already swept
    /// per theme by `checkStatTileRecipe`/`checkPills` and by
    /// `HelmCard.applyCardSurface`'s single definition.
    private static func checkConsoleCardChromeGeometry(_ ok: inout Bool) {
        print("\n-- console card chrome (SRE Lead active) --")
        let pad = HelmMetrics.s3
        let paneWidth: CGFloat = 380
        let chrome = ConsoleCardChrome(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        chrome.pad = pad
        chrome.gap = pad

        // Closed: the card spans the full content width, inset by `pad` all
        // round - the degenerate case, and the one that proves the card edge
        // tracks the terminal's inset rather than a hardcoded number.
        chrome.paneStripWidth = nil
        let closed = chrome.terminalCardRect
        if closed != NSRect(x: pad, y: pad, width: 1200 - pad * 2, height: 700 - pad * 2) {
            print("  FAIL closed card rect \(closed) does not inset 1200x700 by \(pad) on all sides")
            ok = false
        }
        if chrome.paneCardRect != nil {
            print("  FAIL a pane card rect exists with no pane open")
            ok = false
        }

        // Open: two panels, one gap.
        chrome.paneStripWidth = paneWidth
        let card = chrome.terminalCardRect
        guard let pane = chrome.paneCardRect else {
            print("  FAIL no pane card rect with a pane open")
            ok = false
            return
        }
        var failures: [String] = []
        if card.minX != pad { failures.append("terminal card leading \(card.minX) != \(pad)") }
        if card.minY != pad { failures.append("terminal card bottom \(card.minY) != \(pad)") }
        if card.maxY != 700 - pad { failures.append("terminal card top \(card.maxY) != \(700 - pad)") }
        if pane.minY != card.minY || pane.maxY != card.maxY {
            failures.append("panels are not the same height: \(card) vs \(pane)")
        }
        if pane.maxX != 1200 - pad {
            failures.append("pane card trailing \(pane.maxX) != \(1200 - pad) (must match the terminal card's own \(pad)pt window margin)")
        }
        if pane.minX - card.maxX != pad {
            failures.append("workspace gap between the panels is \(pane.minX - card.maxX), expected exactly \(pad)")
        }
        // The pane card is what `ConsoleController` constrains inside the
        // 380pt backdrop strip: full strip width minus its own trailing pad.
        if pane.width != paneWidth - pad {
            failures.append("pane card width \(pane.width) != \(paneWidth - pad)")
        }
        if failures.isEmpty {
            print("  OK - terminal card \(card), pane card \(pane), gap \(pane.minX - card.maxX)pt")
        } else {
            for failure in failures { print("  FAIL \(failure)") }
            ok = false
        }

        // A window too small to hold either panel must degrade to an empty
        // rect rather than a negative-size one AppKit would then try to draw.
        let tiny = ConsoleCardChrome(frame: NSRect(x: 0, y: 0, width: 40, height: 10))
        tiny.pad = pad
        tiny.gap = pad
        tiny.paneStripWidth = paneWidth
        if !tiny.terminalCardRect.isEmpty || tiny.paneCardRect != nil {
            print("  FAIL a 40x10 content area produced non-empty card rects: \(tiny.terminalCardRect) / \(String(describing: tiny.paneCardRect))")
            ok = false
        }
    }

    // MARK: 1. The shared status pill (audit §5.7)

    /// `ToolRowLayout.pill` used to paint the label and the wash in the same
    /// hue, which fell below 4.5:1 in 44 of 72 theme/hue pairs. It now routes
    /// through `HelmContrast.tintedSurface`; this asserts the result clears
    /// the floor for every pair, against **both** surfaces a pill can land on.
    private static func checkPills(_ ok: inout Bool) {
        print("\n-- pills (target \(HelmContrast.textTarget):1, label vs its own fill) --")
        var unchanged = 0, adjusted = 0
        for theme in HelmTheme.allThemes {
            var cells: [String] = []
            for (name, hue) in hues {
                let hex = hue(theme)
                let resolved = HelmContrast.tintedSurface(tintHex: hex, theme: theme, target: HelmContrast.textTarget)
                let worst = worstRatio(foreground: resolved.foreground, tintHex: hex, theme: theme, wash: resolved.washAlpha)
                if worst < HelmContrast.textTarget - 0.01 {
                    print("  FAIL \(theme.id) \(name): \(fmt(worst)):1 at wash \(resolved.washAlpha)")
                    ok = false
                }
                // The raw hue as its own label is what the old code did -
                // count how often the fix actually had to change anything, so
                // a future reader can see it is not repainting the whole app.
                if HelmContrast.ratio(HelmTheme.nsColor(hex), resolved.fill) >= HelmContrast.textTarget {
                    unchanged += 1
                } else {
                    adjusted += 1
                }
                cells.append("\(name) \(fmt(worst))")
            }
            print("  \(pad(theme.id, 20)) \(cells.joined(separator: "  "))")
        }
        print("  hue/theme pairs whose raw hue already cleared the floor: \(unchanged); nudged toward ink: \(adjusted)")
    }

    // MARK: 2. Icon tiles (audit §5.7, "related, lower severity")

    /// A glyph is a non-text UI component, so the applicable floor is 3:1.
    /// `IconTileView.applyTheme` routes through the same helper.
    private static func checkIconTiles(_ ok: inout Bool) {
        print("\n-- icon tiles (target \(HelmContrast.nonTextTarget):1, glyph vs its own tile fill) --")
        for theme in HelmTheme.allThemes {
            var cells: [String] = []
            for (name, hue) in hues {
                let hex = hue(theme)
                let resolved = HelmContrast.tintedSurface(tintHex: hex, theme: theme,
                                                          target: HelmContrast.nonTextTarget,
                                                          washSteps: HelmContrast.tileWashSteps)
                let worst = worstRatio(foreground: resolved.foreground, tintHex: hex, theme: theme, wash: resolved.washAlpha)
                if worst < HelmContrast.nonTextTarget - 0.01 {
                    print("  FAIL \(theme.id) \(name): \(fmt(worst)):1 at wash \(resolved.washAlpha)")
                    ok = false
                }
                cells.append("\(name) \(fmt(worst))")
            }
            print("  \(pad(theme.id, 20)) \(cells.joined(separator: "  "))")
        }
    }

    // MARK: 3. The one muted-text token (audit §7 item 7)

    /// `HelmTheme.mutedInk` is the app's single muted/secondary text tone.
    /// Its alpha constant is only correct if it clears 4.5:1 on **both**
    /// surfaces real text sits on, in **every** palette - the original 0.7
    /// was measured against the first 8 palettes only, and the audit found
    /// gruvbox-light at 4.37 and tokyo-night-dark at 4.79 once the 10
    /// sourced-family themes landed.
    private static func checkMutedInk(_ ok: inout Bool) {
        print("\n-- HelmTheme.mutedInk (target \(HelmContrast.textTarget):1, on chrome + page background) --")
        for theme in HelmTheme.allThemes {
            let muted = HelmTheme.mutedInk(theme)
            let onChrome = flattenedRatio(muted, over: theme.chromeBackgroundHex)
            let onPage = flattenedRatio(muted, over: theme.backgroundHex)
            let worst = min(onChrome, onPage)
            let alpha = HelmTheme.mutedAlpha(for: theme)
            let raised = alpha > HelmTheme.baseMutedAlpha ? "  (raised from \(fmt(Double(HelmTheme.baseMutedAlpha))))" : ""
            if worst < HelmContrast.textTarget - 0.01 {
                print("  FAIL \(theme.id): chrome \(fmt(onChrome)) page \(fmt(onPage)) at alpha \(fmt(Double(alpha)))")
                ok = false
            }
            print("  \(pad(theme.id, 20)) chrome \(fmt(onChrome))  page \(fmt(onPage))  alpha \(fmt(Double(alpha)))\(raised)")
        }
    }

    // MARK: 4. No system text colours (audit §5.3)

    /// `.tertiaryLabelColor` fails 4.5:1 in every one of the 12 themes
    /// (measured as low as 1.86:1) and `.secondaryLabelColor` fails in the
    /// light ones, because both are fixed system greys that know nothing
    /// about the active `HelmTheme`. Phase 0 replaced all 36 sites with
    /// `HelmTheme.mutedInk` / `chromeInkHex`; this keeps them gone.
    ///
    /// A source scan rather than a colour measurement, because the defect is
    /// "this token is used at all", not "this token measures badly" - the
    /// measurement is printed alongside so the reason stays visible. Uses
    /// `#filePath` to find the sources, and *skips* (rather than fails) when
    /// they are not present, so a relocated/packaged binary running the other
    /// checks does not report a false failure.
    private static func checkNoSystemTextColors(_ ok: inout Bool) {
        print("\n-- system text colours (must not appear in Sources/) --")
        // Measured under the appearance each theme forces on its own views
        // (`ThemeManager.swift`'s checklist), which is the fairest reading of
        // these tokens - they still fail, because they are fixed system greys
        // that know nothing about which Helm palette is active.
        for theme in HelmTheme.allThemes {
            let appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            var t = 0.0, s = 0.0
            let measure = {
                t = flattenedRatio(.tertiaryLabelColor, over: theme.chromeBackgroundHex)
                s = flattenedRatio(.secondaryLabelColor, over: theme.chromeBackgroundHex)
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(measure) } else { measure() }
            print("  (why) \(pad(theme.id, 18)) .tertiaryLabelColor \(fmt(t))  .secondaryLabelColor \(fmt(s))")
        }
        let sourcesDir = SelfTestSources.appSourceDirectory() ?? URL(fileURLWithPath: "/nonexistent")
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP - sources not present next to this binary (\(sourcesDir.path))")
            return
        }
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            // This file names both tokens in prose above; exclude itself.
            if file.lastPathComponent == "HelmContrastSelfTest.swift" { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for token in [".tertiaryLabelColor", ".secondaryLabelColor"] where line.contains(token) {
                    offenders.append("\(file.lastPathComponent):\(n + 1) \(token)")
                }
            }
        }
        if offenders.isEmpty {
            print("  OK - no .tertiaryLabelColor / .secondaryLabelColor text sites")
        } else {
            for o in offenders { print("  FAIL \(o)") }
            print("  \(offenders.count) system-colour text site(s) - use HelmTheme.mutedInk / chromeInkHex instead")
            ok = false
        }
    }

    // MARK: 5. `HelmButton`'s four variants (audit §3.2 "Buttons", §6.3 #3)

    /// Every variant's label has to clear the text floor against the fill that
    /// variant actually paints, in every palette - including the two the audit
    /// singled out as the risky ones:
    ///
    /// - `.primary` is an opaque `accentHex` fill with a `selectionTextHex`
    ///   label. That pairing is borrowed from SwiftTerm's own selected-text
    ///   tone, so it *should* be safe by construction - this asserts it rather
    ///   than assuming it, which is the whole point of Phase 0's rule.
    /// - `.destructive` puts a tint hue's own label on a wash of itself, which
    ///   is exactly the shape §5.7 measured failing in 44 of 72 pairs. It goes
    ///   through `HelmContrast.tintedSurface`; this proves that holds.
    private static func checkButtonVariants(_ ok: inout Bool) {
        print("\n-- HelmButton variants (target \(HelmContrast.textTarget):1, label vs its own fill) --")
        // The system colours the audit measured stock buttons painting. A
        // variant fill must never resolve to one of these in any theme.
        let systemChrome = [NSColor.controlAccentColor,
                            NSColor.selectedContentBackgroundColor].map(HelmContrast.components)
        for theme in HelmTheme.allThemes {
            var cells: [String] = []
            for variant in HelmButtonVariantsUnderTest.all {
                let p = HelmButton.palette(variant: variant.variant, tint: nil, theme: theme)
                // `.quiet` paints no fill of its own, so score its label
                // against both surfaces it can sit on, like a pill.
                let backdrops: [(String, NSColor)] = variant.paintsFill
                    ? [("fill", p.fill)]
                    : [("card", HelmTheme.nsColor(theme.chromeBackgroundHex)),
                       ("page", HelmTheme.nsColor(theme.backgroundHex))]
                var worst = Double.greatestFiniteMagnitude
                for (name, backdrop) in backdrops {
                    let r = HelmContrast.ratio(p.label, backdrop)
                    worst = min(worst, r)
                    if r < HelmContrast.textTarget - 0.01 {
                        print("  FAIL \(theme.id) .\(variant.name) label on \(name): \(fmt(r)):1")
                        ok = false
                    }
                }
                if variant.paintsFill {
                    let fill = HelmContrast.components(p.fill)
                    for system in systemChrome where abs(fill.0 - system.0) < 0.02
                        && abs(fill.1 - system.1) < 0.02 && abs(fill.2 - system.2) < 0.02 {
                        print("  FAIL \(theme.id) .\(variant.name): fill is macOS system chrome, not the palette")
                        ok = false
                    }
                }
                cells.append("\(variant.name) \(fmt(worst))")
            }
            // The one hard identity: a primary action is the theme's accent -
            // unless a white label cannot live on that accent, in which case
            // it is the *smallest* darkening of it that a white label can live
            // on, and nothing else.
            //
            // Phase 6 is why this has two branches. Dusk's `accentHex` is a
            // light blue (`6A8DED`), because on that theme the accent is also
            // a label colour on a dark ground; a white button label on it
            // measures 3.16:1. §2.4's own implementation rule for this case is
            // that the **fill** darkens rather than the label changing, so
            // that is what is asserted - including that the accent genuinely
            // fails, so the exception can never quietly widen to a theme whose
            // accent was fine all along.
            let primaryFill = HelmButton.palette(variant: .primary, tint: nil, theme: theme).fill
            let accent = HelmTheme.nsColor(theme.accentHex)
            let whiteOnAccent = HelmContrast.ratio(.white, accent)
            // Only the Daylight family hardcodes a **white** primary label
            // (§6.6); the other 12 pair their accent with their own
            // `selectionTextHex`, so a white-label measurement says nothing
            // about them and their fill must be the accent, full stop.
            if !theme.isDaylight || whiteOnAccent >= HelmContrast.textTarget - 0.01 {
                if !sameColor(primaryFill, accent) {
                    print("  FAIL \(theme.id): .primary fill is not accentHex")
                    ok = false
                }
            } else {
                let want = DaylightPalette.darkenedForWhiteLabel(accent)
                if !sameColor(primaryFill, want) {
                    print("  FAIL \(theme.id): .primary fill is neither accentHex nor its minimal white-label correction")
                    ok = false
                } else {
                    print("  NOTE \(pad(theme.id, 18)) accent carries a white label at only \(fmt(whiteOnAccent)):1, so .primary darkens the fill to \(hexString(want)) (\(fmt(HelmContrast.ratio(.white, want))):1)")
                }
            }
            print("  \(pad(theme.id, 20)) \(cells.joined(separator: "  "))")
        }
        // A tinted label (the "\u{2606} Favorite" / "Install in Bootstrap"
        // emphasis three pages used to hand-roll) has to clear the floor too.
        print("  -- tinted labels on .secondary / .quiet --")
        for theme in HelmTheme.allThemes {
            for (name, hue) in hues {
                for variant in [HelmButton.Variant.secondary, .quiet] {
                    let p = HelmButton.palette(variant: variant, tint: tint(named: name), theme: theme)
                    let backdrop = variant == .secondary
                        ? p.fill : HelmTheme.nsColor(theme.chromeBackgroundHex)
                    let r = HelmContrast.ratio(p.label, backdrop)
                    if r < HelmContrast.textTarget - 0.01 {
                        print("  FAIL \(theme.id) .\(variant) tint \(name): \(fmt(r)):1")
                        ok = false
                    }
                    _ = hue
                }
            }
        }
        print("  OK - all \(HelmTheme.allThemes.count) themes x 4 variants, plus every tint on .secondary/.quiet")
    }

    /// `HelmTint` by the name `hues` uses, so the tinted-label sweep above can
    /// ask for the real enum case rather than a hex.
    private static func tint(named name: String) -> HelmTint {
        switch name {
        case "red": return .critical
        case "green": return .good
        case "amber": return .warn
        case "blue": return .info
        case "violet": return .violet
        case "accent": return .accent
        default: return .neutral
        }
    }

    // MARK: 6. The stock bezel must not come back (audit §3.2, §7 Phase 2)

    /// The audit counted 124 `bezelStyle` sites across 29 files; Phase 2 left
    /// exactly one, and it is not a button. A new one is almost always someone
    /// reaching for `NSButton` instead of `HelmButton`, which is invisible in
    /// review and only shows up as one grey control on an otherwise themed
    /// page - so it fails here instead.
    private static func checkNoStockBezels(_ ok: inout Bool) {
        print("\n-- stock bezels (must not appear in Sources/) --")
        let sourcesDir = SelfTestSources.appSourceDirectory() ?? URL(fileURLWithPath: "/nonexistent")
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP - sources not present next to this binary (\(sourcesDir.path))")
            return
        }
        // The one allowed site, with the reason it is allowed: this is
        // `NSTextField.bezelStyle` on `TabChipView`'s inline-rename field - a
        // different property on a different class, not a button at all.
        let allowed: Set<String> = ["TabChipView.swift:label.bezelStyle = .roundedBezel"]
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            if file.lastPathComponent == "HelmContrastSelfTest.swift" { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                guard trimmed.contains("bezelStyle") else { continue }
                if allowed.contains("\(file.lastPathComponent):\(trimmed)") { continue }
                offenders.append("\(file.lastPathComponent):\(n + 1) \(trimmed)")
            }
        }
        if offenders.isEmpty {
            print("  OK - no stock bezels (1 documented NSTextField exception allowed)")
        } else {
            for o in offenders { print("  FAIL \(o)") }
            print("  \(offenders.count) stock-bezel site(s) - use HelmButton instead")
            ok = false
        }
    }

    // MARK: 7. One accent-row recipe (audit §3.2, §6.3 component 2, Phase 3)

    /// Every `HelmAccentRow` renders the same recipe in every theme: the bar
    /// at one weight and position, the badge at one size, the kicker at one
    /// font/kern **in `mutedInk`, never the hue**, and the card at one radius
    /// with a `tint @ 0.4` border. This is the invariant the four
    /// pre-Phase-3 copies each broke differently - `SRELeadChatView`'s worst,
    /// with no border and a hue-coloured kicker.
    private static func checkAccentRowRecipe(_ ok: inout Bool) {
        print("\n-- accent rows (one recipe, all themes) --")
        for theme in HelmTheme.allThemes {
            for (name, _) in hues.prefix(3) {
                let tint: HelmTint = name == "red" ? .critical : (name == "green" ? .good : .warn)
                // The two structural variants both callers use.
                for placement in [HelmAccentRow.ChipPlacement.trailing, .belowBody] {
                    let row = HelmAccentRow(chipPlacement: placement)
                    row.configure(HelmAccentRow.Content(tint: tint,
                                                        kicker: "Kicker",
                                                        title: "A representative row title",
                                                        meta: "a meta line",
                                                        badgeSymbol: "bell.fill",
                                                        chipText: "Chip"),
                                  theme: theme)
                    // Give it a realistic width so the geometry resolves.
                    row.widthAnchor.constraint(equalToConstant: 420).isActive = true
                    let g = row.debugGeometry()
                    let muted = HelmTheme.mutedInk(theme)
                    var problems: [String] = []
                    if abs(g.barFrame.width - 3) > 0.01 { problems.append("bar width \(g.barFrame.width)") }
                    if g.badgeFrame.map({ abs($0.width - HelmMetrics.tileSmall) > 0.01 }) ?? true {
                        problems.append("badge size \(String(describing: g.badgeFrame?.width))")
                    }
                    if abs(g.cardRadius - HelmMetrics.rRow) > 0.01 { problems.append("radius \(g.cardRadius)") }
                    if g.kickerFont?.pointSize != HelmType.kicker().pointSize { problems.append("kicker font") }
                    if (g.kickerKern ?? 0) != HelmType.kickerKern { problems.append("kicker kern \(String(describing: g.kickerKern))") }
                    // The rule: a tint hue is safe as a fill or a bar, never
                    // automatically as text. The kicker is `mutedInk`.
                    if let kc = g.kickerColor, HelmContrast.ratio(kc, muted) > 1.01 {
                        problems.append("kicker not mutedInk")
                    }
                    if !g.chipVisible { problems.append("chip missing") }
                    if g.cardBorderColor == nil { problems.append("no card border") }
                    if !problems.isEmpty {
                        print("  FAIL \(theme.id) \(name) \(placement): \(problems.joined(separator: ", "))")
                        ok = false
                    }
                }
            }
        }
        print("  OK - bar 3pt, badge \(Int(HelmMetrics.tileSmall))pt, radius \(Int(HelmMetrics.rRow)), kicker in mutedInk, tinted border, in all \(HelmTheme.allThemes.count) themes")
    }

    /// A kicker built by hand is how the app ended up with three kern values
    /// for one label, and with `SRELeadChatView` colouring its kicker from
    /// the raw tint hue - the exact "hue as text" mistake §5.7 is about. Every
    /// kicker goes through `HelmType.kicker()`/`kickerKern`, so a stray
    /// `.kern:` outside the design system fails here.
    private static func checkNoHandRolledKickers(_ ok: inout Bool) {
        print("\n-- kickers (must come from HelmType) --")
        let sourcesDir = SelfTestSources.appSourceDirectory() ?? URL(fileURLWithPath: "/nonexistent")
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP - sources not present next to this binary (\(sourcesDir.path))")
            return
        }
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            if ["HelmContrastSelfTest.swift", "HelmDesignSystem.swift"].contains(file.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                guard trimmed.contains(".kern:") else { continue }
                // The token itself is fine wherever it appears.
                if trimmed.contains("HelmType.kickerKern") { continue }
                offenders.append("\(file.lastPathComponent):\(n + 1) \(trimmed)")
            }
        }
        if offenders.isEmpty {
            print("  OK - no hand-rolled kern outside HelmType")
        } else {
            for o in offenders { print("  FAIL \(o)") }
            print("  \(offenders.count) hand-rolled kicker(s) - use HelmType.kickerAttributes")
            ok = false
        }
    }

    // MARK: 8. The status column stays a column, on the right (audit §5.4)

    /// The shared checklist row's status pill has to be a **column**, and it
    /// has to be a column **on the trailing side of the row**. Three separate
    /// live-reported defects live in this one check:
    ///
    /// - Pre-§5.4, the pill sat immediately after the name label, so it
    ///   tracked the name's length: a 64pt spread over five real Updates
    ///   rows, a ragged diagonal instead of a column.
    /// - §5.4 fixed that with a fixed 42%-of-the-row name column, which put
    ///   the pill at 42% *from the leading edge* - so a row with short detail
    ///   text left roughly half the row empty between the pill and the
    ///   right-anchored actions (measured on the real GitHub Sync page:
    ///   729.5pt of dead gap on every row), and a row with long detail text
    ///   truncated 6pt short of the pill with ~670pt of unused row to its
    ///   right (Updates' real `firstmate` row).
    /// - So the column is now measured from the trailing edge
    ///   (`ToolRowLayout.statusColumnTrailingReserve`). This asserts what that
    ///   actually guarantees, not a weaker restatement of it.
    ///
    /// Deliberately measures the pill's **trailing** edge, not its `minX`: the
    /// pills are right-aligned now, and their own widths differ legitimately
    /// ("Up to Date" vs "Update Available" is a real 32.5pt difference), so
    /// `minX` would report that text-length difference as a layout failure.
    private static func checkStatusColumnAligned(_ ok: inout Bool) {
        print("\n-- status column (audit §5.4, trailing-anchored) --")
        let theme = ThemeManager.shared.theme
        // Deliberately mismatched name lengths, detail lengths *and* action
        // sets - the first two used to move the pill, and the third is what
        // the reserve exists to absorb. Every action set here fits inside
        // `statusColumnTrailingReserve`; the row that does not fit is checked
        // separately below.
        let fixtures: [(name: String, detail: String, buttons: [String])] = [
            ("gh-axi", "0.1.30 - up to date", ["Check"]),
            ("chrome-devtools-axi", "0.1.29 \u{2192} 0.1.30", ["Check", "Update"]),
            ("gh (GitHub CLI)", "2.97.0 - up to date", ["Check"]),
            ("manjesh-raj/treehouse", "In sync with kunchenguid/treehouse", []),
            // The real string that used to truncate flush against the pill.
            ("firstmate", "main carries 24 commit(s) of its own and is 7 behind upstream/main; run without --check to merge upstream into main, then push to origin", ["Check", "Update"]),
        ]
        for width in [760.0, 1064.0, 1400.0] as [CGFloat] {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
            host.translatesAutoresizingMaskIntoConstraints = false
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(stack)
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: width),
                stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                stack.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            var rows: [(pill: NSView, detail: NSTextField, row: NSView)] = []
            for fx in fixtures {
                let v = ToolRowLayout.Views(
                    iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
                    detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
                    pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
                    detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
                    logContainer: NSView(), rowContainer: HoverHighlightView())
                ToolRowLayout.pill(text: "Up to Date", colorHex: theme.accentHex,
                                   into: v.pill, label: v.pillLabel, theme: theme)
                let row = ToolRowLayout.build(
                    v, iconSymbol: "shippingbox", tint: .info, name: fx.name,
                    trailingViews: fx.buttons.map { HelmButton(title: $0, variant: .secondary, size: .small) },
                    identifier: fx.name)
                v.detailLabel.stringValue = fx.detail
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                rows.append((v.pill, v.detailLabel, v.rowContainer))
            }
            host.layoutSubtreeIfNeeded()

            // 1. One column: the pill's trailing edge is the same distance
            //    from every row's trailing edge.
            let insets = rows.map { $0.row.bounds.width - $0.pill.convert($0.pill.bounds, to: $0.row).maxX }
            let spread = (insets.max() ?? 0) - (insets.min() ?? 0)
            // 2. On the right: that distance is a small fraction of the row,
            //    not the ~50% the leading-edge column left behind.
            let rowWidth = rows.first?.row.bounds.width ?? 1
            let inset = insets.first ?? 0
            // 3. No conflict: the detail line never reaches the pill.
            let gaps = rows.map { $0.pill.convert($0.pill.bounds, to: $0.row).minX - $0.detail.convert($0.detail.bounds, to: $0.row).maxX }
            let minGap = gaps.min() ?? 0

            var problems: [String] = []
            if spread > 0.5 { problems.append("pill trailing-inset spread \(fmt(Double(spread)))pt - not a column") }
            if inset > rowWidth * 0.25 {
                problems.append("pill sits \(fmt(Double(inset)))pt from the row's end on a \(fmt(Double(rowWidth)))pt row - that is not the right side")
            }
            // A **literal** floor, not `ToolRowLayout.statusColumnLeadingGap`
            // itself - checking a constant against itself is a tautology, and
            // "someone deletes the gap spacer / zeroes the constant" is
            // exactly the regression this line is here to catch (confirmed:
            // setting that constant to 0 has to fail here, and does).
            let hardGapFloor: CGFloat = 12
            if minGap < hardGapFloor {
                problems.append("detail text comes within \(fmt(Double(minGap)))pt of the pill (hard floor is \(fmt(Double(hardGapFloor))))")
            }
            if ToolRowLayout.statusColumnLeadingGap < hardGapFloor {
                problems.append("statusColumnLeadingGap is \(fmt(Double(ToolRowLayout.statusColumnLeadingGap)))pt, below the \(fmt(Double(hardGapFloor)))pt floor")
            }
            if problems.isEmpty {
                print("  OK width \(Int(width)): pill trailing inset constant at \(fmt(Double(inset)))pt, min text->pill gap \(fmt(Double(minGap)))pt")
            } else {
                for p in problems { print("  FAIL width \(Int(width)): \(p)") }
                ok = false
            }
        }

        // A row whose actions are genuinely wider than the reserve shifts
        // left - by exactly its own overflow, deterministically, never by
        // anything to do with its text. Asserted rather than left implicit,
        // because it is the one case the column above does not cover and the
        // trade-off is deliberate (see `statusColumnTrailingReserve`).
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 200))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 1200),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        var wide: [(pill: NSView, row: NSView)] = []
        for name in ["DevOps Playbook", "Automic Vault"] {
            let v = ToolRowLayout.Views(
                iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
                detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
                pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
                detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
                logContainer: NSView(), rowContainer: HoverHighlightView())
            ToolRowLayout.pill(text: "Not Installed", colorHex: theme.accentHex,
                               into: v.pill, label: v.pillLabel, theme: theme)
            let row = ToolRowLayout.build(
                v, iconSymbol: "shippingbox", tint: .info, name: name,
                trailingViews: [HelmButton(title: "Check", variant: .secondary, size: .small),
                                HelmButton(title: "Install in Bootstrap \u{2192}", variant: .secondary, size: .small)],
                identifier: name)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            wide.append((v.pill, v.rowContainer))
        }
        host.layoutSubtreeIfNeeded()
        let wideInsets = wide.map { $0.row.bounds.width - $0.pill.convert($0.pill.bounds, to: $0.row).maxX }
        let wideSpread = (wideInsets.max() ?? 0) - (wideInsets.min() ?? 0)
        if wideSpread > 0.5 {
            print("  FAIL over-reserve rows disagree with each other by \(fmt(Double(wideSpread)))pt - the shift is supposed to be a function of the action set, nothing else")
            ok = false
        } else if (wideInsets.first ?? 0) <= ToolRowLayout.statusColumnTrailingReserve {
            print("  FAIL an over-reserve row did not shift left at all (inset \(fmt(Double(wideInsets.first ?? 0)))pt) - the reserve is silently absorbing a wider action set")
            ok = false
        } else {
            print("  OK over-reserve rows shift left together, to a constant \(fmt(Double(wideInsets.first ?? 0)))pt inset")
        }
    }

    // MARK: 8b. A row must never resize the window (fm/grandline-design-fidelity-fixes)

    /// **No constraint inside a `ToolRowLayout` row may outrank
    /// `NSLayoutPriorityWindowSizeStayPut` (500).**
    ///
    /// A window only holds its own size at priority 500, so *any* content
    /// constraint above that can reach out and resize the whole window. The
    /// fixed-name-column constraint (§5.4's fix) shipped at `.defaultHigh + 1`
    /// (751) paired with a required `<= nameColumnMaxWidth`, and between them
    /// they capped the entire app window at `nameColumnMaxWidth /
    /// nameColumnFraction` plus the row, card and page insets - **1410pt** -
    /// on every page carrying these rows. On a 1512pt-wide screen the window
    /// refused to grow past that, reported `isZoomed == true` at it, and even
    /// genuine macOS full screen rendered 1410pt wide, centred, with a black
    /// bar down each side.
    ///
    /// Two checks, because either alone would miss it: the priority itself,
    /// and a real window that is asked to be wider than the cap and must
    /// actually stay there.
    private static func checkRowDoesNotResizeWindow(_ ok: inout Bool) {
        print("\n-- rows must not drive window size (priority < 500) --")
        let theme = ThemeManager.shared.theme

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 300))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        let v = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView())
        ToolRowLayout.pill(text: "Up to Date", colorHex: theme.accentHex,
                           into: v.pill, label: v.pillLabel, theme: theme)
        let row = ToolRowLayout.build(v, iconSymbol: "shippingbox", tint: .info, name: "chrome-devtools-axi",
                                      trailingViews: [HelmButton(title: "Check", variant: .secondary, size: .small)],
                                      identifier: "probe")
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        host.layoutSubtreeIfNeeded()

        let stayPut = NSLayoutConstraint.Priority(rawValue: 500)
        var offenders: [NSLayoutConstraint] = []
        func scan(_ view: NSView) {
            for c in view.constraints where c.isActive && c.priority > stayPut && c.priority < .required {
                switch c.firstAttribute {
                case .width, .leading, .trailing, .left, .right, .centerX: offenders.append(c)
                default: break
                }
            }
            view.subviews.forEach(scan)
        }
        scan(host)
        if offenders.isEmpty {
            print("  OK no horizontal row constraint sits above NSLayoutPriorityWindowSizeStayPut")
        } else {
            for c in offenders { print("  FAIL priority \(c.priority.rawValue) > 500: \(c)") }
            ok = false
        }

        // The real thing: a window whose content is one of these rows must be
        // able to hold a width well past `nameColumnMaxWidth / fraction`.
        let target: CGFloat = 1600
        let vc = NSViewController()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inner.topAnchor.constraint(equalTo: content.topAnchor),
            inner.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        let v2 = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView())
        ToolRowLayout.pill(text: "Up to Date", colorHex: theme.accentHex,
                           into: v2.pill, label: v2.pillLabel, theme: theme)
        let row2 = ToolRowLayout.build(v2, iconSymbol: "shippingbox", tint: .info, name: "chrome-devtools-axi",
                                       trailingViews: [HelmButton(title: "Check", variant: .secondary, size: .small)],
                                       identifier: "probe2")
        inner.addArrangedSubview(row2)
        row2.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        vc.view = content
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentViewController = vc
        win.setFrame(NSRect(x: -30000, y: -30000, width: target, height: 300), display: false)
        win.layoutIfNeeded()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        let held = win.frame.width
        if held >= target - 1 {
            print("  OK a window carrying one of these rows holds \(Int(held))pt")
        } else {
            print("  FAIL window shrank to \(Int(held))pt when asked for \(Int(target)) - a row constraint is resizing it")
            ok = false
        }
        win.orderOut(nil)

        // **The other direction: a long detail line must not set a *floor*.**
        //
        // The 42%-of-the-row name column this layout replaced came with a
        // required `textStack.width <= 520` cap, which outranked the labels
        // and so kept them free to truncate. Removing the cap without also
        // lowering the labels' own compression resistance (an `NSTextField`
        // defaults to 750, above `NSLayoutPriorityWindowSizeStayPut`) hands
        // the *full intrinsic width of the text* to the row as a minimum -
        // measured on Updates' real `firstmate` string: a 1016pt container
        // produced a 1055pt row, and the window it was in came back 1103pt
        // wide after being asked for 1064.
        // It has to be a real *window* asked for a narrow width, not a host
        // view with a required width: inside a required-width container the
        // solver has no choice but to break the label's own resistance, so
        // the row fits and the check passes while the bug is fully present.
        // A resizable window is precisely the case where AppKit resolves the
        // conflict by growing the window instead - which is the symptom.
        let narrow: CGFloat = 900
        let tightVC = NSViewController()
        let tightHost = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let tightStack = NSStackView()
        tightStack.orientation = .vertical
        tightStack.alignment = .leading
        tightStack.translatesAutoresizingMaskIntoConstraints = false
        tightHost.addSubview(tightStack)
        NSLayoutConstraint.activate([
            tightStack.leadingAnchor.constraint(equalTo: tightHost.leadingAnchor),
            tightStack.trailingAnchor.constraint(equalTo: tightHost.trailingAnchor),
            tightStack.topAnchor.constraint(equalTo: tightHost.topAnchor),
            tightStack.bottomAnchor.constraint(lessThanOrEqualTo: tightHost.bottomAnchor),
        ])
        let v3 = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView())
        ToolRowLayout.pill(text: "Update Available", colorHex: theme.accentHex,
                           into: v3.pill, label: v3.pillLabel, theme: theme)
        let row3 = ToolRowLayout.build(v3, iconSymbol: "shippingbox", tint: .accent, name: "firstmate",
                                       trailingViews: [HelmButton(title: "Check", variant: .secondary, size: .small),
                                                       HelmButton(title: "Update", variant: .secondary, size: .small)],
                                       identifier: "probe3")
        v3.detailLabel.stringValue = "main carries 24 commit(s) of its own and is 7 behind upstream/main; run without --check to merge upstream into main, then push to origin"
        tightStack.addArrangedSubview(row3)
        row3.widthAnchor.constraint(equalTo: tightStack.widthAnchor).isActive = true
        tightVC.view = tightHost
        let tightWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        tightWin.contentViewController = tightVC
        tightWin.setFrame(NSRect(x: -30000, y: -30000, width: narrow, height: 200), display: false)
        tightWin.layoutIfNeeded()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        let narrowHeld = tightWin.frame.width
        if narrowHeld <= narrow + 1 {
            print("  OK a window carrying a row with a 700pt-wide detail line holds \(Int(narrowHeld))pt")
        } else {
            print("  FAIL window grew to \(fmt(Double(narrowHeld)))pt when asked for \(Int(narrow)) - a long detail label is setting a width floor")
            ok = false
        }
        tightWin.orderOut(nil)
    }

    // MARK: 9. One stat-tile recipe (audit §3.2 "Stat tile", §6.3 #4, Phase 4)

    /// Every `HelmStatTile` renders one recipe in every theme - one height, one
    /// radius, one metric size, one caption size, `HelmCard`'s own fill and
    /// border - and, the part that is a real defect rather than inconsistency,
    /// **a tinted metric clears the text floor against the tile's own fill**.
    /// Two of the three copies this replaced set the value label straight to
    /// `HelmTheme.nsColor(tint.hex(in: theme))`, which is §5.7's "a hue is safe
    /// as a fill, not automatically as text" mistake: Solarized Dark's green
    /// measures 2.71:1 that way.
    private static func checkStatTileRecipe(_ ok: inout Bool) {
        print("\n-- stat tiles (one recipe + legible tinted metric, all themes) --")
        var worst = (ratio: Double.greatestFiniteMagnitude, label: "")
        for theme in HelmTheme.allThemes {
            for tint in [nil, HelmTint.good, .warn, .critical, .accent, .info, .violet] as [HelmTint?] {
                let tile = HelmStatTile(symbol: "checkmark.circle", value: "12", caption: "a caption", tint: tint)
                tile.applyTheme(theme)
                tile.widthAnchor.constraint(equalToConstant: 180).isActive = true
                let g = tile.debugGeometry()
                var problems: [String] = []
                if abs(g.tileFrame.height - HelmStatTile.height) > 0.01 {
                    problems.append("height \(g.tileFrame.height)")
                }
                if abs(g.cornerRadius - HelmMetrics.rRow) > 0.01 { problems.append("radius \(g.cornerRadius)") }
                if abs(g.borderWidth - 1) > 0.01 { problems.append("border width \(g.borderWidth)") }
                // Compared against the recipe's own constants rather than
                // literals, so GL-32's chrome scale (`HelmType.scaled`) can
                // never make this check fail for the right reason - the point
                // is one recipe per theme, not one hardcoded point size.
                if g.metricFont?.pointSize != HelmType.scaled(19) {
                    problems.append("metric size \(String(describing: g.metricFont?.pointSize))")
                }
                if g.captionFont?.pointSize != HelmType.scaled(HelmStatTile.captionSize) {
                    problems.append("caption size \(String(describing: g.captionFont?.pointSize))")
                }
                // The fill is `HelmCard`'s, so a tile and a card on one page can
                // never drift into two surfaces again. The alpha check matters
                // as much as the hue: Updates' copy was the same colour at
                // `@ 0.60`, which is a different *rendered* surface.
                if let fill = g.fill {
                    if HelmContrast.ratio(fill, HelmTheme.nsColor(theme.chromeBackgroundHex)) > 1.01 {
                        problems.append("fill is not the card surface")
                    }
                    if abs(fill.alphaComponent - 1) > 0.01 {
                        problems.append("fill alpha \(fmt(Double(fill.alphaComponent)))")
                    }
                }
                if let metric = g.metricColor, let fill = g.fill {
                    let r = HelmContrast.ratio(metric, fill)
                    if r < worst.ratio { worst = (r, "\(theme.id) \(String(describing: tint))") }
                    if r < HelmContrast.textTarget - 0.01 { problems.append("metric contrast \(fmt(r))") }
                }
                if let caption = g.captionColor,
                   HelmContrast.ratio(caption, HelmTheme.mutedInk(theme)) > 1.01 {
                    problems.append("caption not mutedInk")
                }
                if !problems.isEmpty {
                    print("  FAIL \(theme.id) \(String(describing: tint)): \(problems.joined(separator: ", "))")
                    ok = false
                }
            }
        }
        print("  OK - \(Int(HelmStatTile.height))pt / radius \(Int(HelmMetrics.rRow)) / metric \(fmt(Double(HelmType.scaled(19)))) / caption \(fmt(Double(HelmType.scaled(HelmStatTile.captionSize)))), card surface, worst metric contrast \(fmt(worst.ratio)) (\(worst.label))")
    }

    // MARK: 10. One empty-state recipe (audit §3.2 "Empty state", §6.3 #5, Phase 4)

    /// Both `HelmEmptyState` sizes render one recipe: a real glyph (four of the
    /// six treatments this replaced had none, and one of those made Vault's
    /// panels collapse to `bodyH=0` - §5.5), body copy in `mutedInk` with a real
    /// non-zero width (the `preferredMaxLayoutWidth` trap this class inherited a
    /// fix for), and a title only where one was asked for.
    private static func checkEmptyStateRecipe(_ ok: inout Bool) {
        print("\n-- empty states (one recipe, both sizes, all themes) --")
        for theme in HelmTheme.allThemes {
            for size in [HelmEmptyState.Size.compact, .standard] {
                for boxed in [false, true] {
                    let empty = HelmEmptyState(symbol: "tray",
                                               title: size == .standard ? "Nothing here" : nil,
                                               body: "A single-line explanation long enough to need a real width to lay out in.",
                                               size: size,
                                               boxed: boxed)
                    empty.applyTheme(theme)
                    // A realistic container, so `layout()` has a width to hand
                    // the wrapping label.
                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 160))
                    host.addSubview(empty)
                    NSLayoutConstraint.activate([
                        empty.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        empty.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                        empty.topAnchor.constraint(equalTo: host.topAnchor),
                        empty.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    ])
                    host.layoutSubtreeIfNeeded()
                    let g = empty.debugGeometry()
                    var problems: [String] = []
                    if g.glyphFrame.width < 1 { problems.append("no glyph") }
                    if g.titleVisible != (size == .standard) { problems.append("title visible \(g.titleVisible)") }
                    if g.bodyFont?.pointSize != HelmType.caption().pointSize {
                        problems.append("body size \(String(describing: g.bodyFont?.pointSize))")
                    }
                    if let bodyColor = g.bodyColor,
                       HelmContrast.ratio(bodyColor, HelmTheme.mutedInk(theme)) > 1.01 {
                        problems.append("body not mutedInk")
                    }
                    // The trap: a wrapping label in a centre-aligned stack with
                    // inequality side constraints collapses to a few characters
                    // per line unless handed a real width.
                    if g.bodyFrame.width < 100 { problems.append("body width \(fmt(Double(g.bodyFrame.width)))") }
                    if boxed && abs(g.cornerRadius - HelmMetrics.rRow) > 0.01 {
                        problems.append("boxed radius \(g.cornerRadius)")
                    }
                    if !problems.isEmpty {
                        print("  FAIL \(theme.id) \(size) boxed=\(boxed): \(problems.joined(separator: ", "))")
                        ok = false
                    }
                }
            }
        }
        print("  OK - glyph + body in mutedInk at a real width, title only when asked, boxed radius \(Int(HelmMetrics.rRow))")
    }

    // MARK: 11. One sub-navigation recipe (audit §3.2, §6.3 #6, Phase 4)

    /// Every `HelmSegmentedTabs` is pills in a bordered capsule, and the active
    /// pill's label clears the text floor **against the wash it actually sits
    /// on**. Both copies this replaced painted `label.textColor = accent`
    /// directly over an accent wash - the same §5.7 mistake as the stat tiles.
    private static func checkSegmentedTabsRecipe(_ ok: inout Bool) {
        print("\n-- segmented tabs (one recipe + legible active label, all themes) --")
        var worst = (ratio: Double.greatestFiniteMagnitude, label: "")
        for theme in HelmTheme.allThemes {
            for size in [HelmSegmentedTabs.Size.standard, .compact] {
                let tabs = HelmSegmentedTabs(items: [.init(id: "a", title: "First"),
                                                     .init(id: "b", title: "Second"),
                                                     .init(id: "c", title: "Third")],
                                             selected: "b", size: size)
                tabs.applyTheme(theme)
                let g = tabs.debugGeometry()
                var problems: [String] = []
                if g.pillCount != 3 { problems.append("pill count \(g.pillCount)") }
                if g.activeID != "b" { problems.append("active \(g.activeID)") }
                // Theme-aware rather than exempting Daylight: the assertion is
                // still "one recipe per theme", it just no longer assumes the
                // recipe is the same in all of them. §7 makes the Daylight
                // strip space-pill-shaped - capsules on the page's own
                // surface, so no bordered container to measure - while the
                // twelve palettes keep the bordered translucent capsule.
                if theme.isDaylight {
                    if g.capsuleBorderWidth != 0 { problems.append("Daylight capsule still has a border") }
                    let expected = size.daylightPillRadius(for: tabs.debugPillsForAccessibilityTests()[0])
                    if g.pillRadii.contains(where: { abs($0 - expected) > 0.01 }) {
                        problems.append("pill radii \(g.pillRadii) are not capsules (want \(expected))")
                    }
                } else {
                    if abs(g.capsuleBorderWidth - 1) > 0.01 { problems.append("no capsule border") }
                    if abs(g.capsuleRadius - size.capsuleRadius) > 0.01 { problems.append("capsule radius \(g.capsuleRadius)") }
                    if g.pillRadii.contains(where: { abs($0 - size.pillRadius) > 0.01 }) {
                        problems.append("pill radii \(g.pillRadii)")
                    }
                }
                if Set(g.labelPointSizes).count != 1 { problems.append("label sizes \(g.labelPointSizes)") }
                // The active label lands on the accent wash composited over the
                // capsule's own fill, which itself sits over one of the two page
                // surfaces - score the worse.
                if theme.isDaylight, let activeInk = g.activeInk, let fill = g.activeFill {
                    // Daylight's active pill is an opaque `ink` capsule, so the
                    // label is scored straight against it - there is no
                    // translucent capsule underneath to composite through.
                    let r = HelmContrast.ratio(activeInk, fill)
                    if r < worst.ratio { worst = (r, "\(theme.id) \(size)") }
                    if r < HelmContrast.textTarget - 0.01 { problems.append("active label contrast \(fmt(r))") }
                } else if let activeInk = g.activeInk, let wash = g.activeFill {
                    for behindHex in [theme.chromeBackgroundHex, theme.backgroundHex] {
                        let capsule = HelmContrast.mix(
                            HelmContrast.components(HelmTheme.nsColor(theme.chromeBackgroundHex)),
                            HelmContrast.components(HelmTheme.nsColor(behindHex)),
                            Double(HelmSegmentedTabs.capsuleAlpha))
                        let fill = HelmContrast.mix(HelmContrast.components(wash), capsule,
                                                    Double(wash.alphaComponent))
                        let r = HelmContrast.ratio(HelmContrast.components(activeInk), fill)
                        if r < worst.ratio { worst = (r, "\(theme.id) \(size)") }
                        if r < HelmContrast.textTarget - 0.01 { problems.append("active label contrast \(fmt(r))") }
                    }
                }
                if let inactiveInk = g.inactiveInk,
                   HelmContrast.ratio(inactiveInk, HelmTheme.mutedInk(theme)) > 1.01 {
                    problems.append("inactive label not mutedInk")
                }
                if !problems.isEmpty {
                    print("  FAIL \(theme.id) \(size): \(problems.joined(separator: ", "))")
                    ok = false
                }
            }
        }
        print("  OK - bordered capsule, one pill radius / label size per size, inactive in mutedInk, worst active label contrast \(fmt(worst.ratio)) (\(worst.label))")
    }

    // MARK: 12. One sunken-field recipe (audit §3.2 "Sunken form field", §6.3's
    //            `HelmField` extraction, Phase 6)

    /// Every field shape - single-line, secure, multi-line, date picker, field
    /// card, toggle row - resolves to one radius, one border width and one
    /// fill, in every theme; and that fill is visibly distinct from *both*
    /// page surfaces.
    ///
    /// The distinctness assertion is the load-bearing one, and it is why the
    /// fill blends toward ink rather than using a token straight:
    /// `chromeBackgroundHex == backgroundHex` in three of the twelve palettes
    /// (`gruvbox-light`, `tokyo-night-dark`, `tokyo-night-light`), so a field
    /// painted with either token bare would have no visible boundary at all in
    /// exactly those three - which is a real bug this app has already shipped
    /// once, in the Compose popover.
    private static func checkFieldRecipe(_ ok: inout Bool) {
        print("\n-- form fields (one recipe + a visible boundary, all themes) --")
        var worstInk = (ratio: Double.greatestFiniteMagnitude, label: "")
        var worstMuted = (ratio: Double.greatestFiniteMagnitude, label: "")
        var worstEdge = (ratio: Double.greatestFiniteMagnitude, label: "")
        for theme in HelmTheme.allThemes {
            let text = HelmTextField(placeholder: "Placeholder")
            let secure = HelmSecureTextField(placeholder: "Placeholder")
            let multi = HelmTextView(height: 80)
            let picker = HelmDatePicker()
            let card = HelmFieldCard(label: "Priority", accessory: HelmDotAccessory())
            let toggle = HelmToggleRow(title: "Something", subtitle: "Explains itself")
            text.applyTheme(theme)
            secure.applyTheme(theme)
            multi.applyTheme(theme)
            picker.applyTheme(theme)
            card.applyTheme(theme)
            toggle.applyTheme(theme)

            let shapes: [(String, NSView)] = [
                ("text", text.chromeView), ("secure", secure.chromeView), ("textview", multi.chromeView),
                ("datepicker", picker.chromeView), ("card", card.chromeView), ("toggle", toggle.chromeView),
            ]
            var problems: [String] = []
            let expected = HelmField.fill(theme)
            for (name, view) in shapes {
                let g = HelmField.geometry(of: view)
                // The field card and the toggle row are row-shaped surfaces, so
                // they carry the row radius; everything else is a control.
                // Both resolve **per theme** since Daylight §6.9 rounds a well
                // to `dWell` - the check is still "one radius per theme", it
                // just no longer assumes that radius is the same in all of
                // them.
                let wantRadius = (name == "card" || name == "toggle")
                    ? HelmField.rowCornerRadius(for: theme)
                    : HelmField.cornerRadius(for: theme)
                if abs(g.radius - wantRadius) > 0.01 { problems.append("\(name) radius \(g.radius)") }
                if abs(g.borderWidth - 1) > 0.01 { problems.append("\(name) border width \(g.borderWidth)") }
                guard let fill = g.fill else { problems.append("\(name) no fill"); continue }
                if HelmContrast.ratio(fill, expected) > 1.01 { problems.append("\(name) fill is not HelmField.fill") }
            }

            // The fill has to be visibly separate from whichever surface the
            // field lands on. 1.02:1 is a deliberately low bar - a field's
            // boundary is also carried by its border - but it catches "the fill
            // is literally the background", which is the real failure mode.
            //
            // One palette legitimately cannot clear it on both surfaces, and
            // is handled by proving the substitute rather than by an exemption.
            // Daylight's well token (§2.1's `inset`) sits deliberately close to
            // its `paper` ground - the design separates a well on the bare page
            // with its 1px `hair` border, not with a fill step - so where the
            // fill cannot carry the boundary the **border** must, measurably,
            // against that same fill. A theme that fails both is still a
            // failure. (No pre-existing palette takes this branch: the three
            // whose card and page are the same token derive a fill 1.15:1 off
            // both.)
            let borderVsFill = HelmContrast.ratio(HelmField.border(theme).withAlphaComponent(1), expected)
            for (surfaceName, hex) in [("chrome", theme.chromeBackgroundHex), ("page", theme.backgroundHex)] {
                let r = HelmContrast.ratio(expected, HelmTheme.nsColor(hex))
                if r < worstEdge.ratio { worstEdge = (r, "\(theme.id) vs \(surfaceName)") }
                guard r < 1.02 else { continue }
                if borderVsFill >= 1.10 {
                    print("  NOTE \(theme.id): fill sits on \(surfaceName) (\(fmt(r))) - boundary carried by the border (\(fmt(borderVsFill)))")
                } else {
                    problems.append("fill indistinguishable from \(surfaceName) (\(fmt(r))) and its border cannot carry the boundary either (\(fmt(borderVsFill)))")
                }
            }

            let inkRatio = HelmContrast.ratio(HelmField.ink(theme), expected)
            if inkRatio < worstInk.ratio { worstInk = (inkRatio, theme.id) }
            if inkRatio < HelmContrast.textTarget - 0.01 {
                problems.append("field text contrast \(fmt(inkRatio))")
            }
            let mutedRatio = HelmContrast.ratio(HelmField.mutedInk(theme), expected)
            if mutedRatio < worstMuted.ratio { worstMuted = (mutedRatio, theme.id) }
            if mutedRatio < HelmContrast.textTarget - 0.01 {
                problems.append("field muted text contrast \(fmt(mutedRatio))")
            }

            if !problems.isEmpty {
                print("  FAIL \(theme.id): \(problems.joined(separator: ", "))")
                ok = false
            }
        }
        print("  OK - one fill / one border / one control + one row radius per theme, worst field text \(fmt(worstInk.ratio)) (\(worstInk.label)), worst field muted \(fmt(worstMuted.ratio)) (\(worstMuted.label)), worst fill-vs-surface \(fmt(worstEdge.ratio)) (\(worstEdge.label))")
    }

    // MARK: 13. The sunken fill must stay defined once (audit §3.2, Phase 6)

    /// The audit found this recipe hand-rolled three times, each copy carrying
    /// a doc comment pointing at the others. A fourth is invisible in review
    /// and only shows up as one field that drifts on some themes - so it fails
    /// here instead. Also catches an `NSScrollView` reaching back for AppKit's
    /// own `.bezelBorder` frame, which is the same system chrome `HelmButton`
    /// removed from every push button.
    private static func checkNoReDerivedFieldChrome(_ ok: inout Bool) {
        print("\n-- re-derived field chrome (must not appear in Sources/) --")
        let sourcesDir = SelfTestSources.appSourceDirectory() ?? URL(fileURLWithPath: "/nonexistent")
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP - sources not present next to this binary (\(sourcesDir.path))")
            return
        }
        let banned = [
            "blended(withFraction: 0.08, of: ink)",
            "fieldFillColor",
            "styleSunkenField",
            "styleDetailFormField",
            "borderType = .bezelBorder",
        ]
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            // `HelmForm.swift` is where the one definition lives; this file
            // names the banned strings in prose above.
            if ["HelmForm.swift", "HelmContrastSelfTest.swift"].contains(file.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for token in banned where line.contains(token) {
                    offenders.append("\(file.lastPathComponent):\(n + 1) \(token)")
                }
            }
        }
        if offenders.isEmpty {
            print("  OK - one HelmField.fill, no re-derived sunken chrome, no scroll-view bezels")
        } else {
            for o in offenders { print("  FAIL \(o)") }
            print("  \(offenders.count) re-derived field-chrome site(s) - use HelmField instead")
            ok = false
        }
    }

    // MARK: 13b. No raw text inputs (audit D2/R2, Daylight Phase 0)

    /// The guard that stops this review being needed a third time.
    ///
    /// Buttons got a source guard in Phase 2 (`checkNoStockBezels`) and stock
    /// bezels have stayed at ~zero since. Inputs got the component
    /// (`HelmTextField`/`HelmTextView`, Phase 6) and no guard, and drifted
    /// immediately: by the time the Daylight audit swept the tree there were
    /// **27 bare `NSTextField()` construction sites across 16 files** plus 2
    /// `NSSearchField()`s - every one of them either a surface built after
    /// Phase 6 or one its scope ("the six editor sheets") never covered:
    /// search fields, filter fields, quick-add fields, inline parameter
    /// fields, settings fields. A stock field paints the dynamic system
    /// `.textBackgroundColor`, which under wallpaper tinting is the brown box
    /// the captain reported inside otherwise-themed cards (D2).
    ///
    /// Bans the bare *input* initializers only. `NSTextField(labelWithString:)`
    /// and `NSTextField(wrappingLabelWithString:)` are the label initializers
    /// and are used everywhere on purpose - a label is not an input.
    private static func checkNoRawTextInputs(_ ok: inout Bool) {
        print("\n-- raw text inputs (must not appear in Sources/) --")
        let sourcesDir = SelfTestSources.appSourceDirectory() ?? URL(fileURLWithPath: "/nonexistent")
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP - sources not present next to this binary (\(sourcesDir.path))")
            return
        }
        // `HelmForm.swift` is where the input language lives: `HelmSearchField`
        // builds its editor out of one chromeless `NSTextField` sitting inside
        // a well the component itself paints, which is the whole point of the
        // component. This file names the banned tokens in prose above.
        let exemptFiles: Set<String> = ["HelmForm.swift", "HelmContrastSelfTest.swift"]
        // The one allowed site outside those, with the reason: `TabChipView`'s
        // inline-rename field is the audit's own documented bespoke one-off
        // (`ui-report.md` §3.1 row 10 - not part of row 7's migration list),
        // and it is already the single documented exception in
        // `checkNoStockBezels` for the same control.
        //
        // The second allowed site is an `NSAlert` accessory view. An alert's
        // box is drawn by AppKit itself, so a theme-derived well inside it
        // would read as *less* consistent, not more - the same reasoning that
        // keeps the lock screen's bespoke scene out of scope. It is listed
        // here rather than left to a different initializer, because a guard
        // one initializer away from useless gets bypassed by accident: the
        // audit's own sweep grepped `NSTextField()` and missed this site
        // entirely for exactly that reason.
        let allowedSites: Set<String> = [
            "TabChipView.swift:private let label = NSTextField()",
            "ConsoleController+Incident.swift:let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))",
        ]
        let banned = ["NSTextField()", "NSSearchField()", "NSTextField(frame:", "NSSearchField(frame:"]
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            if exemptFiles.contains(file.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                for token in banned where trimmed.contains(token) {
                    if allowedSites.contains("\(file.lastPathComponent):\(trimmed)") { continue }
                    offenders.append("\(file.lastPathComponent):\(n + 1) \(trimmed)")
                }
            }
        }
        if offenders.isEmpty {
            print("  OK - no raw NSTextField()/NSSearchField() inputs (1 documented exception allowed)")
        } else {
            for o in offenders { print("  FAIL \(o)") }
            print("  \(offenders.count) raw input site(s) - use HelmTextField/HelmTextView/HelmSearchField")
            ok = false
        }
    }

    // MARK: 14. The one page toolbar (audit §3.2 "Page toolbars", Phase 7)

    /// Console, Docs and Tools each built their own bar (42 / 44 / 42pt, plus
    /// a second 40pt one inside Docs' Playbook tab) and Console's glyphs were
    /// bare borderless images while the top bar 40pt above rendered bordered
    /// squares. This asserts the shared component resolves to one height, one
    /// fill, one hairline per theme, and that its glyph really is the
    /// bordered `.secondary` square rather than a borderless one - the exact
    /// thing the audit measured as "two icon-button languages".
    private static func checkPageToolbarRecipe(_ ok: inout Bool) {
        print("\n-- page toolbar (one height / fill / hairline / bordered square) --")

        // Shape first, and it is theme-independent: a square at the shared
        // side length, `HelmButton`'s own control radius, and - the part that
        // matters - a variant that paints a border.
        let glyph = HelmPageToolbar.iconButton(symbol: "magnifyingglass", tooltip: "t", target: nil, action: nil)
        // In a real superview, laid out for real - a bare view with no
        // ancestor resolves only some of its own constraints.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        host.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        if glyph.variant != .secondary {
            print("  FAIL toolbar glyph variant is \(glyph.variant), not .secondary (a borderless glyph is the audit's finding)")
            ok = false
        }
        // A 1pt tolerance, and the reason is measured rather than slack: the
        // frame lands on exactly 28.0 x 28.0 when the button is inside a real
        // `NSWindow` (verified with a render probe) and 28.0 x 27.5 in this
        // windowless host, because `NSButton.alignmentRectInsets` resolves
        // slightly differently without one. What this check is actually
        // guarding is the 5.5pt error the naive version had - a plain
        // `heightAnchor == 28` renders a **33.5pt** tall box, since Auto Layout
        // sizes the alignment rect while the layer paints the frame (see
        // `HelmPageToolbar.iconButton`).
        let side = HelmPageToolbar.iconButtonSide
        if abs(glyph.frame.width - side) > 1 || abs(glyph.frame.height - side) > 1 {
            print("  FAIL toolbar glyph is \(glyph.frame.size), not a \(side)pt square")
            ok = false
        }
        // Theme-aware: Daylight §6.6 makes every button a capsule, so the
        // toolbar's icon square rounds to half its own side there. The point
        // of the check is unchanged - one radius, from the shared helper,
        // never a literal at the call site.
        let wantGlyphRadius = HelmButton.cornerRadius(for: ThemeManager.shared.theme,
                                                     height: glyph.bounds.height)
        if abs((glyph.layer?.cornerRadius ?? -1) - wantGlyphRadius) > 0.01 {
            print("  FAIL toolbar glyph radius \(glyph.layer?.cornerRadius ?? -1), want \(wantGlyphRadius)")
            ok = false
        }

        let bar = HelmPageToolbar()
        bar.setLeading(NSView())
        bar.setTrailing(HelmPageToolbar.group([
            HelmPageToolbar.iconButton(symbol: "plus", tooltip: "t", target: nil, action: nil),
        ]))
        // A real width, so the two slots resolve to real frames.
        bar.frame = NSRect(x: 0, y: 0, width: 900, height: HelmPageToolbar.height)

        for theme in HelmTheme.allThemes {
            bar.applyTheme(theme)
            let g = bar.debugGeometry()
            var problems: [String] = []
            if abs(g.height - HelmPageToolbar.height) > 0.01 { problems.append("height \(g.height)") }
            if let fill = g.fill {
                if HelmContrast.ratio(fill, HelmTheme.nsColor(theme.chromeBackgroundHex)) > 1.01 {
                    problems.append("fill is not chromeBackgroundHex")
                }
            } else {
                problems.append("no fill (a bar with no explicit background paints nothing - gotcha #8)")
            }
            if let sep = g.separatorFill {
                if HelmContrast.ratio(sep, HelmTheme.nsColor(theme.chromeLineHex)) > 1.01 {
                    problems.append("hairline is not chromeLineHex")
                }
            } else {
                problems.append("no hairline")
            }
            if abs(g.leadingMinX - HelmPageToolbar.leadingInset) > 0.51 {
                problems.append("leading inset \(g.leadingMinX)")
            }
            if abs((bar.frame.width - g.trailingMaxX) - HelmPageToolbar.trailingInset) > 0.51 {
                problems.append("trailing inset \(bar.frame.width - g.trailingMaxX)")
            }
            if !problems.isEmpty {
                print("  FAIL \(theme.id): \(problems.joined(separator: ", "))")
                ok = false
            }
        }
        print("  OK - \(HelmPageToolbar.height)pt, chromeBackground fill + chromeLine hairline in all \(HelmTheme.allThemes.count) themes, \(HelmPageToolbar.iconButtonSide)pt bordered .secondary squares")
    }

    // MARK: 15. The one responsive grid (audit §4.8, Phase 7)

    /// Settings' theme grid used a fixed 4-column chunk, which is what left
    /// the audit's ragged 4/2/4/2 last row; Tools and Docs each had their own
    /// copy of the real math. This asserts the shared helper's two guarantees
    /// - column count tracks real width, and a partial last row is padded to a
    /// full column count so `.fillEqually` divides by the same number - hold
    /// for a spread of widths and item counts, including the awkward ones.
    private static func checkResponsiveGrid(_ ok: inout Bool) {
        print("\n-- responsive grid (columns from real width, partial row padded) --")
        let minWidth: CGFloat = 300
        let spacing = HelmResponsiveGrid.spacing

        // Column count must be monotonic in width and never below 1, including
        // for a zero width (the pre-first-layout case, which would otherwise
        // collapse a whole grid to one column permanently).
        var previous = 0
        for width in [CGFloat(0), 200, 320, 600, 900, 1120, 1500, 2400] {
            let columns = HelmResponsiveGrid.columns(containerWidth: width, minItemWidth: minWidth)
            if columns < 1 {
                print("  FAIL width \(width) -> \(columns) columns")
                ok = false
            }
            // Width 0 falls back to a nominal container, so it is exempt from
            // the monotonic check.
            if width > 0 {
                if columns < previous {
                    print("  FAIL width \(width) gave fewer columns (\(columns)) than a narrower one (\(previous))")
                    ok = false
                }
                previous = columns
            }
            let itemWidth = HelmResponsiveGrid.itemWidth(containerWidth: width, columns: columns)
            // Cards plus gaps must fill the container exactly - the "cards
            // hug the leading edge and waste the rest" bug in reverse.
            let container = width > 0 ? width : HelmResponsiveGrid.fallbackContainerWidth
            let total = itemWidth * CGFloat(columns) + spacing * CGFloat(columns - 1)
            if abs(total - container) > 0.01 {
                print("  FAIL width \(width): \(columns) x \(itemWidth) + gaps = \(total), want \(container)")
                ok = false
            }
            if columns > 1 && itemWidth < minWidth - 0.01 {
                print("  FAIL width \(width): \(columns) columns forces \(itemWidth) < minimum \(minWidth)")
                ok = false
            }
        }

        // Every row - full or partial - must end up with the same number of
        // arranged subviews, so a lone leftover card is never stretched.
        for count in 1...13 {
            let rows = HelmResponsiveGrid.rows(Array(0..<count),
                                              containerWidth: 1120,
                                              minItemWidth: minWidth) { _, _ in NSView() }
            let expectedColumns = HelmResponsiveGrid.columns(containerWidth: 1120, minItemWidth: minWidth)
            let slotCounts = Set(rows.map { $0.arrangedSubviews.count })
            if rows.isEmpty || slotCounts != [expectedColumns] {
                print("  FAIL \(count) items -> row slot counts \(slotCounts.sorted()), want every row at \(expectedColumns)")
                ok = false
            }
            if let first = rows.first, first.distribution != .fillEqually {
                print("  FAIL \(count) items -> row distribution \(first.distribution)")
                ok = false
            }
        }
        print("  OK - columns track width, rows fill the container, every row padded to a full column count")
    }

    // MARK: 16. One page-title voice, at one size (audit §6.2, Phase 7)

    /// The captain's registered decision is "promote the serif to the app-wide
    /// page-title voice, at a single size (22)". The audit's finding was that
    /// the serif existed at **four** sizes (15 / 17 / 19 / 22 / 23 across
    /// Shift and the Command Library) with no rule, so the guarantee worth
    /// enforcing is not "serif is used" but "`ShiftFont.serif` is reachable
    /// only through `HelmType.pageTitle`" - which is what keeps a fifth size
    /// from appearing.
    private static func checkPageTitleVoice(_ ok: inout Bool) {
        print("\n-- page-title voice (serif only via HelmType.pageTitle, one size) --")

        // 22 is the *designed* size; GL-32's chrome scale multiplies it, so the
        // invariant this check exists for - one size, both voices - is
        // expressed against the scaled value rather than the literal.
        let wantPageTitle = HelmType.scaled(22)
        for voice in [HelmType.Voice.sans, .serif] {
            let font = HelmType.pageTitle(voice)
            if abs(font.pointSize - wantPageTitle) > 0.01 {
                print("  FAIL pageTitle(\(voice)) is \(font.pointSize)pt, want \(wantPageTitle)")
                ok = false
            }
        }
        if HelmType.pageTitle(.serif).fontName == HelmType.pageTitle(.sans).fontName {
            print("  FAIL the serif and sans voices resolve to the same face (\(HelmType.pageTitle(.serif).fontName))")
            ok = false
        }

        let sourcesDir = SelfTestSources.appSourceDirectory() ?? URL(fileURLWithPath: "/nonexistent")
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP source guard - sources not present next to this binary")
            return
        }
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            // `HelmDesignSystem.swift` holds the one call (inside
            // `HelmType.pageTitle`); `ShiftTypography.swift` declares
            // `ShiftFont.serif` itself; this file names it in prose.
            if ["HelmDesignSystem.swift", "ShiftTypography.swift", "HelmContrastSelfTest.swift"]
                .contains(file.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains("ShiftFont.serif(") {
                    offenders.append("\(file.lastPathComponent):\(n + 1)")
                }
            }
        }
        if offenders.isEmpty {
            print("  OK - serif reachable only via HelmType.pageTitle(.serif), at 22pt")
        } else {
            for o in offenders { print("  FAIL \(o) calls ShiftFont.serif directly - use HelmType.pageTitle(.serif) or HelmType.sectionTitle()") }
            ok = false
        }
    }

    // MARK: Daylight - the migration's palette sweep (Phase 1)

    /// Every contrast pair the Daylight migration's §2.4 table names, measured
    /// against this codebase's own WCAG formula rather than trusted.
    ///
    /// The table lists both the prototype's raw value and the corrected one, so
    /// this asserts **both directions**: the corrected value clears the floor,
    /// *and* the raw value it replaced genuinely fails it. A check that only
    /// asserted the first half would still pass if someone reverted a
    /// correction to a value that happened to be fine for a different reason,
    /// and would tell a future reader nothing about why the correction exists.
    private static func checkDaylightPalette(_ ok: inout Bool) {
        print("\n-- daylight palette (migration section 2.4, every pair measured) --")
        guard let daylight = HelmTheme.theme(id: "daylight") else {
            print("  FAIL the daylight theme is not in HelmTheme.allThemes")
            ok = false
            return
        }
        let card = HelmTheme.nsColor(DaylightPalette.card)
        let paper = HelmTheme.nsColor(DaylightPalette.paper)
        let inset = HelmTheme.nsColor(DaylightPalette.inset)
        let floor = HelmContrast.textTarget

        func expect(_ label: String, _ value: Double, atLeast target: Double) {
            if value < target - 0.01 {
                print("  FAIL \(label): \(fmt(value)):1, want >= \(fmt(target))")
                ok = false
            } else {
                print("  OK   \(pad(label, 44)) \(fmt(value)):1")
            }
        }
        func expectBelow(_ label: String, _ value: Double, _ target: Double) {
            if value >= target {
                print("  FAIL \(label): \(fmt(value)):1 - this value is supposed to FAIL the floor, so the correction it justifies is now unexplained")
                ok = false
            } else {
                print("  OK   \(pad(label, 44)) \(fmt(value)):1 (correctly below \(fmt(target)))")
            }
        }

        for (name, got, want) in [
            ("chromeBackgroundHex = card", daylight.chromeBackgroundHex, DaylightPalette.card),
            ("backgroundHex = paper", daylight.backgroundHex, DaylightPalette.paper),
            ("chromeInkHex = ink", daylight.chromeInkHex, DaylightPalette.ink),
            ("chromeLineHex = hair", daylight.chromeLineHex, DaylightPalette.hair),
            ("accentHex = corrected link blue", daylight.accentHex, DaylightPalette.linkBlue),
        ] where got.lowercased() != want.lowercased() {
            print("  FAIL daylight.\(name): got \(got), want \(want)")
            ok = false
        }
        if daylight.mode != .light {
            print("  FAIL daylight must be a light-mode theme")
            ok = false
        }

        let muted = HelmTheme.nsColor(DaylightPalette.muted)
        expect("muted on card", HelmContrast.ratio(muted, card), atLeast: floor)
        expect("muted on paper", HelmContrast.ratio(muted, paper), atLeast: floor)
        expect("muted on inset", HelmContrast.ratio(muted, inset), atLeast: floor)
        expectBelow("prototype muted 7C7767 on inset",
                    HelmContrast.ratio(HelmTheme.nsColor("7C7767"), inset), floor)
        if HelmContrast.ratio(HelmTheme.mutedInk(daylight), muted) > 1.01 {
            print("  FAIL HelmTheme.mutedInk(daylight) is not DaylightPalette.muted")
            ok = false
        }

        expectBelow("faint B0AA97 on paper (decorative only)",
                    HelmContrast.ratio(HelmTheme.nsColor(DaylightPalette.faint), paper), floor)

        let rawBlue = HelmDomainHue.blue.baseColor(in: daylight)
        expect("raw domain blue on card", HelmContrast.ratio(rawBlue, card), atLeast: floor)
        expectBelow("raw domain blue on paper", HelmContrast.ratio(rawBlue, paper), floor)
        let linkBlue = HelmTheme.nsColor(DaylightPalette.linkBlue)
        expect("corrected link blue on paper", HelmContrast.ratio(linkBlue, paper), atLeast: floor)
        expect("corrected link blue on card", HelmContrast.ratio(linkBlue, card), atLeast: floor)
        expect("selection text on selection fill",
               HelmContrast.ratio(HelmTheme.nsColor(daylight.selectionTextHex),
                                  HelmTheme.nsColor(daylight.selectionHex)), atLeast: floor)

        for (name, hue, corrected, wash) in [
            ("ok", DaylightPalette.ok, DaylightPalette.okText, 0.12),
            ("warn", DaylightPalette.warn, DaylightPalette.warnText, 0.14),
            ("bad", DaylightPalette.bad, DaylightPalette.badText, 0.12),
        ] {
            let fill = HelmContrast.mix(HelmContrast.components(HelmTheme.nsColor(hue)),
                                        HelmContrast.components(card), wash)
            expectBelow("raw \(name) label on its own wash",
                        HelmContrast.ratio(HelmContrast.components(HelmTheme.nsColor(hue)), fill), floor)
            expect("corrected \(name) label on its own wash",
                   HelmContrast.ratio(HelmContrast.components(HelmTheme.nsColor(corrected)), fill),
                   atLeast: floor)
        }

        for entry in DaylightPalette.primaryButtonFills {
            let raw = entry.hue.baseColor(in: daylight)
            expectBelow("raw \(entry.hue.rawValue) fill, white label",
                        HelmContrast.ratio(.white, raw), floor)
            expect("corrected \(entry.hue.rawValue) fill, white label",
                   HelmContrast.ratio(.white, HelmTheme.nsColor(entry.corrected)), atLeast: floor)
        }
        for hue in [HelmDomainHue.blue, .violet] {
            expect("\(hue.rawValue) fill passes raw, white label",
                   HelmContrast.ratio(.white, hue.baseColor(in: daylight)), atLeast: floor)
        }

        var worstAnsi = (index: -1, ratio: Double.greatestFiniteMagnitude)
        for (i, hex) in daylight.ansiHex.enumerated() {
            let r = HelmContrast.ratio(HelmTheme.nsColor(hex), paper)
            if r < worstAnsi.ratio { worstAnsi = (i, r) }
            if r < floor - 0.01 {
                print("  FAIL ansi[\(i)] \(hex) on paper: \(fmt(r)):1")
                ok = false
            }
        }
        print("  OK   \(pad("all 16 ansi slots on paper", 44)) worst is ansi[\(worstAnsi.index)] at \(fmt(worstAnsi.ratio)):1")
    }

    // MARK: Dusk - the dark register, measured the same way (Phase 6)

    /// Every value `DaylightTokens.dusk` derives, re-measured against the
    /// codebase's own WCAG formula.
    ///
    /// **The point of this check is that Dusk is not an inversion.** Two of
    /// §2.4's three correction directions reverse in a dark register: a chip
    /// label has to get *lighter* than its hue there, where in Daylight it got
    /// darker. So this asserts both halves of every pair - the raw value
    /// genuinely fails, and the derived value genuinely clears - which is what
    /// makes each derived colour explained rather than merely tolerated. It
    /// also asserts the *direction* of each correction explicitly, so a future
    /// edit that "tidies" Dusk into a mirror of Daylight's own hexes fails
    /// here with the reason rather than shipping illegible chips.
    ///
    /// The four surfaces every measurement runs against are the four real
    /// grounds running text lands on in this design: the card, the page, an
    /// input well, and a hovered row. Daylight's own check uses three; the
    /// hover fill matters more here because in a dark register it is the
    /// *lightest* of the four and therefore the worst case for light ink.
    private static func checkDuskPalette(_ ok: inout Bool) {
        print("\n-- dusk palette (phase 6: daylight's dark register, every derived value measured) --")
        guard let dusk = HelmTheme.theme(id: "dusk") else {
            print("  FAIL the dusk theme is not in HelmTheme.allThemes")
            ok = false
            return
        }
        guard let daylight = HelmTheme.theme(id: "daylight") else { return }
        let t = DaylightTokens.dusk
        let floor = HelmContrast.textTarget
        let card = HelmTheme.nsColor(t.card)
        let paper = HelmTheme.nsColor(t.paper)
        let inset = HelmTheme.nsColor(t.inset)
        let rowHover = HelmTheme.nsColor(t.rowHover)
        let surfaces: [(String, NSColor)] = [("card", card), ("paper", paper),
                                             ("inset", inset), ("rowHover", rowHover)]

        func expectAllSurfaces(_ label: String, _ hex: String) {
            let c = HelmTheme.nsColor(hex)
            var worst = ("", Double.greatestFiniteMagnitude)
            var cells: [String] = []
            for (name, surface) in surfaces {
                let r = HelmContrast.ratio(c, surface)
                cells.append("\(name) \(fmt(r))")
                if r < worst.1 { worst = (name, r) }
            }
            if worst.1 < floor - 0.01 {
                print("  FAIL \(label) #\(hex): \(fmt(worst.1)):1 on \(worst.0)")
                ok = false
            } else {
                print("  OK   \(pad(label, 34)) #\(hex)  \(cells.joined(separator: "  "))")
            }
        }
        func expectBelowOnCard(_ label: String, _ hex: String) {
            let r = HelmContrast.ratio(HelmTheme.nsColor(hex), card)
            if r >= floor {
                print("  FAIL \(label) #\(hex) measures \(fmt(r)):1 on the dusk card - it is supposed to FAIL, so the correction it justifies is now unexplained")
                ok = false
            } else {
                print("  OK   \(pad(label, 34)) #\(hex)  \(fmt(r)):1 (correctly below \(fmt(floor)))")
            }
        }

        // Registration and the family pairing.
        if dusk.mode != .dark {
            print("  FAIL dusk must be a dark-mode theme")
            ok = false
        }
        if !dusk.isDaylight || !dusk.isDusk {
            print("  FAIL dusk must answer true to both isDaylight (the design language) and isDusk (the register)")
            ok = false
        }
        if daylight.isDusk {
            print("  FAIL daylight must not answer true to isDusk")
            ok = false
        }
        // A mutual pair, unlike the interim one-way pointer at helm-dark.
        if dusk.pairId != "daylight" || daylight.pairId != "dusk" {
            print("  FAIL daylight/dusk are not a mutual pair (daylight -> \(daylight.pairId), dusk -> \(dusk.pairId))")
            ok = false
        } else {
            print("  OK   \(pad("daylight <-> dusk is a mutual pair", 34)) the quick flip reaches both registers")
        }
        // ...and re-pointing helm-dark's own pair would have changed the quick
        // flip for a captain who has never selected either Daylight theme.
        if HelmTheme.dark.pairId != "helm-light" || HelmTheme.light.pairId != "helm-dark" {
            print("  FAIL helm-dark/helm-light no longer pair with each other")
            ok = false
        }
        if dusk.daylightTokens.card != t.card {
            print("  FAIL dusk.daylightTokens does not resolve to the dusk set")
            ok = false
        }
        if daylight.daylightTokens.card != DaylightTokens.light.card {
            print("  FAIL daylight.daylightTokens does not resolve to the light set")
            ok = false
        }
        for (name, got, want) in [
            ("chromeBackgroundHex = card", dusk.chromeBackgroundHex, t.card),
            ("backgroundHex = paper", dusk.backgroundHex, t.paper),
            ("chromeInkHex = ink", dusk.chromeInkHex, t.ink),
            ("chromeLineHex = hair", dusk.chromeLineHex, t.hair),
            ("accentHex = dusk link blue", dusk.accentHex, t.linkBlue),
        ] where got.lowercased() != want.lowercased() {
            print("  FAIL dusk.\(name): got \(got), want \(want)")
            ok = false
        }

        // Surfaces: a card has to read as a card. Like Daylight (whose own
        // white-on-paper is 1.08:1) the separation is deliberately small and
        // the 1px `hair` border is what carries the boundary, so what is
        // asserted is that the border does its job - not that the fills are
        // far apart.
        let cardVsPaper = HelmContrast.ratio(card, paper)
        let hairVsCard = HelmContrast.ratio(HelmTheme.nsColor(t.hair), card)
        let daylightHairVsCard = HelmContrast.ratio(HelmTheme.nsColor(DaylightTokens.light.hair),
                                                    HelmTheme.nsColor(DaylightTokens.light.card))
        if hairVsCard < daylightHairVsCard - 0.01 {
            print("  FAIL dusk's hair on card (\(fmt(hairVsCard))) is fainter than daylight's (\(fmt(daylightHairVsCard))) - a dark register needs at least as firm an edge")
            ok = false
        } else {
            print("  OK   \(pad("card floats on paper", 34)) \(fmt(cardVsPaper)):1, hair on card \(fmt(hairVsCard)):1 (daylight \(fmt(daylightHairVsCard)))")
        }

        // Ink and muted.
        expectAllSurfaces("ink", t.ink)
        expectAllSurfaces("muted", t.muted)
        expectBelowOnCard("daylight's muted, on dusk", DaylightTokens.light.muted)
        if HelmContrast.ratio(HelmTheme.mutedInk(dusk), HelmTheme.nsColor(t.muted)) > 1.01 {
            print("  FAIL HelmTheme.mutedInk(dusk) is not the dusk muted token")
            ok = false
        }
        // Muted has to be *muted*: dimmer than ink, and not so bright it is a
        // second ink. Daylight's own worst-surface muted measures 4.53.
        let mutedWorst = surfaces.map { HelmContrast.ratio(HelmTheme.nsColor(t.muted), $0.1) }.min() ?? 0
        let inkWorst = surfaces.map { HelmContrast.ratio(HelmTheme.nsColor(t.ink), $0.1) }.min() ?? 0
        if mutedWorst >= inkWorst {
            print("  FAIL dusk muted is not dimmer than dusk ink")
            ok = false
        }
        if mutedWorst > 6.0 {
            print("  FAIL dusk muted measures \(fmt(mutedWorst)):1 at worst - that is an ink, not a muted (daylight's is 4.53)")
            ok = false
        }
        expectBelowOnCard("faint (decorative only)", t.faint)

        // The blue, and the reason it had to move at all.
        expectBelowOnCard("raw domain blue", HelmDomainHue.blue.daylightH1ForTests)
        expectBelowOnCard("daylight's corrected link blue", DaylightTokens.light.linkBlue)
        expectAllSurfaces("dusk link blue", t.linkBlue)
        expect(&ok, "selection text on selection fill",
               HelmContrast.ratio(HelmTheme.nsColor(dusk.selectionTextHex),
                                  HelmTheme.nsColor(dusk.selectionHex)), floor)

        // Chip labels on their own wash, and the direction reversal that is
        // the whole reason this palette could not be an inversion.
        for (name, hue, duskText, lightText, wash) in [
            ("ok", DaylightPalette.ok, t.okText, DaylightTokens.light.okText, 0.12),
            ("warn", DaylightPalette.warn, t.warnText, DaylightTokens.light.warnText, 0.14),
            ("bad", DaylightPalette.bad, t.badText, DaylightTokens.light.badText, 0.12),
        ] {
            let fill = HelmContrast.mix(HelmContrast.components(HelmTheme.nsColor(hue)),
                                        HelmContrast.components(card), wash)
            let rawR = HelmContrast.ratio(HelmContrast.components(HelmTheme.nsColor(hue)), fill)
            let duskR = HelmContrast.ratio(HelmContrast.components(HelmTheme.nsColor(duskText)), fill)
            if rawR >= floor {
                print("  FAIL raw \(name) label on its dusk wash measures \(fmt(rawR)):1 - it is supposed to fail")
                ok = false
            }
            expect(&ok, "corrected \(name) label on its dusk wash", duskR, floor)
            let lum = { HelmContrast.relativeLuminance(HelmContrast.components(HelmTheme.nsColor($0))) }
            if lum(duskText) <= lum(hue) {
                print("  FAIL dusk's \(name) correction is not LIGHTER than the raw hue - a dark-register chip label has to lighten")
                ok = false
            }
            if lum(lightText) >= lum(hue) {
                print("  FAIL daylight's \(name) correction is not darker than the raw hue - the two registers should correct in opposite directions")
                ok = false
            }
        }
        print("  OK   \(pad("chip corrections reverse direction", 34)) dusk lightens where daylight darkens - not an inversion of hexes")

        // ANSI. Slot 0 is exempt by nature, as it is in every dark palette:
        // a terminal's black cannot separate from a dark background, and
        // lightening it until it could would stop it being black.
        let blackVsPaper = HelmContrast.ratio(HelmTheme.nsColor(dusk.ansiHex[0]), paper)
        let helmDarkBlack = HelmContrast.ratio(HelmTheme.nsColor(HelmTheme.dark.ansiHex[0]),
                                               HelmTheme.nsColor(HelmTheme.dark.backgroundHex))
        var worstAnsi = (index: -1, ratio: Double.greatestFiniteMagnitude)
        for (i, hex) in dusk.ansiHex.enumerated() where i > 0 {
            let r = HelmContrast.ratio(HelmTheme.nsColor(hex), paper)
            if r < worstAnsi.ratio { worstAnsi = (i, r) }
            if r < floor - 0.01 {
                print("  FAIL ansi[\(i)] \(hex) on paper: \(fmt(r)):1")
                ok = false
            }
        }
        print("  OK   \(pad("ansi[1...15] on paper", 34)) worst is ansi[\(worstAnsi.index)] at \(fmt(worstAnsi.ratio)):1")
        print("  NOTE \(pad("ansi[0] (\"black\") is \(fmt(blackVsPaper)):1", 34)) exempt by nature - helm-dark's own is \(fmt(helmDarkBlack)):1")
        // On a dark ground "brighter" has to mean lighter. This is the mirror
        // of the call Daylight makes when it blends 15% *black* into each
        // normal sibling, and getting it backwards is the single easiest way
        // to ship an unreadable bright palette.
        for i in 9...14 {
            let normal = HelmContrast.relativeLuminance(HelmContrast.components(HelmTheme.nsColor(dusk.ansiHex[i - 8])))
            let bright = HelmContrast.relativeLuminance(HelmContrast.components(HelmTheme.nsColor(dusk.ansiHex[i])))
            if bright <= normal {
                print("  FAIL ansi[\(i)] is not lighter than ansi[\(i - 8)] - on a dark ground bright must mean lighter")
                ok = false
            }
        }
        print("  OK   \(pad("bright slots are lighter", 34)) mirrors daylight, where they are darker")
    }

    private static func expect(_ ok: inout Bool, _ label: String, _ value: Double, _ target: Double) {
        if value < target - 0.01 {
            print("  FAIL \(label): \(fmt(value)):1, want >= \(fmt(target))")
            ok = false
        } else {
            print("  OK   \(pad(label, 34)) \(fmt(value)):1")
        }
    }

    // MARK: Daylight - per-domain hues and the per-theme fallback

    /// Section 2.2's hue table plus 2.8's requirement that it resolve per
    /// theme.
    ///
    /// The load-bearing half is the **fallback**: a Phase 2/4 component asks
    /// for "the Hosts hue" unconditionally, so a captain on any of the 12
    /// pre-existing palettes has to get a real, in-palette, legible pair back.
    /// That is asserted for every theme, not just Daylight.
    private static func checkDaylightDomainHues(_ ok: inout Bool) {
        print("\n-- daylight domain hues (section 2.2 table, 2.8 per-theme fallback) --")
        guard let daylight = HelmTheme.theme(id: "daylight") else { return }

        var seen: [String: String] = [:]
        for hue in HelmDomainHue.allCases {
            let pair = hue.pair(in: daylight)
            let key = hexString(pair.h1)
            if let clash = seen[key] {
                print("  FAIL \(hue.rawValue) and \(clash) resolve to the same h1 (\(key)) on daylight")
                ok = false
            }
            seen[key] = hue.rawValue
            let l1 = HelmContrast.relativeLuminance(HelmContrast.components(pair.h1))
            let l2 = HelmContrast.relativeLuminance(HelmContrast.components(pair.h2))
            if l2 <= l1 {
                print("  FAIL \(hue.rawValue): h2 is not lighter than h1 on daylight")
                ok = false
            }
        }
        print("  OK   seven distinct hues on daylight, every h2 lighter than its h1")

        for theme in HelmTheme.allThemes {
            var cells: [String] = []
            for hue in HelmDomainHue.allCases {
                let pair = hue.pair(in: theme)
                let l1 = HelmContrast.relativeLuminance(HelmContrast.components(pair.h1))
                let l2 = HelmContrast.relativeLuminance(HelmContrast.components(pair.h2))
                if l2 < l1 - 0.0001 {
                    print("  FAIL \(theme.id) \(hue.rawValue): fallback h2 is darker than h1")
                    ok = false
                }
                let glyph = HelmGradientTile.glyphColor(for: hue, theme: theme)
                let r = HelmContrast.ratio(glyph, pair.h1)
                if r < HelmContrast.nonTextTarget - 0.01 {
                    print("  FAIL \(theme.id) \(hue.rawValue): glyph on h1 is \(fmt(r)):1")
                    ok = false
                }
                cells.append("\(hue.rawValue.prefix(2)) \(fmt(r))")
            }
            print("  \(pad(theme.id, 20)) \(cells.joined(separator: " "))")
        }

        let setup: [RailDestination] = [.updates, .bootstrap, .automation, .githubSync]
        if Set(setup.map { $0.domainHue }).count != 1 {
            print("  FAIL the four Setup sub-pages do not share one domain hue")
            ok = false
        }
        let owners = Set(RailDestination.allCases.map { $0.domainHue })
        let unowned = HelmDomainHue.allCases.filter { !owners.contains($0) }
        if unowned.isEmpty {
            print("  OK   all \(RailDestination.allCases.count) destinations mapped; every hue owns at least one area")
        } else {
            print("  NOTE hues with no destination: \(unowned.map { $0.rawValue }.joined(separator: ", "))")
        }
    }

    // MARK: Daylight - the radius scale is the enforced set

    /// Section 2.6 states its radii as complete: "no other radius values are
    /// allowed". This asserts the set is exactly those nine values, that every
    /// named Daylight token is a member, and that the one component Phase 1
    /// ships (`HelmGradientTile`) picks its radii from it rather than a
    /// literal.
    private static func checkDaylightRadiiScale(_ ok: inout Bool) {
        print("\n-- daylight radii (section 2.6, the complete allowed set) --")
        let want: Set<CGFloat> = [20, 24, 18, 16, 14, 12, 10, 8, 999]
        if HelmMetrics.daylightRadii != want {
            print("  FAIL HelmMetrics.daylightRadii is \(HelmMetrics.daylightRadii.sorted()), want \(want.sorted())")
            ok = false
        }
        let tokens: [(String, CGFloat)] = [
            ("dModule", HelmMetrics.dModule), ("dSheet", HelmMetrics.dSheet),
            ("dBar", HelmMetrics.dBar), ("dSurface", HelmMetrics.dSurface),
            ("dWell", HelmMetrics.dWell), ("dTileLarge", HelmMetrics.dTileLarge),
            ("dTileSmall", HelmMetrics.dTileSmall), ("dLogoDot", HelmMetrics.dLogoDot),
            ("dCapsule", HelmMetrics.dCapsule),
        ]
        for (name, value) in tokens where !HelmMetrics.daylightRadii.contains(value) {
            print("  FAIL HelmMetrics.\(name) = \(value) is not in the allowed set")
            ok = false
        }
        for size in [HelmGradientTile.Size.logo, .module, .drill]
        where !HelmMetrics.daylightRadii.contains(size.cornerRadius) {
            print("  FAIL HelmGradientTile.Size.\(size) radius \(size.cornerRadius) is not in the allowed set")
            ok = false
        }
        if HelmMetrics.capsuleRadius(forHeight: 28) != 14 {
            print("  FAIL capsuleRadius(forHeight: 28) is \(HelmMetrics.capsuleRadius(forHeight: 28)), want 14")
            ok = false
        }
        print("  OK   \(tokens.count) tokens, all in the 9-value set; capsule clamps to half its height")
    }

    // MARK: Daylight - the two elevation levels

    /// Exactly two depth levels, Daylight's matching section 2.5's measured
    /// values, and - the regression half - the pre-existing themes' `.resting`
    /// shadow byte-identical to what `ConsoleCardChrome` has always rendered.
    private static func checkDaylightElevation(_ ok: inout Bool) {
        print("\n-- daylight elevation (section 2.5, two levels) --")
        guard let daylight = HelmTheme.theme(id: "daylight") else { return }
        let resting = HelmCard.elevation(for: daylight, level: .resting)
        let raised = HelmCard.elevation(for: daylight, level: .raised)
        func check(_ label: String, _ shadow: NSShadow, alpha: CGFloat, blur: CGFloat, dy: CGFloat) {
            let a = shadow.shadowColor?.alphaComponent ?? 0
            if abs(a - alpha) > 0.005 || abs(shadow.shadowBlurRadius - blur) > 0.01
                || abs(shadow.shadowOffset.height - dy) > 0.01 {
                print("  FAIL \(label): alpha \(fmt(Double(a))) blur \(shadow.shadowBlurRadius) dy \(shadow.shadowOffset.height), want \(alpha)/\(blur)/\(dy)")
                ok = false
            } else {
                print("  OK   \(pad(label, 30)) alpha \(fmt(Double(a)))  blur \(blur)  dy \(dy)")
            }
        }
        check("daylight resting", resting, alpha: 0.10, blur: 15, dy: -6)
        check("daylight raised", raised, alpha: 0.15, blur: 28, dy: -14)
        let ink = HelmTheme.nsColor(DaylightPalette.shadowInk)
        if let c = resting.shadowColor?.withAlphaComponent(1),
           HelmContrast.ratio(c, ink) > 1.01 {
            print("  FAIL daylight's shadow is not ink-tinted")
            ok = false
        }
        for theme in HelmTheme.allThemes where !theme.isDaylight {
            let r = HelmCard.elevation(for: theme, level: .resting)
            let expected: CGFloat = theme.mode == .dark ? 0.45 : 0.24
            let a = r.shadowColor?.alphaComponent ?? 0
            if abs(a - expected) > 0.005 || r.shadowBlurRadius != 16 || r.shadowOffset.height != -5 {
                print("  FAIL \(theme.id) resting drifted from the historical shadow")
                ok = false
            }
            let up = HelmCard.elevation(for: theme, level: .raised)
            if up.shadowBlurRadius <= r.shadowBlurRadius
                || abs(up.shadowOffset.height) <= abs(r.shadowOffset.height) {
                print("  FAIL \(theme.id) raised is not deeper than resting")
                ok = false
            }
        }
        let byDefault = HelmCard.elevation(for: HelmTheme.dark)
        if byDefault.shadowBlurRadius != HelmCard.elevation(for: HelmTheme.dark, level: .resting).shadowBlurRadius {
            print("  FAIL elevation(for:)'s default level is not .resting")
            ok = false
        }
        print("  OK   12 pre-existing palettes keep their historical resting shadow")
    }

    // MARK: Daylight - the new type roles

    /// The roles section 3 adds, plus the two deferrals Phase 1 made on
    /// purpose.
    ///
    /// The deferrals are asserted, not just commented: `body()` staying at 12
    /// and `pageTitle(.serif)` staying Georgia are deliberate Phase 1
    /// decisions (section 3 retunes both, and both are visible app-wide
    /// restyles that belong to Phase 4), so a future edit that "fixes" them
    /// has to change this test and read why.
    private static func checkDaylightTypeRoles(_ ok: inout Bool) {
        print("\n-- daylight type roles (section 3) --")
        let roles: [(String, NSFont, CGFloat)] = [
            ("heroTitle", HelmType.heroTitle(), 30),
            ("drillTitle", HelmType.drillTitle(), 26),
            ("moduleTitle", HelmType.moduleTitle(), 13.5),
            ("moduleMetric", HelmType.moduleMetric(), 34),
            ("metricUnit", HelmType.metricUnit(), 12),
            ("cardTitle", HelmType.cardTitle(), 13.5),
            ("captionSmall", HelmType.captionSmall(), 10.5),
            ("chip", HelmType.chip(), 10.5),
        ]
        for (name, font, designed) in roles {
            let want = HelmType.scaled(designed)
            if abs(font.pointSize - want) > 0.01 {
                print("  FAIL \(name) is \(font.pointSize)pt, want \(want) (designed \(designed))")
                ok = false
            }
            if font.pointSize < HelmType.minimumUIPointSize {
                print("  FAIL \(name) is below the \(HelmType.minimumUIPointSize)pt floor")
                ok = false
            }
        }
        let plain = NSFont.systemFont(ofSize: HelmType.scaled(30), weight: .heavy)
        if HelmType.heroTitle().fontName == plain.fontName {
            print("  FAIL heroTitle resolves to the plain system face (\(plain.fontName)) - the rounded design did not apply")
            ok = false
        } else {
            print("  OK   rounded display face resolves: \(HelmType.heroTitle().fontName)")
        }
        if abs(HelmType.body().pointSize - HelmType.scaled(12)) > 0.01 {
            print("  FAIL body() moved off 12 - section 3's bump to 13.5 is a Phase 4 restyle, not a token change")
            ok = false
        }
        if HelmType.pageTitle(.serif).fontName == HelmType.pageTitle(.sans).fontName {
            print("  FAIL pageTitle(.serif) no longer resolves to its own face - serif retirement is Phase 2/4's, via heroTitle/drillTitle")
            ok = false
        }
        print("  OK   \(roles.count) new roles; body() and pageTitle(.serif) unchanged, as Phase 1 requires")
    }

    // MARK: Daylight - the gradient tile

    /// `HelmGradientTile`'s anatomy: section 6.2's three sizes, a real
    /// two-stop gradient filling the tile, a resolved symbol, and a glyph
    /// colour that clears the icon floor in **every** theme.
    private static func checkGradientTileRecipe(_ ok: inout Bool) {
        print("\n-- HelmGradientTile (section 6.2) --")
        let sizes: [(HelmGradientTile.Size, CGFloat)] = [(.logo, 22), (.module, 30), (.drill, 34)]
        for (size, side) in sizes {
            let tile = HelmGradientTile(size: size)
            tile.configure(symbol: "sailboat.fill", hue: .blue)
            tile.frame = NSRect(x: 0, y: 0, width: side, height: side)
            tile.layoutSubtreeIfNeeded()
            let g = tile.geometryForTests
            if abs(g.side - side) > 0.01 {
                print("  FAIL \(size) is \(g.side)pt wide, want \(side)")
                ok = false
            }
            if abs(g.cornerRadius - size.cornerRadius) > 0.01 {
                print("  FAIL \(size) radius \(g.cornerRadius), want \(size.cornerRadius)")
                ok = false
            }
            if g.gradientColorCount != 2 {
                print("  FAIL \(size) gradient has \(g.gradientColorCount) stops, want 2")
                ok = false
            }
            if g.gradientFrame != tile.bounds {
                print("  FAIL \(size) gradient frame \(g.gradientFrame) does not fill \(tile.bounds)")
                ok = false
            }
            if !g.hasImage {
                print("  FAIL \(size) has no glyph - the symbol did not resolve")
                ok = false
            }
            print("  OK   \(pad("\(size)", 8)) \(g.side)pt  r\(g.cornerRadius)  2 stops  glyph present")
        }
        for destination in RailDestination.allCases {
            let tile = HelmGradientTile(size: .drill)
            tile.configure(for: destination)
            if !tile.geometryForTests.hasImage {
                print("  FAIL \(destination.title): SF Symbol '\(destination.symbol)' did not resolve")
                ok = false
            }
        }
        print("  OK   all \(RailDestination.allCases.count) destination symbols resolve on a gradient tile")

        // It themes itself: a theme change has to repaint both stops from that
        // theme's own resolution of the hue, with no help from a page. Checked
        // on Daylight (where the §2.2 table applies) and on one fallback
        // palette (where §2.8's `HelmTint` derivation does), because a tile
        // that only ever read the table would pass the first and fail the
        // second silently.
        guard let daylight = HelmTheme.theme(id: "daylight") else { return }
        let tile = HelmGradientTile(size: .drill)
        tile.configure(symbol: "lock.fill", hue: .violet)
        for theme in [daylight, HelmTheme.gruvboxLight] {
            tile.applyTheme(theme)
            let want = HelmDomainHue.violet.pair(in: theme)
            let got = tile.resolvedColorsForTests
            guard let h1 = got.h1, let h2 = got.h2, let glyph = got.glyph else {
                print("  FAIL \(theme.id): tile has no resolved colours after applyTheme")
                ok = false
                continue
            }
            if HelmContrast.ratio(h1, want.h1) > 1.01 || HelmContrast.ratio(h2, want.h2) > 1.01 {
                print("  FAIL \(theme.id): stops \(hexString(h1))/\(hexString(h2)) do not match the resolved pair \(hexString(want.h1))/\(hexString(want.h2))")
                ok = false
            }
            if HelmContrast.ratio(glyph, want.h1) < HelmContrast.nonTextTarget - 0.01 {
                print("  FAIL \(theme.id): glyph does not clear the icon floor after applyTheme")
                ok = false
            }
        }
        print("  OK   re-themes both stops and its glyph from the active theme's own resolution")
    }

    // MARK: Helpers

    /// The chip's own fill is the hue washed over a surface; the label has to
    /// clear the floor on whichever surface the chip actually landed on, so
    /// score the worst of the two.
    private static func worstRatio(foreground: NSColor, tintHex: String, theme: HelmTheme, wash: CGFloat) -> Double {
        let tint = HelmContrast.components(HelmTheme.nsColor(tintHex))
        let fg = HelmContrast.components(foreground)
        return [theme.chromeBackgroundHex, theme.backgroundHex].map { surfaceHex -> Double in
            let surface = HelmContrast.components(HelmTheme.nsColor(surfaceHex))
            return HelmContrast.ratio(fg, HelmContrast.mix(tint, surface, Double(wash)))
        }.min() ?? 0
    }

    /// Contrast of a possibly-translucent colour once composited over an
    /// opaque surface - what the eye actually sees.
    private static func flattenedRatio(_ color: NSColor, over surfaceHex: String) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        let surface = HelmContrast.components(HelmTheme.nsColor(surfaceHex))
        let straight = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        let flattened = HelmContrast.mix(straight, surface, Double(c.alphaComponent))
        return HelmContrast.ratio(flattened, surface)
    }

    /// Component-wise colour equality.
    ///
    /// **Not** `HelmContrast.ratio(a, b) < 1.01` - that compares relative
    /// *luminance*, so two entirely different hues of similar brightness pass
    /// it (AGENTS.md records this trap costing real time twice already).
    private static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    /// `#RRGGBB` for a colour, used only in this file's own printouts.
    private static func hexString(_ color: NSColor) -> String {
        let c = HelmContrast.components(color)
        return String(format: "#%02X%02X%02X",
                      Int((c.0 * 255).rounded()), Int((c.1 * 255).rounded()), Int((c.2 * 255).rounded()))
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}

#endif
