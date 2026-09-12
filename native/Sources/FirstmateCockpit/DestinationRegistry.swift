// Manjesh Grand Line - native macOS app.
//
// GL-37 (production review section 6): the destination table, and
// lazy-mount-with-permanent-retention for everything that does not own a
// live process.
//
// **What this replaces.** Adding a body destination used to mean editing six
// hand-maintained sites in lockstep: the `RailDestination` case, a stored
// property on `AppShellController`, an `addChild` line, the `embed(...)`
// array, a `case` in `show(_:)`, and a line in `hideAllDestinations()`.
// Missing any one of them fails in a different, non-obvious way (a
// destination that never appears, one that never hides, one whose title is
// wrong). Now it is the `RailDestination` case plus one `register(...)` line
// here. (That enum's declaration order used to be the icon rail's own
// top-to-bottom order; Daylight Phase 2 removed the rail, so the order is
// free - see `RailDestination.swift`'s own Phase 2 note.)
//
// **Why lazy.** Every fixed destination used to run `loadView` during app
// launch and then stay mounted forever with only `isHidden` toggled. Two
// separate costs came out of that. The launch cost is real work for pages
// the captain may never open in a session (Docs spawns a `WKWebView`
// unconditionally; Tools, Log Analyzer and the four Setup pages each build a
// full page of chrome). The layout cost is subtler and has caused three
// production incidents already: an ordinary hidden `NSView`'s constraints
// still participate fully in the window's Auto Layout, so a hidden
// destination can and did cap the whole window's width (AGENTS.md gotchas
// (11) and (13) are both write-ups of exactly that). A destination that was
// never opened now contributes nothing to either.
//
// **Why retention, not teardown.** Once mounted, a slot stays mounted for
// the process's life. Tearing a destination down on navigate-away would
// throw away in-progress state a captain expects to find again (a half-typed
// Log Analyzer paste, an expanded Docs runbook, a Tools tab) and would
// reintroduce the exact failure mode the permanent-mount model was chosen to
// avoid. Host pages already work this way - built on first connect, kept
// until the host is deleted - so this makes the fixed destinations match a
// model this app already relies on rather than inventing a second one.
//
// **What stays eager, and why.** `mountsEagerly` is not a performance
// escape hatch; each of the three uses is a real invariant:
//
//   - `.console` owns live PTYs. The shared Firstmate console opens its own
//     Shell tab at launch (`ConsoleController.openFirstmateHost`), and a
//     running child process must never be waiting on a view that does not
//     exist yet.
//   - `.overview` and `.review` seed the "needs you" counts at launch
//     (`refreshIfNeeded()`), and both controllers render that count *through
//     their own views* - their view properties are implicitly-unwrapped
//     optionals built in `loadView`, so their render path cannot run against
//     an unloaded controller. Decoupling their data fetch from their render
//     is a real refactor of both pages and is deliberately not folded into
//     this change; until then, seeding the count requires the view. (Those
//     counts fed the rail's badges when this was written; since Daylight
//     Phase 2 they feed the Notification Center and the canvas's Fleet /
//     Merge-queue chips instead - same counts, same trigger.)
//   - `.homeCanvas` is the launch landing and the target of every drill
//     page's back button, so it can never wait for a first visit.
//
// Everything else - Hosts, Tasks, DevOps Commands, Log Analyzer, Tools,
// Vault, Dictation, Docs, the four Engineering setup pages (Updates,
// Bootstrap, Automation, GitHub Sync) and Settings - is lazy.

import AppKit

// MARK: - DaylightDrillActions

/// Daylight §6.4: a destination's own "primary + quiet actions", hoisted into
/// the shell's drill header.
///
/// **Why a protocol rather than a switch in `AppShellController`.** GL-37's
/// whole point was that adding or migrating a destination should not mean
/// editing the shell in lockstep with the page - so the shell *asks* the
/// mounted controller what its actions are, and a destination Phase 4 has not
/// reached yet simply does not conform. That also means the migration order is
/// visible in the code: the set of conformers is exactly the set of restyled
/// drill pages.
///
/// The views are caller-owned. A page keeps its Refresh button, its sync pill,
/// and whatever enabled/spinner state it already manages on them - the header
/// only positions them.
protocol DaylightDrillActions: AnyObject {
    var drillHeaderActions: [NSView] { get }

    /// §6.4's "`caption()` subtitle with live numbers". `nil` falls back to
    /// `RailDestination.drillSubtitle`, the static line about the *area* that
    /// every unmigrated destination still shows.
    ///
    /// A page whose numbers change after the header was configured tells the
    /// shell by calling the closure it was handed (`onDrillSubtitleChanged`),
    /// rather than reaching into the header itself - the header belongs to the
    /// shell, and a page writing to it directly is how two owners of one view
    /// start disagreeing.
    var drillHeaderSubtitle: String? { get }
}

extension DaylightDrillActions {
    var drillHeaderSubtitle: String? { nil }
}

/// One mountable body view.
///
/// **One-to-one with `RailDestination` today, and deliberately still its own
/// type.** It was not always one-to-one: `.updates`/`.bootstrap`/
/// `.automation`/`.githubSync` shared a single `SetupContainerController`
/// slot until `fm/grandline-separate-setup-destinations` un-merged them (see
/// `RailDestination.slot` below for the captain's own reasoning), and
/// `.poneglyph` was a fifth tab of that same container before it. Keeping the
/// separate type is what let both of those be a table edit rather than a
/// refactor of everything keyed on it - a body view and a place you can
/// navigate to are genuinely different concepts, and this app has now moved
/// the line between them twice.
enum DestinationSlotID: String, CaseIterable {
    /// Daylight Phase 2's home canvas - eagerly mounted, because it is the
    /// launch landing and the target of every drill page's back button.
    case homeCanvas
    case overview, strawHat, console, hosts, shift, review, logAnalyzer, kubernetes
    case tools, whiteboard, codePreview, stickyBoard, commandLibrary, vault, dictation, schedules, health, docs, runbooks, postmortems, poneglyph, settings
    /// The four Engineering setup pages. One slot each since
    /// `fm/grandline-separate-setup-destinations`; they shared a single
    /// `setup` slot before that.
    case updates, bootstrap, automation, githubSync
}

extension RailDestination {
    /// Which body view this destination shows.
    var slot: DestinationSlotID {
        switch self {
        case .homeCanvas: return .homeCanvas
        case .overview: return .overview
        case .strawHat: return .strawHat
        case .console: return .console
        case .hosts: return .hosts
        case .shift: return .shift
        case .review: return .review
        case .logAnalyzer: return .logAnalyzer
        case .kubernetes: return .kubernetes
        case .tools: return .tools
        case .whiteboard: return .whiteboard
        case .stickyBoard: return .stickyBoard
        case .codePreview: return .codePreview
        case .commandLibrary: return .commandLibrary
        case .vault: return .vault
        case .dictation: return .dictation
        case .schedules: return .schedules
        case .health: return .health
        case .docs: return .docs
        case .runbooks: return .runbooks
        case .postmortems: return .postmortems
        // `fm/grandline-separate-setup-destinations`: these four shared one
        // `.setup` slot - a `SetupContainerController` with a
        // `HelmSegmentedTabs` strip across the top - until the captain used
        // the Engineering canvas and objected: "we have 4 cards, however when
        // we go inside it says setup and everything is lumped up." The
        // container's original justification was sibling navigation (the old
        // icon rail's Setup flyout was their only entry point, so picking one
        // stranded you from the other three), and the canvas retired that
        // premise - each of the four has its own always-visible card now, so
        // the tab strip only produced the lumping. A deliberate reversal of
        // `fm/grandline-design-fidelity-fixes`, not a regression of it.
        case .updates: return .updates
        case .bootstrap: return .bootstrap
        case .automation: return .automation
        case .githubSync: return .githubSync
        // `fm/poneglyph-own-destination-and-strawhat-toolbar-shortcut` made
        // the same move one release earlier, for the same reason: Poneglyph
        // was a fifth sub-page of that shared container, and opening the
        // captain's own credential vault from its Stores card showed a page
        // titled "Setup" with a setup-pipeline tab strip above it.
        case .poneglyph: return .poneglyph
        case .settings: return .settings
        }
    }

    /// The line under a drill page's title (Daylight §6.4). Deliberately
    /// short, static, and about the *area* rather than about live data - live
    /// numbers belong on that page's own header, which Phase 4 builds.
    var drillSubtitle: String {
        switch self {
        case .homeCanvas: return ""
        // `fm/polish-straw-hat-overview-card-and-voice-c8d3` narrowed this: the
        // crew chat is its own destination now, so Fleet's line is about the
        // dispatched-crewmate board it actually shows.
        case .overview: return "Dispatched crew, decisions and the morning briefing"
        case .strawHat: return "Ask the crew - every write is yours to confirm"
        case .console: return "Terminals, hosts and the shared Firstmate session"
        case .hosts: return "Saved hosts, SSH keys and snippets"
        // `fm/grandline-tasks-kanban-devops-split` narrowed this: DevOps
        // Commands is its own destination now. In practice this static string
        // is a fallback only - `ShiftController` conforms to
        // `DaylightDrillActions` and always supplies its own live subtitle.
        case .shift: return "A task board, follow-ups and projects"
        case .review: return "Open pull requests, ready to merge"
        case .logAnalyzer: return "Collect, analyse and explain captured output"
        case .kubernetes: return "Read-only cluster browsing and multi-pod log tailing"
        case .tools: return "Nine offline utilities"
        case .whiteboard: return "An Excalidraw canvas, offline, with AI diagrams"
        case .stickyBoard: return "A freeform corkboard of quick sticky notes"
        case .codePreview: return "Paste code and read it properly, synced to your config repo"
        case .commandLibrary: return "Your saved shell commands, parameterised and ready to run"
        // `fm/swap-vault-poneglyph-naming-in-grand-lin-1f` reclaimed `.vault`
        // for Automic Vault's hardening panel - the credential vault's own
        // line moved to `.poneglyph` below. In practice this static string is
        // a fallback only: `VaultController` conforms to
        // `DaylightDrillActions` and always supplies its own live subtitle
        // (secret/launcher counts), which `AppShellController.applyDrillHeader`
        // prefers.
        case .vault: return "Secret names and tool hardening status from Automic Vault"
        case .dictation: return "Speech to text, on this machine"
        case .schedules: return "Unattended runs of actions this app already has"
        case .health: return "How this app's own background services are doing"
        // `fm/grandline-docs-split-runbooks-postmortems` narrowed this to
        // just the Playbook, since Runbooks and Postmortems are their own
        // destinations now.
        case .docs: return "The DevOps Playbook, browsable offline"
        case .runbooks: return "Step-by-step operational procedures"
        case .postmortems: return "Incident write-ups and root causes"
        // `fm/grandline-separate-setup-destinations` split the one line these
        // four shared ("Toolchain, machine config and fork sync") into four,
        // now that each is its own page with its own title above it. In
        // practice all four are fallbacks only: every one of them conforms to
        // `DaylightDrillActions` and supplies its own live line (update
        // counts, step counts, fork counts), which
        // `AppShellController.applyDrillHeader` prefers.
        case .updates: return "Every tool in the catalog, and what needs updating"
        case .bootstrap: return "Set this machine up, and see what has drifted"
        case .automation: return "Run every setup step in order, unattended"
        case .githubSync: return "Pull upstream into each of your personal forks"
        // The credential vault's own line, moved here from `.vault` by the
        // same swap noted above. In practice this static string is a fallback
        // only: `CredentialVaultController` conforms to `DaylightDrillActions`
        // directly now (`fm/poneglyph-own-destination-and-strawhat-toolbar-
        // shortcut` gave it its own slot instead of sharing the
        // since-retired `SetupContainerController`'s) and always supplies its
        // own live
        // subtitle (credential count, lock state), which
        // `AppShellController.applyDrillHeader` prefers - the same
        // "conforming page wins, this is just what an unmigrated page would
        // show" shape every other case in this switch already follows.
        case .poneglyph: return "Your credentials, encrypted and one click from the clipboard"
        case .settings: return "Connection, appearance, terminal, security and backup"
        }
    }
}

/// A single registered destination: its controller, its top-bar title, and
/// whether it has been mounted into the body container yet.
final class DestinationSlot {
    let id: DestinationSlotID
    let title: String
    let mountsEagerly: Bool
    let controller: NSViewController

    /// `true` once the controller has been added as a child and its view
    /// embedded - i.e. once `loadView` has actually run. Never goes back to
    /// `false`: mounting is permanent by design (see the file header).
    fileprivate(set) var isMounted = false

    init(id: DestinationSlotID, title: String, mountsEagerly: Bool, controller: NSViewController) {
        self.id = id
        self.title = title
        self.mountsEagerly = mountsEagerly
        self.controller = controller
    }
}

/// Owns the destination table and the mount/show/hide mechanics.
///
/// Deliberately knows nothing about `AppShellController`, the top bar, the
/// rail, or host pages - it is handed a `mount` closure that does the real
/// `addChild` + `embed` work and otherwise only tracks which slots exist and
/// which have been built. That is what makes the laziness itself testable
/// (`DestinationMountingSelfTest` drives it with counting stub controllers)
/// without standing up the whole app shell, its stores and its network-backed
/// launch refreshes.
final class DestinationMounter {

    private var slots: [DestinationSlotID: DestinationSlot] = [:]
    /// Registration order, so `mountEagerSlots` and `hideAll` are
    /// deterministic rather than dictionary-order.
    private var order: [DestinationSlotID] = []

    /// Adds the controller as a child and pins its view into the body area.
    /// Injected rather than implemented here so this type never touches the
    /// shell's own view hierarchy.
    private let mount: (NSViewController) -> Void

    init(mount: @escaping (NSViewController) -> Void) {
        self.mount = mount
    }

    /// Registers one slot. Registering the same id twice is a programmer
    /// error (two controllers claiming one body view), not something to
    /// silently resolve.
    func register(_ slot: DestinationSlot) {
        precondition(slots[slot.id] == nil, "destination slot \(slot.id.rawValue) registered twice")
        slots[slot.id] = slot
        order.append(slot.id)
    }

    func slot(for id: DestinationSlotID) -> DestinationSlot? { slots[id] }

    var registeredSlots: [DestinationSlot] { order.compactMap { slots[$0] } }

    var mountedSlots: [DestinationSlot] { registeredSlots.filter { $0.isMounted } }

    /// Builds the three slots that cannot wait for a first visit (see the
    /// file header's "What stays eager" note). Called once, from
    /// `AppShellController.loadView`, after the top bar exists - `embed`
    /// anchors every destination to the top bar's bottom edge.
    func mountEagerSlots() {
        for slot in registeredSlots where slot.mountsEagerly {
            mountIfNeeded(slot)
            slot.controller.view.isHidden = true
        }
    }

    /// Mounts `id` if this is its first visit, then reveals it. Returns the
    /// slot so the caller can read its title, or `nil` for an unregistered
    /// id (which would be a wiring bug, and is logged rather than crashing a
    /// captain's session mid-navigation).
    @discardableResult
    func show(_ id: DestinationSlotID) -> DestinationSlot? {
        guard let slot = slots[id] else {
            AppLog.lifecycle.error("no destination registered for slot \(id.rawValue, privacy: .public)")
            return nil
        }
        mountIfNeeded(slot)
        slot.controller.view.isHidden = false
        return slot
    }

    /// Hides every *mounted* slot. An unmounted one has no view to hide, and
    /// asking for `controller.view` here would defeat the whole point by
    /// building it.
    func hideAll() {
        for slot in mountedSlots {
            slot.controller.view.isHidden = true
        }
    }

    private func mountIfNeeded(_ slot: DestinationSlot) {
        guard !slot.isMounted else { return }
        AppLog.lifecycle.debug("mounting destination \(slot.id.rawValue, privacy: .public)")
        mount(slot.controller)
        slot.isMounted = true
    }
}
