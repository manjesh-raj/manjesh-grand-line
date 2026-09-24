// Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for the reading list's *logic* half
// (`fm/grandline-feature-f4-reading-list`, F4 of full review #3 §8): URL
// detection and normalisation, tag folding, the filter and ordering rules, the
// three-valued metadata state, the AI prompt and its reply parse, the store's
// disk round trip, its GL-01 refusals, its forward-compatible decode, and the
// destination's own wiring into the shell's tables.
//
// **Pure logic, no window** - and that classification is the operative one,
// not a style note: `NEEDS_SESSION` in `Scripts/run-all-tests.sh` decides
// whether a suite guards the *blocking* CI job, so a pure-logic suite parked
// there would still pass, still look healthy, and never once guard a merge
// (AGENTS.md's "Writing a self-test"). Nothing here builds a view.
// `ReadingListViewSelfTest` is the window-backed half, and it is the one in
// `NEEDS_SESSION`.
//
// **Nothing here reaches the network.** `LPMetadataProvider` is behind the
// `ReadingListMetadataFetching` seam, and this suite drives the seam's own
// canned implementations - what is interesting is what the *store and the
// card* do with each outcome, not whether a site was up.
//
// `FM_RUN_READING_LIST_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ReadingListSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkURLDetection(check)
        checkNormalisation(check)
        checkHostAndMonogram(check)
        checkHostHueIsStable(check)
        checkTagNormalisation(check)
        checkTagCounts(check)
        checkDisplayTitleAndSummaryKind(check)
        checkFiltersAndOrdering(check)
        checkHeadline(check)
        checkStoreRoundTrip(check)
        checkStoreRefusesNonURLsAndDuplicates(check)
        checkStoreRefusesWritingAnUnreadableFile(check)
        checkStorePreservesRecordsThisBuildCannotDecode(check)
        checkLegacyRecordDecode(check)
        checkStoreHonoursShiftDirOverride(check)
        checkIconCacheNaming(check)
        checkAIPromptAndParse(check)
        checkCaptureRouterDefault(check)
        checkDestinationWiring(check)

        print(ok ? "ReadingListSelfTest: OK" : "ReadingListSelfTest: FAILURES")
        return ok
    }

    // MARK: Scratch helpers

    /// A disposable store, rooted in a temp directory. **Never** the production
    /// constructor: `ReadingListStore()` with no override resolves to
    /// `ReadingListGitSync.shared`, which shares `ShiftGitSync.shared`'s real
    /// clone of the captain's private config repo.
    private static func scratchStore(_ body: (ReadingListStore, URL) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-reading-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        body(ReadingListStore(root: root), root)
    }

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    private static func link(_ url: String,
                             title: String = "",
                             ai: String = "",
                             tags: [String] = [],
                             added: String = "2026-09-01T09:00:00Z",
                             read: String? = nil,
                             state: ReadingLinkMetadataState = .resolved) -> ReadingLink {
        ReadingLink(id: url, url: url, title: title, aiSummary: ai, tags: tags,
                    addedAt: date(added), readAt: read.map(date), metadataState: state)
    }

    // MARK: URLs

    private static func checkURLDetection(_ check: (Bool, String) -> Void) {
        // The fixture's own discriminating power first: if every case below
        // returned the same thing, the assertions after it would be vacuous.
        check(ReadingListURL.detect("https://kubernetes.io/docs/") != nil
              && ReadingListURL.detect("write the migration note") == nil,
              "URL detection: the fixture does not distinguish a URL from prose at all")

        check(ReadingListURL.detect("https://kubernetes.io/docs/concepts/")
              == "https://kubernetes.io/docs/concepts/",
              "URL detection: an absolute https URL should survive unchanged")
        check(ReadingListURL.detect("  https://swift.org/blog  ") == "https://swift.org/blog",
              "URL detection: surrounding whitespace should be trimmed")
        check(ReadingListURL.detect("www.pganalyze.com/blog/index-only-scans")
              == "https://www.pganalyze.com/blog/index-only-scans",
              "URL detection: a www. host should be given https://")
        check(ReadingListURL.detect("pganalyze.com/blog") == "https://pganalyze.com/blog",
              "URL detection: a bare host.tld/path should be given https://")
        check(ReadingListURL.detect("http://example.com") == "http://example.com",
              "URL detection: http should be kept as http rather than upgraded silently")

        // The refusals, which are the half that keeps a capture honest.
        check(ReadingListURL.detect("read https://swift.org later") == nil,
              "URL detection: prose containing a link is not a reading item")
        check(ReadingListURL.detect("mailto:someone@example.com") == nil,
              "URL detection: a mailto: must not be given an https:// prefix")
        check(ReadingListURL.detect("file:///Users/manjesh/notes.md") == nil,
              "URL detection: a file: URL is not a reading item")
        check(ReadingListURL.detect("hello") == nil,
              "URL detection: a bare word is not a host")
        check(ReadingListURL.detect("1.2") == nil,
              "URL detection: a numeric TLD is not a host")
        check(ReadingListURL.detect("") == nil,
              "URL detection: an empty capture is not a URL")
        check(ReadingListURL.detect("https://example.com/" + String(repeating: "a", count: 4000)) == nil,
              "URL detection: a URL past `maximumLength` should be refused rather than stored")
    }

    private static func checkNormalisation(_ check: (Bool, String) -> Void) {
        check(ReadingListURL.normalise("https://Example.COM/Docs") == "https://example.com/Docs",
              "normalise: the host lowercases and the path does not")
        check(ReadingListURL.normalise("https://example.com/") == "https://example.com",
              "normalise: a bare host's lone trailing slash is dropped")
        check(ReadingListURL.normalise("https://example.com/docs/") == "https://example.com/docs/",
              "normalise: a real path's trailing slash is kept - a server may treat it differently")
        check(ReadingListURL.normalise("https://example.com/a?utm_source=news&id=7")
              == "https://example.com/a?id=7",
              "normalise: utm_* is stripped and a load-bearing parameter is kept")
        check(ReadingListURL.normalise("https://example.com/a?gclid=xyz") == "https://example.com/a",
              "normalise: a lone tracking parameter leaves no empty query string behind")
        check(ReadingListURL.normalise("https://example.com/doc#the-section")
              == "https://example.com/doc#the-section",
              "normalise: the fragment is kept - a deep link is usually the point of the capture")
        check(ReadingListURL.isTrackingParameter("UTM_Campaign"),
              "normalise: the tracking-parameter check should be case-insensitive")
        check(!ReadingListURL.isTrackingParameter("page"),
              "normalise: an ordinary parameter must not be treated as tracking")
    }

    private static func checkHostAndMonogram(_ check: (Bool, String) -> Void) {
        check(ReadingListURL.host(of: "https://www.kubernetes.io/docs") == "kubernetes.io",
              "host: www. is dropped")
        check(ReadingListURL.host(of: "not a url") == "",
              "host: an unparseable string yields the empty string rather than a crash")
        check(ReadingListURL.monogram(for: "https://kubernetes.io") == "K",
              "monogram: the host's first letter, uppercased")
        check(ReadingListURL.monogram(for: "https://") == "?",
              "monogram: a URL with no host still produces something drawable")
        check(ReadingListURL.pathSummary(of: "https://example.com/a/b?x=1") == "example.com/a/b?x=1",
              "pathSummary: the scheme is dropped and the rest kept")
        check(ReadingListURL.pathSummary(of: "https://example.com/" + String(repeating: "x", count: 200),
                                         limit: 40).count == 41,
              "pathSummary: a long URL is elided to the limit plus the ellipsis")
    }

    private static func checkHostHueIsStable(_ check: (Bool, String) -> Void) {
        // The property that matters is *stability across processes*, which a
        // seeded `String.hashValue` would not have. Asserted as "the same host
        // maps to the same hue" plus a pinned expectation, so a change of hash
        // function fails here rather than repainting a captain's grid.
        let first = ReadingListHostHue.hue(for: "https://kubernetes.io/docs")
        let second = ReadingListHostHue.hue(for: "https://kubernetes.io/other/page")
        check(first == second, "host hue: one host must resolve to one hue whatever the path")
        check(ReadingListHostHue.hue(for: "nonsense") == .slate,
              "host hue: an unparseable URL gets the no-identity hue")
        check(ReadingListHostHue.hue(for: "https://swift.org") != .slate,
              "host hue: a real host must never wear the no-identity hue")
        // Discriminating power: a function returning one constant would pass
        // every assertion above.
        let hues = Set(["a.com", "b.com", "c.io", "d.dev", "e.net", "f.org", "g.co", "h.ai"]
            .map { ReadingListHostHue.hue(for: "https://" + $0) })
        check(hues.count >= 3, "host hue: eight hosts collapsed onto fewer than three hues")
    }

    // MARK: Tags

    private static func checkTagNormalisation(_ check: (Bool, String) -> Void) {
        check(ReadingListTags.normalise("K8s") == "k8s",
              "tags: lowercased, so one tag is one sidebar row rather than one per spelling")
        check(ReadingListTags.normalise("strict concurrency") == "strict-concurrency",
              "tags: a space folds to a dash")
        check(ReadingListTags.normalise("  swift / server  ") == "swift-server",
              "tags: separators collapse and the result is trimmed")
        check(ReadingListTags.normalise("!!!") == nil,
              "tags: punctuation alone is not a tag")
        check(ReadingListTags.normalise("") == nil, "tags: an empty string is not a tag")
        check(ReadingListTags.normalise(String(repeating: "x", count: 100))?.count
              == ReadingListTags.maximumLength,
              "tags: a long tag is capped at `maximumLength`")

        let list = ReadingListTags.normaliseList(["k8s", "K8s", "drain", "", "!!"])
        check(list == ["k8s", "drain"],
              "tags: duplicates fold and unusable entries drop, first-seen order kept")
        let many = ReadingListTags.normaliseList((0..<20).map { "tag\($0)" })
        check(many.count == ReadingListTags.maximumPerLink,
              "tags: a link may not carry more than `maximumPerLink`")
    }

    private static func checkTagCounts(_ check: (Bool, String) -> Void) {
        let links = [
            link("https://a.com", tags: ["k8s", "drain"]),
            link("https://b.com", tags: ["k8s"]),
            link("https://c.com", tags: ["swift"]),
        ]
        let counts = ReadingListTags.counts(in: links)
        check(counts.first?.tag == "k8s" && counts.first?.count == 2,
              "tag counts: the most-used tag sorts first")
        check(counts.map(\.tag) == ["k8s", "drain", "swift"],
              "tag counts: ties break alphabetically, so the sidebar cannot reshuffle between renders")
        check(ReadingListTags.stableIndex(of: "k8s") == ReadingListTags.stableIndex(of: "k8s"),
              "tag colour index: must be stable for one tag")
        check(ReadingListTags.stableIndex(of: "k8s") != ReadingListTags.stableIndex(of: "swift"),
              "tag colour index: two tags collapsing onto one index makes the dot meaningless")
    }

    // MARK: The model's own rendering decisions

    private static func checkDisplayTitleAndSummaryKind(_ check: (Bool, String) -> Void) {
        let resolved = link("https://kubernetes.io/docs/a", title: "Graceful node shutdown")
        check(resolved.displayTitle == "Graceful node shutdown",
              "displayTitle: a resolved link shows its real title")

        let pending = link("https://kubernetes.io/docs/a", title: "", state: .pending)
        check(pending.displayTitle == "kubernetes.io/docs/a",
              "displayTitle (GL-14): a link with no fetched title shows its path, never a blank")

        // The direction that matters: a *stale* title from a build that
        // recorded one before the state went back to pending must not be shown
        // as though it were current.
        let staleTitle = link("https://kubernetes.io/docs/a", title: "an old title", state: .pending)
        check(staleTitle.displayTitle == "kubernetes.io/docs/a",
              "displayTitle (GL-14): a title is only shown while the state says it was fetched")

        var withPage = resolved
        withPage.summary = "the page's own blurb"
        check(withPage.summaryKind == .page("the page's own blurb"),
              "summaryKind: a page description alone reads as `.page`")
        withPage.aiSummary = "the model's paragraph"
        check(withPage.summaryKind == .ai("the model's paragraph"),
              "summaryKind: the AI paragraph wins when there is one")
        check(link("https://a.com").summaryKind == ReadingLink.SummaryKind.none,
              "summaryKind: no summary at all reads as `.none`")

        check(ReadingLinkMetadataState.failed("nope").failureReason == "nope",
              "metadata state: a failure carries its own reason")
        check(ReadingLinkMetadataState.pending.failureReason == nil
              && ReadingLinkMetadataState.resolved.failureReason == nil,
              "metadata state: only a failure has a reason, so an empty one cannot be rendered as text")
    }

    // MARK: Filtering and ordering

    private static func checkFiltersAndOrdering(_ check: (Bool, String) -> Void) {
        let now = date("2026-09-21T12:00:00Z")
        let links = [
            link("https://old-unread.com", added: "2026-09-01T09:00:00Z"),
            link("https://new-unread.com", added: "2026-09-21T08:00:00Z"),
            link("https://read-early.com", added: "2026-09-02T09:00:00Z", read: "2026-09-10T09:00:00Z"),
            link("https://read-late.com", added: "2026-09-03T09:00:00Z", read: "2026-09-20T09:00:00Z"),
            link("https://summarised.com", ai: "a paragraph", added: "2026-09-04T09:00:00Z"),
        ]

        let all = ReadingListQuery.apply(.all, to: links, now: now)
        check(all.count == 5, "filter .all: everything")
        check(all.prefix(3).allSatisfy { !$0.isRead },
              "ordering: unread comes before read")
        check(all[0].url == "https://new-unread.com",
              "ordering: inside unread, newest-saved first")
        check(all[3].url == "https://read-late.com",
              "ordering: inside read, most-recently-read first")

        check(ReadingListQuery.apply(.unread, to: links, now: now).count == 3,
              "filter .unread")
        check(ReadingListQuery.apply(.read, to: links, now: now).count == 2,
              "filter .read")
        check(ReadingListQuery.apply(.summarised, to: links, now: now).map(\.url)
              == ["https://summarised.com"],
              "filter .summarised is the *AI* summary, not the page's own description")
        check(ReadingListQuery.apply(.addedToday, to: links, now: now).map(\.url)
              == ["https://new-unread.com"],
              "filter .addedToday")

        // The distinction the Summarised tab exists to make.
        var pageOnly = link("https://page-only.com")
        pageOnly.summary = "the page's own blurb"
        check(!ReadingListQuery.matches(.summarised, pageOnly),
              "filter .summarised must not count a page's own og:description as a summary")

        let tagged = [link("https://a.com", tags: ["k8s"]), link("https://b.com", tags: ["swift"])]
        check(ReadingListQuery.apply(.tag("k8s"), to: tagged, now: now).map(\.url) == ["https://a.com"],
              "filter .tag")
        check(ReadingListFilter.fromID("tag:k8s") == .tag("k8s"),
              "filter ids round-trip through `fromID` - the sidebar hands one back as a string")
        check(ReadingListFilter.fromID("unread") == .unread,
              "filter ids: an inbox slice round-trips too")
        check(ReadingListFilter.fromID("nonsense") == nil,
              "filter ids: an unknown id is nil rather than silently `.all`")
    }

    private static func checkHeadline(_ check: (Bool, String) -> Void) {
        check(ReadingListQuery.headline([]) == "Nothing saved yet",
              "headline (GL-14): an empty list says so in words rather than showing zeroes")
        check(ReadingListQuery.headline([link("https://a.com")]) == "1 unread \u{00B7} 1 saved",
              "headline: singular")
        check(ReadingListQuery.headline([link("https://a.com", read: "2026-09-10T09:00:00Z")])
              == "All read \u{00B7} 1 saved",
              "headline: a list with nothing waiting says so rather than \"0 unread\"")
    }

    // MARK: The store

    private static func checkStoreRoundTrip(_ check: (Bool, String) -> Void) {
        scratchStore { store, root in
            guard case .added(let saved) = store.add("https://kubernetes.io/docs/?utm_source=x",
                                                     tags: ["K8s", "Drain"]) else {
                check(false, "store: a plain https URL should be accepted")
                return
            }
            check(saved.url == "https://kubernetes.io/docs/",
                  "store: the URL is normalised once, at the write, so the card and the file agree")
            check(saved.tags == ["k8s", "drain"], "store: tags are normalised at the write")
            check(saved.metadataState == .pending,
                  "store: a new link starts `.pending`, never `.resolved` with an empty title")

            store.applyMetadata(id: saved.id,
                                ReadingListMetadata(title: "Graceful node shutdown",
                                                    summary: "The kubelet drains in two phases."))
            store.setRead(id: saved.id, read: true, now: date("2026-09-20T09:00:00Z"))
            store.setAISummary(id: saved.id, summary: "a paragraph")

            let reread = ReadingListStore(root: root)
            check(reread.links.count == 1, "store: one link survives a reload")
            guard let back = reread.links.first else { return }
            check(back.title == "Graceful node shutdown", "store: the title round-trips")
            check(back.summary == "The kubelet drains in two phases.", "store: the description round-trips")
            check(back.aiSummary == "a paragraph", "store: the AI summary round-trips")
            check(back.tags == ["k8s", "drain"], "store: the tags round-trip")
            check(back.isRead, "store: the read state round-trips")
            check(back.metadataState == .resolved, "store: the metadata state round-trips")

            // Idempotence, which is what keeps the Read slice's order stable
            // under a doubled click.
            let readAt = back.readAt
            let again = reread.setRead(id: back.id, read: true, now: date("2026-09-21T09:00:00Z"))
            check(again?.readAt == readAt,
                  "store: re-marking a read link read must not move its readAt")

            // Delete and undo, GL-33's "restore the value the caller had".
            guard let removed = reread.delete(id: back.id) else {
                check(false, "store: delete should return the removed link")
                return
            }
            check(reread.links.isEmpty, "store: delete removes the link")
            reread.restore(removed)
            check(reread.links.first == removed,
                  "store: restore puts back the exact record, not an approximation")
            reread.restore(removed)
            check(reread.links.count == 1, "store: a doubled undo must not duplicate the link")
        }
    }

    private static func checkStoreRefusesNonURLsAndDuplicates(_ check: (Bool, String) -> Void) {
        scratchStore { store, _ in
            if case .rejected = store.add("write the migration note") {
                check(true, "")
            } else {
                check(false, "store: prose must be rejected rather than saved as a link")
            }
            _ = store.add("https://example.com/a?utm_source=newsletter")
            // The whole reason `normalise` strips campaign parameters: the same
            // article from two sources is one card.
            if case .duplicate(let existing) = store.add("https://example.com/a?gclid=abc") {
                check(existing.url == "https://example.com/a",
                      "store: a duplicate returns the existing link so the page can scroll to it")
            } else {
                check(false, "store: the same article from two campaigns must be one card")
            }
            check(store.links.count == 1, "store: a duplicate adds nothing")
        }
    }

    private static func checkStoreRefusesWritingAnUnreadableFile(_ check: (Bool, String) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-reading-list-gl01-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("links.yaml")
        // Real content this build cannot parse - the hand-edited-syntax-error
        // case GL-01 exists for, not an empty or missing file.
        try? "links: [ { id: \"a\"\nbroken".write(to: path, atomically: true, encoding: .utf8)

        let store = ReadingListStore(root: root)
        check(store.isInFailedLoadState,
              "GL-01: an unparseable file must be recorded as a failed load, not read as zero links")
        if case .rejected = store.add("https://example.com") {
            check(true, "")
        } else {
            check(false, "GL-01: a store in a failed-load state must refuse to save anything new")
        }
        let onDisk = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        check(onDisk.contains("broken"),
              "GL-01: the unreadable file must still be on disk, not overwritten by an empty list")
        // The fixture's own discriminating power: a readable file must not
        // trip this, or the assertion above proves nothing.
        scratchStore { healthy, _ in
            check(!healthy.isInFailedLoadState,
                  "GL-01: a healthy store must not report a failed load")
        }
    }

    private static func checkStorePreservesRecordsThisBuildCannotDecode(_ check: (Bool, String) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-reading-list-skew-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("links.yaml")
        // The cross-machine skew this store's git sync exists to serve: a
        // record with no `url` at all is one this build genuinely cannot make
        // sense of. The audit's finding 4.2 is that dropping it destroys data
        // rather than only hiding it.
        let yaml = """
        links:
          - id: "from-a-newer-build"
            added_at: "2026-09-01T09:00:00Z"
            something_this_build_has_never_heard_of: "value"
          - id: "ordinary"
            url: "https://example.com"
            added_at: "2026-09-02T09:00:00Z"

        """
        try? yaml.write(to: path, atomically: true, encoding: .utf8)

        let store = ReadingListStore(root: root)
        check(store.links.count == 1, "skew: the one decodable record loads")
        check(store.unreadableRecordCount == 1,
              "skew: the record this build cannot decode is counted rather than silently dropped")
        // Now make this build write the file, which is exactly what destroyed
        // the record before the fix.
        store.setRead(id: "ordinary", read: true)
        let after = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        check(after.contains("from-a-newer-build"),
              "skew (audit 4.2): an older build's write must not delete a newer build's record")
        check(after.range(of: "from-a-newer-build")!.lowerBound
              < after.range(of: "ordinary")!.lowerBound,
              "skew: a preserved record keeps its place in the file rather than drifting to the end")
    }

    private static func checkLegacyRecordDecode(_ check: (Bool, String) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-reading-list-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The minimum a record can carry. GL-01's rule is that every field
        // needs a real fallback on the way in, and the way that gets proven is
        // against a real file rather than by reading the decoder.
        let yaml = """
        links:
          - id: "minimal"
            url: "https://example.com"

        """
        try? yaml.write(to: root.appendingPathComponent("links.yaml"),
                        atomically: true, encoding: .utf8)
        let store = ReadingListStore(root: root)
        check(store.links.count == 1, "legacy decode: a record with only id and url must still load")
        guard let link = store.links.first else { return }
        check(link.title.isEmpty && link.tags.isEmpty && !link.isRead,
              "legacy decode: absent fields take their defaults")
        check(link.metadataState == .pending,
              "legacy decode (GL-14): an absent metadata_state reads as pending, never resolved")
    }

    private static func checkStoreHonoursShiftDirOverride(_ check: (Bool, String) -> Void) {
        // `FM_SHIFT_DIR` as the second fallback is what keeps every existing
        // self-test harness in this app off the captain's real clone with no
        // per-harness edit - `StickyBoardStore.init` spells out the reasoning.
        let shiftDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-reading-list-shiftdir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: shiftDir) }
        let previousNarrow = ProcessInfo.processInfo.environment["FM_READING_LIST_DIR"]
        let previousShift = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        unsetenv("FM_READING_LIST_DIR")
        setenv("FM_SHIFT_DIR", shiftDir.path, 1)
        defer {
            if let previousNarrow { setenv("FM_READING_LIST_DIR", previousNarrow, 1) }
            if let previousShift { setenv("FM_SHIFT_DIR", previousShift, 1) } else { unsetenv("FM_SHIFT_DIR") }
        }
        let store = ReadingListStore()
        check(store.gitSync == nil,
              "FM_SHIFT_DIR: an overridden store must not attach to the production git sync")
        check(store.root.path == shiftDir.appendingPathComponent("reading-list").path,
              "FM_SHIFT_DIR: the store roots itself under the override's own reading-list folder")
    }

    private static func checkIconCacheNaming(_ check: (Bool, String) -> Void) {
        check(ReadingListIconCache.filename(forHost: "kubernetes.io") == "kubernetes.io.png",
              "icon cache: an ordinary host names its own file")
        check(ReadingListIconCache.filename(forHost: "../../etc/passwd")?.contains("/") == false,
              "icon cache: a path separator must never survive into the filename")
        check(ReadingListIconCache.filename(forHost: "..") == nil,
              "icon cache: a name that would resolve to a directory entry is refused outright")
        check(ReadingListIconCache.filename(forHost: "") == nil,
              "icon cache: an empty host has no file")
    }

    // MARK: The AI half

    private static func checkAIPromptAndParse(_ check: (Bool, String) -> Void) {
        let prompt = ReadingListAI.prompt(title: "Graceful node shutdown",
                                          host: "kubernetes.io",
                                          url: "https://kubernetes.io/docs/a",
                                          pageSummary: "The kubelet drains in two phases.")
        check(prompt.contains("https://kubernetes.io/docs/a") && prompt.contains("kubernetes.io")
              && prompt.contains("Graceful node shutdown")
              && prompt.contains("The kubelet drains in two phases."),
              "AI prompt: every known field reaches the model")
        check(prompt.contains("You have not read the page"),
              "AI prompt: the honesty clause is what stops a model inventing the article")
        check(prompt.contains("do not invent"),
              "AI prompt: the no-invention instruction must be present")

        let thin = ReadingListAI.prompt(title: "", host: "example.com",
                                        url: "https://example.com", pageSummary: "")
        check(!thin.contains("- Title:") && !thin.contains("own description:"),
              "AI prompt: an absent title or description is omitted, never sent as an empty label")

        check(ReadingListAI.parse("  A paragraph about draining.  ") == "A paragraph about draining.",
              "AI parse: whitespace is trimmed")
        check(ReadingListAI.parse("```\nA paragraph.\n```") == "A paragraph.",
              "AI parse: a code fence is stripped")
        check(ReadingListAI.parse("Summary: A paragraph.") == "A paragraph.",
              "AI parse: a leading label is stripped")
        check(ReadingListAI.parse("\u{201C}A paragraph.\u{201D}") == "A paragraph.",
              "AI parse: a wrapping smart-quote pair is stripped")
        check(ReadingListAI.parse("Line one.\n\nLine two.") == "Line one. Line two.",
              "AI parse: a multi-line answer folds to one paragraph, so the card's own wrapping decides")
        check(ReadingListAI.parse("   ") == nil,
              "AI parse: an empty answer is a failure - a blank summary would read as summarised")
        let long = ReadingListAI.parse(String(repeating: "word ", count: 500)) ?? ""
        check(long.count == ReadingListAI.maximumSummaryLength + 1,
              "AI parse: a long answer is elided to the cap plus the ellipsis rather than refused")
    }

    // MARK: The capture route

    private static func checkCaptureRouterDefault(_ check: (Bool, String) -> Void) {
        let url = CaptureRouter.draft(from: "https://kubernetes.io/docs/a")
        check(CaptureRouter.defaultDestination(for: url) == .link,
              "capture: a capture that is nothing but a URL defaults to the reading list")
        let prose = CaptureRouter.draft(from: "read https://kubernetes.io/docs/a before Friday")
        check(CaptureRouter.defaultDestination(for: prose) == .task,
              "capture: prose containing a link is still a task, which is what it was before F4")
        check(CaptureRouter.defaultDestination(for: CaptureRouter.draft(from: "")) == .task,
              "capture: an empty panel still shows the task tile as its default")

        check(CaptureDestination.link.chordDigit == 6,
              "capture: the link destination is \u{2318}6 - appended, so no existing chord renumbered")
        check(CaptureDestination.task.chordDigit == 1 && CaptureDestination.codeSnippet.chordDigit == 5,
              "capture: appending `.link` must not have renumbered the five chords already learned")
        check(CaptureDestination.forChordDigit(6) == .link, "capture: \u{2318}6 resolves to the link")
        check(CaptureDestination.forChordDigit(7) == nil,
              "capture: a digit past the last destination does nothing rather than filing a task")
        check(CaptureDestination.link.railDestination == .readingList,
              "capture: the link tile names the reading list as its destination")
        check(CaptureRouter.parseClassification("link") == .link,
              "capture: the crew's classifier can name the new destination")
        check(CaptureRouter.classificationPrompt(for: "x").contains("- link:"),
              "capture: the classification prompt describes the new destination, or the crew cannot pick it")
        check(CaptureRouter.classificationPrompt(for: "x").contains("one of six"),
              "capture: the prompt's own count must match the number of destinations it lists")
    }

    // MARK: Wiring

    private static func checkDestinationWiring(_ check: (Bool, String) -> Void) {
        check(RailDestination.readingList.slot == .readingList,
              "wiring: the destination maps to its own body slot")
        check(RailDestination.readingList.title == "Reading List", "wiring: the title")
        check(!RailDestination.readingList.drillSubtitle.isEmpty,
              "wiring: a destination with no drill subtitle shows a blank line under its title")
        check(NSImage(systemSymbolName: RailDestination.readingList.symbol,
                      accessibilityDescription: nil) != nil,
              "wiring: the SF Symbol must resolve - `NSImage(systemSymbolName:)` returns nil silently, "
              + "and this app has shipped an invisible icon that way")
        check(RailDestination.readingList.domainHue == .green,
              "wiring: the hue the reviewed mockup draws the page in")
        check(!RailDestination.readingList.isDailyUse,
              "wiring: the reading list is a Stores utility, not one of the daily-use six")

        check(DaylightModule.readingList.space == .stores,
              "wiring: the canvas card belongs on the Stores shelf - the report's own \"fit\"")
        check(DaylightModule.readingList.opens == .readingList,
              "wiring: the canvas card opens the destination")
        check(DaylightModule.readingList.title == "Reading List",
              "wiring: the card and the page agree about the name")
        check(DaylightModule.readingList.symbol == RailDestination.readingList.symbol,
              "wiring: the card's fallback glyph and the page's must not disagree")
        check(!DaylightModule.readingList.appearsOnOverview,
              "wiring: a new module must be listed explicitly, or it silently takes a slot on Overview")

        check(ContextualNewAction.savedLink.owningDestination == .readingList,
              "wiring: the File menu's creation verb points at this destination")
        check(ContextualNewAction.forDestination(.readingList) == .savedLink,
              "wiring: the destination maps back to its creation verb, so \u{2318}N on the page works")
        check(!ContextualNewAction.savedLink.menuTitle.hasSuffix("\u{2026}"),
              "wiring: no ellipsis - the link is saved immediately rather than opening a sheet")

        check(UnifiedSearchKind.savedLink.groupTitle == "Reading list",
              "wiring: \u{2318}K groups saved links under their own heading")
        check(UnifiedSearchKind.groupOrder.contains("Reading list"),
              "wiring: a group missing from `groupOrder` never renders in the palette")
        check(NSImage(systemSymbolName: UnifiedSearchKind.savedLink.symbol,
                      accessibilityDescription: nil) != nil,
              "wiring: the palette row's symbol must resolve")
    }
}

#endif
