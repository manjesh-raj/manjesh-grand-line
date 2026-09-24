// Grand Line - the WidgetKit extension.
//
// The Tasks-due widget, small and medium. The reviewed mockup's own two left
// panels (`data/grandline-future-features-mockups-artifact/report.md` names
// the artifact; F23's section draws "Tasks · small" and "Tasks · medium").
//
// ## What is *not* in this file
//
// Which rows, in which order, with which sub-label, and whether the footer
// counts honestly. All of that is `GrandLineWidgetDigest`, in the shared
// contract, under test. This file is layout: it takes a digest and draws it.
// That split is deliberate and it is the only reason F23 has meaningful
// coverage at all - the rendering half cannot be asserted in this
// environment (no signed bundle, so no widget host), while the half that can
// actually be *wrong* is ordinary pure logic.
//
// ## The refresh cadence
//
// A timeline of quarter-hour entries over the next four hours, then `.atEnd`.
// Not a single entry: "overdue" is a function of the clock, so a task due at
// 15:00 has to turn red at 15:00 without the app publishing anything - which
// is exactly what a timeline is for. Not one-minute entries either: WidgetKit
// budgets refreshes per day, and a minute-accurate widget spends that budget
// to move a label nobody is watching. The app's own publish (`WidgetCenter.
// reloadAllTimelines` on every store change) is what makes a *content* change
// appear immediately; the timeline only has to carry the passage of time.

import SwiftUI
import WidgetKit

struct TasksDueEntry: TimelineEntry {
    let date: Date
    let state: GrandLineWidgetDigest.State
    /// Task ids the captain has already ticked on the widget, still waiting
    /// for the app to apply them. See `CompleteTaskIntent`'s header.
    let pendingTaskIDs: Set<String>
}

struct TasksDueProvider: TimelineProvider {

    /// How many rows each family draws. Small takes three, which is what the
    /// mockup shows and what fits 168pt once the header and footer have their
    /// lines; medium takes four in two columns.
    static func rowLimit(for family: WidgetFamily) -> Int {
        family == .systemSmall ? 3 : 4
    }

    func placeholder(in context: Context) -> TasksDueEntry {
        TasksDueEntry(date: Date(), state: .ready(TasksDuePreviewData.snapshot), pendingTaskIDs: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (TasksDueEntry) -> Void) {
        // The widget gallery's own preview. Real data when there is any -
        // the gallery is where the captain decides whether to add this at
        // all, so showing their actual next three tasks is the honest pitch -
        // and the fixture when there is none, because a gallery tile reading
        // "Not available" is not a choice anyone can evaluate.
        let live = GrandLineWidgetDigest.load(from: GrandLineWidgetContainer.snapshotURL())
        if case .ready = live, !context.isPreview {
            completion(TasksDueEntry(date: Date(), state: live, pendingTaskIDs: pending()))
        } else {
            completion(TasksDueEntry(date: Date(), state: .ready(TasksDuePreviewData.snapshot), pendingTaskIDs: []))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TasksDueEntry>) -> Void) {
        let state = GrandLineWidgetDigest.load(from: GrandLineWidgetContainer.snapshotURL())
        let pendingIDs = pending()
        let now = Date()
        let entries = Self.refreshInstants(from: now).map { instant in
            TasksDueEntry(date: instant, state: state, pendingTaskIDs: pendingIDs)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    /// Quarter-hour boundaries for the next four hours, starting with now.
    static func refreshInstants(
        from now: Date,
        calendar: Calendar = .current,
        hours: Int = 4
    ) -> [Date] {
        var instants: [Date] = [now]
        let minute = calendar.component(.minute, from: now)
        let toNextQuarter = 15 - (minute % 15)
        guard var cursor = calendar.date(byAdding: .minute, value: toNextQuarter, to: now) else {
            return instants
        }
        cursor = calendar.date(bySetting: .second, value: 0, of: cursor) ?? cursor
        let end = calendar.date(byAdding: .hour, value: hours, to: now) ?? now
        while cursor < end {
            instants.append(cursor)
            guard let next = calendar.date(byAdding: .minute, value: 15, to: cursor) else { break }
            cursor = next
        }
        return instants
    }

    private func pending() -> Set<String> {
        let found = GrandLineWidgetAction.pending(directory: GrandLineWidgetContainer.actionsDirectory())
        return Set(found.requests.filter { $0.request.kind == .completeTask }.map(\.request.taskID))
    }
}

struct TasksDueWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GrandLineWidgetKind.tasksDue, provider: TasksDueProvider()) { entry in
            TasksDueWidgetView(entry: entry)
        }
        .configurationDisplayName("Tasks due")
        .description("What today needs, with a tick you can make from the desktop.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// The widget's entry point: reads the two environment values a widget host
/// supplies and hands them on as plain parameters.
///
/// The split is not decoration. `EnvironmentValues.widgetFamily` is
/// **read-only** - there is no `.environment(\.widgetFamily, .systemMedium)` -
/// so a view that reads it directly can only ever be rendered by a real
/// widget host, which is precisely the thing this environment cannot provide
/// (see `native/Widgets/README.md`). With the family as a parameter, the body
/// below renders under `ImageRenderer` at both families' real point sizes,
/// which is how this feature's layout was actually checked.
struct TasksDueWidgetView: View {
    let entry: TasksDueEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TasksDueBody(entry: entry, family: family, fallbackScheme: colorScheme)
    }
}

struct TasksDueBody: View {
    let entry: TasksDueEntry
    let family: WidgetFamily
    let fallbackScheme: ColorScheme

    var body: some View {
        content
            .grandLineWidgetSurface(palette)
    }

    private var palette: WidgetPalette {
        switch entry.state {
        case .ready(let snapshot): return .resolve(snapshot.appearance)
        case .locked: return .resolve(fallbackScheme)
        case .unavailable: return .resolve(fallbackScheme)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .unavailable(let reason):
            WidgetUnavailableView(reason: reason, palette: palette)
        case .locked:
            WidgetLockedView(palette: palette)
        case .ready(let snapshot):
            let digest = GrandLineWidgetDigest.taskDigest(
                from: snapshot,
                now: entry.date,
                limit: TasksDueProvider.rowLimit(for: family)
            )
            if family == .systemSmall {
                small(digest)
            } else {
                medium(digest)
            }
        }
    }

    // MARK: Small

    private func small(_ digest: GrandLineWidgetDigest.TaskDigest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WidgetMetrics.rowGap) {
                WidgetIdentityTile(systemName: "checkmark", gradient: WidgetDomainHue.taskGradient)
                Text("Today")
                    .font(WidgetType.tinyStrong)
                    .foregroundStyle(palette.muted)
                Spacer(minLength: 0)
                if digest.lateCount > 0 {
                    Text("\(digest.lateCount) late")
                        .font(WidgetType.tinyStrong)
                        .foregroundStyle(palette.badText)
                }
            }
            if digest.rows.isEmpty {
                emptyDay
            } else {
                VStack(alignment: .leading, spacing: WidgetMetrics.rowGap) {
                    ForEach(digest.rows) { row in
                        TaskCheckRow(row: row, palette: palette, isPending: entry.pendingTaskIDs.contains(row.id), showsDetail: false)
                    }
                }
                .padding(.top, 10)
                Spacer(minLength: 0)
            }
            footer(digest)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Medium

    private func medium(_ digest: GrandLineWidgetDigest.TaskDigest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WidgetMetrics.rowGap) {
                WidgetIdentityTile(systemName: "checkmark", gradient: WidgetDomainHue.taskGradient)
                Text(GrandLineWidgetDigest.headline(for: entry.date))
                    .font(WidgetType.tinyStrong)
                    .foregroundStyle(palette.muted)
                Spacer(minLength: 0)
                if digest.lateCount > 0 {
                    Text("\(digest.lateCount) late")
                        .font(WidgetType.tinyStrong)
                        .foregroundStyle(palette.badText)
                }
            }
            if digest.rows.isEmpty {
                emptyDay
            } else {
                // Two columns, as the mockup draws it. A `LazyVGrid` rather
                // than two `VStack`s so a three-row day fills left-to-right
                // instead of leaving a whole empty column.
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(digest.rows) { row in
                        TaskCheckRow(row: row, palette: palette, isPending: entry.pendingTaskIDs.contains(row.id), showsDetail: true)
                    }
                }
                .padding(.top, 10)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if let followUps = digest.followUpSummary {
                    Text(followUps)
                        .font(WidgetType.tiny)
                        .foregroundStyle(palette.muted)
                }
                Spacer(minLength: 0)
                Text(stamp(digest))
                    .font(WidgetType.tiny)
                    .foregroundStyle(digest.isStale ? palette.warnText : palette.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Shared pieces

    /// A genuinely empty day, which is a different claim from "not
    /// available" and reads differently on purpose (GL-14).
    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nothing due")
                .font(WidgetType.row)
                .foregroundStyle(palette.ink)
            Text("No task is due in the next \(GrandLineWidgetDigest.horizonDays) days.")
                .font(WidgetType.tiny)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func footer(_ digest: GrandLineWidgetDigest.TaskDigest) -> some View {
        HStack(spacing: 5) {
            Text(digest.openSummary)
                .font(WidgetType.tiny)
                .foregroundStyle(palette.muted)
            Spacer(minLength: 0)
            if !entry.pendingTaskIDs.isEmpty {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(palette.warnText)
            }
        }
    }

    /// "updated 14:20", or the snapshot's own date once it is stale enough
    /// that a time of day would imply it was today (GL-14's subtler half -
    /// see `GrandLineWidgetDigest.staleAfter`).
    private func stamp(_ digest: GrandLineWidgetDigest.TaskDigest) -> String {
        let formatter = DateFormatter()
        if digest.isStale {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            return "as of \(formatter.string(from: digest.generatedAt))"
        }
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return "updated \(formatter.string(from: digest.generatedAt))"
    }
}

/// One task row: a tappable checkbox, the title, and - on medium - the
/// digest's own sub-label.
struct TaskCheckRow: View {
    let row: GrandLineWidgetDigest.TaskRow
    let palette: WidgetPalette
    let isPending: Bool
    let showsDetail: Bool

    var body: some View {
        HStack(alignment: .top, spacing: WidgetMetrics.rowGap) {
            Button(intent: CompleteTaskIntent(taskID: row.id)) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(boxColor, lineWidth: 1.5)
                    .frame(width: WidgetMetrics.checkbox, height: WidgetMetrics.checkbox)
                    .overlay {
                        if isPending {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(palette.muted)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isPending)
            .padding(.top, 2)
            .accessibilityLabel(isPending ? "\(row.title), ticked, applies when the app opens" : "Complete \(row.title)")

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(WidgetType.row)
                    .foregroundStyle(isPending ? palette.faint : palette.ink)
                    .strikethrough(isPending, color: palette.faint)
                    .lineLimit(showsDetail ? 1 : 2)
                if showsDetail {
                    Text(isPending ? "applies when the app opens" : row.detail)
                        .font(WidgetType.tiny)
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var boxColor: Color {
        if isPending { return palette.faint }
        return row.isOverdue ? palette.badText : palette.hair
    }

    private var detailColor: Color {
        if isPending { return palette.warnText }
        return row.isOverdue ? palette.badText : palette.muted
    }
}

/// The gallery/placeholder fixture.
///
/// The reviewed mockup's own four rows, so the tile a captain sees in the
/// widget gallery is the thing that was signed off. Dated **relative to
/// now** rather than to fixed days, because a fixture pinned to September
/// 2026 would render every row "overdue" a week later - which would look
/// exactly like a bug in the widget.
enum TasksDuePreviewData {
    static var snapshot: GrandLineWidgetSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ offset: Int, hour: Int? = nil) -> Date? {
            guard let base = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            guard let hour else { return base }
            return calendar.date(byAdding: .hour, value: hour, to: base)
        }
        return GrandLineWidgetSnapshot(
            generatedAt: Date(),
            availability: .ready,
            appearance: .dark,
            tasks: [
                .init(id: "p1", title: "Renew wildcard TLS certificate", priority: "high",
                      dueAt: day(-1, hour: 9), hasDueTime: true),
                .init(id: "p2", title: "Rotate the prod bastion SSH keys", priority: "high",
                      dueAt: day(0), hasDueTime: false),
                .init(id: "p3", title: "Standup notes", priority: "normal",
                      dueAt: day(0), hasDueTime: false, recurrenceSummary: "Every weekday"),
                .init(id: "p4", title: "Review OTel Helm values", priority: "normal",
                      dueAt: day(1), hasDueTime: false)
            ],
            openTaskCount: 6,
            pendingFollowUpCount: 2
        )
    }
}

// MARK: - Previews
//
// `#Preview` is the only rendering check available for this file in this
// environment: the extension cannot be loaded by a real widget host until the
// app has a Team ID (see `native/Widgets/README.md`), so there is no
// screenshot to take and no `cacheDisplay` substitute either - a widget is
// not an `NSView` this repo's usual off-screen probe can reach. These
// previews compile, and they are what a captain with Xcode open can look at.

#Preview("Tasks · small", as: .systemSmall) {
    TasksDueWidget()
} timeline: {
    TasksDueEntry(date: Date(), state: .ready(TasksDuePreviewData.snapshot), pendingTaskIDs: [])
    TasksDueEntry(date: Date(), state: .ready(TasksDuePreviewData.snapshot), pendingTaskIDs: ["p2"])
    TasksDueEntry(date: Date(), state: .unavailable(.neverPublished), pendingTaskIDs: [])
    TasksDueEntry(date: Date(), state: .locked, pendingTaskIDs: [])
}

#Preview("Tasks · medium", as: .systemMedium) {
    TasksDueWidget()
} timeline: {
    TasksDueEntry(date: Date(), state: .ready(TasksDuePreviewData.snapshot), pendingTaskIDs: [])
    TasksDueEntry(
        date: Date(),
        state: .ready(GrandLineWidgetSnapshot(generatedAt: Date(), availability: .ready, appearance: .light,
                                              tasks: TasksDuePreviewData.snapshot.tasks,
                                              openTaskCount: 6, pendingFollowUpCount: 2)),
        pendingTaskIDs: []
    )
}
