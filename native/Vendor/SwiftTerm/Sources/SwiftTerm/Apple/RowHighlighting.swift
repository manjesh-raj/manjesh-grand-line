//
//  RowHighlighting.swift
//
// Grand Line patch 8: a colour-override hook used while a row is built for
// drawing. See `Vendor/SwiftTerm/README.md`'s "Eighth patch" section.
//
// In short: the app colours keywords ("error", "warning", an IP address) in
// terminal output the way Termius does, and there is no seam for it upstream.
// `buildAttributedString` and `getAttributes` are `internal`, `draw(_:)` is not
// `open`, and the only alternative - rewriting the byte stream with SGR codes
// before `feed` - would change the buffer, which copy, search, scrollback and
// every machine reader of this terminal (`getBufferAsData`) all read.
//
// So the hook sits at draw time and touches nothing but the attributed string
// a visible row is drawn from:
//
//  - It only runs for rows `draw(_:)` actually builds, which are the visible
//    ones, and only when patch 7's per-row render cache misses - so an
//    unchanged screen costs nothing, and a row is scanned again only when its
//    text changes.
//  - Results are memoised by the row's own text plus the highlighter's
//    `highlightVersion`. Once scrollback is full every frame rotates every
//    visible `BufferLine` reference, which defeats patch 7's identity check,
//    but the text of a row that moved up by one line is unchanged, so the scan
//    is not repeated.
//  - It skips the alternate screen (vim, htop, less), any cell a program
//    already coloured, and any row wider than `rowHighlightMaximumColumns`.
//  - It changes the foreground colour of a cell and nothing else. The buffer,
//    selection, copy, search and `getBufferAsData` never see it.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

#if os(macOS)
import AppKit
/// The colour a highlight paints its cells' foreground in.
public typealias TerminalHighlightColor = NSColor
#else
import UIKit
public typealias TerminalHighlightColor = UIColor
#endif

/// One coloured run in a row's text.
public struct TerminalRowHighlight: Equatable {
    /// UTF-16 offsets into the code units handed to
    /// `TerminalRowHighlighter.highlights(forRow:)`.
    public var range: Range<Int>
    public var color: TerminalHighlightColor

    public init(range: Range<Int>, color: TerminalHighlightColor) {
        self.range = range
        self.color = color
    }
}

/// What the view asks to colour a row. Owned by the app.
public protocol TerminalRowHighlighter: AnyObject {
    /// Whether highlighting is on at all. Read once per rebuilt row, so a
    /// highlighter that is switched off costs one call and nothing else.
    var highlightsEnabled: Bool { get }
    /// Changes whenever the rules or their colours change. Part of patch 7's
    /// cache key and of the memo's, so a new version repaints every row.
    var highlightVersion: UInt64 { get }
    /// The coloured runs in one row's text, given as UTF-16 code units with one
    /// or two units per cell (a wide character's second cell contributes
    /// nothing). Runs may overlap the program-coloured cells the view will
    /// drop, and must lie inside `0..<units.count`; anything else is ignored.
    func highlights(forRow units: [UInt16]) -> [TerminalRowHighlight]
}

extension TerminalView {
    /// Rows wider than this are never scanned. A row is at most `cols` wide,
    /// so this only bites a terminal pinned wide by patch 5's
    /// `minimumColumns`, whose output is machine-read rather than looked at.
    public static let rowHighlightMaximumColumns = 2_000

    /// How many distinct row texts the memo keeps before it starts over. A
    /// screen is ~50 rows, so this is many screens of history - enough for a
    /// scroll back and forth to hit - and small enough that clearing it is
    /// cheaper than tracking recency.
    static let rowHighlightMemoLimit = 2_048

    /// The version patch 7's cache entries are stamped with: the
    /// highlighter's own version while it is on, and `0` while it is off or
    /// absent, so switching it off repaints rows that were coloured.
    var effectiveRowHighlightVersion: UInt64 {
        guard let highlighter = rowHighlighter, highlighter.highlightsEnabled else { return 0 }
        return highlighter.highlightVersion
    }

    /// Per-column foreground overrides for one row, or `nil` when nothing in
    /// it is highlighted. Indexed by the column a cell starts at.
    func rowHighlightColors (line: BufferLine, cols: Int) -> [TerminalHighlightColor?]? {
        guard let highlighter = rowHighlighter,
              highlighter.highlightsEnabled,
              cols <= Self.rowHighlightMaximumColumns,
              !terminal.isCurrentBufferAlternate else {
            return nil
        }

        // The row's text, one entry per UTF-16 unit, with the column each unit
        // belongs to and whether that column is ours to colour.
        var units: [UInt16] = []
        units.reserveCapacity(cols)
        var unitColumns: [Int32] = []
        unitColumns.reserveCapacity(cols)
        var eligible = [Bool](repeating: false, count: cols)
        var anyEligibleText = false
        let quiet: CharacterStyle = [.inverse, .dim, .invisible]
        var col = 0
        while col < cols {
            let ch = line[col]
            let width = max(1, Int(ch.width))
            let attribute = ch.attribute
            // "A cell a program already coloured" is any cell whose colours or
            // emphasis the program chose. Only plain default-on-default text
            // is coloured here, so a coloured prompt, a diff or a TUI's chrome
            // keeps exactly what the program asked for.
            let plain = attribute.fg == .defaultColor
                && attribute.bg == .defaultColor
                && attribute.style.isDisjoint(with: quiet)
            eligible[col] = plain
            let code = ch.code
            if code > 0 && code < 0x80 {
                units.append(UInt16(code))
                unitColumns.append(Int32(col))
                if plain && code != 0x20 { anyEligibleText = true }
            } else if code == 0 {
                units.append(0x20)
                unitColumns.append(Int32(col))
            } else {
                for unit in String(terminal.getCharacter(for: ch)).utf16 {
                    units.append(unit)
                    unitColumns.append(Int32(col))
                }
                if plain { anyEligibleText = true }
            }
            col += width
        }
        guard anyEligibleText else { return nil }

        let version = highlighter.highlightVersion
        if rowHighlightMemoVersion != version {
            rowHighlightMemo.removeAll(keepingCapacity: true)
            rowHighlightMemoVersion = version
        }
        let runs: [TerminalRowHighlight]
        if let memoised = rowHighlightMemo[units] {
            runs = memoised
        } else {
            rowHighlightScans &+= 1
            runs = highlighter.highlights(forRow: units)
            if rowHighlightMemo.count >= Self.rowHighlightMemoLimit {
                rowHighlightMemo.removeAll(keepingCapacity: true)
            }
            rowHighlightMemo[units] = runs
        }
        guard !runs.isEmpty else { return nil }

        var colors = [TerminalHighlightColor?](repeating: nil, count: cols)
        var any = false
        for run in runs {
            guard run.range.lowerBound >= 0, run.range.upperBound <= units.count, !run.range.isEmpty else {
                continue
            }
            // A run that touches a program-coloured cell is dropped whole
            // rather than coloured in part: half a word in a second colour
            // reads as a rendering fault.
            var touchesProgramColour = false
            for unit in run.range where !eligible[Int(unitColumns[unit])] {
                touchesProgramColour = true
                break
            }
            if touchesProgramColour { continue }
            for unit in run.range {
                let column = Int(unitColumns[unit])
                if colors[column] == nil {
                    colors[column] = run.color
                    any = true
                }
            }
        }
        return any ? colors : nil
    }
}
#endif
