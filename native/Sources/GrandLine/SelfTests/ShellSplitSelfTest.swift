// Grand Line - native macOS app.
//
// Stage 2 of the modular-shell migration: `AppShellController` was split into
// the floating-bar shell's chrome and the parts any shell hosts - `Workspace`
// (the pages and stores), `WorkspaceContent`, `Navigator`,
// `HostSessionCoordinator`, `LockPresenter` and `CaptureFilingService`. Step 3
// builds a second shell over those parts, so this suite fails if the split is
// reverted or quietly undone:
//
//   1. **The shell is chrome only.** None of the moved responsibilities is
//      back in `AppShellController.swift` - no page or store built there, no
//      mounter, no lock overlay, no host-page storage, no navigation record.
//      Since stage 3 the same holds for the split-view shell
//      (`MainSplitShellController.swift`) and for the base class both extend
//      (`WorkspaceShellController.swift`): two shells over one workspace,
//      neither with a second copy of it.
//   2. **Each part still owns its half.** The core of each responsibility is
//      where the split put it, so a move that drops one fails by name.
//   3. **`DestinationMounter` is untouched.** The plan's step 2 keeps it
//      verbatim for the new shell to reuse; its body is pinned by a digest,
//      so a change has to be deliberate here as well as there.
//   4. **Capture filing really files** - a headless check of the writes the
//      split moved into `CaptureFilingService`, which no suite drove before
//      (the capture panel's suite uses a stand-in filer).
//
// Pure logic: source guards and scratch stores, no window.
//
// Run with:
//   swift build && FM_RUN_SHELL_SPLIT_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import CryptoKit
import Foundation

enum ShellSplitSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkTheShellIsChromeOnly, checkEachPartOwnsItsHalf,
                      checkTheMounterIsUntouched, checkCaptureFilingFiles] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ShellSplitSelfTest: all checks passed" : "ShellSplitSelfTest: FAILED")
        return allOK
    }

    private static func code(_ file: String) -> String? {
        FeatureInventorySelfTest.source(file)
    }

    // MARK: 1 - the shell is chrome only

    /// Tokens that each mark one of the responsibilities stage 2 moved out.
    /// One reappearing in the shell is the split being undone.
    private static let movedOut: [(token: String, owner: String)] = [
        ("HomeCanvasController(", "Workspace builds the pages"),
        ("FleetController(", "Workspace builds the pages"),
        ("StrawHatController(", "Workspace builds the pages"),
        ("LaunchSignposts.measure(", "Workspace builds the stores"),
        ("GrandLineServices.shared.register(", "Workspace registers the stores"),
        ("register(DestinationSlot(", "Workspace holds the destination table"),
        ("DestinationMounter(", "WorkspaceContent owns the mounter"),
        ("destinationPins[", "WorkspaceContent pins the pages"),
        ("LockScreenController()", "LockPresenter owns the lock overlay"),
        ("VaultSource.verifyAppPassword", "LockPresenter checks the password"),
        ("var hostConsoles", "HostSessionCoordinator holds the host pages"),
        (".register(hostID:", "HostSessionCoordinator registers live sessions"),
        ("recordNavigation(leaving:", "Navigator records every navigation"),
        ("readingListStore.add(", "CaptureFilingService files a capture"),
    ]

    /// Each shell file, and a token of its own chrome - the discriminating
    /// check that the file read really is that shell, so one emptied or
    /// renamed does not pass for the right reason.
    private static let shellFiles: [(file: String, chrome: [String])] = [
        ("AppShellController.swift", ["let bar = DaylightBarController()", "func reassertBodyContainerWidthTie(",
                                      "func applyDrillHeader(", "func updateKeyViewLoop()"]),
        ("MainSplitShellController.swift", ["NSSplitViewItem(sidebarWithViewController:", "func fitPanesToWindow()",
                                            "override func workspaceDidShow("]),
        ("WorkspaceShellController.swift", ["self.workspace = Workspace(", "func paintGroundAndFollowTextScale()"]),
    ]

    private static func checkTheShellIsChromeOnly(_ ok: inout Bool) {
        for (file, chrome) in shellFiles {
            guard let shell = code(file) else {
                fail("could not read \(file) - the guard cannot run", &ok)
                continue
            }
            for token in chrome {
                check(shell.contains(token), "\(file) lost its own chrome (\(token)) - this guard is reading the wrong file", &ok)
            }
            for (token, owner) in movedOut {
                check(!shell.contains(token),
                      "\(file) contains `\(token)` again - \(owner) since stage 2, and both shells host that one copy", &ok)
            }
        }
        // Exactly one shell builds the workspace, and it is the base class:
        // a subclass building a second one would be a second set of pages.
        for file in ["AppShellController.swift", "MainSplitShellController.swift"] {
            guard let shell = code(file) else { continue }
            check(!shell.contains("Workspace("), "\(file) builds a Workspace of its own", &ok)
        }
    }

    // MARK: 2 - each part owns its half

    private static let owners: [(file: String, tokens: [String])] = [
        ("Workspace.swift", ["GrandLineServices.shared.register(", "func registerDestinations()",
                             "func wireEagerPages()", "func makeCaptureFiler()"]),
        ("WorkspaceContent.swift", ["DestinationMounter(", "func setDestinationVisible(",
                                    "func animateDestinationEntrance("]),
        ("Navigator.swift", ["func show(_ dest: RailDestination)", "recordNavigation(leaving:",
                             "func revealHostPage(", "func captureSessionState()"]),
        ("HostSessionCoordinator.swift", ["func connectHost(", ".register(hostID:", ".unregister(hostID:",
                                          "func switchToSession(hostID:"]),
        ("LockPresenter.swift", ["func showLock(reason:", "VaultSource.verifyAppPassword", "func hideLock()"]),
        ("CaptureFilingService.swift", ["func file(_ destination: CaptureDestination"]),
    ]

    private static func checkEachPartOwnsItsHalf(_ ok: inout Bool) {
        for (file, tokens) in owners {
            guard let text = code(file) else {
                fail("\(file) is gone - stage 2 put a part of the shell there", &ok)
                continue
            }
            for token in tokens {
                check(text.contains(token), "\(file) no longer contains `\(token)`", &ok)
            }
        }
        // The destination table is complete where it lives now.
        let lines = code("Workspace.swift")?.components(separatedBy: "register(DestinationSlot(").count ?? 1
        check(lines - 1 == DestinationSlotID.allCases.count,
              "Workspace.swift registers \(lines - 1) slots for \(DestinationSlotID.allCases.count)", &ok)
    }

    // MARK: 3 - the mounter is untouched

    /// SHA-256 of `DestinationMounter`'s body, comments stripped and
    /// whitespace collapsed - the plan keeps it verbatim for the split-view
    /// shell to reuse. A change to the mounter is allowed, but it has to be a
    /// deliberate edit to this digest too, with the reason in its PR.
    static let mounterDigest = "b964813add86907555b57f2f8533339650ff70443d3042ae7eb4cd8ab1a1510a"

    static func mounterFingerprint() -> String? {
        guard let registry = code("DestinationRegistry.swift"),
              let start = registry.range(of: "final class DestinationMounter {") else { return nil }
        let body = FeatureInventorySelfTest.braceBody(registry, from: start.upperBound)
        let normalised = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data(normalised.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkTheMounterIsUntouched(_ ok: inout Bool) {
        guard let fingerprint = mounterFingerprint() else {
            fail("could not find `final class DestinationMounter` in DestinationRegistry.swift", &ok)
            return
        }
        check(fingerprint == mounterDigest,
              "DestinationMounter changed (digest \(fingerprint)) - the migration keeps it verbatim for both shells; "
                + "if the change is deliberate, update `mounterDigest` and say why in the PR", &ok)
    }

    // MARK: 4 - capture filing files

    private static func checkCaptureFilingFiles(_ ok: inout Bool) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-split-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        setenv("FM_SHIFT_DIR", scratch.appendingPathComponent("shift").path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }

        let shiftStore = ShiftStore()
        let notebookStore = NotebookStore(root: scratch.appendingPathComponent("notebook"))
        let codePreviewStore = CodePreviewStore(root: scratch.appendingPathComponent("code"))
        let readingListStore = ReadingListStore(root: scratch.appendingPathComponent("reading"))
        var stickies: [(String, String)] = []
        var secrets: [String] = []
        let filing = CaptureFilingService(
            shiftStore: shiftStore, notebookStore: notebookStore,
            codePreviewStore: codePreviewStore, readingListStore: readingListStore,
            addStickyNote: { title, text in stickies.append((title, text)) },
            handOffCredential: { secret in secrets.append(secret) })

        func draft(_ text: String) -> CaptureDraft {
            let lines = text.components(separatedBy: "\n")
            return CaptureDraft(text: text, title: lines[0],
                                body: lines.dropFirst().joined(separator: "\n"),
                                dueDate: nil, dueHasTime: false)
        }

        let tasksBefore = shiftStore.activeTasks.count
        check(filing.file(.task, draft("Rotate the staging certs\nbefore Friday")) == .filed(.task),
              "a task capture did not report filed", &ok)
        check(shiftStore.activeTasks.count == tasksBefore + 1
                && shiftStore.activeTasks.contains { $0.title == "Rotate the staging certs" && $0.description == "before Friday" },
              "a task capture did not land in the task store with its title and body", &ok)

        check(filing.file(.sticky, draft("Call the vendor\nabout the renewal")) == .filed(.sticky),
              "a sticky capture did not report filed", &ok)
        check(stickies.count == 1 && stickies.first?.0 == "Call the vendor" && stickies.first?.1 == "about the renewal",
              "a sticky capture did not reach the board's own add with its title and body", &ok)

        let pagesBefore = notebookStore.listPages().count
        check(filing.file(.note, draft("Incident notes\nThe cache warmed slowly")) == .filed(.note),
              "a note capture did not report filed", &ok)
        check(notebookStore.listPages().count == pagesBefore + 1, "a note capture did not create a notebook page", &ok)

        let snippetsBefore = codePreviewStore.list().count
        check(filing.file(.codeSnippet, draft("kubectl get pods -A")) == .filed(.codeSnippet),
              "a code capture did not report filed", &ok)
        check(codePreviewStore.list().count == snippetsBefore + 1, "a code capture did not create a snippet", &ok)

        check(filing.file(.link, draft("https://example.com/runbook")) == .filed(.link),
              "a link capture did not report filed", &ok)
        if case .refused = filing.file(.link, draft("https://example.com/runbook")) {} else {
            fail("the same link filed twice was not refused as a duplicate", &ok)
        }

        check(filing.file(.credential, draft("s3cr3t-value")) == .handedOff(.credential),
              "a credential capture did not hand off", &ok)
        check(secrets == ["s3cr3t-value"], "a credential capture did not reach Poneglyph's hand-off", &ok)
    }
}

#endif
