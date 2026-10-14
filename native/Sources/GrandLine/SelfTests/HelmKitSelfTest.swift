// Grand Line - native macOS app.
//
// The UI/UX revamp's component kit (UI-39), the recipe half: what each kit
// piece *paints*, read off the real views after `applyTheme`, across every
// palette where the claim is about contrast.
//
// Run with `FM_RUN_HELM_KIT_TESTS=1 .build/debug/GrandLine`.
//
// **Why this is pure logic.** Every case builds views and reads their layer
// colours, label fonts and attributed strings - none of it needs a window
// server, and none of it reads a resolved frame. The geometry half (where a
// row's text lands, how tall a flat row is) is `HelmKitViewSelfTest`, which
// mounts a real window. So this suite is not in `NEEDS_SESSION` and guards
// CI's blocking lane.
//
// What it covers:
//
//   1. **The three row styles' recipes.** `.card` is unchanged (a tint-washed
//      outline - every unmigrated row depends on that); `.flat` paints no
//      border and no fill of its own, hovers to `rowHover` on Daylight and
//      hides its bar unless the row carries an identity; `.cardFlat` is
//      outlined in the neutral hairline, never in its tint.
//   2. **The row's new text fields.** A trailing caption, a coloured meta
//      lead and a struck title paint what they claim, and the caption and
//      the lead clear 4.5:1 on all 26 palettes.
//   3. **`HelmStatusPill`.** The capsule's word clears 4.5:1 on its fill and
//      the dot-and-word's clears it on the card, for every tint and palette.
//   4. **`HelmSectionHeader`.** A nil count is no count; a dot and a tile are
//      exclusive; the hero eyebrow is upper-cased; actions land in the slot.
//   5. **`HelmFlatList`.** n rows, n-1 hairlines, and a rebuild never
//      doubles them.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum HelmKitSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== HelmKitSelfTest ==")
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }
        autoreleasepool {
            checkRowStyleRecipes(&ok)
            checkRowTextFields(&ok)
            checkStatusPillContrast(&ok)
            checkSectionHeader(&ok)
            checkFlatList(&ok)
        }
        print(ok ? "HelmKitSelfTest: OK" : "HelmKitSelfTest: FAILED")
        return ok
    }

    // MARK: Fixtures

    static func theme(_ id: String) -> HelmTheme {
        HelmTheme.theme(id: id) ?? ThemeManager.shared.theme
    }

    static func same(_ a: NSColor?, _ b: NSColor?, tolerance: Double = 0.01) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) < tolerance && abs(x.1 - y.1) < tolerance && abs(x.2 - y.2) < tolerance
    }

    static func isClear(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB) else { return true }
        return color.alphaComponent < 0.01
    }

    static func content(title: String = "Follow up with Nithin") -> HelmAccentRow.Content {
        HelmAccentRow.Content(tint: .critical, kicker: "Follow-up", title: title)
    }

    // MARK: 1 - row style recipes

    private static func checkRowStyleRecipes(_ ok: inout Bool) {
        let daylight = theme("daylight")

        // `.card`: the unmigrated recipe, unchanged.
        let card = HelmAccentRow(style: .card)
        card.configure(content(), theme: daylight)
        let cardGeo = card.debugGeometry()
        check(card.debugCardBorderWidth == 1, ".card should keep its 1px outline", &ok)
        check(same(cardGeo.cardBorderColor,
                   HelmTheme.nsColor(HelmTint.critical.hex(in: daylight)).withAlphaComponent(HelmAccentRow.borderAlpha)),
              ".card's outline should still be a wash of its own tint", &ok)
        check(!card.debugBarHidden, ".card should draw its bar", &ok)

        // `.flat`: no border, no fill of its own, rowHover on hover.
        let flat = HelmAccentRow(style: .flat)
        flat.configure(content(), theme: daylight)
        check(flat.debugCardBorderWidth == 0, ".flat should draw no outline", &ok)
        check(isClear(flat.debugPaint().fill), ".flat should paint no fill of its own at rest", &ok)
        check(same(flat.debugPaint().hoverFill, HelmTheme.nsColor(daylight.daylightTokens.rowHover)),
              ".flat should hover to Daylight's rowHover token", &ok)
        check(flat.debugBarHidden, ".flat should hide its bar unless the row carries an identity", &ok)
        check(flat.debugGeometry().cardRadius == 0, ".flat should have no radius of its own", &ok)
        var identity = content()
        identity.showsBar = true
        flat.configure(identity, theme: daylight)
        check(!flat.debugBarHidden, ".flat with showsBar should draw the bar", &ok)

        // `.cardFlat`: neutral hairline, never the tint.
        let lane = HelmAccentRow(style: .cardFlat)
        lane.configure(content(), theme: daylight)
        check(lane.debugCardBorderWidth == 1, ".cardFlat should draw a 1px outline", &ok)
        check(same(lane.debugGeometry().cardBorderColor, HelmTheme.nsColor(daylight.chromeLineHex)),
              ".cardFlat's outline should be the hairline, not the tint", &ok)
        check(!same(lane.debugGeometry().cardBorderColor, HelmTheme.nsColor(HelmTint.critical.hex(in: daylight))),
              "the fixture's tint and hairline must differ, or the check above cannot fail", &ok)
        check(same(lane.debugPaint().fill, HelmTheme.nsColor(daylight.chromeBackgroundHex)),
              ".cardFlat should be filled with the card surface", &ok)
        check(lane.debugGeometry().cardRadius == HelmMetrics.rRow, ".cardFlat's radius should be 10", &ok)

        // Selection (UI-28) reads on the flat styles too.
        lane.isRowSelected = true
        check(!same(lane.debugPaint().fill, HelmTheme.nsColor(daylight.chromeBackgroundHex)),
              "a selected .cardFlat should take the accent wash", &ok)

        // The metrics table: the kit's numbers.
        let m = HelmAccentRow.metrics(for: .flat)
        check(m.minHeight == 44 && m.contentVertical == 10 && m.barLeadingInset + 3 + m.contentLeading == 16,
              ".flat should be 10/16 with a 44pt floor, got \(m)", &ok)
        let c = HelmAccentRow.metrics(for: .cardFlat)
        check(c.contentVertical == 10 && c.contentTrailing == 12 && c.cornerRadius == 10,
              ".cardFlat should be 10/12 at radius 10, got \(c)", &ok)
    }

    // MARK: 2 - the row's new text fields

    private static func checkRowTextFields(_ ok: inout Bool) {
        var worstCaption = Double.infinity, worstLead = Double.infinity
        var worstAt = ""
        for palette in HelmTheme.allThemes {
            let row = HelmAccentRow(style: .flat)
            var c = content()
            c.trailingCaption = "Overdue 26 days \u{00B7} since 18 Sep"
            c.trailingCaptionTint = .critical
            c.metaLead = "Due today"
            c.metaLeadTint = .warn
            c.meta = "1/2 subtasks"
            row.configure(c, theme: palette)
            let surface = HelmTheme.nsColor(palette.chromeBackgroundHex)
            if let color = row.debugTrailingCaptionColor {
                let ratio = HelmContrast.ratio(color, surface)
                if ratio < worstCaption { worstCaption = ratio; worstAt = palette.id }
            }
            let meta = row.debugMetaAttributed
            if meta.length > 0, let lead = meta.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
                worstLead = min(worstLead, HelmContrast.ratio(lead, surface))
            }
            if palette.id == "daylight" {
                check(row.debugTrailingCaption == "Overdue 26 days \u{00B7} since 18 Sep",
                      "the trailing caption should paint its text", &ok)
                check(meta.string == "Due today \u{00B7} 1/2 subtasks",
                      "the meta line should read lead then rest, got \"\(meta.string)\"", &ok)
                if meta.length > 12,
                   let rest = meta.attribute(.foregroundColor, at: meta.length - 1, effectiveRange: nil) as? NSColor,
                   let lead = meta.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
                    check(same(rest, HelmTheme.mutedInk(palette)), "the meta remainder should be muted", &ok)
                    check(!same(rest, lead), "the meta lead should be coloured, not muted", &ok)
                }
                var done = content(title: "Check with Nithin")
                done.titleStruck = true
                row.configure(done, theme: palette)
                let title = row.debugTitleAttributed
                check(title.length > 0
                      && (title.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue,
                      "a struck title should carry a strikethrough", &ok)
            }
        }
        check(worstCaption >= HelmContrast.textTarget,
              "a critical trailing caption should clear 4.5:1 on every palette, worst \(worstCaption) on \(worstAt)", &ok)
        check(worstLead >= HelmContrast.textTarget,
              "a warn meta lead should clear 4.5:1 on every palette, worst \(worstLead)", &ok)
    }

    // MARK: 3 - HelmStatusPill

    private static func checkStatusPillContrast(_ ok: inout Bool) {
        let tints: [HelmTint] = [.good, .warn, .critical, .info, .accent, .neutral, .violet]
        var worstPill = Double.infinity, worstDot = Double.infinity
        var worstAt = ""
        for palette in HelmTheme.allThemes {
            for tint in tints {
                let pill = HelmStatusPill(style: .pill)
                pill.configure(text: "Local changes", tint: tint, theme: palette)
                if let fill = pill.debugFill, let ink = pill.debugLabel.textColor {
                    let ratio = HelmContrast.ratio(ink, fill)
                    if ratio < worstPill { worstPill = ratio; worstAt = "\(palette.id)/\(tint)" }
                }
                let word = HelmStatusPill(style: .dotWord)
                word.configure(text: "Synced", tint: tint, theme: palette)
                if let ink = word.debugLabel.textColor {
                    worstDot = min(worstDot, HelmContrast.ratio(ink, HelmTheme.nsColor(palette.chromeBackgroundHex)))
                }
            }
        }
        check(worstPill >= HelmContrast.textTarget,
              "a status pill's word should clear 4.5:1 on its fill everywhere, worst \(worstPill) at \(worstAt)", &ok)
        check(worstDot >= HelmContrast.textTarget,
              "a dot-and-word should clear 4.5:1 on the card everywhere, worst \(worstDot)", &ok)

        let daylight = theme("daylight")
        let word = HelmStatusPill(style: .dotWord)
        word.configure(text: "Synced", tint: .good, theme: daylight)
        check(isClear(word.debugFill), "a dot-and-word should paint no capsule", &ok)
        check(same(word.debugDotColor, HelmTheme.nsColor(HelmTint.good.hex(in: daylight))),
              "a dot-and-word's dot should be its hue", &ok)
        check(word.debugLabel.font == HelmType.chip(), "the pill face should be HelmType.chip()", &ok)
        check(word.accessibilityLabel() == "Synced", "a status pill should announce its word", &ok)
    }

    // MARK: 4 - HelmSectionHeader

    private static func checkSectionHeader(_ ok: inout Bool) {
        let lane = HelmSectionHeader(size: .lane)
        lane.configure(leading: .dot(.warn), title: "In Progress", count: "1")
        check(lane.debugDotVisible && !lane.debugTileVisible, "a lane header shows a dot, not a tile", &ok)
        check(!lane.countLabel.isHidden && lane.countLabel.stringValue == "1", "a lane header shows its count", &ok)
        lane.configure(leading: .dot(.warn), title: "In Progress", count: nil)
        check(lane.countLabel.isHidden, "a nil count should be no count, never a zero", &ok)

        let section = HelmSectionHeader(size: .section)
        section.configure(leading: .tile(symbol: "bell", tint: .warn), title: "Follow-ups", count: "2 pending")
        check(section.debugTileVisible && !section.debugDotVisible, "a section header shows a tile", &ok)
        check(section.titleLabel.font == HelmType.moduleTitle(), "a section header uses moduleTitle", &ok)
        let add = HelmButton(title: "Add", variant: .quiet, size: .small, symbol: "plus")
        section.setActions([add])
        check(section.debugActions.count == 1 && section.debugActions.first === add,
              "an action should land in the trailing slot", &ok)
        section.setActions([])
        check(section.debugActions.isEmpty, "setActions([]) should empty the slot", &ok)

        let hero = HelmSectionHeader(size: .hero)
        hero.configure(leading: .tile(symbol: "exclamationmark.triangle.fill", tint: .critical),
                       title: "Two things are late.", eyebrow: "Needs attention \u{00B7} 2",
                       subline: "Fleet read at 10:18")
        check(hero.eyebrowLabel.stringValue == "NEEDS ATTENTION \u{00B7} 2", "the eyebrow is upper-cased", &ok)
        check(!hero.sublineLabel.isHidden, "the hero shows its subline", &ok)
        check(abs((hero.titleLabel.font?.pointSize ?? 0) - HelmType.scaled(19)) < 0.01,
              "the hero headline is 19pt", &ok)
    }

    // MARK: 5 - HelmFlatList

    private static func checkFlatList(_ ok: inout Bool) {
        let list = HelmFlatList()
        let rows = (0..<3).map { _ in NSView() }
        list.setRows(rows)
        check(list.debugSeparatorCount == 2, "three rows should have two hairlines, got \(list.debugSeparatorCount)", &ok)
        list.setRows(rows)
        check(list.debugSeparatorCount == 2, "a rebuild must not double the hairlines", &ok)
        list.separatesFirstRow = true
        list.setRows(rows)
        check(list.debugSeparatorCount == 3, "separatesFirstRow adds one above the first row", &ok)
        list.setRows([])
        check(list.debugSeparatorCount == 0, "an empty list has no hairlines", &ok)
    }
}

#endif
