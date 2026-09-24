// Grand Line - native macOS app.
//
// F21's outer shell: the five `AppIntent` types Siri, Shortcuts, Spotlight
// and Raycast see, and the `AppShortcutsProvider` that gives them spoken
// phrases. Every one of them is a parameter list plus one call into
// `GrandLineIntentActions`, which is where the behaviour, the gating and the
// tests are. Nothing in this file decides anything.
//
// ## What makes an intent actually appear in Shortcuts
//
// Worth stating plainly, because it is the one part of F21 that is not code:
// **these types compile into the binary, but Shortcuts discovers them from a
// `Metadata.appintents` bundle**, produced by `appintentsmetadataprocessor`.
// SwiftPM does not run that tool - it is an Xcode build phase - and this
// project builds with `swift build` and Command Line Tools by design
// (AGENTS.md's "Build, run, test").
//
// So `native/build_native_app.sh` runs the processor itself when it can find
// it, as one guarded step while assembling the `.app`, and says so loudly
// when it cannot. That keeps the *build* Xcode-free, which is the invariant
// that matters, while letting the packaged app register its actions on a
// machine that has Xcode installed. A `.app` built without it is not broken -
// it simply has no Shortcuts actions, and the Settings card says which of
// those two states this copy is in rather than claiming five working
// intents.
//
// ## Two shapes used throughout
//
//   - **`openAppWhenRun = false`.** The whole value of F21 is running without
//     raising the window, which is what the mockup's own footnote says
//     ("Runs without raising the window"). The app is still launched if it is
//     not running - the system does that to host `perform()` - but it is not
//     brought forward.
//   - **Every `perform()` hops to the main actor** through
//     `GrandLineIntentBridge`, because every store an action touches is
//     main-thread-only by contract. Annotating the intent types `@MainActor`
//     instead reads better and is not available: it makes the `AppIntent`
//     conformance itself cross an actor boundary, the compiler warns, and
//     GL-07 fails this build on any warning.
//
// ## Copy Credential returns no value
//
// `CopyCredentialIntent` deliberately returns `ProvidesDialog` and nothing
// else - no `ReturnsValue<String>`, no `IntentFile`. Read
// `GrandLineIntentActions`'s header before changing that: an intent that
// handed a vault secret back as a shortcut variable would make every shortcut
// on the machine a vault exfiltration path. The secret goes on the clipboard,
// concealed and auto-clearing, exactly as the Poneglyph page's own Copy
// button puts it there.

import AppIntents
import Foundation

// MARK: - Shared plumbing

@available(macOS 13.0, *)
enum GrandLineIntentBridge {

    /// Turns an action's `Result` into what an intent must throw or return.
    ///
    /// `IntentActionError` is a `LocalizedError`, which is what Shortcuts
    /// renders, so nothing here rewrites a message - the action already said
    /// the useful thing.
    static func value(_ result: Result<IntentActionResult, IntentActionError>) throws -> IntentActionResult {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    /// Run a synchronous action on the main actor and unwrap it.
    ///
    /// Every store an action touches is main-thread-only by contract, and
    /// `perform()` is not main-isolated - annotating the intent types
    /// `@MainActor` instead looks tidier and is not available here: it makes
    /// the `AppIntent` conformance itself cross an actor boundary, which the
    /// compiler warns about, and GL-07 fails this build on any warning.
    static func onMain(_ body: @escaping @MainActor () -> Result<IntentActionResult, IntentActionError>) async throws -> IntentActionResult {
        let result = await MainActor.run { body() }
        return try value(result)
    }

    /// The completion-handler actions, bridged to `async`.
    ///
    /// `withCheckedThrowingContinuation` traps if its continuation is resumed
    /// twice or never - which is exactly why `GrandLineIntentActions`
    /// documents "main thread, exactly once, on every path" as a contract
    /// rather than a habit, and why both callbacks below funnel through one
    /// `finish` in that file.
    static func awaitAction(_ run: @escaping @MainActor (@escaping (Result<IntentActionResult, IntentActionError>) -> Void) -> Void) async throws -> IntentActionResult {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                run { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

/// The three priorities, as something a shortcut can pick from a menu.
@available(macOS 13.0, *)
enum TaskPriorityAppValue: String, AppEnum {
    case low, normal, high

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Priority" }
    static var caseDisplayRepresentations: [TaskPriorityAppValue: DisplayRepresentation] {
        [.low: "Low", .normal: "Normal", .high: "High"]
    }

    var shiftPriority: ShiftPriority {
        switch self {
        case .low: return .low
        case .normal: return .normal
        case .high: return .high
        }
    }
}

// MARK: - New Task

@available(macOS 13.0, *)
struct GrandLineNewTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "New Task"
    static var description = IntentDescription(
        "Add a task to Grand Line. The due date understands the same phrases quick capture does - \"tomorrow\", \"friday 3pm\".",
        categoryName: "Tasks")
    static var openAppWhenRun = false

    @Parameter(title: "Title", requestValueDialog: "What's the task?")
    var taskTitle: String

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "Due", description: "A phrase like \"tomorrow\" or \"friday 3pm\". Ignored if it isn't understood.")
    var due: String?

    @Parameter(title: "Priority", default: .normal)
    var priority: TaskPriorityAppValue?

    @Parameter(title: "Project", description: "Matched by name against your projects. Ignored if there's no such project.")
    var project: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add task \(\.$taskTitle) to Grand Line") {
            \.$due
            \.$priority
            \.$project
            \.$notes
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await GrandLineIntentBridge.onMain {
            GrandLineIntentActions.newTask(title: taskTitle,
                notes: notes,
                dueDateText: due,
                priority: (priority ?? .normal).shiftPriority,
                projectName: project,
                store: GrandLineServices.shared.shiftStore)
        }
        return .result(dialog: IntentDialog(stringLiteral: result.message))
    }
}

// MARK: - New Note

@available(macOS 13.0, *)
struct GrandLineNewNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "New Note"
    static var description = IntentDescription(
        "Append a line to a Notebook page. With no page named it goes onto today's daily note.",
        categoryName: "Notebook")
    static var openAppWhenRun = false

    @Parameter(title: "Text", requestValueDialog: "What should I note down?")
    var text: String

    @Parameter(title: "Page", description: "A page title. Created if it doesn't exist; appended to if it does. Leave empty for today's note.")
    var page: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Note \(\.$text) in Grand Line") {
            \.$page
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await GrandLineIntentBridge.onMain {
            GrandLineIntentActions.newNote(text: text,
                pageTitle: page,
                store: GrandLineServices.shared.notebookStore)
        }
        return .result(dialog: IntentDialog(stringLiteral: result.message))
    }
}

// MARK: - Start Focus Timer

@available(macOS 13.0, *)
struct GrandLineStartFocusTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Focus Timer"
    static var description = IntentDescription(
        "Start Grand Line's focus timer on a task. With no task named it picks the one due soonest.",
        categoryName: "Tasks")
    static var openAppWhenRun = false

    @Parameter(title: "Task", description: "Matched against your open tasks by name. Leave empty for the one due soonest.")
    var task: String?

    @Parameter(title: "Minutes", default: 25, controlStyle: .field, inclusiveRange: (1, 240))
    var minutes: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Focus on \(\.$task) for \(\.$minutes) minutes")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await GrandLineIntentBridge.onMain {
            GrandLineIntentActions.startFocusTimer(taskQuery: task,
                        minutes: minutes,
                        store: GrandLineServices.shared.shiftStore,
                        timer: GrandLineServices.shared.focusTimer)
        }
        return .result(dialog: IntentDialog(stringLiteral: result.message))
    }
}

// MARK: - Copy Credential

/// Puts a Poneglyph credential on the clipboard behind the vault's own
/// authentication - and returns nothing but a confirmation. See this file's
/// header and `GrandLineIntentActions`'s.
@available(macOS 13.0, *)
struct GrandLineCopyCredentialIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Credential"
    static var description = IntentDescription(
        "Copy a Poneglyph credential to the clipboard. Always goes through the vault's own unlock, and never hands the secret back to the shortcut - it only ever lands on the clipboard, concealed, and clears itself.",
        categoryName: "Poneglyph")
    static var openAppWhenRun = false
    /// The one intent here that says so. A shortcut that copies a secret
    /// should not be silently runnable from a locked screen or a widget tap
    /// with no acknowledgement; this is the system's own affordance for that,
    /// and it costs one tap on the path that most deserves one.
    static var isDiscoverable = true

    @Parameter(title: "Name", requestValueDialog: "Which credential?")
    var credentialName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Copy \(\.$credentialName) from the Grand Line vault")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // `GrandLineServices.vault` builds the store on first use, which is
        // correct here: an intent may be the first thing that touches the
        // vault after a launch, and asking a store that does not exist yet
        // whether it is unlocked would answer "no" for the wrong reason.
        let name = credentialName
        let result = try await GrandLineIntentBridge.awaitAction { completion in
            GrandLineIntentActions.copyCredential(title: name,
                                                  vault: GrandLineServices.shared.vault,
                                                  completion: completion)
        }
        return .result(dialog: IntentDialog(stringLiteral: result.message))
    }
}

// MARK: - Ask the Crew

@available(macOS 13.0, *)
struct GrandLineAskCrewIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask the Crew"
    static var description = IntentDescription(
        "Put one question to the Straw Hat crew and get the answer back as text.",
        categoryName: "Crew")
    static var openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What should I ask the crew?")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask the Grand Line crew \(\.$prompt)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let question = prompt
        let result = try await GrandLineIntentBridge.awaitAction { completion in
            GrandLineIntentActions.askCrew(prompt: question, completion: completion)
        }
        let answer = result.text ?? ""
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer.isEmpty ? result.message : answer))
    }
}

// MARK: - The spoken phrases

/// What Siri listens for, and what Spotlight offers.
///
/// `\(.applicationName)` is required in every phrase - App Intents refuses a
/// phrase without it, deliberately, so a spoken command can never be
/// ambiguous between two apps.
@available(macOS 13.0, *)
struct GrandLineAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GrandLineNewTaskIntent(),
                    phrases: ["New task in \(.applicationName)",
                              "Add a task to \(.applicationName)"],
                    shortTitle: "New Task",
                    systemImageName: "checkmark.circle")
        AppShortcut(intent: GrandLineNewNoteIntent(),
                    phrases: ["New note in \(.applicationName)",
                              "Note this in \(.applicationName)"],
                    shortTitle: "New Note",
                    systemImageName: "note.text")
        AppShortcut(intent: GrandLineStartFocusTimerIntent(),
                    phrases: ["Start a focus timer in \(.applicationName)",
                              "Focus with \(.applicationName)"],
                    shortTitle: "Start Focus Timer",
                    systemImageName: "timer")
        AppShortcut(intent: GrandLineCopyCredentialIntent(),
                    phrases: ["Copy a credential from \(.applicationName)"],
                    shortTitle: "Copy Credential",
                    systemImageName: "key.fill")
        AppShortcut(intent: GrandLineAskCrewIntent(),
                    phrases: ["Ask the \(.applicationName) crew"],
                    shortTitle: "Ask the Crew",
                    systemImageName: "person.2.fill")
    }
}

// MARK: - What the Settings card lists

/// The five actions as plain data, so `SettingsController`'s "Shortcuts &
/// Siri" card renders the real list rather than five hardcoded rows that can
/// drift from the intents above.
///
/// It is still a hand-maintained table - App Intents exposes no runtime
/// enumeration of an app's own intents - so `AppIntentActionsSelfTest` asserts
/// it has one entry per `AppIntent` type in this file, by grepping the source.
/// That is the only thing standing between "we added a sixth intent" and a
/// Settings card that quietly still says five.
struct GrandLineIntentCatalogEntry {
    var title: String
    var parameters: String
    var symbol: String
    var tint: HelmTint
    /// Set for Copy Credential, and nothing else. The card renders it as the
    /// mockup's "guarded" chip - the one row whose behaviour a captain needs
    /// to know before they wire it into a shortcut.
    var guardNote: String?
}

enum GrandLineIntentCatalog {
    static let entries: [GrandLineIntentCatalogEntry] = [
        .init(title: "New Task",
              parameters: "title \u{00B7} due date \u{00B7} priority \u{00B7} project \u{00B7} notes",
              symbol: "checkmark.circle", tint: .violet, guardNote: nil),
        .init(title: "New Note",
              parameters: "text \u{00B7} page (defaults to today's note, appends rather than replaces)",
              symbol: "note.text", tint: .info, guardNote: nil),
        .init(title: "Start Focus Timer",
              parameters: "task \u{00B7} minutes (defaults to the task due soonest, 25 minutes)",
              symbol: "timer", tint: .accent, guardNote: nil),
        .init(title: "Copy Credential",
              parameters: "name \u{00B7} always goes through the vault's own unlock, and never returns the secret to the shortcut - it lands on the clipboard concealed, and clears itself",
              symbol: "key.fill", tint: .warn, guardNote: "guarded"),
        .init(title: "Ask the Crew",
              parameters: "question \u{00B7} returns the reply as text",
              symbol: "person.2.fill", tint: .good, guardNote: nil),
    ]
}
