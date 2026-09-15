// Manjesh Grand Line - native macOS app.
//
// Data side for Settings' "Touch ID for sudo" row (cockpit-settings-sudo-
// touchid). `av harden sudo` (automic-vault/src/isotopes/hardeners/sudo.rs)
// appends `auth sufficient pam_tid.so` to `/etc/pam.d/sudo_local`, but only
// takes effect if `/etc/pam.d/sudo` already `include`s `sudo_local` - that's
// a real macOS caveat (documented in the hardener's own sudo.md), not
// something to assume true on every Mac, so this file checks both files'
// actual content rather than trusting a cached flag. Mirrors
// `NotSyncedSource`'s plumbing style but needs no `av` invocation for the
// status check itself - `av`'s own `sudo` hardener isn't in its
// `hardeners --json` listing (that command is root-only and file-content
// driven, unlike the account-based hardeners it does list), so this reads
// the PAM files directly, the same way `sudo.rs`'s own `pam_tid_enabled`
// does.
//
// cockpit-settings-sudo-nixdarwin: on a nix-darwin-managed Mac,
// `/etc/pam.d/sudo_local` is a symlink chain into the immutable Nix store
// (`/etc/pam.d/sudo_local` -> `/etc/static/pam.d/sudo_local` ->
// `/nix/store/.../etc-sudo_local`). `av harden sudo` refuses to write
// through a symlink (a correct guard against symlink attacks on root-owned
// PAM files) and fails with ELOOP there, and even bypassing that would be
// pointless: the file is regenerated from the flake on every rebuild, so a
// manual edit is wiped on the next `rebuild.sh` anyway. The real fix on
// that class of machine is nix-darwin's own declarative
// `security.pam.services.sudo_local.touchIdAuth = true;` option in
// `configuration.nix`, not `av harden sudo` - see `.notEnabledNixDarwin`
// below and its guidance text in `SettingsController.sudoTouchIDRow()`.
// Reading the file's *content* for `pam_tid.so` is unaffected either way,
// since reading through a symlink is transparently fine - only writing
// through one is what `av harden sudo` refuses to do.

import Foundation

enum SudoTouchIDStatus: Equatable {
    case checking
    /// Enabled by a `pam_tid.so` line in `/etc/pam.d/sudo_local`, which is a
    /// real file this app can edit - the one enabled state that offers a
    /// Disable action (`SudoTouchIDSource.disableCommand`).
    case enabled
    /// Enabled, but `/etc/pam.d/sudo_local` resolves into `/nix/store/` - the
    /// same nix-darwin case `.notEnabledNixDarwin` describes, seen from the
    /// other side. Removing the line here is impossible (the store is
    /// read-only and `sudo_local` is a symlink into it) and would be futile
    /// anyway, since the next `rebuild.sh` regenerates the file from the
    /// flake. Turning it off means `security.pam.services.sudo_local` in
    /// `configuration.nix`, exactly as turning it on does.
    case enabledNixDarwin
    /// Enabled by a `pam_tid.so` line in `/etc/pam.d/sudo` itself rather than
    /// in `sudo_local`. `av harden sudo` never writes there and neither does
    /// this app: `sudo` is the file Apple ships and replaces on a system
    /// update, and `sudo_local` exists precisely so local changes have
    /// somewhere else to live. So this is reported and left alone - a Disable
    /// that only edited `sudo_local` would silently do nothing here, which is
    /// worse than saying so.
    case enabledInSudoFile
    case notEnabled
    /// Not enabled, and `/etc/pam.d/sudo_local` resolves into `/nix/store/` -
    /// this Mac is managed by nix-darwin, so `av harden sudo` would fail
    /// with ELOOP (it refuses to write through a symlink) even if run, and
    /// any manual edit would be wiped on the next `rebuild.sh` regardless.
    case notEnabledNixDarwin
    /// `/etc/pam.d/sudo` doesn't `include` `sudo_local` on this Mac, so
    /// `av harden sudo` would have no effect even if run - the hardener's
    /// own documented caveat.
    case pamNotConfigured
    case checkFailed(String)
}

enum SudoTouchIDSource {

    private static let pamDir = "/etc/pam.d"

    /// The one file this app ever edits for Touch ID, and the one
    /// `av harden sudo` appends to. `/etc/pam.d/sudo` is deliberately never a
    /// write target - see `.enabledInSudoFile`.
    static let sudoLocalPath = "/etc/pam.d/sudo_local"

    static func checkStatus() -> SudoTouchIDStatus {
        guard let sudoContents = try? String(contentsOfFile: "\(pamDir)/sudo", encoding: .utf8) else {
            return .checkFailed("could not read /etc/pam.d/sudo")
        }
        let sudoLocalContents = try? String(contentsOfFile: sudoLocalPath, encoding: .utf8)
        return classify(sudoContents: sudoContents,
                        sudoLocalContents: sudoLocalContents,
                        isNixDarwin: isManagedByNixDarwin())
    }

    /// The whole status decision, split out from the three file reads above so
    /// it can be driven directly - `checkStatus` reads `/etc/pam.d`, which a
    /// suite cannot stand in for, while *which* status a given pair of file
    /// contents means is exactly the part that now decides whether a Disable
    /// button is offered at all.
    static func classify(sudoContents: String,
                         sudoLocalContents: String?,
                         isNixDarwin: Bool) -> SudoTouchIDStatus {
        // Asked before the `include` check on purpose: a `pam_tid.so` line in
        // `/etc/pam.d/sudo` itself is read by `sudo` directly, so Touch ID is
        // genuinely on whether or not that file also includes `sudo_local`.
        // Reporting `.pamNotConfigured` there - which this returned before the
        // Disable action existed - would have been a claim that Touch ID
        // cannot work on a Mac where it demonstrably does, and it is exactly
        // the state where a Disable button scoped to `sudo_local` would press
        // cleanly and change nothing.
        if enablesPamTid(sudoContents) {
            return .enabledInSudoFile
        }
        guard includesSudoLocal(sudoContents) else {
            return .pamNotConfigured
        }
        if enablesPamTid(sudoLocalContents ?? "") {
            // The same symlink-into-the-store test the not-enabled branch
            // makes, asked here too: which of the two enabled states this is
            // decides whether the line can be removed at all.
            return isNixDarwin ? .enabledNixDarwin : .enabled
        }
        return isNixDarwin ? .notEnabledNixDarwin : .notEnabled
    }

    #if FM_SELFTESTS
    /// Lets `SudoTouchIDDisableSelfTest` assert the one invariant that matters
    /// most here: `disableCommand` removes a line **exactly** when this says
    /// that line enables Touch ID. Without it the suite would have to carry its
    /// own copy of the rule, which is the copy that drifts.
    static func debugEnablesPamTid(_ contents: String) -> Bool { enablesPamTid(contents) }
    #endif

    // MARK: Disable

    /// The shell command behind the Security card's "Disable" action, run the
    /// same way "Enable" runs `sudo av harden sudo`: handed to a real Console
    /// tab so macOS's own `sudo` prompt is the authentication gate. Nothing
    /// here tries to pre-authorize or bypass that prompt.
    ///
    /// There is no `av` counterpart to reverse `av harden sudo` - its sudo
    /// hardener (`automic-vault/src/isotopes/hardeners/sudo.rs`) only has
    /// `enable_pam_tid`, with no unharden side - so the removal is this app's
    /// own, and it is deliberately the smallest edit that can turn Touch ID
    /// off:
    ///
    ///   * only `/etc/pam.d/sudo_local` is ever touched, never
    ///     `/etc/pam.d/sudo` (see `.enabledInSudoFile`),
    ///   * only whole lines that `enablesPamTid` itself matches are dropped,
    ///     every other byte of the file is rewritten unchanged,
    ///   * the rewrite is `cat tmp > file`, not a `sed -i`/move, so the file
    ///     keeps its inode, root ownership and mode - which for a PAM file
    ///     matters more than the two saved characters, and
    ///   * the file is only truncated once the filtered copy exists and has
    ///     been shown to differ, so a failed `awk` can never empty it.
    ///
    /// The `awk` mirrors `enablesPamTid` field for field rather than
    /// approximating it: trim spaces and tabs, take the first
    /// **space**-delimited token, require it to be `auth`, and require some
    /// other space-delimited token to be exactly `pam_tid.so`. It needs no
    /// separate comment check the way `enablesPamTid` has one - a commented
    /// line's first token is `#` or `#auth`, never `auth` - and the suite
    /// drives both of those shapes rather than taking that on trust. The `index`
    /// against a space-padded copy is what enforces "exactly", so
    /// `pam_tid.so.bak` and a tab-separated `auth\tsufficient\tpam_tid.so`
    /// are both left alone - the second because `enablesPamTid` does not
    /// count it as enabling either. Matching the status check exactly is the
    /// point: a removal that deleted a line the app does not believe is there
    /// would be the app editing a PAM file behind its own back.
    ///
    /// The `-L` guard repeats `av harden sudo`'s own refusal to write through
    /// a symlink. The UI already withholds Disable in that case
    /// (`.enabledNixDarwin`), so this is the second lock on the same door -
    /// the one that still holds if a future caller forgets the first.
    ///
    /// `path` exists so `SudoTouchIDDisableSelfTest` can run this exact
    /// string against a scratch file; production always takes the default.
    static func disableCommand(path: String = sudoLocalPath) -> String {
        // Passed to the Console tab's login shell as a single `-lc` argument
        // and never re-quoted, so the outer single quotes survive both zsh and
        // bash - which is why nothing inside may use a single quote of its
        // own. `<<"AWKEOF"` keeps the shell out of the awk program, and
        // `awk "$prog"` expands the variable once, so the `$0` inside it
        // reaches awk rather than the shell.
        """
        sudo /bin/sh -c '
        set -e
        f="\(path)"
        if [ -L "$f" ]; then
          echo "Refusing to edit $f: it is a symlink, so PAM is managed declaratively here (nix-darwin). Turn Touch ID off in your dotfiles configuration.nix and run rebuild.sh instead." >&2
          exit 1
        fi
        if [ ! -f "$f" ]; then
          echo "No $f - Touch ID for sudo is already off."
          exit 0
        fi
        prog=$(cat <<"AWKEOF"
        {
          line = $0
          sub(/^[ \\t]+/, "", line)
          sub(/[ \\t]+$/, "", line)
          head = line
          sub(/ .*$/, "", head)
          if (head == "auth" && index(" " line " ", " pam_tid.so ") > 0) next
          print
        }
        AWKEOF
        )
        t=$(mktemp -t grandline-sudo-local) || exit 1
        awk "$prog" "$f" > "$t" || { rm -f "$t"; exit 1; }
        if cmp -s "$t" "$f"; then
          rm -f "$t"
          echo "No Touch ID (pam_tid.so) line in $f - nothing to change."
          exit 0
        fi
        cat "$t" > "$f" || { rm -f "$t"; exit 1; }
        rm -f "$t"
        echo "Removed the Touch ID (pam_tid.so) line from $f. sudo will ask for your password again."
        '
        """
    }

    /// Resolves `/etc/pam.d/sudo_local`'s real path (following the full
    /// symlink chain, not just the first hop) and checks whether it lands
    /// in `/nix/store/` - nix-darwin's tell, since it regenerates that file
    /// from the evaluated flake config on every rebuild.
    private static func isManagedByNixDarwin() -> Bool {
        let resolved = (("\(pamDir)/sudo_local") as NSString).resolvingSymlinksInPath
        return resolved.hasPrefix("/nix/store/")
    }

    /// Mirrors `sudo.rs`'s `line_enables_pam_tid`: an uncommented `auth` line
    /// naming `pam_tid.so` among its fields.
    private static func enablesPamTid(_ contents: String) -> Bool {
        contents.split(separator: "\n").contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            return fields.first == "auth" && fields.contains("pam_tid.so")
        }
    }

    /// Mirrors the hardener's documented caveat: `/etc/pam.d/sudo` must
    /// `include` `sudo_local` for the appended line to ever take effect.
    private static func includesSudoLocal(_ contents: String) -> Bool {
        contents.split(separator: "\n").contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            return fields.first == "auth" && fields.contains("include") && fields.last == "sudo_local"
        }
    }
}
