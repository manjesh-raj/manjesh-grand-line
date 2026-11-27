// Grand Line - native macOS app.
//
// D-03 of full review 4: key and certificate expiry reminders.
// Run with `FM_RUN_EXPIRY_REMINDER_TESTS=1 .build/debug/GrandLine`.
//
// Headless, with no network: the TLS probe is replaced by a fake.
//
// What it pins:
//
//  - **The OpenSSH certificate reader agrees with `ssh-keygen`.** The two
//    fixtures below were produced by `ssh-keygen -s` (user and host, one with
//    `-V ...:forever`), and the expected fields are what `ssh-keygen -L` and
//    `ssh-keygen -lf` printed for them - not values this file's own writer
//    produced.
//  - **The filing rule**: a task inside the lead window, none outside it,
//    once per certificate, closed when the certificate is renewed, and never
//    for an unknown reading (GL-14).
//  - **The schedule**: due once a day after 06:00.
//  - **The monitor end to end** against a scratch `ShiftStore`: a filed task
//    with its due date and project, the bell entry, a renewal completing it,
//    an unreachable host reading "Unknown, not OK" with no task, and the TLS
//    switch keeping the probe from running at all.
//  - **Source guards** on the Keys tab's wiring, because a check of the
//    monitor passes with the grid's TLS section deleted.

#if FM_SELFTESTS

import AppKit

enum ExpiryReminderSelfTest {

    static func run() -> Bool {
        var ok = true
        let cases: [(String, () -> String?)] = [
            ("user certificate matches ssh-keygen", test_userCertificate),
            ("host certificate that never expires", test_hostCertificate),
            ("garbage is not a certificate", test_garbage),
            ("filing rule", test_policy),
            ("daily schedule", test_schedule),
            ("status words", test_words),
            ("monitor files, closes and bells", test_monitorFilesAndCloses),
            ("unreachable host is unknown, never OK", test_unreachableHost),
            ("TLS switch off skips the probe", test_tlsOff),
            ("Keys tab wiring", test_keysTabWiring),
        ]
        let savedLead = AppSettings.shared.expiryLeadDays
        let savedTLS = AppSettings.shared.expiryChecksTLS
        let savedProject = AppSettings.shared.expiryProjectID
        defer {
            AppSettings.shared.expiryLeadDays = savedLead
            AppSettings.shared.expiryChecksTLS = savedTLS
            AppSettings.shared.expiryProjectID = savedProject
        }
        for (name, body) in cases {
            if let failure = body() { fail("[expiry] \(name): \(failure)", &ok) } else { print("[expiry] PASS \(name)") }
        }
        print(ok ? "[expiry] ALL PASS" : "[expiry] FAILED")
        return ok
    }

    // MARK: Fixtures (ssh-keygen output, see the header)

    static let userCert = "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAICayonupWbjgAZmbCJwVonnT05PFx8clAl+q+T/PugY2AAAAIEtdywQtYtLWlD7N2ogKUXdJmMOnBdgryWj9bp8ZU1nYAAAAAAAAAAAAAAABAAAAC29wcy1lZDI1NTE5AAAAEQAAAANvcHMAAAAGZGVwbG95AAAAAGrmgQAAAAAAaxICgAAAAAAAAACCAAAAFXBlcm1pdC1YMTEtZm9yd2FyZGluZwAAAAAAAAAXcGVybWl0LWFnZW50LWZvcndhcmRpbmcAAAAAAAAAFnBlcm1pdC1wb3J0LWZvcndhcmRpbmcAAAAAAAAACnBlcm1pdC1wdHkAAAAAAAAADnBlcm1pdC11c2VyLXJjAAAAAAAAAAAAAAAzAAAAC3NzaC1lZDI1NTE5AAAAINbRLEvXQsanigQzUXKhztZh11CxWx/5brkT2LjM3nJaAAAAUwAAAAtzc2gtZWQyNTUxOQAAAEA5UmUmubFMt02/POecRfiqrtVPCdoOIG0duTVXL32+op8PUot99fERaJtLOW7rG3EeIhbGytzxVr5xz1efqkcO ops"
    static let hostCert = "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAILwYNWKrbZxLfQUN+KdUr+TV0qkfcRbNBbHaouE6lmzvAAAAIEtdywQtYtLWlD7N2ogKUXdJmMOnBdgryWj9bp8ZU1nYAAAAAAAAAAAAAAACAAAAB2Jhc3Rpb24AAAAcAAAAGGJhc3Rpb24uc3RnLmV4YW1wbGUudGVzdAAAAABq5oEA//////////8AAAAAAAAAAAAAAAAAAAAzAAAAC3NzaC1lZDI1NTE5AAAAINbRLEvXQsanigQzUXKhztZh11CxWx/5brkT2LjM3nJaAAAAUwAAAAtzc2gtZWQyNTUxOQAAAEDYTtYkfkVtY5OiZqOrb9IJXboqKpRadJJF1tcxglHEDc0N8fi/6HB1vaYdUATIfHPwlFonCPZA2vygO0ztBHcN ops"
    static let caFingerprint = "SHA256:hCOkAf/heRnCIfm1kxhI1603DGGwcvO1qRdFM+gXPGo"

    static func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// Local noon on a fixed day, so no runner's time zone moves "today".
    static func noon(_ day: String) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    static func tlsItem(_ address: String, expires: Date?, state: ExpiryItem.State = .expires) -> ExpiryItem {
        ExpiryItem(id: "tls:\(address):443", kind: .tls, label: "\(address):443", detail: "x \u{00B7} y",
                   state: state, expiresAt: expires, reason: nil, ownerID: nil)
    }

    // MARK: Cases

    static func test_userCertificate() -> String? {
        guard let cert = SSHCertificateParser.parse(userCert) else { return "the fixture did not parse" }
        guard cert.kind == .user else { return "expected a user certificate" }
        guard cert.keyID == "ops-ed25519" else { return "key id \(cert.keyID)" }
        guard cert.principals == ["ops", "deploy"] else { return "principals \(cert.principals)" }
        guard cert.validAfter == iso("2026-11-01T00:00:00Z") else { return "valid after \(String(describing: cert.validAfter))" }
        guard cert.validBefore == iso("2026-12-04T00:00:00Z") else { return "valid before \(String(describing: cert.validBefore))" }
        guard cert.signingKeyFingerprint == caFingerprint else { return "CA fingerprint \(cert.signingKeyFingerprint)" }
        // A saved key with the CA's fingerprint names the signer.
        let ca = SSHKey(label: "ops-ca", type: .ed25519, publicKey: "ssh-ed25519 AAAA", fingerprint: caFingerprint)
        let user = SSHKey(label: "ops-ed25519", type: .ed25519, publicKey: "ssh-ed25519 BBBB", fingerprint: "SHA256:x",
                          certificate: userCert)
        let items = ExpirySources.items(for: [ca, user])
        guard let item = items.first(where: { $0.label == "ops-ed25519" }),
              item.detail == "SSH certificate \u{00B7} signed by ops-ca \u{00B7} principals: ops, deploy",
              item.state == .expires, item.kind == .sshCertificate else {
            return "the key's expiry item is wrong: \(items)"
        }
        guard items.first(where: { $0.label == "ops-ca" })?.state == .noExpiry else { return "a plain key should read No expiry" }
        return nil
    }

    static func test_hostCertificate() -> String? {
        guard let cert = SSHCertificateParser.parse(hostCert) else { return "the fixture did not parse" }
        guard cert.kind == .host, cert.principals == ["bastion.stg.example.test"] else { return "fields \(cert)" }
        guard cert.validBefore == nil else { return "a forever certificate should have no expiry" }
        return nil
    }

    static func test_garbage() -> String? {
        if SSHCertificateParser.parse("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINbRLEvXQsanigQzUXKhztZh11CxWx/5brkT2LjM3nJa") != nil {
            return "a plain public key parsed as a certificate"
        }
        let truncated = String(userCert.prefix(120))
        if SSHCertificateParser.parse(truncated) != nil { return "a truncated certificate parsed" }
        let key = SSHKey(label: "bad", type: .ed25519, publicKey: "", fingerprint: "", certificate: truncated)
        return ExpirySources.items(for: [key]).first?.state == .unknown ? nil : "an unreadable certificate should be unknown"
    }

    static func test_policy() -> String? {
        let now = noon("2026-11-22")
        let soon = tlsItem("grafana.example.test", expires: noon("2026-12-06"))   // 14 days
        let later = tlsItem("edge-01.example.test", expires: noon("2027-02-14"))
        let unknown = tlsItem("db", expires: nil, state: .unknown)
        let actions = ExpiryReminderPolicy.actions(items: [soon, later, unknown], filed: [:], now: now, leadDays: 14)
        guard actions == [.file(soon)] else { return "expected one filing, got \(actions)" }
        // The window edge has discriminating power: 15 days out files nothing.
        let fifteen = tlsItem("x", expires: noon("2026-12-07"))
        guard ExpiryReminderPolicy.actions(items: [fifteen], filed: [:], now: now, leadDays: 14).isEmpty else {
            return "15 days out should not file with a 14-day lead"
        }
        let filed = ["tls:grafana.example.test:443": ExpiryFiledTask(taskID: "t1", expiresAt: noon("2026-12-06"), filedAt: now)]
        guard ExpiryReminderPolicy.actions(items: [soon], filed: filed, now: now, leadDays: 14).isEmpty else {
            return "a filed certificate was filed again"
        }
        let renewed = tlsItem("grafana.example.test", expires: noon("2027-03-06"))
        guard ExpiryReminderPolicy.actions(items: [renewed], filed: filed, now: now, leadDays: 14)
                == [.close(itemID: renewed.id, taskID: "t1")] else {
            return "a renewed certificate should close its task"
        }
        let unknownNow = tlsItem("grafana.example.test", expires: nil, state: .unknown)
        guard ExpiryReminderPolicy.actions(items: [unknownNow], filed: filed, now: now, leadDays: 14).isEmpty else {
            return "an unknown reading closed a task"
        }
        return nil
    }

    static func test_schedule() -> String? {
        let cal = Calendar.current
        let today6 = cal.date(bySettingHour: 6, minute: 0, second: 0, of: noon("2026-11-22"))!
        let morning = today6.addingTimeInterval(3600)
        guard ExpiryReminderMonitor.isDue(lastCheckedAt: nil, now: morning) else { return "never checked should be due" }
        guard ExpiryReminderMonitor.isDue(lastCheckedAt: today6.addingTimeInterval(-600), now: morning) else {
            return "a check from before 06:00 should be due after it"
        }
        guard !ExpiryReminderMonitor.isDue(lastCheckedAt: today6.addingTimeInterval(60), now: morning) else {
            return "a check after 06:00 today should not run again"
        }
        let early = today6.addingTimeInterval(-3600)
        guard !ExpiryReminderMonitor.isDue(lastCheckedAt: today6.addingTimeInterval(-7200 - 3600 * 12), now: early) else {
            return "yesterday afternoon's check is still current before 06:00"
        }
        return nil
    }

    static func test_words() -> String? {
        let now = noon("2026-11-25")
        let s1 = ExpiryWords.status(for: tlsItem("a", expires: noon("2026-12-04")), now: now, leadDays: 14)
        guard s1.text == "Expires 4 Dec \u{00B7} 9 days", s1.tint == .warn else { return "soon: \(s1)" }
        let s2 = ExpiryWords.status(for: tlsItem("a", expires: noon("2027-01-26")), now: now, leadDays: 14)
        guard s2.text == "62 days", s2.tint == .good else { return "later: \(s2)" }
        let s3 = ExpiryWords.status(for: tlsItem("a", expires: nil, state: .unknown), now: now, leadDays: 14)
        guard s3.text == "Unknown, not OK", s3.tint != .good else { return "unknown: \(s3)" }
        let head = ExpiryWords.headline(items: [tlsItem("a", expires: noon("2026-12-04")),
                                                tlsItem("b", expires: noon("2026-12-06")),
                                                tlsItem("c", expires: noon("2027-01-26"))], now: now, leadDays: 14)
        return head == "2 expire within 14 days." ? nil : "headline: \(head)"
    }

    /// A monitor over a scratch `ShiftStore`, one key with the user cert and
    /// the given TLS answers.
    static func withMonitor(answers: [String: TLSExpiryProbe.Outcome], hosts: [Host],
                            _ body: (ExpiryReminderMonitor, ShiftStore, Probed) -> String?) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("expiry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", dir.appendingPathComponent("shift").path, 1)
        defer { if let saved { setenv("FM_SHIFT_DIR", saved, 1) } else { unsetenv("FM_SHIFT_DIR") } }
        let shift = ShiftStore()
        var project = ShiftProject.fresh()
        project.name = "Infra hardening"
        shift.addProject(project)
        AppSettings.shared.expiryProjectID = project.id
        AppSettings.shared.expiryLeadDays = 14
        let key = SSHKey(label: "ops-ed25519", type: .ed25519, publicKey: "ssh-ed25519 BBBB", fingerprint: "SHA256:x",
                         certificate: userCert)
        let monitor = ExpiryReminderMonitor(store: ExpiryReminderStore(directory: dir.appendingPathComponent("expiry")),
                                            keys: { [key] }, hosts: { hosts }, shiftStore: shift)
        let probed = Probed()
        monitor.probe = { address, done in
            probed.addresses.append(address)
            done(answers[address] ?? .failed("connection refused"))
        }
        return body(monitor, shift, probed)
    }

    final class Probed { var addresses: [String] = [] }

    static func runCheck(_ monitor: ExpiryReminderMonitor) {
        var finished = false
        monitor.check { finished = true }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func test_monitorFilesAndCloses() -> String? {
        AppSettings.shared.expiryChecksTLS = true
        let grafana = Host(label: "grafana", address: "grafana.example.test", username: "ops")
        var answers: [String: TLSExpiryProbe.Outcome] = [
            "grafana.example.test": .certificate(notAfter: noon("2026-12-06"), subject: "CN=*.example.test",
                                                 issuer: "C=US, O=Let's Encrypt, CN=R11"),
        ]
        return withMonitor(answers: answers, hosts: [grafana]) { monitor, shift, _ in
            monitor.now = { noon("2026-11-22") }
            runCheck(monitor)
            let tasks = shift.activeTasks.filter { $0.tags.contains("expiry") }
            guard tasks.count == 2 else { return "expected 2 filed tasks (SSH cert and TLS), got \(tasks.map(\.title))" }
            guard let tls = tasks.first(where: { $0.title == "Renew the TLS certificate for grafana.example.test" }) else {
                return "the TLS task is missing: \(tasks.map(\.title))"
            }
            guard tls.dueDate == "2026-12-06", tls.projectID == AppSettings.shared.expiryProjectID else {
                return "the TLS task is due \(tls.dueDate ?? "nil") in \(tls.projectID ?? "nil")"
            }
            let item = monitor.store.state.items.first { $0.kind == .tls }
            guard item?.detail == "*.example.test \u{00B7} R11" else { return "TLS detail \(item?.detail ?? "nil")" }
            guard GrandLineNotificationCenter.shared.entries.contains(where: {
                $0.id == ExpiryReminderMonitor.bellID("tls:grafana.example.test:443")
            }) else { return "no bell entry for the filing" }
            // Again: nothing new is filed.
            runCheck(monitor)
            guard shift.activeTasks.filter({ $0.tags.contains("expiry") }).count == 2 else { return "a second check filed again" }
            // Renewed: the TLS task completes and its bell clears.
            answers["grafana.example.test"] = .certificate(notAfter: noon("2027-03-06"), subject: "CN=*.example.test", issuer: "CN=R11")
            monitor.probe = { address, done in done(answers[address] ?? .failed("x")) }
            runCheck(monitor)
            guard !shift.activeTasks.contains(where: { $0.id == tls.id && $0.status != .completed }) else {
                return "a renewed certificate did not close its task"
            }
            guard !GrandLineNotificationCenter.shared.entries.contains(where: {
                $0.id == ExpiryReminderMonitor.bellID("tls:grafana.example.test:443")
            }) else { return "the bell entry outlived the renewal" }
            return nil
        }
    }

    static func test_unreachableHost() -> String? {
        AppSettings.shared.expiryChecksTLS = true
        let db = Host(label: "db-replica-eu", address: "db-replica-eu", username: "ops")
        return withMonitor(answers: [:], hosts: [db]) { monitor, shift, _ in
            monitor.now = { noon("2026-10-01") } // the SSH cert is outside the window
            runCheck(monitor)
            guard let item = monitor.store.state.items.first(where: { $0.kind == .tls }) else { return "no TLS item" }
            guard item.state == .unknown, item.detail == "Could not connect: connection refused" else {
                return "unreachable reads \(item.state) / \(item.detail)"
            }
            return shift.activeTasks.contains(where: { $0.tags.contains("expiry") }) ? "an unknown host filed a task" : nil
        }
    }

    static func test_tlsOff() -> String? {
        AppSettings.shared.expiryChecksTLS = false
        defer { AppSettings.shared.expiryChecksTLS = true }
        let grafana = Host(label: "grafana", address: "grafana.example.test", username: "ops")
        return withMonitor(answers: [:], hosts: [grafana]) { monitor, _, probed in
            runCheck(monitor)
            return probed.addresses.isEmpty ? nil : "the probe ran with TLS checks off: \(probed.addresses)"
        }
    }

    static func test_keysTabWiring() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("[expiry] SKIP wiring guard: no app sources")
            return nil
        }
        func read(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        let keys = read("HostsController+Keys.swift")
        guard keys.contains("sections.append(.init(title: \"TLS on saved hosts\", cards: tls.map(tlsExpiryCard)))") else {
            return "the Keys grid no longer draws the TLS section"
        }
        guard keys.contains("card.status = ExpiryWords.status(for: expiry") else { return "key cards no longer show expiry" }
        let workspace = read("Workspace.swift")
        guard workspace.contains("expiryMonitor.start()"), workspace.contains("hostsPanel.expiryMonitor = expiryMonitor") else {
            return "the workspace no longer starts the monitor or hands it to the Keys tab"
        }
        return nil
    }
}

#endif
