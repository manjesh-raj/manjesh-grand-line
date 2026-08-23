// Manjesh Grand Line - native macOS app.
//
// F3: the "App" card at the top of the Updates page - this app's own row on
// the page that checks every other tool the captain runs.
//
// It is a separate card above the tool categories rather than a row inside
// one, for two reasons. It is not a `DependencyItem` (no catalog entry, no
// `UpdatesSource` check, a completely different source and action), and
// wedging it into the catalog would mean either a fake entry the software
// checklist on the Bootstrap page would also pick up, or a special case in
// every loop over `DependencyCatalog.items`. And it genuinely is the page's
// most important row: it is the only thing on the page the captain cannot
// update any other way.
//
// Three states, and the middle one is the point:
//
//   - up to date / nothing released yet / couldn't check - status only.
//   - an update is available and this build can verify a download: an
//     Update button that downloads, verifies, swaps and relaunches.
//   - an update is available and this build *cannot* verify a download
//     (today's state - no Developer ID yet, see `AppUpdateInstaller`'s
//     header): a "Release notes" button that opens the release page, and a
//     detail line saying plainly why in-place installing is off. Not a
//     disabled Update button with no explanation, and definitely not an
//     Update button that installs something unverified.
//
// A `swift run` binary has no bundle to replace and says so instead of
// offering an action that cannot work.

import AppKit

extension UpdatesController {

    // MARK: Building

    func buildAppCard() -> HelmCard {
        appRow.checkButton.target = self
        appRow.checkButton.action = #selector(checkAppUpdateTapped)
        appRow.actionButton.target = self
        appRow.actionButton.action = #selector(appUpdateActionTapped)
        appRow.actionButton.isHidden = true

        appRow.spinner.style = .spinning
        appRow.spinner.controlSize = .small
        appRow.spinner.isIndeterminate = true
        appRow.spinner.translatesAutoresizingMaskIntoConstraints = false
        appRow.spinner.isHidden = true
        appRow.progressLabel.font = .systemFont(ofSize: 11, weight: .medium)
        appRow.progressLabel.isHidden = true

        let row = ToolRowLayout.build(
            appRow.toolRowViews,
            iconSymbol: "sailboat",
            tint: .accent,
            name: "Manjesh Grand Line",
            statusViews: [appRow.pill, appRow.spinner, appRow.progressLabel],
            trailingViews: [appRow.checkButton, appRow.actionButton],
            identifier: Self.appRowIdentifier,
            showDetails: false
        )
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = HelmCard()
        card.setHeader(symbol: "shippingbox.and.arrow.backward",
                       tint: .accent,
                       title: "App",
                       subtitle: "This app updates every tool on the machine; this row is the one that updates the app.")
        card.setBody(row, insets: HelmCard.contentInsets)
        registerAppCard(card)
        return card
    }

    // MARK: Check

    @objc func checkAppUpdateTapped() { checkAppUpdate() }

    /// Runs the release check off the main thread and re-renders. Called from
    /// the row's own button and once from `checkAll()`, so the App row
    /// refreshes with everything else rather than needing its own visit.
    func checkAppUpdate() {
        guard !appRow.isBusy else { return }
        appRow.isBusy = true
        appRow.detail = "Checking for a newer release\u{2026}"
        renderAppRow()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = AppUpdateSource.check()
            DispatchQueue.main.async {
                guard let self else { return }
                self.appRow.isBusy = false
                self.appRow.status = status
                self.renderAppRow()
            }
        }
    }

    // MARK: Action

    @objc func appUpdateActionTapped() {
        switch appRow.status {
        case .updateAvailable(_, let release):
            // Only reachable when `AppUpdateInstaller.canInstall` - see
            // `renderAppRow`, which shows the release-notes action instead
            // otherwise.
            guard AppUpdateInstaller.canInstall else {
                NSWorkspace.shared.open(release.htmlURL)
                return
            }
            confirmAndInstall(release)
        case .updateAvailableWithoutArtifact(_, let release):
            NSWorkspace.shared.open(release.htmlURL)
        default:
            NSWorkspace.shared.open(AppUpdateSource.releasesPageURL)
        }
    }

    /// An app replacing itself and quitting is exactly the kind of
    /// hard-to-reverse, outward-facing action this app confirms first
    /// (`PRODUCT.md`'s own bar, and the same treatment host/key deletes get).
    private func confirmAndInstall(_ release: AppRelease) {
        let alert = NSAlert()
        alert.messageText = "Update to \(release.tag)?"
        alert.informativeText = "Manjesh Grand Line will download the release, verify its signature, replace itself and relaunch. Any unsaved work in an open editor sheet will be lost."
        alert.addButton(withTitle: "Update and Relaunch")
        alert.addButton(withTitle: "Cancel")
        // `runModal`, like every other confirm in this app (host delete,
        // key delete) - a sheet's asynchronous completion would let this
        // method return before the captain has answered.
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        appRow.isBusy = true
        appRow.detail = "Starting\u{2026}"
        renderAppRow()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = AppUpdateInstaller.install(release) { message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.appRow.detail = message
                    self.renderAppRow()
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.appRow.isBusy = false
                switch outcome {
                case .installedPendingRelaunch:
                    self.appRow.detail = "Installed - relaunching\u{2026}"
                    self.renderAppRow()
                    AppLog.lifecycle.info("app update installed; terminating for relaunch")
                    NSApp.terminate(nil)
                case .refusedUnverified(let reason):
                    self.appRow.installFailure = reason
                    self.renderAppRow()
                case .failed(let reason):
                    self.appRow.installFailure = reason
                    self.renderAppRow()
                }
            }
        }
    }

    // MARK: Render

    func renderAppRow() {
        let views = appRow.toolRowViews
        var pillText = "Unknown"
        var pillHex = theme.chromeLineHex
        var detail = appRow.detail
        var actionTitle: String?
        var showAction = false
        var detailIsFailure = false

        if appRow.isBusy {
            views.pill.isHidden = true
            appRow.spinner.isHidden = false
            appRow.spinner.startAnimation(nil)
            appRow.progressLabel.isHidden = false
            appRow.progressLabel.stringValue = "Working\u{2026}"
            appRow.checkButton.isEnabled = false
            appRow.actionButton.isEnabled = false
        } else {
            appRow.spinner.stopAnimation(nil)
            appRow.spinner.isHidden = true
            appRow.progressLabel.isHidden = true
            views.pill.isHidden = false
            appRow.checkButton.isEnabled = true
            appRow.actionButton.isEnabled = true

            switch appRow.status {
            case .notBundled:
                pillText = "Dev Build"
                pillHex = theme.chromeLineHex
                detail = "Running from \u{201C}swift build\u{201D}, not an installed app - nothing here to update."
            case .checkFailed(let reason):
                pillText = "Check Failed"
                pillHex = theme.ansiHex[1]
                detail = reason
                detailIsFailure = true
                actionTitle = "Open Releases"
                showAction = true
            case .noReleaseYet(let current):
                pillText = "Unreleased"
                pillHex = theme.chromeLineHex
                detail = "\(AppVersion.build) - no release has been published yet (current \(current))."
                actionTitle = "Open Releases"
                showAction = true
            case .upToDate(_, let latest):
                pillText = "Up to Date"
                pillHex = theme.ansiHex[2]
                detail = "\(AppVersion.build) - latest release is \(latest)."
            case .updateAvailableWithoutArtifact(_, let release):
                pillText = "Update Available"
                pillHex = theme.ansiHex[3]
                detail = "\(release.tag) is published, but that release has no downloadable build attached."
                actionTitle = "Release Notes"
                showAction = true
            case .updateAvailable(_, let release):
                pillText = "Update Available"
                pillHex = theme.ansiHex[3]
                if AppUpdateInstaller.canInstall {
                    detail = "\(AppVersion.build) \u{2192} \(release.tag)"
                    actionTitle = "Update and Relaunch"
                } else {
                    detail = "\(release.tag) is available. \(AppUpdateInstaller.verificationUnavailableReason)"
                    actionTitle = "Release Notes"
                }
                showAction = true
            }

            if let failure = appRow.installFailure {
                detail = failure
                detailIsFailure = true
            }
        }

        if let actionTitle {
            appRow.actionButton.title = actionTitle
            appRow.actionButton.variant = actionTitle == "Update and Relaunch" ? .primary : .secondary
        }
        appRow.actionButton.isHidden = !showAction || appRow.isBusy

        ToolRowLayout.pill(text: pillText, colorHex: pillHex, into: views.pill, label: views.pillLabel, theme: theme)
        views.detailLabel.stringValue = detail
        ToolRowLayout.applyTheme(views, theme: theme, detailFailed: detailIsFailure)
    }
}

/// The App row's own mutable state - deliberately not an `UpdateRow`, which
/// is built around a `DependencyItem` this row does not have.
final class AppUpdateRowState {
    var status: AppUpdateStatus = .checkFailed("Not checked yet")
    var detail: String = "Not checked yet"
    var isBusy = false
    /// Set when an install attempt was refused or failed, so the reason
    /// survives on the row instead of vanishing into a toast.
    var installFailure: String?

    let iconTile = IconTileView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let pill = NSView()
    let pillLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "Working\u{2026}")
    let checkButton = HelmButton(title: "Check", variant: .secondary, size: .small)
    let actionButton = HelmButton(title: "Release Notes", variant: .secondary, size: .small)
    let detailsButton = NSButton()
    let logField = NSTextField(wrappingLabelWithString: "")
    let logContainer = NSView()
    let rowContainer = HoverHighlightView()
    let trailingStack = NSStackView()

    var toolRowViews: ToolRowLayout.Views {
        ToolRowLayout.Views(
            iconTile: iconTile, nameLabel: nameLabel, detailLabel: detailLabel,
            pill: pill, pillLabel: pillLabel, trailingStack: trailingStack,
            detailsButton: detailsButton, logField: logField, logContainer: logContainer,
            rowContainer: rowContainer
        )
    }
}
