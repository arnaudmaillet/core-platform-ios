import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// A showcase's card (#2216)
extension PostGridListRowCell {
    // MARK: - A showcase's card (#2216)

    /// Between the author's words and the card under them.
    public static let embedCaptionGap: CGFloat = Spacing.sm

    /// The size a card gives a showcase's embed (#2216), nil for a post with
    /// none or with the switch off: full on the list's card, the words above
    /// it; compact on a card of a FIXED height (`captionLines` — a shelf's),
    /// the card alone. Pure.
    public static func embedSize(
        for post: GalleryPost, captionLines: Int?, showsEmbed: Bool
    ) -> PostEmbeds.Size? {
        guard post.kind == .text, PostEmbeds.shown(post.embed, drawn: showsEmbed) != nil else { return nil }
        return captionLines == nil ? .full : .compact
    }

    /// Built once the closing line exists: the card's foot hangs it.
    func buildEmbedCard() {
        embedCard.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(embedCard)
        embedFollowsCaption = embedCard.topAnchor.constraint(
            equalTo: captionLabel.bottomAnchor, constant: Self.embedCaptionGap
        )
        metaFollowsEmbed = metaRow.topAnchor.constraint(
            equalTo: embedCard.bottomAnchor, constant: Self.captionFollowGap
        )
        // ⚠️ SOFT on a fixed card (a shelf's): the lane's height is measured
        // for its words (`fixedTextCardHeight`), and a compact card can be a
        // few points taller than two lines — it leans into the gap above the
        // line rather than break the card's own constraints.
        metaStandsUnderEmbed = metaRow.topAnchor.constraint(
            greaterThanOrEqualTo: embedCard.bottomAnchor, constant: Spacing.xs
        )
        metaStandsUnderEmbed.priority = .defaultHigh
        embedClosesCard = embedCard.bottomAnchor.constraint(
            equalTo: card.bottomAnchor, constant: -Self.contentInset
        )
        NSLayoutConstraint.activate([
            embedCard.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.captionInset),
            embedCard.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.captionInset),
            embedFollowsCaption,
        ])
    }

    /// Shows `post`'s embed at `size`, or none. The caller decides the words
    /// first (`fullCaption`): flush under no words, a gap under some.
    func applyEmbed(_ size: PostEmbeds.Size?, for post: GalleryPost?, imagePipeline: ImagePipeline?) {
        guard let size, let embed = post?.embed else {
            embedCard.clear()
            return
        }
        embedCard.show(embed, size: size, pipeline: imagePipeline)
        embedFollowsCaption.constant = fullCaption.isEmpty ? 0 : Self.embedCaptionGap
    }

    #if DEBUG
    /// The showcase's card under the card's words, nil for none (#2216).
    public var debugEmbedCard: PostEmbedView? { embedCard.isHidden ? nil : embedCard }
    /// Whether the comment count shows (#2216: a showcase draws none).
    public var debugShowsCommentCount: Bool { !commentsAction.isHidden }
    #endif

    #if DEBUG
    /// The voice the card draws in its caption's place, nil for none.
    public var debugVoiceCaption: VoicePostCaptionView? { voiceCaption.isHidden ? nil : voiceCaption }
    /// The voice part, shown or not — for a test to put its own hub in.
    public var debugVoicePart: VoicePostCaptionView { voiceCaption }
    #endif
}
