import UIKit

/// An action from a menu, under way (#1775): block, follow, report — nothing
/// on screen is left to wear a busy state once the menu has gone, and the
/// answer could take seconds with no word. Past the loader's grace its
/// loading toast says so ("Blocking @ava…"); the answer replaces it in place
/// (one `id`). An answer within the grace shows alone, so a fast action
/// never flashes a spinner.
///
/// ⚠️ EVERY PATH ENDS IN `succeed` / `undoable` / `fail` / `warn` / `end`: a loading
/// toast has no timer of its own (`Feedback.loading`).
@MainActor
public final class PendingFeedback {
    /// The toasts' shared identity: the answer takes the loading toast's place.
    public let id = "pending-" + UUID().uuidString
    private weak var source: UIViewController?
    private let position: ToastPosition
    private var loading: ToastView?
    private var isDone = false

    public init(
        _ message: String, from source: UIViewController, at position: ToastPosition = .bottom,
        clock: LoadingClock = .system
    ) {
        self.source = source
        self.position = position
        clock.after(LoadingTiming.loaderGrace) { [weak self] in
            guard let self, !isDone, let source = self.source else { return }
            loading = Feedback.loading(message, id: id, from: source, at: position)
        }
    }

    /// Whether the loading toast is up. Tests.
    public var isShowingLoading: Bool { loading != nil && !isDone }

    @discardableResult
    public func succeed(
        _ message: String, symbol: String? = Feedback.Kind.success.defaultSymbol, action: ToastView.Action? = nil
    ) -> ToastView? {
        finish { source in Feedback.success(message, symbol: symbol, from: source, at: position, action: action, id: id) }
    }

    @discardableResult
    public func undoable(
        _ message: String, symbol: String? = Feedback.Kind.success.defaultSymbol,
        commit: @escaping @MainActor () -> Void, undo: @escaping @MainActor () -> Void
    ) -> ToastView? {
        finish { source in
            Feedback.undoable(message, symbol: symbol, from: source, at: position, id: id, commit: commit, undo: undo)
        }
    }

    @discardableResult
    public func fail(_ message: String) -> ToastView? {
        finish { source in Feedback.failure(message, from: source, at: position, id: id) }
    }

    @discardableResult
    public func warn(_ message: String) -> ToastView? {
        finish { source in Feedback.warning(message, from: source, at: position, id: id) }
    }

    /// Ends with no word: the loading toast leaves.
    public func end() {
        guard !isDone else { return }
        isDone = true
        loading?.dismiss(animated: true)
    }

    private func finish(_ show: (UIViewController) -> ToastView) -> ToastView? {
        guard !isDone else { return nil }
        isDone = true
        guard let source else {
            // The screen is gone: nothing to say it over, and the loading
            // toast must not stay.
            loading?.dismiss(animated: true)
            return nil
        }
        return show(source)
    }
}
