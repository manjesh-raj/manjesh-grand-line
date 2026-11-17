// Grand Line - native macOS app.
//
// The plate-card grid shared by the Runbooks and Postmortems destinations.
//
// `fm/grandline-docs-split-runbooks-postmortems` split those two tabs out of
// `DocsController` (which used to hold all three - Playbook, Runbooks,
// Postmortems - as one tabbed page, see that file's own header for the prior
// shape) into their own top-level destinations, `RunbooksController` and
// `PostmortemsController`. Both still need the exact same "compact
// module-style plate, laid out as a wrapping multi-column grid" this file
// used to build inline for each tab - extracted here rather than duplicated,
// since the layout math and the card recipe are byte-for-byte the same for
// both callers.
//
// See `HelmResponsiveGrid`'s own header for the columns-from-container-width
// + partial-last-row-padding approach this reuses (originally
// `ToolsController.rebuildGrid()`'s own math, later lifted into that shared
// component so every page's landing grid shares one definition).

import AppKit

/// One card's content, independent of layout - built fresh from disk on
/// every reload, then re-laid-out (with no disk re-read) on every window
/// resize.
struct DocGridItem {
    let title: String
    let subtitle: String
    /// Hover text for the whole card. Carries what the one-line subtitle no
    /// longer has room for once it shows real metadata - the full title and
    /// the "Updated N ago" timestamp.
    var tooltip: String? = nil
    let icon: String
    let tint: HelmTint
    let onOpen: () -> Void
    let onDelete: (() -> Void)?
    /// S07: a duplicate action, shown on aim beside delete.
    var onDuplicate: (() -> Void)? = nil
}

enum DocsGridSupport {
    static let minCardWidth: CGFloat = 260
    static let cardSpacing: CGFloat = 14

    /// Lays `items` out as a grid of rows, each row a `.fillEqually`
    /// horizontal stack of cards sized to `containerWidth`. Returns the
    /// built rows (to add as arranged subviews of the caller's own vertical
    /// list stack) and the cards themselves (for the caller's own
    /// `applyTheme()` re-tint pass).
    static func layoutGrid(items: [DocGridItem], containerWidth: CGFloat) -> (rows: [NSView], cards: [HelmPlateCard]) {
        var cards: [HelmPlateCard] = []
        let rows = HelmResponsiveGrid.rows(items,
                                           containerWidth: containerWidth,
                                           minItemWidth: minCardWidth,
                                           spacing: cardSpacing,
                                           // S06: each row as tall as its tallest
                                           // plate - a two-line title beside a
                                           // one-line one - and no taller.
                                           equalHeights: true) { item, _ in
            // The width the grid computed is unused: a plate takes its width
            // from the row's `.fillEqually` distribution and its height from
            // its own constant, and it reads the real text-column width back
            // in `layout()` rather than being told an estimate up front.
            let card = buildCard(item)
            cards.append(card)
            return card
        }
        return (rows, cards)
    }

    /// Daylight §7: a "module-style plate" - `HelmPlateCard`, the shared
    /// sibling of the canvas's own `HelmModuleCard` (see that file's header
    /// for why it is a separate type).
    ///
    /// S07 of the 2026-11-17 UI/UX proposals: the plate is the control. The
    /// Open button §7 added sat beside a card that already opened on click,
    /// and the trash glyph showed at rest, so two runbooks drew four controls
    /// for two actions. `.onAim` makes the whole card the button (hover wash,
    /// focus ring, Return) and shows duplicate and delete only on aim.
    ///
    /// The per-kind hue comes from the item's own `HelmTint` through
    /// `HelmDomainHue(tint:)` rather than a second mapping, so a runbook
    /// stays blue (Docs' own domain hue) and a postmortem stays amber
    /// exactly as they did before, in every palette.
    static func buildCard(_ item: DocGridItem) -> HelmPlateCard {
        let plate = HelmPlateCard()
        plate.configure(.init(title: item.title,
                              subtitle: item.subtitle,
                              symbol: item.icon,
                              hue: HelmDomainHue(tint: item.tint),
                              tooltip: item.tooltip,
                              onOpen: item.onOpen,
                              onDelete: item.onDelete,
                              deleteTooltip: "Delete",
                              actionReveal: .onAim,
                              onDuplicate: item.onDuplicate))
        return plate
    }

    /// GL-P3: called once per card, and `HelmResponsiveGrid` re-flows the whole
    /// grid on every window resize - so this ran per card per resize frame.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relativeDate(_ date: Date) -> String {
        // A file written this instant reads "in 0 sec" from the formatter,
        // which treats zero as the future. Under a second is "just now", the
        // wording the Claude card's "Updated just now" already uses.
        let now = Date()
        guard now.timeIntervalSince(date) >= 1 else { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    /// S07: a plate's one meta line - what the document says about itself,
    /// and when it changed. `leadingUpdate` puts the time first, for a
    /// description long enough to truncate (a postmortem's root cause), so
    /// the time is the part that survives.
    static func metaLine(_ detail: String?, modifiedAt: Date, leadingUpdate: Bool = false) -> String {
        let when = relativeDate(modifiedAt)
        guard let detail, !detail.isEmpty else { return "Updated \(when)" }
        return leadingUpdate ? "Updated \(when) \u{00B7} \(detail)" : "\(detail) \u{00B7} updated \(when)"
    }
}
