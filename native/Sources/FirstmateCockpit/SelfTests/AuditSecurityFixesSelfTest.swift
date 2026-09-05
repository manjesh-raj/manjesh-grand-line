// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated coverage for the pure-logic half of the full-app
// audit's "Security Enhancements" section
// (`data/grandline-full-app-audit/report.md` §5), fixed in
// `fm/grandline-audit-security-fixes`. Run with:
//
//   swift build && FM_RUN_AUDIT_SECURITY_FIXES_TESTS=1 .build/debug/FirstmateCockpit
//
// Everything here is a value type, a pure function or a source guard, so all
// of it runs in CI. The window-backed half of §5.1 - constructing the two real
// palettes and reading the gate's own registration back - lives in
// `AuditSecurityLockSelfTest`, which needs a login session and is skipped by
// `--ci`, exactly the split `FM_RUN_WHITEBOARD_TESTS` /
// `FM_RUN_WHITEBOARD_VIEW_TESTS` already use.
//
// What each case pins, and why reading the code is not enough:
//
//  - **§5.2 (⌘K's own gate case).** The palette reused `.quickCapture`.
//    Nothing observable changes when a surface shares a neighbour's case -
//    that is the whole problem, and it is why the check is "these two resolve
//    independently", not "the palette is gated".
//  - **§5.3/§5.4 (`WebNavigationPolicy`).** The containment bug was a *string*
//    prefix, so it only shows up for a path that is a genuine string prefix of
//    the allowed directory without being inside it - a case no ordinary
//    navigation produces and no reading of `hasPrefix` makes obvious.
//  - **§5.5 (`isSafeToken`).** Non-ASCII word characters are not shell
//    metacharacters, so nothing misbehaves either way. The property under test
//    is the *claim* the function makes, which only an explicit non-ASCII input
//    can check.
//  - **§5.6 (the Whisper pin).** A self-test cannot download 547MB, so the
//    real content check is driven against small fixtures with their own
//    expected hash, plus a known-answer vector for the streaming hasher, plus
//    a shape check on the pinned constant itself (a truncated or re-cased
//    paste is otherwise invisible until a captain's download fails).
//  - **§5.7.** Verify-only: already fixed in PR #333. Asserted here so the
//    two sections cannot drift apart silently.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import CryptoKit
import Foundation

enum AuditSecurityFixesSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-security-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        print("== full-app audit §5: security enhancements ==")

        case_5_2_unifiedSearchHasItsOwnGateCase(check)
        case_5_1_bothPalettesRegisterWithTheGate(check)
        case_5_3_and_5_4_navigationPolicy(scratch, check)
        case_5_3_bothWebViewsUseThePolicy(check)
        case_5_5_isSafeTokenRequiresASCII(check)
        case_5_6_whisperPin(scratch, check)
        case_5_7_scheduleLogIsAlreadyRedacted(check)

        if failures.isEmpty {
            print("[AuditSecurityFixesSelfTest] PASS")
            return true
        }
        for f in failures { print("[AuditSecurityFixesSelfTest] FAIL: \(f)") }
        return false
    }

    // MARK: - 5.2  ⌘K gets its own AppLockedSurface case

    /// The fix is that `.unifiedSearch` exists and the palette consults *it*.
    /// Both halves are needed: the case alone proves nothing (the call site
    /// could still say `.quickCapture`), and a "the palette is refused while
    /// locked" check passes with the bug present, since `.quickCapture` is
    /// refused too. So this asserts the case exists and is distinct, and a
    /// source guard below binds the call site to it.
    private static func case_5_2_unifiedSearchHasItsOwnGateCase(_ check: (Bool, String) -> Void) {
        print("- 5.2: ⌘K has its own lock-gate case, not ⌥Space's")

        let gate = AppLockGate.shared
        let wasLocked = gate.isLocked
        defer { gate.setLocked(wasLocked) }

        gate.setLocked(true)
        check(!gate.allows(.unifiedSearch), "the ⌘K palette is refused while locked")
        gate.setLocked(false)
        check(gate.allows(.unifiedSearch), "and allowed once unlocked")

        // Distinctness, structurally: two cases that compare equal would be
        // the reused-case bug wearing a new name.
        check(AppLockedSurface.unifiedSearch != AppLockedSurface.quickCapture,
              "`.unifiedSearch` and `.quickCapture` are genuinely different cases")

        guard let source = read("UnifiedSearch.swift") else {
            check(false, "could not read UnifiedSearch.swift to check its gate call site")
            return
        }
        check(source.contains("allows(.unifiedSearch)"),
              "UnifiedSearch consults `.unifiedSearch`")
        check(!source.contains("allows(.quickCapture)"),
              "UnifiedSearch no longer borrows `.quickCapture`'s case")
    }

    // MARK: - 5.1  both always-open palettes register with the lock gate

    /// Source guard. The behavioural half - build the real palettes, read the
    /// gate's registrations back - needs real `NSPanel`s and lives in
    /// `AuditSecurityLockSelfTest`. This one is what fails in CI if the call
    /// disappears from either file.
    private static func case_5_1_bothPalettesRegisterWithTheGate(_ check: (Bool, String) -> Void) {
        print("- 5.1: ⌘K and ⌥Space register as secondary windows")

        for file in ["UnifiedSearch.swift", "ShiftQuickCapture.swift"] {
            guard let source = read(file) else {
                check(false, "could not read \(file)")
                continue
            }
            check(source.contains("AppLockGate.shared.registerSecondaryWindow"),
                  "\(file) registers its panel with the lock gate")
        }
    }

    // MARK: - 5.3 / 5.4  the shared navigation policy

    private static func case_5_3_and_5_4_navigationPolicy(_ scratch: URL, _ check: (Bool, String) -> Void) {
        print("- 5.3/5.4: file-URL containment is component-wise, not a string prefix")

        let root = scratch.appendingPathComponent("docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Inside - every one of these is a real navigation the bundles make.
        check(WebNavigationPolicy.allowsFileURL(root.appendingPathComponent("index.html"), under: root),
              "a file directly inside the directory is allowed")
        check(WebNavigationPolicy.allowsFileURL(root.appendingPathComponent("a/b/c.js"), under: root),
              "a nested file is allowed")
        check(WebNavigationPolicy.allowsFileURL(root, under: root),
              "the directory itself is allowed (the bundle's own base URL)")

        // §5.4's actual bug: a sibling whose path is a string prefix.
        let sibling = scratch.appendingPathComponent("docs-evil", isDirectory: true)
        check(!WebNavigationPolicy.allowsFileURL(sibling.appendingPathComponent("payload.html"), under: root),
              "a sibling directory sharing the name as a string prefix is REFUSED (§5.4)")
        check(!WebNavigationPolicy.allowsFileURL(sibling, under: root),
              "and so is that sibling directory itself")

        // Traversal back out, and out-and-back-in.
        check(!WebNavigationPolicy.allowsFileURL(
                root.appendingPathComponent("../secrets.txt"), under: root),
              "a `..` traversal out of the directory is refused")
        check(WebNavigationPolicy.allowsFileURL(
                root.appendingPathComponent("a/../b.html"), under: root),
              "a `..` that stays inside is still allowed")

        // Elsewhere on disk entirely.
        check(!WebNavigationPolicy.allowsFileURL(URL(fileURLWithPath: "/etc/passwd"), under: root),
              "an unrelated absolute path is refused")

        // §5.3's actual bug: a top-level navigation off the bundle. A CSP
        // cannot stop these, which is the whole reason the delegate exists.
        for remote in ["https://example.com/x", "http://example.com/x",
                       "data:text/html,<b>x", "javascript:alert(1)",
                       "about:blank", "blob:null/abcd"] {
            guard let url = URL(string: remote) else {
                check(false, "could not build the fixture URL \(remote)")
                continue
            }
            check(!WebNavigationPolicy.allowsFileURL(url, under: root),
                  "a `\(url.scheme ?? "?")` navigation is refused (§5.3)")
        }

        // Only a real web URL is handed to the system browser: a refused
        // `file:`/`data:` navigation must not become an `NSWorkspace.open` on
        // the page's say-so.
        check(WebNavigationPolicy.opensExternally(URL(string: "https://example.com")!),
              "https is handed to the browser")
        check(WebNavigationPolicy.opensExternally(URL(string: "HTTP://example.com")!),
              "scheme comparison is case-insensitive")
        for kept in ["file:///etc/passwd", "data:text/html,x", "javascript:alert(1)",
                     "about:blank", "blob:null/abcd", "ftp://example.com"] {
            check(!WebNavigationPolicy.opensExternally(URL(string: kept)!),
                  "a `\(kept.split(separator: ":").first.map(String.init) ?? "?")` refusal is dropped, never opened externally")
        }

        // The bundles' own real index URLs must pass, or the delegate would
        // refuse the very page it is meant to host - which `activate()` would
        // then retry forever.
        if let dir = WhiteboardAssets.webDirectory(), let index = WhiteboardAssets.indexURL() {
            check(WebNavigationPolicy.allowsFileURL(index, under: dir),
                  "the real Excalidraw index.html is allowed under its own bundle dir")
        } else {
            print("[AuditSecurityFixesSelfTest] NOTE: no Excalidraw bundle on this machine - real-index check skipped")
        }
        if let dir = CodePreviewAssets.webDirectory(), let index = CodePreviewAssets.indexURL() {
            check(WebNavigationPolicy.allowsFileURL(index, under: dir),
                  "the real Monaco index.html is allowed under its own bundle dir")
        } else {
            print("[AuditSecurityFixesSelfTest] NOTE: no Monaco bundle on this machine - real-index check skipped")
        }
    }

    /// Source guard: all three web-view hosts route through the one policy,
    /// and neither bundle host has drifted back to a `hasPrefix` of its own.
    /// A behavioural check cannot see a *fourth* host added without one.
    private static func case_5_3_bothWebViewsUseThePolicy(_ check: (Bool, String) -> Void) {
        print("- 5.3: every WKWebView host routes through WebNavigationPolicy")

        for file in ["WhiteboardWebView.swift", "CodePreviewWebView.swift", "DocsController.swift"] {
            guard let source = read(file) else {
                check(false, "could not read \(file)")
                continue
            }
            check(source.contains("decidePolicyFor navigationAction"),
                  "\(file) implements a navigation-policy delegate")
            check(source.contains("WebNavigationPolicy.allowsFileURL"),
                  "\(file) decides containment through the shared policy")
            check(!source.contains(".hasPrefix(docsPath)"),
                  "\(file) no longer uses the string-prefix containment check (§5.4)")
        }

        // The cancel/reload loop guard: a navigation this app *cancels*
        // surfaces as `didFailProvisionalNavigation`, and both bundle hosts
        // answer that by reloading. Without the `NSURLErrorCancelled` early
        // return, refuse -> reload -> refuse spins a web content process
        // forever. Nothing in a headless test can observe that loop, so the
        // guard is asserted at the source.
        for file in ["WhiteboardWebView.swift", "CodePreviewWebView.swift"] {
            guard let source = read(file) else { continue }
            check(source.contains("NSURLErrorCancelled"),
                  "\(file) does not treat its own cancelled navigation as page loss")
        }
    }

    // MARK: - 5.5  isSafeToken requires ASCII

    private static func case_5_5_isSafeTokenRequiresASCII(_ check: (Bool, String) -> Void) {
        print("- 5.5: VaultSource.isSafeToken requires ASCII, matching KubeCommand's")

        for good in ["GRANDLINE_APP_PASSWORD", "gh", "aws-prod", "a1", "A_1-b"] {
            check(VaultSource.isSafeToken(good), "`\(good)` is still accepted")
        }

        // The §5.5 payloads: real Unicode letters and digits, which
        // `Character.isLetter`/`isNumber` accept across the whole of Unicode.
        for nonASCII in ["ПАРОЛЬ",           // Cyrillic letters
                         "ｇｈ",               // fullwidth Latin
                         "secret\u{0660}",   // Arabic-Indic digit
                         "café",             // precomposed é
                         "e\u{0301}"] {      // combining acute
            check(!VaultSource.isSafeToken(nonASCII),
                  "a non-ASCII token is now refused (\(nonASCII.unicodeScalars.map { "U+\(String($0.value, radix: 16, uppercase: true))" }.joined(separator: " ")))")
        }

        // Unchanged: the metacharacters that made this function necessary.
        for bad in ["", "a b", "a;b", "a$b", "a`b", "a|b", "a&b", "../x", "a\nb", "a'b", "a\"b"] {
            check(!VaultSource.isSafeToken(bad), "`\(bad)` is still refused")
        }

        // And the two commands built on it refuse rather than emitting an
        // unquoted token - the actual consequence the check exists for.
        check(VaultSource.saveSecretCommand(name: "ПАРОЛЬ") == nil,
              "`av save` refuses to build a command for a non-ASCII name")
        check(VaultSource.injectCommand(secretName: "ПАРОЛЬ", command: "echo hi") == nil,
              "`av inject` refuses the same")
        check(VaultSource.saveSecretCommand(name: "GRANDLINE_APP_PASSWORD") == "av save GRANDLINE_APP_PASSWORD",
              "a real secret name still produces its real command")

        // Parity with the sibling this was aligned to.
        check(!KubeCommand.isSafeToken("ПАРОЛЬ") && !VaultSource.isSafeToken("ПАРОЛЬ"),
              "both token checks now agree on a non-ASCII input")
    }

    // MARK: - 5.6  the Whisper model is pinned to a SHA-256

    private static func case_5_6_whisperPin(_ scratch: URL, _ check: (Bool, String) -> Void) {
        print("- 5.6: the Whisper model download is pinned to a known SHA-256")

        // The constant itself: a truncated or upper-cased paste is otherwise
        // invisible until a captain's 547MB download fails.
        let pin = WhisperModelManager.expectedSHA256
        check(pin.count == 64, "the pinned digest is 64 hex characters (got \(pin.count))")
        check(pin.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
              "the pinned digest is lowercase hex")
        check(WhisperModelManager.expectedByteCount > 500_000_000,
              "the pinned byte count is the real model's size, not a placeholder")

        // Known-answer vector for the streaming hasher: SHA-256("abc").
        let abc = scratch.appendingPathComponent("abc.bin")
        try? Data("abc".utf8).write(to: abc)
        check(WhisperModelManager.sha256Hex(ofFileAt: abc)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
              "the streaming hasher matches the standard SHA-256(\"abc\") vector")

        // Multi-chunk: bigger than one 4MiB read, so the incremental update
        // path is genuinely exercised rather than a single-shot hash.
        let big = scratch.appendingPathComponent("big.bin")
        var bigBytes = Data([0x6c, 0x6d, 0x67, 0x67])
        bigBytes.append(Data(repeating: 0x5A, count: 11_000_000))
        try? bigBytes.write(to: big)
        let streamed = WhisperModelManager.sha256Hex(ofFileAt: big)
        let oneShot = SHA256.hash(data: bigBytes).map { String(format: "%02x", $0) }.joined()
        check(streamed == oneShot, "a multi-chunk file hashes the same as a one-shot digest")

        // An unreadable path is `nil`, never a digest of nothing.
        check(WhisperModelManager.sha256Hex(ofFileAt: scratch.appendingPathComponent("absent.bin")) == nil,
              "a missing file hashes to nil rather than a plausible-looking digest")

        // The real comparison, driven against the fixture's own true hash.
        let size = Int64(bigBytes.count)
        if case .failure(let e) = WhisperModelManager.verifyPinnedContents(
            fileAt: big, expectedSHA256: oneShot, expectedByteCount: size) {
            check(false, "a file matching its pin was rejected: \(e.message)")
        } else {
            check(true, "a file matching its pin is accepted")
        }
        check(caseInsensitiveAccepted(big, oneShot.uppercased(), size),
              "the digest comparison is case-insensitive")

        // Wrong content, right size - the tampering shape the pin exists for,
        // and the one the old size+magic validation accepted happily.
        var tampered = bigBytes
        tampered[tampered.count - 1] = 0x00
        let tamperedURL = scratch.appendingPathComponent("tampered.bin")
        try? tampered.write(to: tamperedURL)
        check(isRejected(WhisperModelManager.verifyPinnedContents(
                fileAt: tamperedURL, expectedSHA256: oneShot, expectedByteCount: size)),
              "a same-size file with one byte changed is REFUSED")
        // ...and the pre-fix structural check would have waved it through, so
        // the two checks are genuinely testing different things.
        check(!isRejected(WhisperModelManager.validate(fileAt: tamperedURL)),
              "the structural check alone still accepts it - the pin is what catches it")

        // Truncated: reported as an unfinished download, not as a mismatch.
        let shortURL = scratch.appendingPathComponent("short.bin")
        try? bigBytes.prefix(9_000_000).write(to: shortURL)
        if case .failure(let e) = WhisperModelManager.verifyPinnedContents(
            fileAt: shortURL, expectedSHA256: oneShot, expectedByteCount: size) {
            check(e.message.contains("did not finish"),
                  "a truncated download says so, rather than reporting a checksum mismatch")
        } else {
            check(false, "a truncated download was accepted")
        }

        // `validateDownload` is the composition the download path uses: a
        // structurally-fine file that is not the pinned model is refused.
        check(isRejected(WhisperModelManager.validateDownload(fileAt: big)),
              "validateDownload refuses a well-formed file that is not the pinned model")

        // Source guard: the download path must call the composed check. A
        // future edit calling `validate` alone would silently drop the pin,
        // and nothing observable here would change.
        if let source = read("WhisperModel.swift") {
            check(source.contains("Self.validateDownload(fileAt: location)"),
                  "didFinishDownloadingTo runs the pinned check, not the structural one alone")
        } else {
            check(false, "could not read WhisperModel.swift")
        }

        // Opt-in: when a real model is on this machine, prove the pin is the
        // hash of the bytes this app actually downloads - the one check that
        // makes the constant more than a well-formed string.
        let realPath = ProcessInfo.processInfo.environment["FM_WHISPER_TEST_MODEL_PATH"]
            ?? WhisperModelManager.shared.modelPathOnDisk
        if FileManager.default.fileExists(atPath: realPath) {
            let url = URL(fileURLWithPath: realPath)
            if case .failure(let e) = WhisperModelManager.verifyPinnedContents(fileAt: url) {
                check(false, "the real model on this machine failed the pin: \(e.message)")
            } else {
                check(true, "the real downloaded model on this machine matches the pin")
            }
        } else {
            print("[AuditSecurityFixesSelfTest] NOTE: no real Whisper model on this machine - the pin's value is verified by its four sources (see WhisperModel.swift), not by this run")
        }
    }

    private static func caseInsensitiveAccepted(_ url: URL, _ digest: String, _ size: Int64) -> Bool {
        !isRejected(WhisperModelManager.verifyPinnedContents(
            fileAt: url, expectedSHA256: digest, expectedByteCount: size))
    }

    private static func isRejected(_ result: Result<Void, WhisperModelValidationError>) -> Bool {
        if case .failure = result { return true }
        return false
    }

    // MARK: - 5.7  verify only: already fixed in PR #333

    /// §5.7 and §6.4 were the same finding, double-counted across two sections;
    /// the Feature Enhancements task fixed it. Re-asserted here so removing the
    /// redaction cannot pass a §5 run while only a §6 test notices - and so a
    /// future reader of §5 can see it is genuinely covered rather than skipped.
    private static func case_5_7_scheduleLogIsAlreadyRedacted(_ check: (Bool, String) -> Void) {
        print("- 5.7: (verify only, fixed in PR #333) a schedule run's log is redacted before it is persisted")

        let secret = "ghp_auditFiveSevenVerifyOnly1234567890"
        let entry = ScheduleRunHistoryEntry(
            scheduleID: UUID(), at: Date(timeIntervalSince1970: 1_700_000_000), verdict: .clean,
            summary: "synced", actionTitle: "Fork sync",
            log: "remote: https://x-access-token:\(secret)@github.com/o/r.git\nEverything up-to-date")

        guard let stored = entry.log else {
            check(false, "the entry lost its log entirely")
            return
        }
        check(!stored.contains(secret), "the literal token does not survive into the stored entry")
        check(stored.contains(LogRedactor.placeholder), "the stored log carries a redaction marker")
        check(stored.contains("Everything up-to-date"),
              "the surrounding output survives - \"View Log\" still shows the real run")
    }

    // MARK: - helpers

    /// A source file with its full-line `//` comments stripped.
    ///
    /// Every guard below greps for *code*, and this file's own fixes are
    /// documented in comments that necessarily quote the pattern they
    /// replaced ("this was `path.hasPrefix(docsPath)`"). Without this, a guard
    /// asserting that pattern is gone fails on the comment explaining that it
    /// is gone - which is exactly what happened on this suite's first run.
    /// Only whole-line comments are dropped, so a `https://` inside a string
    /// literal is untouched.
    private static func read(_ fileName: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        guard let raw = try? String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8) else {
            return nil
        }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

#endif
