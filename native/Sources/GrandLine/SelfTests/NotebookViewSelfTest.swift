// Grand Line - native macOS app.
//
// The Notebook's **window-backed** half (`fm/grandline-feature-f1-notebook`,
// F1 of full review #3 §8): everything that is only answerable by mounting the
// real destination in a real `NSWindow` and laying it out.
//
// Its pure-logic sibling is `NotebookSelfTest` (`FM_RUN_NOTEBOOK_TESTS`) and
// runs in CI's **blocking** lane. This one is in `NEEDS_SESSION`, because
// every case below needs a window server: real rendered geometry across the
// three view modes, real painted text read back out of the preview's own
// attributed string, a real `WKWebView` loading the real vendored Monaco
// bundle, and Monaco's own tokenizer output read back over the bridge.
//
// **Two things this suite deliberately asserts rather than re-derives**
// (AGENTS.md's "assert what is painted, not what was computed"):
//
//   - the preview's colours and fonts come out of the attributed string the
//     view actually installed, not out of `NotebookMarkdown`;
//   - the editor's wiki-link highlighting comes out of **Monaco's own
//     tokenizer** through the bridge's `tokensAt`, not out of the palette
//     this app handed over. `CodePreviewTheme.Key.operatorToken`'s own
//     history is a theme push that threw page-side and was silently dropped
//     on every theme change for the life of that feature, which a
//     "did we send a palette" check would have passed throughout.
//
// `FM_RUN_NOTEBOOK_VIEW_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum NotebookViewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        // The theme is process-global and persisted, and the suite runner is
        // not hermetic: a suite that changes it without restoring poisons
        // every later run on this tree (AGENTS.md's "The self-test suite is
        // not hermetic"). Captured before anything, restored after everything.
        let startingTheme = ThemeManager.shared.theme

        checkPageTreeAndSelection(check)
        checkPreviewRendersWhatWasParsed(check)
        checkWikiLinkIsPaintedAsALink(check)
        checkBacklinkPanel(check)
        checkDailyNoteButton(check)
        checkAutoTitleOnFirstHeading(check)
        checkViewModeGeometry(check)
        checkThemesBothRegisters(check, startingTheme: startingTheme)
        checkEditorHighlightsWikiLinks(check)

        ThemeManager.shared.setTheme(startingTheme)

        print(ok ? "NotebookViewSelfTest: OK" : "NotebookViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Fixtures

    private static let cutover = """
    # RaaS cutover

    Window: **Sat 27 Sep**, owner manjesh. Runbook: [[Node drain]].

    ## Pre-flight
    - [x] Freeze deploys
    - [ ] Confirm [[Wildcard TLS]] expiry

    #migration #raas
    """

    private static let drain = """
    # Node drain

    Called from [[RaaS cutover]] step 4.
    """

    /// Mounts the real destination in a real off-screen window over a
    /// disposable store.
    ///
    /// `OffScreenProbe.window(...)`, never a hand-rolled `NSWindow` - a
    /// hand-rolled one is *not* off-screen whatever origin it is given, and
    /// these were caught live on the captain's own display.
    private static func withMountedPage(
        width: CGFloat = 1280,
        height: CGFloat = 840,
        seed: [(String, String)] = [("raas-cutover", cutover), ("node-drain", drain)],
        _ body: (NotebookController, NotebookStore, NSWindow) -> Void
    ) {
        autoreleasepool {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("grandline-notebook-view-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = NotebookStore(root: root)
            for (id, content) in seed {
                store.updatePage(id: id, content: content)
            }

            let controller = NotebookController(store: store)
            // `OffScreenProbe.window(...)` clears `isReleasedWhenClosed`
            // itself - see that factory's own note for the crash that put it
            // there.
            let window = OffScreenProbe.window(width: width, height: height)
            window.contentViewController = controller
            window.layoutIfNeeded()
            controller.viewWillAppear()
            controller.view.layoutSubtreeIfNeeded()
            body(controller, store, window)
            window.contentViewController = nil
            window.close()
        }
    }

    // MARK: Cases

    private static func checkPageTreeAndSelection(_ check: (Bool, String) -> Void) {
        withMountedPage(seed: [("raas-cutover", cutover),
                               ("migrations/node-drain", drain),
                               ("daily/2026-09-18", "# 18 Sep\n\nblocked on [[RaaS cutover]] window\n")]) { page, _, _ in
            check(page.debugPages.count == 3, "the tree found all three pages, got \(page.debugPages.count)")
            let ids = page.debugPages.map(\.id).sorted()
            check(ids == ["daily/2026-09-18", "migrations/node-drain", "raas-cutover"],
                  "every folder in the tree is walked, got \(ids)")

            // Selection is what the sidebar shows as current, and it has to
            // follow a programmatic open - a page tree whose highlight lags
            // the editor is exactly the kind of thing that reads as a bug.
            page.debugOpen(pageID: "migrations/node-drain")
            check(page.debugCurrentPageID == "migrations/node-drain", "opening a page makes it current")
            check(page.debugSidebar.selection == "migrations/node-drain",
                  "and the tree's own selection follows, got \(String(describing: page.debugSidebar.selection))")
        }
    }

    private static func checkPreviewRendersWhatWasParsed(_ check: (Bool, String) -> Void) {
        withMountedPage { page, _, _ in
            page.debugOpen(pageID: "raas-cutover")
            page.view.layoutSubtreeIfNeeded()

            let blocks = page.debugPreview.debugBlockViews
            check(!blocks.isEmpty, "the preview drew something")
            check(!page.debugPreview.debugShowsEmptyState,
                  "a page with content must not show the empty state")

            // Two real checkboxes, one ticked - the mockup's own shape, and
            // the one thing `AttributedString(markdown:)` could not have
            // given this feature.
            let checkboxes = blocks.flatMap { descendants(of: $0).compactMap { $0 as? NotebookCheckboxView } }
            check(checkboxes.count == 2, "two task items drew two checkboxes, got \(checkboxes.count)")
            let ticked = checkboxes.filter { $0.accessibilityValue() as? Int == 1 }
            check(ticked.count == 1, "exactly one is ticked, got \(ticked.count)")
            check(checkboxes.contains { $0.accessibilityLabel() == "Done" },
                  "GL-16: the state is readable, not only visible")

            // The rendered text is the *rendered* text - the `[[…]]` syntax
            // and the `**` markers are gone.
            let prose = page.debugPreview.debugProseViews.map(\.debugPlainText).joined(separator: "\n")
            check(prose.contains("Node drain"), "the wiki-link's label is shown, got:\n\(prose)")
            check(!prose.contains("[["), "the wiki-link syntax is not shown")
            check(!prose.contains("**"), "the bold markers are not shown")
            check(prose.contains("Sat 27 Sep"), "and the bold text itself survives")

            // A rendered heading really is bigger than body copy. Read off
            // the installed attributed strings, so a heading that stopped
            // being styled fails here even though the parser still calls it a
            // heading.
            let fonts = page.debugPreview.debugProseViews.compactMap { view -> CGFloat? in
                guard view.debugAttributedText.length > 0 else { return nil }
                let font = view.debugAttributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                return font?.pointSize
            }
            check((fonts.max() ?? 0) > (fonts.min() ?? 0) + 3,
                  "the h1 must render visibly larger than body copy, sizes: \(fonts)")
        }
    }

    private static func checkWikiLinkIsPaintedAsALink(_ check: (Bool, String) -> Void) {
        withMountedPage { page, _, _ in
            page.debugOpen(pageID: "raas-cutover")
            page.view.layoutSubtreeIfNeeded()

            // The mechanism that made this check necessary in the first
            // place: `NSTextView` paints its own styling over a `.link` range
            // and its default is the system blue, which overrode both colours
            // below with one. So the *override* is asserted directly - the
            // attributed string being right is not enough if the view repaints
            // it.
            for view in page.debugPreview.debugProseViews {
                check(view.linkTextAttributes?[.foregroundColor] == nil,
                      "the text view must not repaint links in its own colour")
                check(view.linkTextAttributes?[.underlineStyle] == nil,
                      "nor add its own underline over the run's")
            }

            var resolvedLink: (NSColor, URL)?
            var missingLink: (NSColor, URL)?
            for view in page.debugPreview.debugProseViews {
                let text = view.debugAttributedText
                text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                    guard let url = value as? URL,
                          let token = NotebookProseView.decodeWikiURL(url),
                          let color = text.attribute(.foregroundColor, at: range.location,
                                                     effectiveRange: nil) as? NSColor else { return }
                    if token.isExisting { resolvedLink = (color, url) } else { missingLink = (color, url) }
                }
            }

            guard let resolvedLink, let missingLink else {
                check(false, "the preview must carry both a resolved and an unresolved wiki-link "
                      + "(resolved: \(resolvedLink != nil), missing: \(missingLink != nil))")
                return
            }

            check(NotebookProseView.decodeWikiURL(resolvedLink.1)?.payload == "node-drain",
                  "a resolved link carries the page id it will open")
            check(NotebookProseView.decodeWikiURL(missingLink.1)?.payload == "Wildcard TLS",
                  "an unresolved link carries the raw target, so it can be created")

            // The two must be visibly different, or "this page does not exist
            // yet" is not being communicated at all. Component-wise, because
            // `HelmContrast.ratio` compares luminance and two different hues
            // of similar brightness pass it.
            let a = HelmContrast.components(resolvedLink.0)
            let b = HelmContrast.components(missingLink.0)
            let same = abs(a.0 - b.0) < 0.02 && abs(a.1 - b.1) < 0.02 && abs(a.2 - b.2) < 0.02
            check(!same, "a link to a page that does not exist must not look identical to one that does")

            // And both must clear the text floor on the card they are drawn
            // on - a tinted hue is safe as a fill and is not automatically
            // safe as text.
            let surface = HelmTheme.nsColor(ThemeManager.shared.theme.chromeBackgroundHex)
            for (name, color) in [("resolved", resolvedLink.0), ("missing", missingLink.0)] {
                let ratio = HelmContrast.ratio(color, surface)
                check(ratio >= 4.5,
                      "the \(name) link colour measures \(String(format: "%.2f", ratio)) on the card, below 4.5")
            }
        }
    }

    private static func checkBacklinkPanel(_ check: (Bool, String) -> Void) {
        withMountedPage { page, store, _ in
            page.debugOpen(pageID: "raas-cutover")
            check(page.debugBacklinksTitle.contains("1"),
                  "one page links here, and the panel says so: \(page.debugBacklinksTitle)")
            check(page.debugBacklinkRowCount == 1, "one backlink row, got \(page.debugBacklinkRowCount)")

            // The other direction, so the check is not passing because
            // everything reports one.
            page.debugOpen(pageID: "node-drain")
            check(page.debugBacklinkRowCount == 1, "Node drain is linked to as well")

            // A page nothing links to says so rather than showing an empty
            // panel with a count of zero.
            _ = store.createPage(title: "Orphan")
            page.debugReload()
            page.debugOpen(pageID: "orphan")
            check(page.debugBacklinksTitle == "Backlinks",
                  "an orphan's panel carries no count, got \(page.debugBacklinksTitle)")
            check(page.debugBacklinkRowCount == 1,
                  "and shows one explanatory line rather than nothing at all")

            // The index is live: a link typed now resolves now, without a
            // page switch.
            page.debugEdit(id: "orphan", content: "# Orphan\n\nsee [[Node drain]]\n")
            page.debugOpen(pageID: "node-drain")
            check(page.debugBacklinkRowCount == 2,
                  "a link typed a moment ago shows up in the target's backlinks, got \(page.debugBacklinkRowCount)")
        }
    }

    private static func checkDailyNoteButton(_ check: (Bool, String) -> Void) {
        withMountedPage(seed: []) { page, store, _ in
            check(store.listPages().isEmpty, "fixture check: the notebook really starts empty")
            page.debugToday()
            let expected = NotebookStore.dailyNoteID(for: Date())
            check(page.debugCurrentPageID == expected,
                  "one click opens today's note, got \(String(describing: page.debugCurrentPageID))")
            check(store.exists(id: expected), "and the file exists on disk")

            // Clicking again opens the same page rather than making a second.
            page.debugEdit(id: expected, content: "# Today\n\nsomething\n")
            page.debugToday()
            check(store.listPages().count == 1, "a second click creates nothing, got \(store.listPages().count)")
            check(store.page(id: expected)?.content.contains("something") == true,
                  "and does not blank what is already there")
        }
    }

    private static func checkAutoTitleOnFirstHeading(_ check: (Bool, String) -> Void) {
        withMountedPage(seed: [("other", "# Other\n\nsee [[untitled]]\n")]) { page, store, _ in
            page.debugNewPage()
            let placeholder = page.debugCurrentPageID
            check(placeholder == "untitled", "a new page starts as a placeholder, got \(String(describing: placeholder))")

            page.debugEdit(id: "untitled", content: "# Wildcard TLS\n\nexpiry\n")
            check(page.debugCurrentPageID == "wildcard-tls",
                  "the first heading renames the file, got \(String(describing: page.debugCurrentPageID))")
            check(!store.exists(id: "untitled"), "and the placeholder file is gone")

            // The link that pointed at the placeholder follows the rename,
            // rather than silently dangling.
            check(store.page(id: "other")?.content.contains("[[Wildcard TLS]]") == true,
                  "a link to the old name is retargeted, got "
                  + String(describing: store.page(id: "other")?.content))

            // A name the captain chose is never overwritten.
            page.debugEdit(id: "wildcard-tls", content: "# Something else entirely\n")
            check(store.exists(id: "wildcard-tls"),
                  "a page that already has a real name keeps it when the heading changes")

            // **Review bug B7**, which every assertion above passed straight
            // over. The rename set `currentID`, renamed the file and moved the
            // sidebar selection - and `HelmPageSidebar.select` does not fire
            // `onSelect`, so `open(pageID:)` never ran and **Monaco kept the
            // old id**. The editor went on posting `change` under `untitled`,
            // and the next debounce hit `pageEdited`'s own
            // `guard store.exists(id:)` and dropped the keystrokes silently.
            //
            // `open(pageID:)` is the only path that re-points the editor, and
            // the only thing it writes that a headless suite can see is the
            // editor's own caption - the web view is never ready here, so no
            // `openSnippet` is sent at all and `currentID`/the sidebar
            // selection were both already correct with the bug present. The
            // caption is therefore the witness: it still read "untitled.md"
            // after a rename to `wildcard-tls`.
            check(page.debugEditorTitle == "something-else-entirely.md"
                    || page.debugEditorTitle == "wildcard-tls.md",
                  "after the auto-title rename the editor must be re-opened on the new id - its "
                  + "caption still reads \(page.debugEditorTitle), so open(pageID:) never ran and "
                  + "the editor keeps posting changes under the old id (B7)")

            // Discriminating power, in both directions: the caption really is
            // written by an open, and it really did start as the placeholder.
            store.updatePage(id: "second-page", content: "# Second\n")
            page.debugReload()
            page.debugOpen(pageID: "second-page")
            check(page.debugEditorTitle == "second-page.md",
                  "the fixture is vacuous unless an open actually writes the caption, got "
                  + page.debugEditorTitle)
        }
    }

    /// The three view modes are a real geometry question: a hidden card still
    /// participates in Auto Layout (gotcha (11)), so "hidden" is not enough -
    /// the width tie has to move with it, and the visible pane has to
    /// actually take the width back.
    private static func checkViewModeGeometry(_ check: (Bool, String) -> Void) {
        withMountedPage { page, _, window in
            page.debugOpen(pageID: "raas-cutover")

            page.debugSetMode(.split)
            page.view.layoutSubtreeIfNeeded()
            let splitEditor = page.debugEditorCard.frame.width
            let splitPreview = page.debugPreviewCard.frame.width
            check(splitEditor > 100 && splitPreview > 100,
                  "split gives both panes real width, got \(splitEditor)/\(splitPreview)")
            check(abs(splitEditor - splitPreview) < 2,
                  "and shares it evenly, got \(splitEditor) vs \(splitPreview)")

            page.debugSetMode(.preview)
            page.view.layoutSubtreeIfNeeded()
            check(page.debugEditorCardHidden, "preview mode hides the editor")
            check(page.debugEditorCard.frame.width < 1,
                  "and collapses it, got \(page.debugEditorCard.frame.width)")
            check(page.debugPreviewCard.frame.width > splitPreview + 50,
                  "so the preview takes the width back, got \(page.debugPreviewCard.frame.width) "
                  + "vs \(splitPreview) in split")

            page.debugSetMode(.edit)
            page.view.layoutSubtreeIfNeeded()
            check(page.debugPreviewCardHidden, "source mode hides the preview")
            check(page.debugEditorCard.frame.width > splitEditor + 50,
                  "and the editor takes the width back, got \(page.debugEditorCard.frame.width)")

            page.debugToggleRail()
            page.view.layoutSubtreeIfNeeded()
            check(page.debugRailHidden, "the rail toggle hides the rail")
            check(page.debugRail.frame.width < 1, "and collapses its column, got \(page.debugRail.frame.width)")

            // Gotcha (13): nothing on this page may cap the window. Measured
            // rather than reasoned - the fixed page tree and the fixed rail
            // are both exactly the shape that has capped it twice before.
            page.debugToggleRail()
            page.debugSetMode(.split)
            let wide = NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: 1512, height: 900)
            window.setFrame(wide, display: true)
            page.view.layoutSubtreeIfNeeded()
            check(abs(window.frame.width - 1512) < 1,
                  "the window must reach 1512pt, got \(window.frame.width)")
            let narrow = NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: 900, height: 700)
            window.setFrame(narrow, display: true)
            page.view.layoutSubtreeIfNeeded()
            check(abs(window.frame.width - 900) < 1,
                  "and shrink back to 900pt, got \(window.frame.width) - a >500-priority content "
                  + "constraint on this page would be a window-size cap")
        }
    }

    /// Both registers, because the Daylight family and the twelve palettes
    /// take different branches everywhere in this app.
    private static func checkThemesBothRegisters(_ check: (Bool, String) -> Void, startingTheme: HelmTheme) {
        for themeID in ["dusk", "daylight", "helm-dark"] {
            guard let theme = HelmTheme.allThemes.first(where: { $0.id == themeID }) else { continue }
            ThemeManager.shared.setTheme(theme)
            withMountedPage { page, _, _ in
                page.debugOpen(pageID: "raas-cutover")
                page.view.layoutSubtreeIfNeeded()
                // `ThemeManager.swift`'s checklist item 2 - the one most often
                // missed, and the "half-themed" defect that has shipped four
                // separate times.
                let expected: NSAppearance.Name = theme.mode == .dark ? .darkAqua : .aqua
                check(page.view.appearance?.name == expected,
                      "\(themeID): the page must force its own appearance, got "
                      + String(describing: page.view.appearance?.name))

                // Every painted run has to clear the floor on the card it is
                // actually drawn on.
                let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
                var worst = 21.0
                for view in page.debugPreview.debugProseViews {
                    let text = view.debugAttributedText
                    guard text.length > 0 else { continue }
                    text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                        guard let color = value as? NSColor else { return }
                        worst = min(worst, HelmContrast.ratio(color, surface))
                    }
                }
                check(worst >= 4.5,
                      "\(themeID): the least legible painted run measures \(String(format: "%.2f", worst)) "
                      + "on the preview card, below 4.5")
            }
        }
        ThemeManager.shared.setTheme(startingTheme)
    }

    /// The source pane's own highlighting, read back out of **Monaco's own
    /// tokenizer** rather than out of the palette this app sent.
    ///
    /// This is the case that fails by name if a future bundle bump changes
    /// the markdown grammar under `NotebookEditorTheme`'s feet - which is
    /// exactly the risk that comes with colouring an existing tokenizer's
    /// output rather than shipping a dedicated one (see that file's header).
    private static func checkEditorHighlightsWikiLinks(_ check: (Bool, String) -> Void) {
        guard CodePreviewAssets.isAvailable else {
            print("  SKIP - no Monaco bundle on this machine (\(CodePreviewAssets.missingBundleMessage))")
            return
        }
        withMountedPage { page, _, window in
            window.orderFrontRegardless()
            page.debugOpen(pageID: "raas-cutover")

            // The page has to finish loading before the bridge answers, and
            // nothing turns the run loop in a headless suite.
            let deadline = Date().addingTimeInterval(20)
            var tokens: [[String: Any]] = []
            var failure: String?
            var landed = false
            var asked = false

            while !landed, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                guard !asked, page.debugEditorIsReady else { continue }
                asked = true
                // Line 3 of the fixture is the paragraph carrying
                // `[[Node drain]]`.
                page.debugEditorCall("tokensAt", payload: ["line": 3]) { result in
                    switch result {
                    case .success(let reply): tokens = (reply["tokens"] as? [[String: Any]]) ?? []
                    case .failure(let error): failure = error.message
                    }
                    landed = true
                }
            }

            guard landed else {
                check(false, "the editor did not answer within 20s (ready: \(page.debugEditorIsReady))")
                return
            }
            if let failure {
                check(false, "the editor refused to report its tokens: \(failure)")
                return
            }

            let types = tokens.compactMap { $0["type"] as? String }
            check(!types.isEmpty, "Monaco reported no tokens for the line at all")
            // The grammar's own answer. Asserted as a *family* prefix rather
            // than an exact string, since Monaco appends the language id.
            check(types.contains { $0.hasPrefix("string") },
                  "Monaco's markdown grammar must tokenize `[[Node drain]]` as a link/string token - "
                  + "`NotebookEditorTheme` colours that family. Got: \(types)")
            check(types.contains { $0.hasPrefix("") && !$0.hasPrefix("string") },
                  "fixture check: the line must also carry non-link tokens, or the check above is vacuous")
        }
    }

    // MARK: Helpers

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}

#endif
