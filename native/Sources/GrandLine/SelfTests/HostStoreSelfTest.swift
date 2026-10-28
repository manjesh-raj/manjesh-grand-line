// Grand Line - native macOS app.
//
// Regression coverage for `fm/cockpit-fix-host-decode-regression`: block-view
// Stage 0 (`fm/cockpit-block-view-stage0`) added `blockViewOptIn` to `Host`'s
// `CodingKeys`, and Swift's synthesized `Decodable` requires every listed key
// to be present regardless of the Swift property's own default value - the
// captain's real `hosts.json`, saved before that field existed, failed to
// decode entirely and `HostStore.load()` (correctly, by design) treated the
// failure as file corruption, silently emptying the Hosts page. `Host.swift`
// now has a custom `init(from:)` that falls back to each field's default via
// `decodeIfPresent(...) ?? default` - see that file's header. This is the
// same env-var-gated, permanent self-test convention as `BackupSelfTest.swift`
// et al. Run via `FM_RUN_HOST_STORE_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum HostStoreSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ label: String) {
            SelfTestAssertions.record(condition, label, &ok)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoststore-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // MARK: Old-format JSON - no `blockViewOptIn` key at all, exactly the
        // shape every host saved before that field existed. This is the
        // literal shape of the captain's real, live incident.
        let oldFormatJSON = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "label": "DEV Bastion",
            "address": "10.0.0.4",
            "port": 2222,
            "username": "deploy",
            "iconSymbol": "server.rack",
            "accentHex": "6cd7e3",
            "tags": ["dev"],
            "agentForward": true,
            "portForwards": []
          },
          {
            "id": "22222222-2222-2222-2222-222222222222",
            "label": "Prod Bastion",
            "address": "10.0.0.5",
            "port": 22,
            "username": "ops",
            "iconSymbol": "cloud.fill",
            "accentHex": "ff8179",
            "tags": [],
            "agentForward": false,
            "portForwards": [],
            "jumpVia": "DEV Bastion"
          }
        ]
        """

        let oldFormatURL = tmp.appendingPathComponent("old-format-hosts.json")
        try? Data(oldFormatJSON.utf8).write(to: oldFormatURL)

        do {
            let decoded = try JSONDecoder().decode([Host].self, from: Data(oldFormatJSON.utf8))
            check(decoded.count == 2, "old-format JSON (missing blockViewOptIn) decodes both hosts")
            check(decoded.allSatisfy { $0.blockViewOptIn == false }, "blockViewOptIn defaults to false when the key is absent")
            check(decoded[0].label == "DEV Bastion" && decoded[0].port == 2222 && decoded[0].username == "deploy" && decoded[0].agentForward == true,
                  "other fields on the first host survive the decode untouched")
            check(decoded[1].jumpVia == "DEV Bastion", "optional fields (jumpVia) still decode correctly")
        } catch {
            check(false, "old-format JSON decodes at all (\(error.localizedDescription))")
        }

        // MARK: HostStore.load() end to end against that exact file - the
        // real path the captain hit, not just JSONDecoder in isolation.
        setenv("FM_HOSTS_FILE", oldFormatURL.path, 1)
        let store = HostStore()
        check(store.hosts.count == 2, "HostStore.load() reads both hosts from old-format JSON")
        check(store.loadFailureBackupPath == nil, "HostStore.load() does NOT treat old-format JSON as corrupt")
        let corruptBackups = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        check(!corruptBackups.contains(where: { $0.contains(".corrupt-") }), "no hosts.json.corrupt-* backup file was created for valid-but-old-shape JSON")

        // MARK: Full round trip - load old-format JSON, re-save, reload -
        // confirm every field on both hosts (not just blockViewOptIn) survives.
        store.update(store.hosts[0]) // triggers persist() with no other change
        let reloadEnv = tmp.appendingPathComponent("old-format-hosts.json")
        guard let reloadedData = try? Data(contentsOf: reloadEnv),
              let reloaded = try? JSONDecoder().decode([Host].self, from: reloadedData) else {
            check(false, "re-saved hosts.json still decodes")
            return ok
        }
        check(reloaded.count == 2, "round trip keeps both hosts")
        if let devReloaded = reloaded.first(where: { $0.label == "DEV Bastion" }) {
            check(devReloaded.address == "10.0.0.4", "round trip preserves address")
            check(devReloaded.port == 2222, "round trip preserves port")
            check(devReloaded.username == "deploy", "round trip preserves username")
            check(devReloaded.agentForward == true, "round trip preserves agentForward")
            check(devReloaded.tags == ["dev"], "round trip preserves tags")
            check(devReloaded.blockViewOptIn == false, "round trip preserves blockViewOptIn default")
        } else {
            check(false, "DEV Bastion survives the round trip")
        }
        if let prodReloaded = reloaded.first(where: { $0.label == "Prod Bastion" }) {
            check(prodReloaded.jumpVia == "DEV Bastion", "round trip preserves jumpVia")
        } else {
            check(false, "Prod Bastion survives the round trip")
        }

        // MARK: New-format JSON (blockViewOptIn present, true) still decodes -
        // the fix must not have broken the ordinary present-key case.
        let newFormatJSON = """
        [{"id":"33333333-3333-3333-3333-333333333333","label":"Block view host","address":"10.0.0.6","port":22,"username":"","iconSymbol":"server.rack","accentHex":"6cd7e3","tags":[],"agentForward":false,"portForwards":[],"blockViewOptIn":true}]
        """
        do {
            let decoded = try JSONDecoder().decode([Host].self, from: Data(newFormatJSON.utf8))
            check(decoded.count == 1 && decoded[0].blockViewOptIn == true, "new-format JSON (blockViewOptIn present) still decodes correctly")
        } catch {
            check(false, "new-format JSON decodes (\(error.localizedDescription))")
        }

        // MARK: Genuinely malformed JSON is still correctly treated as
        // corrupt - the distinction in HostStore.load() must not have been
        // lost while fixing the missing-optional-key case.
        let malformedURL = tmp.appendingPathComponent("malformed-hosts.json")
        try? Data("{ this is not valid JSON at all".utf8).write(to: malformedURL)
        setenv("FM_HOSTS_FILE", malformedURL.path, 1)
        let malformedStore = HostStore()
        check(malformedStore.hosts.isEmpty, "genuinely malformed JSON still yields an empty host list")
        check(malformedStore.loadFailureBackupPath != nil, "genuinely malformed JSON is still backed up as corrupt")

        unsetenv("FM_HOSTS_FILE")
        checkLastConnectedAt(tmp: tmp, oldFormatJSON: oldFormatJSON, &ok)
        checkKeyLastUsedAt(tmp: tmp, &ok)
        checkConnectRecordsUse(&ok)
        checkBulkAdd(tmp: tmp, &ok)
        return ok
    }

    // MARK: R4-BUG-05 - an import is one write

    /// `add(contentsOf:)` appends every host in order with one `persist()`,
    /// which is one atomic write and one round of observers. SSH config
    /// import goes through it; `ConnectionsCardsSelfTest` asserts that end to
    /// end through the preview's Import button.
    private static func checkBulkAdd(tmp: URL, _ ok: inout Bool) {
        let url = tmp.appendingPathComponent("bulk-add-hosts.json")
        setenv("FM_HOSTS_FILE", url.path, 1)
        defer { unsetenv("FM_HOSTS_FILE") }
        let store = HostStore()
        var notifications = 0
        let token = store.observe { notifications += 1 }
        defer { store.unobserve(token) }
        let batch = (1...40).map { Host(label: "bulk-\($0)", address: "10.0.1.\($0)") }
        store.add(contentsOf: batch)
        check(notifications == 1, "R4-BUG-05: 40 hosts added at once notified \(notifications) time(s), want 1", &ok)
        check(store.hosts.map(\.label) == batch.map(\.label), "R4-BUG-05: add(contentsOf:) keeps the hosts in order", &ok)
        let reread = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Host].self, from: $0) }
        check(reread?.count == 40, "R4-BUG-05: all 40 reach hosts.json, got \(reread?.count ?? -1)", &ok)
        store.add(contentsOf: [])
        check(notifications == 1, "R4-BUG-05: an empty import writes nothing", &ok)
    }

    // MARK: X2 and K5 - the two "when" fields (Termius-style plan)

    /// `Host.lastConnectedAt` is new, so a file saved before it must still
    /// decode (GL-01), and `recordConnection` must stamp exactly one host and
    /// write it to disk.
    private static func checkLastConnectedAt(tmp: URL, oldFormatJSON: String, _ ok: inout Bool) {
        let decoded = try? JSONDecoder().decode([Host].self, from: Data(oldFormatJSON.utf8))
        check(decoded?.count == 2 && decoded?.allSatisfy({ $0.lastConnectedAt == nil }) == true,
              "X2: a hosts.json saved before lastConnectedAt decodes, with the field nil", &ok)

        let url = tmp.appendingPathComponent("last-connected-hosts.json")
        try? Data(oldFormatJSON.utf8).write(to: url)
        setenv("FM_HOSTS_FILE", url.path, 1)
        defer { unsetenv("FM_HOSTS_FILE") }
        let store = HostStore()
        guard store.hosts.count == 2 else {
            fail("X2: the fixture store loads both hosts", &ok)
            return
        }
        let target = store.hosts[1].id
        let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
        store.recordConnection(id: target, at: when)
        check(store.host(id: target)?.lastConnectedAt == when, "X2: recordConnection stamps the host it names", &ok)
        check(store.hosts[0].lastConnectedAt == nil, "X2: recordConnection leaves every other host alone", &ok)
        let reread = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Host].self, from: $0) }
        check(reread?.first(where: { $0.id == target })?.lastConnectedAt == when,
              "X2: the stamp reaches hosts.json and round-trips", &ok)
        store.recordConnection(id: UUID(), at: when)
        check(store.hosts.count == 2, "X2: recording a connection to an unknown id adds nothing", &ok)
    }

    /// `SSHKey.lastUsedAt` is new too: an old keys.json decodes, and
    /// `recordUse` stamps and persists one key.
    private static func checkKeyLastUsedAt(tmp: URL, _ ok: inout Bool) {
        let oldKeysJSON = """
        [{"id":"44444444-4444-4444-4444-444444444444","label":"Deploy key","type":"ed25519",
          "publicKey":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnly fixture","fingerprint":"SHA256:fixture",
          "hasPassphrase":false}]
        """
        let decoded = try? JSONDecoder().decode([SSHKey].self, from: Data(oldKeysJSON.utf8))
        check(decoded?.count == 1 && decoded?.first?.lastUsedAt == nil,
              "K5: a keys.json saved before lastUsedAt decodes, with the field nil", &ok)

        let url = tmp.appendingPathComponent("last-used-keys.json")
        try? Data(oldKeysJSON.utf8).write(to: url)
        setenv("FM_KEYS_FILE", url.path, 1)
        defer { unsetenv("FM_KEYS_FILE") }
        let store = SSHKeyStore()
        guard let id = store.keys.first?.id else {
            fail("K5: the fixture key store loads its key", &ok)
            return
        }
        let when = Date(timeIntervalSinceReferenceDate: 800_000_100)
        store.recordUse(id: id, at: when)
        check(store.key(id: id)?.lastUsedAt == when, "K5: recordUse stamps the key", &ok)
        let reread = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([SSHKey].self, from: $0) }
        check(reread?.first?.lastUsedAt == when, "K5: the stamp reaches keys.json and round-trips", &ok)
    }

    /// The one connect path stamps both, and session restore does not - a
    /// source guard, because the app delegate's connect needs the whole app.
    private static func checkConnectRecordsUse(_ ok: inout Bool) {
        guard let source = SelfTestSources.appDelegateSource() else {
            fail("X2/K5: the app delegate's sources could not be read", &ok)
            return
        }
        guard let start = source.range(of: "func connectToHost(_ host: Host"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
            fail("X2/K5: connectToHost was not found", &ok)
            return
        }
        let body = String(source[start.lowerBound..<end.upperBound])
        check(body.contains("hostStore.recordConnection(id: host.id)"),
              "X2: connectToHost records the connection on the host", &ok)
        check(body.contains("keyStore.recordUse(id: keyID)"),
              "K5: connectToHost records the use on the host's key", &ok)
        check(source.contains("connectToHost(host, recordsConnection: false)"),
              "X2: session restore connects without recording a use", &ok)
    }
}

#endif
