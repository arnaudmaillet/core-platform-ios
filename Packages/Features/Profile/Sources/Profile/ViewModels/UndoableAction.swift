import Foundation

/// An action the viewer can still take back (#957), as a view model hands it
/// to its screen: the one line the undo toast shows, and the two ends of it —
/// `commit` when the countdown runs out (or the toast leaves any other way),
/// `undo` when the viewer taps Undo. Exactly one of them runs, once
/// (`Feedback.undoable`, #954).
///
/// ⚠️ `commit` MUST NOT NEED THE SCREEN. The toast is the scene's: it outlives
/// a pop, and a deferred commit still has to reach the server when the
/// screen — and its view model — are gone. Commits hold what they send
/// strongly and their view model weakly.
@MainActor
struct UndoableAction {
    let message: String
    let symbol: String
    let commit: @MainActor () -> Void
    let undo: @MainActor () -> Void
}
