// Grand Line - native macOS app.
//
// F4 of full review #3 §8, "Reading list / link inbox": the model and every
// decision that is a *rule* rather than a view or a write.
//
// The report's own entry is one sentence - "paste a URL anywhere, a card with
// title/favicon/summary (local `LinkPresentation`), tags, 'read', optional AI
// one-paragraph summary via `ClaudeOneShot`" - and the captain reviewed a
// mockup of the page before any of it existed. What is here is that mockup's
// arrangement, with the two departures stated in `ReadingListController`'s
// own header.
//
// **This file owns no AppKit, on purpose.** AGENTS.md's self-test
// classification rule decides whether a suite guards the *blocking* CI job,
// and getting it wrong is silent - so the split is made before the code is
// written rather than argued about afterwards. Everything below is assertable
// with no window at all and is `ReadingListSelfTest`'s; only the page's own
// rendered geometry and painted colours need a session, and those are
// `ReadingListViewSelfTest`'s.
//
// The three things worth reading before changing anything here:
//
//   - **`detectURL` is deliberately conservative.** It accepts a bare
//     `https://...`, a `www.` host and a naked `host.tld/path`, and it
//     refuses anything else - including a line of prose that merely *contains*
//     a link. A capture that guessed wrong would file a sentence as a reading
//     item and lose the sentence's own destination, which is worse than
//     making the captain press ⌘6.
//   - **`normalise` strips tracking parameters.** Two captures of the same
//     article arriving from a newsletter and from a search result are the
//     same article, and `isDuplicate` is what stops the grid growing a second
//     card for it. The strip list is `utm_*` plus the four vendor click ids
//     this app has actually seen; anything unrecognised is left alone, since
//     a query parameter is generally load-bearing.
//   - **Metadata state is three-valued** (GL-14, the most-cited rule in
//     AGENTS.md). "Not fetched yet", "fetched and this is the title" and
//     "fetch failed" are different states, and none of them renders as a
//     blank title pretending to be one.

import Foundation

// MARK: - Metadata state

/// Where a link's own title/summary came from - GL-14's three states, never
/// collapsed into "there is a title" / "there is not".
///
/// Stored, not derived: a fetch that failed on a plane must still read as a
/// failure after a relaunch, rather than as a link nobody has got to yet.
enum ReadingLinkMetadataState: Equatable {
    /// Saved, and `LinkPresentation` has not answered yet. The card shows the
    /// URL and says so.
    case pending
    /// `LinkPresentation` answered. `title`/`summary` are its words.
    case resolved
    /// `LinkPresentation` refused or timed out. The card keeps the URL, says
    /// the title could not be read, and offers a retry - it does **not**
    /// silently show the URL as though it were the title.
    case failed(String)

    var rawValue: String {
        switch self {
        case .pending: return "pending"
        case .resolved: return "resolved"
        case .failed: return "failed"
        }
    }

    /// The failure's own words, for the card's second line. `nil` for the two
    /// states that are not failures, so a caller cannot render an empty
    /// reason as though there were one.
    var failureReason: String? {
        if case .failed(let why) = self { return why }
        return nil
    }
}

// MARK: - One saved link

/// One card in the reading list.
///
/// `title` and `summary` are **whatever `LinkPresentation` said**, and stay
/// empty when it has said nothing yet - the card decides what to draw from
/// `metadataState`, so an empty title can never be mistaken for a fetched one.
/// `aiSummary` is separate from `summary` for the same reason: the page's own
/// `og:description` and a paragraph a model wrote are different claims and the
/// card labels them differently.
struct ReadingLink: Equatable {
    var id: String
    /// The normalised absolute URL - see `ReadingListURL.normalise`.
    var url: String
    /// `LinkPresentation`'s title. Empty until it answers.
    var title: String
    /// `LinkPresentation`'s own description, when the page carried one.
    var summary: String
    /// `ClaudeOneShot`'s paragraph. Empty until the captain asks for one -
    /// this is never fetched on paste, see `ReadingListAI`'s header.
    var aiSummary: String
    var tags: [String]
    var addedAt: Date
    /// `nil` is unread. A date rather than a `Bool` so the Read filter can be
    /// ordered most-recently-read first and the card can say *when*.
    var readAt: Date?
    var metadataState: ReadingLinkMetadataState

    var isRead: Bool { readAt != nil }

    /// The host, for the card's kicker and the monogram tile. Derived rather
    /// than stored: it is a pure function of `url` and a stored copy could
    /// only ever disagree with it.
    var host: String { ReadingListURL.host(of: url) }

    init(id: String,
         url: String,
         title: String = "",
         summary: String = "",
         aiSummary: String = "",
         tags: [String] = [],
         addedAt: Date = Date(),
         readAt: Date? = nil,
         metadataState: ReadingLinkMetadataState = .pending) {
        self.id = id
        self.url = url
        self.title = title
        self.summary = summary
        self.aiSummary = aiSummary
        self.tags = tags
        self.addedAt = addedAt
        self.readAt = readAt
        self.metadataState = metadataState
    }

    /// What the card puts on its title line.
    ///
    /// GL-14 in one function. A resolved link shows its real title; a link
    /// whose fetch has not landed or has failed shows the *path*, which is
    /// honest about being the URL rather than a title, and the card's own
    /// second line says which of the two states it is in.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if metadataState == .resolved, !trimmed.isEmpty { return trimmed }
        // Not `url` itself: a 300-character tracking URL is not a title, and
        // the host is already drawn as the kicker right above this line.
        return ReadingListURL.pathSummary(of: url)
    }

    /// Whether the card draws the summary well at all, and with which label.
    ///
    /// Deliberately an enum rather than two optionals checked in the view: the
    /// mockup's whole judgment call is that "optional AI summary" is shown as
    /// *state* - one card carries a summary, one carries a Summarise button,
    /// one needed neither - so the three states are named once, here, and the
    /// card renders whichever it is handed.
    enum SummaryKind: Equatable {
        case ai(String)
        case page(String)
        case none
    }

    /// The AI paragraph wins when there is one: the captain asked for it
    /// explicitly, and it is about the article rather than about the page's
    /// marketing copy.
    var summaryKind: SummaryKind {
        let ai = aiSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ai.isEmpty { return .ai(ai) }
        let page = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !page.isEmpty { return .page(page) }
        return .none
    }
}

// MARK: - URLs

/// Everything this feature decides about a URL string.
///
/// One type rather than helpers scattered over the store, the router and the
/// card, because the capture panel shows the captain what it is about to
/// save and the store then saves it - and those two have to be the same
/// string (`CaptureRouter.snippetName`'s own note records this app learning
/// that lesson on a different feature).
enum ReadingListURL {

    /// Query parameters that identify a *campaign* rather than a document,
    /// stripped so the same article captured twice is one card.
    ///
    /// Everything not on this list survives, deliberately: `?v=` on YouTube,
    /// `?id=` on a tracker and `?page=2` on a forum thread are all
    /// load-bearing, and a generous strip list would silently save the wrong
    /// page. The vendor click ids are the four this app has actually seen in
    /// a captain's own captures.
    static let trackingParameterPrefixes = ["utm_"]
    static let trackingParameterNames: Set<String> = [
        "gclid", "fbclid", "mc_cid", "mc_eid", "igshid", "ref_src",
    ]

    /// The longest URL this feature will accept.
    ///
    /// A data URI or a signed S3 link can run to tens of kilobytes; one of
    /// those in a git-synced YAML file is a diff nobody can read, and it is
    /// not a thing anyone reads later either.
    static let maximumLength = 2048

    /// Turn one captured string into the URL this feature stores, or `nil`
    /// when it is not one.
    ///
    /// Accepts three shapes and no others - see this file's header for why
    /// the conservatism is deliberate:
    ///
    ///   - an absolute `http`/`https` URL;
    ///   - a `www.`-led host, which gets `https://`;
    ///   - a bare `host.tld[/path]` whose TLD is alphabetic and at least two
    ///     characters, which also gets `https://`.
    ///
    /// Everything else - a `file:` path, a `mailto:`, an IP literal with no
    /// scheme, a sentence with a link in the middle of it - returns `nil`.
    static func detect(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
        // One token. A capture with a space in it is prose, and prose that
        // happens to contain a link is a note, not a reading item.
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return normalise(trimmed)
        }
        // A scheme this feature does not handle must not be silently given
        // `https://` - `mailto:someone@example.com` would become a nonsense
        // host. Anything with a `:` before the first `/` is treated as
        // already-schemed and refused.
        if let colon = trimmed.firstIndex(of: ":") {
            let beforeColon = trimmed[trimmed.startIndex..<colon]
            if !beforeColon.contains("/"), !beforeColon.isEmpty,
               beforeColon.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
                return nil
            }
        }
        guard looksLikeBareHost(trimmed) else { return nil }
        return normalise("https://" + trimmed)
    }

    /// `host.tld`, `www.host.co.uk/path?q=1`, but not `hello`, `1.2`, or
    /// `../relative/path`.
    private static func looksLikeBareHost(_ candidate: String) -> Bool {
        let hostPart = candidate.split(separator: "/", maxSplits: 1,
                                       omittingEmptySubsequences: false)[0]
        // Strip a userinfo/port so `example.com:8080` still reads as a host.
        let bare = hostPart.split(separator: ":", maxSplits: 1,
                                  omittingEmptySubsequences: false)[0]
        let labels = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        guard labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// The stored form: scheme and host lowercased, tracking parameters
    /// dropped, a lone trailing `/` on a bare host removed, fragment kept.
    ///
    /// The fragment is kept on purpose - a deep link into a long document is
    /// the paragraph someone meant to come back to, and dropping it would
    /// lose the only interesting part of the capture.
    static func normalise(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumLength else { return nil }
        guard var components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.scheme = scheme
        components.host = host

        if let items = components.queryItems {
            let kept = items.filter { !isTrackingParameter($0.name) }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        // `URLComponents` keeps a trailing `/` on `https://example.com/`,
        // which would make it a different string from `https://example.com`
        // for `isDuplicate`. Only a *bare* host is trimmed; `/docs/` is a real
        // path and a server may well treat it differently from `/docs`.
        if components.path == "/" { components.path = "" }
        return components.string
    }

    static func isTrackingParameter(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if trackingParameterNames.contains(lowered) { return true }
        return trackingParameterPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// The host, with `www.` dropped - `kubernetes.io`, `pganalyze.com`. The
    /// empty string for anything unparseable, which only a hand-edited file
    /// can produce.
    static func host(of url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return "" }
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }

    /// The URL minus its scheme, elided - what a card shows on its title line
    /// while there is no real title to show.
    static func pathSummary(of url: String, limit: Int = 72) -> String {
        guard let components = URLComponents(string: url) else { return url }
        var text = components.host ?? url
        if !components.path.isEmpty, components.path != "/" { text += components.path }
        if let query = components.query, !query.isEmpty { text += "?" + query }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\u{2026}"
    }

    /// The one or two letters a monogram tile draws when there is no favicon.
    ///
    /// The host's first label, uppercased - `K` for `kubernetes.io`, `GH` for
    /// `github.com`? No: one letter, deliberately. The mockup draws a single
    /// character in an 18pt square and two would have to be set smaller than
    /// the caption type this app floors at 11pt (GL-32).
    static func monogram(for url: String) -> String {
        let h = host(of: url)
        guard let first = h.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }
}

// MARK: - Tags

enum ReadingListTags {

    /// The longest a tag may be. Long enough for `strict-concurrency`, short
    /// enough that a chip never has to truncate on a 320pt card.
    static let maximumLength = 24

    /// The most tags one link may carry, so a card's tag row stays one line.
    static let maximumPerLink = 8

    /// One tag, as it is stored: lowercased, spaces and separators folded to
    /// `-`, everything else dropped, collapsed runs, no leading or trailing
    /// dash. `nil` when nothing usable survives.
    ///
    /// Lowercasing is what makes the sidebar's tag list a list of *tags*
    /// rather than of spellings - `K8s` and `k8s` are one row with one count,
    /// which is the whole reason the sidebar is worth having.
    static func normalise(_ raw: String) -> String? {
        var out = ""
        var lastWasDash = false
        for scalar in raw.lowercased() {
            if scalar.isLetter || scalar.isNumber {
                out.append(scalar)
                lastWasDash = false
            } else if scalar == "-" || scalar == "_" || scalar == "." || scalar.isWhitespace || scalar == "/" {
                guard !out.isEmpty, !lastWasDash else { continue }
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        guard !out.isEmpty else { return nil }
        return String(out.prefix(maximumLength))
    }

    /// Normalise a whole list, dropping duplicates and keeping first-seen
    /// order, capped at `maximumPerLink`.
    static func normaliseList(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for candidate in raw {
            guard let tag = normalise(candidate), !seen.contains(tag) else { continue }
            seen.insert(tag)
            out.append(tag)
            if out.count == maximumPerLink { break }
        }
        return out
    }

    /// A stable index for a tag, so the sidebar's dot keeps one colour for one
    /// tag across launches.
    ///
    /// Not `String.hashValue`, which Swift seeds per-process - the same reason
    /// `ReadingListHostHue` rolls its own. FNV-1a over the tag's UTF-8.
    static func stableIndex(of tag: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in tag.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % 0x7fff_ffff)
    }

    /// Every tag across the list with how many links carry it, ordered by
    /// count then alphabetically - the sidebar's Tags section.
    ///
    /// Ordering is fixed rather than "however the dictionary came out",
    /// because a sidebar whose rows reshuffle on every render is unusable.
    static func counts(in links: [ReadingLink]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for link in links {
            for tag in link.tags { counts[tag, default: 0] += 1 }
        }
        return counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.tag < rhs.tag : lhs.count > rhs.count
            }
    }
}

// MARK: - Filtering

/// The three segmented tabs the mockup draws over the grid, plus the sidebar's
/// own inbox slices. One type, because they are the same question - which
/// subset of the list is on screen - and two types would let the tab strip and
/// the sidebar disagree about it.
enum ReadingListFilter: Equatable {
    case all
    case unread
    case read
    case summarised
    case addedToday
    case tag(String)

    /// The segmented strip's own three, in the mockup's order.
    static let tabs: [ReadingListFilter] = [.all, .unread, .summarised]

    var id: String {
        switch self {
        case .all: return "all"
        case .unread: return "unread"
        case .read: return "read"
        case .summarised: return "summarised"
        case .addedToday: return "added-today"
        case .tag(let tag): return "tag:" + tag
        }
    }

    var title: String {
        switch self {
        case .all: return "All"
        case .unread: return "Unread"
        case .read: return "Read"
        case .summarised: return "Summarised"
        case .addedToday: return "Added today"
        case .tag(let tag): return tag
        }
    }

    static func fromID(_ id: String) -> ReadingListFilter? {
        if id.hasPrefix("tag:") { return .tag(String(id.dropFirst(4))) }
        return [ReadingListFilter.all, .unread, .read, .summarised, .addedToday]
            .first { $0.id == id }
    }
}

enum ReadingListQuery {

    /// Apply one filter, then order.
    ///
    /// **Unread first, newest first inside each half** - which is the order a
    /// reading list is for. Read items keep their own most-recently-read-first
    /// order, so "what did I just finish" is at the top of the Read slice
    /// rather than at the bottom of a pile sorted by when it was saved.
    static func apply(_ filter: ReadingListFilter, to links: [ReadingLink],
                      now: Date = Date(), calendar: Calendar = .current) -> [ReadingLink] {
        let matching = links.filter { matches(filter, $0, now: now, calendar: calendar) }
        return matching.sorted(by: order)
    }

    static func matches(_ filter: ReadingListFilter, _ link: ReadingLink,
                        now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch filter {
        case .all: return true
        case .unread: return !link.isRead
        case .read: return link.isRead
        // "Summarised" is the *AI* summary, not the page's own description:
        // the tab exists so the captain can find the ones they spent a
        // `claude -p` call on, and every second page on the web carries an
        // `og:description`.
        case .summarised: return !link.aiSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .addedToday: return calendar.isDate(link.addedAt, inSameDayAs: now)
        case .tag(let tag): return link.tags.contains(tag)
        }
    }

    static func order(_ lhs: ReadingLink, _ rhs: ReadingLink) -> Bool {
        if lhs.isRead != rhs.isRead { return !lhs.isRead }
        if lhs.isRead, rhs.isRead {
            return (lhs.readAt ?? .distantPast) > (rhs.readAt ?? .distantPast)
        }
        return lhs.addedAt > rhs.addedAt
    }

    /// The drill header's live line: how many are waiting and how many there
    /// are altogether - the mockup's "11 unread \u{00B7} 34 saved".
    ///
    /// GL-14: the caller decides whether the list has been read off disk yet;
    /// this never invents a zero for a list nobody has loaded.
    static func headline(_ links: [ReadingLink]) -> String {
        guard !links.isEmpty else { return "Nothing saved yet" }
        let unread = links.filter { !$0.isRead }.count
        let saved = links.count == 1 ? "1 saved" : "\(links.count) saved"
        guard unread > 0 else { return "All read \u{00B7} \(saved)" }
        return "\(unread) unread \u{00B7} \(saved)"
    }

    /// Whether this URL is already on the list. Compares the **normalised**
    /// string, which is the whole reason `normalise` strips campaign
    /// parameters - see its own note.
    static func existing(_ url: String, in links: [ReadingLink]) -> ReadingLink? {
        guard let normalised = ReadingListURL.normalise(url) else { return nil }
        return links.first { $0.url == normalised }
    }
}

// MARK: - Identity colour

/// The monogram tile's colour, derived from the host.
///
/// A `HelmDomainHue`, never a `HelmTint`: the tile says "this is
/// kubernetes.io", not "this is a warning", and routing an identity through a
/// semantic slot is the exact defect `HelmDomainHue.identityHex(in:)` exists
/// to stop (`CaptureDestination.hue` carries the same note, for the same
/// reason).
///
/// Derived rather than stored so a host's colour is the same on every card and
/// on every machine, and so nothing has to migrate when the palette grows.
enum ReadingListHostHue {

    /// Deliberately not `String.hashValue`, which is seeded per-process in
    /// Swift and would give one host a different colour on every launch. A
    /// plain FNV-1a over the host's UTF-8 is stable forever, which is the only
    /// property that matters here.
    static func hue(for url: String) -> HelmDomainHue {
        let host = ReadingListURL.host(of: url)
        guard !host.isEmpty else { return .slate }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in host.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        // `.slate` is excluded from the rotation: it is this app's "no
        // identity" hue and is what an unparseable URL gets above, so a real
        // host wearing it would be indistinguishable from a broken one.
        let palette: [HelmDomainHue] = [.blue, .teal, .green, .amber, .rose, .violet]
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// What the reader's `WKNavigationDelegate` should do with one navigation.
///
/// A pure function rather than a body inside the delegate, because a
/// `WKNavigationAction` has no public initialiser - the decision could
/// otherwise only be asserted by driving a real remote page, which is exactly
/// how the sub-frame half of this rule shipped wrong (B15).
enum ReadingListNavigation {

    enum Decision: Equatable {
        /// Let the web view load it.
        case allow
        /// Refuse it, and say nothing - a `file:`/custom-scheme redirect from
        /// a remote page is not something a reading list follows anywhere.
        case cancel
        /// Refuse it and hand it to the system browser instead.
        case openExternally
    }

    /// The reader loads the saved link and whatever that page navigates to on
    /// the same site; anything else is the captain's decision, in a real
    /// browser.
    ///
    /// **The rule is about the top-level page, never about a sub-frame.** A
    /// modern article embeds YouTube, a comment widget, an analytics pixel and
    /// a newsletter form, and every one of those is a cross-host navigation in
    /// a frame the reader owns. Applying the same-host rule to them cancels
    /// the embed (so the article renders with holes) *and* opens each one as a
    /// tab in the system browser - a page with three embeds opened three tabs
    /// the captain never asked for. A sub-frame load is part of rendering the
    /// page the captain already chose to read, so it is allowed on its own
    /// scheme check alone.
    ///
    /// `isMainFrame` is `navigationAction.targetFrame?.isMainFrame ?? true`:
    /// a nil target frame is a `target="_blank"`-shaped navigation into a
    /// frame that does not exist yet, which is a new top-level page and must
    /// take the strict path.
    static func decide(url: URL, savedHost: String, isMainFrame: Bool) -> Decision {
        if url.scheme?.lowercased() == "about" { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .cancel }
        if !isMainFrame { return .allow }
        let targetHost = ReadingListURL.host(of: url.absoluteString)
        if !savedHost.isEmpty, targetHost == savedHost { return .allow }
        return .openExternally
    }
}
