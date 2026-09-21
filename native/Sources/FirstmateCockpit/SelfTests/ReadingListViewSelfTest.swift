// Manjesh Grand Line - native macOS app.
//
// The reading list's **window-backed** half (`fm/grandline-feature-f4-reading-
// list`, F4 of full review #3 §8): the real `ReadingListController` mounted in
// a real `NSWindow`, its grid laid out at real widths, its cards' painted
// colours read back out of an off-screen render, and its drop target's real
// accept/refuse decision.
//
// **This suite is in `NEEDS_SESSION`**, and that classification is the
// operative one rather than a style note - see `ReadingListSelfTest`'s header.
// Everything that is a *rule* rather than a rendering lives there and guards
// CI's blocking lane; what is here genuinely needs a window server.
//
// ## How the colours are checked
//
// Two ways, deliberately, because they catch different things (AGENTS.md: "a
// behavioural check and a source guard catch different things"):
//
//   - **Against the view's own resolved colours** - what `applyTheme` put on
//     the layer - which is cheap and precise about the *decision*.
//   - **Against a real render**, through `bitmapImageRepForCachingDisplay`,
//     for the one thing a resolved colour cannot prove: that the pixel is
//     actually painted. Both of that call's traps are respected here - the rep
//     is measured in **pixels** (a factor of two on a retina machine, so the
//     index is scaled by `rep.pixelsWide / bounds.width`), and the expected
//     colour is converted into **`rep.colorSpace`** rather than the sample
//     into sRGB, which is the mistake that once reported a correct accent as a
//     colour bug.
//
// ## Hermeticity
//
// The suite changes the theme, so it **saves and restores `fm.themeID`** -
// AGENTS.md's own most-repeated operational lesson, and
// `Phase3PolishSelfTest.checkSuitesRestoreTheTheme` fails the run for a suite
// that calls `setTheme` without first reading `ThemeManager.shared.theme`.
// Every store is rooted in a scratch directory, and the metadata fetcher is a
// canned one - nothing here touches the network or the captain's clone.
//
// `FM_RUN_READING_LIST_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ReadingListViewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        // Saved and restored around the whole run. Persisting a theme
        // selection is correct behaviour for the app, so the fix belongs at
        // the test - see this file's header.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        checkGridRendersTheThreeMockupStates(check)
        checkMetadataStatesReadDifferently(check)
        checkReadToggleAndOrdering(check)
        checkSidebarTracksTheStore(check)
        checkFiltersDriveTheGrid(check)
        checkEmptyStates(check)
        checkDropTargetDecision(check)
        checkReaderOpensAndMarksRead(check)
        checkCardIsLegibleInBothRegisters(check)
        checkSummaryWellIsActuallyPainted(check)
        checkPageDoesNotCapTheWindow(check)

        print(ok ? "ReadingListViewSelfTest: OK" : "ReadingListViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Harness

    /// A fetcher that answers from a script rather than from the network. The
    /// seam's whole purpose: what is interesting is what the card does with
    /// each outcome.
    private final class CannedFetcher: ReadingListMetadataFetching {
        var answers: [String: Result<ReadingListMetadata, ReadingListMetadataError>] = [:]
        /// Left `false` so a suite that wants a link to stay `.pending` simply
        /// never answers - which is the real state a card is in for the first
        /// second of its life.
        var answersAtAll = false
        private(set) var requested: [String] = []

        func fetch(url: String,
                   completion: @escaping (Result<ReadingListMetadata, ReadingListMetadataError>) -> Void) {
            requested.append(url)
            guard answersAtAll, let answer = answers[url] else { return }
            completion(answer)
        }
    }

    /// One mounted page, in a real window, against a scratch store.
    ///
    /// `autoreleasepool` is mandatory around AppKit construction in a headless
    /// suite - nothing turns the run loop, so removed views are never drained
    /// (AGENTS.md's "Writing a self-test").
    private static func mounted(theme: HelmTheme? = nil,
                                seed: (ReadingListStore) -> Void = { _ in },
                                body: (ReadingListController, ReadingListStore, CannedFetcher, NSWindow) -> Void) {
        autoreleasepool {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fm-reading-list-view-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            if let theme { ThemeManager.shared.setTheme(theme) }
            let store = ReadingListStore(root: root)
            seed(store)
            let fetcher = CannedFetcher()
            let controller = ReadingListController(store: store, fetcher: fetcher)
            // `OffScreenProbe.window(...)`, never a hand-rolled `NSWindow` - a
            // hand-rolled one is *not* off-screen whatever origin it is given,
            // and that was caught live on the captain's own display.
            let window = OffScreenProbe.window(width: 1300, height: 860,
                                               styleMask: [.titled, .resizable])
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            controller.debugReload()
            controller.view.layoutSubtreeIfNeeded()
            body(controller, store, fetcher, window)
            window.contentViewController = nil
            window.close()
        }
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    /// The reviewed mockup's own three cards: one summarised, one awaiting a
    /// summary, one read.
    private static func seedThreeStates(_ store: ReadingListStore) {
        guard case .added(let a) = store.add("https://kubernetes.io/docs/graceful-shutdown"),
              case .added(let b) = store.add("https://pganalyze.com/blog/index-only-scans"),
              case .added(let c) = store.add("https://swift.org/blog/strict-concurrency") else { return }
        store.applyMetadata(id: a.id, ReadingListMetadata(
            title: "Graceful node shutdown and pod eviction ordering"))
        store.setAISummary(id: a.id, summary:
            "The kubelet drains in two phases and only honours terminationGracePeriod up to "
            + "shutdownGracePeriod.")
        store.setTags(id: a.id, tags: ["k8s", "drain"])

        store.applyMetadata(id: b.id, ReadingListMetadata(
            title: "Index-only scans and why your visibility map is cold"))
        store.setTags(id: b.id, tags: ["postgres"])

        store.applyMetadata(id: c.id, ReadingListMetadata(
            title: "Swift 6 strict concurrency: a migration field guide"))
        store.setTags(id: c.id, tags: ["swift", "concurrency"])
        store.setRead(id: c.id, read: true, now: date("2026-09-14T09:00:00Z"))
    }

    // MARK: Cases

    private static func checkGridRendersTheThreeMockupStates(_ check: (Bool, String) -> Void) {
        mounted(seed: seedThreeStates) { controller, _, _, _ in
            let cards = controller.debugCards
            check(cards.count == 3, "grid: three seeded links should render three cards, got \(cards.count)")
            guard cards.count == 3 else { return }

            // The mockup's own ordering: unread first, newest saved first, and
            // the read one last.
            check(cards.last?.debugStatePillText == "read",
                  "grid: the read card sorts last, which is what the mockup draws")

            guard let summarised = cards.first(where: { $0.debugSummaryKicker == "SUMMARY" }) else {
                check(false, "grid: no card carries an AI summary - the mockup's first state is missing")
                return
            }
            check(summarised.debugAccentStripHeight == ReadingListCardView.accentStripHeight,
                  "grid: a summarised card draws its accent strip, which is what makes the state "
                  + "readable from across the grid")
            check(!summarised.debugShowsSummariseButton,
                  "grid: a card that already has a summary must not still offer to make one")
            check(summarised.debugDateLine.hasPrefix("saved "),
                  "grid: an unread card's date slot says when it was saved")

            guard let awaiting = cards.first(where: {
                $0.debugStatePillText == "unread" && $0.debugSummaryKicker.isEmpty
            }) else {
                check(false, "grid: no card is awaiting a summary - the mockup's second state is missing")
                return
            }
            check(awaiting.debugShowsSummariseButton,
                  "grid: a resolved card with no summary offers the Summarise button")
            check(awaiting.debugSecondLine == "No summary yet.",
                  "grid: an un-summarised card says so rather than leaving a blank band")

            guard let read = cards.first(where: { $0.debugStatePillText == "read" }) else { return }
            check(!read.debugShowsSummariseButton && read.debugAccentStripHeight == 0,
                  "grid: the read card carries neither, which is the mockup's third state")
            check(read.debugSecondLine.isEmpty,
                  "grid: a read card must not say \"No summary yet.\" - the card has been dealt "
                  + "with, and that line reads as an outstanding job that is not outstanding")
            check(read.debugDateLine.hasPrefix("read "),
                  "grid: a read card's date slot says when it was read")

            // GL-16: the whole card is spoken, not just "button".
            check(summarised.debugAccessibilityLine.contains("unread")
                  && summarised.debugAccessibilityLine.contains("kubernetes.io")
                  && summarised.debugAccessibilityLine.contains("summarised"),
                  "accessibility: the card's spoken line must carry what it shows visually")
        }
    }

    private static func checkMetadataStatesReadDifferently(_ check: (Bool, String) -> Void) {
        mounted(seed: { store in
            _ = store.add("https://example.com/a-long-article-slug")
        }) { controller, store, _, _ in
            guard let pending = controller.debugCards.first else {
                check(false, "metadata states: no card rendered")
                return
            }
            check(pending.debugTitle == "example.com/a-long-article-slug",
                  "GL-14: a pending link shows its path, never an empty title line")
            check(pending.debugSecondLine.contains("Reading the page"),
                  "GL-14: a pending link says the title is still being read")

            guard let id = store.links.first?.id else { return }
            store.applyMetadataFailure(id: id, reason: "That site did not answer in time.")
            controller.debugReload()
            guard let failed = controller.debugCards.first else { return }
            check(failed.debugSecondLine.contains("did not answer")
                  && failed.debugSecondLine.contains("try again"),
                  "GL-14: a failed fetch reads as a failure with a way out, not as a pending one")
            check(failed.debugTitle == "example.com/a-long-article-slug",
                  "GL-14: a failed fetch keeps showing the path rather than inventing a title")

            store.applyMetadata(id: id, ReadingListMetadata(title: "A real title"))
            controller.debugReload()
            check(controller.debugCards.first?.debugTitle == "A real title",
                  "a resolved fetch shows the fetched title")
            check(controller.debugCards.first?.debugSecondLine == "No summary yet.",
                  "a resolved fetch clears the pending line")
        }
    }

    private static func checkReadToggleAndOrdering(_ check: (Bool, String) -> Void) {
        mounted(seed: seedThreeStates) { controller, store, _, _ in
            guard let card = controller.debugCards.first else {
                check(false, "read toggle: no card rendered")
                return
            }
            let id = card.link.id
            check(card.debugStatePillText == "unread", "read toggle: the fixture starts unread")
            card.debugPressStatePill()
            check(store.link(id: id)?.isRead == true,
                  "read toggle: pressing the pill marks the link read in the store")
            check(controller.debugCards.first(where: { $0.link.id == id })?.debugStatePillText == "read",
                  "read toggle: the card re-renders rather than keeping a stale pill")
            controller.debugCards.first(where: { $0.link.id == id })?.debugPressStatePill()
            check(store.link(id: id)?.isRead == false, "read toggle: pressing again marks it unread")
        }
    }

    private static func checkSidebarTracksTheStore(_ check: (Bool, String) -> Void) {
        mounted(seed: seedThreeStates) { controller, _, _, _ in
            let sidebar = controller.debugSidebar
            check(sidebar.debugRowIndex(id: ReadingListFilter.unread.id) != nil,
                  "sidebar: the Unread slice has a row")
            check(sidebar.debugRowIndex(id: ReadingListFilter.tag("k8s").id) != nil,
                  "sidebar: a tag in the store gets its own row")
            check(sidebar.debugRowIndex(id: ReadingListFilter.tag("nothing").id) == nil,
                  "sidebar: a tag nothing carries must not get a row - otherwise the check above "
                  + "proves nothing")
            check(sidebar.debugDotColor(id: ReadingListFilter.tag("k8s").id) != nil,
                  "sidebar: a tag row draws its identity dot")

            // Clicking a tag row filters the grid, which is the only thing the
            // row is for.
            sidebar.debugClickRow(id: ReadingListFilter.tag("swift").id)
            check(controller.debugFilter == .tag("swift"),
                  "sidebar: clicking a tag row selects that tag as the filter")
            check(controller.debugCards.count == 1,
                  "sidebar: the grid actually narrows to the tag, rather than only the row lighting up")
        }
    }

    private static func checkFiltersDriveTheGrid(_ check: (Bool, String) -> Void) {
        mounted(seed: seedThreeStates) { controller, _, _, _ in
            check(controller.debugCards.count == 3, "filters: All shows everything")
            controller.debugSelectTab(ReadingListFilter.unread.id)
            check(controller.debugCards.count == 2, "filters: Unread drops the read card")
            check(controller.debugCards.allSatisfy { $0.debugStatePillText == "unread" },
                  "filters: nothing read survives the Unread tab")
            controller.debugSelectTab(ReadingListFilter.summarised.id)
            check(controller.debugCards.count == 1,
                  "filters: Summarised shows only the card with an AI paragraph")
            check(controller.debugSidebar.selection == ReadingListFilter.summarised.id,
                  "filters: picking a tab moves the sidebar's selection too, so the two never "
                  + "describe different things at once")
            controller.debugSelectTab(ReadingListFilter.all.id)
            check(controller.debugCards.count == 3, "filters: All restores everything")
        }
    }

    private static func checkEmptyStates(_ check: (Bool, String) -> Void) {
        mounted { controller, _, _, _ in
            check(controller.debugEmptyStateTitle == "Nothing saved yet",
                  "empty state: an untouched list says so in its own words")
        }
        mounted(seed: seedThreeStates) { controller, _, _, _ in
            controller.debugSelectFilter(.tag("nothing-carries-this"))
            check(controller.debugEmptyStateTitle?.contains("Nothing under") == true,
                  "empty state (GL-14): a filter with no matches is a different state from an "
                  + "empty list, and must read differently")
        }
    }

    private static func checkDropTargetDecision(_ check: (Bool, String) -> Void) {
        // The real accept/refuse decision, driven without a live drag session -
        // which needs a window server and a mouse this app's agents cannot
        // drive (AGENTS.md's "Verifying native UI bugs" convention).
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fm-reading-list-drop-test"))

        pasteboard.clearContents()
        pasteboard.setString("https://kubernetes.io/docs/", forType: .string)
        check(ReadingListDropRootView.acceptableURL(fromPasteboard: pasteboard)
              == "https://kubernetes.io/docs/",
              "drop: a dragged URL string is accepted and normalised")

        pasteboard.clearContents()
        pasteboard.setString("just some prose", forType: .string)
        check(ReadingListDropRootView.acceptableURL(fromPasteboard: pasteboard) == nil,
              "drop: prose is refused, so the page does not light up for a drag it cannot use")

        // The concealed-pasteboard rule, asked before the string is read.
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/secret", forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        check(ReadingListDropRootView.acceptableURL(fromPasteboard: pasteboard) == nil,
              "drop: a concealed pasteboard is refused outright - `CredentialVaultClipboard."
              + "isConcealed` is this app's one definition of that, and every reader must ask it")

        mounted { controller, store, _, _ in
            check(controller.debugCapture("https://swift.org/blog"),
                  "drop: a captured URL reaches the store")
            check(store.links.count == 1, "drop: exactly one card")
            check(!controller.debugCapture("https://swift.org/blog"),
                  "drop: the same URL twice is a duplicate, not a second card")
            check(store.links.count == 1, "drop: a duplicate adds nothing")
            check(!controller.debugCapture("not a link"),
                  "drop: prose is refused at the page as well as at the drop target")
        }
    }

    private static func checkReaderOpensAndMarksRead(_ check: (Bool, String) -> Void) {
        mounted(seed: seedThreeStates) { controller, store, _, _ in
            guard let unread = store.links.first(where: { !$0.isRead }) else {
                check(false, "reader: the fixture has no unread link")
                return
            }
            check(!controller.debugReaderIsShowing, "reader: the grid is what a page opens onto")
            controller.debugOpenReader(id: unread.id)
            check(controller.debugReaderIsShowing, "reader: opening a link shows the reader")
            check(store.link(id: unread.id)?.isRead == true,
                  "reader: opening a link marks it read - \"read\" here means \"no longer waiting\"")
            controller.debugCloseReader()
            check(!controller.debugReaderIsShowing, "reader: closing returns to the grid")
            check(!controller.debugCards.isEmpty, "reader: the grid is rebuilt on the way back")
        }
    }

    private static func checkCardIsLegibleInBothRegisters(_ check: (Bool, String) -> Void) {
        // Dusk is the app's default, Daylight its light counterpart. Both, and
        // one twelve-palette theme, because a Daylight-family restyle branches
        // on `theme.isDaylight` and leaves the other twelve byte-identical -
        // so a regression can land on either side of that branch.
        let ids = ["dusk", "daylight", "helm-dark"]
        for id in ids {
            guard let theme = HelmTheme.allThemes.first(where: { $0.id == id }) else {
                check(false, "contrast: theme \(id) not found")
                continue
            }
            mounted(theme: theme, seed: seedThreeStates) { controller, _, _, _ in
                for card in controller.debugCards {
                    let (fill, ink) = card.debugStatePillColors
                    guard let fill, let ink else {
                        check(false, "contrast (\(id)): the state pill has no resolved colours")
                        continue
                    }
                    let ratio = HelmContrast.ratio(HelmContrast.components(ink),
                                                   HelmContrast.components(fill))
                    check(ratio >= HelmContrast.textTarget - 0.01,
                          "contrast (\(id)): the \(card.debugStatePillText) pill's label measures "
                          + "\(String(format: "%.2f", ratio)):1 against its own fill, below the "
                          + "\(HelmContrast.textTarget):1 text target")

                    // The summary well's own kicker, which is the one label
                    // painted on a *tinted* surface rather than on the card -
                    // AGENTS.md's rule that a hue safe as a fill is not
                    // automatically safe as text.
                    if let wellFill = card.debugSummaryWellFill, let kickerInk = card.debugSummaryKickerColor {
                        let wellRatio = HelmContrast.ratio(HelmContrast.components(kickerInk),
                                                           HelmContrast.components(wellFill))
                        check(wellRatio >= HelmContrast.textTarget - 0.01,
                              "contrast (\(id)): the summary well's kicker measures "
                              + "\(String(format: "%.2f", wellRatio)):1 against the well's own fill")
                    }

                    guard let titleColor = card.debugTitleColor,
                          let cardFill = card.layer?.backgroundColor.map({ NSColor(cgColor: $0) }) ?? nil
                    else { continue }
                    let titleRatio = HelmContrast.ratio(HelmContrast.components(titleColor),
                                                        HelmContrast.components(cardFill))
                    check(titleRatio >= HelmContrast.textTarget - 0.01,
                          "contrast (\(id)): the card title measures "
                          + "\(String(format: "%.2f", titleRatio)):1 against the card's own fill")
                }
                // Discriminating power: `HelmContrast.ratio` must not be
                // returning something that clears the target for any pair, or
                // every assertion above is vacuous.
                let black = HelmContrast.components(NSColor.black)
                check(HelmContrast.ratio(black, black) < 1.01,
                      "contrast (\(id)): the ratio function itself is not discriminating")
            }
        }
    }

    private static func checkSummaryWellIsActuallyPainted(_ check: (Bool, String) -> Void) {
        // "Assert what is painted, not what was computed." A resolved layer
        // colour proves the decision; only a render proves the pixel.
        guard let theme = HelmTheme.allThemes.first(where: { $0.id == "dusk" }) else {
            check(false, "render: the dusk theme was not found")
            return
        }
        mounted(theme: theme, seed: seedThreeStates) { controller, _, _, _ in
            guard let card = controller.debugCards.first(where: { $0.debugSummaryKicker == "SUMMARY" }),
                  let expected = card.debugSummaryWellFill else {
                check(false, "render: no summarised card to sample")
                return
            }
            controller.view.layoutSubtreeIfNeeded()
            guard card.bounds.width > 1, card.bounds.height > 1 else {
                check(false, "render: the card never laid out - the sample below would be vacuous")
                return
            }
            guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else {
                check(false, "render: could not build a bitmap rep")
                return
            }
            card.cacheDisplay(in: card.bounds, to: rep)

            // **The rep is measured in pixels, not points** - a factor of two
            // on a retina machine, and sampling point coordinates lands in the
            // top-left quadrant of what was rendered.
            let scaleX = CGFloat(rep.pixelsWide) / card.bounds.width
            let scaleY = CGFloat(rep.pixelsHigh) / card.bounds.height
            // A point inside the summary well but **clear of its own labels**,
            // which are inset by `HelmMetrics.s2` on both sides: sampling the
            // middle lands on antialiased glyphs, not on the fill, and reads as
            // a colour bug (measured: 0.139 away from the resolved fill).
            let wellFrame = card.debugSummaryWellFrame
            guard wellFrame.width > 4, wellFrame.height > 4 else {
                check(false, "render: the summary well has no area - the sample would be vacuous")
                return
            }
            let point = CGPoint(x: wellFrame.minX + 3, y: wellFrame.midY)
            let px = Int(point.x * scaleX)
            // `ReadingListCardView` is an ordinary unflipped `NSView`, so the
            // rep's row 0 is the view's top edge while the frame's y grows
            // upward - the row is mirrored rather than used directly.
            let py = Int((card.bounds.height - point.y) * scaleY)
            guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                  let sampled = rep.colorAt(x: px, y: py) else {
                check(false, "render: the sample point fell outside the rep")
                return
            }
            // **Compared in `rep.colorSpace`, never via a conversion of the
            // sample into sRGB** - `bitmapImageRepForCachingDisplay` returns a
            // rep in the display's own profile inside a real window, and the
            // sRGB conversion is only correct outside one.
            guard let converted = expected.usingColorSpace(rep.colorSpace) else {
                check(false, "render: could not express the expected colour in the rep's space")
                return
            }
            let delta = abs(sampled.redComponent - converted.redComponent)
                + abs(sampled.greenComponent - converted.greenComponent)
                + abs(sampled.blueComponent - converted.blueComponent)
            check(delta < 0.06,
                  "render: the summary well's painted pixel is \(String(format: "%.4f", delta)) away "
                  + "from the colour `applyTheme` resolved for it")

            // Discriminating power: a sample taken outside the well must NOT
            // match, or the assertion above would pass against a card that
            // painted one flat colour everywhere.
            let outsideY = Int((card.bounds.height - 4) * scaleY)
            if let outside = rep.colorAt(x: px, y: max(0, min(rep.pixelsHigh - 1, outsideY))) {
                let outsideDelta = abs(outside.redComponent - converted.redComponent)
                    + abs(outside.greenComponent - converted.greenComponent)
                    + abs(outside.blueComponent - converted.blueComponent)
                check(outsideDelta > 0.01,
                      "render: a pixel outside the summary well is the same colour as one inside it, "
                      + "so the check above proves nothing")
            }
        }
    }

    private static func checkPageDoesNotCapTheWindow(_ check: (Bool, String) -> Void) {
        // Gotcha (13): a content constraint above `NSLayoutPriorityWindowSize
        // StayPut` (500) resizes the whole window, and this page carries a
        // fixed-width sidebar. Measured rather than reasoned - that defect
        // shipped once as "the window doesn't cover the laptop screen".
        mounted(seed: seedThreeStates) { controller, _, _, window in
            let target = NSRect(x: 0, y: 0, width: 760, height: 620)
            window.setFrame(target, display: true)
            controller.view.layoutSubtreeIfNeeded()
            check(abs(window.frame.width - target.width) < 1,
                  "gotcha (13): the window was pushed to \(window.frame.width)pt against a requested "
                  + "760pt - some constraint on this page is acting as a window-width floor")

            let wide = NSRect(x: 0, y: 0, width: 1500, height: 900)
            window.setFrame(wide, display: true)
            controller.view.layoutSubtreeIfNeeded()
            check(abs(window.frame.width - wide.width) < 1,
                  "gotcha (13): the window was capped at \(window.frame.width)pt against a requested "
                  + "1500pt")
            // And the grid actually responded, or the check above would pass
            // for a page that simply ignores its own width.
            let wideColumns = HelmResponsiveGrid.columns(
                containerWidth: controller.debugGridDocument.bounds.width,
                minItemWidth: ReadingListCardView.minimumWidth)
            check(wideColumns >= 2,
                  "grid: a 1500pt window should fit at least two columns, got \(wideColumns)")
        }
    }
}

#endif
