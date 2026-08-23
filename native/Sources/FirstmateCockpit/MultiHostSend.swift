// Manjesh Grand Line - native macOS app.
//
// F9 (v1) - multi-host command execution. The decision layer behind the
// DevOps Command Library's "Send to…" action: which saved hosts a tag filter
// matches, which of them the captain has actually ticked, whether the command
// is even sendable, and - the part that carries the safety property - the
// order in which the risk gate and the delivery run, once per selected host.
//
// **Scope is v1 only, deliberately.** The production review's own F9 entry
// splits this feature in two: v1 (Medium complexity - "results land as one tab
// per host") and a later combined/aggregated result view (High complexity),
// whose stated dependency is "Block View Stage 1 for result aggregation …
// blocks give clean per-command output capture". Block View is at Stage 0
// (opt-in, manual refresh) and Stage 1 is itself blocked on Stage 0 surviving
// real captain use - see AGENTS.md's "Block view" section. So nothing here
// captures, aggregates, or compares per-host output: each selected host gets
// its own real dedicated page and its own real terminal tab, exactly as a
// single-host send already does, N times.
//
// **This file is AppKit-free on purpose.** The picker UI lives in
// `MultiHostSendPicker.swift` and the wiring in `main.swift`; everything that
// can be wrong in a way that matters - a preselected host, a gate that fires
// once for three hosts, a half-substituted template reaching a terminal - is
// decided here, where `FM_RUN_MULTI_HOST_SEND_TESTS=1` can drive it without a
// window, a modal alert, or a real ssh connection.

import Foundation

// MARK: - Filtering

/// The mockup's filter pill row: one pill per distinct tag across the saved
/// hosts, plus a trailing "All hosts" pill.
///
/// Deliberately single-select (a radio row), not the Hosts page's
/// multi-select tag chips: the mockup shows exactly one pill active at a time
/// ("tag: PROD (3)"), and "which hosts am I looking at right now" needs to be
/// unambiguous on a screen whose next button sends a command to all of them.
enum MultiHostSendFilter: Equatable, Hashable {
    case allHosts
    case tag(String)
}

/// One rendered pill: its filter, its title ("tag: PROD (3)" / "All hosts
/// (7)") and how many saved hosts it matches.
struct MultiHostSendFilterOption: Equatable {
    let filter: MultiHostSendFilter
    let title: String
    let count: Int
}

// MARK: - Readiness

/// Whether a command can be sent at all, asked of the real generator rather
/// than re-derived from the parameter list - the same rule, and the same
/// reason, as F5's `UnifiedSearchCommandProvider.isReadyToRunWithoutInput`:
/// it cannot drift from what the detail pane actually renders.
enum MultiHostSendReadiness: Equatable {
    /// Every `{{token}}` resolved. The payload is the exact text every
    /// selected host will receive - one substitution, applied identically to
    /// all of them, never re-derived per host.
    case ready(String)
    /// At least one token is still unfilled. Named so the refusal can say
    /// which field to fill rather than "something is missing".
    case needsParameters([String])
}

// MARK: - Outcome

/// What a send actually did, for the caller's toast and for the self-test.
struct MultiHostSendOutcome: Equatable {
    /// Hosts the gate was shown for *and* accepted, in selection order.
    var sent: [UUID] = []
    /// Hosts whose own risk-gate confirmation the captain declined.
    var declined: [UUID] = []
    /// How many times the risk gate was invoked. Exactly `sent.count +
    /// declined.count` for a risk-bearing command, and 0 for a read-only one
    /// (the gate's `.readOnly` case proceeds without an alert - it is invoked,
    /// it simply does not interrupt, so this counts invocations rather than
    /// visible alerts).
    var gateInvocations: Int = 0

    var isEmpty: Bool { sent.isEmpty && declined.isEmpty }
}

// MARK: - Selection

/// The picker's selection state.
///
/// **Nothing here can preselect a host**, and that is structural rather than
/// a habit: `init` takes no selected set, `setFilter` never adds to one, and
/// there is no "select all" affordance to grow one either. The review's own
/// security line for F9 is that the picker must "default to opt-in host
/// selection, never 'all hosts' preselected", and the mockup repeats it as
/// on-screen copy. A captain ticks each host they mean, every time.
struct MultiHostSendSelection {
    /// Every saved host, in store order.
    let hosts: [Host]
    private(set) var filter: MultiHostSendFilter
    /// Ticked host ids. Starts empty and is only ever grown by an explicit
    /// `toggle`.
    private(set) var selected: Set<UUID> = []

    init(hosts: [Host], filter: MultiHostSendFilter = .allHosts) {
        self.hosts = hosts
        self.filter = filter
    }

    /// The pills, tags first (sorted for a stable row), "All hosts" last -
    /// the mockup's own order.
    var filterOptions: [MultiHostSendFilterOption] {
        let tags = Set(hosts.flatMap(\.tags)).sorted()
        var options = tags.map { tag in
            MultiHostSendFilterOption(
                filter: .tag(tag),
                title: "tag: \(tag) (\(Self.hosts(hosts, matching: .tag(tag)).count))",
                count: Self.hosts(hosts, matching: .tag(tag)).count
            )
        }
        options.append(MultiHostSendFilterOption(filter: .allHosts,
                                                 title: "All hosts (\(hosts.count))",
                                                 count: hosts.count))
        return options
    }

    /// The hosts the active filter shows.
    var visibleHosts: [Host] { Self.hosts(hosts, matching: filter) }

    /// Case-insensitive tag match, so a host tagged `prod` is found by a
    /// `PROD` pill - tags are free text on `Host` and nothing normalises
    /// their case at entry.
    static func hosts(_ hosts: [Host], matching filter: MultiHostSendFilter) -> [Host] {
        switch filter {
        case .allHosts:
            return hosts
        case .tag(let tag):
            let needle = tag.lowercased()
            return hosts.filter { $0.tags.contains { $0.lowercased() == needle } }
        }
    }

    /// Switching filters never changes what is ticked - a host selected under
    /// `PROD` stays selected when the captain looks at `STAGING`, and is still
    /// in the send. Silently dropping it would make the count in the button
    /// disagree with what actually gets sent; silently *adding* the newly
    /// visible hosts would be the preselect this feature must never do.
    mutating func setFilter(_ newFilter: MultiHostSendFilter) {
        filter = newFilter
    }

    mutating func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func isSelected(_ id: UUID) -> Bool { selected.contains(id) }

    /// Selected hosts in store order - so the gate runs, and the tabs open,
    /// in the order the captain sees them listed rather than `Set` order.
    var selectedHosts: [Host] { hosts.filter { selected.contains($0.id) } }

    var selectedCount: Int { selected.count }

    /// How many ticked hosts the active filter is currently showing. The
    /// difference against `selectedCount` is what the picker reports as
    /// "N selected hosts aren't shown by this filter" - a ticked host stays
    /// ticked across a filter change, so without that line the button's count
    /// can exceed the boxes on screen with nothing explaining why.
    var visibleSelectedCount: Int { visibleHosts.filter { selected.contains($0.id) }.count }

    /// The mockup's primary button. Disabled at zero, which is also the state
    /// the sheet opens in.
    var sendButtonTitle: String {
        selectedCount == 1 ? "Send to 1 host" : "Send to \(selectedCount) hosts"
    }

    var canSend: Bool { selectedCount > 0 }
}

// MARK: - Execution

/// Runs a multi-host send: for each selected host, the risk gate, then - only
/// if it was accepted - the delivery.
///
/// Both halves are injected closures rather than direct calls, for one reason
/// each. `confirm` is a blocking `NSAlert.runModal()` in production
/// (`CommandRiskConfirmation.confirm`, the app's *one* gate definition - F5
/// extracted it so the palette could not drift into a lookalike, and this is
/// its third caller, not a fourth definition), which a headless self-test can
/// neither show nor answer; `deliver` ends in a real ssh connection and a real
/// keystroke into a real PTY. Injecting both is what lets
/// `MultiHostSendSelfTest` assert the property that actually matters here -
/// **the gate fires once per host, and no host is delivered to without its own
/// confirmation having been accepted first** - by counting, rather than by
/// describing it in a comment.
struct MultiHostSendExecutor {
    /// `(command, generatedText, host, context, proceed)`, where `context` is
    /// the "Sending to Prod Bastion (2 of 3)." line the gate appends to its
    /// own text. `proceed` runs iff the captain accepted *this host's*
    /// confirmation.
    let confirm: (DevOpsCommand, String, Host, String, () -> Void) -> Void
    /// `(host, generatedText)` - connect (or reuse) that host's dedicated page
    /// and type the command into it.
    let deliver: (Host, String) -> Void

    /// Sends `command` to `hosts`, one gate and one delivery per host.
    ///
    /// Returns `nil` when the command is not sendable at all - a still-unfilled
    /// `{{token}}` - in which case **nothing is gated and nothing is
    /// delivered, for any host**. F5's rule ("sending a half-substituted
    /// template would be worse than useless, and inventing a value would be a
    /// lie") does not weaken because several hosts are selected; if anything
    /// it matters more, since the mistake would land N times.
    func send(command: DevOpsCommand, values: [String: String], to hosts: [Host]) -> MultiHostSendOutcome? {
        guard case .ready(let text) = MultiHostSend.readiness(for: command, values: values) else { return nil }
        var outcome = MultiHostSendOutcome()
        for (index, host) in hosts.enumerated() {
            var accepted = false
            outcome.gateInvocations += 1
            let context = MultiHostSend.confirmationContext(hostLabel: host.label,
                                                            index: index, total: hosts.count)
            confirm(command, text, host, context) { accepted = true }
            if accepted {
                outcome.sent.append(host.id)
                deliver(host, text)
            } else {
                outcome.declined.append(host.id)
            }
        }
        return outcome
    }
}

// MARK: - Entry points

enum MultiHostSend {
    /// The one readiness rule, shared by the "Send to…" button (which refuses
    /// to even open the picker without it) and by the executor (which re-asks
    /// at send time). Two checks of the same function, in the shape F4's merge
    /// gate uses: the first is what the captain sees, the second is what
    /// actually guards the terminal.
    static func readiness(for command: DevOpsCommand, values: [String: String]) -> MultiHostSendReadiness {
        let text = command.generatedCommand(values: values)
        guard text.contains("{{") else { return .ready(text) }
        let unfilled = command.effectiveParameters
            .map(\.name)
            .filter { text.contains("{{\($0)}}") || text.contains("{{ \($0) }}") }
        return .needsParameters(unfilled)
    }

    /// The line the risk gate appends when it is running as one of several -
    /// "Sending to Prod Bastion (2 of 3)."
    ///
    /// Without it, three consecutive identical alerts read as one alert
    /// misfiring rather than as three separate per-host decisions, which
    /// undermines the very property the per-host gate exists to give. A
    /// single-host selection gets the host name with no index, since "(1 of
    /// 1)" is noise.
    static func confirmationContext(hostLabel: String, index: Int, total: Int) -> String {
        total > 1
            ? "Sending to \(hostLabel) (\(index + 1) of \(total))."
            : "Sending to \(hostLabel)."
    }

    /// The refusal message for a command that still needs input, named field
    /// by field so the captain knows what to fill on the form they are already
    /// looking at.
    static func unfilledParameterMessage(_ names: [String]) -> String {
        guard !names.isEmpty else { return "Fill in this command's parameters before sending it." }
        let list = names.joined(separator: ", ")
        return names.count == 1
            ? "Fill in \u{201C}\(list)\u{201D} before sending this command to any host."
            : "Fill in \(list) before sending this command to any host."
    }

    /// The toast after a send. Names the declined count rather than hiding it:
    /// the gate is per host, so "sent to 2 of 3" is a real outcome a captain
    /// produced on purpose and should see confirmed.
    static func resultMessage(_ outcome: MultiHostSendOutcome) -> String {
        let sent = outcome.sent.count
        let declined = outcome.declined.count
        if sent == 0 { return "Nothing sent - every host's confirmation was cancelled" }
        let sentPart = sent == 1 ? "Sent to 1 host" : "Sent to \(sent) hosts"
        return declined == 0 ? sentPart : "\(sentPart) \u{00B7} \(declined) cancelled"
    }
}
