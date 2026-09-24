import Foundation

/// The four states every screen in this app spells for what it shows
/// (charter P11): waiting, showing, nothing to show, could not show.
///
/// ⚠️ **SIXTEEN VIEW MODELS DECLARED THIS ENUM BEFORE IT EXISTED**, each as
/// its own `Phase` with the same four cases and the same `failed(message:)`
/// payload, and a screen without an `.empty` or a `.failed` rendering was
/// simply one whose author had not copied all four. Declaring the shape once
/// makes the missing case a compile error in the screen's `switch`, and lets
/// a container, a test or a probe reason about any screen's phase without
/// knowing which screen it is.
///
/// A view model adopts it as `public typealias Phase = Loadable<Content>`;
/// every `switch` over `.loading / .content / .empty / .failed` reads as
/// before. It is adopted screen by screen as each is touched, never in one
/// sweep — the charter's last PR, on purpose.
public enum Loadable<Content: Equatable & Sendable>: Equatable, Sendable {
    /// Nothing yet: the screen wears its skeleton (P8).
    case loading
    /// What the screen is for.
    case content(Content)
    /// Loaded, and there was nothing — a state, not an error.
    case empty
    /// Could not load; `message` is what the screen says.
    case failed(message: String)

    /// The content, when there is some.
    public var content: Content? {
        if case .content(let content) = self { return content }
        return nil
    }

    /// True while the screen has nothing of its own to show and is waiting.
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
