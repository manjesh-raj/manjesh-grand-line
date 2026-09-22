// Manjesh Grand Line - the WidgetKit extension.
//
// The pieces both widgets share: the identity tile in the header, the type
// scale, and the two states that are not "here is your data" - GL-14's
// `.unavailable` and the lock.
//
// ## The type scale
//
// Not `HelmType.scaled`. That routes through `AppSettings.shared.fontSize`,
// which is a captain preference living in the app's `UserDefaults` domain -
// a second process cannot read it, and a widget's canvas is 168pt square, so
// a captain who scaled the app's chrome up would get a widget that clipped
// rather than one that scaled. The sizes below are the reviewed mockup's own
// (9.5 / 11.5 / 14), in the system face the app renders in, and they are the
// one place a widget's type is decided.

import SwiftUI
import WidgetKit

enum WidgetType {
    static let kicker = Font.system(size: 9.5, weight: .semibold)
    static let tiny = Font.system(size: 9.5, weight: .regular)
    static let tinyStrong = Font.system(size: 9.5, weight: .semibold)
    static let row = Font.system(size: 11.5, weight: .semibold)
    static let body = Font.system(size: 11.5, weight: .regular)
    static let title = Font.system(size: 14, weight: .bold)
}

enum WidgetMetrics {
    static let cardRadius: CGFloat = 14
    static let tile: CGFloat = 18
    static let tileRadius: CGFloat = 6
    static let checkbox: CGFloat = 12
    static let rowGap: CGFloat = 7
    static let padding: CGFloat = 13
}

/// The rounded gradient square every destination in this app is identified
/// by - the same shape as the top bar's `tb-icon`, at widget scale.
struct WidgetIdentityTile: View {
    let systemName: String
    let gradient: [Color]

    var body: some View {
        RoundedRectangle(cornerRadius: WidgetMetrics.tileRadius, style: .continuous)
            .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: WidgetMetrics.tile, height: WidgetMetrics.tile)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// GL-14, drawn.
///
/// "Unknown is never rendered as zero" is the most-cited rule in this repo's
/// own invariant list, and a widget is where it is easiest to break: an empty
/// `VStack` reads exactly like a finished day. So the absence of data has its
/// own headline, its own explanation and its own muted register - it never
/// borrows the "nothing due" wording, which belongs to a snapshot that really
/// says so.
struct WidgetUnavailableView: View {
    let reason: GrandLineWidgetDigest.Unavailable
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.warnText)
                Text(reason.headline)
                    .font(WidgetType.row)
                    .foregroundStyle(palette.ink)
            }
            Text(reason.detail)
                .font(WidgetType.tiny)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The locked state. Deliberately the app's own mark and one word - the same
/// answer `ShiftMenuBarController` gives for the same reason: a count is a
/// real disclosure about the captain's day, readable by whoever is standing
/// at the machine.
struct WidgetLockedView: View {
    let palette: WidgetPalette

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "lock.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.muted)
            Text("Locked")
                .font(WidgetType.row)
                .foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The app's card surface, as the widget's own background.
///
/// `containerBackground(for: .widget)` is required on macOS 14 - a widget
/// that paints its own background inside the content view gets it clipped to
/// the wrong shape and, on some hosts, drawn over.
extension View {
    func grandLineWidgetSurface(_ palette: WidgetPalette) -> some View {
        self
            .padding(WidgetMetrics.padding)
            .containerBackground(for: .widget) { palette.card }
    }
}
