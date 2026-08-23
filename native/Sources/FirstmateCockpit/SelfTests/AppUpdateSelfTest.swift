// Manjesh Grand Line - native macOS app.
//
// F3 regression coverage: version comparison, release parsing, and - the one
// that actually matters - the rule that an artifact this app cannot verify is
// never installed.
//
// The install path itself is deliberately not exercised end to end here: it
// downloads a real artifact, replaces the running bundle and terminates the
// process, none of which belongs in a test run, and there is no signed
// artifact to point it at yet anyway. What *is* covered is every decision the
// install path makes before it touches the filesystem, which is where the
// security property lives:
//
//   - `AppUpdateInstaller.canInstall` is false while there is no expected
//     Team ID, and `install` refuses rather than proceeding.
//   - `signatureRejection` accepts only a Developer ID signature whose Team
//     ID matches, and names the specific reason for every other shape -
//     unsigned, ad-hoc, self-signed local dev (which is what this app is
//     signed with today, so this is a real case rather than a hypothetical
//     one), and a Developer ID belonging to somebody else.
//
// Confirmed, per this project's convention, to catch a real regression rather
// than merely to pass: making `signatureRejection` return `nil` whenever the
// seal is intact (the tempting "codesign --verify passed, that's good
// enough" shortcut) fails four of its five cases, including the self-signed
// one that describes this app's own current signing setup.
//
// Run with:
//   swift build && FM_RUN_APP_UPDATE_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum AppUpdateSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("versionComparisonOrdersReleases", test_versionCompare),
            ("versionComparisonIgnoresDescribeSuffix", test_versionCompareDescribeSuffix),
            ("releaseJSONParsesTagAndZipAsset", test_parseRelease),
            ("releaseJSONWithoutAnArtifactStillParses", test_parseReleaseNoAsset),
            ("draftReleaseIsNeverOffered", test_parseDraftRelease),
            ("malformedReleaseJSONIsRejected", test_parseGarbage),
            ("unverifiableArtifactIsRefusedNotInstalled", test_refusesUnverified),
            ("onlyAMatchingDeveloperIDIsAccepted", test_signatureRejection),
            ("relaunchPathIsShellQuoted", test_shellQuoting),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
            ? "AppUpdateSelfTest: all \(cases.count) cases passed"
            : "AppUpdateSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Versions

    private static func test_versionCompare() -> String? {
        let older = ["0.1.0", "v0.1.0", "0.9.9", "1.0.0", "1.2", "0.2.0"]
        let newer = ["0.2.0", "v0.2.0", "1.0.0", "1.0.1", "1.2.1", "0.10.0"]
        for (a, b) in zip(older, newer) {
            guard AppVersion.compare(a, b) < 0 else { return "\(a) should sort before \(b)" }
            guard AppVersion.compare(b, a) > 0 else { return "\(b) should sort after \(a)" }
        }
        // `1.2` and `1.2.0` are the same release, written two ways.
        guard AppVersion.compare("1.2", "1.2.0") == 0 else { return "1.2 and 1.2.0 should compare equal" }
        guard AppVersion.compare("v3.4.5", "3.4.5") == 0 else { return "a leading v should not change the ordering" }
        // 0.10 beats 0.9 - the classic string-compare trap.
        guard AppVersion.compare("0.9.0", "0.10.0") < 0 else { return "0.10.0 should be newer than 0.9.0, not older" }
        return nil
    }

    private static func test_versionCompareDescribeSuffix() -> String? {
        // A dev build seven commits past v0.2.0 must not be told it is behind
        // v0.2.0 - that would offer an update that downgrades it.
        guard AppVersion.compare("0.2.0-7-gabc1234", "v0.2.0") == 0 else {
            return "a git-describe suffix should not make a build look older than its own tag"
        }
        guard AppVersion.compare("0.2.0-7-gabc1234-dirty", "v0.3.0") < 0 else {
            return "a dirty dev build should still be older than a genuinely newer tag"
        }
        guard AppVersion.numericComponents("not a version").isEmpty else {
            return "a non-numeric string should yield no components rather than a bogus one"
        }
        return nil
    }

    // MARK: Release payloads

    private static func releaseJSON(tag: String, assets: String, draft: Bool = false) -> Data {
        Data("""
        {
          "tag_name": "\(tag)",
          "html_url": "https://github.com/manjesh-raj/manjesh-grand-line/releases/tag/\(tag)",
          "draft": \(draft),
          "prerelease": false,
          "assets": [\(assets)]
        }
        """.utf8)
    }

    private static func test_parseRelease() -> String? {
        let asset = """
        {"name": "Manjesh-Grand-Line-v0.2.0.zip",
         "browser_download_url": "https://github.com/manjesh-raj/manjesh-grand-line/releases/download/v0.2.0/Manjesh-Grand-Line-v0.2.0.zip",
         "size": 12345678}
        """
        guard let release = AppUpdateSource.parseRelease(releaseJSON(tag: "v0.2.0", assets: asset)) else {
            return "a well-formed release payload did not parse"
        }
        guard release.tag == "v0.2.0" else { return "wrong tag: \(release.tag)" }
        guard release.assetName == "Manjesh-Grand-Line-v0.2.0.zip" else { return "wrong asset: \(release.assetName ?? "nil")" }
        guard release.assetSize == 12_345_678 else { return "wrong asset size: \(release.assetSize)" }
        guard release.assetURL?.absoluteString.hasSuffix(".zip") == true else { return "asset URL not picked up" }
        return nil
    }

    private static func test_parseReleaseNoAsset() -> String? {
        // A tag pushed before the release workflow existed: published, but
        // nothing to download. A real state, not a failure.
        guard let release = AppUpdateSource.parseRelease(releaseJSON(tag: "v0.1.0", assets: "")) else {
            return "a release with no assets should still parse"
        }
        guard release.assetURL == nil, release.assetName == nil else {
            return "a release with no assets should report no artifact"
        }
        // A non-zip asset (a checksum file, say) must not be mistaken for the build.
        let sums = """
        {"name": "SHA256SUMS.txt",
         "browser_download_url": "https://example.invalid/SHA256SUMS.txt", "size": 64}
        """
        guard AppUpdateSource.parseRelease(releaseJSON(tag: "v0.1.0", assets: sums))?.assetURL == nil else {
            return "a non-zip asset should not be treated as the app build"
        }
        return nil
    }

    private static func test_parseDraftRelease() -> String? {
        let asset = """
        {"name": "x.zip", "browser_download_url": "https://example.invalid/x.zip", "size": 1}
        """
        guard AppUpdateSource.parseRelease(releaseJSON(tag: "v9.9.9", assets: asset, draft: true)) == nil else {
            return "a draft release must never be offered as an update"
        }
        return nil
    }

    private static func test_parseGarbage() -> String? {
        guard AppUpdateSource.parseRelease(Data("not json".utf8)) == nil else {
            return "non-JSON should not parse into a release"
        }
        guard AppUpdateSource.parseRelease(Data(#"{"unexpected": true}"#.utf8)) == nil else {
            return "JSON without a tag should not parse into a release"
        }
        return nil
    }

    // MARK: The verification gate

    private static func test_refusesUnverified() -> String? {
        // The whole security property in one assertion: with no expected Team
        // ID configured, nothing installs.
        guard AppUpdateInstaller.expectedTeamIdentifier == nil || AppUpdateInstaller.canInstall else {
            return "canInstall disagrees with expectedTeamIdentifier"
        }
        guard !AppUpdateInstaller.canInstall else {
            // If a future change sets a real Team ID, this case has served its
            // purpose and should be replaced with one that verifies against a
            // real signed fixture - fail loudly rather than silently passing.
            return "expectedTeamIdentifier is now set; replace this case with real signed-fixture coverage"
        }
        let release = AppRelease(
            tag: "v9.9.9",
            htmlURL: URL(string: "https://example.invalid/release")!,
            assetURL: URL(string: "https://example.invalid/app.zip")!,
            assetName: "app.zip",
            assetSize: 1
        )
        // Must refuse *before* any network access - `example.invalid` does not
        // resolve, so a download attempt would report a transport failure
        // instead, and this case would be proving the wrong thing.
        let started = Date()
        switch AppUpdateInstaller.install(release) {
        case .refusedUnverified:
            guard Date().timeIntervalSince(started) < 2 else {
                return "install refused, but only after what looks like a network attempt"
            }
            return nil
        case .installedPendingRelaunch:
            return "install claimed success with no verifiable signature - this is the bug this whole file exists to prevent"
        case .failed(let reason):
            return "expected a verification refusal, got a plain failure: \(reason)"
        }
    }

    private static func test_signatureRejection() -> String? {
        let team = "ABCDE12345"

        // The real shape of `codesign --display --verbose=4` for a properly
        // distributed app.
        let developerID = """
        Executable=/Applications/Manjesh Grand Line.app/Contents/MacOS/FirstmateCockpit
        Identifier=com.firstmate.cockpit.native
        Authority=Developer ID Application: Manjesh Raj (\(team))
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        TeamIdentifier=\(team)
        """
        if let reason = AppUpdateInstaller.signatureRejection(in: developerID, expectedTeam: team) {
            return "a matching Developer ID signature was rejected: \(reason)"
        }

        // This app's own current signing: a local self-signed identity. It has
        // an intact seal and no Team ID, which is exactly why an
        // intactness-only check is not enough.
        let localDev = """
        Identifier=com.firstmate.cockpit.native
        Authority=Firstmate Cockpit Local Dev
        TeamIdentifier=not set
        """
        guard AppUpdateInstaller.signatureRejection(in: localDev, expectedTeam: team) != nil else {
            return "a locally self-signed build was accepted as a distributable release"
        }

        // Ad-hoc (`codesign -s -`).
        let adHoc = """
        Identifier=com.firstmate.cockpit.native
        Signature=adhoc
        TeamIdentifier=not set
        """
        guard AppUpdateInstaller.signatureRejection(in: adHoc, expectedTeam: team) != nil else {
            return "an ad-hoc signed build was accepted"
        }

        // A genuine Developer ID belonging to somebody else.
        let otherTeam = """
        Authority=Developer ID Application: Someone Else (ZZZZZ99999)
        Authority=Developer ID Certification Authority
        TeamIdentifier=ZZZZZ99999
        """
        guard let reason = AppUpdateInstaller.signatureRejection(in: otherTeam, expectedTeam: team) else {
            return "a Developer ID from a different team was accepted"
        }
        guard reason.contains("ZZZZZ99999") else {
            return "the rejection should name the team it actually found, got: \(reason)"
        }

        // Nothing at all.
        guard AppUpdateInstaller.signatureRejection(in: "", expectedTeam: team) != nil else {
            return "empty codesign output was accepted"
        }
        return nil
    }

    private static func test_shellQuoting() -> String? {
        // The relaunch helper interpolates the bundle path into a shell
        // command, and "Manjesh Grand Line.app" already contains spaces.
        let quoted = AppUpdateInstaller.shellQuoted("/Applications/Manjesh Grand Line.app")
        guard quoted == "'/Applications/Manjesh Grand Line.app'" else { return "unexpected quoting: \(quoted)" }
        let nasty = AppUpdateInstaller.shellQuoted("/tmp/a'b; rm -rf /.app")
        guard !nasty.contains("; rm -rf /") || nasty.hasPrefix("'") else { return "quoting did not contain the payload" }
        // Round-trip it through a real shell: whatever comes back must be the
        // original string, not a command that ran.
        let echoed = Subprocess.run(executable: "/bin/sh", arguments: ["-c", "printf %s \(nasty)"], timeout: 10)
        guard echoed.stdout == "/tmp/a'b; rm -rf /.app" else {
            return "a quoted path did not survive a real shell verbatim: \(echoed.stdout)"
        }
        return nil
    }
}

#endif
