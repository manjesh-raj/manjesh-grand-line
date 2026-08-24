// Manjesh Grand Line - native macOS app.
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
                                           spacing: cardSpacing) { item, _ in
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
    /// for why it is a separate type). The compact `IconTileView` card this
    /// replaced had no visible affordance at all: the whole surface was a
    /// click target and nothing said so. The plate keeps that whole-surface
    /// click and adds §7's explicit Open button.
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
                              deleteTooltip: "Delete"))
        return plate
    }

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
