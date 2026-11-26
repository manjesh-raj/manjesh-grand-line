// Grand Line - native macOS app.
//
// D-02 of full review 4: a dev server's log, as DevOps Hub's project page
// shows it - "pid 48211 · stdout and stderr" above the last lines of output
// in a monospaced, read-only text view that follows the end unless the
// captain has scrolled up to read.

import AppKit

final class DevServerLogView: NSView {

    private let headLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var lastCount = -1
    private var lastDropped = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        headLabel.font = HelmType.caption()
        headLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headLabel)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: HelmType.scaled(12), weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            headLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            headLabel.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            scroll.topAnchor.constraint(equalTo: headLabel.bottomAnchor, constant: HelmMetrics.s2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s2),
        ])
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// "pid 48211 · stdout and stderr", or the run's end.
    static func headline(pid: pid_t?, dropped: Int) -> String {
        var parts = [pid.map { "pid \($0)" } ?? "Not running", "stdout and stderr"]
        if dropped > 0 { parts.append("earlier lines dropped, the last \(DevServerLog.logLineLimit) kept") }
        return parts.joined(separator: " \u{00B7} ")
    }

    func show(_ supervisor: DevServerSupervisor?) {
        let log = supervisor?.log ?? DevServerLog()
        headLabel.stringValue = Self.headline(pid: supervisor?.pid, dropped: log.dropped)
        guard log.lines.count != lastCount || log.dropped != lastDropped else { return }
        lastCount = log.lines.count
        lastDropped = log.dropped
        let atEnd = scroll.contentView.bounds.maxY >= textView.frame.height - 24
        textView.string = log.lines.joined(separator: "\n")
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    var renderedText: String { textView.string }

    func applyTheme(_ theme: HelmTheme) {
        // The one card surface (the component index), not a hand-rolled one.
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: HelmMetrics.rCard)
        headLabel.textColor = HelmTheme.mutedInk(theme)
        textView.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
    }
}
