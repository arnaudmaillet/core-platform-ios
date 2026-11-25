import DesignSystem

/// What the "+" offers (`CreateBarItem`), in menu order: the three ways to
/// make a post, and "New Channel" after Text Post with the channels on
/// (#2230). Every one is PRESENTED over the shell by the app, never pushed:
/// making a post belongs to no tab.
public enum CreateDestination: String, CaseIterable, Sendable {
    case camera
    case upload
    case text
    /// "New Channel" (#2230): a channel addresses an audience — it is shown
    /// in the feed and on the map (#2216) — so it is made where posts are. A
    /// group stays out: writing to several people is a conversation, not a
    /// publication.
    case channel

    /// The menu's entries, in order. Without the channels, the menu is as it
    /// was before the epic.
    public static func offered(channels: Bool) -> [CreateDestination] {
        allCases.filter { $0 != .channel || channels }
    }

    /// The row's word.
    public var title: String {
        switch self {
        case .camera: "Camera"
        case .upload: "Upload Media"
        case .text: "Text Post"
        case .channel: "New Channel"
        }
    }

    /// The row's glyph: the owner's camera, gallery and megaphone (#2458,
    /// #2415), resolved by `UIImage.symbol(named:)`.
    public var symbolName: String {
        switch self {
        case .camera: AppSymbol.camera.rawValue
        case .upload: AppSymbol.gallery.rawValue
        case .text: "textformat"
        case .channel: AppSymbol.megaphone.rawValue
        }
    }
}
