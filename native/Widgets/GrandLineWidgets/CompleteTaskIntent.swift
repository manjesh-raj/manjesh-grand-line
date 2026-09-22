// Manjesh Grand Line - the WidgetKit extension.
//
// The tick. macOS 14's interactive widgets are the whole reason F23 is worth
// a signing workstream - the reviewed mockup's own closing note says so: "a
// read-only widget is a screenshot of the app".
//
// ## What a tap does, and what it deliberately does not do
//
// `perform()` runs in the **extension's** process. It does not write the
// captain's task files, and the reasoning is in
// `GrandLineWidgetAction`'s own header: those files are YAML under a git
// working tree owned by `ShiftGitSync` on a serial queue, and a second
// writer races `.git/index.lock` - a lesson this repo has already paid for.
//
// So the tap records the request in the shared container and the app applies
// it through `ShiftStore.setTaskCompleted`, which is the same call the Tasks
// page's own checkbox makes. That matters for more than tidiness: completing
// a *recurring* task is what spawns its next occurrence (see
// `ShiftStore.nextOccurrence`), and a widget that wrote the YAML itself would
// have silently broken every repeating task the captain ticked from the
// desktop.
//
// ## The honest consequence, which the widget states rather than hides
//
// The task therefore does not vanish the instant it is tapped: it clears when
// the app next runs. `TasksDueWidget`'s footer says "ticked - applies when the
// app opens" for exactly as long as a request is pending, because a checkbox
// that appears to do nothing is worse than one that explains itself.

import AppIntents
import Foundation
import WidgetKit

struct CompleteTaskIntent: AppIntent {

    static var title: LocalizedStringResource = "Complete task"
    static var description = IntentDescription("Marks a Manjesh Grand Line task as done.")

    /// Widgets only: this intent is meaningless outside the widget that owns
    /// the row, and should never appear as a standalone Shortcuts action with
    /// a task id the captain has to type.
    static var isDiscoverable: Bool = false

    /// Not `openAppWhenRun`. The point of an interactive widget is that the
    /// day changes without opening anything.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        // Throws rather than swallowing - GL-10's rule, and here the thrown
        // error is also the only way WidgetKit can tell the captain the tap
        // did not take.
        try GrandLineWidgetAction.enqueue(
            GrandLineWidgetAction.Request(kind: .completeTask, taskID: taskID, requestedAt: Date()),
            directory: GrandLineWidgetContainer.actionsDirectory()
        )
        // Redraw now, so the row picks up its pending state in the same
        // frame the tap produced.
        WidgetCenter.shared.reloadTimelines(ofKind: GrandLineWidgetKind.tasksDue)
        return .result()
    }
}
