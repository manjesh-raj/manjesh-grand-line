// Manjesh Grand Line - native macOS app.
//
// F11: the New/Edit Schedule sheet behind the Automation page's "+ New
// Schedule" button.
//
// Four choices and nothing else: which already-existing action, how often, at
// what time, and when it is worth telling the captain. Built on the shared form
// scaffold (`HelmForm.swift`, Phase 6 of the UI audit) like the other seven
// editor sheets, so it inherits the sheet background, the forced appearance and
// the single `ThemeManager` observation rather than hand-rolling all three -
// which is what three of the six original editors got wrong.
//
// The action picker is deliberately the *only* way to name an action, and it is
// populated from `ScheduledActionKind.allCases`. There is no free-text command
// field anywhere in this sheet, which is what makes F11's security bar ("only
// ever schedules actions that exist today") true by construction rather than by
// review: a schedule cannot name anything this app did not already ship.

import AppKit

final class ScheduleEditorController: NSViewController {

    private let editing: AutomationSchedule?

    /// Called with the assembled schedule on Save. The caller persists it.
    var onSave: ((AutomationSchedule) -> Void)?
    /// Called with the schedule id on Delete (only offered when editing).
    var onDelete: ((UUID) -> Void)?

    // MARK: Working state
    //
    // The sheet edits a value copy and only hands it back on Save, so Cancel
    // is genuinely a no-op on the store.

    private var action: ScheduledActionKind
    private var isWeekly: Bool
    private var weekday: Int
    private var notifyOn: ScheduleNotifyOn

    // MARK: Controls

    private let actionCard = HelmFieldCard(label: "Action")
    private let cadenceCard = HelmFieldCard(label: "Repeats")
    private let weekdayCard = HelmFieldCard(label: "Day")
    private let notifyCard = HelmFieldCard(label: "Notify me")
    private let timePicker = NSDatePicker()
    private var explanationLabel: NSTextField!
    private var remoteWriteCard: NSView?
    private var form: HelmFormSheet!

    init(schedule: AutomationSchedule?) {
        self.editing = schedule
        let initial = schedule ?? AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 2, minute: 0))
        self.action = initial.action
        self.notifyOn = initial.notifyOn
        switch initial.cadence.normalized {
        case .daily:
            self.isWeekly = false
            self.weekday = 1
        case .weekly(let wd, _, _):
            self.isWeekly = true
            self.weekday = wd
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let form = HelmFormSheet(title: editing == nil ? "New Schedule" : "Edit Schedule",
                                 domainHue: RailDestination.schedules.domainHue)
        self.form = form
        view = form

        // MARK: Action

        form.addSection("What runs")
        actionCard.configureChoices(
            ScheduledActionKind.allCases.map { $0.pickerTitle },
            selectedIndex: ScheduledActionKind.allCases.firstIndex(of: action) ?? 0
        ) { [weak self] index in
            guard let self, ScheduledActionKind.allCases.indices.contains(index) else { return }
            self.action = ScheduledActionKind.allCases[index]
            self.refreshForAction()
        }
        form.addRow(actionCard)

        // Says exactly what the chosen action will do, unattended. An action
        // that pushes to a remote should never be a bare name in a picker.
        explanationLabel = form.addCaption(action.explanation)

        // MARK: Cadence

        form.addSection("When")
        cadenceCard.configureChoices(["Daily", "Weekly"], selectedIndex: isWeekly ? 1 : 0) { [weak self] index in
            guard let self else { return }
            self.isWeekly = index == 1
            self.weekdayCard.isHidden = !self.isWeekly
        }

        weekdayCard.configureChoices(
            Array(ScheduleCadence.weekdayNames.dropFirst()),
            selectedIndex: max(0, min(6, weekday - 1))
        ) { [weak self] index in
            self?.weekday = index + 1
        }
        weekdayCard.isHidden = !isWeekly

        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = [.hourMinute]
        timePicker.dateValue = Self.date(hour: (editing?.cadence.hour) ?? 2,
                                        minute: (editing?.cadence.minute) ?? 0)
        timePicker.translatesAutoresizingMaskIntoConstraints = false

        form.addColumns([cadenceCard, weekdayCard])
        form.addField("At", timePicker)

        // MARK: Notify

        form.addSection("Notify")
        notifyCard.configureChoices(
            ScheduleNotifyOn.allCases.map { $0.pickerTitle(for: action) },
            selectedIndex: ScheduleNotifyOn.allCases.firstIndex(of: notifyOn) ?? 0
        ) { [weak self] index in
            guard let self, ScheduleNotifyOn.allCases.indices.contains(index) else { return }
            self.notifyOn = ScheduleNotifyOn.allCases[index]
        }
        form.addRow(notifyCard)
        form.addCaption(
            "Every run is recorded on the Health page whichever of these you pick. "
            + "This only decides when a run also raises a notification."
        )

        remoteWriteCard = form.addInfoCard(
            symbol: "arrow.up.circle",
            text: "This action pushes to GitHub on its own, with no confirmation at the time. "
                + "It is the same push the button on its own page performs \u{2014} never a force-push, "
                + "and a diverged repository is always left alone."
        )
        remoteWriteCard?.isHidden = !action.writesRemotely

        form.setFooter(target: self,
                       confirmTitle: editing == nil ? "Create Schedule" : "Save",
                       confirm: #selector(save),
                       cancel: #selector(cancel),
                       delete: editing == nil ? nil : (title: "Delete", action: #selector(deleteSchedule)))

        // `ThemeManager.observe` fires synchronously at registration, which for
        // a scaffold is before any row exists - so the first firing always
        // finds empty registries and every editor here ends `loadView` this
        // way. See `HelmFormSheet.refreshTheme`.
        form.setSubtitle("Runs on its own and reports to Health.")
        form.refreshTheme()
        form.sizeToFitContent()
    }

    /// The action picker drives three other things: the explanation, the
    /// notify labels (`.changeOnly` reads "Only on drift" for one action and
    /// "Only on updates available" for another), and whether the
    /// pushes-to-GitHub note is shown.
    private func refreshForAction() {
        explanationLabel?.stringValue = action.explanation
        notifyCard.configureChoices(
            ScheduleNotifyOn.allCases.map { $0.pickerTitle(for: action) },
            selectedIndex: ScheduleNotifyOn.allCases.firstIndex(of: notifyOn) ?? 0
        ) { [weak self] index in
            guard let self, ScheduleNotifyOn.allCases.indices.contains(index) else { return }
            self.notifyOn = ScheduleNotifyOn.allCases[index]
        }
        remoteWriteCard?.isHidden = !action.writesRemotely
        form?.refreshTheme()
        form?.sizeToFitContent()
    }

    private static func date(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    private var chosenCadence: ScheduleCadence {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        let hour = comps.hour ?? 2
        let minute = comps.minute ?? 0
        return isWeekly
            ? .weekly(weekday: weekday, hour: hour, minute: minute)
            : .daily(hour: hour, minute: minute)
    }

    @objc private func save() {
        var schedule = editing ?? AutomationSchedule(action: action, cadence: chosenCadence)
        schedule.action = action
        schedule.cadence = chosenCadence
        schedule.notifyOn = notifyOn
        onSave?(schedule)
        dismiss(self)
    }

    @objc private func deleteSchedule() {
        guard let id = editing?.id else { return }
        onDelete?(id)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }
}
