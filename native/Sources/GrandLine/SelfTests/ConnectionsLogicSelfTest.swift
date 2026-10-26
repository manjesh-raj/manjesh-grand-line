// Grand Line - native macOS app.
//
// The Termius-style Hosts and Keys work (PR 1 of 3 of the captain's plan):
// its pure-logic half. The arithmetic and parsing the pages rely on, asserted
// without mounting a view, so it runs in CI's blocking headless lane.
//
//   - H9: how many tag chips fit the filter row beside the "+N" chip, and
//     that the count settles rather than feeding back on "+N"'s own width.
//   - The flat host grid: its order, and the Grouped choice's stored default.
//   - H7: the card grid's column plan, and its pixel grid at 1x and 2x for a
//     half-point column (the case CI's 1x runner hits and a 2x Mac cannot).
//   - X2: "last connected" in words, and the recent row's order.
//   - X1: reading an OpenSSH client config - aliases, options, forwards, the
//     blocks it skips, GL-08's refusal and what is already saved.
//
// The window-backed half is `ConnectionsCardsSelfTest`.
//
// Run with:
//   swift build && FM_RUN_CONNECTIONS_LOGIC_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ConnectionsLogicSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkTagChipFit, checkTagStripSettles, checkFlatOrder, checkGroupedSetting,
                      checkGridPlan, checkLastConnected, checkKeyWords, checkSSHConfigParse] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ConnectionsLogicSelfTest: all checks passed" : "ConnectionsLogicSelfTest: FAILED")
        return allOK
    }

    // MARK: H7

    private static func checkGridPlan(_ ok: inout Bool) {
        let minimum = HelmCardGrid.minimumCardWidth, gap = HelmCardGrid.spacing
        let exact = HelmCardGrid.plan(width: 3 * minimum + 2 * gap)
        check(exact.columns == 3 && abs(exact.cardWidth - minimum) < 0.001, "H7: three minimum cards fit exactly (\(exact))", &ok)
        check(HelmCardGrid.plan(width: 3 * minimum + 2 * gap - 1).columns == 2, "H7: a point short drops a column", &ok)
        check(HelmCardGrid.plan(width: 120).columns == 1, "H7: a narrow column still shows one card", &ok)
        // A half-point column, at 1x and 2x: every edge lands on a device pixel.
        let width: CGFloat = 1100.5 - 300
        let plan = HelmCardGrid.plan(width: width)
        for scale: CGFloat in [1, 2] {
            for column in 0..<plan.columns {
                let x = CGFloat(column) * (plan.cardWidth + gap)
                let aligned = HelmCardGrid.pixelAligned(x, scale: scale)
                check(abs(aligned * scale - (aligned * scale).rounded()) < 0.0001 && abs(aligned - x) <= 0.5 / scale + 0.0001,
                      "H7: column \(column) at \(scale)x lands at \(aligned) for \(x)", &ok)
            }
        }
        check(HelmCardGrid.pixelAligned(10.25, scale: 1) == 10 && HelmCardGrid.pixelAligned(10.25, scale: 2) == 10.5,
              "H7: the pixel grid rounds differently at 1x and 2x", &ok)
    }

    // MARK: X2

    private static func checkLastConnected(_ ok: inout Bool) {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        check(HostsController.lastConnectedText(now.addingTimeInterval(-20), now: now) == "Last connected just now",
              "X2: a connection seconds ago reads \(HostsController.lastConnectedText(now.addingTimeInterval(-20), now: now))", &ok)
        let hours = HostsController.lastConnectedText(now.addingTimeInterval(-2 * 3600), now: now)
        check(hours.hasPrefix("Last connected ") && hours.contains("2"), "X2: two hours ago reads \(hours)", &ok)
        var a = Host(label: "a", address: "a.example.test"); a.lastConnectedAt = now.addingTimeInterval(-50)
        var b = Host(label: "b", address: "b.example.test"); b.lastConnectedAt = now
        let c = Host(label: "c", address: "c.example.test")
        check(HostsController.recentHosts([a, c, b]).map(\.label) == ["b", "a"],
              "X2: the recent row is newest first and leaves out a host never connected", &ok)
        check(HostsController.recentHosts([a, b], limit: 1).map(\.label) == ["b"], "X2: the recent row honours its limit", &ok)
    }

    // MARK: K4

    private static func checkKeyWords(_ ok: inout Bool) {
        let short = HostsController.shortFingerprint("SHA256:abcdefghijklmnopqrstuvwxyz0123456789")
        check(short == "SHA256:abcdefghijkl\u{2026}", "K4: the short fingerprint is \(short)", &ok)
        check(HostsController.shortFingerprint("SHA256:abc") == "SHA256:abc", "K4: a short hash gains an ellipsis", &ok)
        check(HostsController.lastUsedText(nil) == "Never used", "K4: a key never used reads \(HostsController.lastUsedText(nil))", &ok)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        check(HostsController.lastUsedText(now.addingTimeInterval(-5), now: now) == "Used just now", "K4: a key used now reads otherwise", &ok)
    }

    // MARK: X1

    static let fixtureConfig = """
    # Fixture only: reserved example.test names and documentation addresses.
    Host *
        ServerAliveInterval 30
        User everyone

    Host web-01 web-02 *.example.test
        HostName web.example.test
        User deploy
        User ignored-second-value
        Port 2200
        IdentityFile ~/.ssh/id_ed25519_fixture
        ForwardAgent yes

    Host db-replica
        HostName=192.0.2.88
        User "postgres"
        ProxyJump bastion.example.test
        LocalForward 127.0.0.1:5433 localhost:5432
        DynamicForward 1080
        RemoteForward 9000 localhost:-bad

    Host edge-proxy-01
        HostName edge-01.example.test
        User ops

    Host evil
        HostName -oProxyCommand=touch
    Host badport
        HostName port.example.test
        Port 99999
    Match host *.internal
        User nobody
    Include ~/.ssh/config.d/*
    """

    private static func checkSSHConfigParse(_ ok: inout Bool) {
        let existing = [Host(label: "edge-proxy-01", address: "edge-01.example.test", username: "ops")]
        let result = SSHConfigImport.parse(fixtureConfig, existing: existing)
        let labels = result.candidates.map(\.host.label)
        check(labels == ["web-01", "web-02", "db-replica", "edge-proxy-01", "evil", "badport"],
              "X1: the candidates are \(labels)", &ok)
        check(result.skippedPatterns == 1 && result.skippedMatchBlocks == 1 && result.includes == 1,
              "X1: skipped \(result.skippedPatterns) patterns, \(result.skippedMatchBlocks) Match, \(result.includes) Include", &ok)
        guard result.candidates.count == 6 else { return }
        let web = result.candidates[0], db = result.candidates[2]
        check(web.host.address == "web.example.test" && web.host.username == "deploy" && web.host.port == 2200
                && web.host.agentForward && web.identityFile == "~/.ssh/id_ed25519_fixture" && web.skipReason == nil,
              "X1: web-01 read as \(web.host.subtitle), agent \(web.host.agentForward), key \(web.identityFile ?? "-")", &ok)
        check(result.candidates[1].host.address == "web.example.test", "X1: an alias beside another did not share its block", &ok)
        check(web.host.username != "everyone", "X1: Host *'s defaults leaked into a host", &ok)
        check(db.host.address == "192.0.2.88" && db.host.username == "postgres" && db.host.jumpVia == "bastion.example.test",
              "X1: db-replica read as \(db.host.subtitle) via \(db.host.jumpVia ?? "-")", &ok)
        let forwards = db.host.portForwards
        check(forwards.count == 2 && forwards[0].kind == .local && forwards[0].bindAddress == "127.0.0.1"
                && forwards[0].listenPort == 5433 && forwards[0].destHost == "localhost" && forwards[0].destPort == 5432
                && forwards[1].kind == .dynamic && forwards[1].listenPort == 1080,
              "X1: db-replica's forwards are \(forwards.map(\.summary)) - the bad RemoteForward must be dropped", &ok)
        check(result.candidates[3].skipReason == .alreadySaved, "X1: a saved host is not marked already saved", &ok)
        check(result.candidates[4].skipReason?.canImport == false && result.candidates[4].skipReason?.text.contains("Address") == true,
              "X1: a leading-dash address was offered (\(String(describing: result.candidates[4].skipReason)))", &ok)
        check(result.candidates[5].skipReason?.canImport == false, "X1: a bad port was offered", &ok)
        check(SSHConfigImport.parse("").candidates.isEmpty, "X1: an empty config named hosts", &ok)
    }

    // MARK: H9

    private static func checkTagChipFit(_ ok: inout Bool) {
        let widths: [CGFloat] = [40, 50, 60, 30]
        // 40 + 50 + 60 + 30 + 3 * 4 = 192.
        func fit(_ strip: CGFloat, shown: Bool) -> Int {
            HostsController.fittingTagCount(chipWidths: widths, spacing: 4, stripWidth: strip,
                                            overflowWidth: 28, overflowShown: shown)
        }
        check(fit(192, shown: false) == 4, "H9: every chip shows when they all fit exactly", &ok)
        check(fit(400, shown: false) == 4, "H9: every chip shows in a wide strip", &ok)
        // With "+N" showing, the strip is narrower by its width and a gap;
        // all four still fit once it goes, so it must go.
        check(fit(192 - 32, shown: true) == 4, "H9: the +N chip goes once the strip has room for every chip", &ok)
        // 191pt: the four do not fit, and beside a 28pt chip (and a gap)
        // only 159pt is left - 40 + 50 + 60 + 2 * 4 = 158 fits, the fourth does not.
        check(fit(191, shown: false) == 3, "H9: a strip one point short puts the last chip behind +N", &ok)
        check(fit(159, shown: true) == 3, "H9: the count is stable once +N is showing", &ok)
        check(fit(20, shown: false) == 0, "H9: a strip too narrow for any chip shows none rather than a cut one", &ok)
        check(HostsController.fittingTagCount(chipWidths: [], spacing: 4, stripWidth: 100,
                                              overflowWidth: 28, overflowShown: false) == 0,
              "H9: no tags fit as zero", &ok)
        // The vacuity guard: the fixture's widths really do need the overflow
        // at 191 and not at 192.
        check(widths.reduce(0, +) + 12 == 192, "H9: the fixture's chips span 192pt", &ok)
    }

    /// The feedback loop a crowded filter row hit: the strip takes what the
    /// row leaves it, so "+N"'s width moving with its label moves the strip.
    /// Played forward a few layout passes from both ends, the count must
    /// come to rest.
    private static func checkTagStripSettles(_ ok: inout Bool) {
        let chips: [CGFloat] = [37.5, 30, 30, 30, 30]
        let gap: CGFloat = 4
        // "+4" one point wider than "+5", as proportional digits can be.
        func label(_ hidden: Int) -> CGFloat { hidden == 4 ? 30 : 29 }
        // What the row gives the strip and "+N" between them: fixed.
        let shared: CGFloat = 70.2
        func strip(showing count: Int) -> CGFloat {
            let hidden = chips.count - count
            return hidden > 0 ? shared - label(hidden) - gap : shared
        }
        func passes(from start: Int, _ next: (CGFloat, Bool, CGFloat) -> Int) -> [Int] {
            var counts = [start]
            for _ in 0..<6 {
                let count = counts.last!, hidden = chips.count - count
                counts.append(next(strip(showing: count), hidden > 0, label(hidden)))
            }
            return counts
        }
        // The fixture's own discriminating power: read from "+N"'s current
        // width, the count flips on every pass.
        let before = passes(from: 0) { strip, shown, width in
            HostsController.fittingTagCount(chipWidths: chips, spacing: gap, stripWidth: strip,
                                            overflowWidth: width, overflowShown: shown)
        }
        check(Set(before.suffix(4)).count == 2, "H9: the fixture does not oscillate the old way (\(before))", &ok)
        let widest = (1...chips.count).map(label).max()!
        for start in [0, 1] {
            let after = passes(from: start) { strip, shown, width in
                HostsController.settledTagCount(chipWidths: chips, spacing: gap, stripWidth: strip, overflowShown: shown,
                                                shownOverflowWidth: width, reservedOverflowWidth: widest)
            }
            check(Set(after.suffix(4)).count == 1, "H9: the tag count never settles from \(start) (\(after))", &ok)
        }
    }

    /// The flat grid's order: by group as the table orders groups (by name,
    /// the ungrouped last), then by name, then as saved.
    private static func checkFlatOrder(_ ok: inout Bool) {
        let hosts = [
            Host(label: "Prod Bastion", address: "a.example.test", group: "PROD"),
            Host(label: "lab-box", address: "b.example.test"),
            Host(label: "web-10", address: "c.example.test", group: "DEV"),
            Host(label: "web-9", address: "d.example.test", group: "DEV"),
            Host(label: "DEV Bastion", address: "e.example.test", group: "DEV"),
            Host(label: "dup", address: "first.example.test", group: "PROD"),
            Host(label: "dup", address: "second.example.test", group: "PROD"),
            Host(label: "home-nas", address: "f.example.test", group: "  "),
        ]
        let group: (Host) -> String? = {
            let g = $0.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return g.isEmpty ? nil : g
        }
        let ordered = HostsController.flatOrder(hosts, group: group)
        check(ordered.map(\.label) == ["DEV Bastion", "web-9", "web-10", "dup", "dup", "Prod Bastion", "home-nas", "lab-box"],
              "flat grid: the order is \(ordered.map(\.label))", &ok)
        check(ordered.filter { $0.label == "dup" }.map(\.address) == ["first.example.test", "second.example.test"],
              "flat grid: two hosts with one name lost their saved order", &ok)
        check(HostsController.flatOrder(hosts.shuffled(), group: group).map(\.label) == ordered.map(\.label),
              "flat grid: the order depends on the order hosts were saved in", &ok)
    }

    /// The Grouped choice: off when nothing is stored - which is every
    /// captain's preference domain from before it existed - and the Grid /
    /// List value saved beside it still loads.
    private static func checkGroupedSetting(_ ok: inout Bool) {
        let suite = "fm.selftest.connectionslogic.grouped.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("flat grid: no scratch defaults domain", &ok)
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        // An older build's domain: List chosen, no Grouped key at all.
        defaults.set("list", forKey: "fm.connections.viewMode")
        let settings = AppSettings(defaults: defaults)
        check(!settings.hostsGrouped, "flat grid: an unset Grouped reads as on", &ok)
        check(settings.connectionsShowList, "flat grid: a saved List no longer loads", &ok)
        settings.hostsGrouped = true
        check(AppSettings(defaults: defaults).hostsGrouped, "flat grid: Grouped was not stored", &ok)
        check(defaults.object(forKey: "fm.connections.hostsGrouped") != nil,
              "flat grid: Grouped is stored under another key", &ok)
        settings.hostsGrouped = false
        check(!AppSettings(defaults: defaults).hostsGrouped, "flat grid: turning Grouped off was not stored", &ok)
    }
}

#endif
