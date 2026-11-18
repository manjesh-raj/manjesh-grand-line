// Grand Line - native macOS app.
//
// S03 of the 2026-11-17 UI/UX proposals: where a page's header line and its
// first content start, measured the way the proposals measured them.
//
// The scout read every page's render back with a small pixel tool
// (`evidence/firstcontent.swift` in the proposals' data folder): scan down a
// column inside the content column and report the first row whose colour is
// not the page ground. This is that scan in-process, over the content pane
// the shell actually laid out, so a suite can assert it and the tour lab can
// print it.
//
// Two numbers, both in window points from the window's top edge (the unit
// the proposals' chart uses):
//
//   - `headerInk`: the first non-ground row inside the header line's slot
//     (`HelmMetrics.pageHeaderLine` under the toolbar) - its text, or nil
//     for an empty line.
//   - `firstContent`: the first non-ground row below the header line's slot.
//     That is the page's own first content, or Console's session strip,
//     which the shell puts at the same line.
//
// The scan covers the page's content column only. A page whose own sidebar
// lives in a `HelmSplitPage` is scanned right of that sidebar, because a side
// column's fill runs from the top of the page and is a column surface, not
// the page's first content. The trailing 24pt are left out too: a runner
// with always-visible scrollbars draws a scroller track from the top of every
// scroll view.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum PageScaffoldProbe {

    struct Reading {
        /// The toolbar's bottom edge: the content pane's safe-area top.
        let toolbarBottom: CGFloat
        /// The top of the page body (the shell's body container).
        let bodyTop: CGFloat
        let headerInk: CGFloat?
        let firstContent: CGFloat?
        /// The content column the scan covered, in window points.
        let columnMinX: CGFloat
        let columnMaxX: CGFloat

        var line: String {
            func show(_ value: CGFloat?) -> String { value.map { String(format: "%.1f", $0) } ?? "none" }
            return "toolbar \(show(toolbarBottom)) body \(show(bodyTop)) header \(show(headerInk)) "
                + "first \(show(firstContent)) column \(Int(columnMinX))-\(Int(columnMaxX))"
        }
    }

    /// How far below the toolbar the scan looks: 40pt past the line. A page
    /// whose first content has drifted shows up inside it, and a page-level
    /// empty state (centred in the page, far lower) does not read as first
    /// content - such a page reads `none`.
    static let scanDepth: CGFloat = HelmMetrics.pageContentTop + 40

    static func measure(_ shell: MainSplitShellController) -> Reading? {
        let pane = shell.debugContentPane
        pane.layoutSubtreeIfNeeded()
        guard let window = pane.window, pane.bounds.width > 0, pane.bounds.height > 0 else { return nil }
        let windowHeight = window.frame.height
        func windowTop(_ y: CGFloat, in view: NSView) -> CGFloat {
            windowHeight - view.convert(NSPoint(x: 0, y: y), to: nil).y
        }
        let safe = pane.safeAreaRect
        let toolbarBottom = windowTop(pane.isFlipped ? safe.minY : safe.maxY, in: pane)
        let body = shell.debugBodyContainer
        let bodyTop = windowTop(body.isFlipped ? body.bounds.minY : body.bounds.maxY, in: body)

        // The content column: the page body, less a split page's sidebar.
        var column = body.convert(body.bounds, to: nil)
        if let page = shell.workspace.content.visibleDestinationView(),
           let split = splitPage(showing: page, in: shell), !split.sidebarItem.isCollapsed {
            column = split.contentPane.convert(split.contentPane.bounds, to: nil)
        }
        var minX = column.minX + HelmMetrics.s2
        let maxX = column.maxX - HelmMetrics.pageGutter
        guard maxX > minX, let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return nil }
        pane.cacheDisplay(in: pane.bounds, to: rep)

        let theme = ThemeManager.shared.theme
        guard let ground = HelmTheme.nsColor(theme.backgroundHex).usingColorSpace(rep.colorSpace) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / pane.bounds.width
        // A row is ground when every sampled pixel is within 0.03 of the
        // ground in every channel. The sample is read raw, in the rep's own
        // space (AGENTS.md's probe rule).
        func isGround(windowY: CGFloat) -> Bool {
            let local = pane.convert(NSPoint(x: 0, y: windowHeight - windowY), from: nil)
            let py = Int((pane.isFlipped ? local.y : pane.bounds.height - local.y) * scale)
            guard py >= 0, py < rep.pixelsHigh else { return true }
            var x = minX
            while x <= maxX {
                let px = Int(pane.convert(NSPoint(x: x, y: 0), from: nil).x * scale)
                if px >= 0, px < rep.pixelsWide, let c = rep.colorAt(x: px, y: py), c.alphaComponent > 0.5 {
                    if abs(c.redComponent - ground.redComponent) > 0.03
                        || abs(c.greenComponent - ground.greenComponent) > 0.03
                        || abs(c.blueComponent - ground.blueComponent) > 0.03 {
                        return false
                    }
                }
                x += HelmMetrics.s1
            }
            return true
        }
        func firstInk(from start: CGFloat, to end: CGFloat) -> CGFloat? {
            var y = start
            while y < end {
                if !isGround(windowY: y) { return y }
                y += 0.5
            }
            return nil
        }
        let slotBottom = toolbarBottom + HelmMetrics.pageHeaderLine
        // The header line spans the whole content column, side band included.
        let header = firstInk(from: toolbarBottom + 1, to: slotBottom)
        // A side column drawn in its own fill from the top of the page (the
        // band Commands and Code draw without a `HelmSplitPage`) is not the
        // page's first content either: skip a leading run of non-ground
        // pixels on the first row under the header line.
        func isGroundPixel(_ x: CGFloat, _ windowY: CGFloat) -> Bool {
            let local = pane.convert(NSPoint(x: x, y: windowHeight - windowY), from: nil)
            let px = Int(local.x * scale)
            let py = Int((pane.isFlipped ? local.y : pane.bounds.height - local.y) * scale)
            guard px >= 0, px < rep.pixelsWide, py >= 0, py < rep.pixelsHigh,
                  let c = rep.colorAt(x: px, y: py) else { return true }
            return abs(c.redComponent - ground.redComponent) <= 0.03
                && abs(c.greenComponent - ground.greenComponent) <= 0.03
                && abs(c.blueComponent - ground.blueComponent) <= 0.03
        }
        var bandEnd = column.minX
        while bandEnd < column.minX + column.width * 0.45, !isGroundPixel(bandEnd + 1, slotBottom + 2) {
            bandEnd += 1
        }
        if bandEnd > column.minX + HelmMetrics.s5 { minX = bandEnd + HelmMetrics.s2 }
        let first = firstInk(from: slotBottom, to: toolbarBottom + scanDepth)
        return Reading(toolbarBottom: toolbarBottom, bodyTop: bodyTop, headerInk: header, firstContent: first,
                       columnMinX: minX, columnMaxX: maxX)
    }

    /// The `HelmSplitPage` inside the page on screen, if it has one.
    private static func splitPage(showing page: NSView, in shell: MainSplitShellController) -> HelmSplitPage? {
        for slot in shell.workspace.content.mounter.mountedSlots where slot.controller.view === page {
            return (slot.controller as? HelmSplitPageHosting)?.splitPage
        }
        return nil
    }
}

#endif
