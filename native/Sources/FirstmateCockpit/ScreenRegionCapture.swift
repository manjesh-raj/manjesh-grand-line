// Manjesh Grand Line - native macOS app.
//
// F15 of full review #3 §8: "Capture region -> Whiteboard (Excalidraw already
// draws on images), annotate, copy."
//
// This file is the *capture* half only - how a region of the screen becomes an
// `NSImage` in this process. `WhiteboardCaptureScene.swift` turns that image
// into a board, and `WhiteboardController` owns the buttons.
//
// # Why `screencapture`, and not ScreenCaptureKit
//
// ScreenCaptureKit is the modern API and it is the wrong one here, for two
// reasons that are about this app rather than about the framework:
//
//   1. **It has no region picker.** SCK captures a display, a window or an
//      application - a *rectangle the captain drags* is not one of its inputs,
//      so choosing it would mean building the selection overlay (a full-screen
//      borderless window per display, a crosshair cursor, the live dimension
//      readout, Escape to cancel, Space to switch to window mode) and then
//      maintaining a worse copy of something every Mac user already has in
//      muscle memory.
//   2. **It needs Screen Recording permission, and `screencapture -i` does
//      not.** SCK's content list is TCC-gated: a first call puts up the system
//      prompt, and a denial leaves the feature permanently dead until the
//      captain finds the Privacy pane. `/usr/sbin/screencapture` in
//      *interactive* mode is the system's own capture agent doing the capture
//      on the captain's explicit drag, so the app never holds the capability
//      at all. For an app that carries a credential vault, not acquiring a
//      standing "read every pixel on this screen" grant is the better posture,
//      not merely the cheaper one.
//
// The cost of the choice, stated: no capture without the captain present (this
// cannot be scripted or scheduled), and the shutter is the system's rather
// than ours. Both are fine for the feature the report asked for.
//
// # The pasteboard, not a file
//
// `-c` sends the capture to the pasteboard, so the unredacted original is
// never written to disk by this app - which is the promise the captain's own
// reviewed mockup prints in the Whiteboard's footer, and the reason it is a
// real promise rather than a slogan. It also means the intake path is the one
// this app already had: `ShiftImageAttachmentWell.image(fromPasteboard:)`, the
// same function the task editor's screenshot paste has used since
// `grandline-shift-task-image-attachments`. There is no second "how do we get
// an image out of a pasteboard" here.
//
// Two consequences, both deliberate:
//
//   - The general pasteboard is clobbered by a capture. That matches what
//     `⌃⇧⌘4` does system-wide, and the flow's own last step ("Copy image")
//     overwrites it again anyway.
//   - The capture never reaches the clipboard history. `ClipboardHistoryStore.
//     record(from:)` only ever records `.string`, so an image write is
//     `.nothingToRecord` - asserted by `ScreenRegionCaptureSelfTest` rather
//     than assumed, because "a screenshot of a token silently landed in an
//     on-disk history" is exactly the failure this app cannot have.
//
// # Cancel is not failure
//
// Pressing Escape during the drag is the commonest outcome after a
// misjudged start, and `screencapture` exits **0** for it - so the exit status
// alone cannot tell "captured" from "cancelled". What distinguishes them is
// that a cancelled capture writes nothing, which is what
// `NSPasteboard.changeCount` measures. `Outcome.decide` is that rule, kept as
// a pure function so the three-way decision is testable without a screen.

import AppKit
import Foundation

enum ScreenRegionCapture {

    /// What one capture attempt came to.
    enum Outcome: Equatable {
        /// The captain dragged a region and it landed on the pasteboard.
        case captured
        /// The captain pressed Escape, or dragged a zero-size region.
        case cancelled
        /// `screencapture` could not run, was killed, or exited non-zero.
        case failed(String)
    }

    /// The real tool. Absolute, not resolved through `PATH`: this is a system
    /// binary at a fixed location and a `PATH` lookup would be a way for a
    /// shadowing copy earlier in `PATH` to be handed the captain's screen.
    static let executable = "/usr/sbin/screencapture"

    /// The argv, as one reviewable constant.
    ///
    /// - `-i` interactive region selection - the whole point.
    /// - `-c` to the pasteboard, so nothing unredacted is written to disk.
    /// - `-o` no window shadow, for the Space-to-pick-a-window mode the system
    ///   picker offers mid-drag: a shadow is transparent padding that makes the
    ///   placed image's bounds disagree with what was selected.
    /// - `-t png` lossless, and the format Excalidraw stores a file in.
    ///
    /// The shutter sound is deliberately **not** suppressed (`-x`): it is the
    /// system's own confirmation that a capture happened, and a silent one
    /// leaves the captain unsure whether the drag registered.
    static let arguments = ["-i", "-c", "-o", "-t", "png"]

    /// How long the captain has to make the selection before the run is
    /// abandoned. Generous on purpose - this is a bound (GL-02), not a
    /// deadline: the drag is human-paced and a captain who is deciding where
    /// to start is not a hung child.
    static let selectionTimeout: TimeInterval = 300

    // MARK: The decision

    /// The pure three-way rule, with no screen and no subprocess in it.
    ///
    /// - Parameters:
    ///   - outcome: what `Subprocess` said happened to the child.
    ///   - status: the child's exit status.
    ///   - stderr: its trimmed stderr, used only to make a failure legible.
    ///   - pasteboardChanged: did `NSPasteboard.changeCount` move across the
    ///     run? This is the only thing that separates a cancel from a capture,
    ///     because `screencapture -i` exits 0 for both.
    static func decide(outcome: SubprocessResult.Outcome,
                       status: Int32,
                       stderr: String,
                       pasteboardChanged: Bool) -> Outcome {
        switch outcome {
        case .launchFailed:
            return .failed("macOS's screencapture tool could not be started" + suffix(stderr))
        case .timedOut:
            return .failed("The capture was still waiting for a selection after "
                           + "\(Int(selectionTimeout / 60)) minutes, so it was cancelled.")
        case .exited:
            guard status == 0 else {
                return .failed("macOS's screencapture tool exited with status \(status)" + suffix(stderr))
            }
            return pasteboardChanged ? .captured : .cancelled
        }
    }

    private static func suffix(_ stderr: String) -> String {
        stderr.isEmpty ? "." : " - \(stderr)"
    }

    // MARK: Running it

    /// What a caller gets back: the decision, and the image when there is one.
    struct Result {
        let outcome: Outcome
        /// Non-nil only for `.captured`, and only when the pasteboard really
        /// held an image afterwards. A `.captured` with no image is reported
        /// as a failure by `capture(...)` rather than handed on as a success
        /// with nothing in it.
        let image: NSImage?
    }

    /// The seam every test uses: run the tool, hand back what `Subprocess`
    /// would have. Defaults to the real thing.
    typealias Runner = (_ completion: @escaping (SubprocessResult) -> Void) -> Void

    static let systemRunner: Runner = { completion in
        // GL-04: `runAsync`, because the caller is the main thread and the
        // child blocks for as long as the captain takes to drag.
        Subprocess.runAsync(executable: executable,
                            arguments: arguments,
                            timeout: selectionTimeout,
                            log: AppLog.subprocess,
                            completion: completion)
    }

    /// Capture a region, then read it back off the pasteboard.
    ///
    /// `completion` is called on the main thread exactly once.
    static func capture(runner: @escaping Runner = systemRunner,
                        pasteboard: NSPasteboard = .general,
                        completion: @escaping (Result) -> Void) {
        let before = pasteboard.changeCount
        runner { result in
            let changed = pasteboard.changeCount != before
            let outcome = decide(outcome: result.outcome,
                                 status: result.status,
                                 stderr: result.stderr,
                                 pasteboardChanged: changed)
            guard case .captured = outcome else {
                completion(Result(outcome: outcome, image: nil))
                return
            }
            // The one intake path this app already had, reused rather than
            // rewritten (see this file's header).
            guard let image = ShiftImageAttachmentWell.image(fromPasteboard: pasteboard) else {
                completion(Result(
                    outcome: .failed("The capture finished but nothing usable reached the clipboard."),
                    image: nil))
                return
            }
            completion(Result(outcome: .captured, image: image))
        }
    }
}
