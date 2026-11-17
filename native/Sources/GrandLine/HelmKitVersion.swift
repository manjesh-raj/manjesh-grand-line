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
    static let version = "1.2.0"

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
        Component("HelmCardGrid", "1.0.0", file: "HelmCardGrid.swift"),
        Component("HelmGridCardView", "1.0.0", file: "HelmCardGrid.swift"),
        // HelmConfirm.swift
        Component("HelmConfirm", "1.0.0", file: "HelmConfirm.swift"),
        Component("HelmConfirmView", "1.0.0", file: "HelmConfirm.swift"),
        // HelmDataTable.swift
        Component("HelmDataTable", "1.0.0", file: "HelmDataTable.swift"),
        Component("HelmDataTableActionsCell", "1.0.0", file: "HelmDataTable.swift"),
        Component("HelmDataTableRowView", "1.0.0", file: "HelmDataTable.swift"),
        Component("HelmDataTableRunDotsCell", "1.0.0", file: "HelmDataTable.swift"),
        Component("HelmTagChip", "1.0.0", file: "HelmDataTable.swift"),
        // HelmDateField.swift
        Component("HelmDateField", "1.0.0", file: "HelmDateField.swift"),
        // HelmDaylight.swift
        Component("HelmDomainHue", "1.0.0", file: "HelmDaylight.swift"),
        // HelmDesignSystem.swift
        Component("HelmAccentRow", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmButton", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmCard", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmCountBadge", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmEmptyState", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmFocusRing", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmMetrics", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmPageToolbar", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmPopUpButton", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmResponsiveGrid", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmSegmentedTabs", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmStatTile", "1.0.0", file: "HelmDesignSystem.swift"),
        Component("HelmType", "1.0.0", file: "HelmDesignSystem.swift"),
        // HelmDrillHeader.swift
        Component("HelmDrillHeader", "1.0.0", file: "HelmDrillHeader.swift"),
        // HelmFocusVisibility.swift
        Component("HelmFocusVisibility", "1.0.0", file: "HelmFocusVisibility.swift"),
        // HelmForm.swift
        Component("HelmCenteredSecureTextFieldCell", "1.0.0", file: "HelmForm.swift"),
        Component("HelmCenteredTextFieldCell", "1.0.0", file: "HelmForm.swift"),
        Component("HelmChipInput", "1.0.0", file: "HelmForm.swift"),
        Component("HelmDotAccessory", "1.0.0", file: "HelmForm.swift"),
        Component("HelmField", "1.0.0", file: "HelmForm.swift"),
        Component("HelmFieldCard", "1.0.0", file: "HelmForm.swift"),
        Component("HelmFieldCentering", "1.0.0", file: "HelmForm.swift"),
        Component("HelmFormSheet", "1.0.0", file: "HelmForm.swift"),
        Component("HelmSearchField", "1.0.0", file: "HelmForm.swift"),
        Component("HelmSecureTextField", "1.0.0", file: "HelmForm.swift"),
        Component("HelmTextField", "1.0.0", file: "HelmForm.swift"),
        Component("HelmTextView", "1.0.0", file: "HelmForm.swift"),
        Component("HelmToggle", "1.0.0", file: "HelmForm.swift"),
        Component("HelmToggleRow", "1.0.0", file: "HelmForm.swift"),
        // HelmGradientTile.swift
        Component("HelmGradientTile", "1.0.0", file: "HelmGradientTile.swift"),
        // HelmInput.swift
        Component("HelmFocusRegistration", "1.0.0", file: "HelmInput.swift"),
        Component("HelmFocusSensing", "1.0.0", file: "HelmInput.swift"),
        Component("HelmInputSurface", "1.0.0", file: "HelmInput.swift"),
        Component("HelmSelection", "1.0.0", file: "HelmInput.swift"),
        // HelmKeyHint.swift
        Component("HelmKeyHint", "1.0.0", file: "HelmKeyHint.swift"),
        // HelmKeyedRows.swift
        Component("HelmKeyedRows", "1.0.0", file: "HelmKeyedRows.swift"),
        // HelmKit.swift
        Component("HelmFlatList", "1.0.0", file: "HelmKit.swift"),
        Component("HelmKPIStrip", "1.0.0", file: "HelmKit.swift"),
        Component("HelmKeyboardListView", "1.0.0", file: "HelmKit.swift"),
        Component("HelmListNavigation", "1.0.0", file: "HelmKit.swift"),
        Component("HelmOverflowMenu", "1.0.0", file: "HelmKit.swift"),
        Component("HelmReading", "1.0.0", file: "HelmKit.swift"),
        Component("HelmRelativeTime", "1.0.0", file: "HelmKit.swift"),
        Component("HelmSectionHeader", "1.0.0", file: "HelmKit.swift"),
        Component("HelmStatusPill", "1.0.0", file: "HelmKit.swift"),
        // HelmListMotion.swift
        Component("HelmRowEntrance", "1.0.0", file: "HelmListMotion.swift"),
        Component("HelmRowWash", "1.0.0", file: "HelmListMotion.swift"),
        Component("HelmScrollEdgeHairline", "1.0.0", file: "HelmListMotion.swift"),
        // HelmMetricCard.swift
        Component("HelmMetricCard", "1.0.0", file: "HelmMetricCard.swift"),
        Component("HelmMetricRow", "1.0.0", file: "HelmMetricCard.swift"),
        // HelmModuleCard.swift
        Component("HelmDaylightPriority", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleCard", "1.1.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleChip", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModulePeekRow", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleRowState", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleUsageRow", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleUsageSection", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleUsageSpend", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmModuleUsageStatus", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmProgressBar", "1.0.0", file: "HelmModuleCard.swift"),
        Component("HelmRingGauge", "1.1.0", file: "HelmModuleCard.swift"),
        // HelmMotion.swift
        Component("HelmDisplayAccessibility", "1.0.0", file: "HelmMotion.swift"),
        Component("HelmMotion", "1.0.0", file: "HelmMotion.swift"),
        // HelmNestedScrollView.swift
        Component("HelmNestedScrollView", "1.0.0", file: "HelmNestedScrollView.swift"),
        // HelmOverflowHint.swift
        Component("HelmOverflowHint", "1.0.0", file: "HelmOverflowHint.swift"),
        // HelmPageSidebar.swift
        Component("HelmPageSidebar", "1.0.0", file: "HelmPageSidebar.swift"),
        // HelmPlateCard.swift
        Component("HelmPlateCard", "1.0.0", file: "HelmPlateCard.swift"),
        // HelmRevealableSecretField.swift
        Component("HelmRevealableSecretField", "1.0.0", file: "HelmRevealableSecretField.swift"),
        // HelmScrollMemory.swift
        Component("HelmScrollMemory", "1.0.0", file: "HelmScrollMemory.swift"),
        // HelmSkeleton.swift
        Component("HelmSkeletonList", "1.0.0", file: "HelmSkeleton.swift"),
        Component("HelmSkeletonRow", "1.0.0", file: "HelmSkeleton.swift"),
        // HelmSplitButton.swift
        Component("HelmSplitButton", "1.0.0", file: "HelmSplitButton.swift"),
        // HelmSplitPage.swift
        Component("HelmHitTransparentView", "1.0.0", file: "HelmSplitPage.swift"),
        Component("HelmSplitPage", "1.0.0", file: "HelmSplitPage.swift"),
        Component("HelmSplitPageHosting", "1.0.0", file: "HelmSplitPage.swift"),
        // HelmSymbol.swift
        Component("HelmSymbol", "1.0.0", file: "HelmSymbol.swift"),
        // HelmTextScale.swift
        Component("HelmTextScale", "1.0.0", file: "HelmTextScale.swift"),
        // HelmTheme.swift
        Component("HelmTerminalCard", "1.0.0", file: "HelmTheme.swift"),
        Component("HelmTheme", "1.0.0", file: "HelmTheme.swift"),
        // HelmUIComponents.swift
        Component("HelmComposerCard", "1.0.0", file: "HelmUIComponents.swift"),
        Component("HelmContrast", "1.1.0", file: "HelmUIComponents.swift"),
        Component("HelmGestureArbitration", "1.0.0", file: "HelmUIComponents.swift"),
        Component("HelmRefreshPill", "1.0.0", file: "HelmUIComponents.swift"),
        Component("HelmSignalDot", "1.0.0", file: "HelmUIComponents.swift"),
        Component("HelmTableView", "1.0.0", file: "HelmUIComponents.swift"),
        Component("HelmTint", "1.0.0", file: "HelmUIComponents.swift"),
        // HelmZoomStepper.swift
        Component("HelmZoomStepper", "1.0.0", file: "HelmZoomStepper.swift"),
    ]

    /// App-level views the proposals version alongside the kit. Not hashed;
    /// see the file header.
    static let surfaces: [Component] = [
        Component("Home Health card", "1.0.1", file: "HomeCanvasController.swift"),
        Component("MorningBriefingCard", "1.0.1", file: "MorningBriefingCard.swift"),
        Component("StateVocabulary", "1.1.0", file: "StateVocabulary.swift"),
        Component("Tasks board (page)", "1.0.0", file: "ShiftBoardViews.swift"),
        Component("WorkspaceToolbar", "1.0.0", file: "WorkspaceToolbar.swift"),
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
        SourceDigest(file: "HelmBackgroundReload.swift", stamp: "HelmBackgroundReload@1.0.0,HelmParseThread@1.0.0", sha256: "9fdf57f19f0187aaaf3f29774bde5659a79547ea20b5b21eb2c71552e1621d4b"),
        SourceDigest(file: "HelmBarPanel.swift", stamp: "HelmBarPanel@1.0.0,HelmBarPanelWindow@1.0.0", sha256: "6811b25ea2dc491014342b855ce2b8eefcbd29118920f1007fafcbaf74d7c5e9"),
        SourceDigest(file: "HelmCardGrid.swift", stamp: "HelmCardGrid@1.0.0,HelmGridCardView@1.0.0", sha256: "c671a7649823f2e01e4c16e749c03461b1de084728104d8c64e27f5e90cf63e6"),
        SourceDigest(file: "HelmConfirm.swift", stamp: "HelmConfirm@1.0.0,HelmConfirmView@1.0.0", sha256: "f963808036b62ebe6d2ee5c85bc522c8c55cae7d927417525faacb79d8f389e0"),
        SourceDigest(file: "HelmDataTable.swift", stamp: "HelmDataTable@1.0.0,HelmDataTableActionsCell@1.0.0,HelmDataTableRowView@1.0.0,HelmDataTableRunDotsCell@1.0.0,HelmTagChip@1.0.0", sha256: "86d47ee1a1d1e68003ac63f882f31bd55a49fbc1a4348039729ffe907093b294"),
        SourceDigest(file: "HelmDateField.swift", stamp: "HelmDateField@1.0.0", sha256: "5f99cbfec49aa505d830385f27c038c793791c8f4f90be50896823841be934be"),
        SourceDigest(file: "HelmDaylight.swift", stamp: "HelmDomainHue@1.0.0", sha256: "4cf96b3b4987874ec79c91382329d21684cf1ce2ddc275809ad26690510f073e"),
        SourceDigest(file: "HelmDesignSystem.swift", stamp: "HelmAccentRow@1.0.0,HelmButton@1.0.0,HelmCard@1.0.0,HelmCountBadge@1.0.0,HelmEmptyState@1.0.0,HelmFocusRing@1.0.0,HelmMetrics@1.0.0,HelmPageToolbar@1.0.0,HelmPopUpButton@1.0.0,HelmResponsiveGrid@1.0.0,HelmSegmentedTabs@1.0.0,HelmStatTile@1.0.0,HelmType@1.0.0", sha256: "14b78ba80501a7369e4456d64ee431bfc193b30873481d79c83b1f4f6a5171c1"),
        SourceDigest(file: "HelmDrillHeader.swift", stamp: "HelmDrillHeader@1.0.0", sha256: "73712c9e058defa127936a03d9b47618e039e031d7713652d471db2c1a29480b"),
        SourceDigest(file: "HelmFocusVisibility.swift", stamp: "HelmFocusVisibility@1.0.0", sha256: "de4eab8dd4eac530b4f2c41fe9a9da80ae8e1665b02c9a4424df5c8dd6f9872f"),
        SourceDigest(file: "HelmForm.swift", stamp: "HelmCenteredSecureTextFieldCell@1.0.0,HelmCenteredTextFieldCell@1.0.0,HelmChipInput@1.0.0,HelmDotAccessory@1.0.0,HelmField@1.0.0,HelmFieldCard@1.0.0,HelmFieldCentering@1.0.0,HelmFormSheet@1.0.0,HelmSearchField@1.0.0,HelmSecureTextField@1.0.0,HelmTextField@1.0.0,HelmTextView@1.0.0,HelmToggle@1.0.0,HelmToggleRow@1.0.0", sha256: "fd963300a638f252103670c0759a6ec0949c589421a171f8d9311ae7b1a1b366"),
        SourceDigest(file: "HelmGradientTile.swift", stamp: "HelmGradientTile@1.0.0", sha256: "b2ec10777e795afde1a07241b6f9991c3fe12616c1b293e63e45dc22bc65f517"),
        SourceDigest(file: "HelmInput.swift", stamp: "HelmFocusRegistration@1.0.0,HelmFocusSensing@1.0.0,HelmInputSurface@1.0.0,HelmSelection@1.0.0", sha256: "97a99026d76c07e5e4d2a8514a53c657c5d97d5f4c8b980d68a6c4931aa1ce20"),
        SourceDigest(file: "HelmKeyHint.swift", stamp: "HelmKeyHint@1.0.0", sha256: "fc81e10be20a16c5bc8fa0074639fbbbe4b9abc73f82cadb6e647c75c703b854"),
        SourceDigest(file: "HelmKeyedRows.swift", stamp: "HelmKeyedRows@1.0.0", sha256: "ee6de57defc5a7b90e58a48918aea4d7eea383521f54782b6cc39600feced94c"),
        SourceDigest(file: "HelmKit.swift", stamp: "HelmFlatList@1.0.0,HelmKPIStrip@1.0.0,HelmKeyboardListView@1.0.0,HelmListNavigation@1.0.0,HelmOverflowMenu@1.0.0,HelmReading@1.0.0,HelmRelativeTime@1.0.0,HelmSectionHeader@1.0.0,HelmStatusPill@1.0.0", sha256: "d3fd1cca207223d3db7c65489b95a9d6dc878744daa7f2ab700b80d4419ec009"),
        SourceDigest(file: "HelmListMotion.swift", stamp: "HelmRowEntrance@1.0.0,HelmRowWash@1.0.0,HelmScrollEdgeHairline@1.0.0", sha256: "b61272f6eb12d0e43b75f5aa8b13a5013af1bb8fe0d341e66fc59cca707ac7df"),
        SourceDigest(file: "HelmMetricCard.swift", stamp: "HelmMetricCard@1.0.0,HelmMetricRow@1.0.0", sha256: "a8fd44422f7072c8e3a98718dd1ef1a3f9045fb3c6a462ddc7411222ae76e91c"),
        SourceDigest(file: "HelmModuleCard.swift", stamp: "HelmDaylightPriority@1.0.0,HelmModuleCard@1.1.0,HelmModuleChip@1.0.0,HelmModulePeekRow@1.0.0,HelmModuleRowState@1.0.0,HelmModuleUsageRow@1.0.0,HelmModuleUsageSection@1.0.0,HelmModuleUsageSpend@1.0.0,HelmModuleUsageStatus@1.0.0,HelmProgressBar@1.0.0,HelmRingGauge@1.1.0", sha256: "99a5ce447d7516f93bf87320fa257d921402797950d3114d1bdcedd7dc95b80d"),
        SourceDigest(file: "HelmMotion.swift", stamp: "HelmDisplayAccessibility@1.0.0,HelmMotion@1.0.0", sha256: "d4c8c1bfa26b3f14604b271d024f5e4445656c3989364b80cf9dc29dc058173b"),
        SourceDigest(file: "HelmNestedScrollView.swift", stamp: "HelmNestedScrollView@1.0.0", sha256: "f7f7f1af0345d92201f8d86b3a02625e31e887258cb7ca078a2c978c8fbf2ede"),
        SourceDigest(file: "HelmOverflowHint.swift", stamp: "HelmOverflowHint@1.0.0", sha256: "5ad0c7b7fcd180a18f38e1f0de119b44a752bc3dd93990b7ce3b1d68759233f6"),
        SourceDigest(file: "HelmPageSidebar.swift", stamp: "HelmPageSidebar@1.0.0", sha256: "04672c8da6d392b2aef7a9b37d3de5a2623462befa58d0c0f6db9c2f9f684471"),
        SourceDigest(file: "HelmPlateCard.swift", stamp: "HelmPlateCard@1.0.0", sha256: "77e307fead14f0fafc6c13611c4e17945a3d1a8ecbc82b8aabcb6ab6789db0d3"),
        SourceDigest(file: "HelmRevealableSecretField.swift", stamp: "HelmRevealableSecretField@1.0.0", sha256: "0c7ef5b228b5bb38c51c646e74d1985cb220e26998251f86f7b1fe3845d65398"),
        SourceDigest(file: "HelmScrollMemory.swift", stamp: "HelmScrollMemory@1.0.0", sha256: "462b598c2a7fe6105bb84271f16a5829fd8ae1fd5c5f221b2a02801c066f18a2"),
        SourceDigest(file: "HelmSkeleton.swift", stamp: "HelmSkeletonList@1.0.0,HelmSkeletonRow@1.0.0", sha256: "5029ae0b4e7848a80497823bb348affbabd0f9883aabbf2ddcc6a1d556f61a48"),
        SourceDigest(file: "HelmSplitButton.swift", stamp: "HelmSplitButton@1.0.0", sha256: "f9ba58abda9751dfeabe1ba021f9da70077f2a4ffc845900b79f9d1ef36b769b"),
        SourceDigest(file: "HelmSplitPage.swift", stamp: "HelmHitTransparentView@1.0.0,HelmSplitPage@1.0.0,HelmSplitPageHosting@1.0.0", sha256: "a621d2e98201039ec707076fb6470ec688a6e61a36b631a1973d3b0ee191fdd8"),
        SourceDigest(file: "HelmSymbol.swift", stamp: "HelmSymbol@1.0.0", sha256: "91d848c2e8fe1ad21104944c2e0714a3ebfb0880f5850324c4cc5d9c18cc3f54"),
        SourceDigest(file: "HelmTextScale.swift", stamp: "HelmTextScale@1.0.0", sha256: "beffe9873d7dd7464ddbfecf30779b3b3c5bd5055bc5becfa385d9a2ca44f4f4"),
        SourceDigest(file: "HelmTheme.swift", stamp: "HelmTerminalCard@1.0.0,HelmTheme@1.0.0", sha256: "aeb5c35527f4ef0d337751ac64656b6277d8dae167eea1b074d71caf0bc1158e"),
        SourceDigest(file: "HelmUIComponents.swift", stamp: "HelmComposerCard@1.0.0,HelmContrast@1.1.0,HelmGestureArbitration@1.0.0,HelmRefreshPill@1.0.0,HelmSignalDot@1.0.0,HelmTableView@1.0.0,HelmTint@1.0.0", sha256: "561d0b12cf27472f75561ac8a32be00ac179c77b9c65db0a755c902bf5f1d0f4"),
        SourceDigest(file: "HelmZoomStepper.swift", stamp: "HelmZoomStepper@1.0.0", sha256: "c5700730b36166ba03d1ebd484c91c7d87b8b141dfdc973f4244c4481cb8bd80"),
    ]
}
