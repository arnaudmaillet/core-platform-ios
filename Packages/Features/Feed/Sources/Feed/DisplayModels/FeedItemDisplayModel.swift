import CoreModels
import MediaCore
import PostGrid
import Foundation
import UIKit

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// Everything the snap feed cell renders for one post. Full-screen cells are
/// bounds-sized, so there is no precomputed geometry — just the content.
///
/// `Equatable` is load-bearing, not a convenience. The pager is a diffable data
/// source keyed by `PostID`, and a snapshot whose identifiers are unchanged
/// re-renders nothing — so a page that arrives as a projection and is later
/// replaced by the real entry needs someone to notice the CONTENT changed under
/// a stable identity. `SnapFeedViewController.render` compares models to decide
/// what to reconfigure; without this it could only compare ids, and a seeded
/// page would keep its seed for the rest of its life.
public struct FeedItemDisplayModel: Identifiable, Sendable, Equatable {
    public let id: PostID
    let authorID: ProfileID
    let authorName: String
    let metaText: String // "@handle · 3m"
    let avatarURL: URL?
    let caption: String?
    let mediaURL: URL?
    let mediaKind: MediaKind
    /// Poster/thumbnail; for a video it's shown under the player until the first
    /// frame is ready.
    let thumbnailURL: URL?
    /// The media toolbar's audio attribution line ("Original audio · @handle").
    /// Derived — the BFF exposes no track metadata yet; swap for the real
    /// track title/artist once the post proto carries audio. Nil for
    /// non-video posts (the toolbar falls back to `metaText`).
    let audioText: String?
    /// The like count at hydration time (the feed entry's snapshot; live
    /// updates supersede it via the realtime plane). Rendered by the
    /// engaged card's metrics row.
    let likeCount: Int64
    /// The post's age as a compact relative string ("now"/"3m"/"5h"/"5d"),
    /// the design system's timestamp form (the nav pill and comment rows
    /// use the same). Rendered leading on the engaged info card's actions
    /// row. Empty only for models built outside the feed builder (tests).
    let timestampText: String
    /// The gallery card's metric line, when the opener knew it — views,
    /// reactions, comments, each optional because absent and zero are
    /// different claims (`PostMetricLabel` hides a `nil` and renders a `0`).
    ///
    /// `nil` for a model built from a `FeedEntry`, which carries a like count
    /// and nothing else. Only a grid knows all three, so only a grid-seeded
    /// model can fill this — see `GalleryPostProjection`.
    let cardMetrics: PostCardMetrics?
    /// Pages two and up of a COLLECTION post, empty for everything else.
    ///
    /// The head stays in `mediaURL` / `thumbnailURL` / `mediaKind` above rather
    /// than folding into an array, because everything on this page that shows
    /// ONE piece of a post reads those: the video surface, the poster, the hero
    /// landing, the media toolbar's attribution. An array would have made each
    /// of them say `.first`, which is the shape of the bug this undoes.
    ///
    /// PHOTOS only, which follows the contract's own line between `carousel`
    /// and `main_video`: a page carries one video surface, and a collection of
    /// clips would need one per page plus a playback owner per page.
    let extraMedia: [GalleryPost.MediaPage]

    init(
        id: PostID,
        authorID: ProfileID,
        authorName: String,
        metaText: String,
        avatarURL: URL?,
        caption: String?,
        mediaURL: URL?,
        mediaKind: MediaKind,
        thumbnailURL: URL?,
        audioText: String?,
        likeCount: Int64 = 0,
        timestampText: String = "",
        cardMetrics: PostCardMetrics? = nil,
        extraMedia: [GalleryPost.MediaPage] = []
    ) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.metaText = metaText
        self.avatarURL = avatarURL
        self.caption = caption
        self.mediaURL = mediaURL
        self.mediaKind = mediaKind
        self.thumbnailURL = thumbnailURL
        self.audioText = audioText
        self.likeCount = likeCount
        self.timestampText = timestampText
        self.cardMetrics = cardMetrics
        self.extraMedia = extraMedia
    }

    /// Every page of the post, head included — what a carousel is built from.
    var mediaPages: [GalleryPost.MediaPage] {
        guard mediaURL != nil || thumbnailURL != nil else { return [] }
        return [GalleryPost.MediaPage(
            thumbnailURL: thumbnailURL ?? mediaURL,
            videoURL: mediaKind == .video ? mediaURL : nil
        )] + extraMedia
    }

    /// Whether this post is a collection — the only question the page's
    /// carousel asks.
    var isCollection: Bool { !extraMedia.isEmpty }
}

/// Builds display models from hydrated feed entries. Pure, deterministic, and
/// `Sendable`.
public struct FeedDisplayModelBuilder: Sendable {
    public init() {}

    public func build(_ entries: [FeedEntry], relativeTo now: Date) -> [FeedItemDisplayModel] {
        entries.map { build($0, now: now) }
    }

    func build(_ entry: FeedEntry, now: Date) -> FeedItemDisplayModel {
        let trimmed = entry.post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = entry.post.attachments.first
        let mediaKind = attachment.map { MediaKind(mimeType: $0.mimeType) } ?? .image
        return FeedItemDisplayModel(
            id: entry.post.id,
            authorID: entry.author.id,
            authorName: entry.author.displayName,
            metaText: "@\(entry.author.handle) · \(Self.relativeTime(from: entry.post.publishedAt, to: now))",
            avatarURL: entry.author.avatarURL,
            caption: trimmed.isEmpty ? nil : trimmed,
            mediaURL: attachment?.url,
            mediaKind: mediaKind,
            thumbnailURL: attachment?.thumbnailURL,
            audioText: (attachment != nil && mediaKind == .video)
                ? "Original audio · @\(entry.author.handle)" : nil,
            likeCount: entry.likeCount,
            timestampText: Self.readableTimestamp(from: entry.post.publishedAt, to: now),
            // Everything after the head. `attachments` is a repeated field and
            // this builder kept only its first element — the page showed one
            // photograph of a collection and nothing said there were more.
            extraMedia: entry.post.attachments.dropFirst().map { attachment in
                GalleryPost.MediaPage(
                    thumbnailURL: attachment.thumbnailURL ?? attachment.url,
                    // ⚠️ The page's OWN stream, and it was dropped here.
                    //
                    // This mapped a thumbnail and an aspect and nothing else, so
                    // every page after the head arrived as a still whatever its
                    // MIME said — a clip on page two of a collection reached the
                    // post page as a photograph, with no badge and nothing to
                    // play. The two grid projections already carry it; this one
                    // is where the page's model is built and it did not.
                    //
                    // Routed through `MediaKind`, not a `video/` prefix: an HLS
                    // manifest declares `application/vnd.apple.mpegurl`, which a
                    // prefix test reads as a still.
                    videoURL: MediaKind(mimeType: attachment.mimeType) == .video
                        ? attachment.url : nil,
                    aspectRatio: attachment.aspectRatio
                )
            }
        )
    }

    /// The COMPACT relative age ("now"/"3m"/"5h"/"5d") — the nav pill and
    /// the comment rows' register. Kept terse: it rides inside the
    /// "@handle · 3m" meta line where space is scarce.
    ///
    /// ⚠️ Internal rather than private so `GalleryPostProjection` can spell an
    /// age the same way. A grid tile's own register is a calendar date past a
    /// week ("28 May", see `PostMetadata.compactAge`) and this one never stops
    /// counting days — both are right for their surface, and a seed built with
    /// the wrong one visibly rewrites itself the moment the real entry lands.
    static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    /// The HUMAN-READABLE age for the engaged info card ("5 minutes",
    /// "1 hour", "5 days", "7 weeks") — full words, pluralized and
    /// localized by `DateComponentsFormatter`, with days rolling into
    /// weeks past 7 days (52 days reads "7 weeks", never "52 days"). The
    /// unit is chosen HERE (one explicit component) so the day→week
    /// threshold is exact; the formatter only supplies the localized,
    /// correctly-pluralized word.
    static func readableTimestamp(from date: Date, to now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        var components = DateComponents()
        switch seconds {
        case ..<3_600: components.minute = seconds / 60
        case ..<86_400: components.hour = seconds / 3_600
        case ..<604_800: components.day = seconds / 86_400        // 1–6 days
        default: components.weekOfMonth = seconds / 604_800       // 7+ days → weeks
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full // "5 days", not "5d"
        formatter.maximumUnitCount = 1
        return formatter.string(from: components) ?? "now"
    }
}
