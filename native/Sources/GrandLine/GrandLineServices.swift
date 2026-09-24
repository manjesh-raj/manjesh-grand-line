// Grand Line - native macOS app.
//
// The one place a *non-UI* entry point can reach this app's live stores.
//
// Built for two features that arrived together and needed the same thing:
//
//   - **F21 (App Intents).** An intent's `perform()` runs with no view
//     controller, no window and no injected dependencies - Siri or Shortcuts
//     may have launched the app for it. It still has to write into the *same*
//     `ShiftStore` the Tasks page is showing, not a second one: GL-23 is
//     explicit that a caching store gets one shared instance, and `ShiftStore`
//     caches its active tasks. A second instance would write a task the open
//     page never sees and then lose it on that page's next save.
//   - **F24 (export everything).** The Backup card lives on `SettingsController`,
//     which is constructed in `main.swift` and holds four stores; the five new
//     sections live under roots owned by `AppShellController`. Passing four
//     more stores down that constructor would have wired a page to stores it
//     has no other reason to know, and re-deriving the roots here would have
//     grown a second copy of the `FM_*`-override resolution every store
//     already owns - the `CommandLibraryStore` mistake AGENTS.md records.
//
// **This is a registry, not a factory.** With one exception it creates
// nothing: `AppShellController` registers the instances it already built, and
// anything asking before that gets `nil` and must degrade honestly (GL-14) -
// an intent fired at a half-launched app says "Grand Line is still starting
// up", never silently does nothing.
//
// The exception is the vault, and it is deliberate. `CredentialVaultStore`
// was the one store constructed inside its own controller, so unlock state
// lived on a destination that mounts lazily (GL-37) and did not exist until
// the captain first opened Poneglyph. Copy Credential needs *that* store -
// the unlocked one - so the store moved here and the controller now asks for
// it. Still exactly one instance, still created on first use rather than at
// launch (GL-12: nothing slow on the main thread before the window exists).
//
// Main thread only, like every store it holds.

import Foundation

final class GrandLineServices {

    static let shared = GrandLineServices()

    private init() {}

    // MARK: Registered by the shell

    private(set) weak var shiftStore: ShiftStore?
    private(set) weak var notebookStore: NotebookStore?
    private(set) weak var stickyBoardStore: StickyBoardStore?
    private(set) weak var codePreviewStore: CodePreviewStore?
    private(set) weak var focusTimer: FocusTimerController?

    /// Registered once, from `AppShellController.init`, with the instances it
    /// has just built. `weak` throughout: this registry must never be the
    /// reason a store outlives the shell that owns it, and a `nil` here is a
    /// perfectly good answer meaning "the app is not up".
    func register(shiftStore: ShiftStore,
                  notebookStore: NotebookStore,
                  stickyBoardStore: StickyBoardStore,
                  codePreviewStore: CodePreviewStore,
                  focusTimer: FocusTimerController) {
        self.shiftStore = shiftStore
        self.notebookStore = notebookStore
        self.stickyBoardStore = stickyBoardStore
        self.codePreviewStore = codePreviewStore
        self.focusTimer = focusTimer
    }

    // MARK: The vault

    private var vaultStore: CredentialVaultStore?

    /// The app's one `CredentialVaultStore`, created on first use.
    ///
    /// Strongly held, unlike everything above, because nothing else owns it -
    /// `CredentialVaultController` is a lazily-mounted destination and the
    /// unlock state has to outlive any one mounting of it.
    var vault: CredentialVaultStore {
        if let vaultStore { return vaultStore }
        let store = CredentialVaultStore()
        vaultStore = store
        return store
    }

    /// Whether a vault store has actually been built yet. Used by the export
    /// path so that assembling a backup never *creates* a vault on a machine
    /// that has none - the file's existence is checked directly instead.
    var hasBuiltVault: Bool { vaultStore != nil }

    /// Test seam: point the registry at scratch instances. Never called from
    /// production code.
    func replaceVaultForTests(_ store: CredentialVaultStore?) {
        vaultStore = store
    }

    /// Re-read from disk after a restore wrote files underneath the live
    /// stores.
    ///
    /// Only the two that cache need it. `NotebookStore` and `CodePreviewStore`
    /// re-read their directory on every call, so a restored page is already
    /// visible the next time anything asks; `ShiftStore` and
    /// `StickyBoardStore` hold decoded arrays, and without this the captain
    /// would see the pre-restore board until relaunch - and worse, the next
    /// edit would write that stale array back over what was just restored.
    func reloadStoresAfterRestore() {
        shiftStore?.reloadAll()
        stickyBoardStore?.reloadAll()
    }

    // MARK: Backup roots

    /// Where F24's five sections live on this machine, or `nil` when the shell
    /// has not registered yet.
    ///
    /// Read off the live store instances, so this cannot drift from the
    /// `FM_*` overrides those stores resolved at construction - which is the
    /// property that keeps a self-test's scratch roots scratch.
    ///
    /// The vault's path is resolved without touching `vault`, so an export on
    /// a machine that has never opened Poneglyph reads "no file here" rather
    /// than constructing a store and creating one.
    var backupRoots: BackupStoreArchives.Roots? {
        guard let shiftStore, let notebookStore, let stickyBoardStore, let codePreviewStore else { return nil }
        return BackupStoreArchives.Roots(
            tasks: shiftStore.root,
            notebook: notebookStore.root,
            stickyBoard: stickyBoardStore.root,
            codeSnippets: codePreviewStore.root,
            vaultFile: vaultFileURLWithoutBuildingTheStore()
        )
    }

    /// The same resolution `CredentialVaultStore.init()` performs, minus the
    /// side effects (directory creation, the local-only adoption, starting git
    /// sync). Duplicating three lines of `if let override` is the lesser evil
    /// against an export that creates a vault directory on a Mac with no
    /// vault; the store's own `init` is the authority and this must be read
    /// beside it.
    private func vaultFileURLWithoutBuildingTheStore() -> URL {
        if let built = vaultStore { return built.fileURL }
        let env = ProcessInfo.processInfo.environment
        let root: URL
        if let override = env["FM_CREDENTIAL_VAULT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("grand-line-vault", isDirectory: true)
        } else {
            root = CredentialVaultGitSync.shared.dataRoot
        }
        return root.appendingPathComponent(CredentialVaultGitSync.vaultFileName)
    }
}
