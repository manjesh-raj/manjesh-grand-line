// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-badge-fixes`: the context/namespace badge's own per-tab
// display state, and how the toolbar toggle that shows it looks in each
// state - the direct counterpart of `SRELeadPhase.swift` for this feature.
//
// Before this task the badge was a plain, non-interactive `ToolRowLayout.pill`
// that only ever existed at all (hidden vs. shown) - there was no toggle to
// click, because activation happened automatically for every tab of an
// opted-in host (see `KubeContextBridge.swift`'s header, issue 3). Now that
// activating the badge is an explicit per-tab action, the toolbar control
// needs a real four-state display exactly like `SRELeadPhase` already gives
// SRE Lead's own toolbar button - so this mirrors that file's shape rather
// than inventing a second one.

import AppKit

/// Where one tab's context/namespace safety badge currently is.
///
/// Stored on `TabModel.kubeContextBadgeStatus`, and only ever leaves
/// `.notStarted` when the captain explicitly activates the toolbar toggle for
/// that specific tab (`ConsoleController.activateKubeContextBadge`) - a
/// freshly opened or duplicated tab always starts here, never inheriting a
/// sibling tab's state.
enum KubeContextBadgeStatus: Equatable {
    /// Never activated for this tab, or explicitly turned back off again.
    case notStarted
    /// Activated: the first attempt (or a post-give-up manual retry) hasn't
    /// produced a result yet, or the bridge is in the middle of a short run
    /// of retries before either succeeding or giving up - see
    /// `KubeContextBridge`'s own backoff/give-up mechanism. Deliberately not
    /// re-shown on every later *background* refresh once a context is
    /// already known - see `active`'s own doc comment.
    case checking
    /// The most recently *successful* refresh. A later transient failure (a
    /// busy refusal, or a real command failure that hasn't yet reached the
    /// give-up threshold) leaves this showing rather than reverting to
    /// `.checking` - the badge never re-announces "checking" for a routine
    /// background poll, and never blanks a known-good answer over a refusal
    /// that might resolve on its own.
    case active(KubeContextInfo)
    /// `KubeContextBridge` gave up after `maxConsecutiveFailures` real,
    /// consecutive command failures (e.g. `kubectl` not on PATH) and stopped
    /// scheduling any further automatic retry - the fix for issue 1
    /// (`fm/grandline-k8s-badge-fixes`): a tab that can never succeed no
    /// longer gets hammered with the same failing command forever. The
    /// captain's own click reactivates it (`ConsoleController.
    /// activateKubeContextBadge`, the exact same call as first-time
    /// activation), which resets the failure count and tries again. Carries
    /// the last failure's own message for the tooltip.
    case unavailable(String)
}

extension KubeContextBadgeStatus {
    /// The glyph for this state - all three names were already proven valid
    /// elsewhere in this app before being reused here (`AGENTS.md`'s own
    /// warning that `NSImage(systemSymbolName:)` fails silently, so a name is
    /// never guessed at). `.active` gets the filled shield regardless of the
    /// production heuristic - `buttonTint` carries that distinction, not the
    /// glyph, matching `SRELeadPhase.symbol`'s own reasoning for why `.ready`
    /// is filled and every other state is outlined.
    var buttonSymbol: String {
        switch self {
        case .notStarted, .checking: return "checkmark.shield"
        case .active: return "checkmark.shield.fill"
        case .unavailable: return "shield.slash"
        }
    }

    var buttonTitle: String {
        switch self {
        case .notStarted: return "Check Context"
        case .checking: return "Checking\u{2026}"
        case .active(let info): return "\u{2388} \(info.shortLabel)"
        case .unavailable: return "Context Unavailable"
        }
    }

    /// `nil` for `.notStarted`, matching `SRELeadPhase.tint`'s own reasoning:
    /// the idle default should read at the same weight as its toolbar
    /// siblings, not quieter for sitting unactivated. `.checking` borrows
    /// SRE Lead's `.starting` tint (`.warn`) for the same "working,
    /// transient" reason. `.unavailable` is `.warn` too, deliberately never
    /// `.critical` - `.critical` is reserved for the one signal that actually
    /// matters most here, `KubeContextInfo.looksLikeProduction` - conflating
    /// "this badge is broken" with "you're on/near production" would blur
    /// the one distinction a safety badge exists to make unambiguous.
    var buttonTint: HelmTint? {
        switch self {
        case .notStarted: return nil
        case .checking: return .warn
        case .active(let info): return info.looksLikeProduction ? .critical : .neutral
        case .unavailable: return .warn
        }
    }

    /// The full detail - always includes the complete, never-shortened
    /// context name, so nothing `buttonTitle`'s short label leaves out is
    /// ever actually lost.
    var tooltip: String {
        switch self {
        case .notStarted:
            return "Kubernetes context/namespace safety badge - click to start checking this tab."
        case .checking:
            return "Checking the current kubectl context on this tab\u{2026}"
        case .active(let info):
            var text = "Kubernetes context: \(info.contextName)\nNamespace: \(info.namespace)"
            // Issue 4 (confirmed correct, unchanged): a case-insensitive
            // substring match on "prod" - stated explicitly here in both
            // directions, per the task's own optional ask, rather than left
            // implicit.
            if info.looksLikeProduction {
                text += "\n\n\u{26A0}\u{FE0F} This context's name matches a simple \u{201C}prod\u{201D} pattern - a heuristic, not a guarantee. Double-check before running anything destructive."
            } else {
                text += "\n\nNo \u{201C}prod\u{201D} pattern matched in the context name - not flagged."
            }
            text += "\n\nClick to stop checking this tab."
            return text
        case .unavailable(let message):
            return "Couldn't determine the kubectl context after several attempts (\(message)). Not retrying automatically - click to try again."
        }
    }
}
