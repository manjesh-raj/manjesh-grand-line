// Grand Line - native macOS app.
//
// P6 of the Grand Line vs Automic Vault polish report: a native menu on the
// compact-mode status item.
//
// Automic Vault's one status item opens a live `NSMenu`: section headers,
// counts, submenus. Grand Line's compact mode opens a four-tab popover, and
// that was the captain's own design ("Four tabs, not a menu" -
// `docs/history/40-menu-bar-mode.md`). The captain's decision for P6 keeps
// it: **a left-click still opens the popover**, and a right-click or a
// control-click opens this menu, the usual macOS split.
//
// The menu is built fresh on every open from the same data the popover
// reads - nothing is cached here - so it is never staler than the popover:
//
//   - **Needs you**: the notification center's action-needed entries, each
//     opening what it is about.
//   - **Due today**: the Today tab's own digest, each task with a submenu to
//     mark it done or open it in Tasks.
//   - **Crew**: one item, the popover on its Crew tab.
//   - Show Popover, Open Grand Line, Settings.
//
// GL-09: with the app locked, the menu carries none of the captain's data -
// only the ways back in (the popover's own unlock form, and the window with
// its lock screen) - behind its own `AppLockedSurface` case.

import AppKit

/// Which surface a click on the status item opens.
enum CompactModeClickRoute: Equatable {
    case popover
    case menu

    /// A right-click, or a left-click with Control held (the one-button
    /// mouse's right-click), opens the menu; every other click the popover.
    static func route(for type: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> CompactModeClickRoute {
        switch type {
        case .rightMouseDown?, .rightMouseUp?: return .menu
        default: return modifiers.contains(.control) ? .menu : .popover
        }
    }
}

enum CompactModeStatusMenu {

    /// Everything the menu shows and does, supplied by the controller so this
    /// file reads no store of its own.
    struct Inputs {
        var isUnlocked: Bool
        var needsYou: [(title: String, open: () -> Void)]
        var dueToday: [CompactTaskRow]
        var onCompleteTask: (String) -> Void
        var onOpenTasks: () -> Void
        var onAskCrew: () -> Void
        var onShowPopover: () -> Void
        var onOpenFullWindow: () -> Void
        var onOpenSettings: () -> Void
    }

    /// The most rows a section lists before it says how many it left out -
    /// the density rule (P4) applies to a menu as much as to a card.
    static let rowLimit = 5

    static func build(_ inputs: Inputs) -> NSMenu {
        let menu = NSMenu(title: "Grand Line")
        menu.autoenablesItems = false

        guard inputs.isUnlocked else {
            let locked = NSMenuItem(title: "Grand Line is locked", action: nil, keyEquivalent: "")
            locked.isEnabled = false
            menu.addItem(locked)
            menu.addItem(.separator())
            menu.addItem(HelmMenuAction.item("Unlock\u{2026}", symbol: "lock.open", inputs.onShowPopover))
            menu.addItem(HelmMenuAction.item("Open Grand Line", symbol: "macwindow", inputs.onOpenFullWindow))
            return menu
        }

        menu.addItem(header("Needs you", count: inputs.needsYou.count))
        if inputs.needsYou.isEmpty {
            menu.addItem(note("Nothing needs you"))
        } else {
            for entry in inputs.needsYou.prefix(rowLimit) {
                menu.addItem(HelmMenuAction.item(entry.title, symbol: "exclamationmark.circle", entry.open))
            }
            if inputs.needsYou.count > rowLimit {
                menu.addItem(note("and \(inputs.needsYou.count - rowLimit) more"))
            }
        }

        menu.addItem(.separator())
        menu.addItem(header("Due today", count: inputs.dueToday.count))
        if inputs.dueToday.isEmpty {
            menu.addItem(note("Nothing due"))
        } else {
            for task in inputs.dueToday.prefix(rowLimit) {
                let item = NSMenuItem(title: task.title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: task.urgency == .overdue ? "exclamationmark.circle" : "circle",
                                     accessibilityDescription: nil)
                item.toolTip = task.detail
                let submenu = NSMenu(title: task.title)
                let id = task.id
                submenu.addItem(HelmMenuAction.item("Mark Done", symbol: "checkmark.circle") { inputs.onCompleteTask(id) })
                submenu.addItem(HelmMenuAction.item("Open in Tasks", symbol: "arrow.up.forward.app", inputs.onOpenTasks))
                item.submenu = submenu
                menu.addItem(item)
            }
            if inputs.dueToday.count > rowLimit {
                menu.addItem(HelmMenuAction.item("View all \(inputs.dueToday.count) in Tasks", symbol: nil, inputs.onOpenTasks))
            }
        }

        menu.addItem(.separator())
        menu.addItem(header("Crew", count: nil))
        menu.addItem(HelmMenuAction.item("Ask the Crew\u{2026}", symbol: "bubble.left.and.bubble.right", inputs.onAskCrew))

        menu.addItem(.separator())
        menu.addItem(HelmMenuAction.item("Show Popover", symbol: "rectangle.topthird.inset.filled", inputs.onShowPopover))
        menu.addItem(HelmMenuAction.item("Open Grand Line", symbol: "macwindow", inputs.onOpenFullWindow))
        menu.addItem(HelmMenuAction.item("Settings\u{2026}", symbol: "gearshape", inputs.onOpenSettings))
        return menu
    }

    /// A section header with its count - the system's own header on macOS
    /// 14, a disabled item before it.
    private static func header(_ title: String, count: Int?) -> NSMenuItem {
        let text = count.map { "\(title) \u{00B7} \($0)" } ?? title
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: text)
        }
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// Carries a closure into an `NSMenuItem`'s target, which AppKit requires to
/// be an object. One box per item, retained by the item's own
/// `representedObject` - a menu built fresh per open has no other owner.
/// The app's one copy (the notification panel's right-click menu and the
/// status menu both use it).
final class HelmMenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }

    static func item(_ title: String, symbol: String? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        let box = HelmMenuAction(run)
        item.target = box
        item.representedObject = box
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    #if FM_SELFTESTS
    /// Runs an item built by `item(_:symbol:_:)` through its real target and
    /// action - what AppKit does on a pick.
    static func debugPerform(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        _ = (item.target as? NSObject)?.perform(action, with: item)
    }
    #endif
}
