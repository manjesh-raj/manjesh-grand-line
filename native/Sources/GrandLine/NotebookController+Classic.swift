// Grand Line - native macOS app.
//
// `NotebookController`'s floating-bar presentation (R2-ARCH-04): the page's own toolbar row - the mode switch, find, the details column and delete - which the sidebar layout hides for the window toolbar's controls (R2-UX-06).
//
// The floating bar is the classic layout, frozen by R2-ARCH-01: it gets
// fixes but no new features and no page redesigns. So the members only its
// presentation uses live here, moved verbatim out of `NotebookController.swift`, and
// that file carries the presentation the sidebar layout draws. A member both
// layouts use stays there. Swift's `private` is file-scoped, so the few
// members this file and the main one share lost `private`; treat this pair
// as one type's private parts (GL-36). `ClassicPresentationSelfTest` fails if
// one of these members moves back.

import AppKit

extension NotebookController {

    func buildToolbar(in root: NSView) {
        root.addSubview(toolbar)
        modeTabs.translatesAutoresizingMaskIntoConstraints = false
        modeTabs.onSelect = { [weak self] id in
            guard let self, let picked = ViewMode(rawValue: id) else { return }
            self.mode = picked
            self.applyMode()
        }

        // The sync line that sat beside the mode switch was the drill
        // header's subtitle, word for word, one row above it.
        toolbar.setLeading(HelmPageToolbar.group([modeTabs]))
        toolbar.setTrailing(HelmPageToolbar.group([findButton, railButton, deleteButton]))

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
        ])
    }
}
