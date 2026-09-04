// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-cluster-tail`: the stern-equivalent's own logic - what a
// `kubectl logs --timestamps` block means, how several pods' blocks merge
// into one ordered stream, and which colour each pod carries. Pure, no
// AppKit and no bridge dependency, so every rule below is unit-tested
// (`KubeBridgeSelfTest`) rather than only visible in a running app.
//
// **Honest limits, stated here and in the UI rather than implied away.**
// This is *bounded polling*, not `kubectl logs -f`. The bridge types one
// visible, bounded command per pod into a real shell and reads its output
// back; a long-lived `-f` would never terminate, so its end marker would
// never print and the single-flight bridge would be wedged for the session.
// So: `--since=<window>` every `pollInterval`, per selected pod, serialized.
// Two consequences the UI says out loud (`KubeLogTailSession.limitsNote`):
// lines appear a poll behind, and cross-pod ordering is only as good as the
// `--timestamps` prefix each container emitted.
//
// **Why the window is deliberately wider than the poll interval.** Sampling
// exactly `--since=<poll>` every `<poll>` seconds loses every line that lands
// in the gap between a command finishing and the next one starting - and the
// bridge's own queueing/contention makes that gap variable, not fixed. The
// window is `pollInterval * overlapFactor` instead, so consecutive polls
// genuinely overlap and no line falls between them. That guarantees
// **duplicates**, which is what `KubeLogMerger`'s dedupe exists for: they are
// the price of not losing lines, and losing lines silently is the worse
// failure for a triage tool.

import Foundation

/// One rendered log line.
struct KubeLogLine: Equatable {
    let pod: String
    /// The RFC3339 timestamp `--timestamps` prefixes, kept as the original
    /// string as well as a parsed `Date`: the string is what dedupes exactly
    /// (byte-identical between two overlapping polls) while the `Date` is what
    /// orders across pods.
    let timestampText: String
    let timestamp: Date?
    let text: String
    let isError: Bool

    /// The dedupe key. Pod + exact timestamp + exact text: two genuinely
    /// distinct lines a container emitted in the same nanosecond with
    /// identical text are indistinguishable in `kubectl logs`' own output too,
    /// so collapsing them is not a loss this layer could avoid.
    var identity: String { "\(pod)\u{0000}\(timestampText)\u{0000}\(text)" }
}

enum KubeLogParser {

    /// `kubectl logs --timestamps` prefixes each line with an RFC3339Nano
    /// timestamp and a single space. A line without one (a container that
    /// wrote a partial line, or kubectl's own "unable to retrieve container
    /// logs" note) is kept verbatim with a `nil` timestamp rather than
    /// dropped - a triage tool that silently discards the one line explaining
    /// why there are no lines is worse than useless.
    static func parseBlock(_ raw: String, pod: String) -> [KubeLogLine] {
        raw.components(separatedBy: "\n").compactMap { rawLine in
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            if let spaceIndex = line.firstIndex(of: " ") {
                let head = String(line[line.startIndex..<spaceIndex])
                if let date = parseTimestamp(head) {
                    let body = String(line[line.index(after: spaceIndex)...])
                    return KubeLogLine(pod: pod, timestampText: head, timestamp: date,
                                       text: body, isError: looksLikeError(body))
                }
            }
            return KubeLogLine(pod: pod, timestampText: "", timestamp: nil,
                               text: line, isError: looksLikeError(line))
        }
    }

    /// Kubernetes emits RFC3339 with nanosecond precision and a `Z` suffix
    /// (`2026-09-04T11:02:31.482913204Z`), which `ISO8601DateFormatter`
    /// handles only after the fractional part is truncated to what it
    /// accepts. Parsed by hand rather than with a `DateFormatter` per line -
    /// this runs once per log line, and a cached formatter that has to be
    /// reconfigured for the with/without-fraction cases is both slower and
    /// more fragile than reading the fixed-width fields directly.
    static func parseTimestamp(_ text: String) -> Date? {
        // 2026-09-04T11:02:31[.fraction][Z|+hh:mm]
        guard text.count >= 20, text.hasPrefix("2") || text.hasPrefix("1") else { return nil }
        let chars = Array(text)
        func int(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= chars.count else { return nil }
            return Int(String(chars[range]))
        }
        guard chars.count > 19, chars[4] == "-", chars[7] == "-", chars[10] == "T",
              chars[13] == ":", chars[16] == ":",
              let year = int(0..<4), let month = int(5..<7), let day = int(8..<10),
              let hour = int(11..<13), let minute = int(14..<16), let second = int(17..<19) else { return nil }
        var fraction: TimeInterval = 0
        var index = 19
        if index < chars.count, chars[index] == "." {
            var digits = ""
            index += 1
            while index < chars.count, chars[index].isNumber {
                if digits.count < 9 { digits.append(chars[index]) }
                index += 1
            }
            if !digits.isEmpty, let value = Double(digits) {
                fraction = value / pow(10, Double(digits.count))
            }
        }
        // Only a `Z` (UTC) suffix is accepted - which is what kubelet always
        // emits. An offset-bearing timestamp would need a whole timezone
        // parse for a case that does not occur; treating it as unparsed keeps
        // the line (with a `nil` date) rather than mis-ordering it by hours.
        guard index < chars.count, chars[index] == "Z" else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let base = calendar.date(from: components) else { return nil }
        return base.addingTimeInterval(fraction)
    }

    /// Deliberately a **plain, documented heuristic**, exactly like
    /// `KubeContextInfo.looksLikeProduction` - a substring scan for the tokens
    /// container logs conventionally use, never a claim to have understood the
    /// line. It drives one optional filter and one colour, never a decision,
    /// so a false positive costs a row being visible under "Errors only" and
    /// nothing more.
    static func looksLikeError(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Substring tokens. "error" alone already covers `level=error`,
        // `"level":"error"`, `[ERROR]` and `ERR0R`-free variants, so those are
        // deliberately not listed again - a longer list that adds nothing is
        // just more to get wrong.
        for token in ["error", "fatal", "panic", "exception", "traceback", "failed", "failure"] where lower.contains(token) {
            return true
        }
        // Prefix-only forms, which a substring scan would over-match on
        // (`err` appears inside "referred", "inferred", "terrible").
        return lower.hasPrefix("err") || lower.hasPrefix("e ") || lower.hasPrefix("crit") || lower.hasPrefix("severe")
    }
}

/// Assigns each pod a stable, theme-resolved colour.
///
/// **Why `HelmTint` cases rather than a fixed hex palette.** The obvious
/// reach is `HostCatalog.accents` - eight literal hexes this app already
/// has - but AGENTS.md records exactly why that was wrong when
/// `SSHKeyType.accentHex` tried it: those hexes were picked against
/// `helm-dark` and measurably washed out on Gruvbox Light once they landed on
/// a real accent bar, which is why that type now carries a `HelmTint`
/// instead. A log line's colour is *text on a surface*, the most
/// contrast-sensitive use there is, so the same lesson applies with more
/// force. Semantic tints resolve per theme in all 14 palettes and go through
/// `HelmContrast.legibleTintedText` at render time.
///
/// `.critical` is excluded: it is what an error line is drawn in, and a pod
/// permanently coloured "error red" would make every one of its lines read as
/// a failure. `.neutral` is excluded because it *is* the ink - a pod coloured
/// neutral would be indistinguishable from an unassigned line.
enum KubeLogPalette {
    static let tints: [HelmTint] = [.accent, .info, .good, .warn, .violet]

    /// Stable by *first appearance*, never by hash and never re-sorted: the
    /// captain builds a mental map of "the teal one is search-api" within
    /// seconds, and a colour that moved when an unrelated pod was added or
    /// removed would break it. The caller keeps the ordered pod list.
    static func tint(forPodAt index: Int) -> HelmTint {
        tints[index % tints.count]
    }
}

/// Accumulates polls into one ordered, deduped, bounded stream.
///
/// Owned by the Log Tail view; deliberately a plain value-semantics-ish class
/// with no timer of its own, so a test can drive it with literal blocks.
final class KubeLogMerger {

    /// How many lines are retained. A tail is a *window*, not an archive -
    /// the Log Analyzer destination is what this app has for keeping output.
    /// The cap also bounds the demand-driven table's row count, though that
    /// table would survive far more (`ReviewPRListView`'s own header records
    /// why every list in this app is a table rather than a stack).
    let maxLines: Int

    private(set) var lines: [KubeLogLine] = []
    /// Every identity currently in `lines`, so dedupe is O(1) per candidate
    /// rather than a scan of the whole window per polled line.
    private var seen: Set<String> = []
    /// Pods in first-appearance order - the index `KubeLogPalette` colours by.
    private(set) var podOrder: [String] = []

    init(maxLines: Int = 4000) {
        self.maxLines = max(1, maxLines)
    }

    /// Registers a pod's colour slot before it has produced any line, so a
    /// selected-but-silent pod still has a stable colour in the picker.
    func registerPod(_ pod: String) {
        guard !podOrder.contains(pod) else { return }
        podOrder.append(pod)
    }

    func tint(for pod: String) -> HelmTint {
        KubeLogPalette.tint(forPodAt: podOrder.firstIndex(of: pod) ?? 0)
    }

    /// Merges one poll's worth of new lines. Returns how many were genuinely
    /// new, so a caller can tell "nothing happened" from "the poll failed".
    @discardableResult
    func append(_ incoming: [KubeLogLine]) -> Int {
        var added = 0
        for line in incoming where !seen.contains(line.identity) {
            seen.insert(line.identity)
            lines.append(line)
            registerPod(line.pod)
            added += 1
        }
        guard added > 0 else { return 0 }
        // Sort the whole window rather than only the new tail: a slow pod's
        // block can legitimately arrive a poll late and belong earlier in the
        // stream. `sort` on an almost-sorted array is close to linear, and the
        // window is bounded by `maxLines`.
        //
        // A line with no parsable timestamp keeps its arrival position rather
        // than being flung to one end - `sort(by:)` is not stable, so ordering
        // is by a (timestamp, arrival-index) pair with a nil timestamp
        // inheriting the previous line's, which is exactly what a container's
        // own continuation line means.
        var lastKnown: Date = .distantPast
        var keyed: [(KubeLogLine, Date, Int)] = []
        keyed.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if let ts = line.timestamp { lastKnown = ts }
            keyed.append((line, line.timestamp ?? lastKnown, index))
        }
        keyed.sort { a, b in a.1 == b.1 ? a.2 < b.2 : a.1 < b.1 }
        lines = keyed.map(\.0)
        if lines.count > maxLines {
            let dropped = lines.prefix(lines.count - maxLines)
            for line in dropped { seen.remove(line.identity) }
            lines.removeFirst(lines.count - maxLines)
        }
        return added
    }

    func clear() {
        lines.removeAll()
        seen.removeAll()
        // `podOrder` deliberately survives a clear: the captain's selection
        // (and therefore their colour map) has not changed just because the
        // window was emptied.
    }

    /// The rows the view renders, honouring the errors-only filter.
    func visibleLines(errorsOnly: Bool) -> [KubeLogLine] {
        errorsOnly ? lines.filter(\.isError) : lines
    }
}

/// The tail's own tunables and the honest limits sentence the UI shows.
enum KubeLogTailSession {
    /// The scout report's own reasoned range is 5-10s. **5s** is the choice:
    /// the report calls the Log Tail a triage tool, and the difference
    /// between a 5s and a 10s lag is the difference between watching a
    /// rollout and reading about it. The cost - one visible command per
    /// selected pod per cycle in the *dedicated feed tab* - lands nowhere the
    /// captain is typing, which is the whole reason the feed tab exists.
    static let pollInterval: TimeInterval = 5

    /// See this file's header: the `--since` window is deliberately wider
    /// than the poll interval so consecutive polls overlap and no line falls
    /// in the gap. 3x covers a poll cycle that ran long behind contention
    /// without pulling back so much history that every cycle re-sends
    /// hundreds of already-seen lines.
    static let overlapFactor: Double = 3

    static var sinceSeconds: Int { Int(pollInterval * overlapFactor) }

    /// The most pods that may be tailed at once. Each one costs its own
    /// serialized command per cycle, so at 5s a selection of six already
    /// leaves under a second of headroom per command - past that the tail
    /// silently falls behind its own cadence, which is worse than refusing
    /// the seventh checkbox.
    static let maxSelectedPods = 6

    static let limitsNote =
        "Bounded polling, not live streaming: one `kubectl logs --since=\(sinceSeconds)s --timestamps` per selected pod every \(Int(pollInterval))s, in the feed tab. Lines appear up to one cycle late, and ordering across pods is only as good as each container's own timestamps."
}
