// Grand Line - native macOS app.
//
// Regression coverage for a real, captain-reported bug on Setup > Updates:
// the page would not scroll with the pointer over the Tools card. It scrolled
// over the margins either side of the card, and stopped the moment the
// pointer crossed into it.
//
// **Root cause.** The Tools card is a `HelmDataTable` with `sizesToFitRows`,
// so the card grows to every row and the page does the scrolling. But the
// table still lives in its own `NSScrollView`, nested inside the page's.
// AppKit has no scroll chaining: a wheel or trackpad event goes to the
// innermost scroll view under the pointer, and a plain `NSScrollView` keeps
// it even when its document fits and it has nothing to scroll. Reproduced
// here before the fix: over the margin the page's scroll view received the
// wheel event, over a tool row the table's own scroll view did and the page
// never saw it. The same table shape is GitHub Sync's forks card, so that tab
// had the same trap. Setup steps and Automation have no nested scroll view
// and did not.
//
// **Fix.** `HelmDataTable`'s scroll view is a `HelmNestedScrollView`, which
// hands the wheel to the page whenever its rows all fit. That is the rule
// Home's Needs Attention list already had in a private copy, now one shared
// component.
//
// **Why this suite records routing rather than a scroll offset.** A
// synthetic wheel event does not move an off-screen window's scroll view,
// even over the margin where nothing is nested (measured while writing this
// suite, and `NeedsAttentionViewSelfTest` measured the same). So an offset
// assertion could never fail. What the event's path does show is which
// scroll view's `scrollWheel(with:)` it reaches, so each case swaps in a
// recorder for `NSScrollView.scrollWheel(with:)` for its own duration. The
// recorder calls the original, so nothing else about dispatch changes.
//
// **Where the event enters, and why there is no window.** Measured too:
// neither `window.sendEvent` nor `NSApplication.sendEvent` delivers a
// `CGEvent`-built wheel event to an off-screen window - zero scroll views
// received it, over the margin as well, with or without the window-number
// fields set. So the suite does what `NSWindow` does with a wheel event:
// hit-test at the pointer and send `scrollWheel(with:)` to the view that
// comes back. From there the real responder chain carries it, which is the
// whole of this bug. The margin case is the control that this entry point
// reaches the page at all. Hit-testing and the responder chain are the view
// tree's own and need no window server, so this suite builds no window and
// runs in CI's blocking headless lane.
//
// Run with:
//   swift build && FM_RUN_HELM_DATA_TABLE_WHEEL_TESTS=1 \
//     .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum HelmDataTableWheelSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkTheUpdatesPageScrollsOverItsToolsCard,
                      checkTheGitHubSyncPageScrollsOverItsForksCard,
                      checkAClippedTableKeepsItsOwnWheel] {
            var ok = true
            autoreleasepool { check(&ok) }
            allOK = allOK && ok
        }
        print(allOK ? "HelmDataTableWheelSelfTest: all checks passed"
                    : "HelmDataTableWheelSelfTest: FAILED")
        return allOK
    }

    // MARK: - Recording which scroll view takes the wheel

    /// Every `NSScrollView` whose own `scrollWheel(with:)` ran, in order. A
    /// subclass that forwards without calling `super` is not recorded, which
    /// is the point: it did not handle the event.
    private static var received: [ObjectIdentifier] = []

    fileprivate static func record(_ scroll: NSScrollView) { received.append(ObjectIdentifier(scroll)) }

    /// Swaps the recorder in for `body`'s duration and puts the original back.
    private static func recordingWheel(_ ok: inout Bool, _ body: () -> Void) {
        guard let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.scrollWheel(with:))),
              let recorder = class_getInstanceMethod(NSScrollView.self,
                                                     #selector(NSScrollView.fm_recordScrollWheel(with:))) else {
            return fail("HelmDataTableWheel: could not install the wheel recorder", &ok)
        }
        method_exchangeImplementations(original, recorder)
        defer { method_exchangeImplementations(original, recorder) }
        body()
    }

    /// Delivers one wheel event at `point` (in `root`'s coordinates) to the
    /// view `root` hit-tests there, and returns the scroll views that handled
    /// it. See the header for why it enters at the hit view.
    ///
    /// The event is built through `CGEvent`, because `NSEvent` has no
    /// scroll-wheel factory.
    private static func dispatchWheel(at point: NSPoint, in root: NSView,
                                      _ ok: inout Bool) -> [ObjectIdentifier] {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: -40, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else {
            fail("HelmDataTableWheel: could not build a wheel event", &ok)
            return []
        }
        check(event.type == .scrollWheel && event.scrollingDeltaY != 0,
              "HelmDataTableWheel: fixture - the event should be a real vertical wheel, "
              + "type \(event.type.rawValue) dy \(event.scrollingDeltaY)", &ok)
        guard let hit = hitView(at: point, in: root) else {
            fail("HelmDataTableWheel: nothing under \(point)", &ok)
            return []
        }
        received = []
        recordingWheel(&ok) { hit.scrollWheel(with: event) }
        return received
    }

    /// The view a wheel at `point` would go to. `root` has no superview and
    /// sits at the origin, so `point` is already in the coordinates
    /// `hitTest` expects.
    private static func hitView(at point: NSPoint, in root: NSView) -> NSView? {
        root.hitTest(point)
    }

    /// The scroll views from the hit view out to `root`, innermost first.
    private static func scrollViews(at point: NSPoint, in root: NSView) -> [NSScrollView] {
        var view = hitView(at: point, in: root)
        var chain: [NSScrollView] = []
        while let current = view {
            if let scroll = current as? NSScrollView { chain.append(scroll) }
            view = current.superview
        }
        return chain
    }

    // MARK: - The shared assertion

    /// A wheel over the table's rows reaches the page's scroll view, and the
    /// table's own scroll view lets it go. A wheel over the page margin is the
    /// control: it proves this dispatch reaches the page at all.
    private static func checkWheelReachesPage(_ name: String, table: HelmDataTable,
                                              page: NSScrollView, root: NSView, _ ok: inout Bool) {
        let card = table.card.convert(table.card.bounds, to: root)
        let visible = page.convert(page.bounds, to: root).intersection(card.insetBy(dx: -10_000, dy: 0))
        // Low in the visible part of the card, so the point is on a row rather
        // than on the card's title or the column header.
        let y = max(card.minY, visible.minY) + min(40, card.height / 4)
        let overRows = NSPoint(x: card.midX, y: y)
        let overMargin = NSPoint(x: visible.minX + 4, y: y)

        // Discriminating power: the row point really is inside the table's
        // own scroll view, nested in the page's, and the margin point is not.
        let rowChain = scrollViews(at: overRows, in: root)
        guard rowChain.count >= 2, rowChain.last === page else {
            return fail("\(name): fixture - the point over the rows should sit in a scroll view nested in the "
                        + "page, found \(rowChain.count) scroll view(s)", &ok)
        }
        let inner = rowChain[0]
        check(inner.isDescendant(of: table.card), "\(name): fixture - the inner scroll view is the table's", &ok)
        check(scrollViews(at: overMargin, in: root).map(ObjectIdentifier.init) == [ObjectIdentifier(page)],
              "\(name): fixture - the margin point should be over the page alone", &ok)

        let marginReceivers = dispatchWheel(at: overMargin, in: root, &ok)
        check(marginReceivers == [ObjectIdentifier(page)],
              "\(name): a wheel over the margin should reach the page - \(marginReceivers.count) receiver(s)", &ok)

        let rowReceivers = dispatchWheel(at: overRows, in: root, &ok)
        check(!rowReceivers.contains(ObjectIdentifier(inner)),
              "\(name): the table's own scroll view kept a wheel event it had nothing to scroll with", &ok)
        check(rowReceivers.contains(ObjectIdentifier(page)),
              "\(name): a wheel over the table's rows should reach the page", &ok)
    }

    // MARK: - Cases

    /// The captain's report, on the real page. Its view is loaded but never
    /// shown, so `viewWillAppear` - which starts real `brew`/`npm` sweeps -
    /// never runs.
    private static func checkTheUpdatesPageScrollsOverItsToolsCard(_ ok: inout Bool) {
        let controller = UpdatesController()
        let root = controller.view
        root.frame = NSRect(x: 0, y: 0, width: 1000, height: 520)
        controller.adoptSidebarLayout()
        root.layoutSubtreeIfNeeded()
        guard let page = root.subviews.compactMap({ $0 as? NSScrollView }).first,
              let document = page.documentView else {
            return fail("Updates: no page scroll view", &ok)
        }
        // The page really does scroll here, so the trap is the one reported.
        check(document.frame.height > page.contentView.bounds.height + 100,
              "Updates: fixture - the page should be taller than its viewport, "
              + "\(document.frame.height) in \(page.contentView.bounds.height)", &ok)
        check(controller.debugToolsTable.sizesToFitRows, "Updates: the Tools table should size to its rows", &ok)
        checkWheelReachesPage("Updates", table: controller.debugToolsTable, page: page, root: root, &ok)
    }

    /// The same table shape on Setup's GitHub Sync tab, loaded the same way
    /// so its `viewWillAppear` never starts a real fork check.
    private static func checkTheGitHubSyncPageScrollsOverItsForksCard(_ ok: inout Bool) {
        let controller = GitHubSyncController()
        let root = controller.view
        root.frame = NSRect(x: 0, y: 0, width: 1000, height: 520)
        controller.adoptSidebarLayout()
        root.layoutSubtreeIfNeeded()
        guard let page = root.subviews.compactMap({ $0 as? NSScrollView }).first else {
            return fail("GitHubSync: no page scroll view", &ok)
        }
        check(controller.debugForksTable.sizesToFitRows, "GitHubSync: the forks table should size to its rows", &ok)
        checkWheelReachesPage("GitHubSync", table: controller.debugForksTable, page: page, root: root, &ok)
    }

    /// The other half of the rule: a table with rows below the fold keeps the
    /// wheel, or forwarding would make its last rows unreachable.
    private static func checkAClippedTableKeepsItsOwnWheel(_ ok: inout Bool) {
        let table = HelmDataTable(columns: [.init(id: "name", title: "Name", width: 200, flexible: true)],
                                  actionsWidth: 80)
        table.setRows((0..<30).map { index in
            var row = HelmDataTable.Row.record("row-\(index)")
            row.cells["name"] = .text("Row \(index)")
            return row
        })
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(table.card)
        NSLayoutConstraint.activate([
            table.card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            table.card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            table.card.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            table.card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        root.layoutSubtreeIfNeeded()

        let card = table.card.convert(table.card.bounds, to: root)
        let point = NSPoint(x: card.midX, y: card.minY + 40)
        guard let inner = scrollViews(at: point, in: root).first as? HelmNestedScrollView else {
            return fail("Clipped: the point over the rows should be in the table's scroll view", &ok)
        }
        // Measured from the geometry, not from `forwardsWheelToPage`, which is
        // the thing under test.
        let documentHeight = inner.documentView?.frame.height ?? 0
        check(documentHeight > inner.contentView.bounds.height + 100,
              "Clipped: fixture - 30 rows in a 360pt card should overflow, document "
              + "\(documentHeight) in \(inner.contentView.bounds.height)", &ok)
        let receivers = dispatchWheel(at: point, in: root, &ok)
        check(receivers == [ObjectIdentifier(inner)],
              "Clipped: a table with rows below the fold should keep its wheel - \(receivers.count) receiver(s)", &ok)
    }
}

extension NSScrollView {
    /// The recorder `HelmDataTableWheelSelfTest` swaps in. After the exchange,
    /// calling this selector runs the original `scrollWheel(with:)`.
    @objc fileprivate func fm_recordScrollWheel(with event: NSEvent) {
        HelmDataTableWheelSelfTest.record(self)
        fm_recordScrollWheel(with: event)
    }
}

#endif
