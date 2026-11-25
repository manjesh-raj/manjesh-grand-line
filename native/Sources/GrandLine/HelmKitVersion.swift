// Grand Line - native macOS app.
//
// S01 of the 2026-11-17 UI/UX proposals: the Helm kit has a version.
//
// The kit was large and real long before this file (every `Helm*.swift` file
// in this directory, a hundred-odd types, one spacing scale, one type scale),
// but nothing named a version of it. A pull request that changed a recipe had
// no way to say "this is a breaking change to the row" except prose, and
// nothing failed when a recipe changed under a page that depended on it.
//
// P-01 of the 2026-11-25 full review changed what is recorded by hand. The
// kit-wide semver (10.4.0 after eight days) and a committed table of SHA-256
// digests made this file, and the top of the release notes, a merge point for
// every UI branch. Neither is committed any more.
//
// Three pieces make the numbers real:
//
//   - This table. `HelmKit.components` gives every type declared in a kit file
//     its own semantic version. There is no kit-wide constant: the kit's
//     number is the date of its newest release note (`Helm 2026-11-26`).
//   - The release notes. `docs/design-system/helm-kit-releases/` holds one
//     file per release, named `YYYY-MM-DD-<slug>.md`, so two branches never
//     edit the same file. `docs/design-system/helm-kit-versions.md` keeps the
//     rules and the frozen 1.0.0 to 10.4.0 history.
//   - `HelmKitVersionSelfTest` (`FM_RUN_HELM_KIT_VERSION_TESTS`). It hashes
//     every kit file at the branch's base revision and in the working tree,
//     both with comments stripped, and fails when a file changed but none of
//     its components' versions moved. The base is `FM_HELM_KIT_BASE` (CI sets
//     it to the pull request's base, or the previous `main` on a push) and
//     otherwise the merge base with `origin/main`. It also checks that every
//     version here is the newest one the release notes reach, and that each
//     written bump kind matches its numbers.
//
// The bump rule for a component:
//
//   - patch: a visual tweak or a fix that changes no call site.
//   - minor: a new or extended component, option or token.
//   - major: a removed or renamed API, the only change a caller has to act
//     on. Its release-notes line has to say which API was removed or renamed.
//   - new: a component that did not exist (it enters at 1.0.0).
//
// **Kit and surfaces.** A kit file is any `Helm*.swift` file in this directory
// except this one. Its digest is guarded. A *surface* is a named app-level view
// the proposals also version (a page, the window toolbar, a shared vocabulary).
// A surface carries a version and a release-notes line like a component, but
// its file is not hashed: page files change for many reasons that are not a
// design-system release, and the hash would make every one of them a bump.
//
// To change a kit file: bump the version of the component you changed, add a
// release file with one line per component that moved, and run the suite.

import Foundation

enum HelmKit {

    struct Component {
        let name: String
        let version: String
        let file: String

        init(_ name: String, _ version: String, file: String) {
            self.name = name
            self.version = version
            self.file = file
        }
    }

    /// Every type declared at the top level of a kit file.
    ///
    /// The suite fails on a type that is declared in a kit file and missing
    /// here, and on an entry whose type is no longer there, so a new component
    /// enters the table at 1.0.0 the day it lands.
    static let components: [Component] = [
        // HelmBackgroundReload.swift
        Component("HelmBackgroundReload", "1.0.0", file: "HelmBackgroundReload.swift"),
        Component("HelmParseThread", "1.0.0", file: "HelmBackgroundReload.swift"),
        // HelmBarPanel.swift
        Component("HelmBarPanel", "1.0.0", file: "HelmBarPanel.swift"),
        Component("HelmBarPanelWindow", "1.0.0", file: "HelmBarPanel.swift"),
        // HelmCardGrid.swift
        Component("HelmCardGrid", "1.1.0", file: "HelmCardGrid.swift"),
        Component("HelmGridCardView", "1.2.0", file: "HelmCardGrid.swift"),
        // HelmConfirm.swift
        Component("HelmConfirm", "1.0.0", file: "HelmConfirm.swift"),
        Component("HelmConfirmView", "1.0.0", file: "HelmConfirm.swift"),
        // HelmDataTable.swift
        Component("HelmDataTable", "1.0.1", file: "HelmDataTable.swift"),
        Component("HelmDataTableActionsCell", "1.0.0", file: "HelmDataTable.swift"),
        Component("HelmDataTableRowView", "1.0.0", file: "HelmDataTable.swift"),
        Component("HelmDataTableRunDotsCell", "1.0.0", file: "HelmDataTable.swift"),
        Component("HelmTagChip", "1.0.0", file: "HelmDataTable.swift"),
        // HelmDateField.swift
        Component("HelmDateField", "1.0.0", file: "HelmDateField.swift"),
        // HelmDaylight.swift
        Component("HelmDomainHue", "1.1.0", file: "HelmDaylight.swift"),
        // HelmDesignSystem.swift
        Component("HelmAccentRow", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmButton", "1.4.0", file: "HelmDesignSystem.swift"),
        Component("HelmCard", "2.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmCountBadge", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmEmptyState", "1.0.1", file: "HelmDesignSystem.swift"),
        Component("HelmFocusRing", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmMetrics", "1.1.0", file: "HelmDesignSystem.swift"),
        Component("HelmPageToolbar", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmPopUpButton", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmResponsiveGrid", "1.1.0", file: "HelmDesignSystem.swift"),
        Component("HelmSegmentedTabs", "1.3.0", file: "HelmDesignSystem.swift"),
        Component("HelmType", "1.2.0", file: "HelmDesignSystem.swift"),
        // HelmDensity.swift
        Component("HelmDensity", "1.0.0", file: "HelmDensity.swift"),
        // HelmDrillHeader.swift
        Component("HelmDrillHeader", "1.0.0", file: "HelmDrillHeader.swift"),
        // HelmFocusVisibility.swift
        Component("HelmFocusVisibility", "1.0.0", file: "HelmFocusVisibility.swift"),
        // HelmForm.swift
        Component("HelmCenteredSecureTextFieldCell", "1.1.0", file: "HelmForm.swift"),
        Component("HelmCenteredTextFieldCell", "1.0.0", file: "HelmForm.swift"),
        Component("HelmChipInput", "1.1.0", file: "HelmForm.swift"),
        Component("HelmDotAccessory", "1.0.0", file: "HelmForm.swift"),
        Component("HelmField", "1.2.0", file: "HelmForm.swift"),
        Component("HelmFieldCard", "1.1.0", file: "HelmForm.swift"),
        Component("HelmFieldCentering", "1.1.0", file: "HelmForm.swift"),
        Component("HelmFormSheet", "1.2.0", file: "HelmForm.swift"),
        Component("HelmSearchField", "1.2.0", file: "HelmForm.swift"),
        Component("HelmSecureTextField", "1.2.0", file: "HelmForm.swift"),
        Component("HelmTextField", "1.1.0", file: "HelmForm.swift"),
        Component("HelmTextView", "1.1.0", file: "HelmForm.swift"),
        Component("HelmToggle", "1.0.0", file: "HelmForm.swift"),
        Component("HelmToggleRow", "1.1.0", file: "HelmForm.swift"),
        // HelmGradientTile.swift
        Component("HelmGradientTile", "1.0.0", file: "HelmGradientTile.swift"),
        // HelmHeroCard.swift
        Component("HelmHeroCard", "2.1.0", file: "HelmHeroCard.swift"),
        Component("HelmHeroStatusPill", "1.0.0", file: "HelmHeroCard.swift"),
        Component("HelmHeroTile", "1.1.0", file: "HelmHeroCard.swift"),
        Component("HelmHeroTileGrid", "1.1.0", file: "HelmHeroCard.swift"),
        // HelmHeroColumn.swift
        Component("HelmHeroColumn", "1.6.0", file: "HelmHeroColumn.swift"),
        Component("HelmHeroNavRow", "1.0.0", file: "HelmHeroColumn.swift"),
        Component("HelmHeroRow", "1.0.0", file: "HelmHeroColumn.swift"),
        // HelmHeroSplitCard.swift
        Component("HelmHeroSplitCard", "1.0.0", file: "HelmHeroSplitCard.swift"),
        // HelmHeroSurface.swift
        Component("HelmHeroSurface", "1.3.0", file: "HelmHeroSurface.swift"),
        // HelmInput.swift
        Component("HelmFocusRegistration", "1.0.0", file: "HelmInput.swift"),
        Component("HelmFocusSensing", "1.0.0", file: "HelmInput.swift"),
        Component("HelmInputSurface", "1.2.0", file: "HelmInput.swift"),
        Component("HelmSelection", "1.0.0", file: "HelmInput.swift"),
        // HelmKeyHint.swift
        Component("HelmKeyHint", "1.0.0", file: "HelmKeyHint.swift"),
        // HelmKeyedRows.swift
        Component("HelmKeyedRows", "1.0.0", file: "HelmKeyedRows.swift"),
        // HelmKit.swift
        Component("HelmFlatList", "1.0.0", file: "HelmKit.swift"),
        Component("HelmKPIStrip", "1.4.0", file: "HelmKit.swift"),
        Component("HelmKeyboardListView", "1.0.0", file: "HelmKit.swift"),
        Component("HelmListNavigation", "1.0.0", file: "HelmKit.swift"),
        Component("HelmOverflowMenu", "1.0.0", file: "HelmKit.swift"),
        Component("HelmReading", "1.0.0", file: "HelmKit.swift"),
        Component("HelmRelativeTime", "1.0.0", file: "HelmKit.swift"),
        Component("HelmSectionHeader", "1.1.0", file: "HelmKit.swift"),
        Component("HelmStatusPill", "1.1.0", file: "HelmKit.swift"),
        // HelmListMotion.swift
        Component("HelmRowEntrance", "1.0.0", file: "HelmListMotion.swift"),
        Component("HelmRowWash", "1.0.0", file: "HelmListMotion.swift"),
        Component("HelmScrollEdgeHairline", "1.0.0", file: "HelmListMotion.swift"),
        // HelmModuleCard.swift
        Component("HelmDaylightPriority", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleCard", "1.5.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleChip", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModulePeekRow", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleRowState", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleUsageRow", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleUsageSection", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleUsageSpend", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleUsageStatus", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmProgressBar", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmRingGauge", "1.3.0", file: "HelmModuleCard.swift"),
        // HelmMotion.swift
        Component("HelmDisplayAccessibility", "1.0.0", file: "HelmMotion.swift"),
        Component("HelmMotion", "1.0.0", file: "HelmMotion.swift"),
        // HelmNestedScrollView.swift
        Component("HelmNestedScrollView", "1.0.0", file: "HelmNestedScrollView.swift"),
        // HelmOverflowHint.swift
        Component("HelmOverflowHint", "1.0.0", file: "HelmOverflowHint.swift"),
        // HelmPageSidebar.swift
        Component("HelmPageSidebar", "1.2.0", file: "HelmPageSidebar.swift"),
        // HelmPlateCard.swift
        Component("HelmPlateCard", "1.1.1", file: "HelmPlateCard.swift"),
        // HelmPromptWell.swift
        Component("HelmPromptTextView", "1.0.0", file: "HelmPromptWell.swift"),
        Component("HelmPromptWell", "1.0.0", file: "HelmPromptWell.swift"),
        // HelmRevealableSecretField.swift
        Component("HelmRevealableSecretField", "1.0.0", file: "HelmRevealableSecretField.swift"),
        // HelmScrollMemory.swift
        Component("HelmScrollMemory", "1.0.0", file: "HelmScrollMemory.swift"),
        // HelmSkeleton.swift
        Component("HelmSkeletonList", "1.1.0", file: "HelmSkeleton.swift"),
        Component("HelmSkeletonRow", "1.1.0", file: "HelmSkeleton.swift"),
        // HelmSplitButton.swift
        Component("HelmSplitButton", "1.0.0", file: "HelmSplitButton.swift"),
        // HelmSplitPage.swift
        Component("HelmHitTransparentView", "1.0.0", file: "HelmSplitPage.swift"),
        Component("HelmSplitPage", "1.2.0", file: "HelmSplitPage.swift"),
        Component("HelmSplitPageHosting", "1.0.0", file: "HelmSplitPage.swift"),
        // HelmSymbol.swift
        Component("HelmSymbol", "1.1.0", file: "HelmSymbol.swift"),
        // HelmTextScale.swift
        Component("HelmTextScale", "1.0.0", file: "HelmTextScale.swift"),
        // HelmTheme.swift
        Component("HelmTerminalCard", "1.0.0", file: "HelmTheme.swift"),
        Component("HelmTheme", "1.0.0", file: "HelmTheme.swift"),
        // HelmUIComponents.swift
        Component("HelmComposerCard", "1.1.0", file: "HelmUIComponents.swift"),
        Component("HelmContrast", "1.1.0", file: "HelmUIComponents.swift"),
        Component("HelmGestureArbitration", "1.0.0", file: "HelmUIComponents.swift"),
        Component("HelmRefreshPill", "1.0.0", file: "HelmUIComponents.swift"),
        Component("HelmSignalDot", "1.0.0", file: "HelmUIComponents.swift"),
        Component("HelmTableView", "1.0.0", file: "HelmUIComponents.swift"),
        Component("HelmTint", "1.0.0", file: "HelmUIComponents.swift"),
        // HelmZoomStepper.swift
        Component("HelmZoomStepper", "1.0.0", file: "HelmZoomStepper.swift"),
        // HelmNotice.swift
        Component("HelmNotice", "1.0.0", file: "HelmNotice.swift"),
        // HelmFilterBar.swift
        Component("HelmFilterBar", "1.0.1", file: "HelmFilterBar.swift"),
        // HelmChoiceCard.swift
        Component("HelmChoiceCard", "1.0.0", file: "HelmChoiceCard.swift"),
        // HelmIconButton.swift
        Component("HelmIconButton", "1.1.0", file: "HelmIconButton.swift"),
        // HelmPageScaffold.swift
        Component("HelmPageScaffold", "1.0.0", file: "HelmPageScaffold.swift"),
    ]

    /// App-level views the proposals version alongside the kit. Not hashed;
    /// see the file header.
    static let surfaces: [Component] = [
        Component("StrawHatMenuBarPopoverController", "1.1.0", file: "StrawHatMenuBar.swift"),
        Component("WorkspaceInspectorCrewPanel", "1.0.1", file: "WorkspaceInspectorCrewPanel.swift"),
        Component("WorkspaceInspector", "2.0.0", file: "WorkspaceInspector.swift"),
        Component("PageShortcuts", "1.1.0", file: "HiddenPowerTips.swift"),
        Component("WorkspaceGoMenu", "1.1.0", file: "MainMenuBuilder.swift"),
        Component("GitHub sync (page)", "1.1.0", file: "GitHubSyncController.swift"),
        Component("Kubernetes (page)", "1.0.2", file: "KubernetesController.swift"),
        Component("SettingsThemeCard", "1.2.0", file: "SettingsThemeCard.swift"),
        Component("ShiftProjectPalette", "2.0.0", file: "ShiftBoardViews.swift"),
        Component("Home Health card", "1.0.1", file: "HomeCanvasController.swift"),
        Component("Home Tasks card", "1.0.1", file: "HomeCanvasController.swift"),
        Component("Home (page)", "2.2.0", file: "HomeCanvasController.swift"),
        Component("Home Hosts card", "1.0.0", file: "HomeCanvasController.swift"),
        Component("Home Claude card", "1.1.1", file: "HomeCanvasController.swift"),
        Component("Home Fleet card", "1.1.1", file: "HomeCanvasController.swift"),
        Component("Health (page)", "1.0.0", file: "HealthController.swift"),
        Component("Connections (page)", "1.1.0", file: "HostsController.swift"),
        Component("Console (page)", "1.2.0", file: "ConsoleController.swift"),
        Component("Claude usage popover", "1.0.0", file: "QuotaUsagePopover.swift"),
        Component("Secrets (page)", "1.1.0", file: "CredentialVaultController.swift"),
        Component("Automic Vault (page)", "1.0.0", file: "VaultController.swift"),
        Component("Dictation (page)", "1.0.0", file: "DictationController.swift"),
        Component("Setup (page)", "1.1.0", file: "SetupHeroRow.swift"),
        Component("Settings (page)", "1.1.0", file: "SettingsController.swift"),
        Component("MorningBriefingCard", "1.0.1", file: "MorningBriefingCard.swift"),
        Component("StateVocabulary", "1.1.0", file: "StateVocabulary.swift"),
        Component("Tasks board (page)", "1.3.0", file: "ShiftBoardViews.swift"),
        Component("Calendar (page)", "1.0.0", file: "ShiftCalendarHero.swift"),
        Component("Sticky Board (page)", "1.0.0", file: "StickyBoardController.swift"),
        Component("WorkspaceModuleHeader", "2.0.0", file: "WorkspaceModuleHeader.swift"),
        Component("WorkspaceToolbar", "1.2.0", file: "WorkspaceToolbar.swift"),
        Component("WorkspaceSidebar", "4.1.0", file: "WorkspaceSidebar.swift"),
        Component("DevOps Hub (page)", "2.0.0", file: "DevOpsHubController.swift"),
        Component("Lock screen", "1.0.0", file: "LockScreenController.swift"),
        Component("Notifications panel", "1.0.0", file: "NotificationBridgePanel.swift"),
        Component("Toasts", "1.0.0", file: "Toast.swift"),
        Component("Dictation HUD", "1.0.0", file: "DictationHUD.swift"),
        Component("⌘K palette", "1.0.0", file: "UnifiedSearch.swift"),
        Component("Capture panel", "1.0.0", file: "ShiftQuickCapture.swift"),
        Component("Task sheet", "1.0.0", file: "ShiftTaskEditorController.swift"),
        Component("Crew (page)", "1.2.0", file: "FleetController.swift"),
        Component("Reply composer", "1.0.0", file: "FleetReplyCard.swift"),
        Component("Menu-bar popover", "1.0.0", file: "CompactModePopover.swift"),
    ]
}
