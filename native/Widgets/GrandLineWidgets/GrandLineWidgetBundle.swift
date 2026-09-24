// Grand Line - the WidgetKit extension.
//
// The extension's entry point. `@main` on a `WidgetBundle` is what
// `_NSExtensionMain` resolves to, which is why
// `Scripts/build-widget-extension.sh` links with `-e _NSExtensionMain` and
// compiles this target `-parse-as-library` (a `main.swift`-style top-level
// entry point would give the `.appex` an `_main` no widget host ever calls).
//
// Two widgets, both listed here - a bundle is how one `.appex` offers more
// than one widget, and the alternative (two extensions) would mean two
// Info.plists, two signings and two entries in the widget gallery's own
// grouping for no gain.

import SwiftUI
import WidgetKit

@main
struct GrandLineWidgetBundle: WidgetBundle {
    var body: some Widget {
        TasksDueWidget()
        StickyNoteWidget()
    }
}
