// Grand Line - native macOS app.
//
// D-05 of full review 4: export Incident mode's timeline, the commands sent
// and the Log Analyzer's findings as one Markdown postmortem draft.
//
// **How this differs from "End Incident → generate postmortem".** That action
// hands the incident's aggregated transcript to the AI postmortem generator
// (`SRELeadPostmortem`), which writes judgement: a summary, a root cause and
// actions. This export writes facts only. Every line in it comes from the
// incident record or from a saved Log Analyzer investigation, and the parts
// that need a person (summary, impact, root cause, action items) are left as
// prompts. It needs no AI, no network, and works on an active incident as
// well as an ended one, which is why it sits beside the End button rather
// than replacing it.
//
// **Redaction is always on.** The incident record already stores redacted
// command text and one-line titles, but an SRE Lead question or a note is
// free text the captain typed, so the whole draft goes through
// `LogRedactor` once more on the way out. There is no option to turn it off,
// which is what the mock-up's "Always on" row says.

import AppKit

// MARK: - The draft

enum IncidentPostmortemExport {

    /// What the captain chose to put in the draft. Every section defaults on.
    struct Options: Equatable {
        var timeline = true
        var commands = true
        var findings = true
        var runbookRuns = true
    }

    /// Where the draft goes.
    enum Destination: String, CaseIterable {
        case postmortems
        case file
        case copy

        var title: String {
            switch self {
            case .postmortems: return "To Postmortems"
            case .file: return "Markdown file"
            case .copy: return "Copy"
            }
        }
    }

    /// One Log Analyzer finding the draft can quote, resolved from a saved
    /// investigation the incident references. Built by the caller so this
    /// file never reads a store.
    struct Finding: Equatable {
        var investigationTitle: String
        var likelyCause: String?
        var confidence: String?
        var findings: [String]
    }

    /// The counts the options panel shows beside each section.
    struct Counts: Equatable {
        var timeline: Int
        var commands: Int
        var findings: Int
        var runbookRuns: Int
    }

    static func counts(for incident: Incident, findings: [Finding]) -> Counts {
        Counts(timeline: incident.entries.count,
               commands: incident.entries.filter { $0.kind == .command }.count,
               findings: findings.count,
               runbookRuns: incident.entries.filter { $0.kind == .runbook }.count)
    }

    /// The investigations an incident references, resolved through `lookup`.
    /// An investigation that cannot be read, or was never analysed, is left
    /// out rather than shown as an empty finding (GL-14).
    static func findings(for incident: Incident, lookup: (String) -> LogInvestigation?) -> [Finding] {
        var seen = Set<String>()
        var out: [Finding] = []
        for entry in incident.entries where entry.kind == .logCapture {
            guard let reference = entry.reference, seen.insert(reference).inserted,
                  let investigation = lookup(reference), let analysis = investigation.analysis else { continue }
            let cause = analysis.ai?.rootCause
            out.append(Finding(investigationTitle: investigation.title,
                               likelyCause: cause?.summary,
                               confidence: cause.map { $0.confidence.rawValue },
                               findings: analysis.findings.prefix(5).map { finding in
                                   finding.detail.isEmpty ? finding.title : "\(finding.title): \(finding.detail)"
                               }))
        }
        return out
    }

    /// The draft itself. Pure: the same incident, findings and options always
    /// give the same text, which is what the self-test pins.
    static func markdown(for incident: Incident,
                         findings: [Finding],
                         options: Options,
                         timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        lines.append("# Postmortem: \(incident.title)")
        lines.append("")
        lines.append("\(incident.id) \u{00B7} \(window(for: incident, timeZone: timeZone)) \u{00B7} \(incident.hostLabel) \u{00B7} draft")
        lines.append("")
        lines.append("## Summary")
        lines.append("")
        lines.append("_What happened, in two sentences._")
        lines.append("")
        lines.append("## Impact")
        lines.append("")
        lines.append("_Who noticed, for how long, and how badly._")

        if options.timeline {
            lines.append("")
            lines.append("## Timeline")
            lines.append("")
            if incident.entries.isEmpty {
                lines.append("_Nothing attached to this incident._")
            } else {
                lines.append("| Time | Event |")
                lines.append("|-------|-------|")
                for entry in incident.entries {
                    lines.append("| \(clock(entry.at, timeZone: timeZone)) | \(tableCell(timelineText(entry))) |")
                }
            }
        }

        if options.commands {
            let commands = incident.entries.filter { $0.kind == .command }
            lines.append("")
            lines.append("## Commands")
            lines.append("")
            if commands.isEmpty {
                lines.append("_No commands were sent from Grand Line during this incident._")
            } else {
                lines.append("```")
                for command in commands { lines.append(command.title) }
                lines.append("```")
            }
        }

        if options.findings {
            lines.append("")
            lines.append("## Log Analyzer findings")
            lines.append("")
            if findings.isEmpty {
                lines.append("_No saved Log Analyzer investigation is attached._")
            } else {
                for finding in findings {
                    lines.append("### \(finding.investigationTitle)")
                    lines.append("")
                    if let cause = finding.likelyCause {
                        let confidence = finding.confidence.map { " (\($0) confidence)" } ?? ""
                        lines.append("- **Likely cause:** \(cause)\(confidence)")
                    }
                    for item in finding.findings { lines.append("- \(item)") }
                    lines.append("")
                }
                if lines.last == "" { lines.removeLast() }
            }
        }

        if options.runbookRuns {
            let runs = incident.entries.filter { $0.kind == .runbook }
            lines.append("")
            lines.append("## Runbook runs")
            lines.append("")
            if runs.isEmpty {
                lines.append("_No runbook ran during this incident._")
            } else {
                for run in runs {
                    let detail = run.detail.map { " \u{2014} \($0)" } ?? ""
                    lines.append("- \(clock(run.at, timeZone: timeZone)) \(run.title)\(detail)")
                }
            }
        }

        lines.append("")
        lines.append("## Root cause")
        lines.append("")
        lines.append("_To fill: what made this possible, not who._")
        lines.append("")
        lines.append("## Action items")
        lines.append("")
        lines.append("- [ ] _to fill_")
        lines.append("")
        return LogRedactor.redact(lines.joined(separator: "\n")).text
    }

    /// "25 Nov 2026 · 10:41 to 11:15 IST", or "... 10:41, still active".
    static func window(for incident: Incident, timeZone: TimeZone) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_GB")
        day.timeZone = timeZone
        day.dateFormat = "d MMM yyyy"
        let zone = timeZone.abbreviation(for: incident.startedAt) ?? timeZone.identifier
        let start = clock(incident.startedAt, timeZone: timeZone)
        guard let end = incident.endedAt else {
            return "\(day.string(from: incident.startedAt)) \u{00B7} \(start) \(zone), still active"
        }
        return "\(day.string(from: incident.startedAt)) \u{00B7} \(start) to \(clock(end, timeZone: timeZone)) \(zone)"
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// One timeline row's wording: the kind first, so a reader of the table
    /// can tell an SRE Lead turn from a command without the card's colours.
    static func timelineText(_ entry: IncidentTimelineEntry) -> String {
        switch entry.kind {
        case .command: return "Command: `\(entry.title)`"
        case .note: return "Note: \(entry.title)"
        default:
            if let detail = entry.detail, !detail.isEmpty { return "\(entry.title) (\(detail))" }
            return entry.title
        }
    }

    /// A pipe would end the Markdown table cell early.
    static func tableCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    /// The file name a Markdown export suggests: "INC-014-postmortem-draft.md".
    static func suggestedFileName(for incident: Incident) -> String {
        "\(incident.id)-postmortem-draft.md"
    }
}

// MARK: - The options panel

/// The mock-up's state 2, "Export · INC-014 · Postmortem draft": a row per
/// section with its count and a toggle, the redaction row that cannot be
/// turned off, the three destinations and "Create draft". It is shown inside
/// the incident card's popover in place of the timeline, so it inherits the
/// card's lock-gate registration and needs no window of its own.
final class IncidentExportPanel: NSView {

    var onCancel: (() -> Void)?
    var onCreate: ((IncidentPostmortemExport.Options, IncidentPostmortemExport.Destination) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let kickerLabel = NSTextField(labelWithString: "Postmortem draft")
    private let rowsStack = NSStackView()
    private var toggles: [String: HelmToggle] = [:]
    private var countLabels: [String: NSTextField] = [:]
    private var rowLabels: [NSTextField] = []
    private let redactLabel = NSTextField(labelWithString: "Redact secrets and tokens")
    private let redactValue = NSTextField(labelWithString: "Always on")
    private let destination = HelmSegmentedTabs(
        items: IncidentPostmortemExport.Destination.allCases.map { .init(id: $0.rawValue, title: $0.title) },
        selected: IncidentPostmortemExport.Destination.postmortems.rawValue,
        size: .compact)
    private let cancelButton = HelmButton(title: "Back", variant: .quiet, size: .small)
    private let createButton = HelmButton(title: "Create draft", variant: .primary, size: .small,
                                          symbol: "doc.badge.plus")
    private var selectedDestination: IncidentPostmortemExport.Destination = .postmortems
    private var dividers: [NSView] = []

    private static let sections: [(id: String, title: String)] = [
        ("timeline", "Timeline"),
        ("commands", "Commands sent"),
        ("findings", "Log Analyzer findings"),
        ("runbookRuns", "Runbook runs"),
    ]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        titleLabel.font = HelmType.sectionTitle()
        kickerLabel.font = HelmType.caption()
        let header = NSStackView(views: [titleLabel, kickerLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 1

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        for section in Self.sections {
            let toggle = HelmToggle()
            toggle.isOn = true
            toggles[section.id] = toggle
            let count = NSTextField(labelWithString: "")
            count.font = HelmType.caption()
            countLabels[section.id] = count
            addRow(makeRow(title: section.title, trailing: [count, toggle]))
        }
        redactLabel.font = HelmType.body()
        redactValue.font = HelmType.caption()
        addRow(makeRow(label: redactLabel, trailing: [redactValue]))

        destination.onSelect = { [weak self] id in
            self?.selectedDestination = IncidentPostmortemExport.Destination(rawValue: id) ?? .postmortems
        }

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        createButton.target = self
        createButton.action = #selector(createTapped)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [cancelButton, spacer, createButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        buttons.spacing = HelmMetrics.s2

        let stack = NSStackView(views: [header, rowsStack, destination, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func addRow(_ row: NSView) {
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func makeRow(title: String, trailing: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = HelmType.body()
        return makeRow(label: label, trailing: trailing)
    }

    private func makeRow(label: NSTextField, trailing: [NSView]) -> NSView {
        rowLabels.append(label)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        for view in trailing {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let row = NSStackView(views: [label] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        // AGENTS.md gotcha (10).
        row.distribution = .fill
        row.spacing = HelmMetrics.s3
        row.edgeInsets = NSEdgeInsets(top: HelmMetrics.s2, left: 0, bottom: HelmMetrics.s2, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        dividers.append(divider)
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(row)
        wrap.addSubview(divider)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            row.topAnchor.constraint(equalTo: wrap.topAnchor),
            divider.topAnchor.constraint(equalTo: row.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    func configure(incident: Incident, counts: IncidentPostmortemExport.Counts, theme: HelmTheme) {
        titleLabel.stringValue = "Export \u{00B7} \(incident.id)"
        let values = ["timeline": counts.timeline, "commands": counts.commands,
                      "findings": counts.findings, "runbookRuns": counts.runbookRuns]
        let nouns = ["timeline": ("event", "events"), "commands": ("command", "commands"),
                     "findings": ("finding", "findings"), "runbookRuns": ("run", "runs")]
        for (id, label) in countLabels {
            let n = values[id] ?? 0
            let noun = nouns[id].map { n == 1 ? $0.0 : $0.1 } ?? ""
            label.stringValue = "\(n) \(noun)"
        }
        applyTheme(theme)
    }

    var options: IncidentPostmortemExport.Options {
        IncidentPostmortemExport.Options(timeline: toggles["timeline"]?.isOn ?? true,
                                         commands: toggles["commands"]?.isOn ?? true,
                                         findings: toggles["findings"]?.isOn ?? true,
                                         runbookRuns: toggles["runbookRuns"]?.isOn ?? true)
    }

    func applyTheme(_ theme: HelmTheme) {
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        kickerLabel.textColor = HelmTheme.mutedInk(theme)
        for label in rowLabels { label.textColor = HelmTheme.nsColor(theme.chromeInkHex) }
        for label in countLabels.values { label.textColor = HelmTheme.mutedInk(theme) }
        redactValue.textColor = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.dividerAlpha)
        for divider in dividers { divider.layer?.backgroundColor = line.cgColor }
        destination.applyTheme(theme)
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func createTapped() { onCreate?(options, selectedDestination) }

    #if FM_SELFTESTS
    func debugSetSection(_ id: String, on: Bool) { toggles[id]?.isOn = on }
    func debugSelectDestination(_ destination: IncidentPostmortemExport.Destination) {
        selectedDestination = destination
    }
    func debugCreate() { createButton.performClick(nil) }
    var debugCountTexts: [String: String] { countLabels.mapValues(\.stringValue) }
    #endif
}
