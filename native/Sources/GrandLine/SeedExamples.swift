// Grand Line - native macOS app.
//
// **UX issue X5 of the 2026-09-27 review.** Runbooks, Postmortems, Sticky
// Board and the Notebook all open completely empty on a new install, and two
// of them offered no action at all - so the first thing a captain sees on
// four of this app's own stores is a sentence and nothing to press.
//
// The review's own argument is that the Command Library already solves this:
// it ships 73 seeded commands, and that turns an empty app into a tour.
// Seeding these four the same way is not right, though, and the difference
// is worth stating because it is the whole design of this file: a command
// library is a *reference* that is useful before you have written anything,
// while a runbook, a note and a notebook page are the captain's own records.
// Pre-filling somebody's own board with content they did not write is
// clutter they then have to delete.
//
// So the affordance is opt-in: one button, one example, once. The content
// below is written to be immediately deletable and to teach the page's own
// mechanics rather than to look like real data - the notebook page
// demonstrates `[[links]]` (the review's own suggestion), the runbook shows
// the fenced command blocks the page counts steps from, and the postmortem
// shows the `Root cause:` line its own subtitle reads.
//
// **Docs is deliberately not here.** It is a synced copy of the DevOps
// Playbook, not a store the captain writes to - its empty state's "Sync Now"
// is already the right and only action, and seeding a fabricated page into a
// git-synced repo would be writing somebody else's content into their
// history.

import Foundation

enum SeedExamples {

    // MARK: Runbooks

    static let runbookTitle = "Example: restart a wedged service"

    /// Fenced blocks on purpose: `DocsRunbookMetadata.commandLines` counts
    /// them, so the seeded runbook's own "3 steps" subtitle is real rather
    /// than a zero next to a page full of prose.
    static let runbookContent = """
    # \(runbookTitle)

    Category: Example

    A runbook is a checklist you can follow at 3am. This one is here to show
    the shape - edit it, or delete it once you have written your own.

    ## 1. Confirm it is actually wedged

    ```
    systemctl status my-service
    ```

    ## 2. Look at what it last said

    ```
    journalctl -u my-service -n 100 --no-pager
    ```

    ## 3. Restart it, then watch

    ```
    systemctl restart my-service
    ```
    """

    // MARK: Postmortems

    static let postmortemTitle = "Example: the 02:14 checkout outage"

    /// Carries a real `## Root cause` section, because
    /// `DocsRunbookMetadata.rootCause` reads the first line under that
    /// heading and it is what the page's row subtitle shows - a seeded
    /// postmortem without one would demonstrate the page's emptiest row
    /// rather than its shape.
    static let postmortemContent = """
    # \(postmortemTitle)

    A postmortem is what you write down so the next person does not have to
    work it out again. This one is an example - edit it, or delete it.

    ## Root cause

    A config change removed the connection-pool limit, so one slow query
    exhausted the database's connections.

    ## What happened

    Checkout returned 503 for 18 minutes overnight. No data was lost.

    ## Why it took as long as it did

    The alert fired on error rate, not on connection saturation, so the first
    ten minutes were spent looking at the wrong graph.

    ## What changed because of it

    - The pool limit is set explicitly and is asserted at deploy time.
    - There is an alert on connection saturation.
    """

    // MARK: Sticky board

    static let stickyTitle = "Example note"
    static let stickyText = """
    Drag me anywhere. Right-click for colours, a checklist, or to archive me.

    Delete me once you have your own notes up.
    """

    // MARK: Notebook

    static let notebookTitle = "Welcome"

    /// The review asked specifically for "a Welcome notebook page
    /// demonstrating `[[links]]`", because that is the one mechanic in the
    /// notebook nothing else in the app hints at - an empty page gives no
    /// clue that typing two brackets makes a link, or that the backlinks
    /// panel on the right will then have something in it.
    static let notebookContent = """
    # Welcome

    This is a notebook page. Everything here is plain markdown, and the
    preview on the right follows as you type.

    ## Linking pages

    Write two square brackets around a page's name to link it:
    [[Example: a linked page]]. The link works whether or not that page
    exists yet - following one that does not creates it.

    Any page that links *to* the page you are reading shows up under
    **Backlinks** in the right-hand panel, so a notebook grows its own index
    without you keeping one.

    ## What else is here

    - "Today's note" in the toolbar opens a page dated today, and keeps them
      together under Daily notes.
    - A page's name is its filename, so keep it short.

    Delete this page whenever you like.
    """
}
