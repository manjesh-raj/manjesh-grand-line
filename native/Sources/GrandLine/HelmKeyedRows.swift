// Grand Line - native macOS app.
//
// P2 of the Grand Line vs Automic Vault polish report: refresh in place
// instead of rebuilding.
//
// Most of this app's lists are an `NSStackView` of rows that every refresh
// emptied and refilled - 61 teardown loops in 46 files by the report's count.
// A refresh that rebuilds a row it could have updated throws away the row's
// own state (a hover, a focus, a half-typed reply), re-registers its theme
// observer, re-solves its constraints, and makes the list flash.
//
// This is the one reconciler for that shape: rows are keyed by a stable id,
// a row whose key is still in the list is **updated in place**, only a new key
// builds a row, only a key that left removes one, and rows are moved only
// when their order changed. The first fill builds everything, as before; a
// row that appears after that fades in on the motion table's state duration
// (instant under Reduce Motion). A row that leaves goes at once, so the list's
// arranged subviews - which suites and the key view loop read - always match
// the data synchronously.
//
// `update` must fully configure a row from its item, because it runs for new
// and reused rows alike: that is what makes "updated in place" and "built
// fresh" render the same.

import AppKit

final class HelmKeyedRows {

    private weak var stack: NSStackView?
    private(set) var rowsByKey: [String: NSView] = [:]
    private var placeholder: NSView?
    private var hasFilled = false
    /// Views already pinned to the stack's width, so a move never adds a
    /// second tie.
    private var tied = Set<ObjectIdentifier>()

    init(stack: NSStackView) {
        self.stack = stack
    }

    /// The rows in display order, as the stack holds them now.
    var orderedRows: [NSView] {
        stack?.arrangedSubviews.filter { $0 !== placeholder } ?? []
    }

    /// Reconcile the stack against `items`, in order.
    ///
    /// - Parameters:
    ///   - key: a stable identity for an item - the same thing keeps the same
    ///     key across refreshes.
    ///   - make: builds the row for a key seen for the first time.
    ///   - update: configures a row (new or reused) for its item.
    ///   - placeholder: shown in place of the rows when `items` is empty;
    ///     built once and kept.
    ///   - tiesWidth: pins each row's width to the stack's, once, when built.
    func reconcile<Item>(_ items: [Item],
                         key: (Item) -> String,
                         make: (Item) -> NSView,
                         update: (NSView, Item) -> Void,
                         placeholder makePlaceholder: (() -> NSView)? = nil,
                         tiesWidth: Bool = true) {
        guard let stack else { return }
        var desired: [NSView] = []
        var seen = Set<String>()
        var built: [NSView] = []
        for item in items {
            let id = key(item)
            guard seen.insert(id).inserted else { continue }   // a duplicate key shows once
            let row: NSView
            if let existing = rowsByKey[id] {
                row = existing
            } else {
                row = make(item)
                rowsByKey[id] = row
                built.append(row)
            }
            update(row, item)
            desired.append(row)
        }
        for (id, row) in rowsByKey where !seen.contains(id) {
            rowsByKey[id] = nil
            tied.remove(ObjectIdentifier(row))
            if row.superview === stack {
                stack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
        }

        if desired.isEmpty, let makePlaceholder {
            let shown = placeholder ?? makePlaceholder()
            if placeholder == nil {
                placeholder = shown
                if tiesWidth { shown.translatesAutoresizingMaskIntoConstraints = false }
            }
            desired = [shown]
        } else if let placeholder, placeholder.superview === stack {
            stack.removeArrangedSubview(placeholder)
            placeholder.removeFromSuperview()
        }

        // Anything arranged that is no longer wanted (a row from before this
        // reconciler owned the stack, or the placeholder) comes out.
        for view in stack.arrangedSubviews where !desired.contains(where: { $0 === view }) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // Then put the wanted views in order, moving only what is out of place.
        for (index, view) in desired.enumerated() {
            let arranged = stack.arrangedSubviews
            if index < arranged.count, arranged[index] === view { continue }
            if view.superview === stack { stack.removeArrangedSubview(view) }
            stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
            if tiesWidth, tied.insert(ObjectIdentifier(view)).inserted {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        if hasFilled {
            for row in built {
                row.alphaValue = 0
                HelmMotion.fade(row, to: 1, duration: HelmMotion.stateDuration, animated: true)
            }
        }
        hasFilled = true
    }
}
