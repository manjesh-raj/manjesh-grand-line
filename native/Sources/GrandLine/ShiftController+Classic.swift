// Grand Line - native macOS app.
//
// `ShiftController`'s floating-bar presentation (R2-ARCH-04): the page's own second column - Workspace, Projects and Smart views - which the sidebar layout collapses and carries on its filter row instead (stage 7).
//
// The floating bar is the classic layout, frozen by R2-ARCH-01: it gets
// fixes but no new features and no page redesigns. So the members only its
// presentation uses live here, moved verbatim out of `ShiftController.swift`, and
// that file carries the presentation the sidebar layout draws. A member both
// layouts use stays there. Swift's `private` is file-scoped, so the few
// members this file and the main one share lost `private`; treat this pair
// as one type's private parts (GL-36). `ClassicPresentationSelfTest` fails if
// one of these members moves back.

import AppKit

extension ShiftController {

    func buildSidebar() {
        rebuildSidebarSections(projects: store.projects)
        sidebar.setFooter(links: [
            .init(id: Self.settingsRowID, title: "Settings"),
            .init(id: Self.shortcutsRowID, title: "Shortcuts"),
        ])

        // The column's one badge: Follow-ups, while any are waiting.
        sidebar.attentionCountRowIDs = [Self.followUpsRowID]
        sidebar.onSelect = { [weak self] id in
            guard let self else { return }
            if let scope = ShiftTaskScope(rawValue: id) {
                self.taskScope = scope
                self.render()
                return
            }
            if id.hasPrefix(Self.projectRowPrefix) {
                self.pickProjectFromSidebar(String(id.dropFirst(Self.projectRowPrefix.count)))
                return
            }
            switch id {
            case Self.settingsRowID:
                self.onNavigateToDestination?(.settings)
                return
            case Self.shortcutsRowID:
                self.onOpenCommandPalette?()
                return
            default:
                break
            }
            // An action row from Weekly Review has to take the captain back to
            // the board first - the panel it scrolls to is not on that view.
            if self.topLevelView != .dashboard { self.switchTopLevelView(.dashboard) }
            switch id {
            case Self.followUpsRowID: self.scrollToPanel(self.followUpPanel)
            default: break
            }
        }
    }

    /// The column's three groups, rebuilt from the live project list.
    ///
    /// **The Projects group is the whole point of this column's redesign.**
    /// Before it the sidebar collapsed every project into one "Projects 5"
    /// count row, so the one place a captain would look to see *which*
    /// projects exist showed a number instead - the projects were already
    /// modelled (`ShiftStore.projects`) and already listed individually by the
    /// board's own filter chips; nothing iterated them into nav rows.
    ///
    /// Each row's dot takes `ShiftProjectPalette.tint(forProjectID:)`, the
    /// same stable per-project hue the board cards' accent bars and the filter
    /// chips already paint, so one project is one colour everywhere.
    func rebuildSidebarSections(projects: [ShiftProject]) {
        sidebar.setSections([
            .init(header: "Workspace", rows:
                ShiftTaskScope.workspaceCases.map {
                    .init(id: $0.rawValue, indicator: .symbol($0.symbol), title: $0.title)
                }
                // Follow-ups scrolls to a panel rather than filtering, so it is
                // an `.action` row and never takes the selection.
                + [.init(id: Self.followUpsRowID, indicator: .symbol("bell"),
                         title: "Follow-ups", kind: .action)]),
            .init(header: "Projects", rows: projects.map { project in
                .init(id: Self.projectRowID(project.id),
                      indicator: .dot(ShiftProjectPalette.tint(forProjectID: project.id)),
                      title: project.name.isEmpty ? "Untitled project" : project.name,
                      group: Self.projectGroup,
                      showsCount: false)
            }),
            .init(header: "Smart views", rows: ShiftTaskScope.smartViewCases.map {
                .init(id: $0.rawValue, indicator: .symbol($0.symbol), title: $0.title,
                      showsCount: false)
            }),
        ])
        sidebarProjectSignature = Self.projectSignature(projects)
    }

    /// One filter, two controls. Clicking the already-selected project clears
    /// it, matching the chip row's own toggle, and the chip row is moved to
    /// match rather than being left showing something else.
    private func pickProjectFromSidebar(_ projectID: String) {
        projectFilter = projectFilter == projectID ? nil : projectID
        if topLevelView != .dashboard { switchTopLevelView(.dashboard) }
        render()
    }
}
