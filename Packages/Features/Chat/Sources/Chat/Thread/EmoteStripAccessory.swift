import FeedInterface
import UIKit

/// The emote strip, handed to Feed's conversation screen as the footer item
/// that stands where a post shows its music.
///
/// A wrapper and nothing more: the strip, its Lottie dependency and its
/// sticker bundle stay in Chat, and a tap still inserts the sticker's EMOJI
/// into the composer rather than sending — chat.v1 carries a text body and
/// nothing else, so a sticker cannot travel as itself.
@MainActor
final class EmoteStripAccessory: ConversationThreadAccessory {
    private let strip = FavoriteStickerStripView()

    var view: UIView { strip }
    var onInsertText: ((String) -> Void)?

    init() {
        strip.onSelect = { [weak self] sticker in self?.onInsertText?(sticker.emoji) }
    }

    func setPreferredWidth(_ width: CGFloat) {
        strip.setPreferredWidth(width)
    }
}
