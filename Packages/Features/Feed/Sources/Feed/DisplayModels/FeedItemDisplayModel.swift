import MediaCore
import CoreModels
import Foundation
import UIKit

/// Geometry constants shared by `FeedDisplayModelBuilder` (which computes
/// heights off-main) and `FeedCell.layoutSubviews` (which places frames with
/// the same math). Change them together — that invariant is what makes
/// scroll-time sizing a dictionary lookup.
enum FeedCellMetrics {
    static let horizontalMargin: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    static let avatarSize: CGFloat = 44
    static let headerToCaptionSpacing: CGFloat = 8
    static let captionToMediaSpacing: CGFloat = 12
    static let mediaCornerRadius: CGFloat = 12
    /// Engagement bar (like button + count) below the content; constant, so
    /// live count updates never change cell height.
    static let footerHeight: CGFloat = 40
    /// Portrait media is capped at 4:5 (0.8), landscape at 1.91:1 — the
    /// range hostile aspect ratios get clamped into.
    static let minAspectRatio: CGFloat = 0.8
    static let maxAspectRatio: CGFloat = 1.91

    static let nameFont = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
    static let metaFont = UIFont.preferredFont(forTextStyle: .footnote)
    static let captionFont = UIFont.preferredFont(forTextStyle: .body)

    static func contentWidth(cellWidth: CGFloat) -> CGFloat {
        cellWidth - 2 * horizontalMargin
    }

    static func mediaHeight(contentWidth: CGFloat, aspectRatio: Double) -> CGFloat {
        let clamped = min(max(CGFloat(aspectRatio), minAspectRatio), maxAspectRatio)
        return (contentWidth / clamped).rounded(.up)
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// Immutable pre-rendered text, safe to hop threads. The wrapped instance is
/// `NSAttributedString` (never the mutable subclass) built once by the
/// display-model builder — that invariant is what justifies `@unchecked`.
struct RenderedText: @unchecked Sendable {
    let attributed: NSAttributedString
}

/// Everything a feed cell renders, precomputed off the main thread: the
/// attributed caption is already built, and `height` is final for the width
/// it was computed at. Scroll-time layout does zero text measurement.
public struct FeedItemDisplayModel: Identifiable, Sendable {
    public let id: PostID
    let authorID: ProfileID
    let authorName: String
    let metaText: String // "@handle · 3m"
    let avatarURL: URL?
    let caption: RenderedText?
    let captionHeight: CGFloat
    let mediaURL: URL?
    let mediaKind: MediaKind
    let mediaHeight: CGFloat
    public let height: CGFloat
}

/// Builds display models for a fixed layout width. Pure, deterministic, and
/// `Sendable` — the view model runs it via `Task.detached`.
public struct FeedDisplayModelBuilder: Sendable {
    private let cellWidth: CGFloat

    public init(cellWidth: CGFloat) {
        self.cellWidth = cellWidth
    }

    public func build(_ entries: [FeedEntry], relativeTo now: Date) -> [FeedItemDisplayModel] {
        entries.map { build($0, now: now) }
    }

    func build(_ entry: FeedEntry, now: Date) -> FeedItemDisplayModel {
        let contentWidth = FeedCellMetrics.contentWidth(cellWidth: cellWidth)

        let caption: RenderedText?
        let captionHeight: CGFloat
        let trimmed = entry.post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            caption = nil
            captionHeight = 0
        } else {
            let attributed = NSAttributedString(string: trimmed, attributes: [
                .font: FeedCellMetrics.captionFont,
                .foregroundColor: UIColor.label
            ])
            caption = RenderedText(attributed: attributed)
            captionHeight = attributed.boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height.rounded(.up)
        }

        let attachment = entry.post.attachments.first
        let mediaKind = attachment.map { MediaKind(mimeType: $0.mimeType) } ?? .image
        let mediaHeight = attachment.map {
            FeedCellMetrics.mediaHeight(contentWidth: contentWidth, aspectRatio: $0.aspectRatio)
        } ?? 0

        var height = FeedCellMetrics.verticalPadding + FeedCellMetrics.avatarSize
        if captionHeight > 0 {
            height += FeedCellMetrics.headerToCaptionSpacing + captionHeight
        }
        if mediaHeight > 0 {
            height += FeedCellMetrics.captionToMediaSpacing + mediaHeight
        }
        height += FeedCellMetrics.footerHeight
        height += FeedCellMetrics.verticalPadding

        return FeedItemDisplayModel(
            id: entry.post.id,
            authorID: entry.author.id,
            authorName: entry.author.displayName,
            metaText: "@\(entry.author.handle) · \(Self.relativeTime(from: entry.post.publishedAt, to: now))",
            avatarURL: entry.author.avatarURL,
            caption: caption,
            captionHeight: captionHeight,
            mediaURL: attachment?.url,
            mediaKind: mediaKind,
            mediaHeight: mediaHeight,
            height: height.rounded(.up)
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
