//
//  Buffer.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/26/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

/**
 * The buffer represents the contents shown to the user.
 *
 * The buffer object contains both the lines that are shwon the user (including the scorllback) as well
 * as attributes like the cursor (x, y) position, the defined scroll region, the tab stops, the left and right margins and the scrolling delta.
 *
 * Some of the saved state information is also tracked here.
 */
public final class Buffer {
    private var _lines: CircularBufferLineList
    var xDisp, _yDisp, xBase: Int
    private var _x, _y, _yBase: Int
    private var _linesWithImagesCount: Int = 0
    
    // this keeps incrementing even as we run out of space in _lines and trim out
    // old lines.
    var linesTop: Int

    /// Monotonic count of lines that have been trimmed off the top of the
    /// scrollback since this buffer was created or reset. Increments by one
    /// each time output pushes a line out of a full scrollback buffer
    /// (`Terminal.scroll`); resets to zero on hard reset (RIS) and buffer
    /// (re)construction. Embedders can use this to anchor a scrolled-up
    /// viewport by absolute buffer line rather than pixel offset: at the
    /// scrollback cap the content height stays constant while rows shift,
    /// so a pixel-based anchor drifts by one row per trimmed line.
    public var totalLinesTrimmed: Int { linesTop }


    /// This is the index into the `lines` array that corresponds to the top row of displayed
    /// content in the terminal when the scroll is zero.   So the terminal contents that the application
    /// has access to are `lines [yBase..(yBase+rows)]`
    var yBase: Int {
        get { _yBase }
        set {
            if newValue > _lines.count {
//                #if DEBUG
//                abort ()
//                #else
//                return
//                #endif
            }
            _yBase = newValue
        }
    }
    /// This property tracks the first row in the `lines` array that will be displayed as the top row
    /// when scrolling takes place, this variable is updated to move the window of visible content
    public var yDisp: Int {
        get { return _yDisp }
        set {
            if _yDisp < 0 {
                #if DEBUG
                abort()
                #else
                return
                #endif
            }
            _yDisp = newValue
        }
    }
    /**
     * This is the cursor column 0-based, due to the way that the terminal must behave, buffer.x sometimes can
     * be beyond the boundary of the buffer, so it is important that any writes to a line with [buffer.x] first
     * does so by clamping the value to cols-1.
     *
     */
    public var x: Int {
        get { return _x }
        set(newValue) {
            if newValue < 0 {
                #if DEBUG
                abort()
                #else
                return
                #endif
            }
            _x = newValue
        }
    }
    
    /**
     * This is the cursor row 0-based
     */
    public var y: Int {
        get { return _y }
        set(newValue) {
            if newValue < 0 {
                #if DEBUG
                abort()
                #else
                return
                #endif
            }
            _y = newValue
        }
    }
    
    private var _scrollBottom: Int
    /**
     * This sets the bottom of the scrolling region in the buffer when Origin Mode is turned on
     */
    public var scrollBottom: Int {
        get { _scrollBottom }
        set {
            if newValue < 0 {
                #if DEBUG
                abort()
                #else
                return
                #endif
            }
            _scrollBottom = newValue
        }
    }
    
    var _scrollTop: Int

    /**
     * This sets the top scrolling region in the buffer when Origin Mode is turned on
     */
    public var scrollTop: Int {
        set(newValue) {
            if newValue >= 0 {
                _scrollTop = newValue
            }
        }
        get {
            return _scrollTop
        }
    }
    var tabStops: [Bool]
    
    /**
     * This records the saved X position
     */
    public var savedX: Int
    
    /**
     * This records the saved Y position
     */
    public var savedY: Int

    /// Saved state for the origin mode
    var savedOriginMode: Bool = false
    /// Saved state for the origin mode
    var savedMarginMode: Bool = false
    /// Saved state for the wrap around mode
    var savedWraparound: Bool = false
    /// Saved state for the reverse wrap around mode
    var savedReverseWraparound: Bool = false

    /**
     * The left margin, 0-indexed, used when marginMode is turned on
     */
    public var marginLeft: Int {
        get {
            _marginLeft
        }
        set {
            _marginLeft = newValue
        }
    }
    private var _marginLeft: Int = 0

    /**
     * The right margin, 0-indexed, used when marginMode is turned on
     */
    public var marginRight: Int {
        get {
            _marginRight
        }
        set {
            _marginRight = newValue
        }
    }
    private var _marginRight: Int = 0
    
    /**
     * This represents the saved attributed
     */
    public var savedAttr = CharData.defaultAttr
    
    /**
     * This tracks the current charset
     */
    public var savedCharset: [UInt8:String]? = nil
    
    var hasScrollback : Bool
    var cols: Int {
        get { _cols }
        set { _cols = newValue }
    }
    var rows: Int {
        get { _rows }
        set { _rows = newValue }
    }
    private var _cols: Int
    private var _rows: Int
    
    var scrollback: Int?
    
    var lines : CircularBufferLineList {
        get { return _lines }
    }

    /// Returns true if any lines in this buffer have images attached
    public var hasAnyImages: Bool {
        return _linesWithImagesCount > 0
    }

    /// Attaches an image to the line at the given index, tracking the count of lines with images
    func attachImage(_ image: TerminalImage, toLineAt index: Int) {
        let line = lines[index]
        let hadImages = line.images != nil
        line.attach(image: image)
        if !hadImages {
            _linesWithImagesCount += 1
        }
    }

    /// Clears images from the line at the given index, tracking the count of lines with images
    func clearImagesFromLine(at index: Int) {
        let line = lines[index]
        if line.images != nil {
            _linesWithImagesCount -= 1
            line.images = nil
        }
    }

    /// Recalculates the count of lines with images (used after reflow operations)
    func recalculateLinesWithImagesCount() {
        var count = 0
        for i in 0..<lines.count {
            if lines[i].images != nil {
                count += 1
            }
        }
        _linesWithImagesCount = count
    }

    private func setupLinesCallbacks() {
        _lines.onLineRecycled = { [weak self] hadImages in
            if hadImages {
                self?._linesWithImagesCount -= 1
            }
        }
        _lines.onLinePushed = { [weak self] hasImages in
            if hasImages {
                self?._linesWithImagesCount += 1
            }
        }
    }
    
    private var curAttr: Attribute = Attribute.empty
    private var insertMode: Bool = false
    private var marginMode: Bool = false
    private var wraparound: Bool = false
    var scroll: (_ isWrapped: Bool)->() = { x in
        fatalError("This should be set after creating a buffer")
    }
    
    func setInsertMode(_ value: Bool) {
        self.insertMode = value
    }

    func setMarginMode(_ value: Bool) {
        self.marginMode = value
    }

    func setWraparound(_ value: Bool) {
        self.wraparound = value
    }

    public init (cols: Int, rows: Int, tabStopWidth: Int, scrollback: Int?) {
        self.hasScrollback = scrollback != nil
        _yDisp = 0
        xDisp = 0
        _yBase = 0
        tabStops = [Bool]()
        savedX = 0
        savedY = 0
        xBase = 0
        _scrollTop = 0
        _scrollBottom = rows - 1
        _marginLeft = 0
        _marginRight = cols - 1
        linesTop = 0
        _x = 0
        _y = 0
        self._cols = cols
        self._rows = rows
        self.scrollback = scrollback
        
        let len = hasScrollback ? (scrollback ?? 0) + rows : rows
        _lines = CircularBufferLineList (maxLength: len)
        _lines.makeEmpty = { [unowned self] line in getBlankLine(attribute: CharData.defaultAttr, isWrapped: false) }
        setupLinesCallbacks()
        setupTabStops (tabStopWidth: tabStopWidth)
    }
        
    public func getCorrectBufferLength (_ rows: Int) -> Int
    {
        if hasScrollback {
            let correct = rows + (scrollback ?? 0)
            return correct > Int32.max ? Int (Int32.max) : correct
        } else {
            return rows
        }
    }
    
    public func getNullCell (attribute: Attribute? = nil) -> CharData
    {
        let fgbg = attribute == nil ? Attribute.empty : attribute!.justColor ()
        return CharData(attribute: fgbg, scalar: UnicodeScalar(32)!, size: 1)
    }
    
    public func getBlankLine (attribute: Attribute, isWrapped: Bool = false) -> BufferLine
    {
        let cd = CharData (attribute: attribute)
        
        return BufferLine(cols: cols, fillData: cd, isWrapped: isWrapped)
    }
    
    func makeEmptyLine (_ line: Int) -> BufferLine
    {
        return getBlankLine(attribute: CharData.defaultAttr, isWrapped: false)
    }
    
    /**
     * Returns the CharData at the specified position, the screen coordinate is what the user
     * sees.
     */
    public func getChar (at: Position) -> CharData
    {
        let bufferRow = lines [at.row+_yDisp]
        let col = at.col
        if col >= bufferRow.count || col < 0 {
            return CharData.Null
        }
        return bufferRow [at.col]
    }

    public func getChar (atBufferRelative: Position) -> CharData
    {
        let bufferRow = lines [atBufferRelative.row]
        let col = atBufferRelative.col
        if col >= bufferRow.count || col < 0 {
            return CharData.Null
        }
        return bufferRow [atBufferRelative.col]
    }

    public func clear ()
    {
        yDisp = 0
        yBase = 0
        xBase = 0
        linesTop = 0
        x = 0
        y = 0

        _lines = CircularBufferLineList (maxLength: getCorrectBufferLength(rows))
        _lines.makeEmpty = { [unowned self] line in getBlankLine(attribute: CharData.defaultAttr, isWrapped: false) }
        setupLinesCallbacks()
        _linesWithImagesCount = 0
        scrollTop = 0
        scrollBottom = rows - 1
        marginLeft = 0
        marginRight = cols - 1

        // Figure out how to do this elegantly
        // SetupTabStops ()
    }
    
    public func softReset ()
    {
        savedAttr = CharData.defaultAttr
        savedY = 0
        savedX = 0
        savedCharset = CharSets.defaultCharset
        marginRight = cols-1
        marginLeft = 0
        savedWraparound = false
        savedOriginMode = false
        savedMarginMode = false
        savedReverseWraparound = false
    }
    
    public var isCursorInViewPort : Bool {
        get {
            let absoluteY = yBase + yDisp
            let relativeY = absoluteY + yDisp
            return relativeY >= 0 && relativeY < rows
        }
    }
    
    public func fillViewportRows (attribute : Attribute? = nil)
    {
        // TODO: limitation in original, this does not cope with partial fills, it is either zero or nothing
        if _lines.count != 0 {
            return
        }
        let attr = attribute != nil ? attribute! : CharData.defaultAttr
        for _ in 0..<rows {
            _lines.push (getBlankLine (attribute: attr))
        }
    }
    
    public var isReflowEnabled: Bool {
        return hasScrollback
    }
    
    /// Grand Line patch 9: `keepCursorLine` is upstream's behaviour for the
    /// line the cursor is on - left unreflowed, and cut to the new width -
    /// which is only right when the program will redraw that line itself (a
    /// shell's line editor at its prompt). See `Terminal.cursorLineRedrawnOnResize`.
    public func resize (newCols : Int, newRows : Int, keepCursorLine: Bool = false)
    {
        // Grand Line patch 9: the cursor column before the clamp below, which
        // the narrowing reflow needs to keep the cursor on its own character.
        let cursorXBeforeResize = x
        if marginRight > newCols - 1 {
            marginRight = newCols - 1
        }
        if marginLeft >= marginRight {
            marginLeft = marginRight
        }
        let newMaxLength = getCorrectBufferLength(newRows)
        if newMaxLength > lines.maxLength {
            lines.maxLength = newMaxLength
        }
        if lines.count > 0 {
            // Deal with columns increasing (reducing needs to happen after reflow)
            
            if cols < newCols {
                // Iterate only the lines that exist: touching every capacity slot
                // materializes a BufferLine per empty slot (the CircularList subscript
                // calls makeEmpty), making resize O(scrollback capacity). Empty slots
                // are created on demand at the buffer's current cols, so they never
                // need resizing here.
                for i in 0..<lines.count {
                    lines [i].resize (cols: newCols, fillData: CharData.Null)
                }

            }

            // Resize rows in both directions as needed
            var addToY = 0
            if rows < newRows {
                for y in rows..<newRows {
                    if lines.count < newRows + yBase {
                        if yBase > 0 && lines.count <= yBase + y + addToY + 1 {
                            // There is room above the buffer and there are no empty elements below the line,
                            // scroll up
                            yBase -= 1
                            addToY += 1
                            if yDisp > 0 {
                                // Viewport is at the top of the buffer, must increase downwards
                                yDisp -= 1
                            }
                        } else {
                            // Add a blank line if there is no buffer left at the top to scroll to, or if there
                            // are blank lines after the cursor
                            lines.push (BufferLine (cols: newCols, fillData: CharData.Null))
                        }
                    }
                }
            } else { // (this._rows >= newRows)
                for _ in (newRows..<rows).reversed () {
                    if lines.count > newRows + yBase {
                        if lines.count > yBase + self.y + 1 {
                            // The line is a blank line below the cursor, remove it
                            lines.pop ()
                        } else {
                            // The line is the cursor, scroll down
                            yBase += 1
                            yDisp += 1
                        }
                    }
                }
            }

            // Reduce max length if needed after adjustments, this is done after as it
            // would otherwise cut data from the bottom of the buffer.
            if newMaxLength < lines.maxLength {
                // Trim from the top of the buffer and adjust ybase and ydisp.
                let amountToTrim = lines.count - newMaxLength
                if amountToTrim > 0 {
                    lines.trimStart(count: amountToTrim)
                    yBase = max (yBase - amountToTrim, 0)
                    yDisp = max (yDisp - amountToTrim, 0)
                    savedY = max (savedY - amountToTrim, 0)
                }

                lines.maxLength = newMaxLength
            }

            // Make sure that the cursor stays on screen
            // Grand Line patch 9: only when the width changes. A cursor one
            // past the last column is a pending wrap, and a height-only resize
            // that clamped it made the next character overwrite the last one.
            if newCols != cols {
                x = min (x, newCols - 1)
            }
            y = min (y, newRows - 1)
            if addToY != 0 {
                y += addToY
            }

            savedX = min (savedX, newCols - 1)

            scrollTop = 0
        }
        scrollBottom = newRows - 1
        if tabStops.count > newCols {
            tabStops.removeSubrange (newCols..<tabStops.count-1)
        } else {
            let n = newCols - tabStops.count
            for _ in 0..<n {
                tabStops.append (false)
            }
        }
        
        if isReflowEnabled {
            reflow (newCols, newRows, cursorX: cursorXBeforeResize, keepCursorLine: keepCursorLine)
            // Trim the end of the line off if cols shrunk
            if cols > newCols {
                // lines.count, not lines.maxLength (see the widen loop above).
                for i in 0..<lines.count {
                    lines [i].resize (cols: newCols, fillData: CharData.Null)
                }
            }
        }
        
        // DEBUG: Post-condition
        if lines.count > 0 {
            // lines.count, not lines.maxLength: checking every capacity slot would
            // materialize blank lines for the whole scrollback on every resize and,
            // worse, they would be created at the old `cols` (updated below) and
            // trip the abort() when widening.
            for i in 0..<lines.count {
                let line = lines [i]
                if line.count < newCols {
                    print ("stop here newCols=\(newCols) but the element has: \(line.count)")
                    abort ()
                }
            }
        }
        rows = newRows
        cols = newCols
    }
    
    public func changeHistorySize (_ newScrollback: Int?)
    {
        self.scrollback = newScrollback
        self.hasScrollback = newScrollback != nil
        
        let newMaxLength = getCorrectBufferLength(rows)
        let oldMaxLength = lines.maxLength
        
        if newMaxLength != oldMaxLength {
            if newMaxLength > oldMaxLength {
                // Increase buffer size - just update maxLength
                lines.maxLength = newMaxLength
            } else {
                // Decrease buffer size - need to trim and adjust
                let amountToTrim = lines.count - newMaxLength
                if amountToTrim > 0 {
                    lines.trimStart(count: amountToTrim)
                    yBase = max(yBase - amountToTrim, 0)
                    yDisp = max(yDisp - amountToTrim, 0)
                    savedY = max(savedY - amountToTrim, 0)
                }
                lines.maxLength = newMaxLength
            }
        }
    }
    
    func translateBufferLineToString (lineIndex: Int, trimRight: Bool, startCol: Int = 0, endCol: Int = -1, skipNullCellsFollowingWide: Bool = false, characterProvider: ((CharData) -> Character)? = nil) -> String
    {
        let line = _lines [lineIndex]
        return line.translateToString(trimRight: trimRight, startCol: startCol, endCol: endCol, skipNullCellsFollowingWide: skipNullCellsFollowingWide, characterProvider: characterProvider)
    }
    
    func setupTabStops (index: Int = -1, tabStopWidth: Int)
    {
        var idx = index
        
        if idx != -1 {
            if tabStops.count > cols {
                tabStops.removeSubrange(cols...)
            } else {
                for _ in cols..<tabStops.count {
                    tabStops.append(false)
                }
            }
            let from = min (index, cols - 1)
            if !tabStops [from] {
                idx = previousTabStop (from)
            }
        } else {
            tabStops = Array.init (repeating: false, count: cols)
            idx = 0
        }
        for i in stride(from: idx, to: cols, by: tabStopWidth) {
            tabStops [i] = true
        }
    }
    
    func tabSet (pos : Int)
    {
        if pos < tabStops.count {
            tabStops [pos] = true
        }
    }
    
    func tabClear (pos : Int)
    {
        if pos < tabStops.count {
            tabStops [pos] = false
        }
    }
    
    func clearTabStops ()
    {
        tabStops = Array.init (repeating: false, count: tabStops.count)
    }
    
    func previousTabStop (_ index : Int = -1) -> Int
    {
        var idx = index == -1 ? x : index
        while idx > 0 && !tabStops [idx-1] {
            idx = idx - 1
        }
        if idx > 0 {
            idx -= 1
        }
        return idx >= cols ? cols - 1 : idx
    }
    
    func nextTabStop (marginMode: Bool, _ index : Int = -1) -> Int
    {
        // Users marginMode because apparently for tabs, there is no need to have originMode set
        let limit = marginMode ? marginRight : (cols-1)
        var idx = index == -1 ? x : index
        
        repeat {
            idx = idx + 1
            if idx > limit {
                break
            }
            if tabStops [idx] {
                break
            }
        } while idx < limit
        return idx >= limit ? limit : idx
    }
    
    func getWrappedLineTrimmedLength (_ lines: CircularBufferLineList, _ row: Int, _ cols: Int) -> Int
    {
        return getWrappedLineTrimmedLength (lines [row], row == lines.count - 1 ? nil : lines [row + 1], cols)
    }

    func getWrappedLineTrimmedLength (_ lines: [BufferLine], _ row: Int, _ cols: Int) -> Int
    {
        return getWrappedLineTrimmedLength (lines [row], row == lines.count - 1 ? nil : lines [row+1], cols)
    }

    func getWrappedLineTrimmedLength (_ line: BufferLine, _ nextLine: BufferLine?, _ cols: Int) -> Int
    {
        // If this is the last row in the wrapped line, get the actual trimmed length
        if nextLine == nil {
            return line.getTrimmedLength ()
        }

        // Detect whether the following line starts with a wide character and the end of the current line
        // is null, if so then we can be pretty sure the null character should be excluded from the line
        // length]
        let endsInNull = !(line.hasContent (index: cols - 1)) && line.getWidth (index: cols - 1) == 1
        let followingLineStartsWithWide = nextLine?.getWidth (index: 0) == 2

        if endsInNull && followingLineStartsWithWide {
            return cols - 1
        }

        return cols
    }

    /// Grand Line patch 9: where the widening reflow put the cursor's
    /// character - the absolute row it now sits on, counted before any row
    /// is removed, and its column.
    struct ReflowedCursor {
        var row: Int
        var col: Int
    }

    func getLinesToRemove (oldCols: Int, newCols: Int, bufferAbsoluteY: Int, cursorX: Int, keepCursorLine: Bool, nullChar: CharData) -> (toRemove: [Int], cursor: ReflowedCursor?)
    {
        // Gather all BufferLines that need to be removed from the Buffer here so that they can be
        // batched up and only committed once
        var toRemove : [Int] = []
        var reflowedCursor: ReflowedCursor?

        var y = 0
        while y < lines.count-1 {
            defer { y = y + 1}
            // Check if this row is wrapped
            var i = y
            i = i + 1
            var nextLine = lines [i]
            if !nextLine.isWrapped {
                continue
            }

            // Check how many lines it's wrapped for
            var wrappedLines : [BufferLine] = []
            wrappedLines.append (lines [y])
            while i < lines.count && nextLine.isWrapped {
                wrappedLines.append (nextLine)
                i += 1
                nextLine = lines [i]
            }

            // Grand Line patch 9: the cursor's own line is merged like every
            // other line, and the cursor follows its character. Upstream
            // skipped it, which left the line split at the old width with
            // nulls in the middle of its first row - a later narrowing then
            // reflowed those nulls as spaces into the middle of the text.
            // See `reflowNarrower` for the other half of this.
            var cursorRow: Int? = nil
            var cursorCol = 0
            if bufferAbsoluteY >= y && bufferAbsoluteY < i {
                if keepCursorLine {
                    y += wrappedLines.count - 1
                    continue
                }
                cursorRow = bufferAbsoluteY - y
                cursorCol = cursorX
            }
            // Column 0 of the line's last wrapped row: a carriage return, kept
            // at the start of the merged line's last row (see `reflowNarrower`).
            let cursorAfterCarriageReturn = cursorX == 0 && cursorRow == wrappedLines.count - 1
            // The cursor can sit past the trimmed text of the last row; those
            // cells move with it, so the cursor keeps a cell to land on.
            func srcRowLength (_ row: Int) -> Int {
                let trimmed = getWrappedLineTrimmedLength (wrappedLines, row, oldCols)
                if row == wrappedLines.count - 1, row == cursorRow {
                    return max (trimmed, min (cursorCol, oldCols))
                }
                return trimmed
            }
            if let row = cursorRow {
                cursorCol = min (cursorCol, srcRowLength (row))
                // A cursor parked after the last cell of a full row stands
                // before the first cell of the next one.
                if row < wrappedLines.count - 1, cursorCol >= srcRowLength (row) {
                    cursorRow = row + 1
                    cursorCol = 0
                }
            }
            var cursorTarget: (row: Int, col: Int)? = cursorRow == 0 ? (0, cursorCol) : nil

            // Copy buffer data to new locations
            var destLineIndex = 0
            // Grand Line patch 9: upstream read `lines` here, which measures
            // the buffer's row 0 rather than this line's first row.
            var destCol = getWrappedLineTrimmedLength (wrappedLines, destLineIndex, oldCols)
            var srcLineIndex = 1
            var srcCol = 0
            while srcLineIndex < wrappedLines.count {
                let srcTrimmedTineLength = srcRowLength (srcLineIndex)
                let srcRemainingCells = srcTrimmedTineLength - srcCol
                let destRemainingCells = newCols - destCol
                let cellsToCopy = min (srcRemainingCells, destRemainingCells)

                if srcLineIndex == cursorRow, cursorCol >= srcCol, cursorCol < srcCol + cellsToCopy {
                    cursorTarget = (destLineIndex, destCol + cursorCol - srcCol)
                }

                if destLineIndex < wrappedLines.count {
                    wrappedLines [destLineIndex].copyFrom (wrappedLines [srcLineIndex], srcCol: srcCol,
                                                           dstCol: destCol, len: cellsToCopy)
                }

                destCol += cellsToCopy;
                if destCol == newCols {
                    destLineIndex += 1
                    destCol = 0;
                }

                srcCol += cellsToCopy;
                if srcCol == srcTrimmedTineLength {
                    srcLineIndex += 1
                    srcCol = 0;
                }

                // Make sure the last cell isn't wide, if it is copy it to the current dest
                if destCol == 0 && destLineIndex != 0 {
                    if wrappedLines [destLineIndex - 1].getWidth(index: newCols - 1) == 2 {
                        wrappedLines [destLineIndex].copyFrom (wrappedLines [destLineIndex - 1], srcCol: newCols - 1, dstCol: destCol, len: 1)
                        destCol += 1
                        // Null out the end of the last row
                        wrappedLines [destLineIndex - 1].replaceCells (start: newCols - 1, end: newCols, fillData: nullChar)
                    }
                }
            }

            // Clear out remaining cells or fragments could remain;
            wrappedLines [destLineIndex].replaceCells (start: destCol, end: newCols, fillData: nullChar)

            if cursorAfterCarriageReturn {
                cursorTarget = destCol == 0 && destLineIndex > 0 ? (destLineIndex - 1, 0) : (destLineIndex, 0)
            } else if cursorRow != nil, cursorTarget == nil {
                // The cursor stood after the last character: it goes after
                // the last cell copied, as a pending wrap when that filled a row.
                cursorTarget = destCol == 0 && destLineIndex > 0 ? (destLineIndex - 1, newCols) : (destLineIndex, destCol)
            }

            // Work backwards and remove any rows at the end that only contain null cells
            var countToRemove = 0
            var ix = wrappedLines.count-1
            
            while ix > 0 {
                defer { ix = ix - 1 }
                if let cursorTarget, ix <= cursorTarget.row {
                    break
                }
                if ix > destLineIndex || wrappedLines [ix].getTrimmedLength () == 0 {
                    countToRemove += 1
                } else {
                    break
                }
            }

            if countToRemove > 0 {
                toRemove.append (y + wrappedLines.count - countToRemove) // index
                toRemove.append (countToRemove)
            }
            if let cursorTarget {
                reflowedCursor = ReflowedCursor (row: y + cursorTarget.row, col: cursorTarget.col)
            }

            y += wrappedLines.count - 1
        }

        return (toRemove, reflowedCursor)
    }
    
    func reflowWider (_ oldCols: Int, _ oldRows: Int, _ newCols: Int, _ newRows: Int, cursorX: Int, keepCursorLine: Bool)
    {
        let cursorAbsoluteRow = yBase + y
        let (toRemove, reflowedCursor) = getLinesToRemove(oldCols: oldCols, newCols: newCols, bufferAbsoluteY: cursorAbsoluteRow, cursorX: cursorX, keepCursorLine: keepCursorLine, nullChar: CharData.Null)
        
        //print ("Lines to remove: \(toRemove) \(toRemove.count)")
        if toRemove.count > 0 {
            // Create new layout
            let layout = CircularList<Int> (maxLength: lines.count)
            layout.makeEmpty = { line in 0 }

            // First iterate through the list and get the actual indexes to use for rows
            var nextToRemoveIndex = 0
            var nextToRemoveStart = toRemove [nextToRemoveIndex]
            var countRemovedSoFar = 0

            var i = 0
            while i < lines.count {
                if nextToRemoveStart == i {
                    nextToRemoveIndex += 1
                    let countToRemove = toRemove [nextToRemoveIndex]

                    i += countToRemove - 1
                    countRemovedSoFar += countToRemove

                    nextToRemoveStart = Int.max
                    if nextToRemoveIndex < toRemove.count - 1 {
                        nextToRemoveIndex += 1
                        nextToRemoveStart = toRemove [nextToRemoveIndex]
                    }
                } else {
                    layout.push (i)
                }
                i += 1
            }

            // Apply the new layout
            let newLayoutLines = CircularBufferLineList (maxLength: lines.count)
            newLayoutLines.makeEmpty = { [unowned self] line in getBlankLine(attribute: CharData.defaultAttr, isWrapped: false) }
            for i in 0..<layout.count {
                  newLayoutLines.push (lines [layout [i]])
            }
                  
            // Rearrange the list
            for i in 0..<newLayoutLines.count {
                  lines [i] = newLayoutLines [i]
            }
            lines.count = layout.count
            
            // adjust viewport
            var viewportAdjustments = countRemovedSoFar
            while viewportAdjustments > 0 {
                viewportAdjustments -= 1
                if yBase == 0 {
                    if y > 0 {
                        y -= 1
                    }
    
                    if lines.count < newRows {
                        // Add an extra row at the bottom of the viewport
                        lines.push (BufferLine (cols: newCols, fillData: CharData.Null))
                    }
                } else {
                    if yDisp == yBase {
                        yDisp -= 1
                    }
                    yBase -= 1
                }
            }
            savedY = max (savedY - countRemovedSoFar, 0)
        }

        // Grand Line patch 9: the adjustment above moves the cursor up by
        // every removed row, as if all of them were above it - and stops at
        // row 0. The cursor's own line lost rows below it too, so place it
        // from where its character now is: its row, less the rows removed
        // above it, less the top of the screen.
        if let reflowedCursor {
            var removedAbove = 0
            var pair = 0
            while pair + 1 < toRemove.count {
                if toRemove [pair] < reflowedCursor.row {
                    removedAbove += toRemove [pair + 1]
                }
                pair += 2
            }
            y = min (max (0, reflowedCursor.row - removedAbove - yBase), newRows - 1)
            x = reflowedCursor.col
        }
    }
    
    // Gets the new line lengths for a given wrapped line. The purpose of this function it to pre-
    // compute the wrapping points since wide characters may need to be wrapped onto the following line.
    // This function will return an array of numbers of where each line wraps to, the resulting array
    // will only contain the values `newCols` (when the line does not end with a wide character) and
    // `newCols - 1` (when the line does end with a wide character), except for the last value which
    // will contain the remaining items to fill the line.
    // Calling this with a `newCols` value of `1` will lock up.
    // Grand Line patch 9: `lastLineLength` lets the narrowing reflow count the
    // cursor's own cells on the group's last row, which the cell copy then
    // moves with the text. nil keeps upstream's trimmed length.
    func getNewLineLengths (wrappedLines: [BufferLine] , oldCols: Int, newCols: Int, lastLineLength: Int? = nil) -> [Int]
    {
        var newLineLengths : [Int] = []

        func trimmedLength (_ row: Int) -> Int {
            if row == wrappedLines.count - 1, let lastLineLength {
                return lastLineLength
            }
            return getWrappedLineTrimmedLength (wrappedLines, row, oldCols)
        }

        var cellsNeeded = 0
        for i in 0..<wrappedLines.count {
               cellsNeeded += trimmedLength (i)
        }

        // Use srcCol and srcLine to find the new wrapping point, use that to get the cellsAvailable and
        // linesNeeded
        var srcCol = 0;
        var srcLine = 0;
        var cellsAvailable = 0;
        while cellsAvailable < cellsNeeded {
               if cellsNeeded - cellsAvailable < newCols {
                       // Add the final line and exit the loop
                       newLineLengths.append (cellsNeeded - cellsAvailable)
                       break;
               }

               srcCol += newCols
               let oldTrimmedLength = trimmedLength (srcLine)
               if srcCol > oldTrimmedLength {
                       srcCol -= oldTrimmedLength
                       srcLine += 1
               }

               let endsWithWide = srcLine < wrappedLines.count &&
                                  wrappedLines [srcLine].getWidth(index: srcCol - 1) == 2
               if endsWithWide {
                       srcCol -= 1
               }

               let lineLength = endsWithWide ? newCols - 1 : newCols
               newLineLengths.append (lineLength)
               cellsAvailable += lineLength
        }

        return newLineLengths
    }

    struct InsertionSet {
        var lines: [BufferLine]
        var start: Int
        var isNull: Bool
        public static func Null () -> InsertionSet { InsertionSet (lines: [], start: 0, isNull: true) }
    }
    
    func reflowNarrower (_ oldCols: Int, _ oldRows: Int, _ newCols: Int, _ newRows: Int, cursorX: Int, keepCursorLine: Bool)
    {
        // Gather all BufferLines that need to be inserted into the Buffer here so that they can be
        // batched up and only committed once
        var toInsert : [InsertionSet] = []
        var countToInsert = 0
        // Grand Line patch 9: the cursor's row in the same, pre-insertion
        // numbering `y` walks - the adjustments below move `yBase`/`self.y`.
        let cursorAbsoluteRow = yBase + self.y
        // Grand Line patch 9: rows of the cursor's own line below the cursor -
        // the ones it already had and the ones this reflow adds - which
        // upstream's "everything below the cursor is blank" rule must not pop.
        var contentRowsBelowCursor = 0

        // Go backwards as many lines may be trimmed and this will avoid considering them
        var y = lines.count-1
        while y >= 0 {
            defer { y -= 1 }
            // Check whether this line is a problem or not, if not skip it
            var nextLine = lines [y]
            let lineLength = nextLine.getTrimmedLength ()
            // Grand Line patch 9: a cursor past the new last column still needs
            // its row reflowed, even when the text fits - `resize` clamps it
            // onto the last character otherwise, and the next one overwrites it.
            let cursorNeedsRoom = !keepCursorLine && y == cursorAbsoluteRow && cursorX >= newCols
            if !nextLine.isWrapped && lineLength <= newCols && !cursorNeedsRoom {
                continue
            }

            // Gather wrapped lines and adjust y to be the starting line
            var wrappedLines : [BufferLine] = []
            wrappedLines.append (nextLine)
            while nextLine.isWrapped && y > 0 {
                y -= 1
                nextLine = lines [y]
                wrappedLines.insert (nextLine, at: 0)
            }

            // Grand Line patch 9: the cursor's own line is reflowed like every
            // other line. Upstream skipped it ("the program will handle fixing
            // up wrapped lines with the cursor"), and `resize` then cut every
            // line to `newCols` - so the skipped line lost every cell past the
            // new width for good. A shell redraws its prompt line, but output
            // that was still arriving (the cursor resting at the end of a long
            // line) does not, and widening again brought those cells back as
            // nulls that a copy trims away: the middle of the line vanished
            // from the clipboard (`fm/grandline-selection-copy-corruption-1794208740`).
            let cursorRow: Int? = cursorAbsoluteRow >= y && cursorAbsoluteRow < y + wrappedLines.count ? cursorAbsoluteRow - y : nil
            if keepCursorLine, cursorRow != nil {
                continue
            }

            var lastLineLength = wrappedLines [wrappedLines.count - 1].getTrimmedLength ()
            if let cursorRow, cursorRow == wrappedLines.count - 1 {
                // The cursor can sit past the trimmed text (after a typed
                // space, or one cell past the last character). Count those
                // cells, so the cursor has a cell to land on and the copy
                // below keeps every character in place.
                lastLineLength = max (lastLineLength, min (cursorX, oldCols))
            }
            let destLineLengths = getNewLineLengths (wrappedLines: wrappedLines, oldCols: oldCols, newCols: newCols, lastLineLength: lastLineLength)
            if destLineLengths.count == 0 {
                continue
            }

            // Where the cursor lands, as a row within this group and a column,
            // found by its distance from the group's first cell.
            var cursorTarget: (row: Int, col: Int)?
            if let cursorRow {
                var offset = 0
                for i in 0..<cursorRow {
                    offset += getWrappedLineTrimmedLength (wrappedLines, i, oldCols)
                }
                let rowLength = cursorRow == wrappedLines.count - 1 ? lastLineLength : getWrappedLineTrimmedLength (wrappedLines, cursorRow, oldCols)
                offset += min (cursorX, rowLength)
                var row = 0
                while row < destLineLengths.count - 1 && offset >= destLineLengths [row] {
                    offset -= destLineLengths [row]
                    row += 1
                }
                cursorTarget = (row, offset)
                if cursorX == 0, cursorRow == wrappedLines.count - 1 {
                    // Column 0 of a line's last row is where a carriage return
                    // leaves the cursor - typically the CR of a CR LF whose LF
                    // has not arrived yet. It means "the start of the line's
                    // last row", not "on the character there": mapped by
                    // offset, the LF would land on this line's own new
                    // continuation row, or start the next line part-way across.
                    cursorTarget = (destLineLengths.count - 1, 0)
                }
            }
            let linesToAdd = destLineLengths.count - wrappedLines.count

            var trimmedLines: Int
            if yBase == 0 && self.y != lines.count - 1 {
                // If the top section of the buffer is not yet filled
                trimmedLines = max (0, self.y - lines.maxLength + linesToAdd)
            } else {
                trimmedLines = max (0, lines.count - lines.maxLength + linesToAdd)
            }

            // Add the new lines
            var newLines : [BufferLine] = []
            if linesToAdd > 0 {
                for _ in 0..<linesToAdd {
                    let newLine = getBlankLine (attribute: CharData.defaultAttr, isWrapped: true)
                    newLines.append (newLine)
                }
            }

            if newLines.count > 0 {
                toInsert.append (InsertionSet (lines: newLines, start: y + wrappedLines.count + countToInsert, isNull: false))
                
                countToInsert += newLines.count
            }
            for l in newLines {
                wrappedLines.append (l)
            }

            // Copy buffer data to new locations, this needs to happen backwards to do in-place
            var destLineIndex = destLineLengths.count - 1 // Math.floor(cellsNeeded / newCols)
            var destCol = destLineLengths [destLineIndex] // cellsNeeded % newCols;
            if destCol == 0 {
                destLineIndex -= 1
                destCol = destLineLengths [destLineIndex]
            }

            var srcLineIndex = wrappedLines.count - linesToAdd - 1
            var srcCol = lastLineLength
            while srcLineIndex >= 0 {
                let cellsToCopy = min (srcCol, destCol)
                wrappedLines [destLineIndex].copyFrom (wrappedLines [srcLineIndex], srcCol: srcCol - cellsToCopy, dstCol: destCol - cellsToCopy, len: cellsToCopy)
                destCol -= cellsToCopy
                if destCol == 0 {
                    destLineIndex -= 1
                    if destLineIndex >= 0 {
                        destCol = destLineLengths [destLineIndex]
                    }
                }

                srcCol -= cellsToCopy
                if srcCol == 0 {
                    srcLineIndex -= 1
                    let wrappedLinesIndex = max (srcLineIndex, 0)
                    srcCol = getWrappedLineTrimmedLength (wrappedLines, wrappedLinesIndex, oldCols)
                }
            }

            // Null out the end of the line ends if a wide character wrapped to the following line
            for i in 0..<wrappedLines.count {
                if destLineLengths [i] < newCols {
                    wrappedLines [i] [destLineLengths [i]] = CharData.Null
                }
            }

            // Grand Line patch 9: upstream moves the cursor down by every added
            // row, which is right for a cursor below this group. Inside it,
            // only the rows now above the cursor's character move it; the rest
            // were added below it and are handled after this loop.
            var rowsAddedAboveCursor = linesToAdd
            var rowsAddedBelowCursor = 0
            if let cursorRow, let cursorTarget {
                rowsAddedAboveCursor = cursorTarget.row - cursorRow
                rowsAddedBelowCursor = linesToAdd - rowsAddedAboveCursor
                // The line's own rows already below the cursor - a cursor
                // moved back up into a wrapped line - are not blank either.
                contentRowsBelowCursor += wrappedLines.count - linesToAdd - 1 - cursorRow
            }

            // Adjust viewport as needed
            var viewportAdjustments = rowsAddedAboveCursor - trimmedLines
            while viewportAdjustments > 0 {
                viewportAdjustments -= 1
                if yBase == 0 {
                    // Grand Line patch 9: the rows below the cursor that its
                    // own line now fills are not blank rows to give up.
                    if self.y + contentRowsBelowCursor < newRows - 1 {
                        self.y += 1
                        lines.pop ()
                    } else {
                        yBase += 1
                        yDisp += 1
                    }
                } else {
                    // Ensure ybase does not exceed its maximum value
                    if yBase < min (lines.maxLength, lines.count + countToInsert) - newRows {
                        if yBase == yDisp {
                            yDisp += 1
                        }

                        yBase += 1
                    }
                }
            }

            // Grand Line patch 9: a row added below the cursor takes a blank
            // row from the bottom of the screen while there is one, and
            // otherwise scrolls the screen - the cursor stays on its character,
            // one row higher on the screen.
            for _ in 0..<max (0, rowsAddedBelowCursor) {
                if yBase == 0 && self.y + contentRowsBelowCursor < newRows - 1 {
                    lines.pop ()
                } else {
                    if yBase == 0 {
                        yBase += 1
                        yDisp += 1
                    } else if yBase < min (lines.maxLength, lines.count + countToInsert) - newRows {
                        if yBase == yDisp {
                            yDisp += 1
                        }
                        yBase += 1
                    }
                    self.y = max (0, self.y - 1)
                }
                contentRowsBelowCursor += 1
            }
            if let cursorTarget {
                self.x = cursorTarget.col
            }

            savedY = min (savedY + linesToAdd, yBase + newRows - 1)
        }

        rearrange (toInsert, countToInsert)
    }

    func rearrange (_ toInsert: [InsertionSet], _ countToInsert: Int)
    {
        // Rearrange lines in the buffer if there are any insertions, this is done at the end rather
        // than earlier so that it's a single O(n) pass through the buffer, instead of O(n^2) from many
        // costly calls to CircularList.splice.
        if toInsert.count > 0 {
            // Record buffer insert events and then play them back backwards so that the indexes are
            // correct
            // let insertEvents : [Int] = []

            // Record original lines so they don't get overridden when we rearrange the list
            let originalLines = CircularBufferLineList (maxLength: lines.maxLength)
            for i in 0..<lines.count {
                originalLines.push (lines [i])
            }

            let originalLinesLength = lines.count

            var originalLineIndex = originalLinesLength - 1
            var nextToInsertIndex = 0
            var nextToInsert = toInsert [nextToInsertIndex]
            lines.count = min (lines.maxLength, lines.count + countToInsert)
        
            var countInsertedSoFar = 0
            var i = min (lines.maxLength - 1, originalLinesLength + countToInsert - 1)
            while i >= 0 {
                defer { i = i-1 }
                if !nextToInsert.isNull && nextToInsert.start > originalLineIndex + countInsertedSoFar {
                        // Insert extra lines here, adjusting i as needed
                    for nexti in (0..<nextToInsert.lines.count).reversed() {
                        if i < 0 {
                            // if we reflow and the content has to be scrolled back past the beginning
                            // of the buffer then we end up loosing those lines
                            break
                        }
                        lines [i] = nextToInsert.lines [nexti]
                        i -= 1
                    }

                    i += 1

                    countInsertedSoFar += nextToInsert.lines.count
                    if nextToInsertIndex < toInsert.count - 1 {
                        nextToInsertIndex += 1
                       nextToInsert = toInsert [nextToInsertIndex]
                    } else {
                        nextToInsert = InsertionSet.Null ()
                    }
                } else {
                    lines [i] = originalLines [originalLineIndex]
                    originalLineIndex -= 1
                }
            }
        }
    }
    
    func reflow (_ newCols: Int, _ newRows: Int, cursorX: Int, keepCursorLine: Bool)
    {
        if cols == newCols {
            return
        }
        // iterate through rows, ignore the last one as it cannot be wrapped

        if newCols > cols {
            reflowWider (cols, rows, newCols, newRows, cursorX: cursorX, keepCursorLine: keepCursorLine)
        } else {
            reflowNarrower (cols, rows, newCols, newRows, cursorX: cursorX, keepCursorLine: keepCursorLine)
        }
        recalculateLinesWithImagesCount()
    }
    
    static var n = 0
    
    func dump ()
    {
        var str = ""
        str += "xDisp=\(xDisp), yDisp=\(yDisp), xBase=\(xBase), yBase=\(yBase)\n"
        str += "scrollTop=\(scrollTop) scrollBottom=\(scrollBottom)\n"
        str += "count=\(lines.count) maxLength=\(lines.maxLength)\n"
        for i in 0..<_lines.getArray().count {
            var txt: String
            if let r = _lines.getArray()[i] {
                txt = r.debugDescription.replacingOccurrences(of: "\u{0}", with: " ")
            } else {
                txt = "<empty>"
            }
            let flag = i >= yDisp ? ">>" : "  "
            let istr = String (format: "%03d", i)
            let cstr = String (format: "%03d", _lines.debugGetCyclicIndex(i))
            str += "[\(istr):\(cstr)]\(flag)\(txt)\n"
        }
        let file = "/Users/miguel/Downloads/Logs/dump-\(Buffer.n)"
        do {
            try str.write(to: URL.init (fileURLWithPath: file), atomically: false, encoding: .utf8)

        } catch {
            print ("Could not log the dump() contents to \(file)")
        }
        Buffer.n += 1
    }
    
    // This variable holds the last location that we poked a Character on.   This is required
    // because combining unicode characters come after the character, so we need to poke back
    // at this location.   We track the buffer (so we can distinguish Alt/Normal), the buffer line
    // that we fetched, and the column.
    var lastBufferStorage: (y: Int, x: Int, cols: Int, rows: Int) = (0, 0, 0, 0)

    /// Bulk-inserts ASCII characters (all width-1, non-combining).
    /// Returns number of bytes consumed. Returns 0 if insert mode is active.
    func insertAsciiRun(_ bytes: ArraySlice<UInt8>, attribute: Attribute) -> Int {
        guard !insertMode else { return 0 }
        let right = marginMode ? _marginRight : _cols - 1
        var consumed = 0
        var idx = bytes.startIndex

        while idx < bytes.endIndex {
            if _x > right {
                guard wraparound else { break }
                _x = marginMode ? _marginLeft : 0
                if _y >= _scrollBottom {
                    scroll(true)
                } else {
                    _y += 1
                    // Grand Line patch 9: `_y` is a screen row and `_lines` is
                    // the whole buffer. Upstream marked the scrollback row
                    // `_y` as wrapped instead of the one being written, so
                    // with any scrollback a wrap above the bottom row joined
                    // two unrelated history lines in a copy and split this one.
                    _lines[_y + _yBase].isWrapped = true
                }
            }
            let available = right - _x + 1
            let runLen = min(available, bytes.endIndex - idx)
            let row = _lines[_y + _yBase]
            for i in 0..<runLen {
                row[_x + i] = CharData(attribute: attribute, code: Int32(bytes[idx + i]), size: 1)
            }
            _x += runLen
            consumed += runLen
            idx += runLen
        }
        if consumed > 0 {
            lastBufferStorage = (_y + _yBase, _x - 1, _cols, _rows)
        }
        return consumed
    }

    func insertCharacter(_ charData: CharData) {
        var chWidth = Int (charData.width)
        
        let right = marginMode ? _marginRight : _cols - 1
        // goto next line if ch would overflow
        // TODO: needs a global min terminal width of 2
        // FIXME: additionally ensure chWidth fits into a line
        //   -->  maybe forbid cols<xy at higher level as it would
        //        introduce a bad runtime penalty here
        if _x + chWidth - 1 > right {
            // autowrap - DECAWM
            // automatically wraps to the beginning of the next line
            if wraparound {
                _x = marginMode ? _marginLeft : 0
                
                if _y >= _scrollBottom {
                    scroll (true)
                } else {
                    // The line already exists (eg. the initial viewport), mark it as a
                    // wrapped line
                    _y += 1
                    // Grand Line patch 9: the row being written, not scrollback
                    // row `_y` - see `insertAsciiRun`.
                    _lines [_y + _yBase].isWrapped = true
                }
                // row changed, get it again
            } else {
                if (chWidth == 2) {
                    // FIXME: check for xterm behavior
                    // What to do here? We got a wide char that does not fit into last cell
                    return
                }
                // FIXME: Do we have to set buffer.x to cols - 1, if not wrapping?
                _x = right
            }
        }
        let bufferRow = _lines[_y+_yBase]

        // insert mode: move characters to right
        if insertMode {
            var empty = CharData.Null
            empty.attribute = curAttr
            // right shift cells according to the width
            bufferRow.insertCells (pos: _x, n: chWidth, rightMargin: marginMode ? _marginRight : _cols-1, fillData: empty)
            // test last cell - since the last cell has only room for
            // a halfwidth char any fullwidth shifted there is lost
            // and will be set to eraseChar
            let lastCell = bufferRow [_cols - 1]
            if lastCell.width == 2 {
                bufferRow [_cols - 1] = empty
            }
        }

        // write current char to buffer and advance cursor
        lastBufferStorage = (_y + _yBase, _x, _cols, _rows)
        if _x >= _cols {
            _x = _cols-1
        }
        bufferRow[_x] = charData
        _x += 1

        // fullwidth char - also set next cell to placeholder stub and advance cursor
        // for graphemes bigger than fullwidth we can simply loop to zero
        // we already made sure above, that buffer.x + chWidth will not overflow right
        if chWidth > 1 {
            let wideEmpty = CharData(attribute: curAttr, scalar: UnicodeScalar(0)!, size: 0)
            chWidth -= 1
            while chWidth != 0 && _x < _cols {
                bufferRow [_x] = wideEmpty
                _x += 1
                chWidth -= 1
            }
        }
        
    }
    
    func dumpConsole ()
    {
        let debugBuffer = self
        for y in 0..<debugBuffer._lines.maxLength {
            let flag = y == debugBuffer.yDisp ? "D" : " "
            let yb   = y == debugBuffer.yBase ? "B" : " "
            let istr = String (format: "%03d", y)
            let cstr = String (format: "%03d", debugBuffer._lines.debugGetCyclicIndex(y))
        
            print ("[\(istr):\(cstr)]\(flag)\(yb) \(debugBuffer._lines.getArray() [y].debugDescription)")
        }
    }    
}
