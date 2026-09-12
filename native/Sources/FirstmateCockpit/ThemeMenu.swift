// Manjesh Grand Line - native macOS app.
//
// The theme picker menu (nav-redesign task, item 4; grew from 8 to 12 themes
// in cockpit-theme-overhaul): DARK/LIGHT group headers, a swatch + name +
// checkmark per theme. Shared by the topbar's theme button and Settings'
// Appearance row so both pickers stay in lockstep with zero duplicated
// menu-building logic. Built from `HelmTheme.allThemes` with no hardcoded
// count, so it scales to however many themes that list holds.

import AppKit

// MARK: - H2: SF Symbols on menu items

extension NSMenuItem {
    /// H2 of the UI modernization audit: "keep stock menus (Tahoe menus are
    /// already modern glass - custom menus are a web-app tell), but add SF
    /// Symbol `image`s to menu items (macOS convention now)".
    ///
    /// **A template image, deliberately.** A menu item's image is drawn by
    /// AppKit into a menu whose own appearance it owns - a highlighted row
    /// inverts, and a template glyph inverts with it. A non-template image
    /// would stay its own colour on a selected row, which is exactly the
    /// "two icon languages" tell this section is about.
    ///
    /// Sized to `symbolPointSize`, which is the size AppKit's own menus draw
    /// at; left unconfigured it renders noticeably larger than a system item's.
    ///
    /// Returns self, so a call site stays one line.
    @discardableResult
    func withSymbol(_ name: String) -> NSMenuItem {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.symbolPointSize, weight: .regular)) else {
            // `NSImage(systemSymbolName:)` returns nil silently, and this app
            // has shipped an invisible icon that way before - so a name that
            // does not resolve leaves the item text-only rather than blank.
            AppLog.ui.error("menu symbol \(name, privacy: .public) did not resolve")
            return self
        }
        image.isTemplate = true
        self.image = image
        return self
    }

    static let symbolPointSize: CGFloat = 13
}

extension NSMenu {
    /// `addItem(withTitle:action:keyEquivalent:)` plus H2's symbol, in one
    /// call - the convenience form this app already uses most.
    @discardableResult
    func addItem(withTitle title: String, symbol: String,
                 action: Selector?, keyEquivalent: String) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        return item.withSymbol(symbol)
    }
}


enum ThemeMenu {
    /// `target`/`action` are applied to every theme item (not the group
    /// headers, which are disabled separators-with-a-label); the chosen
    /// theme's id is read back via `NSMenuItem.representedObject`.
    static func build(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        appendGroup("DARK", HelmTheme.allThemes.filter { $0.mode == .dark }, to: menu, target: target, action: action)
        menu.addItem(.separator())
        appendGroup("LIGHT", HelmTheme.allThemes.filter { $0.mode == .light }, to: menu, target: target, action: action)
        return menu
    }

    private static func appendGroup(_ title: String, _ themes: [HelmTheme], to menu: NSMenu, target: AnyObject, action: Selector) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let activeID = ThemeManager.shared.theme.id
        for theme in themes {
            let item = NSMenuItem(title: theme.name, action: action, keyEquivalent: "")
            item.target = target
            item.image = theme.swatchImage()
            item.state = theme.id == activeID ? .on : .off
            item.representedObject = theme.id
            menu.addItem(item)
        }
    }

    /// Read a theme item's id back and apply it - the shared action body for
    /// both the topbar button and Settings' Appearance popup.
    static func apply(from sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let theme = HelmTheme.theme(id: id) else { return }
        ThemeManager.shared.setTheme(theme)
    }
}
