import Foundation

/// The gallery's two filter axes — what the bottom tray selects. Pure model:
/// the view model owns the state, this owns the semantics.
///
/// The axes mirror timeline-first products: the horizontal PAGER moves
/// between content *formats* (each with its own layout), while the drop-down
/// picks the content *source* as a global modifier across all three pages.
public struct GalleryFilter: Equatable, Sendable {
    /// What the content is — the pager's axis. Each format owns a layout:
    /// Activity and Short read as full-width timeline rows, Media as the
    /// 3-column grid.
    public enum Format: Equatable, Sendable, CaseIterable {
        /// Everything, mixed — the classic chronological timeline.
        case activity
        /// Image and video posts only.
        case media
        /// Text-only posts.
        case short
    }

    /// Where the content comes from — the drop-down's axis.
    public enum Source: Equatable, Sendable, CaseIterable {
        /// Own posts, reposts, and tagged posts merged chronologically.
        case all
        /// The profile's own original posts (repost lineage excluded).
        case posts
        /// The profile's posts that reference a parent (post.v1 `parent_id`).
        case reposts
        /// Posts by others mentioning the profile's @handle.
        case tagged
    }

    public var format: Format
    public var source: Source

    /// The landing combination: the full timeline.
    public init(format: Format = .activity, source: Source = .all) {
        self.format = format
        self.source = source
    }

    /// Resolves the active combination against the two fetched datasets:
    /// the source slices (Posts/Reposts split the authored fetch on repost
    /// lineage, Tagged is its own corpus, All merges both newest-first), and
    /// the format then filters by kind. One pure pass, re-run per selection.
    public func tiles(authored: [GalleryPost], tagged: [GalleryPost]) -> [GalleryPost] {
        let sourced: [GalleryPost] = switch source {
        case .all: (authored + tagged).sorted { $0.publishedAtMS > $1.publishedAtMS }
        case .posts: authored.filter { !$0.isRepost }
        case .reposts: authored.filter(\.isRepost)
        case .tagged: tagged
        }
        return switch format {
        case .activity: sourced
        case .media: sourced.filter { $0.kind != .text }
        case .short: sourced.filter { $0.kind == .text }
        }
    }
}
