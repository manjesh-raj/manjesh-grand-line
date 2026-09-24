// Grand Line - native macOS app.
//
// The New/Edit Snippet sheet (design report Section B2, Section D Phase 3):
// just a Label and a command text box - deliberately as small as the Termius
// snippet form gets, since the whole point is a fast save-and-run loop.
//
// Phase 6 of the full-app UI audit moved it onto the shared form scaffold
// (`HelmForm.swift`). It was the most system-chrome-dependent of the six
// editors - a 180x326 sheet whose only controls were a stock bezeled field and
// an `NSScrollView` wearing AppKit's own `.bezelBorder` frame.
//
// F12 added the expander's three fields - the `;abbrev` trigger, where it may
// fire, and the apps it must stay out of - and the placeholder caption. The
// original field set, its validation and its Delete action are unchanged; the
// trigger is optional, so the fast save-and-run loop this sheet was built for
// is still two fields and Return.

import AppKit

final class SnippetEditorController: NSViewController {

    private let editing: Snippet?
    /// Every other snippet, for the duplicate-trigger check. Two snippets
    /// answering to one trigger is not a thing the expander can resolve
    /// sensibly at typing time, so it is refused at save time instead.
    private let existingSnippets: [Snippet]

    /// Called with the assembled snippet on Save. The caller persists it.
    var onSave: ((Snippet) -> Void)?
    /// Called with the snippet id on Delete (only offered when editing).
    var onDelete: ((UUID) -> Void)?

    private let labelField = HelmTextField(placeholder: "Name this snippet", style: .lead)
    private let commandView = HelmTextView(height: 130, monospaced: true)
    private let triggerField = HelmTextField(placeholder: "sig")
    private let scopePopUp = HelmPopUpButton()
    private let excludedInput = HelmChipInput(placeholder: "App name or bundle id, then Return")

    init(snippet: Snippet?, existingSnippets: [Snippet] = []) {
        self.editing = snippet
        self.existingSnippets = existingSnippets
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let form = HelmFormSheet(title: editing == nil ? "New Snippet" : "Edit Snippet",
                                 domainHue: RailDestination.hosts.domainHue)
        view = form

        labelField.stringValue = editing?.label ?? ""
        form.addLead(labelField)

        form.addSection("Expansion")
        commandView.string = editing?.command ?? ""
        form.addRow(commandView)
        form.addCaption(
            "\u{201c}Run\u{201d} sends this text, then Enter, to the active terminal tab. "
            + "A snippet can also be set as a host's startup snippet in the host editor."
        )
        form.addCaption("Placeholders: " + SnippetPlaceholder.allCases
            .map { "\($0.rawValue) (\($0.help))" }
            .joined(separator: ", ") + ".")

        form.addSection("Trigger")
        triggerField.stringValue = editing?.normalizedTrigger ?? ""
        form.addField("\(SnippetTrigger.prefix)", triggerField)
        for scope in SnippetScope.allCases { scopePopUp.addItem(withTitle: scope.title) }
        scopePopUp.selectItem(at: SnippetScope.allCases.firstIndex(of: editing?.scope ?? .consoleOnly) ?? 0)
        form.addField("Where", scopePopUp)
        excludedInput.setTokens(editing?.excludedApps ?? [])
        form.addField("Never in", excludedInput)
        form.addCaption(
            "Type \(SnippetTrigger.prefix)trigger followed by a space or punctuation and it is replaced "
            + "in place. It only fires at the start of a word, so foo\(SnippetTrigger.prefix)trigger is "
            + "left alone, and \(SnippetTrigger.prefix)\(SnippetTrigger.prefix)trigger types it literally. "
            + "Leave this empty for a snippet you only ever run from the list."
        )

        form.setFooter(target: self,
                       confirmTitle: "Save",
                       confirm: #selector(save),
                       cancel: #selector(cancel),
                       delete: editing == nil ? nil : (title: "Delete", action: #selector(deleteSnippet)))

        form.setSubtitle("Sends its text into the active terminal tab, or expands where you type.")
        form.refreshTheme()
        form.sizeToFitContent()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(labelField)
    }

    /// Why this snippet cannot be saved as typed, or `nil`. Split out from
    /// `save()` so the suite asserts the rules rather than the beep.
    func validationFailure() -> String? {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { return "A snippet needs a name." }
        if commandView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A snippet needs some text to expand."
        }
        let trigger = SnippetTrigger.normalize(triggerField.stringValue)
        guard !trigger.isEmpty else { return nil }
        if let rejection = SnippetTrigger.rejection(for: trigger) { return rejection }
        if let clash = SnippetTriggerTable.existingSnippet(withTrigger: trigger,
                                                           in: existingSnippets,
                                                           excluding: editing?.id) {
            return "\(SnippetTrigger.display(trigger)) is already \u{201c}\(clash.label)\u{201d}."
        }
        return nil
    }

    @objc private func save() {
        excludedInput.commitPendingText()
        guard validationFailure() == nil else {
            let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                view.window?.makeFirstResponder(labelField)
            } else if commandView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                view.window?.makeFirstResponder(commandView.textView)
            } else {
                view.window?.makeFirstResponder(triggerField)
            }
            NSSound.beep()
            return
        }
        var snippet = editing ?? Snippet(label: "", command: "")
        snippet.label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.command = commandView.string
        snippet.trigger = SnippetTrigger.normalize(triggerField.stringValue)
        let index = scopePopUp.indexOfSelectedItem
        snippet.scope = SnippetScope.allCases.indices.contains(index)
            ? SnippetScope.allCases[index] : .consoleOnly
        snippet.excludedApps = excludedInput.tokens
        onSave?(snippet)
        dismiss(self)
    }

    @objc private func deleteSnippet() {
        guard let id = editing?.id else { return }
        onDelete?(id)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }

    #if FM_SELFTESTS
    var debugLabelField: HelmTextField { labelField }
    var debugCommandView: HelmTextView { commandView }
    var debugTriggerField: HelmTextField { triggerField }
    var debugScopePopUp: HelmPopUpButton { scopePopUp }
    var debugExcludedInput: HelmChipInput { excludedInput }
    /// Drives the real `save()` - so a suite asserts the assembled snippet the
    /// captain would get, not a reimplementation of it.
    func debugSave() { save() }
    #endif
}
