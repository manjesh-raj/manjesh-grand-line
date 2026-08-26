// Manjesh Grand Line - native macOS app.
//
// Line- and word-level diffing for the Tools page's Mergely-style diff tool
// (cockpit-tools-page-diff, phase 2 of 3 - see ToolsController.swift's
// header for the full phase history). This is a direct Swift re-derivation
// of the algorithm already validated in the captain-reviewed HTML mockup,
// not a port of its JS - classic dynamic-programming LCS over lines, then
// over whitespace-preserving word tokens for the lines inside a paired
// "changed" row. No third-party diff library: LCS is genuinely simple to
// hand-roll correctly at the line counts this tool deals with (manifests,
// config files - tens to low hundreds of lines), unlike the YAML tool's
// parser, which YamlBeautify.swift's header explains was correctly vendored
// instead of hand-rolled.
//
// Deliberately has no AppKit import - this file is pure logic, so its
// correctness (LCS grouping, word-level highlight spans) can be reasoned
// about and exercised independently of any view code.

import Foundation

enum DiffRowKind {
    case unchanged, added, removed, changed
}

/// One word-ish token from `DiffEngine.wordTokens`, tagged with whether it
/// differs from its counterpart on the other side of a `changed` row.
struct DiffToken {
    let text: String
    let changed: Bool
}

/// One aligned row of a side-by-side diff. `left`/`right` are `nil` for the
/// blank counterpart of a pure add/remove row. `changed` rows carry
/// word-level tokens for both sides; other kinds carry a single unchanged
/// token spanning the whole line (so rendering code has one shape to handle).
struct DiffRow {
    let kind: DiffRowKind
    let leftNumber: Int?
    let leftTokens: [DiffToken]?
    let rightNumber: Int?
    let rightTokens: [DiffToken]?
}

enum DiffEngine {

    // MARK: Line-level diff

    /// Computes an aligned, line-level diff of `before`/`after` via classic
    /// LCS, then groups consecutive delete/insert runs into paired `changed`
    /// rows (paired by index within the run), with any count mismatch
    /// rendered as pure add/remove against a blank counterpart.
    /// T3/T4: the ceiling on the LCS table.
    ///
    /// `lcsOps` builds a full `(n+1) x (m+1)` `Int` DP matrix, so two 5,000-line
    /// inputs is ~25M cells and seconds of work - and this ran synchronously on
    /// the main thread from both the Tools page's Diff tab and the Log
    /// Analyzer's Compare tab, on input the captain pastes. 4M cells is roughly
    /// 2,000 x 2,000 lines, which is far past any realistic manifest or config
    /// diff and still resolves in well under a second.
    static let maxLCSCells = 4_000_000

    /// The exact diff plus, when the input was too large to align exactly, a
    /// line saying so. **No silent caps**: a caller that shows a degraded diff
    /// has to be able to say it is degraded.
    struct Diff {
        let rows: [DiffRow]
        /// Non-nil when the alignment fell back to a positional comparison.
        let degradedNote: String?
    }

    static func lineDiff(before: String, after: String) -> [DiffRow] {
        checkedLineDiff(before: before, after: after).rows
    }

    static func checkedLineDiff(before: String, after: String) -> Diff {
        let a = before.components(separatedBy: "\n")
        let b = after.components(separatedBy: "\n")
        let (ops, degraded) = alignedOps(a, b)

        var rows: [DiffRow] = []
        var leftNum = 1
        var rightNum = 1
        var i = 0
        while i < ops.count {
            switch ops[i] {
            case .equal(let line):
                rows.append(DiffRow(
                    kind: .unchanged,
                    leftNumber: leftNum, leftTokens: [DiffToken(text: line, changed: false)],
                    rightNumber: rightNum, rightTokens: [DiffToken(text: line, changed: false)]
                ))
                leftNum += 1
                rightNum += 1
                i += 1
            case .delete, .insert:
                var deletes: [String] = []
                var inserts: [String] = []
                while i < ops.count {
                    if case .delete(let line) = ops[i] { deletes.append(line); i += 1 }
                    else if case .insert(let line) = ops[i] { inserts.append(line); i += 1 }
                    else { break }
                }
                let pairCount = min(deletes.count, inserts.count)
                for p in 0..<pairCount {
                    let (leftTokens, rightTokens) = wordDiff(deletes[p], inserts[p])
                    rows.append(DiffRow(
                        kind: .changed,
                        leftNumber: leftNum, leftTokens: leftTokens,
                        rightNumber: rightNum, rightTokens: rightTokens
                    ))
                    leftNum += 1
                    rightNum += 1
                }
                for d in deletes[pairCount...] {
                    rows.append(DiffRow(
                        kind: .removed,
                        leftNumber: leftNum, leftTokens: [DiffToken(text: d, changed: true)],
                        rightNumber: nil, rightTokens: nil
                    ))
                    leftNum += 1
                }
                for ins in inserts[pairCount...] {
                    rows.append(DiffRow(
                        kind: .added,
                        leftNumber: nil, leftTokens: nil,
                        rightNumber: rightNum, rightTokens: [DiffToken(text: ins, changed: true)]
                    ))
                    rightNum += 1
                }
            }
        }
        return Diff(rows: rows,
                    degradedNote: degraded
                        ? "These inputs are too large to align exactly (\(a.count) vs \(b.count) lines), so this comparison is line-by-line rather than a best-match alignment."
                        : nil)
    }

    /// Trims the common head and tail first - exact, cheap, and on real logs it
    /// removes most of the table - then either runs the exact LCS or, if the
    /// remaining middle is still past `maxLCSCells`, falls back to a positional
    /// comparison and says so.
    private static func alignedOps(_ a: [String], _ b: [String]) -> ([LineOp], Bool) {
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head,
              a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }

        let midA = Array(a[head..<(a.count - tail)])
        let midB = Array(b[head..<(b.count - tail)])

        var ops: [LineOp] = a[0..<head].map { .equal($0) }
        var degraded = false
        if (midA.count + 1) * (midB.count + 1) > maxLCSCells {
            degraded = true
            ops.append(contentsOf: positionalOps(midA, midB))
        } else {
            ops.append(contentsOf: lcsOps(midA, midB))
        }
        ops.append(contentsOf: a[(a.count - tail)...].map { .equal($0) })
        return (ops, degraded)
    }

    /// The fallback: pair line `i` with line `i`, and report the overhang.
    /// Not a best-match alignment, which is exactly what the degraded note
    /// tells the captain.
    private static func positionalOps(_ a: [String], _ b: [String]) -> [LineOp] {
        var ops: [LineOp] = []
        for i in 0..<Swift.max(a.count, b.count) {
            let left = i < a.count ? a[i] : nil
            let right = i < b.count ? b[i] : nil
            switch (left, right) {
            case let (l?, r?) where l == r: ops.append(.equal(l))
            case let (l?, r?): ops.append(.delete(l)); ops.append(.insert(r))
            case let (l?, nil): ops.append(.delete(l))
            case let (nil, r?): ops.append(.insert(r))
            case (nil, nil): break
            }
        }
        return ops
    }

    private enum LineOp {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    /// Backtracks a standard LCS table into an ordered edit script.
    private static func lcsOps(_ a: [String], _ b: [String]) -> [LineOp] {
        let n = a.count, m = b.count
        guard n > 0 || m > 0 else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var ops: [LineOp] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.equal(a[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.delete(a[i]))
                i += 1
            } else {
                ops.append(.insert(b[j]))
                j += 1
            }
        }
        while i < n { ops.append(.delete(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }

    // MARK: Word-level diff

    /// Splits a line into whitespace-preserving tokens (alternating runs of
    /// whitespace and non-whitespace) so re-joining the tokens reconstructs
    /// the line exactly - needed so word-level LCS can align "real" words
    /// without collapsing or losing the spacing between them.
    static func wordTokens(_ line: String) -> [String] {
        guard !line.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for ch in line {
            let isSpace = ch == " " || ch == "\t"
            if currentIsSpace == nil || currentIsSpace == isSpace {
                current.append(ch)
            } else {
                tokens.append(current)
                current = String(ch)
            }
            currentIsSpace = isSpace
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Word-level LCS between two lines, returning each side's tokens
    /// tagged with whether they survived as part of the common subsequence.
    static func wordDiff(_ leftLine: String, _ rightLine: String) -> ([DiffToken], [DiffToken]) {
        let a = wordTokens(leftLine)
        let b = wordTokens(rightLine)
        guard !a.isEmpty || !b.isEmpty else { return ([], []) }

        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var leftTokens: [DiffToken] = []
        var rightTokens: [DiffToken] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                leftTokens.append(DiffToken(text: a[i], changed: false))
                rightTokens.append(DiffToken(text: b[j], changed: false))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                leftTokens.append(DiffToken(text: a[i], changed: true))
                i += 1
            } else {
                rightTokens.append(DiffToken(text: b[j], changed: true))
                j += 1
            }
        }
        while i < n { leftTokens.append(DiffToken(text: a[i], changed: true)); i += 1 }
        while j < m { rightTokens.append(DiffToken(text: b[j], changed: true)); j += 1 }
        return (leftTokens, rightTokens)
    }
}
