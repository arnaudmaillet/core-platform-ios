import CoreModels
import Foundation
import PostGrid

// A grid page's states, as values (#2379, stage A1): top-level, so the post
// surfaces that draw them can leave Feed. For You's own snapshot and rows
// went with the tab (#2453).

public nonisolated enum GridPageState: Equatable, Sendable {
    case loading
    case content([GalleryPost])
    /// The combination has nothing to show, said in two parts so the page
    /// reads intentional rather than broken.
    case empty(GridEmptyState)
    case failed(message: String)
}

/// An empty page, in the two pieces the viewer needs separately.
///
/// The split is not cosmetic. The TITLE is the finding — "No activity yet"
/// — and is true regardless of how the viewer got here. The SUBTITLE is the
/// reason the page might be narrower than they expected, and it is the only
/// part that tells them there is something they can change. Running them
/// into one sentence made the actionable half look like punctuation.
public nonisolated struct GridEmptyState: Equatable, Sendable {
    public let title: String
    /// Absent when nothing is narrowing the page — an unfiltered surface
    /// with no content has no explanation to offer, and inventing one would
    /// be noise.
    public let subtitle: String?

    public init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
}
