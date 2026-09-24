// Grand Line - native macOS app.
//
// One masked-with-reveal field, for every editable secret this app asks the
// captain to type or paste.
//
// This is the component index's rule applied to a pattern that had exactly one
// implementation and was about to get a second: the credential editor's Secret
// row (a `HelmSecureTextField`, a `HelmTextField` and a Show/Hide toggle kept
// in step by hand) and the Settings page's two Google OAuth fields want the
// same control, so there is one control.
//
// Three things about the shape are load-bearing, and all three were already
// true of the credential editor's hand-rolled version:
//
//   * **Exactly one of the two fields is in layout at a time.** An
//     `NSStackView` drops a hidden arranged subview out of layout entirely, so
//     the row's height and the button's position do not move across a toggle.
//     A single `NSTextField` whose cell is swapped between secure and plain
//     would be one view rather than two, but `NSSecureTextFieldCell` is what
//     actually does the masking and swapping a live cell out from under a
//     field being edited loses the field editor - see `HelmForm.swift`'s own
//     note on the centred-cell replacement, which only ever runs at build time.
//   * **Both fields carry the same text at all times.** The toggle copies
//     before it swaps, so a commit fired *by* the toggle (moving the first
//     responder ends editing on the outgoing field, which is what
//     `controlTextDidEndEditing` hangs off) reads the same value whichever
//     field the delegate happens to see. That is why `stringValue`'s setter
//     writes both and its getter may read either.
//   * **Masking is a display concern and nothing else.** This view owns no
//     store, no `Keychain` item and no commit path. A host wires
//     `target`/`action`/`delegate` on `editableFields` - both of them, or the
//     commit works only in whichever state the captain was not in - and the
//     stored value is identical either way.
//
// `fm/grandline-gmail-oauth-field-not-saving` is the reason `editableFields`
// is plural and named the way it is: a field whose value is *persisted* needs
// a delegate as well as a target/action (AppKit gotcha (19)), and a masked
// field that only wired one of its two halves would reopen that same bug in
// the half nobody was looking at.

import AppKit

final class HelmRevealableSecretField: NSStackView {

    /// The masked half. Shown by default - a secret is hidden until the
    /// captain asks for it, never the other way round.
    let maskedField: HelmSecureTextField
    /// The plain half, shown only while revealed.
    let plainField: HelmTextField
    /// The Show / Hide toggle.
    let revealButton = HelmButton(title: "Show", variant: .quiet, size: .small, symbol: "eye")

    private(set) var isRevealed = false

    /// What the toggle's tooltip says while masked. Set it to name the value
    /// ("Show the client secret") where a page has more than one of these.
    var revealHint: String = "Show the value on screen" {
        didSet { applyToggleChrome() }
    }

    /// §6.9: the domain hue both wells' focus rings take, forwarded so a page
    /// that tints its fields does not have to reach through this view.
    var domainHue: HelmDomainHue? {
        didSet {
            maskedField.domainHue = domainHue
            plainField.domainHue = domainHue
        }
    }

    init(placeholder: String = "") {
        maskedField = HelmSecureTextField(placeholder: placeholder)
        plainField = HelmTextField(placeholder: placeholder)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        alignment = .centerY
        spacing = HelmMetrics.s2
        distribution = .fill
        // A stack has no intrinsic content size, so the *stack* priority APIs
        // are the ones that decide anything here - gotcha (12).
        setHuggingPriority(.required, for: .horizontal)

        addArrangedSubview(maskedField)
        addArrangedSubview(plainField)
        addArrangedSubview(revealButton)
        plainField.isHidden = true

        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        revealButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)
        applyToggleChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Value

    /// The captain's value. Reading it is safe in either state; writing it
    /// fills both halves so the state cannot change what is stored.
    var stringValue: String {
        get { isRevealed ? plainField.stringValue : maskedField.stringValue }
        set {
            maskedField.stringValue = newValue
            plainField.stringValue = newValue
        }
    }

    /// The two real text fields, for a host that wires `target`/`action` and a
    /// `delegate`. Wire **both**, per this file's header.
    var editableFields: [NSTextField] { [maskedField, plainField] }

    /// The half currently in layout - the one a click lands in, and the one a
    /// suite driving the real field editor has to reach for. A hidden field
    /// cannot become first responder, so "the field" is always this one.
    var visibleField: NSTextField { isRevealed ? plainField : maskedField }

    /// Whether `field` is one of this control's own halves - what a delegate
    /// switching on its sender asks, since the sender is a half and never
    /// this view.
    func owns(_ field: NSTextField) -> Bool {
        field === maskedField || field === plainField
    }

    /// A preferred width for the text column, below
    /// `NSLayoutPriorityWindowSizeStayPut` so it can never become a window
    /// floor (gotcha (13)). Applied to both halves, so the row does not resize
    /// when it is toggled.
    func setPreferredFieldWidth(_ width: CGFloat) {
        for field in editableFields {
            let constraint = field.widthAnchor.constraint(equalToConstant: width)
            constraint.priority = HelmDaylightPriority.contentTie
            constraint.isActive = true
        }
    }

    // MARK: Reveal

    @objc func toggleReveal() {
        setRevealed(!isRevealed)
    }

    func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        let outgoing = isRevealed ? plainField : maskedField
        let incoming = isRevealed ? maskedField : plainField
        // The outgoing half is the authority, including mid-edit: measured,
        // `NSTextField.stringValue` reads back through the live field editor
        // while a field is being edited, so this picks up text the captain
        // typed and never committed. Copying from the *incoming* half instead
        // is the bug this direction avoids - it would show the reveal's
        // reader a stale value.
        let text = outgoing.stringValue
        // Both halves before either is hidden: moving the first responder
        // below ends editing on `outgoing`, and a `controlTextDidEndEditing`
        // commit fired there must see the new text whichever half it reads.
        maskedField.stringValue = text
        plainField.stringValue = text

        let wasEditing = outgoing.currentEditor() != nil
        isRevealed = revealed
        maskedField.isHidden = revealed
        plainField.isHidden = !revealed
        applyToggleChrome()

        guard wasEditing, let window = incoming.window else { return }
        // Keep the caret where the captain left it. A hidden field cannot be
        // first responder, so this has to happen after the swap.
        window.makeFirstResponder(incoming)
        incoming.currentEditor()?.selectedRange =
            NSRange(location: (text as NSString).length, length: 0)
    }

    private func applyToggleChrome() {
        revealButton.title = isRevealed ? "Hide" : "Show"
        revealButton.symbolName = isRevealed ? "eye.slash" : "eye"
        revealButton.toolTip = isRevealed ? "Hide the value again" : revealHint
        revealButton.setAccessibilityLabel(isRevealed ? "Hide the value again" : revealHint)
    }
}
