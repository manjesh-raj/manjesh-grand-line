// Grand Line - the widget render probe.
//
// This repo's standing rule for a UI change is "assert what is painted, not
// what was computed", and its screenshot substitute is an off-screen
// `cacheDisplay` render. Neither applies to a widget: a widget is not an
// `NSView`, and its views are drawn only by the system's widget host - which
// will not load this extension until the App Group entitlement has a Team ID
// behind it (`native/Widgets/README.md`).
//
// **`ImageRenderer` is the substitute that does work**, and it is a real
// render rather than a preview: the same SwiftUI views the extension
// registers, at both families' real point sizes, rasterised to PNG that can
// be read back with `Read`.
//
// It earned its keep on the first pass. It caught the medium Sticky widget
// drawing `STICKY · NEWEST` on all three notes - meaningless on the second
// and third, and wrapping to two lines at 110pt of column, which cost a line
// of each note's own body. Nothing in the timeline logic or the type system
// could have found that, and the suite could not either.
//
// ## Why the views are split into `…WidgetView` / `…Body`
//
// `EnvironmentValues.widgetFamily` is **read-only** - there is no
// `.environment(\.widgetFamily, .systemMedium)`. A view that reads it
// directly can therefore only ever be rendered by a widget host. So each
// widget's entry point reads the environment and hands the family on as a
// plain parameter, and this probe renders that body. Both widget files say so
// in their own doc comments.
//
// Run it with `Scripts/render-widget-previews.sh`; it is not built by
// `swift build` or by the extension's own build script.

import AppKit
import SwiftUI
import WidgetKit

@MainActor
func render(_ view: some View, size: CGSize, background: Color, to path: String) {
    let wrapped = view
        .frame(width: size.width, height: size.height)
        .background(background)
    let renderer = ImageRenderer(content: wrapped)
    renderer.scale = 2
    // `renderer.nsImage`'s first representation is not an `NSBitmapImageRep`
    // (measured - it is a vector-backed rep), so the PNG has to come through
    // `cgImage`.
    guard let cgImage = renderer.cgImage else {
        print("RENDER FAILED (no cgImage): \(path)")
        return
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("RENDER FAILED (no png): \(path)")
        return
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("  \(rep.pixelsWide)x\(rep.pixelsHigh)  \(path)")
    } catch {
        print("RENDER FAILED (\(error)): \(path)")
    }
}

guard CommandLine.arguments.count > 1 else {
    print("usage: render-probe <output-directory>")
    exit(2)
}
let out = CommandLine.arguments[1]

// `ImageRenderer` resolves fonts and symbol images through AppKit, which
// needs a shared application to exist. It never runs the run loop.
_ = NSApplication.shared

MainActor.assumeIsolated {
    let dusk = WidgetPalette.dusk
    let daylight = WidgetPalette.daylight
    let small = CGSize(width: 168, height: 168)
    let medium = CGSize(width: 352, height: 168)

    var daylightTasks = TasksDuePreviewData.snapshot
    daylightTasks.appearance = .light

    let states: [(String, TasksDueEntry, CGSize, WidgetFamily, Color)] = [
        ("tasks-small-dusk", .init(date: Date(), state: .ready(TasksDuePreviewData.snapshot), pendingTaskIDs: []),
         small, .systemSmall, dusk.card),
        ("tasks-small-pending", .init(date: Date(), state: .ready(TasksDuePreviewData.snapshot), pendingTaskIDs: ["p2"]),
         small, .systemSmall, dusk.card),
        ("tasks-small-empty",
         .init(date: Date(),
               state: .ready(GrandLineWidgetSnapshot(generatedAt: Date(), availability: .ready,
                                                     appearance: .dark, openTaskCount: 3)),
               pendingTaskIDs: []),
         small, .systemSmall, dusk.card),
        ("tasks-small-unavailable", .init(date: Date(), state: .unavailable(.neverPublished), pendingTaskIDs: []),
         small, .systemSmall, dusk.card),
        ("tasks-small-locked", .init(date: Date(), state: .locked, pendingTaskIDs: []),
         small, .systemSmall, dusk.card),
        ("tasks-medium-dusk", .init(date: Date(), state: .ready(TasksDuePreviewData.snapshot), pendingTaskIDs: []),
         medium, .systemMedium, dusk.card),
        ("tasks-medium-daylight", .init(date: Date(), state: .ready(daylightTasks), pendingTaskIDs: []),
         medium, .systemMedium, daylight.card)
    ]
    for (name, entry, size, family, background) in states {
        render(
            TasksDueBody(entry: entry, family: family,
                         fallbackScheme: background == daylight.card ? .light : .dark),
            size: size, background: background, to: "\(out)/\(name).png"
        )
    }

    let notes = StickyNotePreviewData.snapshot
    let stickyStates: [(String, StickyNoteEntry, CGSize, WidgetFamily, Color)] = [
        ("sticky-small-newest", .init(date: Date(), state: .ready(notes), preferredID: nil),
         small, .systemSmall, Color(hex: notes.stickies[0].paperHex)),
        ("sticky-small-pinned", .init(date: Date(), state: .ready(notes), preferredID: notes.stickies[0].id),
         small, .systemSmall, Color(hex: notes.stickies[0].paperHex)),
        ("sticky-medium", .init(date: Date(), state: .ready(notes), preferredID: nil),
         medium, .systemMedium, dusk.card),
        ("sticky-medium-pinned", .init(date: Date(), state: .ready(notes), preferredID: notes.stickies[1].id),
         medium, .systemMedium, dusk.card),
        ("sticky-small-empty",
         .init(date: Date(),
               state: .ready(GrandLineWidgetSnapshot(generatedAt: Date(), availability: .ready, appearance: .dark)),
               preferredID: nil),
         small, .systemSmall, dusk.card),
        ("sticky-medium-locked", .init(date: Date(), state: .locked, preferredID: nil),
         medium, .systemMedium, dusk.card)
    ]
    for (name, entry, size, family, background) in stickyStates {
        render(
            StickyNoteBody(entry: entry, family: family, fallbackScheme: .dark),
            size: size, background: background, to: "\(out)/\(name).png"
        )
    }
}
