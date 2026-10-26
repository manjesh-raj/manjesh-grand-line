// Grand Line - native macOS app.
//
// `VaultController`'s floating-bar presentation (R2-ARCH-04): the keyed secret and launcher rows inside the two cards the floating bar draws, where the sidebar layout draws two tables.
//
// The floating bar is the classic layout, frozen by R2-ARCH-01: it gets
// fixes but no new features and no page redesigns. So the members only its
// presentation uses live here, moved verbatim out of `VaultController.swift`, and
// that file carries the presentation the sidebar layout draws. A member both
// layouts use stays there. Swift's `private` is file-scoped, so the few
// members this file and the main one share lost `private`; treat this pair
// as one type's private parts (GL-36). `ClassicPresentationSelfTest` fails if
// one of these members moves back.

import AppKit

extension VaultController {

    func rebuildSecretsStack() {
        guard let secrets, !secrets.isEmpty else {
            reconcileSecretRows([])
            for v in secretsStack.arrangedSubviews {
                secretsStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            showSecretsState()
            return
        }
        reconcileSecretRows(secrets)
    }

    private func reconcileSecretRows(_ secrets: [VaultSecret]) {
        secretRows.reconcile(secrets,
                             key: \.name,
                             make: { [unowned self] secret in self.secretRowView(secret) },
                             update: { [unowned self] row, secret in
                                 (row as? HelmAccentRow)?.configure(self.secretRowContent(secret), theme: self.theme)
                             })
    }

    private func showSecretsState() {
        guard let secrets else {
            // B1: three states, not two. "Checking" until the first read
            // lands, then a real error - never a confident empty list.
            addUnknownState(to: secretsStack, symbol: "key", noun: "secrets")
            return
        }
        if secrets.isEmpty {
            addEmptyState(to: secretsStack,
                          symbol: "key",
                          text: "No saved secrets yet. Use \u{201c}Add Secret\u{201d} above - the value is entered directly in a real terminal, never through this app.")
            return
        }
    }

    func rebuildToolsStack() {
        guard let tools, !tools.isEmpty else {
            reconcileToolRows([])
            for v in toolsStack.arrangedSubviews {
                toolsStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            showToolsState()
            return
        }
        reconcileToolRows(tools)
    }

    private func reconcileToolRows(_ tools: [VaultTool]) {
        toolRows.reconcile(tools,
                           key: \.name,
                           make: { [unowned self] tool in self.toolRowView(tool) },
                           update: { [unowned self] row, tool in
                               (row as? HelmAccentRow)?.configure(self.toolRowContent(tool), theme: self.theme)
                           })
    }

    private func showToolsState() {
        guard let tools else {
            addUnknownState(to: toolsStack, symbol: "checkmark.shield", noun: "verified launchers")
            return
        }
        if tools.isEmpty {
            addEmptyState(to: toolsStack,
                          symbol: "checkmark.shield",
                          text: "No verified launchers registered with Automic Vault yet.")
            return
        }
    }

    /// This used to return a bare, unpadded, unconstrained wrapping label,
    /// which is why an empty Secrets / Verified Launchers panel collapsed to a
    /// header-only slab - measured live at `bodyH=0` for both, exactly the
    /// state a fresh machine (or a machine where `av list` returns nothing)
    /// shows (audit §5.5). `HelmEmptyState` is the app's one centered icon +
    /// wrapping copy empty state (`HelmDesignSystem.swift`, audit §6.3
    /// component 5 - the class this call site used to know as
    /// `ShiftEmptyStateView`, before Phase 4 promoted it); giving it a real
    /// height is what makes the panel actually occupy space.
    /// B1: the state that used to render as an empty list. Two wordings,
    /// because "I haven't looked yet" and "I looked and couldn't read it" are
    /// different problems with different fixes - the second one names the
    /// approval helper, which is the thing the captain actually has to go
    /// restart (and the same failure the lock screen already handles by name).
    private func addUnknownState(to stack: NSStackView, symbol: String, noun: String) {
        guard hasLoadedOnce else {
            // Review #3's UI4: while the first read is in flight this is a
            // *loading* state, and this app's loading language is D3's
            // skeleton (Review, Overview, Updates and GitHub Sync all took it;
            // this page was written before that pass and kept a sentence).
            // The card no longer sits empty either - see
            // `addLoadingSkeleton`'s note for why the empty card was the more
            // visible half of the finding.
            addLoadingSkeleton(to: stack)
            return
        }
        // A read that *failed* is not a loading state and must not shimmer as
        // though an answer were still coming. It names the approval helper,
        // which is the thing the captain actually has to go restart.
        addEmptyState(to: stack,
                      symbol: "exclamationmark.triangle",
                      text: readWasRefusedHere
                          ? "\(VaultSource.isolationNote)."
                          : "Couldn\u{2019}t read \(noun) from Automic Vault. Its approval helper may not be running - check the \u{201c}Automic Vault\u{201d} menu bar app, then Refresh.")
    }

    private func addEmptyState(to stack: NSStackView, symbol: String, text: String) {
        let empty = HelmEmptyState(symbol: symbol, body: text)
        empty.applyTheme(theme)
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.heightAnchor.constraint(equalToConstant: 90).isActive = true
        stack.addArrangedSubview(empty)
        empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// The app's one "accent-carrying row" (`HelmAccentRow`, `HelmDesignSystem.
    /// swift`) - a colored left accent bar, a tinted round badge, an uppercase
    /// kicker, a body line, a meta line, and a caller-owned trailing accessory
    /// for this row's own action buttons (the same slot the Hosts / Keys /
    /// Snippets lists use for Connect/Edit/…). Replaces the dense
    /// checklist-row shape `ToolRowLayout` gave these two sections before this
    /// pass - `ToolRowLayout` is still the right component for Updates/
    /// Bootstrap/Automation/GitHub Sync's fixed-column checklists, but a
    /// secret or a launcher reads as a record/finding, not a checklist item,
    /// which is exactly the distinction `HelmAccentRow`'s own doc comment
    /// draws between the two components.
    private func secretRowView(_ secret: VaultSecret) -> NSView {
        let row = HelmAccentRow(trailingAccessory: secretRowActions(for: secret), hover: false,
                                maxContentWidth: HelmAccentRow.recordContentWidth)
        row.configure(secretRowContent(secret), theme: theme)
        return row
    }

    private func secretRowActions(for secret: VaultSecret) -> NSView {
        let runButton = HelmButton(title: "Run injected\u{2026}", variant: .secondary, target: self, action: #selector(runInjectedTapped(_:)))
        runButton.controlSize = .small
        runButton.identifier = NSUserInterfaceItemIdentifier("secret-run:\(secret.name)")

        // Still only ever copies the NAME already shown in this row; the
        // secret's value never touches this app (see this file's header
        // comment).
        let copyButton = HelmButton(title: "Copy Name", variant: .secondary, target: self, action: #selector(copyNameTapped(_:)))
        copyButton.controlSize = .small
        copyButton.toolTip = "Copy secret name to clipboard"
        copyButton.identifier = NSUserInterfaceItemIdentifier("secret-copy:\(secret.name)")

        // AGENTS.md gotcha (12): `NSStackView`'s own `.gravityAreas` default
        // distribution honors no hugging priority, so without `.fill` +
        // required stack-level hugging on this stack (a content-priority API
        // is a no-op on the stack itself) - plus required hugging on each
        // button, since a stack has no intrinsic size of its own to hug
        // against - the solver's tie-break can stretch whichever button it
        // likes to fill the row. `HostsListSection`'s identical `actions`
        // stack (`HostsListSection.swift`) is the reference for this exact
        // trio. Without it, "Run injected…" rendered ~1000pt wide here.
        let actions = NSStackView(views: [runButton, copyButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        actions.distribution = .fill
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setClippingResistancePriority(.required, for: .horizontal)
        actions.translatesAutoresizingMaskIntoConstraints = false
        for button in [runButton, copyButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return actions
    }

    private func toolRowView(_ tool: VaultTool) -> NSView {
        let row = HelmAccentRow(hover: false)
        row.configure(toolRowContent(tool), theme: theme)
        return row
    }
}
