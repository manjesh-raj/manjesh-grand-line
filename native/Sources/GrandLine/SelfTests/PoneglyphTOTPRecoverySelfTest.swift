// Grand Line - native macOS app.
//
// F16/F17's pure-logic half: RFC 6238 against the RFC's own published test
// vectors, the password generator's alphabets and entropy arithmetic, the
// recovery key's wrap/unwrap round trip through a real `CredentialVaultStore`
// on a scratch directory, and the three CSV importers against real export
// headers.
//
// **Pure logic, so it is deliberately NOT in `NEEDS_SESSION`** - it mounts no
// window and builds no view, which under AGENTS.md's "Writing a self-test"
// rule is what decides whether a suite guards the *blocking* CI job. The
// window-backed half (the ring, the generator UI, the recovery sheet, the
// menu-bar popover) is `PoneglyphTOTPRecoveryViewSelfTest`, exactly the
// `FM_RUN_CREDENTIAL_VAULT_TESTS`/`..._VIEW_TESTS` split that already exists
// one file over.
//
// **Why the RFC's vectors and not "it produced six digits".** A TOTP
// implementation that is wrong by one byte of the dynamic truncation, or that
// gets the counter's endianness backwards, still produces six plausible
// digits forever - and the captain would discover it at an AWS console at
// 2am. RFC 6238 Appendix B publishes eight (time, algorithm, code) triples
// for exactly this purpose; all eight are asserted below, across all three
// hash functions. A drifted implementation fails by name.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum PoneglyphTOTPRecoverySelfTest {

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        checkRFC6238Vectors(check)
        checkBase32(check)
        checkOtpauthParsing(check)
        checkCountdown(check)
        checkPasswordGenerator(check)
        checkRecoveryRoundTrip(check)
        checkRecoveryCodeFormatting(check)
        checkCSVParser(check)
        checkImporters(check)

        if failures.isEmpty {
            print("[poneglyph-f16-f17] OK - all TOTP / generator / recovery / import checks passed")
            return true
        }
        for failure in failures { print("[poneglyph-f16-f17] FAIL: \(failure)") }
        return false
    }

    // MARK: - RFC 6238

    /// RFC 6238 Appendix B's table, verbatim. The seeds are the RFC's own
    /// ASCII strings ("12345678901234567890" repeated to the hash's block
    /// size), base32-encoded here because that is the form this app stores -
    /// which also means a broken `base32Encode`/`base32Decode` pair fails
    /// these vectors rather than hiding behind them.
    private static func checkRFC6238Vectors(_ check: (Bool, String) -> Void) {
        let sha1Seed = Data("12345678901234567890".utf8)
        let sha256Seed = Data("12345678901234567890123456789012".utf8)
        let sha512Seed = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

        // The RFC's seeds are exactly the block sizes it says they are; if
        // this ever drifts the vectors below would fail for the wrong
        // reason, so the fixture asserts its own shape first (AGENTS.md's
        // "a check that cannot fail is worse than no check").
        check(sha1Seed.count == 20, "the RFC's SHA1 seed must be 20 bytes, got \(sha1Seed.count)")
        check(sha256Seed.count == 32, "the RFC's SHA256 seed must be 32 bytes, got \(sha256Seed.count)")
        check(sha512Seed.count == 64, "the RFC's SHA512 seed must be 64 bytes, got \(sha512Seed.count)")

        let vectors: [(time: TimeInterval, algorithm: VaultTOTP.Algorithm, seed: Data, expected: String)] = [
            (59, .sha1, sha1Seed, "94287082"),
            (59, .sha256, sha256Seed, "46119246"),
            (59, .sha512, sha512Seed, "90693936"),
            (1_111_111_109, .sha1, sha1Seed, "07081804"),
            (1_111_111_111, .sha1, sha1Seed, "14050471"),
            (1_234_567_890, .sha1, sha1Seed, "89005924"),
            (2_000_000_000, .sha256, sha256Seed, "90698825"),
            (20_000_000_000, .sha512, sha512Seed, "47863826"),
        ]

        for vector in vectors {
            // Through the real stored shape - a base32 secret in a
            // `VaultTOTP`, resolved at a `Date` - rather than by calling the
            // raw HMAC helper. That is what the app actually does, so this
            // asserts the whole path including the counter arithmetic.
            let config = VaultTOTP(secret: TOTP.base32Encode(vector.seed),
                                   digits: 8,
                                   period: 30,
                                   algorithm: vector.algorithm)
            let produced = TOTP.code(config, at: Date(timeIntervalSince1970: vector.time))
            check(produced == vector.expected,
                  "RFC 6238 vector T=\(Int(vector.time)) \(vector.algorithm.displayName): expected \(vector.expected), got \(produced ?? "nil")")
        }

        // The vectors are 8-digit by the RFC's own choice; the app's default
        // is 6, which is the last 6 digits of the same truncation. Asserted
        // so a `digits` bug cannot hide behind a table that never uses the
        // default.
        let six = VaultTOTP(secret: TOTP.base32Encode(sha1Seed), digits: 6, period: 30, algorithm: .sha1)
        check(TOTP.code(six, at: Date(timeIntervalSince1970: 59)) == "287082",
              "the 6-digit default must be the low six digits of the RFC's 8-digit vector")
    }

    // MARK: - Base32

    private static func checkBase32(_ check: (Bool, String) -> Void) {
        // RFC 4648's own vectors, so this is not self-referential.
        check(TOTP.base32Encode(Data("foobar".utf8)) == "MZXW6YTBOI======",
              "base32('foobar') must be MZXW6YTBOI====== per RFC 4648, got \(TOTP.base32Encode(Data("foobar".utf8)))")
        check(TOTP.base32Decode("MZXW6YTBOI======") == Data("foobar".utf8),
              "base32 must round-trip RFC 4648's own vector")
        // The tolerances a pasted secret actually needs.
        let canonical = TOTP.base32Decode("JBSWY3DPEHPK3PXP")
        check(canonical != nil, "a canonical base32 secret must decode")
        check(TOTP.base32Decode("jbsw y3dp ehpk 3pxp") == canonical,
              "lower case and spaces must decode identically - that is how every authenticator prints a seed")
        check(TOTP.base32Decode("JBSW-Y3DP-EHPK-3PXP") == canonical, "dash separators must decode identically")
        // And the one thing it must refuse: a character outside the
        // alphabet, which is a typo rather than a secret. Silently skipping
        // it would produce a confidently wrong code forever.
        check(TOTP.base32Decode("JBSWY3DP!HPK3PXP") == nil, "a character outside the alphabet must fail, not be skipped")
        check(TOTP.base32Decode("") == nil, "an empty secret is not a secret")
        check(TOTP.base32Decode("A") == nil, "a secret too short to yield one whole byte must fail")
        check(TOTP.base32Decode("AB")?.count == 1, "two base32 characters are ten bits, which is one whole byte")
    }

    // MARK: - otpauth:// URIs

    private static func checkOtpauthParsing(_ check: (Bool, String) -> Void) {
        let uri = "otpauth://totp/GitHub:manjesh?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&algorithm=SHA256&digits=8&period=60"
        guard let parsed = TOTP.parse(uri) else {
            check(false, "a full otpauth URI must parse")
            return
        }
        check(parsed.secret == "JBSWY3DPEHPK3PXP", "the secret must come from the query, got \(parsed.secret)")
        check(parsed.issuer == "GitHub", "the issuer must be read, got \(parsed.issuer)")
        check(parsed.algorithm == .sha256, "algorithm=SHA256 must be honoured, got \(parsed.algorithm.rawValue)")
        check(parsed.digits == 8, "digits=8 must be honoured, got \(parsed.digits)")
        check(parsed.period == 60, "period=60 must be honoured, got \(parsed.period)")

        // The defaults a bare URI means.
        let bare = TOTP.parse("otpauth://totp/AWS?secret=JBSWY3DPEHPK3PXP")
        check(bare?.digits == 6 && bare?.period == 30 && bare?.algorithm == .sha1,
              "a URI with no parameters must default to RFC 6238's 6/30/SHA1")
        // The label's `Issuer:account` form, when there is no issuer= param.
        check(TOTP.parse("otpauth://totp/AWS:root?secret=JBSWY3DPEHPK3PXP")?.issuer == "AWS",
              "the issuer must fall back to the label prefix")
        // A plain base32 string is the other realistic paste.
        check(TOTP.parse("jbsw y3dp ehpk 3pxp")?.secret.isEmpty == false, "a bare base32 seed must be accepted")
        // And the refusals. Each of these would otherwise store a "2FA
        // secret" that produces wrong codes forever, silently.
        check(TOTP.parse("hotp://totp/x?secret=JBSWY3DPEHPK3PXP") == nil, "hotp:// is counter-based and is not implemented - it must be refused")
        check(TOTP.parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP") == nil, "an otpauth hotp URI must be refused")
        check(TOTP.parse("otpauth://totp/x?issuer=GitHub") == nil, "a URI with no secret must be refused")
        check(TOTP.parse("hunter2!") == nil, "a pasted password must not be accepted as a base32 seed")
        check(TOTP.parse("   ") == nil, "whitespace is not a seed")

        // B19: a scanned or pasted URI is arbitrary text, and a repeated query
        // parameter **trapped** - `Fatal error: Duplicate values for key`,
        // taking the app down from a QR code.
        let repeated = TOTP.parse(
            "otpauth://totp/GitHub:manjesh?secret=JBSWY3DPEHPK3PXP&secret=JBSWY3DPEHPK3PXP"
            + "&issuer=GitHub&issuer=Evil&digits=8&digits=6")
        check(repeated != nil,
              "a URI with a repeated parameter must parse rather than kill the process (B19)")
        check(repeated?.issuer == "GitHub",
              "and the FIRST occurrence wins, got \(repeated?.issuer ?? "nil")")
        check(repeated?.digits == 8,
              "for every repeated parameter, got \(repeated?.digits ?? -1)")
    }

    // MARK: - The countdown

    private static func checkCountdown(_ check: (Bool, String) -> Void) {
        let config = VaultTOTP(secret: "JBSWY3DPEHPK3PXP")
        // A period boundary: at exactly T=60 a 30s window has just started.
        check(TOTP.secondsRemaining(config, at: Date(timeIntervalSince1970: 60)) == 30,
              "a fresh window must report the full period")
        check(TOTP.secondsRemaining(config, at: Date(timeIntervalSince1970: 89)) == 1,
              "one second before rotation must report 1, got \(TOTP.secondsRemaining(config, at: Date(timeIntervalSince1970: 89)))")
        check(abs(TOTP.fractionRemaining(config, at: Date(timeIntervalSince1970: 75)) - 0.5) < 0.001,
              "halfway through a window the ring must be half full")
        // The code really does change across the boundary - without this the
        // two checks above could both pass over a frozen code.
        let before = TOTP.code(config, at: Date(timeIntervalSince1970: 89))
        let after = TOTP.code(config, at: Date(timeIntervalSince1970: 90))
        check(before != after, "the code must rotate at the period boundary")
        check(TOTP.code(config, at: Date(timeIntervalSince1970: 61)) == before,
              "the code must be stable within one window")
        check(TOTP.grouped("418902") == "418\u{2009}902", "a six-digit code must be grouped for reading")
    }

    // MARK: - The password generator

    /// A deterministic generator, so the *shape* of the output can be
    /// asserted rather than only its statistics. Not a security claim about
    /// production, which uses `CryptoRandomNumberGenerator` - see that type.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static func checkPasswordGenerator(_ check: (Bool, String) -> Void) {
        // The word list's size is load-bearing: the entropy arithmetic in
        // `PasswordGenerator` is stated as exactly 8 bits per word, which is
        // only true at 256. A list that drifts makes every printed figure a
        // lie, silently.
        check(PasswordGenerator.wordList.count == 256,
              "the word list must be exactly 256 words for 8 bits each, got \(PasswordGenerator.wordList.count)")
        check(Set(PasswordGenerator.wordList).count == 256, "every word must be distinct or the entropy is overstated")
        check(PasswordGenerator.wordList.allSatisfy { $0.allSatisfy { $0.isLowercase && $0.isLetter } },
              "every word must be plain lower-case letters - a word with a digit or a dash breaks the separator")

        var rng = SeededRNG(state: 20_260_921)
        // Random mode: every class present when asked for, none when not.
        let all = PasswordGenerator.generate(.init(mode: .random, length: 24,
                                                    useDigits: true, useSymbols: true, useUppercase: true),
                                              using: &rng)
        check(all.value.count == 24, "a 24-character random password must be 24 characters, got \(all.value.count)")
        check(abs(all.entropyBits - log2(Double(PasswordGenerator.lowercase.count
                                                + PasswordGenerator.uppercase.count
                                                + PasswordGenerator.digits.count
                                                + PasswordGenerator.symbols.count)) * 24) < 0.01,
              "the entropy figure must be log2(alphabet) * length, got \(all.entropyBits)")

        let lettersOnly = PasswordGenerator.generate(.init(mode: .random, length: 40,
                                                            useDigits: false, useSymbols: false, useUppercase: false),
                                                      using: &rng)
        check(lettersOnly.value.allSatisfy { PasswordGenerator.lowercase.contains($0) },
              "with every class off, only the lower-case alphabet may be used: \(lettersOnly.value)")
        // The discriminating half: a 40-character sample from a 25-letter
        // alphabet that contains no digit is evidence only if digits were
        // genuinely reachable in the other call.
        check(all.value.contains(where: { PasswordGenerator.digits.contains($0) }),
              "the all-classes sample must actually contain a digit, or the check above proves nothing")

        // No ambiguous glyphs anywhere, in any mode - the reason those
        // characters are excluded at all.
        let ambiguous = Set("IOl10")
        for _ in 0..<40 {
            let sample = PasswordGenerator.generate(.init(mode: .random, length: 32), using: &rng)
            if sample.value.contains(where: { ambiguous.contains($0) && $0 != "0" && $0 != "1" }) {
                check(false, "a random password must contain no ambiguous letter: \(sample.value)")
                break
            }
        }

        // PIN mode.
        let pin = PasswordGenerator.generate(.init(mode: .pin, length: 8), using: &rng)
        check(pin.value.count == 8 && pin.value.allSatisfy(\.isNumber), "a PIN must be digits only, got \(pin.value)")
        check(abs(pin.entropyBits - log2(10.0) * 8) < 0.01, "an 8-digit PIN is log2(10)*8 bits, got \(pin.entropyBits)")

        // Words mode: the mockup's own shape - words joined by a separator,
        // one capitalised, a digit at the end.
        let phrase = PasswordGenerator.generate(.init(mode: .words, length: 4,
                                                       useDigits: true, useSymbols: false, useUppercase: true),
                                                 using: &rng)
        let words = phrase.value.dropLast().split(separator: "-").map(String.init)
        check(words.count == 4, "a 4-word passphrase must have four words, got \(words.count) from \(phrase.value)")
        check(phrase.value.last?.isNumber == true, "a digit must be appended when digits are on: \(phrase.value)")
        check(words.contains { $0.first?.isUppercase == true }, "one word must be capitalised: \(phrase.value)")
        check(words.allSatisfy { PasswordGenerator.wordList.contains($0.lowercased()) },
              "every word must come from the list: \(phrase.value)")
        check(abs(phrase.entropyBits - (8.0 * 4 + log2(4.0) + log2(10.0))) < 0.01,
              "a 4-word phrase with a capital and a digit is 8*4 + log2(4) + log2(10) bits, got \(phrase.entropyBits)")

        // The length clamps: a slider cannot be dragged out of range, but a
        // caller could pass anything.
        check(PasswordGenerator.generate(.init(mode: .pin, length: 99), using: &rng).value.count
                == PasswordGenerator.Mode.pin.lengthRange.upperBound,
              "an out-of-range length must clamp rather than produce a 99-digit PIN")

        // The bands the chip prints.
        check(GeneratedPassword(value: "x", entropyBits: 40).strengthLabel == "fair", "40 bits reads as fair")
        check(GeneratedPassword(value: "x", entropyBits: 70).strengthLabel == "strong", "70 bits reads as strong")
        check(GeneratedPassword(value: "x", entropyBits: 130).strengthLabel == "very strong", "130 bits reads as very strong")

        // The production entry point really does produce different values -
        // the one property a deterministic RNG cannot assert.
        let live = Set((0..<8).map { _ in PasswordGenerator.generate(.init(mode: .random, length: 20)).value })
        check(live.count == 8, "eight live generations must all differ - a stuck RNG would collapse them")
    }

    // MARK: - The recovery key (F17)

    /// The load-bearing case of this whole feature: a recovery key must open
    /// the *same* vault, and a wrong one must not.
    ///
    /// Driven through a real `CredentialVaultStore` on a scratch directory
    /// rather than against `CredentialVaultRecovery` alone, because the
    /// claim worth asserting is "the recovered key decrypts the captain's
    /// real items", not "AES-GCM round-trips 32 bytes".
    private static func checkRecoveryRoundTrip(_ check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("poneglyph-recovery-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let password = "correct horse battery staple"
        let store = CredentialVaultStore(root: scratch)
        guard case .success = store.createVault(masterPassword: password) else {
            check(false, "could not create a scratch vault")
            return
        }
        var secret = VaultCredential(title: "AWS root", account: "root@example.com", secret: "s3cr3t-value")
        secret.totp = VaultTOTP(secret: "JBSWY3DPEHPK3PXP")
        guard case .success = store.add(secret) else {
            check(false, "could not add a credential to the scratch vault")
            return
        }
        check(!store.hasRecoveryKey, "a fresh vault must have no recovery key")

        let code: String
        switch store.enrollRecoveryKey() {
        case .success(let printed): code = printed
        case .failure(let error):
            check(false, "enrolling a recovery key failed: \(error.localizedDescription)")
            return
        }
        check(store.hasRecoveryKey, "the vault must report a recovery key after enrolling one")
        check(CredentialVaultRecovery.looksWellFormed(code), "the printed code must be well formed: \(code)")
        check(store.auditLog.contains { $0.kind == .recoveryKeyPrinted },
              "printing a recovery key must leave an audit event")

        // It must be on *disk*, not only in memory - the whole point is that
        // it survives to the machine that needs it.
        store.lock(reason: "self-test")
        let reopened = CredentialVaultStore(root: scratch)
        check(reopened.loadState() == .present, "the vault file must still be present after locking")

        // 1. The recovery key opens the same vault, and the items decrypt.
        var recovered: VaultUnlockOutcome?
        let unlockDone = DispatchSemaphore(value: 0)
        reopened.unlockWithRecoveryKey(code) { outcome in
            recovered = outcome
            unlockDone.signal()
        }
        pump(until: unlockDone)
        check(recovered == .unlocked, "the recovery key must unlock the vault, got \(String(describing: recovered))")
        check(reopened.credentials.first?.secret == "s3cr3t-value",
              "the recovered key must decrypt the real item, got \(reopened.credentials.first?.secret ?? "nil")")
        check(reopened.credentials.first?.totp?.secret == "JBSWY3DPEHPK3PXP",
              "the TOTP seed must survive the round trip through the sealed payload")
        check(reopened.unlockedViaRecoveryKey, "the session must know it was opened with the recovery key")

        // 2. A wrong code of the right shape must fail. Same length, same
        //    alphabet, one character different - which is the realistic
        //    mistyping, and the case a weak comparison would let through.
        reopened.lock(reason: "self-test")
        let wrongCode = mutateOneCharacter(of: code)
        check(CredentialVaultRecovery.normalize(wrongCode) != CredentialVaultRecovery.normalize(code),
              "the fixture's 'wrong' code must really differ from the right one")
        var wrongOutcome: VaultUnlockOutcome?
        let wrongDone = DispatchSemaphore(value: 0)
        reopened.unlockWithRecoveryKey(wrongCode) { outcome in
            wrongOutcome = outcome
            wrongDone.signal()
        }
        pump(until: wrongDone)
        if case .wrongPassword = wrongOutcome {} else {
            check(false, "a wrong recovery key must be refused as a wrong attempt, got \(String(describing: wrongOutcome))")
        }
        check(!reopened.isUnlocked, "a wrong recovery key must leave the vault locked")

        // 3. The password path is untouched by any of this - the central
        //    claim of the design. Same password, same items, after a
        //    recovery key exists.
        var passwordOutcome: VaultUnlockOutcome?
        let passwordDone = DispatchSemaphore(value: 0)
        reopened.unlock(masterPassword: password) { outcome in
            passwordOutcome = outcome
            passwordDone.signal()
        }
        pump(until: passwordDone)
        check(passwordOutcome == .unlocked, "the master password must still unlock a vault with a recovery key enrolled")
        check(!reopened.unlockedViaRecoveryKey, "a password unlock must not set the recovery flag")

        // 4. A password change invalidates the kit, deliberately. This is the
        //    property a future maintainer is most likely to "fix" into a
        //    silent one, so it is asserted rather than only documented.
        let changed = DispatchSemaphore(value: 0)
        var changeResult: Result<Void, Error>?
        reopened.changeMasterPassword(currentPassword: password, newPassword: "an entirely different passphrase") { result in
            changeResult = result
            changed.signal()
        }
        pump(until: changed)
        if case .failure(let error)? = changeResult {
            check(false, "the password change failed: \(error.localizedDescription)")
        }
        check(!reopened.hasRecoveryKey, "a password change must drop the recovery wrap - it holds the old key's bytes")
        reopened.lock(reason: "self-test")
        var afterRekey: VaultUnlockOutcome?
        let afterDone = DispatchSemaphore(value: 0)
        CredentialVaultStore(root: scratch).unlockWithRecoveryKey(code) { outcome in
            afterRekey = outcome
            afterDone.signal()
        }
        pump(until: afterDone)
        if case .failed = afterRekey {} else {
            check(false, "the old recovery key must no longer be offered a door at all, got \(String(describing: afterRekey))")
        }

        // 5. Removing a kit really removes it.
        let fresh = CredentialVaultStore(root: scratch)
        let reopen2 = DispatchSemaphore(value: 0)
        fresh.unlock(masterPassword: "an entirely different passphrase") { _ in reopen2.signal() }
        pump(until: reopen2)
        guard case .success(let code2) = fresh.enrollRecoveryKey() else {
            check(false, "could not enrol a second recovery key")
            return
        }
        check(fresh.hasRecoveryKey, "the second kit must be enrolled")
        _ = fresh.removeRecoveryKey()
        check(!fresh.hasRecoveryKey, "removing the kit must clear it")
        check(code2 != code, "two enrolments must not produce the same code")
    }

    private static func checkRecoveryCodeFormatting(_ check: (Bool, String) -> Void) {
        let code = CredentialVaultRecovery.newCode()
        let normalized = CredentialVaultRecovery.normalize(code)
        check(normalized.count == CredentialVaultRecovery.codeCharacterCount,
              "a fresh code must normalise to \(CredentialVaultRecovery.codeCharacterCount) characters, got \(normalized.count)")
        check(normalized.count == 32, "20 random bytes must print as 32 base32 characters, got \(normalized.count)")
        check(code.contains(" \u{00B7} "), "the printed form must be grouped for transcription: \(code)")
        check(code.split(separator: "\u{00B7}").count == 8, "the printed form must be eight groups: \(code)")

        // Crockford's aliases, which is the whole reason for that alphabet.
        let typed = normalized.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "I")
        check(CredentialVaultRecovery.normalize(typed) == normalized,
              "O/I must normalise back to 0/1 - a captain transcribing by hand will type letters")
        check(CredentialVaultRecovery.normalize(code.lowercased()) == normalized, "lower case must normalise")
        check(CredentialVaultRecovery.normalize("  \(code)  \n") == normalized, "surrounding whitespace must normalise away")
        check(!CredentialVaultRecovery.looksWellFormed(String(normalized.dropLast())),
              "a code one character short must not look well formed")

        // A fresh code must never be all one character or obviously
        // structured - a cheap but real smoke test on the randomness source.
        let codes = (0..<20).map { _ in CredentialVaultRecovery.normalize(CredentialVaultRecovery.newCode()) }
        check(Set(codes).count == 20, "twenty codes must all differ")
        check(codes.allSatisfy { Set($0).count > 8 }, "a code drawn from 32 symbols should not repeat a handful of characters")
        check(codes.allSatisfy { !$0.contains("U") && !$0.contains("I") && !$0.contains("L") && !$0.contains("O") },
              "Crockford's alphabet excludes I, L, O and U - a code must never contain one")
    }

    // MARK: - CSV

    private static func checkCSVParser(_ check: (Bool, String) -> Void) {
        let text = "a,b,c\n1,\"two, with comma\",3\n4,\"a \"\"quoted\"\" word\",6\n7,\"line\nbreak\",9\n"
        let rows = CSVParser.parse(text)
        check(rows.count == 4, "four rows expected (header + 3), got \(rows.count)")
        check(rows[1] == ["1", "two, with comma", "3"], "a quoted comma must stay inside its field: \(rows[1])")
        check(rows[2] == ["4", "a \"quoted\" word", "6"], "\"\" must unescape to one quote: \(rows[2])")
        check(rows[3] == ["7", "line\nbreak", "9"], "a quoted newline must stay inside its field: \(rows[3])")
        // CRLF, which is what a Windows-exported CSV actually contains.
        let crlf = CSVParser.parse("a,b\r\n1,2\r\n")
        check(crlf.count == 2, "CRLF line endings must parse as two rows, got \(crlf.count): \(crlf)")
        check(crlf.last == ["1", "2"], "and a CRLF must not end up inside a field value: \(crlf)")
        check(CSVParser.parse("a,b\r1,2\r").count == 2, "a bare CR (classic Mac) must also end a row")
        check(CSVParser.parse("").isEmpty, "an empty file must parse to no rows")
    }

    private static func checkImporters(_ check: (Bool, String) -> Void) {
        // 1Password 8's real export header and a realistic row.
        let onePassword = """
        Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes
        Work Gmail,https://mail.google.com,manjesh@example.com,hunter2,otpauth://totp/Google:manjesh?secret=JBSWY3DPEHPK3PXP&issuer=Google,false,false,work\\,email,my notes
        AWS root,https://console.aws.amazon.com,root,rootpass,,true,false,,
        ,,,,,,,,
        """
        let onePlan = CredentialVaultImport.plan(text: onePassword)
        check(onePlan.source == .onePassword, "the 1Password header must be detected, got \(onePlan.source.rawValue)")
        check(onePlan.credentials.count == 2, "two importable rows expected, got \(onePlan.credentials.count)")
        check(onePlan.skipped.count == 1, "the empty row must be skipped and reported, got \(onePlan.skipped.count) skips")
        let gmail = onePlan.credentials.first
        check(gmail?.title == "Work Gmail", "the title column must map to the title, got \(gmail?.title ?? "nil")")
        check(gmail?.account == "manjesh@example.com", "the username column must map to the account")
        check(gmail?.secret == "hunter2", "the password column must map to the secret")
        check(gmail?.location == "https://mail.google.com", "the url column must map to the location")
        check(gmail?.totp?.secret == "JBSWY3DPEHPK3PXP", "the OTPAuth column must be parsed into a TOTP config")
        check(gmail?.category == .email, "a mail.google.com row should land in Email, got \(gmail?.category.rawValue ?? "nil")")
        check(onePlan.credentials[1].category == .cloud, "a console.aws.amazon.com row should land in Cloud & AWS")
        check(gmail?.kind == .login, "a 1Password row with a password is a login")

        // Bitwarden, including its secure-note row - the one export that
        // states the kind.
        let bitwarden = """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Work,0,login,GitHub,,,0,https://github.com,manjesh,ghpass,JBSWY3DPEHPK3PXP
        Ops,0,note,Bastion break-glass,"Step 1: call the on-call.\nStep 2: use the jump host.",,0,,,,
        Ops,0,note,Empty note,,,0,,,,
        """
        let bwPlan = CredentialVaultImport.plan(text: bitwarden)
        check(bwPlan.source == .bitwarden, "the Bitwarden header must be detected, got \(bwPlan.source.rawValue)")
        check(bwPlan.credentials.count == 2, "two importable Bitwarden rows expected, got \(bwPlan.credentials.count)")
        check(bwPlan.credentials[0].kind == .login, "a Bitwarden login row must import as a login")
        check(bwPlan.credentials[0].totp?.secret == "JBSWY3DPEHPK3PXP", "a bare base32 login_totp must be accepted")
        check(bwPlan.credentials[0].tags == ["Work"], "the folder column must become a tag, got \(bwPlan.credentials[0].tags)")
        let note = bwPlan.credentials[1]
        check(note.kind == .secureNote, "a Bitwarden note row must import as a secure note")
        check(note.secret.contains("on-call"), "a note's body must land in the sealed secret field, got \(note.secret)")
        check(bwPlan.skipped.contains { $0.reason.contains("Empty note") },
              "a note with no body must be skipped by name, got \(bwPlan.skipped.map(\.reason))")

        // Chrome.
        let chrome = """
        name,url,username,password,note
        example.com,https://example.com/login,me@example.com,pw1,
        nopassword.com,https://nopassword.com,,,
        """
        let chromePlan = CredentialVaultImport.plan(text: chrome)
        check(chromePlan.source == .chrome, "the Chrome header must be detected, got \(chromePlan.source.rawValue)")
        check(chromePlan.credentials.count == 1, "one importable Chrome row expected, got \(chromePlan.credentials.count)")
        check(chromePlan.skipped.count == 1, "the row with no password must be skipped and reported")

        // A column order this app has never seen - the reason the mapping is
        // resolved by name rather than by index. Swapping two columns must
        // not swap two fields.
        let reordered = """
        Password,Title,Username,Url
        swapped-secret,Reordered,me,https://x.test
        """
        let reorderedPlan = CredentialVaultImport.plan(text: reordered, source: .onePassword)
        check(reorderedPlan.credentials.first?.secret == "swapped-secret",
              "a reordered export must still map by column name, got \(reorderedPlan.credentials.first?.secret ?? "nil")")
        check(reorderedPlan.credentials.first?.title == "Reordered", "and the title with it")

        // Duplicates are counted against what is already in the vault, never
        // merged behind the captain's back.
        let existing = [VaultCredential(title: "Work Gmail", account: "manjesh@example.com", secret: "old")]
        let dupePlan = CredentialVaultImport.plan(text: onePassword, existing: existing)
        check(dupePlan.duplicateTitles == ["Work Gmail"], "an existing title+account must be flagged, got \(dupePlan.duplicateTitles)")
        check(dupePlan.credentials.count == 2, "a duplicate is still importable - flagging is not filtering")

        // A garbage file reports rather than crashing or importing nothing
        // silently.
        let garbage = CredentialVaultImport.plan(text: "one,two,three\nred,green,blue")
        check(garbage.credentials.isEmpty, "a file with no recognisable columns must import nothing")
        check(!garbage.skipped.isEmpty, "and must say why")

        // A malformed 2FA column costs the seed, not the credential.
        let badOTP = """
        Title,Username,Password,OTPAuth
        Thing,me,pw,not-a-seed!!
        """
        let badPlan = CredentialVaultImport.plan(text: badOTP)
        check(badPlan.credentials.count == 1, "a row with an unreadable 2FA seed must still import")
        check(badPlan.credentials.first?.totp == nil, "but without a 2FA config that would produce wrong codes")
        check(badPlan.skipped.contains { $0.reason.contains("2FA") }, "and the loss must be reported")

        // The mapping the sheet renders is derived from the mapping used.
        let rows = onePlan.mapping.rows(header: onePlan.header)
        check(rows.first(where: { $0.column == "Title" })?.field == "Title", "the sheet's mapping list must show Title → Title")
        check(rows.first(where: { $0.column == "Favorite" })?.field == "Skip", "an unmapped column must read Skip")
    }

    // MARK: - Helpers

    /// Change exactly one character of a code to a different symbol from the
    /// same alphabet, so the result is the same length and shape.
    private static func mutateOneCharacter(of code: String) -> String {
        var characters = Array(CredentialVaultRecovery.normalize(code))
        let replacement: Character = characters[0] == "7" ? "9" : "7"
        characters[0] = replacement
        return String(characters)
    }

    /// Run the main run loop until `semaphore` is signalled, so the store's
    /// `DispatchQueue.main.async` completions actually fire in a headless
    /// process that never calls `NSApp.run()`.
    private static func pump(until semaphore: DispatchSemaphore, timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while semaphore.wait(timeout: .now()) == .timedOut {
            if Date() > deadline { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

#endif
