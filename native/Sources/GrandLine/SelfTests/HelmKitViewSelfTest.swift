// Grand Line - native macOS app.
//
// The UI/UX revamp's component kit (UI-39), the geometry half: where the kit
// pieces' content actually lands after a real layout pass in a real window.
// `HelmKitSelfTest` owns what they paint.
//
// Run with `FM_RUN_HELM_KIT_VIEW_TESTS=1 .build/debug/GrandLine`.
//
// **Why this suite is window-backed.** Every case reads a resolved frame, and
// the claims are about padding and alignment the constraint solver decides -
// so it is listed in `NEEDS_SESSION` (AGENTS.md's "what the suite asserts"
// test).
//
// What it covers:
//
//   1. **A flat row is 10/16 with a 44pt floor.** One line of text centres
//      in 44pt, and the text starts 16pt in when the bar is hidden.
//   2. **A card-flat row's text starts 14pt in**, past its 3pt bar.
//   3. **The meta-line chip sits on the meta line's trailing edge**, at the
//      row's 12pt trailing inset, not after the title.
//   4. **A trailing caption sits between the text and the actions**, and the
//      text column - not the caption - is what truncates.
//   5. **A section header's actions sit at its trailing edge**, however
//      short the title.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum HelmKitViewSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== HelmKitViewSelfTest ==")
        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }
        if let daylight = HelmTheme.theme(id: "daylight") { ThemeManager.shared.setTheme(daylight) }
        autoreleasepool {
            checkFlatRowGeometry(&ok)
            checkCardFlatRowGeometry(&ok)
            checkMetaLineChip(&ok)
            checkTrailingCaption(&ok)
            checkSectionHeaderActions(&ok)
        }
        print(ok ? "HelmKitViewSelfTest: OK" : "HelmKitViewSelfTest: FAILED")
        return ok
    }

    /// Mounts `view` at `width` in an off-screen window and lays it out.
    static func mount(_ view: NSView, width: CGFloat) -> NSWindow {
        let window = OffScreenProbe.window(size: NSSize(width: width + 40, height: 400),
                                           styleMask: [.titled])
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width + 40, height: 400))
        window.contentView = host
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            view.widthAnchor.constraint(equalToConstant: width),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
        ])
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private static func content(_ title: String) -> HelmAccentRow.Content {
        HelmAccentRow.Content(tint: .accent, kicker: "", title: title)
    }

    // MARK: 1

    private static func checkFlatRowGeometry(_ ok: inout Bool) {
        let row = HelmAccentRow(style: .flat)
        row.configure(content("One line"), theme: ThemeManager.shared.theme)
        let window = mount(row, width: 400)
        defer { window.orderOut(nil) }
        let geo = row.debugGeometry()
        check(row.frame.height >= HelmType.scaledRowHeight(44) - 0.5,
              "a one-line flat row should be at least 44pt tall, got \(row.frame.height)", &ok)
        let textX = geo.titleFrame.minX + row.debugTitleAlignmentLeadingInset
        check(abs(textX - 16) <= 1,
              "a flat row's text should start 16pt in, got \(textX)", &ok)
        let centreGap = abs(geo.titleFrame.midY - row.bounds.midY)
        check(centreGap <= 1.5, "a one-line flat row should centre its text, off by \(centreGap)", &ok)
    }

    // MARK: 2

    private static func checkCardFlatRowGeometry(_ ok: inout Bool) {
        let row = HelmAccentRow(style: .cardFlat)
        var c = content("SecretManager Sync")
        c.kicker = "Pramata Platform"
        row.configure(c, theme: ThemeManager.shared.theme)
        let window = mount(row, width: 320)
        defer { window.orderOut(nil) }
        let geo = row.debugGeometry()
        let textX = geo.titleFrame.minX + row.debugTitleAlignmentLeadingInset
        check(abs(textX - 14) <= 1, "a card-flat row's text should start 14pt in, got \(textX)", &ok)
        check(geo.barFrame.minX >= 1.5 && geo.barFrame.minX <= 2.5,
              "the identity bar should sit 2pt in, got \(geo.barFrame.minX)", &ok)
    }

    // MARK: 3

    private static func checkMetaLineChip(_ ok: inout Bool) {
        let row = HelmAccentRow(chipPlacement: .metaLine, style: .cardFlat)
        var c = content("HA for the devops-agents ec2-server")
        c.kicker = "sre_sentinel bot"
        c.metaLead = "Due today"
        c.metaLeadTint = .warn
        c.chipText = "High"
        c.chipTint = .critical
        c.titleWraps = true
        row.configure(c, theme: ThemeManager.shared.theme)
        let window = mount(row, width: 320)
        defer { window.orderOut(nil) }
        let geo = row.debugGeometry()
        check(geo.chipVisible, "the chip should show", &ok)
        let trailingGap = row.bounds.width - geo.chipFrame.maxX
        check(abs(trailingGap - 12) <= 1, "the meta-line chip should sit 12pt from the trailing edge, got \(trailingGap)", &ok)
        check(geo.chipFrame.maxY <= geo.titleFrame.minY + 1,
              "the meta-line chip should sit below the title (unflipped), chip \(geo.chipFrame) title \(geo.titleFrame)", &ok)
    }

    // MARK: 4

    private static func checkTrailingCaption(_ ok: inout Bool) {
        let action = HelmButton(title: "Open", variant: .quiet, size: .small)
        let row = HelmAccentRow(trailingAccessory: action, style: .flat)
        var c = content(String(repeating: "A very long follow-up title ", count: 6))
        c.trailingCaption = "Overdue 26 days \u{00B7} since 18 Sep"
        c.trailingCaptionTint = .critical
        row.configure(c, theme: ThemeManager.shared.theme)
        let window = mount(row, width: 600)
        defer { window.orderOut(nil) }
        let geo = row.debugGeometry()
        guard let caption = row.debugTrailingCaptionFrame, let accessory = geo.trailingAccessoryFrame else {
            fail("the caption and the accessory should both be laid out", &ok)
            return
        }
        check(caption.minX >= geo.textColumnFrame.maxX - 0.5,
              "the caption should sit after the text column", &ok)
        check(caption.maxX <= accessory.minX + 0.5, "the caption should sit before the action", &ok)
        let full = row.debugTrailingCaption ?? ""
        let needed = (full as NSString).size(withAttributes: [.font: HelmType.chip()]).width
        check(caption.width >= needed - 1,
              "the caption should not truncate before the title does (\(caption.width) for \(needed))", &ok)
    }

    // MARK: 5

    private static func checkSectionHeaderActions(_ ok: inout Bool) {
        let header = HelmSectionHeader(size: .section)
        header.configure(leading: .tile(symbol: "bell", tint: .warn), title: "Follow-ups", count: "2 pending")
        let add = HelmButton(title: "Add", variant: .quiet, size: .small, symbol: "plus")
        header.setActions([add])
        let window = mount(header, width: 700)
        defer { window.orderOut(nil) }
        let frame = add.convert(add.bounds, to: header)
        check(abs(header.bounds.width - frame.maxX) <= 1,
              "a header's action should sit at its trailing edge, gap \(header.bounds.width - frame.maxX)", &ok)
        let count = header.countLabel.convert(header.countLabel.bounds, to: header)
        let title = header.titleLabel.convert(header.titleLabel.bounds, to: header)
        check(count.minX >= title.maxX && count.minX - title.maxX < 12,
              "the count should sit right beside the title, not drift with the slack", &ok)
    }
}

#endif
