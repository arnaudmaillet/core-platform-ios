import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// A voice post's caption (#2208)
extension PostGridListRowCell {
    // MARK: - A voice post's caption (#2208)

    /// Between the voice and the caption's words under it.
    public static let voiceCaptionGap: CGFloat = Spacing.sm

    /// The size a card gives a voice post's caption (#2208), nil for a post
    /// that does not speak or with the switch off: full on the list's card,
    /// compact on a card of a FIXED height (`captionLines` — a shelf's).
    /// Pure.
    public static func voiceSize(
        for post: GalleryPost, captionLines: Int?, showsVoice: Bool
    ) -> VoicePostDisplay.Size? {
        guard showsVoice, post.kind == .text, post.voice != nil else { return nil }
        return captionLines == nil ? .full : .compact
    }

    /// Whether the voice's drags are its own (#2275): on the list's card,
    /// yes; on a card of a FIXED height (`captionLines` — a horizontal
    /// shelf's), no — a drag on its panel scrolls the shelf, a tap seeks.
    /// Pure.
    public static func voiceDragsAreOwn(captionLines: Int?) -> Bool {
        captionLines == nil
    }

    func buildVoiceCaption() {
        voiceCaption.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(voiceCaption)
        // Nothing in it, it stands zero tall: what it holds outranks this.
        let empty = voiceCaption.heightAnchor.constraint(equalToConstant: 0)
        empty.priority = .defaultLow - 1
        voiceFollowsBand = voiceCaption.topAnchor.constraint(
            equalTo: authorBand.bottomAnchor, constant: Self.authorFollowGap
        )
        captionFollowsVoice = captionLabel.topAnchor.constraint(
            equalTo: voiceCaption.bottomAnchor, constant: Self.voiceCaptionGap
        )
        NSLayoutConstraint.activate([
            voiceCaption.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.captionInset),
            voiceCaption.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.captionInset),
            voiceFollowsBand, empty,
        ])
    }

    /// Shows `post`'s voice at `size`, or none: the caption then hangs off
    /// the voice (flush under a voice alone), or off the band as before.
    func applyVoice(_ size: VoicePostDisplay.Size?, for post: GalleryPost?) {
        guard let size, let post, let voice = post.voice else {
            voiceCaption.clear()
            captionFollowsVoice.isActive = false
            captionFollowsBand.isActive = true
            return
        }
        voiceCaption.show(
            postID: post.id.rawValue, url: voice.url, duration: voice.duration, levels: voice.waveform,
            author: post.authorName, size: size, dragsAreOwn: Self.voiceDragsAreOwn(captionLines: fixedCaptionLines)
        )
        captionFollowsBand.isActive = false
        captionFollowsVoice.constant = fullCaption.isEmpty ? 0 : Self.voiceCaptionGap
        captionFollowsVoice.isActive = true
    }

    /// How far the voice pushes the caption down, measured — zero without one.
    var voiceBlockHeight: CGFloat {
        guard !voiceCaption.isHidden else { return 0 }
        let height = voiceCaption.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        return ceil(height) + captionFollowsVoice.constant
    }

    /// The card left the screen (a list's `didEndDisplaying`): a voice it
    /// plays stops where it is, unless the post's page shows it (#2208).
    public func voiceDidEndDisplaying() {
        voiceCaption.leftScreen()
    }
}
