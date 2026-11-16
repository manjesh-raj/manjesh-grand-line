// Grand Line - native macOS app.
//
// R5-BUG-08 (review #5): the child log caught `starship prompt
// --terminal-width=18` between widths 142 and 141. A Console shell was told
// its terminal was 18 columns wide and then put back, which costs the shell a
// prompt re-render and any TUI a full redraw. Nothing reproduces it from an
// agent shell, so this is a breadcrumb rather than a fix: a width change large
// enough to be that event logs the columns and the superview chain that sized
// the terminal, at debug level, so the next one names its own cause (a
// navigation transition, an inspector toggle, a destination re-pin or a split
// pane).
//
// The hook is the Console's `sizeChanged` delegate rather than SwiftTerm's own
// `TerminalView.sizeChanged`. The delegate fires on exactly the size changes
// that reach the shell as a SIGWINCH (SwiftTerm calls it right after
// `TIOCSWINSZ`), and it keeps the vendored tree free of an eleventh patch for
// a log line. To catch one:
//
//   log stream --level debug --predicate 'subsystem == "com.manjesh.grandline.native" AND category == "ui"' | grep terminal-resize

import AppKit

enum TerminalResizeTrace {

    /// A step is large when it moves the width by at least a third of the
    /// previous width and by at least 16 columns. 142 -> 18 is one. A live
    /// window drag, which moves a column or two per layout pass, never is.
    /// Opening a split halves a pane and does count, deliberately: it is the
    /// same signal from a known cause, and the chain says which it was.
    static func isLargeWidthStep(from old: Int, to new: Int) -> Bool {
        let delta = abs(new - old)
        return delta >= 16 && delta * 3 >= old
    }

    /// The terminal's ancestors, nearest first, each with its width, then the
    /// window's. The first ancestor that is suddenly narrow is the one whose
    /// layout pass sized the terminal.
    static func superviewChain(of view: NSView, limit: Int = 8) -> String {
        var parts: [String] = []
        var current = view.superview
        while let ancestor = current, parts.count < limit {
            parts.append("\(type(of: ancestor)) \(Int(ancestor.frame.width.rounded()))pt")
            current = ancestor.superview
        }
        if current != nil { parts.append("...") }
        let window = view.window.map { "window \(Int($0.frame.width.rounded()))pt" } ?? "no window"
        return (parts.isEmpty ? "no superview" : parts.joined(separator: " < ")) + " | " + window
    }

    /// The width each live terminal last reported. Weak keys, so a closed tab
    /// drops out without a teardown call. Touched on the main thread only,
    /// where AppKit lays the terminal out.
    private static let lastColumns = NSMapTable<NSView, NSNumber>.weakToStrongObjects()

    /// Called from `ConsoleController.sizeChanged(source:newCols:newRows:)`.
    /// Returns whether this change was logged, for the self-test.
    @discardableResult
    static func record(_ terminal: NSView, cols: Int, rows: Int) -> Bool {
        let previous = lastColumns.object(forKey: terminal)?.intValue
        lastColumns.setObject(NSNumber(value: cols), forKey: terminal)
        guard let previous, isLargeWidthStep(from: previous, to: cols) else { return false }
        let width = Int(terminal.frame.width.rounded())
        let chain = superviewChain(of: terminal)
        AppLog.ui.debug("terminal-resize: \(previous) -> \(cols) cols x \(rows) rows, terminal \(width)pt, \(chain, privacy: .public)")
        return true
    }
}
