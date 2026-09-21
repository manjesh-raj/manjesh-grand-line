// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for the Notebook's *logic* half
// (`fm/grandline-feature-f1-notebook`, F1 of full review #3 §8): the markdown
// parser, the `[[wiki-link]]` scanner, the resolver's tie-break order, the
// backlink index, the daily-note naming, the store's disk round trip, its
// refusal of a path that escapes the notebook root, and the destination's own
// wiring into the shell's tables.
//
// **Pure logic, no window** - and that classification is the operative one,
// not a style note: `NEEDS_SESSION` in `Scripts/run-all-tests.sh` decides
// whether a suite guards the *blocking* CI job, so a pure-logic suite parked
// there would still pass, still look healthy, and never once guard a merge
// (AGENTS.md's "Writing a self-test"). Nothing here builds a view.
// `NotebookViewSelfTest` is the window-backed half, and it is the one in
// `NEEDS_SESSION`.
//
// `FM_RUN_NOTEBOOK_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum NotebookSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkWikiLinkScanning(check)
        checkWikiLinksAreNotFoundInCode(check)
        checkResolution(check)
        checkBacklinkIndex(check)
        checkRetarget(check)
        checkMarkdownBlocks(check)
        checkInlineRuns(check)
        checkTagsAndTaskProgress(check)
        checkStoreRoundTrip(check)
        checkStoreRefusesEscapingIdentifiers(check)
        checkStoreHonoursShiftDirOverride(check)
        checkDailyNote(check)
        checkPlaceholderSlugs(check)
        checkEditorPalette(check)
        checkDestinationWiring(check)

        print(ok ? "NotebookSelfTest: OK" : "NotebookSelfTest: FAILURES")
        return ok
    }

    // MARK: Scratch helpers

    /// A disposable store, rooted in a temp directory. Never the production
    /// constructor: `NotebookStore()` with no override resolves to
    /// `NotebookGitSync.shared`, which shares `ShiftGitSync.shared`'s real
    /// clone of the captain's private config repo.
    private static func withScratchStore(_ body: (NotebookStore, URL) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-notebook-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(root: root)
        body(store, root)
    }

    private static func page(_ id: String, _ content: String) -> NotebookPage {
        NotebookPage(id: id,
                     title: NotebookStore.titleFromContent(content, fallback: NotebookStore.humanise(lastComponentOf: id)),
                     content: content,
                     modifiedAt: Date())
    }

    // MARK: Wiki-link scanning

    private static func checkWikiLinkScanning(_ check: (Bool, String) -> Void) {
        let text = "See [[Node drain]] and [[migrations/raas-cutover|the cutover]] before Friday."
        let links = NotebookLinks.parse(text)
        check(links.count == 2, "two links in the line, found \(links.count)")
        guard links.count == 2 else { return }
        check(links[0].target == "Node drain", "plain target, got \(links[0].target)")
        check(links[0].label == "Node drain", "a plain link labels itself")
        check(links[1].target == "migrations/raas-cutover", "piped target, got \(links[1].target)")
        check(links[1].label == "the cutover", "piped label, got \(links[1].label)")
        // The range has to be usable for a replacement, which is what
        // `retarget` relies on - so assert it slices back to the source.
        check(String(text[links[0].range]) == "[[Node drain]]",
              "the range must cover the whole link, got \(String(text[links[0].range]))")

        check(NotebookLinks.parse("[[]]").isEmpty, "an empty target is not a link")
        check(NotebookLinks.parse("[[unterminated").isEmpty, "an unterminated link is not a link")
        check(NotebookLinks.parse("[single]").isEmpty, "one bracket pair is a markdown link, not a wiki-link")
        check(NotebookLinks.parse("\\[[escaped]]").isEmpty, "a backslash escape suppresses the link")
        check(NotebookLinks.parse("[[a]] [[b]]").count == 2, "two links on one line")
        // A `[` inside the brackets aborts, so an unterminated `[[` cannot
        // swallow the next one on the line.
        check(NotebookLinks.parse("[[oops [[real]]").count == 1,
              "an unterminated link must not swallow the next one")
    }

    /// The fixture's discriminating power is asserted first: if the same text
    /// *outside* code did not produce links, the "no links in code" check
    /// would pass vacuously.
    private static func checkWikiLinksAreNotFoundInCode(_ check: (Bool, String) -> Void) {
        let outside = "grep [[abc]] file"
        check(NotebookLinks.parse(outside).count == 1,
              "fixture check: the same text outside code must produce a link")

        let fenced = """
        before [[Real]]
        ```sh
        test [[not a link]] && echo hi
        ```
        after [[Other]]
        """
        let targets = NotebookLinks.parse(fenced).map(\.target)
        check(targets == ["Real", "Other"],
              "a fenced block's brackets are quoted text, got \(targets)")

        let spanned = "use `[[glob]]` literally"
        check(NotebookLinks.parse(spanned).isEmpty,
              "an inline code span's brackets are quoted text")
    }

    // MARK: Resolution

    private static func checkResolution(_ check: (Bool, String) -> Void) {
        let pages = [
            page("migrations/raas-cutover", "# RaaS cutover\n"),
            page("migrations/node-drain", "# Node drain\n"),
            page("scratch", "# Scratch\n"),
            page("interviews/notes", "# Notes\n"),
            page("reading/notes", "# Notes\n"),
        ]
        let resolver = NotebookLinkResolver(pages: pages)

        check(resolver.resolve("migrations/raas-cutover") == "migrations/raas-cutover",
              "an exact id resolves to itself")
        check(resolver.resolve("MIGRATIONS/RAAS-CUTOVER") == "migrations/raas-cutover",
              "an id resolves case-insensitively")
        check(resolver.resolve("RaaS cutover") == "migrations/raas-cutover",
              "a title resolves, got \(String(describing: resolver.resolve("RaaS cutover")))")
        check(resolver.resolve("node-drain") == "migrations/node-drain",
              "a slug resolves across folders")
        check(resolver.resolve("Nothing here") == nil,
              "a page that does not exist resolves to nil rather than to something near it")

        // The documented tie-break: the linking page's own folder wins.
        check(resolver.resolve("Notes", from: "reading/index") == "reading/notes",
              "a tie breaks toward the linking page's own folder, got "
              + String(describing: resolver.resolve("Notes", from: "reading/index")))
        check(resolver.resolve("Notes", from: "interviews/index") == "interviews/notes",
              "and the other way, so the check is not passing by luck")
        // With no folder to prefer it is still deterministic, which is the
        // property that matters more than which one it picks.
        let a = resolver.resolve("Notes", from: "scratch")
        let b = resolver.resolve("Notes", from: "scratch")
        check(a != nil && a == b, "an unbroken tie must still resolve, and resolve the same way twice")
    }

    // MARK: Backlinks

    private static func checkBacklinkIndex(_ check: (Bool, String) -> Void) {
        let pages = [
            page("raas-cutover", "# RaaS cutover\n\nRollback: none.\n"),
            page("daily/2026-09-18", "# 18 Sep\n\n- blocked on [[RaaS cutover]] window\n"),
            page("node-drain", "# Node drain\n\nCalled from [[RaaS cutover]] step 4.\n"),
            page("self-link", "# Self link\n\nSee [[Self link]].\n"),
            page("dangling", "# Dangling\n\nSee [[Wildcard TLS]].\n"),
            page("twice", "# Twice\n\n[[RaaS cutover]] and again [[RaaS cutover]].\n"),
        ]
        let resolver = NotebookLinkResolver(pages: pages)
        let index = NotebookBacklinkIndex(pages: pages, resolver: resolver)

        let incoming = index.backlinks(to: "raas-cutover")
        check(incoming.count == 3,
              "three distinct pages link here, got \(incoming.count): \(incoming.map(\.sourceID))")
        check(index.count(to: "raas-cutover") == 3, "the count agrees with the list")
        check(incoming.filter { $0.sourceID == "twice" }.count == 1,
              "two mentions on one page are one relationship, not two rows")

        check(index.backlinks(to: "self-link").isEmpty,
              "a page linking to itself is not its own backlink")

        let context = incoming.first { $0.sourceID == "daily/2026-09-18" }?.context
        check(context?.contains("blocked on") == true,
              "a backlink quotes the line it sits in, got \(String(describing: context))")
        check(context?.hasPrefix("-") == false,
              "the list marker is stripped from the quote, got \(String(describing: context))")

        let unresolvedTargets = index.unresolved.map(\.target)
        check(unresolvedTargets == ["Wildcard TLS"],
              "a link to a page that does not exist is reported, not dropped: \(unresolvedTargets)")

        // Ordering is part of the contract - a panel that reshuffles on every
        // rebuild reads as broken.
        let again = NotebookBacklinkIndex(pages: pages, resolver: resolver).backlinks(to: "raas-cutover")
        check(again.map(\.sourceID) == incoming.map(\.sourceID),
              "the backlink order must be stable across rebuilds")
    }

    private static func checkRetarget(_ check: (Bool, String) -> Void) {
        let before = "See [[untitled]] and [[untitled|the draft]] plus [[other]]."
        // Fixture check: the thing being replaced really is present.
        check(before.contains("[[untitled]]"), "fixture check: the old target is in the text")
        let after = NotebookLinks.retarget(before, from: "untitled", to: "RaaS cutover")
        check(after == "See [[RaaS cutover]] and [[RaaS cutover|the draft]] plus [[other]].",
              "a rename rewrites every occurrence and keeps each alias, got \(after)")
        check(NotebookLinks.retarget("nothing here", from: "untitled", to: "x") == "nothing here",
              "a page with no links is returned unchanged")
    }

    // MARK: Markdown

    private static func checkMarkdownBlocks(_ check: (Bool, String) -> Void) {
        let source = """
        # RaaS cutover

        Window: **Sat 27 Sep**

        ## Pre-flight
        - [x] Freeze deploys
        - [ ] Confirm [[Wildcard TLS]]
        - plain bullet
        1. first
        2. second

        > a quoted line

        ---

        ```sh
        kubectl get pods
        ```
        """
        let blocks = NotebookMarkdown.parse(source)

        func isHeading(_ block: NotebookBlock, _ level: Int) -> Bool {
            if case .heading(let l, _) = block { return l == level }
            return false
        }
        check(blocks.first.map { isHeading($0, 1) } == true, "the first block is an h1")
        check(blocks.contains { isHeading($0, 2) }, "the `## Pre-flight` heading is an h2")

        let bullets = blocks.compactMap { block -> (Int, Bool?)? in
            if case .bullet(let indent, let checked, _) = block { return (indent, checked) }
            return nil
        }
        check(bullets.count == 3, "three unordered items, got \(bullets.count)")
        check(bullets.first?.1 == true, "`- [x]` is a ticked task item")
        check(bullets.dropFirst().first?.1 == false, "`- [ ]` is an unticked task item")
        check(bullets.last?.1 == nil, "a plain bullet is not a task item")

        let ordered = blocks.compactMap { block -> Int? in
            if case .ordered(_, let n, _) = block { return n }
            return nil
        }
        check(ordered == [1, 2], "the ordered items keep their numbers, got \(ordered)")

        check(blocks.contains { if case .quote = $0 { return true }; return false }, "the quote is a quote")
        check(blocks.contains { if case .rule = $0 { return true }; return false }, "`---` is a rule, not a bullet")

        let code = blocks.compactMap { block -> (String?, String)? in
            if case .code(let lang, let text) = block { return (lang, text) }
            return nil
        }
        check(code.count == 1, "one fenced block, got \(code.count)")
        check(code.first?.0 == "sh", "the fence's language is carried")
        check(code.first?.1 == "kubectl get pods", "the fence's body is verbatim, got \(String(describing: code.first?.1))")

        // The things a naive scanner gets wrong.
        check(NotebookMarkdown.parse("#tag alone").contains { if case .paragraph = $0 { return true }; return false },
              "`#tag` with no space is a tag, never a heading")
        check(NotebookMarkdown.parse("####### seven").contains { if case .paragraph = $0 { return true }; return false },
              "seven hashes is not a heading")
        // A live preview sees an unterminated fence on nearly every keystroke
        // inside one.
        let open = NotebookMarkdown.parse("```\nstill typing")
        check(open.contains { if case .code = $0 { return true }; return false },
              "an unterminated fence still renders as code")
    }

    private static func checkInlineRuns(_ check: (Bool, String) -> Void) {
        let runs = NotebookMarkdown.parseInline("plain **bold** `code` [[Wiki|alias]] [web](https://x.test) _em_")
        check(runs.contains { $0.text == "bold" && $0.bold }, "bold is bold")
        check(runs.contains { $0.text == "code" && $0.kind == .code }, "a backtick span is code")
        check(runs.contains { $0.text == "alias" && $0.kind == .wikiLink(target: "Wiki") },
              "a wiki-link carries its target and shows its alias")
        check(runs.contains { $0.text == "web" && $0.kind == .link(url: "https://x.test") },
              "a markdown link carries its url")
        check(runs.contains { $0.text == "em" && $0.italic }, "underscore emphasis is italic")

        // The identifier case, which is why `_` is boundary-sensitive here.
        let snake = NotebookMarkdown.parseInline("call some_function_name now")
        check(snake.count == 1 && snake[0].text == "call some_function_name now" && !snake[0].italic,
              "snake_case must not become italics, got \(snake.map(\.text))")

        // Nothing is ever dropped: the scanner only moves text.
        let messy = "a * b ** c [ d ] ( e"
        let rebuilt = NotebookMarkdown.parseInline(messy).map(\.text).joined()
        check(rebuilt.replacingOccurrences(of: "*", with: "") == messy.replacingOccurrences(of: "*", with: ""),
              "malformed emphasis must not swallow text, got \(rebuilt)")
    }

    private static func checkTagsAndTaskProgress(_ check: (Bool, String) -> Void) {
        let text = """
        # Cutover #migration

        #!/bin/sh is a shebang, not a tag
        Tagged #raas and #migration again.

        ```
        #infence
        ```
        - [x] one
        - [ ] two
        - [x] three
        """
        let tags = NotebookMarkdown.tags(in: text)
        check(tags == ["migration", "raas"], "tags are de-duplicated and in source order, got \(tags)")
        check(!tags.contains("infence"), "a tag inside a fence is code")
        check(!tags.contains("!"), "a shebang is not a tag")

        let progress = NotebookMarkdown.taskProgress(in: text)
        check(progress == (2, 3), "two of three ticked, got \(progress)")
        check(NotebookMarkdown.taskProgress(in: "no checklist here").total == 0,
              "a page with no checklist reports no total, so the inspector can omit the row")
    }

    // MARK: The store

    private static func checkStoreRoundTrip(_ check: (Bool, String) -> Void) {
        withScratchStore { store, root in
            let created = store.createPage(title: "RaaS cutover", folder: "migrations")
            check(created.id == "migrations/raas-cutover", "the id is folder/slug, got \(created.id)")
            check(FileManager.default.fileExists(atPath: root.appendingPathComponent("migrations/raas-cutover.md").path),
                  "the markdown file is really on disk")

            let clash = store.createPage(title: "RaaS cutover", folder: "migrations")
            check(clash.id == "migrations/raas-cutover-2",
                  "a clashing name is disambiguated rather than overwriting, got \(clash.id)")

            store.updatePage(id: created.id, content: "# RaaS cutover\n\nbody\n")
            check(store.page(id: created.id)?.content.contains("body") == true, "an update round trips")
            check(store.page(id: created.id)?.title == "RaaS cutover", "the title comes from the `# Heading`")

            let top = store.createPage(title: "Scratch")
            check(top.id == "scratch", "a top-level page has no folder in its id")
            check(top.folder.isEmpty, "and reports no folder")

            let pages = store.listPages()
            check(pages.count == 3, "three pages in the tree, got \(pages.count)")
            check(store.folders(in: pages) == ["migrations"],
                  "folders are derived from the pages, got \(store.folders(in: pages))")

            // A title-less file falls back to its own humanised slug rather
            // than showing a raw path.
            store.updatePage(id: top.id, content: "no heading at all\n")
            check(store.page(id: top.id)?.title == "Scratch",
                  "a page with no heading falls back to its humanised slug, got "
                  + String(describing: store.page(id: top.id)?.title))

            let landed = store.renamePage(id: top.id, to: "notes")
            check(landed == "notes", "a rename returns where it landed, got \(String(describing: landed))")
            check(store.page(id: "scratch") == nil, "the old file is gone after a rename")
            check(store.page(id: "notes") != nil, "the new file is there")

            // A rename onto an occupied name disambiguates rather than
            // destroying the captain's writing.
            store.updatePage(id: "notes", content: "# Notes\n\nmine\n")
            let second = store.renamePage(id: "migrations/raas-cutover", to: "notes")
            check(second != nil && second != "notes",
                  "a rename onto an occupied id disambiguates, got \(String(describing: second))")
            check(store.page(id: "notes")?.content.contains("mine") == true,
                  "and the page already there keeps its own content - the worst failure this class could have")

            store.deletePage(id: "notes")
            check(store.page(id: "notes") == nil, "a delete removes the file")
        }
    }

    /// GL-08's posture applied to a page id: the file the captain did not
    /// type is the delivery vector, and a `[[../../.ssh/config]]` in a page
    /// arriving over git sync must not resolve to a path outside the
    /// notebook.
    private static func checkStoreRefusesEscapingIdentifiers(_ check: (Bool, String) -> Void) {
        // Fixture check first: an ordinary id really is accepted, so the
        // refusals below are not passing because everything is refused.
        check(NotebookStore.isSafeIdentifier("migrations/raas-cutover"),
              "fixture check: an ordinary id must be accepted")

        for bad in ["../escape", "a/../../b", "/etc/passwd", "", "a//b", "a/./b",
                    ".hidden", "a\\b", "a/b/c/d/e/f"] {
            check(!NotebookStore.isSafeIdentifier(bad), "\"\(bad)\" must be refused as a page id")
        }

        withScratchStore { store, root in
            check(store.fileURL(for: "../escape") == nil, "an escaping id resolves to no file")
            store.updatePage(id: "../escape", content: "should never be written")
            let sibling = root.deletingLastPathComponent().appendingPathComponent("escape.md")
            check(!FileManager.default.fileExists(atPath: sibling.path),
                  "a write through an escaping id must land nowhere")
        }
    }

    /// AGENTS.md's recorded hermeticity hole: a store inside `ShiftGitSync`'s
    /// working tree that ignores `FM_SHIFT_DIR` lets a suite setting only that
    /// variable still write into the captain's real clone.
    private static func checkStoreHonoursShiftDirOverride(_ check: (Bool, String) -> Void) {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-notebook-shiftdir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let previousNotebook = ProcessInfo.processInfo.environment["FM_NOTEBOOK_DIR"]
        let previousShift = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        unsetenv("FM_NOTEBOOK_DIR")
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer {
            if let previousNotebook { setenv("FM_NOTEBOOK_DIR", previousNotebook, 1) }
            if let previousShift { setenv("FM_SHIFT_DIR", previousShift, 1) } else { unsetenv("FM_SHIFT_DIR") }
        }

        let store = NotebookStore()
        check(store.root.path == scratch.appendingPathComponent("notebook").path,
              "FM_SHIFT_DIR alone must reroot the notebook, got \(store.root.path)")
        check(store.gitSync == nil,
              "an overridden store must have no git sync, or a test could commit to the real remote")
    }

    private static func checkDailyNote(_ check: (Bool, String) -> Void) {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 21
        let date = Calendar.current.date(from: components) ?? Date()

        check(NotebookStore.dailyNoteID(for: date) == "daily/2026-09-21",
              "the dated id is ISO under `daily/`, got \(NotebookStore.dailyNoteID(for: date))")
        // ISO because it sorts, and because it is the same day key
        // `ShiftStore`/`LogAnalyzerStore`/`MorningBriefingData` already use.
        check(NotebookStore.dailyNoteID(for: date) < NotebookStore.dailyNoteID(for: date.addingTimeInterval(86_400)),
              "dated ids must sort chronologically as plain strings")

        withScratchStore { store, _ in
            let first = store.openDailyNote(for: date)
            check(first.id == "daily/2026-09-21", "today's note lands at the dated id")
            check(first.isDailyNote, "and is recognised as a daily note")
            check(first.content.hasPrefix("# "), "with a heading, so the page has a title")

            store.updatePage(id: first.id, content: first.content + "\nsomething I wrote\n")
            let second = store.openDailyNote(for: date)
            check(second.content.contains("something I wrote"),
                  "asking again opens the existing note rather than blanking it")
            check(store.listPages().filter(\.isDailyNote).count == 1,
                  "and does not create a second file")
        }
    }

    private static func checkPlaceholderSlugs(_ check: (Bool, String) -> Void) {
        check(NotebookController.isPlaceholderSlug("untitled"), "`untitled` is a placeholder")
        check(NotebookController.isPlaceholderSlug("untitled-2"), "`untitled-2` is a placeholder")
        check(!NotebookController.isPlaceholderSlug("untitled-notes"),
              "only `untitled-<number>` is a placeholder, not any `untitled-*`")
        check(!NotebookController.isPlaceholderSlug("raas-cutover"),
              "a name the captain chose is never treated as a placeholder")
        check(!NotebookController.isPlaceholderSlug("untitled-"), "`untitled-` with no index is not a placeholder")
    }

    // MARK: The editor palette

    /// The source pane's own highlighting: a link has to be a *different*
    /// colour from body ink, and still clear the text floor on the editor's
    /// own ground. Both halves matter - a link colour that is legible but
    /// identical to ink is not highlighting.
    private static func checkEditorPalette(_ check: (Bool, String) -> Void) {
        for theme in HelmTheme.allThemes {
            let palette = NotebookEditorTheme.palette(for: theme)
            let ground = HelmTheme.nsColor(theme.backgroundHex)
            let link = NotebookEditorTheme.linkHex(for: theme)
            let ink = NotebookEditorTheme.inkHex(for: theme)

            check(palette.count == CodePreviewTheme.palette(for: theme).count,
                  "\(theme.id): the notebook palette must re-point slots, never add or drop them")

            // `HelmContrast.ratio < 1.01` is a *luminance* comparison and is
            // not a colour-equality check (AGENTS.md), so the two are compared
            // component-wise.
            let linkComponents = HelmContrast.components(HelmTheme.nsColor(String(link.dropFirst())))
            let inkComponents = HelmContrast.components(HelmTheme.nsColor(String(ink.dropFirst())))
            let same = abs(linkComponents.0 - inkComponents.0) < 0.01
                && abs(linkComponents.1 - inkComponents.1) < 0.01
                && abs(linkComponents.2 - inkComponents.2) < 0.01
            check(!same, "\(theme.id): a wiki-link must not be painted the same colour as body text (\(link))")

            let ratio = HelmContrast.ratio(HelmTheme.nsColor(String(link.dropFirst())), ground)
            check(ratio >= CodePreviewTheme.textFloor,
                  "\(theme.id): the link colour measures \(String(format: "%.2f", ratio)) on the editor ground, "
                  + "below the \(CodePreviewTheme.textFloor) floor")

            let headingRatio = HelmContrast.ratio(
                HelmTheme.nsColor(String(palette[CodePreviewTheme.Key.keyword.rawValue]!.dropFirst())), ground)
            check(headingRatio >= CodePreviewTheme.textFloor,
                  "\(theme.id): a markdown heading measures \(String(format: "%.2f", headingRatio)) on the editor ground")
        }
    }

    // MARK: Wiring

    private static func checkDestinationWiring(_ check: (Bool, String) -> Void) {
        let dest = RailDestination.notebook
        check(dest.slot == .notebook, "the destination should have a body slot of its own")
        check(dest.title == "Notebook", "the destination's title")
        check(!dest.drillSubtitle.isEmpty, "every destination needs a drill subtitle")
        check(!dest.isDailyUse, "a notebook is a utility, like its Stores-space siblings")

        check(NSImage(systemSymbolName: dest.symbol, accessibilityDescription: nil) != nil,
              "the destination's SF Symbol \(dest.symbol) does not resolve - NSImage returns nil silently")

        let module = DaylightModule.allCases.first { $0.opens == .notebook }
        guard let module else {
            check(false, "no canvas module opens .notebook")
            return
        }
        check(module.space == .stores, "the Stores space is where the markdown destinations live")
        check(module.hue == dest.domainHue, "the card and the page it opens must not disagree about a hue")
        check(NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil) != nil,
              "the module's SF Symbol \(module.symbol) does not resolve")
        check(module.gridSpan == 1, "only the Morning briefing is a wide card")

        // UX4's contextual ⌘N.
        check(ContextualNewAction.forDestination(.notebook) == .notebookPage,
              "⌘N on the Notebook makes a page")
        check(ContextualNewAction.notebookPage.owningDestination == .notebook,
              "and the Shortcuts sheet names the right page")

        // ⌘K.
        check(UnifiedSearchKind.groupOrder.contains(UnifiedSearchKind.notebookPage.groupTitle),
              "the notebook's palette group must be in the order list, or its rows render last by accident")
    }
}

#endif
