// Manjesh Grand Line - native macOS app.
//
// Export/Import panels for the portable local-state bundle (`BackupData.swift`
// holds the format/diff/apply logic - this is the one AppKit-facing
// implementation, shared by Settings' "Backup & Restore" card and
// Bootstrap's "Restore Grand Line config" step so neither duplicates it).
//
// Export writes to a captain-chosen local file (`NSSavePanel`) or to the
// captain's GitHub config repo (`GitHubBackupSource`, `BackupGitHub.swift`);
// import reads from a local file (`NSOpenPanel`) or fetches the one fixed
// bundle GitHub export writes. Either way, the bytes are decoded into a
// `GrandLineBackup`, diffed against the live stores, and shown in a
// confirmation alert before anything is written - nothing is applied without
// that explicit confirm, regardless of where the bytes came from.

import AppKit
import UniformTypeIdentifiers

enum BackupDestination {
    case local
    case github
}

enum BackupUI {
    private static var backupContentType: UTType {
        UTType(filenameExtension: "glbackup") ?? .json
    }

    /// Export the live stores' state, to a destination the captain picks
    /// first. Shows counts (hosts/snippets/referenced keys) before the write,
    /// and a toast confirming what was written after.
    static func exportFlow(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore) {
        // F24: `GrandLineServices.backupRoots` is `nil` only before the shell
        // has registered, in which case this builds exactly the v1 bundle it
        // always did rather than an empty-looking set of new sections.
        let bundle = GrandLineBackupBuilder.build(hosts: hostStore.hosts, snippets: snippetStore.snippets, allKeys: keyStore.keys, dictationStore: dictationStore,
                                                  storeRoots: GrandLineServices.shared.backupRoots)

        resolveGitHubAvailability { githubAvailable in
            guard let destination = chooseDestination(
                in: viewController, verb: "Export", title: "Export Grand Line config",
                localLabel: "Local File…", githubLabel: "Export to \(GitHubBackupSource.destinationLabel)",
                githubAvailable: githubAvailable
            ) else { return }

            switch destination {
            case .local:
                exportToLocal(bundle, from: viewController)
            case .github:
                exportToGitHub(bundle, from: viewController)
            }
        }
    }

    private static func exportToLocal(_ bundle: GrandLineBackup, from viewController: NSViewController) {
        let panel = NSSavePanel()
        panel.title = "Export Grand Line Config"
        panel.prompt = "Export"
        // Deliberately no `.glbackup` suffix here - `allowedContentTypes` owns
        // appending the extension. `.glbackup` has no `UTExportedTypeDeclarations`
        // entry in this app's Info.plist (there is no Info.plist at all - this is
        // a plain SPM executable), so `UTType(filenameExtension:)` synthesizes an
        // unregistered dynamic type; `NSSavePanel` doesn't recognize a name that
        // already ends in that extension as "already correct" and appends its own
        // copy, producing `grand-line-backup.glbackup.glbackup`. Confirmed live via
        // a temporary probe reading `panel.url` after `makeKeyAndOrderFront`.
        panel.nameFieldStringValue = "grand-line-backup"
        panel.allowedContentTypes = [backupContentType]
        panel.message = summaryLine(bundle)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try GrandLineBackupFile.encode(bundle)
            try data.write(to: url, options: .atomic)
            // M3: 0600 on the bundle itself. It aggregates every host, every
            // snippet and all SSH key metadata into one file, so it is at
            // least as sensitive as the stores it is assembled from.
            //
            // The containing directory is emphatically NOT touched: the
            // captain picked it in an `NSSavePanel` and it is their own
            // Documents/Downloads folder, not this app's to narrow. A captain
            // who wants to hand this file to another account can chmod it -
            // that is a deliberate act, which is the right way round.
            SensitiveFile.restrict(url)
            Toast.show(in: viewController.view, message: "Exported \(bundle.hosts.count) host(s), \(bundle.snippets.count) snippet(s)")
        } catch {
            presentError(error, in: viewController)
        }
    }

    /// Writing to GitHub is a real, external, remote action - a real commit
    /// to the captain's real repo (create-or-update, see `GitHubBackupSource.
    /// export`'s doc comment) - not a local write. Runs off the main thread
    /// since it's a blocking network call; the confirming toast/error lands
    /// back on the main thread.
    private static func exportToGitHub(_ bundle: GrandLineBackup, from viewController: NSViewController) {
        Toast.show(in: viewController.view, message: "Exporting to \(GitHubBackupSource.destinationLabel)…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try GitHubBackupSource.export(bundle)
                DispatchQueue.main.async {
                    Toast.show(in: viewController.view, message: "Exported \(bundle.hosts.count) host(s), \(bundle.snippets.count) snippet(s) to \(GitHubBackupSource.destinationLabel)")
                }
            } catch {
                DispatchQueue.main.async { presentError(error, in: viewController) }
            }
        }
    }

    /// What this specific bundle carries, counted from the bundle itself -
    /// never a fixed list of section names, so a section that came back empty
    /// says nothing rather than claiming a zero (GL-14).
    private static func summaryLine(_ bundle: GrandLineBackup) -> String {
        let hostCount = bundle.hosts.count
        let snippetCount = bundle.snippets.count
        var bits = ["\(hostCount) host\(hostCount == 1 ? "" : "s")", "\(snippetCount) snippet\(snippetCount == 1 ? "" : "s")"]
        if bundle.keys.count > 0 {
            bits.append("\(bundle.keys.count) referenced key\(bundle.keys.count == 1 ? "" : "s") (metadata only - no private key material)")
        }
        let vocabularyCount = bundle.dictation?.vocabulary?.count ?? 0
        if vocabularyCount > 0 {
            bits.append("\(vocabularyCount) dictation vocabulary word\(vocabularyCount == 1 ? "" : "s")")
        }
        if let stores = bundle.stores {
            for section in BackupStoreSection.allCases {
                guard let archive = stores.archive(for: section) else { continue }
                if archive.unreadable {
                    // GL-21/GL-14: a section that could not be read is named
                    // as unread, never folded into the happy list or silently
                    // dropped to zero.
                    bits.append("\(section.title): COULD NOT BE READ")
                } else if !archive.files.isEmpty {
                    bits.append("\(archive.files.count) file\(archive.files.count == 1 ? "" : "s") of \(section.title.lowercased())")
                }
            }
            if let vault = stores.vault {
                bits.append("the vault (\(vault.summary))")
            }
        }
        return "About to export: " + bits.joined(separator: ", ") + "."
    }

    /// Read a bundle from a source the captain picks first, diff it against
    /// the live stores, and show that diff for confirmation before writing
    /// anything - identical downstream of the source, whether the bytes came
    /// from a local file or GitHub.
    static func importFlow(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore, onApplied: (() -> Void)? = nil) {
        resolveGitHubAvailability { githubAvailable in
            guard let source = chooseDestination(
                in: viewController, verb: "Import", title: "Import Grand Line config",
                localLabel: "Upload from Local…", githubLabel: "Import from \(GitHubBackupSource.destinationLabel)",
                githubAvailable: githubAvailable
            ) else { return }

            switch source {
            case .local:
                importFromLocal(from: viewController, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore, onApplied: onApplied)
            case .github:
                importFromGitHub(from: viewController, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore, onApplied: onApplied)
            }
        }
    }

    private static func importFromLocal(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore, onApplied: (() -> Void)?) {
        let panel = NSOpenPanel()
        panel.title = "Import Grand Line Config"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [backupContentType]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle: GrandLineBackup
        do {
            let data = try Data(contentsOf: url)
            bundle = try GrandLineBackupFile.decode(data)
        } catch {
            presentError(error, in: viewController)
            return
        }
        diffAndApply(bundle, from: viewController, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore, onApplied: onApplied)
    }

    /// Fetches the one fixed bundle GitHub export writes - no listing or
    /// picker, since there's only ever one file (see `GitHubBackupSource`'s
    /// header). Runs off the main thread since it's a blocking network call;
    /// the diff/confirm alert (and everything downstream of it) runs back on
    /// the main thread exactly like the local-file path.
    private static func importFromGitHub(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore, onApplied: (() -> Void)?) {
        Toast.show(in: viewController.view, message: "Fetching from \(GitHubBackupSource.destinationLabel)…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let bundle = try GitHubBackupSource.fetchBundle()
                DispatchQueue.main.async {
                    diffAndApply(bundle, from: viewController, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore, onApplied: onApplied)
                }
            } catch {
                DispatchQueue.main.async { presentError(error, in: viewController) }
            }
        }
    }

    /// The shared tail of both import paths: diff against the live stores,
    /// confirm, apply, toast.
    private static func diffAndApply(_ bundle: GrandLineBackup, from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore, onApplied: (() -> Void)?) {
        let storeRoots = GrandLineServices.shared.backupRoots
        let preview = BackupImport.diff(
            bundle: bundle, existingHosts: hostStore.hosts, existingSnippets: snippetStore.snippets, existingKeys: keyStore.keys,
            existingVocabulary: dictationStore.vocabulary, existingShortcut: AppSettings.shared.dictationShortcut,
            storeRoots: storeRoots
        )

        guard confirmImport(preview, in: viewController) else { return }

        // F24: replacing an existing vault is its own question, asked only
        // when it is actually on the table. `.adopt` (no vault here) and
        // `.identical` (same bytes) need nothing extra - the import confirm
        // already covered them - and asking anyway would train the captain to
        // click through the one prompt that matters.
        var allowVaultReplace = false
        if preview.stores?.vault?.disposition == .wouldReplace {
            allowVaultReplace = confirmVaultReplace(preview.stores?.vault, in: viewController)
        }

        BackupImport.apply(preview, bundle: bundle, hostStore: hostStore, snippetStore: snippetStore, dictationStore: dictationStore,
                           storeRoots: storeRoots, allowVaultReplace: allowVaultReplace)
        // The two cached stores re-read what was just written underneath them;
        // without this the next edit on the Tasks page or the Sticky Board
        // would write its pre-restore array back over the restore.
        GrandLineServices.shared.reloadStoresAfterRestore()

        let appliedHosts = preview.newHostsCount + preview.changedHostsCount
        let appliedSnippets = preview.newSnippetsCount + preview.changedSnippetsCount
        var message = "Imported \(appliedHosts) host(s), \(appliedSnippets) snippet(s)"
        if let files = preview.stores?.totalFilesToWrite, files > 0 {
            message += ", \(files) file(s)"
        }
        Toast.show(in: viewController.view, message: message)
        onApplied?()
    }

    /// A real destination/source picker, shown before either flow touches
    /// disk or network. The GitHub button is disabled with an explanation
    /// (never silently skipped or attempted) when `gh` isn't installed/
    /// authenticated - the same guidance-only convention this app already
    /// uses for a missing prerequisite (e.g. the gh-cli isotope row in "Not
    /// synced here, by design").
    /// T2: whether the GitHub option is selectable, resolved off the main
    /// thread and cached for the process.
    ///
    /// `GitHubBackupSource.isAvailable()` shells out to `gh auth token` - a
    /// synchronous fork/exec plus a `group.wait` - and this used to run on the
    /// main thread *before* the picker was even built, on every Export/Import
    /// click: typically ~50-200ms of beachball, and up to the subprocess's own
    /// 15s timeout if `gh` or the keychain stalled. The actual export/fetch was
    /// already correctly off-main; only this availability probe was not, and it
    /// was the one main-thread `ghAuthToken()` caller in the app.
    ///
    /// Cached because the answer is "is `gh` logged in", which does not change
    /// between two clicks of the same button, and a stale `true` degrades to
    /// the same real error the export would have produced anyway.
    private static var cachedGitHubAvailability: Bool?

    private static func resolveGitHubAvailability(_ completion: @escaping (Bool) -> Void) {
        if let cached = cachedGitHubAvailability { completion(cached); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let available = GitHubBackupSource.isAvailable()
            DispatchQueue.main.async {
                cachedGitHubAvailability = available
                completion(available)
            }
        }
    }

    private static func chooseDestination(in viewController: NSViewController, verb: String, title: String, localLabel: String, githubLabel: String, githubAvailable: Bool) -> BackupDestination? {
        // G3: a three-way *picker*, which is why `HelmConfirm` carries an
        // `extra` button at all. The GitHub option stays offered-but-disabled
        // with its reason on a tooltip when `gh` is not logged in - saying why
        // it cannot be used beats hiding it.
        //
        // `confirm` is the local option, because Return chose it before.
        var request = HelmConfirm.Request(title: title,
                                          body: githubAvailable
                                            ? "Choose where to \(verb.lowercased()) this config."
                                            : "Choose where to \(verb.lowercased()) this config.\n\n\(GitHubBackupSource.unavailableReason)")
        request.confirmTitle = localLabel
        request.extra = HelmConfirm.ExtraButton(title: githubLabel,
                                                isEnabled: githubAvailable,
                                                tooltip: githubAvailable ? nil : GitHubBackupSource.unavailableReason)
        request.symbol = "arrow.up.arrow.down.circle.fill"
        switch HelmConfirm.confirm(request) {
        case .confirm: return .local
        case .extra: return githubAvailable ? .github : nil
        case .cancel: return nil
        }
    }

    /// A real confirm/cancel alert whose body is the actual diff, row by
    /// row - never a static description. Returns whether the captain chose
    /// to import.
    private static func confirmImport(_ preview: BackupImport.Preview, in viewController: NSViewController) -> Bool {
        // G3: themed. Return still imports, as it did here, and the real
        // per-row diff is still the body - never a static description.
        var request = HelmConfirm.Request(title: "Import Grand Line config?",
                                          body: confirmSummary(preview))
        request.confirmTitle = "Import"
        request.destructive = true
        request.accessory = diffScrollView(preview)
        request.symbol = "square.and.arrow.down.fill"
        request.hue = .amber
        return HelmConfirm.confirm(request) == .confirm
    }

    private static func confirmSummary(_ preview: BackupImport.Preview) -> String {
        var lines = [
            "Hosts: \(preview.newHostsCount) new, \(preview.changedHostsCount) changed, \(preview.unchangedHostsCount) unchanged.",
            "Snippets: \(preview.newSnippetsCount) new, \(preview.changedSnippetsCount) changed, \(preview.unchangedSnippetsCount) unchanged.",
            "Settings to apply: \(preview.settingsSummary).",
        ]
        if !preview.vocabularyRows.isEmpty {
            lines.append("Dictation vocabulary: \(preview.newVocabularyCount) new, \(preview.unchangedVocabularyCount) already present.")
        }
        if let shortcutDisplay = preview.shortcutDisplay {
            lines.append(preview.shortcutStatus == .changed
                ? "Dictation shortcut will change to \(shortcutDisplay)."
                : "Dictation shortcut unchanged (\(shortcutDisplay)).")
        }
        if !preview.keyWarnings.isEmpty {
            lines.append("\(preview.keyWarnings.count) host reference(s) point at a key not on this machine - see below.")
        }
        // GL-08: state the refusal up front in the summary, not just in the
        // scrollable detail - a skipped host is the one thing in this preview
        // the captain cannot approve past, so it should not need scrolling to
        // discover.
        if !preview.rejectedHostWarnings.isEmpty {
            lines.append("\u{26A0} \(preview.rejectedHostWarnings.count) host(s) in this file were REFUSED as unsafe - see below.")
        }
        if let stores = preview.stores {
            for row in stores.rows where !row.unchangedFiles.isEmpty || row.willWriteCount > 0 || row.sourceUnreadable {
                lines.append(row.summaryLine)
            }
            if let vault = stores.vault {
                switch vault.disposition {
                case .adopt:
                    lines.append("Vault: \(vault.archive.summary). It will be restored, and needs its own master password from the machine it came from.")
                case .identical:
                    lines.append("Vault: already identical to the one on this Mac - nothing to do.")
                case .wouldReplace:
                    lines.append("\u{26A0} Vault: a DIFFERENT vault already exists here. You will be asked separately before anything replaces it.")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The real, per-item diff listing - built entirely from `preview`, never
    /// hardcoded copy.
    private static func diffScrollView(_ preview: BackupImport.Preview) -> NSView {
        var lines: [String] = []
        lines.append("HOSTS (\(preview.hostRows.count))")
        if preview.hostRows.isEmpty {
            lines.append("  (none in this file)")
        } else {
            for row in preview.hostRows { lines.append("  [\(row.status.rawValue.uppercased())] \(row.label)") }
        }
        lines.append("")
        lines.append("SNIPPETS (\(preview.snippetRows.count))")
        if preview.snippetRows.isEmpty {
            lines.append("  (none in this file)")
        } else {
            // S4: the command text, not just the label. A snippet is a shell
            // command this app types into a terminal, and a bundled host can
            // name one as its startup snippet - which runs it by itself on the
            // next connect. Approving an import used to mean approving command
            // text the preview never showed.
            for row in preview.snippetRows {
                let autoRun = row.autoRunsOnConnect ? "  \u{26A0} RUNS AUTOMATICALLY ON CONNECT" : ""
                lines.append("  [\(row.status.rawValue.uppercased())] \(row.label)\(autoRun)")
                for commandLine in row.bundleSnippet.command.components(separatedBy: .newlines) {
                    lines.append("      $ \(commandLine)")
                }
            }
        }
        if !preview.vocabularyRows.isEmpty {
            lines.append("")
            lines.append("DICTATION VOCABULARY (\(preview.vocabularyRows.count))")
            for row in preview.vocabularyRows { lines.append("  [\(row.status.rawValue.uppercased())] \(row.word)") }
        }
        if let shortcutDisplay = preview.shortcutDisplay, let shortcutStatus = preview.shortcutStatus {
            lines.append("")
            lines.append("DICTATION SHORTCUT")
            lines.append("  [\(shortcutStatus.rawValue.uppercased())] \(shortcutDisplay)")
        }
        if !preview.keyWarnings.isEmpty {
            lines.append("")
            lines.append("KEY REFERENCES NEEDING ATTENTION")
            for warning in preview.keyWarnings { lines.append("  - \(warning)") }
        }
        if !preview.rejectedHostWarnings.isEmpty {
            lines.append("")
            lines.append("REFUSED - NOT IMPORTED (GL-08)")
            for warning in preview.rejectedHostWarnings { lines.append("  - \(warning)") }
        }
        if let stores = preview.stores {
            for row in stores.rows {
                lines.append("")
                lines.append("\(row.section.title.uppercased()) - \(row.section.detail)")
                if row.sourceUnreadable {
                    lines.append("  ! the machine that exported this could not read the folder, so nothing here will be written (GL-21)")
                    continue
                }
                if row.sourceTruncated {
                    lines.append("  ! the export hit its size limit - this section is incomplete")
                }
                // The listing is per file, capped: a real notebook is
                // thousands of pages and a confirm sheet nobody scrolls to the
                // end of is the same as no confirm at all.
                for path in row.newFiles.prefix(listedFilesPerSection) { lines.append("  [NEW] \(path)") }
                for path in row.changedFiles.prefix(listedFilesPerSection) { lines.append("  [CHANGED] \(path)") }
                let listed = min(row.newFiles.count, listedFilesPerSection) + min(row.changedFiles.count, listedFilesPerSection)
                if row.willWriteCount > listed {
                    lines.append("  \u{2026} and \(row.willWriteCount - listed) more file(s) to write")
                }
                if row.willWriteCount == 0 { lines.append("  (nothing to write - every file here is already identical)") }
                if !row.unchangedFiles.isEmpty { lines.append("  \(row.unchangedFiles.count) unchanged") }
                if !row.localOnlyFiles.isEmpty {
                    lines.append("  \(row.localOnlyFiles.count) file(s) exist only on this Mac and are KEPT - a restore merges, it never deletes")
                }
                for path in row.rejectedPaths { lines.append("  [REFUSED - unsafe path] \(path)") }
            }
            if let vault = stores.vault {
                lines.append("")
                lines.append("PONEGLYPH VAULT (sealed)")
                lines.append("  \(vault.archive.summary)")
                lines.append("  The credentials are not readable by this import - the file is copied still encrypted,")
                lines.append("  and unlocking it needs the master password it had on the machine it came from.")
                lines.append("  Touch ID does not travel: that key is stored ThisDeviceOnly in the other Mac's Keychain.")
                switch vault.disposition {
                case .adopt: lines.append("  [NEW] there is no vault on this Mac yet - this one will be adopted")
                case .identical: lines.append("  [UNCHANGED] identical to the vault already here")
                case .wouldReplace: lines.append("  [NEEDS CONFIRMATION] a different vault is already here")
                }
            }
        }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
        textView.string = lines.joined(separator: "\n")
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        HelmSelection.apply(to: textView, theme: ThemeManager.shared.theme)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        // Phase 6 of the UI audit: the shared sunken chrome rather than
        // AppKit's own `.bezelBorder`. Applied once with the current theme and
        // never observed - this view only exists for the lifetime of a modal
        // `NSAlert`, during which no theme change can reach it.
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let theme = ThemeManager.shared.theme
        HelmField.makeSunken(scroll)
        HelmField.applySunken(to: scroll, theme: theme)
        textView.drawsBackground = true
        textView.backgroundColor = HelmField.fill(theme)
        textView.textColor = HelmField.ink(theme)
        return scroll
    }

    /// How many files per section the scrollable listing names individually.
    private static let listedFilesPerSection = 40

    /// GL-06's shape for the one irreversible thing an import can do.
    ///
    /// Separate from the main confirm on purpose. The import alert is a
    /// preview of a merge - additive, and a captain is meant to be able to say
    /// yes to it. Overwriting a vault is neither: the credentials it replaces
    /// are gone unless a copy exists elsewhere, so it goes through the app's
    /// one irreversible-action prompt (GL-06), where Return means Cancel.
    private static func confirmVaultReplace(_ row: BackupStoreImport.Preview.VaultRow?, in viewController: NSViewController) -> Bool {
        guard let row else { return false }
        return DestructiveConfirm.confirm(
            message: "Replace the vault on this Mac?",
            detail: "This backup carries a different Poneglyph vault (\(row.archive.summary)).\n\n"
                + "Restoring it REPLACES the vault already on this Mac. The credentials in the current vault "
                + "are not merged and cannot be recovered afterwards unless you have another copy.\n\n"
                + "The restored vault is still encrypted and will need the master password it had on the "
                + "machine it came from - Touch ID does not travel with it.",
            confirmTitle: "Replace Vault")
    }

    private static func presentError(_ error: Error, in viewController: NSViewController) {
        HelmConfirm.problem(title: "Couldn't complete that", body: error.localizedDescription)
    }
}
