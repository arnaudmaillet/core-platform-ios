import MediaCore
import CoreModels
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
public struct FeedItemDisplayModel: Identifiable, Sendable {
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
        return FeedItemDisplayModel(
            id: entry.post.id,
            authorID: entry.author.id,
            authorName: entry.author.displayName,
            metaText: "@\(entry.author.handle) · \(Self.relativeTime(from: entry.post.publishedAt, to: now))",
            avatarURL: entry.author.avatarURL,
            caption: trimmed.isEmpty ? nil : trimmed,
            mediaURL: attachment?.url,
            mediaKind: attachment.map { MediaKind(mimeType: $0.mimeType) } ?? .image,
            thumbnailURL: attachment?.thumbnailURL
        )
    }

    private static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}
