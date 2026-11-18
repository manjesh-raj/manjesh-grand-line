// Grand Line - native macOS app.
//
// S03 of the 2026-11-17 UI/UX proposals: one page frame, so every page
// starts its first content at the same height.
//
// Every destination used to assemble its own frame - a scroll view, a
// flipped document, a gutter, and a top constant of its own choosing - and
// the result was measurable: the first piece of content started at ten
// different heights across the pages, from 76pt (Commands) to 117pt (Tasks,
// Calendar), and switching pages made the content jump by up to 41pt.
//
// The frame has three parts, top to bottom, every one of them the same on
// every page:
//
//   1. The header line (`HelmMetrics.pageHeaderLine`, 32pt under the
//      toolbar): the page's subtitle, a control on that line, or nothing. It
//      keeps its height when it is empty. In the sidebar layout the shell
//      draws it (`WorkspaceModuleHeader`), because it is chrome the page
//      does not scroll; `headerLineTextTop` is where its text sits.
//   2. The first content (`HelmMetrics.pageContentTop`, 44pt under the
//      toolbar): a filter row, a number strip, the first card or a tab row.
//      A page reaches it by leaving `HelmMetrics.pageContentInset` above its
//      first content - which is what this view does for a scrolling page,
//      and what `pinFirstContent` does for a page that does not scroll.
//   3. The content column: `pageGutter` either side, `s5` at the foot.
//
// A scrolling page hands this view its content and keeps none of the
// mechanics: the scroll view, the flipped document (gotcha (9)), the
// document pinned to the clip view rather than the scroll view (gotcha (4)),
// the gutter and the top inset are all here. An optional top slot carries a
// row that stays put while the content scrolls under it (a filter bar).
//
// The view paints nothing. The page's root keeps painting the page ground,
// as it always has.

import AppKit

final class HelmPageScaffold: NSView {

    /// The insets around a scrolling page's content column.
    static var contentInsets: NSEdgeInsets {
        NSEdgeInsets(top: HelmMetrics.pageContentInset, left: HelmMetrics.pageGutter,
                     bottom: HelmMetrics.s5, right: HelmMetrics.pageGutter)
    }

    /// Where the header line's text starts inside its 32pt slot.
    static let headerLineTextTop: CGFloat = HelmMetrics.s3

    /// For a page that does not scroll (a terminal, a web island, a split
    /// page's own column): `view`'s top at the first-content line inside
    /// `container`, which fills the page from its top.
    static func pinFirstContent(_ view: NSView, in container: NSView) -> NSLayoutConstraint {
        view.topAnchor.constraint(equalTo: container.topAnchor, constant: HelmMetrics.pageContentInset)
    }

    let scrollView = NSScrollView()
    /// Flipped, so a document shorter than the viewport rests at the top.
    let documentView = FlippedView()
    /// The content column. Vertical, leading-aligned; `addContent` makes a
    /// view fill its width.
    let stack = NSStackView()
    /// The row that stays put above the scrolling content, if any.
    private(set) var topSlot: NSView?

    private var scrollTopToSelf: NSLayoutConstraint!
    private var stackTop: NSLayoutConstraint!
    private var slotConstraints: [NSLayoutConstraint] = []

    /// - Parameters:
    ///   - spacing: between the content's blocks.
    ///   - bottomInset: below the last block.
    init(spacing: CGFloat = HelmMetrics.s4, bottomInset: CGFloat = HelmMetrics.s5) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let insets = Self.contentInsets
        scrollTopToSelf = scrollView.topAnchor.constraint(equalTo: topAnchor)
        stackTop = stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: insets.top)
        NSLayoutConstraint.activate([
            scrollTopToSelf,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Gotcha (4): the clip view, never the scroll view.
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stackTop,
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: insets.left),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -insets.right),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -bottomInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Fill `container` edge to edge - the page's root, under nothing.
    func install(in container: NSView) {
        container.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: container.topAnchor),
            leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Add a block to the content column. A block that `fillsWidth` is as
    /// wide as the column; one that does not keeps its own width at the
    /// leading edge.
    func addContent(_ view: NSView, fillsWidth: Bool = true) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        if fillsWidth { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    /// A row at the first-content line that does not scroll, with the
    /// content scrolling under it. `nil` removes it, and the content's first
    /// block takes the line again.
    func setTopSlot(_ view: NSView?) {
        topSlot?.removeFromSuperview()
        NSLayoutConstraint.deactivate(slotConstraints)
        slotConstraints = []
        topSlot = view
        guard let view else {
            scrollTopToSelf.isActive = true
            stackTop.constant = Self.contentInsets.top
            return
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        scrollTopToSelf.isActive = false
        // The scroll view starts under the row, and the content's own first
        // block leaves the column's ordinary spacing below it.
        stackTop.constant = stack.spacing
        slotConstraints = [
            Self.pinFirstContent(view, in: self),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.pageGutter),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.pageGutter),
            scrollView.topAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(slotConstraints)
    }

    /// Back to the top of the content (gotcha (9): after the document has
    /// its height).
    func scrollToTop() {
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
