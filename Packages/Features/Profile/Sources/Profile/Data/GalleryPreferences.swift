import Foundation

/// The gallery filter as a GLOBAL user preference: which format tab and
/// source the user last chose, persisted across profiles and launches —
/// every profile opened from then on lands directly on that combination.
///
/// UserDefaults-backed (a two-key preference, not a document); the enum⇄key
/// mapping lives here so the pure filter model stays storage-agnostic, and
/// unknown stored values degrade to the defaults rather than crashing a
/// downgrade.
public final class GalleryPreferences: @unchecked Sendable {
    private enum Keys {
        static let format = "profile.gallery.format"
        static let source = "profile.gallery.source"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var filter: GalleryFilter {
        get {
            GalleryFilter(
                format: Self.format(from: defaults.string(forKey: Keys.format)),
                source: Self.source(from: defaults.string(forKey: Keys.source))
            )
        }
        set {
            defaults.set(Self.key(for: newValue.format), forKey: Keys.format)
            defaults.set(Self.key(for: newValue.source), forKey: Keys.source)
        }
    }

    // MARK: - Mapping

    private static func key(for format: GalleryFilter.Format) -> String {
        switch format {
        case .activity: "activity"
        case .media: "media"
        case .short: "short"
        }
    }

    private static func format(from key: String?) -> GalleryFilter.Format {
        switch key {
        case "media": .media
        case "short": .short
        default: .activity
        }
    }

    private static func key(for source: GalleryFilter.Source) -> String {
        switch source {
        case .all: "all"
        case .posts: "posts"
        case .reposts: "reposts"
        case .tagged: "tagged"
        }
    }

    private static func source(from key: String?) -> GalleryFilter.Source {
        switch key {
        case "posts": .posts
        case "reposts": .reposts
        case "tagged": .tagged
        default: .all
        }
    }
}
