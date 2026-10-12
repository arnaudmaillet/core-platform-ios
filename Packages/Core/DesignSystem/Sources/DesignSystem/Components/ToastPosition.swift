import UIKit

/// Where a toast sits on screen (#954): one of six places, the top or bottom
/// edge × leading, centre or trailing. Leading and trailing follow the layout
/// direction, so a right-to-left language mirrors them.
///
/// - **Top** positions sit under the status bar and the Dynamic Island (the
///   window's top safe area).
/// - **Bottom** positions sit above whatever is lowest on screen: the
///   keyboard, the tab bar, a toolbar, the tab accessory, or a screen's own
///   floor such as a composer (`Feedback`'s `above:`).
///
/// `.bottom` is every existing call site's place, and the default.
public enum ToastPosition: Int, CaseIterable, Sendable {
    case topLeading
    case top
    case topTrailing
    case bottomLeading
    case bottom
    case bottomTrailing

    /// Whether the toast hangs from the top edge rather than stands on the
    /// bottom one.
    public var isTop: Bool {
        switch self {
        case .topLeading, .top, .topTrailing: true
        case .bottomLeading, .bottom, .bottomTrailing: false
        }
    }

    /// The toast's alignment along its edge.
    public enum Alignment: Sendable {
        case leading, center, trailing
    }

    public var alignment: Alignment {
        switch self {
        case .topLeading, .bottomLeading: .leading
        case .top, .bottom: .center
        case .topTrailing, .bottomTrailing: .trailing
        }
    }
}
