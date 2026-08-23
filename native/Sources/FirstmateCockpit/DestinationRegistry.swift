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
// wrong). Now it is the `RailDestination` case - which the rail still owns,
// since its declaration order *is* the rail's top-to-bottom order - plus one
// `register(...)` line here.
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
//   - `.console` owns live PTYs. The shared Firstmate console opens its
//     Shell/Mirror pair at launch (`opensFirstmateOnLaunch`), and a running
//     child process must never be waiting on a view that does not exist yet.
//   - `.overview` and `.review` seed the rail's "needs you" badges at launch
//     (`refreshIfNeeded()`), and both controllers render that count *through
//     their own views* - their view properties are implicitly-unwrapped
//     optionals built in `loadView`, so their render path cannot run against
//     an unloaded controller. Decoupling their data fetch from their render
//     is a real refactor of both pages and is deliberately not folded into
//     this change; until then, seeding the badge requires the view.
//
// Everything else - Hosts, Tasks, Log Analyzer, Tools, Vault, Dictation,
// Docs, Setup (all four pages) and Settings - is lazy.

import AppKit

/// One mountable body view.
///
/// Not one-to-one with `RailDestination`: the four Setup pages
/// (`.updates`/`.bootstrap`/`.automation`/`.githubSync`) are four rail
/// destinations sharing a single `SetupContainerController`, which is the
/// whole reason this is a separate type rather than keying the table on
/// `RailDestination` directly.
enum DestinationSlotID: String, CaseIterable {
    case overview, console, hosts, shift, review, logAnalyzer
    case tools, vault, dictation, schedules, docs, setup, settings
}

extension RailDestination {
    /// Which body view this destination shows.
    var slot: DestinationSlotID {
        switch self {
        case .overview: return .overview
        case .console: return .console
        case .hosts: return .hosts
        case .shift: return .shift
        case .review: return .review
        case .logAnalyzer: return .logAnalyzer
        case .tools: return .tools
        case .vault: return .vault
        case .dictation: return .dictation
        case .schedules: return .schedules
        case .docs: return .docs
        case .updates, .bootstrap, .automation, .githubSync: return .setup
        case .settings: return .settings
        }
    }

    /// The top bar's title while this destination is showing.
    ///
    /// Identical to `title` (the rail row's own label) except for the Setup
    /// group: all four of those say "Setup", because the segmented tab row
    /// directly below the top bar is what names the active sub-page - the
    /// same split Hosts already uses for its own three tabs.
    var bodyTitle: String {
        slot == .setup ? "Setup" : title
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
