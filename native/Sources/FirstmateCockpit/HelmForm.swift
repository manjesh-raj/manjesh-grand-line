// Manjesh Grand Line - native macOS app.
//
// The app's one form language: `HelmField` (the sunken-field recipe and the
// controls built on it), `HelmFieldCard` / `HelmToggleRow` (the two non-text
// field shapes), and `HelmFormSheet` (the scaffold every editor sheet builds
// its fields into).
//
// **Why this file exists.** Phase 6 of the full-app UI audit
// (`data/grandline-full-ui-audit/report.md` §4.7, §3.2's "Sunken form field"
// entry, §6.3's `HelmField` supporting extraction, §6.4's "All 6 editor
// sheets" row). The audit measured six sheets that are all "create or edit one
// record" - Task, Follow-up, Project, Snippet, Command, Host - each built
// independently and each looking like a different app:
//
//     Task      357 x 643   custom field cards, NSSwitch, chips, sunken fields
//     Follow-up 302 x 388   NSGridView + 3 stock popups + a stock date picker
//     Project   261 x 364   NSGridView + a stock popup
//     Snippet   180 x 326   a stock bezeled field + stock buttons
//     Command   (NSGridView)  3 stock popups
//     Host      640 x 780 window  NSGridView, 7 bezeled fields, 2 popups
//
// Only the task editor got the field-card treatment, so Priority was a
// clickable card in one sheet and a stock popup in the very next one. Six
// different widths, six header treatments, six footer constructions, and four
// separate `NSGridView` label-column setups that each picked their own column
// width.
//
// Separately, the "sunken field" look - a de-bezelled `NSTextField`/`NSTextView`
// on a theme-derived fill - had been hand-rolled three times with copy-pasted
// logic (`ConsoleComposerPopover.fieldFillColor`, `ShiftController.
// detailFieldFillColor`, `ShiftTaskEditorController.shiftEditorFieldFillColor`),
// each carrying a doc comment pointing at the others. `HelmField.fill(_:)` is
// now the only copy; the other three are gone.
//
// **Nothing here is a new design decision.** The field card, the toggle row,
// the section kickers, the big lead field and the ⌘⏎ footer are all
// `ShiftTaskEditorController`'s own shapes (the newest sheet, redesigned
// against a captain-approved mockup) promoted so the other five can share
// them, exactly as §6.4 asks: "one shared form scaffold; the task editor's
// field-card language becomes the default."
//
// **Adding an editor sheet?** Build a `HelmFormSheet`, assign it as the
// controller's `view`, add a lead field, sections and rows, call `setFooter`,
// then `sizeToFitContent()`. Do not hand-roll an `NSGridView` label column, do
// not add another theme observer for the form's own chrome (the sheet owns
// one - use `onApplyTheme` for anything it does not know about), and do not
// re-derive the sunken fill.

import AppKit

// MARK: - HelmField

/// The one sunken-field recipe: a control with no system bezel, painted from
/// the theme instead.
///
/// The fill deliberately blends `chromeInkHex` into `chromeBackgroundHex`
/// rather than reusing either token bare. That reasoning is load-bearing, not
/// stylistic: `chromeBackgroundHex == backgroundHex` in three of the twelve
/// palettes (`gruvbox-light`, `tokyo-night-dark`, `tokyo-night-light`), so a
/// field painted with either token straight would be invisible against its own
/// container in exactly those three. Ink and background are guaranteed to
/// differ in every theme (otherwise text would not be readable), so blending
/// toward ink by a small fraction always lands on something distinct.
enum HelmField {
    /// The one field/control corner radius, in the twelve pre-Daylight
    /// palettes. Daylight's is `dWell` - see `cornerRadius(for:)`, which is
    /// what every well actually resolves through.
    static let cornerRadius: CGFloat = HelmMetrics.rControl

    /// §6.9's well radius, per theme. Daylight rounds a well to 14 (`dWell`,
    /// the radius its own scale names for exactly this surface); every other
    /// palette keeps `rControl`, so no existing form moves.
    static func cornerRadius(for theme: HelmTheme) -> CGFloat {
        theme.isDaylight ? HelmMetrics.dWell : cornerRadius
    }

    /// The same resolution for a *row*-shaped well - a field card, a toggle
    /// row. Daylight uses one well radius for both, since both are the same
    /// physical object at different widths.
    static func rowCornerRadius(for theme: HelmTheme) -> CGFloat {
        theme.isDaylight ? HelmMetrics.dWell : HelmMetrics.rRow
    }

    /// The resting border weight of a well. `HelmInputSurface` thickens it to
    /// `HelmInputSurface.focusBorderWidth` while focused and back to this when
    /// focus leaves.
    static let hairlineBorderWidth: CGFloat = 1

    /// The field border opacity - the same step fainter than the card outline
    /// that `HelmCard.dividerAlpha` uses, so a field inside a card reads as
    /// nested rather than as a second card.
    static let borderAlpha: CGFloat = 0.5

    /// A larger single-line well, for the one place an input *is* the surface:
    /// the ⌘K palette's query line and ⌥Space quick capture, both of which are
    /// a small panel with one field in it. Same physical object as
    /// `controlHeight`, one step up - not a fourth input language.
    static let prominentHeight: CGFloat = 40

    /// The height of a single-line field, so a column of fields, popups and
    /// date pickers sits on one rhythm.
    ///
    /// Chosen so that a *labelled* field (label + `HelmMetrics.s1` + control)
    /// lands within a point of `HelmFieldCard.height`, which is what lets a
    /// row mix the two shapes - "Follow up" over a date picker beside a
    /// Priority card - without their boxes ending at different heights.
    static let controlHeight: CGFloat = 32

    /// The label above a field. Same size as the label *inside* a
    /// `HelmFieldCard`, which is what makes the two shapes read as one system
    /// despite one label sitting above its control and the other inside it.
    static func labelFont() -> NSFont { .systemFont(ofSize: 10.5) }

    /// The single definition of the sunken fill (audit §3.2, "Sunken form
    /// field - 3 byte-identical copies"). Phase 2 landed it as
    /// `HelmButton.controlFill`; Phase 6 moved it here, which is its real
    /// home, and deleted the last three private copies.
    static func fill(_ theme: HelmTheme) -> NSColor {
        // Daylight publishes a real well token (§2.1's `inset`) instead of
        // leaving this to be derived, and uses it - a token the design names
        // for exactly this surface beats a derivation of two other tokens.
        //
        // What is worth recording is what the derivation revealed. Daylight is
        // the first palette whose card and page differ in a direction that puts
        // the 8%-toward-ink blend almost exactly on the page's own luminance
        // (1.01:1 against `paper`), and `HelmContrastSelfTest.checkFieldRecipe`
        // failed on it. `inset` is **no further** from `paper` (1.02:1), so
        // switching tokens is not what resolves that - on this palette a well
        // on the bare page is separated by its 1px `hair` border by design, and
        // a well on a card (which is where every form in this app actually
        // lives) reads at 1.14:1. That check now proves the border carries the
        // boundary wherever the fill cannot, rather than exempting a theme.
        if theme.isDaylight { return HelmTheme.nsColor(DaylightPalette.inset) }
        let chromeBackground = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        return chromeBackground.blended(withFraction: 0.08, of: ink) ?? chromeBackground
    }

    /// The matching hairline outline. Daylight's `hair` is already the
    /// design's own hairline value, so it is used at full strength - damping
    /// it would erase the only edge a white-on-paper well has (the same
    /// reasoning `HelmCard.applyCardSurface` records for the card outline).
    static func border(_ theme: HelmTheme) -> NSColor {
        theme.isDaylight
            ? HelmTheme.nsColor(theme.chromeLineHex)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(borderAlpha)
    }

    /// The colour text takes **on a field**, which is not the same as ink on
    /// the page.
    ///
    /// The fill is the chrome background nudged 8% toward ink, so it is
    /// slightly closer to the ink than the surface the palette's own contrast
    /// was pinned against - enough to drop `solarized-dark` from a passing
    /// 4.55:1 to a failing 4.20:1, measured. This is Phase 0's rule applied one
    /// level in: a token that is legible on one surface is not automatically
    /// legible on a surface derived from it. `HelmContrast.legible` returns
    /// `base` untouched whenever it already clears the floor, so eleven of the
    /// twelve themes are unaffected.
    static func ink(_ theme: HelmTheme) -> NSColor {
        HelmContrast.legible(HelmTheme.nsColor(theme.chromeInkHex), over: fill(theme))
    }

    /// The same correction for muted text sitting on a field - a placeholder, a
    /// field card's own label, a toggle row's subtitle.
    static func mutedInk(_ theme: HelmTheme) -> NSColor {
        HelmContrast.legible(HelmTheme.mutedInk(theme), over: fill(theme))
    }

    /// One-time chrome setup for any layer-backed view that should read as a
    /// sunken field - a text field, a scroll view wrapping a text view, a
    /// field card. `masksToBounds` matters: without it the view's own
    /// background paint ignores the corner radius and only the border is
    /// rounded.
    static func makeSunken(_ view: NSView, cornerRadius radius: CGFloat = HelmField.cornerRadius) {
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = radius
        view.layer?.borderWidth = hairlineBorderWidth
    }

    /// Recolour, on every theme change.
    ///
    /// `isRow` picks which of the two radii above this well takes. The radius
    /// is re-applied here, not only at `makeSunken` time, because it is now
    /// theme-dependent: a captain switching into Daylight has to see wells
    /// round to 14 without the view tree being rebuilt.
    static func applySunken(to view: NSView, theme: HelmTheme, isRow: Bool = false) {
        view.layer?.backgroundColor = fill(theme).cgColor
        view.layer?.borderColor = border(theme).cgColor
        view.layer?.cornerRadius = isRow ? rowCornerRadius(for: theme) : cornerRadius(for: theme)
    }

    /// What a sunken control actually resolved to, for `HelmContrastSelfTest`
    /// and for a render probe - read from the real layer rather than
    /// re-derived, so a check cannot pass by repeating the same mistake the
    /// component made.
    struct Geometry {
        let radius: CGFloat
        let borderWidth: CGFloat
        let fill: NSColor?
        let border: NSColor?
    }

    static func geometry(of view: NSView) -> Geometry {
        Geometry(radius: view.layer?.cornerRadius ?? -1,
                 borderWidth: view.layer?.borderWidth ?? -1,
                 fill: view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) },
                 border: view.layer?.borderColor.flatMap { NSColor(cgColor: $0) })
    }

    /// De-bezel an `NSTextField` (or an `NSSecureTextField`, which is one).
    static func makeSunkenTextField(_ field: NSTextField) {
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.font = HelmType.body()
        // A single-line field truncates rather than wrapping - without this a
        // long placeholder in a narrow column renders as two clipped half-lines
        // inside a one-line-tall box (seen in a real render of the Command
        // editor's parameter rows).
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        makeSunken(field)
    }
}

// MARK: - Sunken text fields

/// Owns the theme observation and the placeholder re-colouring for a sunken
/// text field.
///
/// `HelmTextField` and `HelmSecureTextField` cannot share a superclass -
/// `NSSecureTextField` already is `NSTextField`'s subclass - so they share this
/// instead of two copies of the same twenty lines.
private final class SunkenFieldTheming {
    private weak var field: NSTextField?
    private var observation: ThemeObservation?
    /// Phase 0's D1 fix: the focused chrome is driven by the window's first
    /// responder, so a click lights the field before a single keystroke.
    private var focus: HelmFocusRegistration?
    private var isFocused = false
    private var lastTheme: HelmTheme = ThemeManager.shared.theme
    /// §6.9: the domain hue this well's focus ring takes. `nil` keeps the
    /// theme accent, which is every unmigrated page.
    var domainHue: HelmDomainHue? {
        didSet { if domainHue != oldValue { apply(lastTheme) } }
    }
    /// Kept as a plain string so the placeholder can be re-rendered in the new
    /// theme's muted ink on every change. `NSTextField.placeholderString` is
    /// drawn in a fixed system grey, which is exactly the §5.3 token this
    /// codebase removed everywhere else.
    var placeholder: String = "" {
        didSet { applyPlaceholder(ThemeManager.shared.theme) }
    }

    init(_ field: NSTextField) {
        self.field = field
        observation = ThemeManager.shared.observe { [weak self] theme in self?.apply(theme) }
        focus = HelmFocusSensing.shared.register(field) { [weak self] focused in
            guard let self else { return }
            self.isFocused = focused
            self.apply(self.lastTheme)
        }
    }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
        if let focus { HelmFocusSensing.shared.unregister(focus) }
    }

    func apply(_ theme: HelmTheme) {
        guard let field else { return }
        lastTheme = theme
        HelmInputSurface.apply(chrome: field, theme: theme, focused: isFocused, hue: domainHue)
        // Both, deliberately. With `drawsBackground = true` the *cell* paints
        // `backgroundColor` over the layer's own fill, and its default is the
        // system `.textBackgroundColor` - so setting only the layer (which is
        // what the three hand-rolled copies this replaced did) leaves a
        // near-black/near-white system box on top of the theme fill. Caught in
        // a real render: the Host editor's fields came out visibly darker than
        // the field card beside them, even though both layers reported the
        // identical colour.
        field.backgroundColor = HelmField.fill(theme)
        field.textColor = HelmField.ink(theme)
        applyPlaceholder(theme)
    }

    private func applyPlaceholder(_ theme: HelmTheme) {
        guard let field, !placeholder.isEmpty else { return }
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: field.font ?? HelmType.body(),
                         .foregroundColor: HelmField.mutedInk(theme)]
        )
    }
}

/// A single-line text field in the app's own chrome.
///
/// `.lead` is the record's own identity field at the top of a sheet - the task
/// editor's big placeholder-styled title field, promoted so every editor names
/// its record the same way. It deliberately carries no fill or border: it is
/// the sheet's headline, not one field among several.
final class HelmTextField: NSTextField {
    enum Style {
        case standard
        case lead
        /// The same well, one step larger, for a small panel whose entire
        /// content is one field (⌥Space quick capture, the ⌘K palette's query
        /// line). Phase 0 added this so those two surfaces could leave their
        /// raw `NSTextField()` behind without shrinking to a form field's
        /// footprint inside a 600pt panel.
        case prominent
    }

    private var theming: SunkenFieldTheming!

    /// §6.9: the domain hue this field's focus ring takes. Forwards to the
    /// shared `SunkenFieldTheming`, which is where the focus treatment lives.
    var domainHue: HelmDomainHue? {
        get { theming.domainHue }
        set { theming.domainHue = newValue }
    }
    private let style: Style
    private var leadObservation: ThemeObservation?

    init(placeholder: String = "", style: Style = .standard) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        lineBreakMode = .byTruncatingTail
        switch style {
        case .standard, .prominent:
            HelmField.makeSunkenTextField(self)
            if style == .prominent { font = .systemFont(ofSize: HelmType.scaled(15)) }
            theming = SunkenFieldTheming(self)
            theming.placeholder = placeholder
            heightAnchor.constraint(
                equalToConstant: style == .prominent ? HelmField.prominentHeight : HelmField.controlHeight
            ).isActive = true
        case .lead:
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            font = HelmType.pageTitle()
            self.leadPlaceholder = placeholder
            leadObservation = ThemeManager.shared.observe { [weak self] theme in self?.applyLead(theme) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let leadObservation { ThemeManager.shared.unobserve(leadObservation) }
    }

    private var leadPlaceholder: String = ""

    /// The view carrying this field's sunken chrome - itself.
    var chromeView: NSView { self }

    /// Force a specific theme. The field observes `ThemeManager` itself, so a
    /// page never needs this; the self-test and a render probe do, to sweep a
    /// theme other than the active one.
    /// A control built before it was added to a hierarchy has no window to
    /// observe yet, so the focus sensing has to pick one up the moment it
    /// lands in one - see `HelmFocusSensing.noteWindowChanged(for:)`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        HelmFocusSensing.shared.noteWindowChanged(for: self)
    }

    func applyTheme(_ theme: HelmTheme) {
        switch style {
        case .standard, .prominent: theming.apply(theme)
        case .lead: applyLead(theme)
        }
    }

    private func applyLead(_ theme: HelmTheme) {
        textColor = HelmTheme.nsColor(theme.chromeInkHex)
        guard !leadPlaceholder.isEmpty else { return }
        placeholderAttributedString = NSAttributedString(
            string: leadPlaceholder,
            attributes: [.font: HelmType.pageTitle(),
                         .foregroundColor: HelmTheme.mutedInk(theme)]
        )
    }
}

/// The password field's shape. Identical chrome to `HelmTextField(.standard)`.
final class HelmSecureTextField: NSSecureTextField {
    private var theming: SunkenFieldTheming!

    /// §6.9: the domain hue this field's focus ring takes. Forwards to the
    /// shared `SunkenFieldTheming`, which is where the focus treatment lives.
    var domainHue: HelmDomainHue? {
        get { theming.domainHue }
        set { theming.domainHue = newValue }
    }

    init(placeholder: String = "") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        HelmField.makeSunkenTextField(self)
        theming = SunkenFieldTheming(self)
        theming.placeholder = placeholder
        heightAnchor.constraint(equalToConstant: HelmField.controlHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    var chromeView: NSView { self }

    /// See `HelmTextField.viewDidMoveToWindow()`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        HelmFocusSensing.shared.noteWindowChanged(for: self)
    }

    /// See `HelmTextField.applyTheme(_:)`.
    func applyTheme(_ theme: HelmTheme) { theming.apply(theme) }
}

/// A multi-line field: an `NSTextView` inside a scroll view wearing the same
/// sunken chrome as `HelmTextField`.
///
/// Modelled on `ConsoleComposerViewController`'s intent field, which is the
/// one multi-line control in the app that already got this right - including
/// `drawsBackground = true` plus an explicit theme fill, without which the
/// control is fully transparent and visually disappears into its container on
/// the light palettes.
final class HelmTextView: NSView {
    let textView = NSTextView()
    private let scroll = NSScrollView()
    private var observation: ThemeObservation?
    private var focus: HelmFocusRegistration?
    private var isFocused = false
    private var lastTheme: HelmTheme = ThemeManager.shared.theme

    /// §6.9: the domain hue this well's focus ring takes (`nil` = the theme
    /// accent, which is every page that has not claimed a hue).
    var domainHue: HelmDomainHue? {
        didSet { if domainHue != oldValue { applyTheme(lastTheme) } }
    }

    var string: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    /// The view carrying this field's sunken chrome - the scroll view, not
    /// this container.
    var chromeView: NSView { scroll }

    init(height: CGFloat, monospaced: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The glow host has to be layer-backed before `layout()` can set its
        // `shadowPath`.
        wantsLayer = true

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = monospaced ? HelmType.code() : HelmType.body()
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        // Never `.bezelBorder`: that is AppKit's own grey frame, the same
        // system chrome `HelmButton` removed from every push button.
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        HelmField.makeSunken(scroll)

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])

        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // The focus target is the text view (a real first responder, unlike a
        // text field's), and `self` is the un-clipped wrapper that can carry
        // the glow - see `HelmInputSurface`'s "two shapes" note.
        focus = HelmFocusSensing.shared.register(textView) { [weak self] focused in
            guard let self else { return }
            self.isFocused = focused
            self.applyTheme(self.lastTheme)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
        if let focus { HelmFocusSensing.shared.unregister(focus) }
    }

    /// See `HelmTextField.viewDidMoveToWindow()`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        HelmFocusSensing.shared.noteWindowChanged(for: textView)
    }

    override func layout() {
        super.layout()
        // An un-clipped layer's shadow otherwise falls back to this view's
        // full rectangular bounds rather than the rounded rect `scroll`
        // actually draws - the same resync `HelmComposerCard.layout()` does,
        // and for the same reason.
        let radius = HelmField.cornerRadius(for: ThemeManager.shared.theme)
        layer?.shadowPath = CGPath(roundedRect: bounds,
                                   cornerWidth: radius,
                                   cornerHeight: radius, transform: nil)
    }

    func applyTheme(_ theme: HelmTheme) {
        lastTheme = theme
        HelmInputSurface.apply(chrome: scroll, shadowHost: self, theme: theme,
                               focused: isFocused, hue: domainHue)
        let ink = HelmField.ink(theme)
        textView.backgroundColor = HelmField.fill(theme)
        textView.textColor = ink
        textView.insertionPointColor = ink
        HelmSelection.apply(to: textView, theme: theme)
    }
}

/// `NSDatePicker` in the same chrome.
///
/// §6.5 puts *reimplementing* AppKit controls out of scope ("reimplementing a
/// date picker is not worth it") but re-tinting one is exactly what it says is
/// buildable: `isBezeled = false` plus `drawsBackground`/`backgroundColor`/
/// `textColor` are all documented `NSDatePicker` API, so the stepper still
/// works and only the grey frame goes away.
final class HelmDatePicker: NSDatePicker {
    private var observation: ThemeObservation?

    init(elements: NSDatePicker.ElementFlags = [.yearMonthDay, .hourMinute]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        datePickerStyle = .textFieldAndStepper
        datePickerElements = elements
        isBezeled = false
        isBordered = false
        drawsBackground = true
        focusRingType = .none
        font = HelmType.body()
        HelmField.makeSunken(self)
        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
    }

    var chromeView: NSView { self }

    func applyTheme(_ theme: HelmTheme) {
        HelmField.applySunken(to: self, theme: theme)
        backgroundColor = HelmField.fill(theme)
        textColor = HelmField.ink(theme)
        // The stepper arrows are cell-drawn system chrome; matching the
        // light/dark side is all a view can do for them.
        appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
    }
}

// MARK: - HelmSearchField

/// The app's one search input (Daylight spec §6.9's search variant, shipped in
/// Phase 0 as recommendation R2): the same sunken well as `HelmTextField`, with
/// a leading magnifier glyph and an optional trailing keyboard-shortcut chip.
///
/// **Why this exists rather than a themed `NSSearchField`.** A stock
/// `NSSearchField` paints its own rounded system chrome and its own system
/// fill; the two sites this replaces (`UpdatesController`'s "Filter tools…"
/// and `HostsController`'s quick-connect) had only their `appearance` forced,
/// which picks the light-or-dark *side* of a system colour and cannot make it
/// theme-derived - which is exactly the wallpaper-tinted brown field the audit
/// measured (D2). `NSSearchField`'s own chrome is not overridable the way
/// `NSTextField`'s bezel is, so the well is rebuilt out of the shared parts
/// instead of fought with.
///
/// Callers get closures rather than having to conform to
/// `NSSearchFieldDelegate`: `onTextChanged` for live filtering, `onCommand`
/// for a panel that needs the arrow/Return/Escape keys (the ⌘K palette).
final class HelmSearchField: NSView, NSTextFieldDelegate {

    enum Size {
        case standard
        /// For a panel whose whole content is this field - see
        /// `HelmTextField.Style.prominent`.
        case prominent
    }

    /// Live filtering: fires on every keystroke.
    var onTextChanged: ((String) -> Void)?
    /// A field-editor command (Return, arrows, Escape). Return `true` to
    /// consume it, exactly like `NSTextFieldDelegate`'s own contract.
    var onCommand: ((Selector) -> Bool)?

    var stringValue: String {
        get { editor.stringValue }
        set {
            editor.stringValue = newValue
            updatePlaceholderVisibility()
        }
    }

    /// The view carrying this field's sunken chrome - the well, not this
    /// container (which is the un-clipped glow host).
    var chromeView: NSView { well }

    private let well = NSView()
    private let icon = NSImageView()
    /// The bare field is deliberately chromeless: the *well* carries the fill,
    /// border and radius, so the editor is only ever text on top of it. This
    /// is the one raw `NSTextField()` in this component and it lives in the
    /// file `checkNoRawTextInputs` exempts, for exactly that reason.
    private let editor = NSTextField()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var hintChip: NSView?
    private var hintLabel: NSTextField?

    private var observation: ThemeObservation?
    private var focus: HelmFocusRegistration?
    private var isFocused = false
    private var lastTheme: HelmTheme = ThemeManager.shared.theme
    /// §6.9: the domain hue this well's focus ring takes (`nil` = the theme
    /// accent, which is every page that has not claimed a hue).
    var domainHue: HelmDomainHue? {
        didSet { if domainHue != oldValue { applyTheme(lastTheme) } }
    }
    private let size: Size

    init(placeholder: String = "", size: Size = .standard, shortcutHint: String? = nil) {
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        HelmField.makeSunken(well)
        well.translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.usesSingleLineMode = true
        editor.cell?.wraps = false
        editor.cell?.isScrollable = true
        editor.lineBreakMode = .byTruncatingTail
        editor.font = size == .prominent ? .systemFont(ofSize: HelmType.scaled(15)) : HelmType.body()
        editor.delegate = self
        editor.translatesAutoresizingMaskIntoConstraints = false

        // `NSTextField`'s own `placeholderString` renders in a fixed system
        // grey - the token this codebase removed everywhere else - and an
        // attributed placeholder on a chromeless field inside a container is
        // easy to get wrong, so the placeholder is a real label the well owns.
        placeholderLabel.font = editor.font
        placeholderLabel.stringValue = placeholder
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(well)
        well.addSubview(icon)
        well.addSubview(editor)
        well.addSubview(placeholderLabel)

        let iconSide: CGFloat = size == .prominent ? 15 : 13
        let inset: CGFloat = size == .prominent ? 12 : 9
        var constraints: [NSLayoutConstraint] = [
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: size == .prominent
                                    ? HelmField.prominentHeight : HelmField.controlHeight),
            icon.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: inset),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconSide),
            icon.heightAnchor.constraint(equalToConstant: iconSide),
            editor.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            editor.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 2),
            placeholderLabel.centerYAnchor.constraint(equalTo: editor.centerYAnchor),
        ]

        if let shortcutHint {
            let chip = NSView()
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 5
            chip.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: shortcutHint)
            label.font = HelmType.code()
            label.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(label)
            well.addSubview(chip)
            hintChip = chip
            hintLabel = label
            constraints += [
                label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
                label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1),
                label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -1),
                chip.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -inset),
                chip.centerYAnchor.constraint(equalTo: well.centerYAnchor),
                editor.trailingAnchor.constraint(equalTo: chip.leadingAnchor, constant: -7),
                placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -7),
            ]
        } else {
            constraints += [
                editor.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -inset),
                placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: well.trailingAnchor,
                                                           constant: -inset),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        focus = HelmFocusSensing.shared.register(editor) { [weak self] focused in
            guard let self else { return }
            self.isFocused = focused
            self.applyTheme(self.lastTheme)
        }
        updatePlaceholderVisibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
        if let focus { HelmFocusSensing.shared.unregister(focus) }
    }

    /// See `HelmTextField.viewDidMoveToWindow()`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        HelmFocusSensing.shared.noteWindowChanged(for: editor)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds,
                                   cornerWidth: HelmField.cornerRadius,
                                   cornerHeight: HelmField.cornerRadius, transform: nil)
    }

    /// Put the caret in this field - what a page's own "focus the search box"
    /// menu action or ⌘K reveal calls.
    func focusEditor() {
        window?.makeFirstResponder(editor)
    }

    func applyTheme(_ theme: HelmTheme) {
        lastTheme = theme
        HelmInputSurface.apply(chrome: well, shadowHost: self, theme: theme,
                               focused: isFocused, hue: domainHue)
        let ink = HelmField.ink(theme)
        editor.textColor = ink
        placeholderLabel.textColor = HelmField.mutedInk(theme)
        // The glyph is decorative next to real text, so it takes the muted
        // token rather than the accent - the accent is reserved for the focus
        // lamp on this same well (audit P1, "the accent is a light, not paint").
        icon.contentTintColor = isFocused ? HelmTheme.nsColor(theme.accentHex) : HelmField.mutedInk(theme)
        hintChip?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(0.45).cgColor
        hintLabel?.textColor = HelmField.mutedInk(theme)
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !editor.stringValue.isEmpty
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updatePlaceholderVisibility()
        onTextChanged?(editor.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        onCommand?(commandSelector) ?? false
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugEditor: NSTextField { editor }
    var debugPlaceholderHidden: Bool { placeholderLabel.isHidden }
    var debugHasShortcutChip: Bool { hintChip != nil }
    #endif
}

// MARK: - HelmChipInput

/// Daylight §6.9's **chips-in-well** input: tokens live *inside* the well, with
/// the editor as the last inline element.
///
/// This replaces the app's "a field, and separately a `ChipFlowView` below it"
/// pattern - `ShiftTaskEditorController`'s tags row, and Dictation's raw
/// vocabulary field. The difference is not decoration: with the chips in a
/// separate view below, a committed token reads as a *result* of the field
/// rather than as the field's own content, which is why the task editor needed
/// a caption explaining that Enter commits.
///
/// Interaction, per §6.9: **Enter commits**, a trailing comma commits (kept
/// from the pattern this replaces, since it is how the captain's existing
/// muscle memory works), and **Backspace on an empty editor pops the last
/// token**. Nothing here owns the token list - the caller does, and hands it
/// back in through `setTokens`, exactly like `HelmFieldCard` does with its
/// value. That is what keeps a migrated editor's save path untouched.
///
/// The well is the same physical object as every other input
/// (`HelmField.makeSunken` + `HelmInputSurface`), so the focus ring, the
/// selection colour and the Daylight radius all come from the shared
/// definitions rather than being rebuilt here.
final class HelmChipInput: NSView, NSTextFieldDelegate {

    /// Fired whenever the token list changes - committed or popped. The caller
    /// re-reads `tokens` rather than being handed a delta, since every caller
    /// already keeps the list as its own model.
    var onTokensChanged: (([String]) -> Void)?

    /// §6.9: the domain hue this well's focus ring takes.
    var domainHue: HelmDomainHue? {
        didSet { if domainHue != oldValue { applyTheme(lastTheme) } }
    }

    private(set) var tokens: [String] = []

    private let well = NSView()
    private let flow = ChipFlowView()
    private let editor = NSTextField()
    private var chips: [VocabularyChipView] = []
    private var observation: ThemeObservation?
    private var focus: HelmFocusRegistration?
    private var isFocused = false
    private var lastTheme: HelmTheme = ThemeManager.shared.theme

    init(placeholder: String = "") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The well clips (its fill has to respect the corner radius) and this
        // outer view does not, so the focus glow has an un-clipped host - the
        // two-layer arrangement `HelmInputSurface`'s doc comment describes.
        layer?.masksToBounds = false

        HelmField.makeSunken(well)
        well.translatesAutoresizingMaskIntoConstraints = false

        // A chrome-less editor: the *well* is the input surface, so the field
        // inside it must paint nothing of its own or it renders as a second,
        // smaller well. `HelmForm.swift` is the one file
        // `checkNoRawTextInputs` exempts for exactly this reason.
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = HelmType.body()
        editor.usesSingleLineMode = true
        editor.cell?.wraps = false
        editor.cell?.isScrollable = true
        editor.placeholderString = placeholder
        editor.delegate = self
        editor.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (13): an editor's own >500 compression resistance
        // inside a card inside a page is a window-width floor.
        editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [flow, editor])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s1 + 2
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(well)
        well.addSubview(column)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: HelmMetrics.s2),
            column.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -HelmMetrics.s2),
            column.topAnchor.constraint(equalTo: well.topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -7),
            flow.widthAnchor.constraint(equalTo: column.widthAnchor),
            editor.widthAnchor.constraint(equalTo: column.widthAnchor),
            editor.heightAnchor.constraint(equalToConstant: 20),
        ])

        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        focus = HelmFocusSensing.shared.register(editor) { [weak self] focused in
            guard let self else { return }
            self.isFocused = focused
            self.applyTheme(self.lastTheme)
        }
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
        if let focus { HelmFocusSensing.shared.unregister(focus) }
    }

    var chromeView: NSView { well }

    /// Replace the whole token list - how a caller seeds an editor it is
    /// opening on an existing record.
    func setTokens(_ values: [String]) {
        tokens = values
        rebuildChips()
    }

    /// Commit whatever is still sitting in the editor. An editor closing with
    /// text typed but not yet committed would otherwise silently drop it,
    /// which is the one way a chip input can lose the captain's work.
    func commitPendingText() {
        let pending = editor.stringValue
        editor.stringValue = ""
        commit(pending)
    }

    private func commit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Case-insensitive dedup, matching the behaviour of both patterns this
        // replaces.
        guard !tokens.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        tokens.append(trimmed)
        rebuildChips()
        onTokensChanged?(tokens)
    }

    private func popLast() {
        guard !tokens.isEmpty else { return }
        tokens.removeLast()
        rebuildChips()
        onTokensChanged?(tokens)
    }

    private func rebuildChips() {
        chips = tokens.map { token in
            let chip = VocabularyChipView(word: token)
            chip.onRemove = { [weak self] in
                guard let self else { return }
                self.tokens.removeAll { $0 == token }
                self.rebuildChips()
                self.onTokensChanged?(self.tokens)
            }
            chip.applyTheme(lastTheme)
            return chip
        }
        flow.setChips(chips)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The glow's shape has to track the well's rounded rect, or AppKit
        // casts it from this view's full rectangular bounds.
        let radius = HelmField.cornerRadius(for: lastTheme)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil)
    }

    func applyTheme(_ theme: HelmTheme) {
        lastTheme = theme
        HelmInputSurface.apply(chrome: well, shadowHost: self, theme: theme,
                               focused: isFocused, hue: domainHue)
        editor.textColor = HelmField.ink(theme)
        editor.placeholderAttributedString = NSAttributedString(
            string: editor.placeholderString ?? "",
            attributes: [.font: HelmType.body(), .foregroundColor: HelmField.mutedInk(theme)])
        chips.forEach { $0.applyTheme(theme) }
        needsLayout = true
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard editor.stringValue.hasSuffix(",") else { return }
        let candidate = String(editor.stringValue.dropLast())
        editor.stringValue = ""
        commit(candidate)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitPendingText()
            return true
        }
        // Backspace on an empty editor pops the last token (§6.9). Anything
        // typed means the captain is editing text, not removing a token.
        if commandSelector == #selector(NSResponder.deleteBackward(_:)), editor.stringValue.isEmpty {
            popLast()
            return true
        }
        return false
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var chipCountForTests: Int { chips.count }
    var editorTextForTests: String { editor.stringValue }
    func debugType(_ text: String) {
        editor.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
    }

    @discardableResult
    func debugPressReturn() -> Bool {
        control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    @discardableResult
    func debugPressBackspace() -> Bool {
        control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.deleteBackward(_:)))
    }
    #endif
}

// MARK: - HelmFieldCard

/// A small "icon-in-a-square" container holding a centred coloured dot, so a
/// hue-carrying choice (Priority, Risk) has the same footprint in a field card
/// as an `IconTileView` does. `ShiftTaskEditorController.PriorityDotView`
/// promoted.
final class HelmDotAccessory: NSView {
    private let dot = NSView()

    init(size: CGFloat = 22, dotDiameter: CGFloat = 10) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotDiameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: dotDiameter),
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setColor(_ color: NSColor) { dot.layer?.backgroundColor = color.cgColor }
}

/// The app's one menu-backed choice control: a clickable card showing an
/// optional leading accessory, a muted field label over the current value, and
/// a trailing chevron. Clicking anywhere on it pops an `NSMenu` just underneath.
///
/// This is `ShiftTaskEditorController.TaskFieldCardView` promoted. It replaces
/// the stock `NSPopUpButton` at every form-level choice across the six editor
/// sheets, which is what makes Priority look the same in the Task sheet and the
/// Follow-up sheet - the audit's own example of the split (§4.7).
///
/// `HelmPopUpButton` is still the right control for a *dense inline* choice
/// (the Command editor's per-parameter kind picker), where a 50pt card in a
/// six-control row would be absurd. Card for a form field, popup for a table
/// cell.
final class HelmFieldCard: NSView {
    /// An extra menu entry below a separator, for a choice list that also
    /// offers an action ("+ New Key…").
    struct ExtraItem {
        let title: String
        let handler: () -> Void
    }

    /// The one field-card height. `HelmField.controlHeight` plus the label
    /// above it lands within a couple of points of this, which is what keeps a
    /// column mixing cards and labelled fields on one rhythm.
    static let height: CGFloat = 50

    let card = HoverHighlightView()
    private let valueLabel = NSTextField(labelWithString: "")
    private let fieldLabelView: NSTextField
    private let chevron = NSImageView()
    private let clickButton = NSButton()

    /// Raised on click when no choice list has been configured - for a card
    /// that opens something other than a menu.
    var onClick: (() -> Void)?

    private var optionTitles: [String] = []
    private var extras: [ExtraItem] = []
    private var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex: Int = -1

    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    /// The view carrying this card's sunken chrome.
    var chromeView: NSView { card }

    init(label: String, accessory: NSView? = nil) {
        fieldLabelView = NSTextField(labelWithString: label)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        card.cornerRadius = HelmMetrics.rRow
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        fieldLabelView.font = HelmField.labelFont()
        fieldLabelView.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = HelmType.rowTitle()
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [fieldLabelView, valueLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // The text column is the only thing in the row allowed to flex, so a
        // long value truncates rather than squeezing the accessory or the
        // chevron (AGENTS.md's dense-row compression-resistance gotcha).
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        var rowViews: [NSView] = []
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            rowViews.append(accessory)
        }
        rowViews += [textStack, chevron]

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        clickButton.title = ""
        clickButton.isBordered = false
        clickButton.target = self
        clickButton.action = #selector(clicked)
        clickButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(clickButton)
        NSLayoutConstraint.activate([
            clickButton.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            clickButton.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            clickButton.topAnchor.constraint(equalTo: card.topAnchor),
            clickButton.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Turn this card into a choice list. `onSelect` fires with the chosen
    /// index into `titles`; the card updates its own displayed value.
    func configureChoices(_ titles: [String],
                          selectedIndex index: Int,
                          extra: [ExtraItem] = [],
                          onSelect: @escaping (Int) -> Void) {
        optionTitles = titles
        extras = extra
        self.onSelect = onSelect
        select(index)
    }

    /// Move the selection without firing `onSelect` - for a value that changed
    /// because of something other than a click on this card.
    func select(_ index: Int) {
        guard optionTitles.indices.contains(index) else {
            selectedIndex = -1
            return
        }
        selectedIndex = index
        value = optionTitles[index]
    }

    @objc private func clicked() {
        guard !optionTitles.isEmpty else {
            onClick?()
            return
        }
        let menu = NSMenu()
        for (i, title) in optionTitles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(choicePicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == selectedIndex ? .on : .off
            menu.addItem(item)
        }
        if !extras.isEmpty {
            menu.addItem(.separator())
            for (i, e) in extras.enumerated() {
                let item = NSMenuItem(title: e.title, action: #selector(extraPicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        }
        popMenu(menu)
    }

    @objc private func choicePicked(_ sender: NSMenuItem) {
        select(sender.tag)
        onSelect?(sender.tag)
    }

    @objc private func extraPicked(_ sender: NSMenuItem) {
        guard extras.indices.contains(sender.tag) else { return }
        extras[sender.tag].handler()
    }

    func popMenu(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: bounds.height + 4), in: self)
    }

    func applyTheme(_ theme: HelmTheme) {
        let fill = HelmField.fill(theme)
        card.normalColor = fill
        card.hoverColor = fill.hoverShifted(by: 0.10, forMode: theme.mode)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = HelmField.border(theme).cgColor
        // §6.9's choice well: the same well as a single-line field, so the
        // radius resolves through the same helper rather than staying pinned
        // to the pre-Daylight row radius.
        card.cornerRadius = HelmField.rowCornerRadius(for: theme)
        fieldLabelView.textColor = HelmField.mutedInk(theme)
        valueLabel.textColor = HelmField.ink(theme)
        chevron.contentTintColor = HelmField.mutedInk(theme)
    }
}

// MARK: - HelmToggleRow

/// A boolean option as a full-width card: an `NSSwitch`, a title, an optional
/// explanatory subtitle, and an optional trailing control that the switch
/// reveals (the task editor's due-date picker).
///
/// `ShiftTaskEditorController`'s "Set due date" card promoted. It replaces the
/// bare `NSButton(checkboxWithTitle:)` rows the Host editor used for the same
/// job, which sat unlabelled in an `NSGridView` with an empty label cell.
///
/// The `NSSwitch` itself stays system chrome - §6.5 and the registered captain
/// decision `grandline-full-ui-audit-decision-nsswitch-theming` leave a
/// bespoke toggle out of scope, and it was measured to answer `false` to every
/// tint setter it was asked about.
final class HelmToggleRow: NSView {
    let toggle = NSSwitch()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField?
    private let trailing: NSView?

    var onToggle: (() -> Void)?

    var isOn: Bool {
        get { toggle.state == .on }
        set { toggle.state = newValue ? .on : .off }
    }

    init(title: String, subtitle: String? = nil, trailing: NSView? = nil) {
        titleLabel = NSTextField(labelWithString: title)
        subtitleLabel = subtitle.map { NSTextField(labelWithString: $0) }
        self.trailing = trailing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        HelmField.makeSunken(self, cornerRadius: HelmMetrics.rRow)

        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel?.font = HelmField.labelFont()
        subtitleLabel?.translatesAutoresizingMaskIntoConstraints = false

        var textViews: [NSView] = [titleLabel]
        if let subtitleLabel { textViews.append(subtitleLabel) }
        let textStack = NSStackView(views: textViews)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let left = NSStackView(views: [toggle, textStack])
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = HelmMetrics.s2 + 2
        left.translatesAutoresizingMaskIntoConstraints = false
        left.setHuggingPriority(.defaultLow, for: .horizontal)

        var rowViews: [NSView] = [left]
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            rowViews.append(trailing)
        }
        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2 + 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            row.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The view carrying this row's sunken chrome - itself.
    var chromeView: NSView { self }

    @objc private func toggled() { onToggle?() }

    func applyTheme(_ theme: HelmTheme) {
        HelmField.applySunken(to: self, theme: theme, isRow: true)
        titleLabel.textColor = HelmField.ink(theme)
        subtitleLabel?.textColor = HelmField.mutedInk(theme)
    }
}

// MARK: - HelmFormSheet

/// The app's one editor-sheet scaffold: a heading, an optional lead field, a
/// column of kickered sections, and a footer.
///
/// **It is the controller's root view**, not something dropped inside one. That
/// is what lets it own the sheet's background, its forced appearance, and the
/// single `ThemeManager` observation the whole sheet needs - the three things
/// all six editors were separately (and in three of six cases, incorrectly)
/// hand-rolling. A controller with extra chrome of its own hooks `onApplyTheme`
/// rather than registering a second observer.
final class HelmFormSheet: NSView {
    /// The one editor width. The six sheets measured 180 / 261 / 302 / 357 /
    /// 520 / 640 before this (audit §4.7); none of that spread encoded a
    /// decision. 520 is the widest sheet's (the redesigned task editor's) own
    /// value, which is a comfortable dialog reading width.
    static let width: CGFloat = 520

    /// The horizontal inset from the sheet's edge to the form column.
    static let gutter: CGFloat = 22

    /// §6.10's domain ribbon weight.
    static let ribbonHeight: CGFloat = 6

    /// Raised after the sheet has themed everything it owns, for a controller
    /// with chrome the scaffold knows nothing about.
    var onApplyTheme: ((HelmTheme) -> Void)?

    let headingLabel = NSTextField(labelWithString: "")

    private let contentStack = NSStackView()
    private let footerContainer = NSView()
    private var scroll: NSScrollView?
    private let footerDivider = NSView()
    private var observation: ThemeObservation?

    /// Everything the sheet re-colours itself: section kickers, field labels
    /// and captions all take `mutedInk`.
    private var mutedLabels: [NSTextField] = []
    private var leadView: NSView?
    private var fieldCards: [HelmFieldCard] = []
    private var toggleRows: [HelmToggleRow] = []
    /// A section's optional accent-tinted numbered chip (the Host/Key editors'
    /// mockup - `grandline-hosts-keys-form-redesign`) - re-tinted with the
    /// theme's own accent on every change, unlike `mutedLabels`.
    private var sectionNumberChips: [(chip: NSView, label: NSTextField)] = []
    /// An accent-tinted info card added via `addInfoCard` - same re-tint
    /// treatment as the numbered chip.
    private var infoCards: [(card: NSView, icon: NSImageView, label: NSTextField)] = []

    private let scrolls: Bool
    private let maxContentWidth: CGFloat

    /// `scrolls` pins the heading at the top and the footer at the bottom and
    /// scrolls only the field column - what the two long forms (Command, Host)
    /// need. The four short sheets size themselves to their content instead
    /// (`sizeToFitContent`).
    ///
    /// `maxContentWidth` caps the field column for a *resizable* container (the
    /// Host editor's window). It is applied with `<=`/`>=`/centerX and never a
    /// required `==` width tie - AGENTS.md's host-editor gotcha (3): an exact
    /// tie makes AppKit's window-auto-fit machinery treat the one width where
    /// that tie has zero slack as the window's true size and snap back to it
    /// after every user resize.
    /// §6.10's 6pt gradient ribbon across the very top of the sheet.
    private let ribbon = NSView()
    private let ribbonGradient = CAGradientLayer()
    /// Which domain owns this sheet - the ribbon's hue, and the hue every
    /// field inside it lights with when focused. Defaults to `.rose`, the hue
    /// §6.10 names for the task editor and the one §4 gives to Tasks.
    private let domainHue: HelmDomainHue
    private var ribbonHeightConstraint: NSLayoutConstraint?
    /// Every well the sheet was handed, as a "point this at a hue" closure -
    /// so §6.10's "the sheet's domain hue drives focus" holds for every field
    /// without `HelmFormSheet` having to know which concrete input type each
    /// row is (there are five, and a sixth would otherwise mean editing this).
    private var fieldHues: [(HelmDomainHue) -> Void] = []

    init(title: String, scrolls: Bool = false, maxContentWidth: CGFloat = HelmFormSheet.width,
         domainHue: HelmDomainHue = .rose) {
        self.scrolls = scrolls
        self.maxContentWidth = maxContentWidth
        self.domainHue = domainHue
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 480))
        wantsLayer = true

        headingLabel.stringValue = title
        headingLabel.font = HelmType.sectionTitle()
        headingLabel.translatesAutoresizingMaskIntoConstraints = false

        ribbon.wantsLayer = true
        ribbon.layer?.addSublayer(ribbonGradient)
        ribbonGradient.startPoint = HelmDomainHue.ribbonStart
        ribbonGradient.endPoint = HelmDomainHue.ribbonEnd
        ribbon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ribbon)
        NSLayoutConstraint.activate([
            ribbon.leadingAnchor.constraint(equalTo: leadingAnchor),
            ribbon.trailingAnchor.constraint(equalTo: trailingAnchor),
            ribbon.topAnchor.constraint(equalTo: topAnchor),
        ])
        let ribbonHeight = ribbon.heightAnchor.constraint(equalToConstant: Self.ribbonHeight)
        ribbonHeight.isActive = true
        ribbonHeightConstraint = ribbonHeight

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = HelmMetrics.s3 - 2
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        footerContainer.translatesAutoresizingMaskIntoConstraints = false

        if scrolls {
            buildScrollingLayout()
        } else {
            buildFixedLayout()
        }

        observation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let observation { ThemeManager.shared.unobserve(observation) }
    }

    // MARK: Layout

    private func buildFixedLayout() {
        // A real, required width - not just an initial frame guess. This is
        // what makes `sizeToFitContent`'s `fittingSize` height read stable:
        // without it Auto Layout also has to guess a width when computing the
        // fitting height, which text wrapping and any wrap-to-width subview
        // make unstable (see `ShiftTaskEditorController`'s own history).
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        let outer = NSStackView(views: [headingLabel, contentStack, footerContainer])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = HelmMetrics.s3 + 2
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.gutter),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.gutter),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s5 - 4),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(HelmMetrics.s4 + 2)),
            contentStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            footerContainer.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
    }

    private func buildScrollingLayout() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.scroll = scroll

        // `FlippedView`, so a document shorter than the clip view rests against
        // its *top* rather than its bottom (AGENTS.md gotcha #9).
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let column = cappedColumn(in: document)
        column.addSubview(contentStack)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: HelmMetrics.s2),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -HelmMetrics.s5),
            contentStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: column.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        scroll.documentView = document

        let headerBox = NSView()
        headerBox.translatesAutoresizingMaskIntoConstraints = false
        // The heading has to start at the *column*'s leading edge, not be
        // centred itself - a bare `centerXAnchor` on the label would centre the
        // words "New Host" in the window while every field below stayed
        // left-aligned in its capped column.
        let headerColumn = cappedColumn(in: headerBox)
        headerColumn.addSubview(headingLabel)

        footerDivider.wantsLayer = true
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBox)
        addSubview(scroll)
        addSubview(footerDivider)
        addSubview(footerContainer)
        NSLayoutConstraint.activate([
            headerBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBox.topAnchor.constraint(equalTo: topAnchor),
            headingLabel.leadingAnchor.constraint(equalTo: headerColumn.leadingAnchor),
            headingLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerColumn.trailingAnchor),
            headerColumn.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: HelmMetrics.s5 - 4),
            headerColumn.bottomAnchor.constraint(equalTo: headerBox.bottomAnchor, constant: -HelmMetrics.s3),
            headingLabel.topAnchor.constraint(equalTo: headerColumn.topAnchor),
            headingLabel.bottomAnchor.constraint(equalTo: headerColumn.bottomAnchor),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerBox.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            // Content scrolls *under* the pinned footer, so it needs an edge.
            footerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footerContainer.topAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            footerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            // `scroll.contentView` (the clip view), never `scroll` itself: a
            // non-overlay vertical scroller reserves a real ~15pt track that
            // narrows the clip view without narrowing the scroll view's own
            // frame (AGENTS.md gotcha #4).
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    /// A leading-aligned column inside `container`, capped at
    /// `maxContentWidth` and centred - the shape the header, the scrolled
    /// field column and the footer all share so their edges line up at any
    /// window width.
    ///
    /// Deliberately inequalities plus a `.defaultHigh` preferred width, never a
    /// required `==` tie: AGENTS.md's host-editor gotcha (3) - a required tie
    /// makes AppKit's window-auto-fit machinery treat the single width where it
    /// has zero slack as the window's true size and snap back to it after every
    /// user resize.
    @discardableResult
    private func cappedColumn(in container: NSView) -> NSView {
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: Self.gutter),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Self.gutter),
            column.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: maxContentWidth),
        ])
        let preferred = column.widthAnchor.constraint(equalToConstant: maxContentWidth)
        preferred.priority = .defaultHigh
        preferred.isActive = true
        return column
    }

    // MARK: Content

    /// A prominent identity field above the first section - the record's own
    /// name. Every editor names its record here, in the same place, at the same
    /// size.
    func addLead(_ view: NSView) {
        appendFullWidth(view)
        leadView = view
        contentStack.setCustomSpacing(HelmMetrics.s4, after: view)
    }

    /// A wrapping hint line directly under the lead field.
    @discardableResult
    func addLeadHint(_ attributed: NSAttributedString) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = attributed
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        appendFullWidth(label)
        // The hint belongs *to* the lead field, so it sits tight under it and
        // takes over the breathing room before the first section.
        if let leadView { contentStack.setCustomSpacing(HelmMetrics.s1, after: leadView) }
        contentStack.setCustomSpacing(HelmMetrics.s4, after: label)
        return label
    }

    /// Start a section. `title` is rendered as the app's one uppercase kicker,
    /// optionally preceded by a small accent-tinted numbered chip (`number`,
    /// e.g. `"01"` - the Host/Key editors' mockup convention; `nil`, the
    /// default, reproduces every pre-existing caller unchanged). `actions`
    /// (if any) sit at the column's trailing edge on the same line - for a
    /// section whose own control belongs beside its name rather than in a row
    /// of its own.
    func addSection(_ title: String, number: String? = nil, actions: [NSView] = []) {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: HelmType.kicker(),
            .kern: HelmType.kickerKern,
        ])
        label.translatesAutoresizingMaskIntoConstraints = false
        mutedLabels.append(label)

        var headViews: [NSView] = []
        if let number {
            headViews.append(makeSectionNumberChip(number))
        }
        headViews.append(label)
        let head = NSStackView(views: headViews)
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = HelmMetrics.s2 - 2
        head.translatesAutoresizingMaskIntoConstraints = false

        guard !actions.isEmpty else {
            appendFullWidth(head)
            contentStack.setCustomSpacing(HelmMetrics.s2, after: head)
            return
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for action in actions {
            action.setContentHuggingPriority(.required, for: .horizontal)
            action.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let row = NSStackView(views: [head, spacer] + actions)
        row.orientation = .horizontal
        row.alignment = .centerY
        // AGENTS.md gotcha #10: `.gravityAreas` honours no hugging priority, so
        // without `.fill` the actions drift with the kicker's own text width.
        row.distribution = .fill
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        appendFullWidth(row)
        contentStack.setCustomSpacing(HelmMetrics.s2, after: row)
    }

    /// The mockup's `.fnum` - a small rounded square carrying the section
    /// number, tinted with the theme's own accent (re-derived on every theme
    /// change via `sectionNumberChips`, unlike the kicker label beside it
    /// which just takes `mutedInk`).
    private func makeSectionNumberChip(_ number: String) -> NSView {
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = HelmMetrics.rChip
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)

        let numberLabel = NSTextField(labelWithString: number)
        numberLabel.font = .systemFont(ofSize: 9.5, weight: .heavy)
        numberLabel.alignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(numberLabel)
        NSLayoutConstraint.activate([
            numberLabel.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 19),
            chip.heightAnchor.constraint(equalToConstant: 19),
        ])
        sectionNumberChips.append((chip, numberLabel))
        return chip
    }

    /// An arbitrary full-width row.
    func addRow(_ view: NSView) {
        appendFullWidth(view)
        register(view)
    }

    /// A labelled field: a small muted caption over a full-width control.
    func addField(_ label: String, _ control: NSView) {
        appendFullWidth(labelled(label, control))
        register(control)
    }

    /// Two or more equal-width controls on one row. Used for the short paired
    /// fields (Address | Port, Priority | Project) that would otherwise make a
    /// long form twice as tall as it needs to be.
    func addColumns(_ views: [NSView]) {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = HelmMetrics.s3 - 2
        row.translatesAutoresizingMaskIntoConstraints = false
        appendFullWidth(row)
        views.forEach { register($0) }
    }

    /// The same, but each column is a labelled field.
    func addFieldColumns(_ pairs: [(String, NSView)]) {
        addColumns(pairs.map { labelled($0.0, $0.1) })
        pairs.forEach { register($0.1) }
    }

    /// An accent-washed note card: a small leading icon plus a wrapping
    /// message. The mockup's `.info-card` (Host/Key editors,
    /// `grandline-hosts-keys-form-redesign`) - a plain `addCaption` reads as
    /// throwaway fine print, this reads as a considered security note.
    @discardableResult
    func addInfoCard(symbol: String = "info.circle", text: String) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = HelmMetrics.rRow - 1
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = HelmType.caption()
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: HelmMetrics.s3),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -HelmMetrics.s3),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            icon.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
        ])
        infoCards.append((card, icon, label))
        appendFullWidth(card)
        return card
    }

    /// A wrapping explanatory paragraph.
    @discardableResult
    func addCaption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = HelmType.caption()
        label.translatesAutoresizingMaskIntoConstraints = false
        mutedLabels.append(label)
        appendFullWidth(label)
        return label
    }

    /// Set explicit spacing after the row most recently added.
    func setSpacingAfterLastRow(_ spacing: CGFloat) {
        guard let last = contentStack.arrangedSubviews.last else { return }
        contentStack.setCustomSpacing(spacing, after: last)
    }

    /// The scaffold's own label-over-control wrapper, exposed so a caller can
    /// build one for a control it wants to place inside `addColumns` itself.
    /// The label joins the sheet's muted-text registry either way, so there is
    /// still exactly one theme observation per sheet.
    func labelledField(_ text: String, _ control: NSView) -> NSView {
        labelled(text, control)
    }

    private func labelled(_ text: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = HelmField.labelFont()
        label.translatesAutoresizingMaskIntoConstraints = false
        mutedLabels.append(label)
        control.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// Every row is pinned to the column's own width. An `NSStackView` left at
    /// its default `.gravityAreas` distribution does not stretch its arranged
    /// subviews (AGENTS.md gotcha #10), so without this a field would size to
    /// its own content and the form would go ragged.
    private func appendFullWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    /// Collects the two components that do not theme themselves, so the sheet's
    /// one observation reaches them.
    private func register(_ view: NSView) {
        if let card = view as? HelmFieldCard { fieldCards.append(card) }
        if let row = view as? HelmToggleRow { toggleRows.append(row) }
        // §6.10: "the sheet's domain hue driving focus". Recorded as a closure
        // per concrete type rather than through a protocol, because these are
        // five unrelated `NSView` subclasses (two of them `NSTextField`
        // subclasses that cannot share one) and a protocol with an `is`-cast
        // ladder behind it buys nothing over the ladder itself.
        if let field = view as? HelmTextField { fieldHues.append { field.domainHue = $0 } }
        if let field = view as? HelmSecureTextField { fieldHues.append { field.domainHue = $0 } }
        if let field = view as? HelmTextView { fieldHues.append { field.domainHue = $0 } }
        if let field = view as? HelmSearchField { fieldHues.append { field.domainHue = $0 } }
        if let field = view as? HelmChipInput { fieldHues.append { field.domainHue = $0 } }
    }

    // MARK: Footer

    /// The one editor footer: an optional muted hint on the left, an optional
    /// destructive action, then Cancel and the confirm button.
    ///
    /// Esc always cancels and Return always confirms - `confirmModifiers`
    /// exists for the one sheet whose confirm is ⌘Return (the task editor,
    /// whose multi-line description field consumes a plain Return).
    @discardableResult
    func setFooter(target: AnyObject,
                   confirmTitle: String,
                   confirm: Selector,
                   cancel: Selector,
                   confirmModifiers: NSEvent.ModifierFlags = [],
                   delete: (title: String, action: Selector)? = nil,
                   hint: String? = nil) -> (confirm: HelmButton, cancel: HelmButton, delete: HelmButton?) {
        footerContainer.subviews.forEach { $0.removeFromSuperview() }

        var views: [NSView] = []
        if let hint {
            let label = NSTextField(labelWithString: hint)
            label.font = HelmType.caption()
            label.translatesAutoresizingMaskIntoConstraints = false
            mutedLabels.append(label)
            views.append(label)
        }
        var deleteButton: HelmButton?
        if let delete {
            let button = HelmButton(title: delete.title, variant: .destructive, target: target, action: delete.action)
            deleteButton = button
            views.append(button)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)

        let cancelButton = HelmButton(title: "Cancel", variant: .secondary, target: target, action: cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let confirmButton = HelmButton(title: confirmTitle, variant: .primary, target: target, action: confirm)
        // `isBordered = false` means there is no default-button bezel left to
        // paint system blue, so the Return shortcut survives without the look
        // (Phase 2). `performKeyEquivalent:` reaches it regardless of first
        // responder, which is what makes ⌘Return work from inside a text view.
        confirmButton.keyEquivalent = "\r"
        confirmButton.keyEquivalentModifierMask = confirmModifiers
        views += [cancelButton, confirmButton]

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s2 + 2
        row.translatesAutoresizingMaskIntoConstraints = false
        if scrolls {
            // Same capped, centred column as the header and the field list, so
            // Cancel/Save sit under the last field rather than out at the
            // window's own edge.
            let column = cappedColumn(in: footerContainer)
            column.addSubview(row)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: footerContainer.topAnchor, constant: HelmMetrics.s3),
                column.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor, constant: -(HelmMetrics.s4 + 2)),
                row.leadingAnchor.constraint(equalTo: column.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: column.trailingAnchor),
                row.topAnchor.constraint(equalTo: column.topAnchor),
                row.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            ])
        } else {
            footerContainer.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),
                row.topAnchor.constraint(equalTo: footerContainer.topAnchor),
                row.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor),
            ])
        }
        applyTheme(ThemeManager.shared.theme)
        return (confirmButton, cancelButton, deleteButton)
    }

    // MARK: Sizing

    /// Size the sheet to exactly what its content needs.
    ///
    /// `presentAsSheet` reads the root view's frame verbatim - it does not
    /// itself resize a sheet to fit Auto Layout content - so a hardcoded frame
    /// height leaves slack that the content stack's `.gravityAreas`
    /// distribution then injects into an arbitrary, sibling-dependent row (the
    /// bug `fm/grandline-task-editor-layout-fix` chased). Four of the six
    /// sheets shipped a literal height (320 / 400 / 420 / 620); none of them
    /// matched their real content.
    ///
    /// Call again from anything that shows or hides a real row.
    func sizeToFitContent() {
        guard !scrolls else { return }
        layoutSubtreeIfNeeded()
        let height = fittingSize.height
        guard height > 0 else { return }
        let size = NSSize(width: Self.width, height: height)
        if let window { window.setContentSize(size) } else { setFrameSize(size) }
    }

    /// Scroll the field column back to the top - for a scrolling sheet whose
    /// content was just rebuilt.
    func scrollToTop() {
        guard let scroll, let document = scroll.documentView else { return }
        layoutSubtreeIfNeeded()
        document.scroll(NSPoint(x: 0, y: 0))
    }

    // MARK: Theme

    override func layout() {
        super.layout()
        ribbonGradient.frame = ribbon.bounds
    }

    private func applyTheme(_ theme: HelmTheme) {
        // A plain `NSView` with no explicit fill paints nothing, so forcing an
        // appearance alone leaves the sheet showing its window's own default
        // (light) backing - three of the six editors had exactly that bug
        // (AGENTS.md gotcha #8).
        appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        // §6.10: the sheet's own ground is `card`, not the page's `paper` -
        // an editor is a floating surface, not a page. Every other palette
        // keeps `backgroundHex`, which is what the six sheets render today.
        layer?.backgroundColor = theme.isDaylight
            ? HelmTheme.nsColor(DaylightPalette.card).cgColor
            : HelmTheme.nsColor(theme.backgroundHex).cgColor
        // The ribbon shows only under Daylight, and `isHidden` alone is not
        // enough - an ordinary hidden `NSView`'s constraints still hold its
        // 6pt of layout (AGENTS.md gotcha (11)), which would leave a gap above
        // the heading in every other theme.
        ribbon.isHidden = !theme.isDaylight
        ribbonHeightConstraint?.constant = theme.isDaylight ? Self.ribbonHeight : 0
        let pair = domainHue.pair(in: theme)
        ribbonGradient.colors = [pair.h1.cgColor, pair.h2.cgColor]
        // §6.10's heading is the rounded display face at 20 heavy; the twelve
        // palettes keep `sectionTitle()`.
        headingLabel.font = theme.isDaylight
            ? HelmType.rounded(HelmType.scaled(20), .heavy)
            : HelmType.sectionTitle()
        headingLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        fieldHues.forEach { $0(domainHue) }
        footerDivider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(HelmCard.dividerAlpha).cgColor
        let muted = HelmTheme.mutedInk(theme)
        mutedLabels.forEach { $0.textColor = muted }
        fieldCards.forEach { $0.applyTheme(theme) }
        toggleRows.forEach { $0.applyTheme(theme) }
        let accent = HelmTheme.nsColor(theme.accentHex)
        sectionNumberChips.forEach { chip, label in
            chip.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
            label.textColor = accent
        }
        infoCards.forEach { card, icon, label in
            card.layer?.backgroundColor = accent.withAlphaComponent(0.07).cgColor
            card.layer?.borderWidth = 1
            card.layer?.borderColor = accent.withAlphaComponent(0.22).cgColor
            icon.contentTintColor = accent
            label.textColor = muted
        }
        onApplyTheme?(theme)
    }

    /// Re-run the sheet's own theming.
    ///
    /// `ThemeManager.observe` fires synchronously at registration, which for a
    /// scaffold happens before the caller has added a single row - so the
    /// first firing always finds empty registries. Every editor calls this once
    /// at the end of `loadView`, after everything exists. This is the fourth
    /// confirmed instance of that trap in this codebase (see `ThemeManager
    /// .swift`'s checklist); centralising it here is what stops a fifth.
    func refreshTheme() {
        applyTheme(ThemeManager.shared.theme)
    }

    // MARK: Probe / self-test surface

    /// What a sheet actually resolved to, for `HelmContrastSelfTest` and for a
    /// render probe - read rather than re-derived.
    struct Geometry {
        let width: CGFloat
        let sectionCount: Int
        let fieldCardCount: Int
        let toggleRowCount: Int
        let headingColor: NSColor?
        let backgroundColor: NSColor?
    }

    var geometry: Geometry {
        Geometry(width: bounds.width,
                 sectionCount: mutedLabels.count,
                 fieldCardCount: fieldCards.count,
                 toggleRowCount: toggleRows.count,
                 headingColor: headingLabel.textColor,
                 backgroundColor: layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear })
    }
}

// MARK: - HelmToggle (Daylight §6.9's pill toggle)

/// The app's one on/off control.
///
/// **Why this exists at all, and why it is not simply an `NSSwitch` restyle.**
/// The full-app UI audit measured `NSSwitch` as the one control in AppKit that
/// genuinely cannot be tinted - its header declares only `state`, and it
/// answers `false` to `setTintColor:` / `setContentTintColor:` /
/// `setAccentColor:` / `setFillColor:` / `setBezelColor:` (its runtime property
/// list does expose a private `trackColor`, deliberately unused here). So six
/// switches shipped in system chrome on a fully-themed page, and whether to
/// build a bespoke toggle was registered as a captain decision
/// (`grandline-full-ui-audit-decision-nsswitch-theming`) rather than silently
/// built. Daylight §6.9 answers that decision **for Daylight**: the
/// captain-approved prototype shows a custom pill, and states the recipe
/// (40x24 capsule, 18pt white knob with a small shadow, on = `ok` fill).
///
/// **Both controls are built and exactly one is shown per theme**, which is the
/// arrangement `HelmAccentRow` already uses for its gradient-vs-symbol badge.
/// That is what keeps the twelve pre-Daylight palettes byte-identical - the
/// registered decision above is still open for them, and answering it here
/// would be answering it for every captain rather than for the one palette
/// whose prototype the captain actually approved. It also means a theme switch
/// needs no rebuild: `applyTheme` swaps which of the two is visible.
///
/// `isOn` is the single source of truth; the `NSSwitch` is kept in step with
/// it rather than being consulted, so a caller never has to know which shape
/// is currently on screen.
final class HelmToggle: NSControl {

    /// §6.9's measurements.
    static let pillWidth: CGFloat = 40
    static let pillHeight: CGFloat = 24
    static let knobSide: CGFloat = 18
    /// The gap between the knob and the pill's edge, both ends - derived so
    /// the knob is vertically centred rather than positioned by a second
    /// literal.
    static var knobInset: CGFloat { (pillHeight - knobSide) / 2 }
    static let animationDuration: TimeInterval = 0.16

    /// Fired on any change the captain made - a click, a keyboard press, or a
    /// VoiceOver activation. Not fired by `isOn`'s setter, so a caller
    /// restoring persisted state (`refreshFromSettings`) cannot re-enter its
    /// own handler.
    var onToggle: (() -> Void)?

    var isOn: Bool = false {
        didSet {
            guard isOn != oldValue else { return }
            fallbackSwitch.state = isOn ? .on : .off
            applyToggleState(animated: true)
        }
    }

    /// The pre-Daylight shape, kept live so the twelve other palettes render
    /// exactly what they always did.
    private let fallbackSwitch = NSSwitch()
    private let pill = NSView()
    private let knob = NSView()
    private var knobLeading: NSLayoutConstraint!
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        fallbackSwitch.target = self
        fallbackSwitch.action = #selector(fallbackSwitchChanged)
        fallbackSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fallbackSwitch)

        pill.wantsLayer = true
        pill.layer?.cornerRadius = HelmMetrics.capsuleRadius(forHeight: Self.pillHeight)
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        knob.wantsLayer = true
        knob.layer?.cornerRadius = Self.knobSide / 2
        knob.layer?.backgroundColor = NSColor.white.cgColor
        // §6.9's "knob 18pt white with a small shadow". Drawn on the knob's own
        // layer rather than by `HelmCard.elevation`, which is the page-level
        // depth system - this is an 18pt dot, not a floating card.
        knob.layer?.shadowColor = HelmTheme.nsColor(DaylightPalette.shadowInk).cgColor
        knob.layer?.shadowOpacity = 0.28
        knob.layer?.shadowRadius = 2
        knob.layer?.shadowOffset = CGSize(width: 0, height: -1)
        knob.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(knob)

        knobLeading = knob.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: Self.knobInset)
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: Self.pillWidth),
            pill.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            knob.widthAnchor.constraint(equalToConstant: Self.knobSide),
            knob.heightAnchor.constraint(equalToConstant: Self.knobSide),
            knob.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            knobLeading,
            // The fallback sits in the same box. It is smaller than the pill,
            // so it is centred rather than pinned - the row around it measures
            // one control either way.
            fallbackSwitch.centerXAnchor.constraint(equalTo: centerXAnchor),
            fallbackSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(pillClicked))
        pill.addGestureRecognizer(click)

        applyTheme(theme)
    }

    @objc private func fallbackSwitchChanged() {
        setOnFromUser(fallbackSwitch.state == .on)
    }

    @objc private func pillClicked() {
        setOnFromUser(!isOn)
    }

    private func setOnFromUser(_ value: Bool) {
        guard isEnabled else { return }
        isOn = value
        onToggle?()
        // Keeps a caller that wired `target`/`action` instead of `onToggle`
        // working, exactly as `NSSwitch` would have.
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override var isEnabled: Bool {
        didSet {
            fallbackSwitch.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.5
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let daylight = theme.isDaylight
        pill.isHidden = !daylight
        fallbackSwitch.isHidden = daylight
        applyToggleState(animated: false)
    }

    private func applyToggleState(animated: Bool) {
        let onFill = HelmTheme.nsColor(theme.isDaylight
                                       ? DaylightPalette.ok
                                       : HelmTint.good.hex(in: theme))
        let offFill = HelmField.fill(theme)
        let offBorder = HelmField.border(theme)
        let target = isOn ? Self.pillWidth - Self.knobSide - Self.knobInset : Self.knobInset

        // GL-16: a decorative slide is real motion, so it is skipped outright
        // under Reduce Motion - the colour and position still change, just
        // without the animation.
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            // `constant` is set **synchronously** inside the group, with
            // `allowsImplicitAnimation` doing the animating - deliberately not
            // `knobLeading.animator().constant`, which defers the write to the
            // animator and leaves the real constraint at its old value until a
            // run loop turn. That difference is invisible in the app and fatal
            // to a headless test, which never turns one.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animationDuration
                ctx.allowsImplicitAnimation = true
                knobLeading.constant = target
                pill.layoutSubtreeIfNeeded()
            }
        } else {
            knobLeading.constant = target
        }
        pill.layer?.backgroundColor = (isOn ? onFill : offFill).cgColor
        pill.layer?.borderWidth = isOn ? 0 : HelmField.hairlineBorderWidth
        pill.layer?.borderColor = offBorder.cgColor
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        setOnFromUser(!isOn)
        return true
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    struct Geometry {
        let showsPill: Bool
        let showsFallbackSwitch: Bool
        let pillSize: CGSize
        let pillRadius: CGFloat
        let knobSide: CGFloat
        let knobLeading: CGFloat
        let pillFill: NSColor?
    }

    var debugGeometry: Geometry {
        Geometry(showsPill: !pill.isHidden,
                 showsFallbackSwitch: !fallbackSwitch.isHidden,
                 pillSize: CGSize(width: Self.pillWidth, height: Self.pillHeight),
                 pillRadius: pill.layer?.cornerRadius ?? 0,
                 knobSide: Self.knobSide,
                 knobLeading: knobLeading.constant,
                 pillFill: pill.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
    }
    #endif
}
