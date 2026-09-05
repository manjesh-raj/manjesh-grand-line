// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-cluster-tail`: turning `kubectl`'s human-oriented column
// output into typed rows. Pure logic, no AppKit and no bridge dependency, so
// every shape below is covered by a plain unit test
// (`KubeBridgeSelfTest`) - the same split `KubeContextParser` already draws.
//
// **The design decision the scout report calls "the real engineering", made
// explicitly rather than by default: parse the human table, not `-o json`.**
// The report's own k9s section states the trade-off ("parsing human-oriented
// column output is brittle; `-o json` would be robust but pushes a much
// larger blob through a terminal buffer") and leaves the call to the build.
// The call is: **human columns.** Why, concretely -
//
//   - Every byte comes back through a *terminal buffer*, read row by row via
//     `Terminal.getBufferAsData()`. A terminal hard-wraps at the tab's real
//     column count, so a single 40KB JSON document arrives as hundreds of
//     wrapped rows that have to be re-joined before they can be parsed, and
//     any row the terminal chose to elide (or the captain scrolled past
//     mid-command) corrupts the whole document rather than one row of it.
//     A wrapped *table* degrades far more gracefully: one unparseable line is
//     one missing pod.
//   - `-o json` for ~40 pods is roughly two orders of magnitude more text
//     than the table, and every byte of it is echoed *visibly into the
//     captain's own bastion session* - the bridge types into a real tab they
//     can see. Filling their scrollback with a JSON wall every 30 seconds is
//     its own defect.
//   - kubectl's table format is far more stable in practice than its
//     reputation suggests, and - crucially - it is **self-describing**: the
//     header row names the columns, so `KubeTable` reads them rather than
//     assuming a fixed order. A kubectl version that adds a column is handled;
//     one that renames one degrades to "that field is missing", never to a
//     mis-assigned value.
//
// **Why splitting on runs of two-or-more spaces is safe here**, rather than
// the more obvious "slice at the header's own character offsets": kubectl
// renders every table through `printers.GetNewTabWriter`, a `tabwriter` with
// padding 3 - so columns are always separated by **at least** two spaces even
// when a value overflows its column, while offset-slicing breaks the moment
// a value is wider than its header. The one column that can legitimately
// contain single spaces is a trailing free-text one (events' `MESSAGE`), which
// is why `KubeTable.row` caps the split at the column count and keeps the
// remainder whole.

import Foundation

// MARK: - Generic table

/// One parsed `kubectl get`-style table: a header row naming the columns, and
/// rows addressed by column *name* rather than by index.
///
/// Reading by name is what makes this survive a kubectl that adds a column:
/// nothing here assumes `RESTARTS` is the fourth field, only that a column
/// called `RESTARTS` exists.
struct KubeTable {
    let columns: [String]
    let rows: [[String]]

    /// Splits on runs of 2+ spaces (see this file's header for why that is
    /// the right separator for kubectl's own tabwriter output). `limit`, when
    /// given, stops splitting after that many fields and keeps the whole
    /// remainder as the last one - which is how a trailing free-text column
    /// (events' `MESSAGE`) survives containing single spaces.
    static func split(_ line: String, limit: Int? = nil) -> [String] {
        var fields: [String] = []
        var current = ""
        var spaceRun = 0
        var index = line.startIndex
        while index < line.endIndex {
            if let limit, fields.count == limit - 1 {
                // Everything left is the final field, single spaces and all.
                let rest = String(line[index...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty || !current.isEmpty {
                    fields.append((current + rest).trimmingCharacters(in: .whitespaces))
                }
                return fields
            }
            let ch = line[index]
            if ch == " " || ch == "\t" {
                spaceRun += 1
            } else {
                if spaceRun >= 2, !current.isEmpty {
                    fields.append(current)
                    current = ""
                } else if spaceRun > 0, !current.isEmpty {
                    current.append(" ")
                }
                spaceRun = 0
                current.append(ch)
            }
            index = line.index(after: index)
        }
        if !current.isEmpty { fields.append(current.trimmingCharacters(in: .whitespaces)) }
        return fields
    }

    /// Parses a whole command's raw output. Returns `nil` when there is no
    /// usable header at all - which is exactly the "kubectl printed an error
    /// instead of a table" case, and must never be mistaken for an empty
    /// namespace (see `KubeResourceParser.parse`'s own no-resources handling).
    ///
    /// `lastColumnIsFreeText` keeps a trailing message column whole.
    init?(raw: String, lastColumnIsFreeText: Bool = false) {
        let lines = raw
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Scan for the header rather than assuming line 0: kubectl writes
        // deprecation warnings (`W0903 ... is deprecated`) and TLS notices to
        // stderr, which lands interleaved in the same terminal buffer ahead
        // of the table. Requiring line 0 to be the header would turn a
        // perfectly good table into a `.failed`.
        guard let headerIndex = lines.firstIndex(where: { Self.looksLikeHeader(Self.split($0)) }) else { return nil }
        let header = Self.split(lines[headerIndex])
        columns = header
        var kept: [[String]] = []
        var dropped = 0
        for line in lines[(headerIndex + 1)...] {
            let fields = Self.split(line, limit: lastColumnIsFreeText ? header.count : nil)
            guard !fields.isEmpty else { continue }
            if Self.isProbableWrapContinuation(fields, header: header) {
                dropped += 1
                continue
            }
            kept.append(fields)
        }
        rows = kept
        droppedLineCount = dropped
    }

    /// How many post-header lines were rejected as wrap debris rather than
    /// parsed. Zero in every healthy case; a caller can surface a non-zero
    /// count instead of silently showing a short table.
    private(set) var droppedLineCount = 0

    /// **Defence in depth against a terminal-wrapped row, never the primary
    /// fix** (`fm/grandline-k8s-ui-revamp`, bug 1).
    ///
    /// The real fix is upstream of this file: the feed tab now runs at a
    /// column floor wide enough that a `kubectl get pods -o wide` line cannot
    /// wrap at all (`CockpitTerminalView.applyMachineReadableGeometry`, and
    /// `Vendor/SwiftTerm/README.md`'s "Fifth patch" for why that needed a
    /// vendored change). This is the second line of defence for the cases
    /// that fix cannot cover - a pod name past the measured worst case, a
    /// kubectl that grows another column, a feed tab adopted before the
    /// widening lands - so that the failure degrades to *one missing row*
    /// rather than to a fabricated one.
    ///
    /// Both tests key off the header, which is why this is not the "fragile
    /// continuation-line detection" the brief rules out as a primary fix:
    ///
    ///  - A line that is itself a header is kubectl's own wrapped header tail
    ///    (`NOMINATED NODE   READINESS GATES` - literally what the captain's
    ///    screenshot showed as a fake pod) or a repeated header. Real data
    ///    never renders as two-or-more all-uppercase, letter-initial fields.
    ///  - A data row from a `tabwriter` always carries every column, so a row
    ///    materially short of the header's column count is the tail of a
    ///    wrapped one (the captain's other fake row: `5` plus a node IP,
    ///    where `5` was the tail of `RESTARTS`). One field of slack is
    ///    allowed for a kubectl that leaves a trailing column empty.
    static func isProbableWrapContinuation(_ fields: [String], header: [String]) -> Bool {
        if looksLikeHeader(fields) { return true }
        // Never applied to a two-column table: the slack would swallow real rows.
        guard header.count >= 4 else { return false }
        return fields.count < header.count - 1
    }

    /// A real kubectl table header is at least two column names, every one of
    /// them already uppercase and starting with a letter. A shell error
    /// (`-bash: kubectl: command not found`) keeps its single spaces and so
    /// splits into one lowercase field; a kubectl warning (`W0903 12:00:00.1
    /// ... deprecated`) fails the leading-letter/uppercase test. That is what
    /// separates "kubectl printed no table" from "the namespace is empty".
    static func looksLikeHeader(_ fields: [String]) -> Bool {
        guard fields.count >= 2 else { return false }
        return fields.allSatisfy { field in
            guard let first = field.first, first.isLetter else { return false }
            return field == field.uppercased()
        }
    }

    /// Direct init, for tests and for a caller assembling a table by hand.
    init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }

    /// Hard-wraps `text` at `columns`, exactly as a terminal emulator does -
    /// one buffer row per wrapped segment, which is what
    /// `Terminal.getBufferAsData()` then reports as separate lines. Used by
    /// the self-tests to reproduce the captain's corruption at a narrow width
    /// and prove it is gone at the feed tab's own floor.
    static func simulateTerminalWrap(_ text: String, columns: Int) -> String {
        guard columns > 0 else { return text }
        return text.components(separatedBy: "\n").flatMap { line -> [String] in
            guard line.count > columns else { return [line] }
            var out: [String] = []
            var rest = Substring(line)
            while rest.count > columns {
                out.append(String(rest.prefix(columns)))
                rest = rest.dropFirst(columns)
            }
            if !rest.isEmpty { out.append(String(rest)) }
            return out
        }.joined(separator: "\n")
    }

    /// One row's value for a named column, or `nil` when that column doesn't
    /// exist or that row is short. Never throws and never guesses.
    func value(_ column: String, in row: [String]) -> String? {
        guard let index = columns.firstIndex(of: column), index < row.count else { return nil }
        let v = row[index].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}

// MARK: - Typed resources

/// One row of the Pods table, joined with its `top pods` row when metrics are
/// available.
struct KubePod: Equatable {
    let name: String
    let ready: String
    let status: String
    let restarts: Int
    let age: String
    let node: String?
    /// From `kubectl top pods`, `nil` when metrics-server isn't installed -
    /// which is a normal cluster configuration, not a failure.
    var cpu: String?
    var memory: String?

    /// How this pod's row should read at a glance. Deliberately three states
    /// rather than mirroring every kubectl phase verbatim: a table's job is
    /// "is anything wrong here", and the exact phase is one `describe` click
    /// away.
    enum Health { case healthy, warning, bad }

    var health: Health {
        // `Completed`/`Succeeded` are terminal-and-fine (a finished Job pod),
        // and must not read as broken just because they aren't Running.
        let s = status.lowercased()
        if s == "running" || s == "completed" || s == "succeeded" {
            // Running but not all containers ready is a real, common
            // half-state worth flagging amber rather than green.
            if s == "running", let (r, t) = KubePod.parseReady(ready), r < t { return .warning }
            return .healthy
        }
        if s.contains("pending") || s.contains("containercreating") || s.contains("terminating") || s.contains("init:") {
            return .warning
        }
        return .bad
    }

    /// `"1/2"` -> `(1, 2)`. `nil` for anything else (a kubectl that renders
    /// READY differently), which callers treat as "unknown, don't flag".
    static func parseReady(_ ready: String) -> (Int, Int)? {
        let parts = ready.split(separator: "/")
        guard parts.count == 2, let r = Int(parts[0]), let t = Int(parts[1]) else { return nil }
        return (r, t)
    }
}

struct KubeDeployment: Equatable {
    let name: String
    let ready: String
    let upToDate: String
    let available: String
    let age: String

    /// A deployment is fine when READY's two halves match; anything else is
    /// mid-rollout or genuinely short of replicas. An unparseable READY is
    /// treated as healthy rather than flagged - a false alarm on every row is
    /// worse than no signal.
    var isFullyReady: Bool {
        guard let (r, t) = KubePod.parseReady(ready) else { return true }
        return r == t
    }
}

struct KubeService: Equatable {
    let name: String
    let type: String
    let clusterIP: String
    let externalIP: String?
    let ports: String
    let age: String
}

struct KubeEvent: Equatable {
    let lastSeen: String
    let type: String
    let reason: String
    let object: String
    let message: String

    var isWarning: Bool { type.lowercased() == "warning" }
}

// MARK: - Parsers

enum KubeResourceParser {

    /// Distinguishes the three outcomes a caller genuinely needs to tell
    /// apart, which a plain `[T]` cannot: rows, a legitimately empty
    /// namespace, and kubectl having failed. Collapsing the last two is
    /// GL-14's rule ("an empty list and a failed fetch must not render the
    /// same") applied here.
    enum Outcome<T> {
        case rows([T])
        case empty
        case failed(String)
    }

    /// kubectl prints this to stderr for an empty namespace; it reaches the
    /// terminal buffer alongside stdout, so it arrives inside the markers.
    private static func isNoResourcesMessage(_ raw: String) -> Bool {
        let t = raw.lowercased()
        return t.contains("no resources found")
    }

    private static func outcome<T>(raw: String, table: KubeTable?, build: (KubeTable) -> [T]) -> Outcome<T> {
        if isNoResourcesMessage(raw) { return .empty }
        guard let table else {
            let message = raw
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty })
            return .failed(message ?? "kubectl produced no output")
        }
        let rows = build(table)
        return rows.isEmpty ? .empty : .rows(rows)
    }

    /// `kubectl get pods -n <ns> -o wide`, optionally joined with
    /// `kubectl top pods -n <ns>` by pod name.
    ///
    /// `topRaw` is separate and optional on purpose: `top` legitimately fails
    /// on a cluster with no metrics-server, and that must degrade to "no
    /// cpu/mem columns", never to a failed pod list.
    static func parsePods(getRaw: String, topRaw: String? = nil) -> Outcome<KubePod> {
        let table = KubeTable(raw: getRaw)
        var result = outcome(raw: getRaw, table: table) { table -> [KubePod] in
            table.rows.compactMap { row in
                guard let name = table.value("NAME", in: row) else { return nil }
                return KubePod(
                    name: name,
                    ready: table.value("READY", in: row) ?? "-",
                    status: table.value("STATUS", in: row) ?? "Unknown",
                    // A modern kubectl renders restarts as `4 (2m ago)`, so
                    // take the leading integer rather than the whole field.
                    restarts: Int(table.value("RESTARTS", in: row)?.prefix(while: { $0.isNumber }) ?? "") ?? 0,
                    age: table.value("AGE", in: row) ?? "-",
                    node: table.value("NODE", in: row),
                    cpu: nil, memory: nil
                )
            }
        }
        if case .rows(var pods) = result, let topRaw, let metrics = parseTopPods(topRaw) {
            for i in pods.indices {
                if let m = metrics[pods[i].name] {
                    pods[i].cpu = m.cpu
                    pods[i].memory = m.memory
                }
            }
            result = .rows(pods)
        }
        return result
    }

    /// `kubectl top pods` -> `[podName: (cpu, memory)]`. `nil` when the
    /// output isn't a table at all (no metrics-server), which the caller
    /// treats as "no metrics", never as an error worth surfacing.
    static func parseTopPods(_ raw: String) -> [String: (cpu: String, memory: String)]? {
        guard let table = KubeTable(raw: raw) else { return nil }
        var out: [String: (cpu: String, memory: String)] = [:]
        for row in table.rows {
            guard let name = table.value("NAME", in: row) else { continue }
            let cpu = table.value("CPU(CORES)", in: row) ?? table.value("CPU", in: row) ?? "-"
            let mem = table.value("MEMORY(BYTES)", in: row) ?? table.value("MEMORY", in: row) ?? "-"
            out[name] = (cpu, mem)
        }
        return out.isEmpty ? nil : out
    }

    static func parseDeployments(_ raw: String) -> Outcome<KubeDeployment> {
        outcome(raw: raw, table: KubeTable(raw: raw)) { table in
            table.rows.compactMap { row in
                guard let name = table.value("NAME", in: row) else { return nil }
                return KubeDeployment(
                    name: name,
                    ready: table.value("READY", in: row) ?? "-",
                    upToDate: table.value("UP-TO-DATE", in: row) ?? "-",
                    available: table.value("AVAILABLE", in: row) ?? "-",
                    age: table.value("AGE", in: row) ?? "-"
                )
            }
        }
    }

    static func parseServices(_ raw: String) -> Outcome<KubeService> {
        outcome(raw: raw, table: KubeTable(raw: raw)) { table in
            table.rows.compactMap { row in
                guard let name = table.value("NAME", in: row) else { return nil }
                return KubeService(
                    name: name,
                    type: table.value("TYPE", in: row) ?? "-",
                    clusterIP: table.value("CLUSTER-IP", in: row) ?? "-",
                    externalIP: table.value("EXTERNAL-IP", in: row),
                    ports: table.value("PORT(S)", in: row) ?? "-",
                    age: table.value("AGE", in: row) ?? "-"
                )
            }
        }
    }

    /// `kubectl get namespaces` - the NAME column only (audit §6.7b).
    ///
    /// Every name is put through `KubeCommand.isSafeToken` here rather than at
    /// the point of use: a namespace this app would refuse to type is one it
    /// must not offer in a picker either, and dropping it at the parse
    /// boundary means the list handed to the UI is, by construction, entirely
    /// selectable. In practice `isSafeToken` already accepts every DNS-1123
    /// name Kubernetes itself permits, so this drops nothing real - it just
    /// means a picker can never present a dead entry.
    static func parseNamespaces(_ raw: String) -> Outcome<String> {
        outcome(raw: raw, table: KubeTable(raw: raw)) { table in
            table.rows.compactMap { row in
                guard let name = table.value("NAME", in: row),
                      KubeCommand.isSafeToken(name) else { return nil }
                return name
            }
        }
    }

    /// `kubectl get events --sort-by=.lastTimestamp`. `MESSAGE` is the
    /// trailing free-text column, so the table is parsed with
    /// `lastColumnIsFreeText` - without it, "Failed to pull image" would be
    /// split into three fields and the message truncated at the first word.
    static func parseEvents(_ raw: String) -> Outcome<KubeEvent> {
        let table = KubeTable(raw: raw, lastColumnIsFreeText: true)
        return outcome(raw: raw, table: table) { table in
            table.rows.compactMap { row in
                guard let type = table.value("TYPE", in: row) else { return nil }
                return KubeEvent(
                    lastSeen: table.value("LAST SEEN", in: row) ?? table.value("LASTSEEN", in: row) ?? "-",
                    type: type,
                    reason: table.value("REASON", in: row) ?? "-",
                    object: table.value("OBJECT", in: row) ?? "-",
                    message: table.value("MESSAGE", in: row) ?? ""
                )
            }
        }
    }
}
