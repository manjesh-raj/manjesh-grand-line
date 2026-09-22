// Manjesh Grand Line - the WidgetKit extension.
//
// The Sticky-note widget, small and medium. The reviewed mockup's own middle
// panel ("Sticky · small"): a note on real paper, with the kicker, the
// captain's own title line, the body, and the date.
//
// ## Why this one is configurable and the Tasks widget is not
//
// The mockup labels it `STICKY · PINNED`, and `StickyNote` has no pin. This
// widget does not add one. A note choice is per-*widget* - two sticky widgets
// on one desktop should be able to show two different notes - which is
// precisely what WidgetKit's own configuration is for, and inventing a
// board-level "pinned" flag would have been a model change (a new field, a
// GL-01 decoder default, a git-synced schema bump, a board affordance) driven
// by a widget rather than by the board.
//
// Unconfigured, it shows the newest note and says so: the kicker reads
// `STICKY · NEWEST` rather than `STICKY · PINNED`, because an unconfigured
// widget's note genuinely changes under the captain and the header is where
// that belongs. `GrandLineWidgetDigest.stickyKicker` is the one place that
// decides, and it is under test.
//
// ## The paper is not a theme token
//
// `StickyBoardModels.swift`'s header is explicit that the six paper hues are
// literal values and a deliberate exception to this app's theme-token rule -
// "a real sticky note does not re-tint itself when the room's lighting
// changes". So the note here is drawn in its own paper and ink, carried in
// the snapshot, identical in both registers. Only the chrome around it (the
// medium family's header, the date line, the card behind the notes) follows
// Daylight/Dusk.

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Choosing a note

/// One note, as something the widget's configuration sheet can list.
struct StickyNoteEntity: AppEntity, Identifiable {

    let id: String
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Sticky note" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title))
    }

    static var defaultQuery = StickyNoteQuery()
}

/// Lists the notes the app has published.
///
/// Reads the same snapshot the widget renders from - it does not open the
/// board's own store, for every reason `GrandLineWidgetContainer`'s header
/// gives. A note the captain has since deleted simply stops being listed, and
/// a widget still configured for it falls back to the newest (see
/// `GrandLineWidgetDigest.stickyRows`, which hoists the preferred note only
/// when it is still there).
struct StickyNoteQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [StickyNoteEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [StickyNoteEntity] {
        all()
    }

    private func all() -> [StickyNoteEntity] {
        guard case .ready(let snapshot) = GrandLineWidgetDigest.load(
            from: GrandLineWidgetContainer.snapshotURL()
        ) else {
            return []
        }
        return GrandLineWidgetDigest
            .stickyRows(from: snapshot, preferredID: nil, limit: GrandLineWidgetSnapshot.stickyLimit)
            .map { StickyNoteEntity(id: $0.id, title: $0.title) }
    }
}

struct SelectStickyNoteIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource = "Choose a sticky note"
    static var description = IntentDescription("Pick which note this widget shows, or leave it on the newest.")

    @Parameter(title: "Note")
    var note: StickyNoteEntity?

    init() {}

    init(note: StickyNoteEntity?) {
        self.note = note
    }
}

// MARK: - The timeline

struct StickyNoteEntry: TimelineEntry {
    let date: Date
    let state: GrandLineWidgetDigest.State
    let preferredID: String?
}

struct StickyNoteProvider: AppIntentTimelineProvider {

    static func noteLimit(for family: WidgetFamily) -> Int {
        family == .systemSmall ? 1 : 3
    }

    func placeholder(in context: Context) -> StickyNoteEntry {
        StickyNoteEntry(date: Date(), state: .ready(StickyNotePreviewData.snapshot), preferredID: nil)
    }

    func snapshot(for configuration: SelectStickyNoteIntent, in context: Context) async -> StickyNoteEntry {
        let live = GrandLineWidgetDigest.load(from: GrandLineWidgetContainer.snapshotURL())
        if case .ready(let snapshot) = live, !snapshot.stickies.isEmpty, !context.isPreview {
            return StickyNoteEntry(date: Date(), state: live, preferredID: configuration.note?.id)
        }
        return StickyNoteEntry(date: Date(), state: .ready(StickyNotePreviewData.snapshot), preferredID: nil)
    }

    func timeline(for configuration: SelectStickyNoteIntent, in context: Context) async -> Timeline<StickyNoteEntry> {
        let state = GrandLineWidgetDigest.load(from: GrandLineWidgetContainer.snapshotURL())
        let entry = StickyNoteEntry(date: Date(), state: state, preferredID: configuration.note?.id)
        // One entry, and a long horizon. Unlike the Tasks widget, nothing
        // here is a function of the clock: a note does not become overdue.
        // The app's own `reloadAllTimelines` on every board change is what
        // makes an edit appear; this interval is only the backstop for a
        // snapshot written while the widget was not being refreshed.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: entry.date) ?? entry.date
        return Timeline(entries: [entry], policy: .after(next))
    }
}

struct StickyNoteWidget: Widget {

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: GrandLineWidgetKind.stickyNote,
            intent: SelectStickyNoteIntent.self,
            provider: StickyNoteProvider()
        ) { entry in
            StickyNoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Sticky note")
        .description("One note off the board, on the desktop.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Same split as `TasksDueWidgetView`, for the same reason - see its own
/// doc comment: `widgetFamily` cannot be injected, so the renderable body
/// takes it as a parameter.
struct StickyNoteWidgetView: View {
    let entry: StickyNoteEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        StickyNoteBody(entry: entry, family: family, fallbackScheme: colorScheme)
    }
}

struct StickyNoteBody: View {
    let entry: StickyNoteEntry
    let family: WidgetFamily
    let fallbackScheme: ColorScheme

    var body: some View {
        content
    }

    private var palette: WidgetPalette {
        if case .ready(let snapshot) = entry.state { return .resolve(snapshot.appearance) }
        return .resolve(fallbackScheme)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .unavailable(let reason):
            WidgetUnavailableView(reason: reason, palette: palette)
                .grandLineWidgetSurface(palette)
        case .locked:
            WidgetLockedView(palette: palette)
                .grandLineWidgetSurface(palette)
        case .ready(let snapshot):
            let notes = GrandLineWidgetDigest.stickyRows(
                from: snapshot,
                preferredID: entry.preferredID,
                limit: StickyNoteProvider.noteLimit(for: family)
            )
            if notes.isEmpty {
                emptyBoard
                    .grandLineWidgetSurface(palette)
            } else if family == .systemSmall, let note = notes.first {
                // The small family *is* the note: the paper reaches the edge
                // of the widget, which is what makes it read as a note on the
                // desktop rather than as a card with a note in it. So this is
                // the one view in the extension that does not use
                // `grandLineWidgetSurface` - it supplies its own container
                // background.
                StickyPaperView(
                    note: note,
                    kicker: GrandLineWidgetDigest.stickyKicker(
                        preferredID: entry.preferredID, resolvedID: note.id
                    ),
                    bodyLineLimit: 4
                )
                .padding(WidgetMetrics.padding)
                .containerBackground(for: .widget) { Color(hex: note.paperHex) }
            } else {
                mediumStack(notes)
                    .grandLineWidgetSurface(palette)
            }
        }
    }

    /// The medium family: up to three notes side by side, each on its own
    /// paper, on the app's own card ground.
    private func mediumStack(_ notes: [GrandLineWidgetSnapshot.Sticky]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: WidgetMetrics.rowGap) {
                WidgetIdentityTile(systemName: "note.text", gradient: WidgetDomainHue.stickyGradient)
                Text("Sticky Board")
                    .font(WidgetType.tinyStrong)
                    .foregroundStyle(palette.muted)
                Spacer(minLength: 0)
                Text(notes.count == 1 ? "1 note" : "\(notes.count) notes")
                    .font(WidgetType.tiny)
                    .foregroundStyle(palette.muted)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(notes) { note in
                    // The kicker is on the *pinned* note only, and only when
                    // one is genuinely pinned. Measured in a real
                    // `ImageRenderer` pass at 352x168: a kicker on all three
                    // repeated "STICKY · NEWEST" three times, which says
                    // nothing, and wrapped to two lines at 110pt of column -
                    // costing a line of the note's own body to print a label
                    // the header ("Sticky Board") already carries.
                    StickyPaperView(
                        note: note,
                        kicker: GrandLineWidgetDigest.stickyBadge(
                            preferredID: entry.preferredID, resolvedID: note.id
                        ),
                        bodyLineLimit: 3
                    )
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: note.paperHex))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A board with no notes on it - a real, knowable state, worded as one
    /// rather than as a failure (GL-14 cuts both ways).
    private var emptyBoard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No notes yet")
                .font(WidgetType.row)
                .foregroundStyle(palette.ink)
            Text("Anything you put on the Sticky Board shows up here.")
                .font(WidgetType.tiny)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One note, on its own paper, in its own ink.
struct StickyPaperView: View {
    let note: GrandLineWidgetSnapshot.Sticky
    /// `nil` draws no kicker at all - the medium family's own case, where the
    /// header already names the board.
    let kicker: String?
    let bodyLineLimit: Int

    private var ink: Color { Color(hex: note.inkHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kicker {
                Text(kicker)
                    .font(WidgetType.kicker)
                    .tracking(1.1)
                    .lineLimit(1)
                    .foregroundStyle(ink.opacity(0.55))
            }
            Text(note.title)
                .font(WidgetType.title)
                .foregroundStyle(ink)
                .lineLimit(2)
                .padding(.top, kicker == nil ? 0 : 8)
            if let done = note.checklistDone, let total = note.checklistTotal {
                // A checklist note's `text` is already its markdown
                // rendering (`- [x] …`), which is the wrong thing to print
                // on a 168pt canvas. Its progress is the useful summary.
                Text("\(done) of \(total) done")
                    .font(WidgetType.body)
                    .foregroundStyle(ink.opacity(0.75))
                    .padding(.top, 6)
            } else if !note.body.isEmpty {
                Text(note.body)
                    .font(WidgetType.body)
                    .foregroundStyle(ink)
                    .lineLimit(bodyLineLimit)
                    .padding(.top, 6)
            }
            Spacer(minLength: 4)
            Text(Self.dateLabel(note.createdAt))
                .font(WidgetType.kicker)
                .foregroundStyle(ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }
}

/// The gallery/placeholder fixture - the reviewed mockup's own note, on the
/// board's own default yellow paper (`StickyNoteColor.yellow`'s literal
/// `FFE066`/`3A2E00` pair).
enum StickyNotePreviewData {
    static var snapshot: GrandLineWidgetSnapshot {
        GrandLineWidgetSnapshot(
            generatedAt: Date(),
            availability: .ready,
            appearance: .dark,
            stickies: [
                .init(id: "s1", title: "Ask Ravi about VPC peering",
                      body: "He owns the 10.42/16 range. Needs a ticket before Friday.",
                      paperHex: "FFE066", inkHex: "3A2E00",
                      createdAt: Date().addingTimeInterval(-4 * 24 * 3600)),
                .init(id: "s2", title: "Grafana board for the new collector",
                      body: "Two rows: OTLP ingest and exporter queue depth.",
                      paperHex: "9BD3F5", inkHex: "0A2E45",
                      createdAt: Date().addingTimeInterval(-6 * 24 * 3600)),
                .init(id: "s3", title: "Renewal checklist",
                      body: "", paperHex: "A8E6A1", inkHex: "0F3010",
                      createdAt: Date().addingTimeInterval(-9 * 24 * 3600),
                      checklistDone: 2, checklistTotal: 5)
            ],
            openTaskCount: 6,
            pendingFollowUpCount: 2
        )
    }
}

// MARK: - Previews (see TasksDueWidget.swift's own note on what these can prove)

#Preview("Sticky · small", as: .systemSmall) {
    StickyNoteWidget()
} timeline: {
    StickyNoteEntry(date: Date(), state: .ready(StickyNotePreviewData.snapshot), preferredID: nil)
    StickyNoteEntry(date: Date(), state: .ready(StickyNotePreviewData.snapshot), preferredID: "s1")
    StickyNoteEntry(date: Date(), state: .unavailable(.neverPublished), preferredID: nil)
}

#Preview("Sticky · medium", as: .systemMedium) {
    StickyNoteWidget()
} timeline: {
    StickyNoteEntry(date: Date(), state: .ready(StickyNotePreviewData.snapshot), preferredID: nil)
    StickyNoteEntry(date: Date(), state: .locked, preferredID: nil)
}
