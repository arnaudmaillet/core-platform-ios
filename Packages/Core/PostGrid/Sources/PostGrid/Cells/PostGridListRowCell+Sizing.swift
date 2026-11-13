import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// The card's shape and the preview's height, measured without a cell
extension PostGridListRowCell {
    // MARK: - The card's shape system
    //
    // Every radius on a card, in one place, because four radii chosen
    // separately is how a card stops looking like one object.
    //
    // ```
    //   card      26        the container, and the platform's own answer
    //   preview   14        concentric: 26 - 12, corners ON the card's corners
    //   chips     capsule   clear of the preview's corners, so unconstrained
    //   avatar    circle    a portrait, exempt — see below
    // ```
    //
    // Two rules produce all of it, and the second is the one that is usually
    // missing:
    //
    // 1. **A child whose corners sit at its parent's is concentric with it** —
    //    radius = parent's less the inset. The preview.
    // 2. **A child clear of its parent's corners has no radius obligation at
    //    all** — it meets only straight edge. The chips.
    //
    // An avatar is neither: it is a picture of a person, and every surface in
    // this app draws one as a circle. A circle near a rounded corner has never
    // read as a disagreement, because it is not perceived as a container — it
    // is perceived as a face. Rounding it to 10 for consistency's sake would
    // make the card MORE uniform and less legible, which is the trade a shape
    // system exists to avoid making by accident.
    //
    // ❌ Making the chips concentric was tried and is the reason this note
    // exists: at 8pt in from the preview's edges the arithmetic gave 2, and a
    // chip at radius 2 is a rectangle. The choice looked like "correct shape or
    // correct radius" until the third option turned up — move the chip off the
    // corner, where neither answer is required.
    // MARK: - The preview's height

    /// The widest a preview may be drawn: 16:9. A floor on HEIGHT, and it is
    /// what stops a 21:9 clip from becoming a slit with a subject in it.
    public static let widestMediaAspect: CGFloat = 16.0 / 9.0
    /// The tallest a preview may be drawn: 4:5, the portrait cap Instagram
    /// settled on and the same one the mock corpus already seeds.
    ///
    /// It is the number that decides how much of a screen one card may take.
    /// Measured on this device (402pt wide, 348pt of preview): 4:5 is 435pt of
    /// preview and about 63% of the screen with the band, caption and padding
    /// on top. Uncapped, a 9:16 post would be 619 and **84%** — one post, one
    /// screen, which is what this exists to prevent.
    public static let tallestMediaAspect: CGFloat = 5.0 / 4.0

    /// How tall the preview is for a post of a given shape, in a card of a
    /// given width.
    ///
    /// A pure function of the two, deliberately: the height has to come from
    /// the MODEL and never from the image once it lands. `MediaAttachment`
    /// already states the rule — heights are computed from `aspectRatio`, never
    /// by sizing views — because a height that changes when the file arrives
    /// reflows everything below it in a list the viewer is already scrolling.
    ///
    /// ⚠️ `aspectRatio` is 1 for a SQUARE post and 1 for a post the backend
    /// never stamped with dimensions; `GalleryPost` says so in as many words.
    /// So an unmeasured post lands here as a square — 348pt rather than the
    /// 180pt letterbox rows used to draw. That is the fail-open direction and
    /// it is the right one for a height (a square is a plausible photo; a slit
    /// is not), but it is a real behaviour change for any surface whose
    /// payload omits width and height.
    public static func mediaHeight(forCardWidth cardWidth: CGFloat, aspectRatio: Double) -> CGFloat {
        let mediaWidth = cardWidth - contentInset * 2
        guard mediaWidth > 0 else { return 0 }
        let ratio = aspectRatio > 0 ? CGFloat(aspectRatio) : 1
        let natural = mediaWidth / ratio
        let shortest = mediaWidth / widestMediaAspect
        let tallest = mediaWidth * tallestMediaAspect
        return (min(max(natural, shortest), tallest)).rounded()
    }

    /// How tall the preview is for a COLLECTION of `pageCount` in a card of a
    /// given width: one item of the carousel's strip
    /// (`MediaCarouselView.cardHeight`), whatever the post's own shape.
    ///
    /// ⚠️ NOT `mediaHeight(forCardWidth:aspectRatio:)`. A collection's box
    /// holds a strip of 3:4 items, two and a bit across, so its height is an
    /// item's — about half what the post's shape across the whole box gave
    /// (2026-10-02, asked for: collections were the tallest cards on the
    /// screen).
    public static func collectionMediaHeight(forCardWidth cardWidth: CGFloat, pageCount: Int) -> CGFloat {
        MediaCarouselView.cardHeight(
            forBoxWidth: cardWidth - contentInset * 2, pageCount: pageCount
        )
    }

    /// How many lines of caption a card previews before it offers the rest.
    ///
    /// A card is a PREVIEW and the post is where the text is read, so the cap
    /// is set where a long caption still reads as a paragraph rather than as a
    /// wall — four lines. Only the card truncates: `PostCaptionRowView`, which
    /// wears the same face on the post's own page, deliberately does not.
    public static let captionLineLimit = 4


    /// How tall a card `width` wide stands in a lane of fixed-height cards:
    /// the taller of a TEXT card whose caption is held to `captionLines` and
    /// fills them — author band, caption, closing line (with the like, repost
    /// and save on it) — and, with voice posts drawn, a VOICE card — the
    /// band, the compact voice panel in the caption's place, the closing line
    /// (#2274). Each is measured on a real card, the way
    /// `RevealDismissCardView` measures. What a lane of such cards is sized
    /// to. Cached per width, line count, text size and voice.
    ///
    /// ⚠️ THE VOICE PANEL IS NEVER SQUEEZED (#2274). Measured on a text card
    /// alone, a lane was two caption lines tall (about 39 pt) where the
    /// compact panel is 44 pt: the card held its height and the panel gave
    /// way, its play glyph on its bottom edge (the owner's recording). The
    /// words under a voice give way in a fixed card instead (they go: the
    /// voice stands alone, `configure`), never the panel.
    public static func fixedTextCardHeight(
        width: CGFloat, captionLines: Int, showsVoice: Bool = VoicePostDisplay.areDrawn
    ) -> CGFloat {
        guard width > 0 else { return 0 }
        // The app's text size, not the iPhone's: above the ceiling they differ
        // (#482), and a card measured at the iPhone's size came out taller
        // than the one drawn.
        let size = TextSizeCeiling.current ?? UIApplication.shared.preferredContentSizeCategory
        let key = "\(width)|\(captionLines)|\(size.rawValue)|\(showsVoice)"
        if let cached = fixedHeights[key] { return cached }
        // Words enough to fill any cap at any width, and a name and handle on
        // the band, as every text card in a lane wears.
        var post = GalleryPost(
            id: PostID("fixed-height-probe"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: String(repeating: "Measured words fill every line of the card. ", count: 12),
            publishedAtMS: 0, authorID: ProfileID("probe"), authorName: "Name", authorHandle: "handle",
            reactionCount: 1, commentCount: 1
        )
        var height = measuredFixedHeight(of: post, width: width, captionLines: captionLines, category: size, showsVoice: false)
        if showsVoice {
            // The same post speaking: its compact panel in the caption's place.
            post.voice = PostVoice(
                assetID: "fixed-height-probe-voice", url: nil, duration: 59, waveform: VoiceView.genericLevels
            )
            let voiced = measuredFixedHeight(of: post, width: width, captionLines: captionLines, category: size, showsVoice: true)
            height = max(height, voiced)
        }
        fixedHeights[key] = height
        return height
    }

    /// `post`'s card at `width`, its caption held to `captionLines`, wired as
    /// a lane wires it, measured.
    private static func measuredFixedHeight(
        of post: GalleryPost, width: CGFloat, captionLines: Int, category: UIContentSizeCategory, showsVoice: Bool
    ) -> CGFloat {
        let card = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        card.traitOverrides.preferredContentSizeCategory = category
        card.configure(
            with: post, imagePipeline: measuringPipeline, captionLines: captionLines,
            showsVoice: showsVoice, showsEmbed: false
        )
        card.showAuthorMenuControlAsScenery()
        card.showRowActionsAsScenery(repost: true, bookmark: true, saved: false)
        card.showStakeAsScenery(viewerStake: 0)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        let fitted = card.preferredLayoutAttributesFitting(attributes).frame.height
        // The probe's voice lets go of the hub it was bound to.
        card.applyVoice(nil, for: nil)
        return fitted
    }

    private static var fixedHeights: [String: CGFloat] = [:]
    /// The measuring card's pipeline: its probe names no picture, so nothing
    /// is ever fetched through it.
    private static let measuringPipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    /// The gap between the caption and whatever follows it — the closing
    /// line, the media preview — and between the preview and the line. The
    /// same step as the gap above the caption (`authorFollowGap`), so the
    /// words sit in equal air.
    public static let captionFollowGap: CGFloat = 16
    /// The author band's measurements, restated as this cell's own names only
    /// so call sites read naturally — the values live with the view that draws
    /// them, because the reveal's prop draws the same band.
    public static var authorAvatarDiameter: CGFloat { PostAuthorBandView.avatarDiameter }
    public static var authorFollowGap: CGFloat { PostAuthorBandView.captionGap }
}
