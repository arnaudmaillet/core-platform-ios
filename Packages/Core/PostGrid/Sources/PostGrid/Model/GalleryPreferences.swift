import Foundation

/// The gallery filter as a GLOBAL user preference: which format tab and
/// source the user last chose, persisted across profiles and launches —
/// every profile opened from then on lands directly on that combination.
///
/// UserDefaults-backed (a two-key preference, not a document); the enum⇄key
/// mapping lives here so the pure filter model stays storage-agnostic, and
/// unknown stored values degrade to the defaults rather than crashing a
/// downgrade.
///
/// `keyPrefix` namespaces the pair so two grid surfaces can each remember
/// their own landing tab. It defaults to the profile gallery's original keys
/// (`profile.gallery.format` / `profile.gallery.source`) — that default is
/// load-bearing, not cosmetic: it is what every already-installed app has
/// written, and what the `-profile.gallery.format <value>` launch argument
/// addresses. A second surface must pass its own prefix or the two will yank
/// each other's active tab.
public final class GalleryPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private let formatKey: String
    private let sourceKey: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "profile.gallery") {
        self.defaults = defaults
        formatKey = keyPrefix + ".format"
        sourceKey = keyPrefix + ".source"
    }

    public var filter: GalleryFilter {
        get {
            GalleryFilter(
                format: Self.format(from: defaults.string(forKey: formatKey)),
                source: Self.source(from: defaults.string(forKey: sourceKey))
            )
        }
        set {
            defaults.set(Self.key(for: newValue.format), forKey: formatKey)
            defaults.set(Self.key(for: newValue.source), forKey: sourceKey)
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
