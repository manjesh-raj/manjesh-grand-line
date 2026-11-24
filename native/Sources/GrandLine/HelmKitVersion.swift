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
// Three pieces make the numbers real:
//
//   - This table. `HelmKit.version` is the kit as a whole, and
//     `HelmKit.components` gives every type declared in a kit file its own
//     semantic version. The kit at 30e26ac3 is Helm 1.0.0 with every
//     component at 1.0.0.
//   - The release notes, `docs/design-system/helm-kit-versions.md`. One
//     section per kit version, newest first, and one bullet per component that
//     moved, naming the proposal or PR.
//   - `HelmKitVersionSelfTest` (`FM_RUN_HELM_KIT_VERSION_TESTS`). It hashes
//     every kit file with its comments stripped and fails the run when a file
//     changed but none of its components' versions moved. It also checks that
//     every version in this table has its line in the release notes, that the
//     bump kind written there matches the numbers, and that the kit version
//     moved by the largest bump of its release.
//
// The bump rule, the same one the proposals were written against:
//
//   - patch: a visual tweak that changes no call site.
//   - minor: a new or extended component, option or token.
//   - major: a breaking replacement or a removal.
//   - new: a component that did not exist (it enters at 1.0.0).
//
// **Kit and surfaces.** A kit file is any `Helm*.swift` file in this directory
// except this one. Its digest is guarded. A *surface* is a named app-level view
// the proposals also version (a page, the window toolbar, a shared vocabulary).
// A surface carries a version and a release-notes line like a component, but
// its file is not hashed: page files change for many reasons that are not a
// design-system release, and the hash would make every one of them a bump.
//
// To change a kit file: bump the version of the component you changed (and the
// kit version), add the release-notes lines, run the suite, and paste the
// digest it prints into `sourceDigests`. The suite only prints a new digest
// once a version has moved, so the table cannot be re-recorded without one.

import Foundation

enum HelmKit {

    /// The kit as a whole. Moves by the largest bump of each release.
    static let version = "10.4.0"

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
        Component("HelmSegmentedTabs", "1.2.0", file: "HelmDesignSystem.swift"),
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
        Component("HelmChipInput", "1.0.0", file: "HelmForm.swift"),
        Component("HelmDotAccessory", "1.0.0", file: "HelmForm.swift"),
        Component("HelmField", "1.2.0", file: "HelmForm.swift"),
        Component("HelmFieldCard", "1.1.0", file: "HelmForm.swift"),
        Component("HelmFieldCentering", "1.1.0", file: "HelmForm.swift"),
        Component("HelmFormSheet", "1.1.0", file: "HelmForm.swift"),
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
        Component("HelmHeroTile", "1.0.0", file: "HelmHeroCard.swift"),
        Component("HelmHeroTileGrid", "1.0.0", file: "HelmHeroCard.swift"),
        // HelmHeroColumn.swift
        Component("HelmHeroColumn", "1.4.0", file: "HelmHeroColumn.swift"),
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
        Component("HelmKPIStrip", "1.3.0", file: "HelmKit.swift"),
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
    ]

    struct SourceDigest {
        let file: String
        /// The file's components and their versions when the digest was
        /// recorded, as `Name@1.0.0` pairs sorted by name.
        let stamp: String
        /// SHA-256 of the file with comments and blank lines stripped.
        let sha256: String
    }

    /// One recorded digest per kit file.
    static let sourceDigests: [SourceDigest] = [
        SourceDigest(file: "HelmPromptWell.swift", stamp: "HelmPromptTextView@1.0.0,HelmPromptWell@1.0.0", sha256: "f63de288d5cb52389445855414c463ea6dd9edee7d4b6db6aa7ce0668017e26c"),
        SourceDigest(file: "HelmPageScaffold.swift", stamp: "HelmPageScaffold@1.0.0", sha256: "cb99965fc36bd64fa45b76f8321efa195f4b3e1e6539271ae776408206fb4134"),
        SourceDigest(file: "HelmDensity.swift", stamp: "HelmDensity@1.0.0", sha256: "c725fb34b3438a1b7bd2ee9a3ba69a52d05b328e9a09b365bd4a468611d61983"),
        SourceDigest(file: "HelmHeroColumn.swift", stamp: "HelmHeroColumn@1.4.0,HelmHeroNavRow@1.0.0,HelmHeroRow@1.0.0", sha256: "c731441f02be60fd5623bfb53fefafce6cf1addfeffe958cf56a42a0a034baca"),
        SourceDigest(file: "HelmHeroSplitCard.swift", stamp: "HelmHeroSplitCard@1.0.0", sha256: "97051bf0f9e67923946b5f2c9c33bff0cb9dd03506d027f1540bc9e01dbf7bef"),
        SourceDigest(file: "HelmHeroSurface.swift", stamp: "HelmHeroSurface@1.3.0", sha256: "41ae8e8154001e27470f163fc9300d007551dba31e6c55b070778b8b80907895"),
        SourceDigest(file: "HelmHeroCard.swift", stamp: "HelmHeroCard@2.1.0,HelmHeroStatusPill@1.0.0,HelmHeroTile@1.0.0,HelmHeroTileGrid@1.0.0", sha256: "f9700de1da7bda6475bedea5584075f6192606e267f336e6eeaa9cf1868ff174"),
        SourceDigest(file: "HelmIconButton.swift", stamp: "HelmIconButton@1.1.0", sha256: "3c6f7a325c59b4768ba3484955c00bd9c810d40d62a1636daf8553f16409e83a"),
        SourceDigest(file: "HelmChoiceCard.swift", stamp: "HelmChoiceCard@1.0.0", sha256: "61392738ce874320cc5c6e4b261921f969545e264122a1094f6be6eb6fdc676b"),
        SourceDigest(file: "HelmFilterBar.swift", stamp: "HelmFilterBar@1.0.1", sha256: "1b8f2acace87634cb6575687afc07fa63b9f4aa0ef00f0928ce99221f9248a36"),
        SourceDigest(file: "HelmNotice.swift", stamp: "HelmNotice@1.0.0", sha256: "a59b3764652021b83e43237d6f3f48c4c11abed019e03e1a3bd2155e8370f8c2"),
        SourceDigest(file: "HelmBackgroundReload.swift", stamp: "HelmBackgroundReload@1.0.0,HelmParseThread@1.0.0", sha256: "9fdf57f19f0187aaaf3f29774bde5659a79547ea20b5b21eb2c71552e1621d4b"),
        SourceDigest(file: "HelmBarPanel.swift", stamp: "HelmBarPanel@1.0.0,HelmBarPanelWindow@1.0.0", sha256: "6811b25ea2dc491014342b855ce2b8eefcbd29118920f1007fafcbaf74d7c5e9"),
        SourceDigest(file: "HelmCardGrid.swift", stamp: "HelmCardGrid@1.1.0,HelmGridCardView@1.2.0", sha256: "7907a592d392344b7308af02e90f691df9c4567662e3377b919959abde2e9262"),
        SourceDigest(file: "HelmConfirm.swift", stamp: "HelmConfirm@1.0.0,HelmConfirmView@1.0.0", sha256: "f963808036b62ebe6d2ee5c85bc522c8c55cae7d927417525faacb79d8f389e0"),
        SourceDigest(file: "HelmDataTable.swift", stamp: "HelmDataTable@1.0.1,HelmDataTableActionsCell@1.0.0,HelmDataTableRowView@1.0.0,HelmDataTableRunDotsCell@1.0.0,HelmTagChip@1.0.0", sha256: "0ffd6a2ceb8f457a59eab4679fff56483f85b19c3da72e11dbe26cbcb46ac48d"),
        SourceDigest(file: "HelmDateField.swift", stamp: "HelmDateField@1.0.0", sha256: "5f99cbfec49aa505d830385f27c038c793791c8f4f90be50896823841be934be"),
        SourceDigest(file: "HelmDaylight.swift", stamp: "HelmDomainHue@1.1.0", sha256: "7e2ca21571386bdcec576440d40a8cbc377b8afc8e4566e8ea342d3172c037f6"),
        SourceDigest(file: "HelmDesignSystem.swift", stamp: "HelmAccentRow@1.0.0,HelmButton@1.4.0,HelmCard@2.0.0,HelmCountBadge@1.0.0,HelmEmptyState@1.0.1,HelmFocusRing@1.0.0,HelmMetrics@1.1.0,HelmPageToolbar@1.0.0,HelmPopUpButton@1.0.0,HelmResponsiveGrid@1.1.0,HelmSegmentedTabs@1.2.0,HelmType@1.2.0", sha256: "dcd89baeb71a61728b9ef28e4ef5ba8dec6eb2f0eabf679670acf8114b71b05e"),
        SourceDigest(file: "HelmDrillHeader.swift", stamp: "HelmDrillHeader@1.0.0", sha256: "73712c9e058defa127936a03d9b47618e039e031d7713652d471db2c1a29480b"),
        SourceDigest(file: "HelmFocusVisibility.swift", stamp: "HelmFocusVisibility@1.0.0", sha256: "de4eab8dd4eac530b4f2c41fe9a9da80ae8e1665b02c9a4424df5c8dd6f9872f"),
        SourceDigest(file: "HelmForm.swift", stamp: "HelmCenteredSecureTextFieldCell@1.1.0,HelmCenteredTextFieldCell@1.0.0,HelmChipInput@1.0.0,HelmDotAccessory@1.0.0,HelmField@1.2.0,HelmFieldCard@1.1.0,HelmFieldCentering@1.1.0,HelmFormSheet@1.1.0,HelmSearchField@1.2.0,HelmSecureTextField@1.2.0,HelmTextField@1.1.0,HelmTextView@1.1.0,HelmToggle@1.0.0,HelmToggleRow@1.1.0", sha256: "3a298c3ab9d82f52517d2ad7d47c9e20bc390f5cfa1aded192f566beac484dd2"),
        SourceDigest(file: "HelmGradientTile.swift", stamp: "HelmGradientTile@1.0.0", sha256: "b2ec10777e795afde1a07241b6f9991c3fe12616c1b293e63e45dc22bc65f517"),
        SourceDigest(file: "HelmInput.swift", stamp: "HelmFocusRegistration@1.0.0,HelmFocusSensing@1.0.0,HelmInputSurface@1.2.0,HelmSelection@1.0.0", sha256: "3e37c4f1a0919196a9ada15b4e1217721f3d54929be690d589e0990d7de470ff"),
        SourceDigest(file: "HelmKeyHint.swift", stamp: "HelmKeyHint@1.0.0", sha256: "fc81e10be20a16c5bc8fa0074639fbbbe4b9abc73f82cadb6e647c75c703b854"),
        SourceDigest(file: "HelmKeyedRows.swift", stamp: "HelmKeyedRows@1.0.0", sha256: "ee6de57defc5a7b90e58a48918aea4d7eea383521f54782b6cc39600feced94c"),
        SourceDigest(file: "HelmKit.swift", stamp: "HelmFlatList@1.0.0,HelmKPIStrip@1.3.0,HelmKeyboardListView@1.0.0,HelmListNavigation@1.0.0,HelmOverflowMenu@1.0.0,HelmReading@1.0.0,HelmRelativeTime@1.0.0,HelmSectionHeader@1.1.0,HelmStatusPill@1.1.0", sha256: "5094793dc8ceca7b48765ffb6e71a1e5d15de75b4694dd253b569236d1578a90"),
        SourceDigest(file: "HelmListMotion.swift", stamp: "HelmRowEntrance@1.0.0,HelmRowWash@1.0.0,HelmScrollEdgeHairline@1.0.0", sha256: "b61272f6eb12d0e43b75f5aa8b13a5013af1bb8fe0d341e66fc59cca707ac7df"),
        SourceDigest(file: "HelmModuleCard.swift", stamp: "HelmDaylightPriority@1.0.0,HelmModuleCard@1.5.0,HelmModuleChip@1.0.0,HelmModulePeekRow@1.0.0,HelmModuleRowState@1.0.0,HelmModuleUsageRow@1.0.0,HelmModuleUsageSection@1.0.0,HelmModuleUsageSpend@1.0.0,HelmModuleUsageStatus@1.0.0,HelmProgressBar@1.0.0,HelmRingGauge@1.3.0", sha256: "0e0a6e5c6d6297d80c7a211b49b4ea0231984a8011f267eefb33362f25b3a586"),
        SourceDigest(file: "HelmMotion.swift", stamp: "HelmDisplayAccessibility@1.0.0,HelmMotion@1.0.0", sha256: "d4c8c1bfa26b3f14604b271d024f5e4445656c3989364b80cf9dc29dc058173b"),
        SourceDigest(file: "HelmNestedScrollView.swift", stamp: "HelmNestedScrollView@1.0.0", sha256: "f7f7f1af0345d92201f8d86b3a02625e31e887258cb7ca078a2c978c8fbf2ede"),
        SourceDigest(file: "HelmOverflowHint.swift", stamp: "HelmOverflowHint@1.0.0", sha256: "5ad0c7b7fcd180a18f38e1f0de119b44a752bc3dd93990b7ce3b1d68759233f6"),
        SourceDigest(file: "HelmPageSidebar.swift", stamp: "HelmPageSidebar@1.2.0", sha256: "0e9d15e7fdeb8196d36a67c0615732240bf114aabdd63806115bc9c889ca8a60"),
        SourceDigest(file: "HelmPlateCard.swift", stamp: "HelmPlateCard@1.1.1", sha256: "1865ad7c7c199b05745191c02d520312deae694e72149d67184841bea0c0d4d8"),
        SourceDigest(file: "HelmRevealableSecretField.swift", stamp: "HelmRevealableSecretField@1.0.0", sha256: "0c7ef5b228b5bb38c51c646e74d1985cb220e26998251f86f7b1fe3845d65398"),
        SourceDigest(file: "HelmScrollMemory.swift", stamp: "HelmScrollMemory@1.0.0", sha256: "462b598c2a7fe6105bb84271f16a5829fd8ae1fd5c5f221b2a02801c066f18a2"),
        SourceDigest(file: "HelmSkeleton.swift", stamp: "HelmSkeletonList@1.1.0,HelmSkeletonRow@1.1.0", sha256: "ee0651854366bf1dbc7108ac12dc731956e7ef163b60dc6b711a8c0e33f85bbf"),
        SourceDigest(file: "HelmSplitButton.swift", stamp: "HelmSplitButton@1.0.0", sha256: "f9ba58abda9751dfeabe1ba021f9da70077f2a4ffc845900b79f9d1ef36b769b"),
        SourceDigest(file: "HelmSplitPage.swift", stamp: "HelmHitTransparentView@1.0.0,HelmSplitPage@1.2.0,HelmSplitPageHosting@1.0.0", sha256: "2cee934061cf5c1852ae8c6d74e006b7ce08c10d7cfd7e378aa2188d0e398761"),
        SourceDigest(file: "HelmSymbol.swift", stamp: "HelmSymbol@1.1.0", sha256: "39157b17c23749b045d2e2e5886e631d2a4c39acd8a5b75b124d22d521bdf371"),
        SourceDigest(file: "HelmTextScale.swift", stamp: "HelmTextScale@1.0.0", sha256: "beffe9873d7dd7464ddbfecf30779b3b3c5bd5055bc5becfa385d9a2ca44f4f4"),
        SourceDigest(file: "HelmTheme.swift", stamp: "HelmTerminalCard@1.0.0,HelmTheme@1.0.0", sha256: "aeb5c35527f4ef0d337751ac64656b6277d8dae167eea1b074d71caf0bc1158e"),
        SourceDigest(file: "HelmUIComponents.swift", stamp: "HelmComposerCard@1.1.0,HelmContrast@1.1.0,HelmGestureArbitration@1.0.0,HelmRefreshPill@1.0.0,HelmSignalDot@1.0.0,HelmTableView@1.0.0,HelmTint@1.0.0", sha256: "db5e2292d9b8db31efd7f6517d553587604da9362cec3309a113c547850a0981"),
        SourceDigest(file: "HelmZoomStepper.swift", stamp: "HelmZoomStepper@1.0.0", sha256: "c5700730b36166ba03d1ebd484c91c7d87b8b141dfdc973f4244c4481cb8bd80"),
    ]
}
