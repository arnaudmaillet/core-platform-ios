import EmoteKit
import FeedInterface
import UIKit

/// The emote strip, handed to Feed's conversation screen as the footer item
/// that stands where a post shows its music.
///
/// EmoteKit's `EmoteStripView` — every emote the build ships, the map's GIF
/// emotes included, each displayed tile animating — sized as a bar item that
/// FILLS what the bar's other items leave:
///
/// **BY AUTO LAYOUT, NOT BY ARITHMETIC.** A custom view that hugs nothing and
/// asks, at the lowest priority, for more room than any bar has is stretched
/// by the bar to exactly what the other items leave — whatever the width, the
/// text size or the OS's bar margins (measured on iOS 27 for the sound
/// sheet's "Use this sound"). The strip draws its own glass capsule, so the
/// host hides the bar's shared bubble around it (`ConversationThreadAccessory`).
///
/// A tap inserts the emote as it is WRITTEN — the emoji itself, or a house
/// emote's `:code:` — which is all chat.v1's text body can carry, and what
/// every EmoteKit label animates on the other side.
@MainActor
final class EmoteStripAccessory: ConversationThreadAccessory {
    /// The bar's glass bubbles' height on iOS 27 (iPhone 18 Pro): the strip's
    /// capsule stands as tall as the bookmark/repost and ••• bubbles beside it.
    static let bubbleHeight: CGFloat = 48
    /// ⚠️ **THE BAR INSETS A CUSTOM VIEW 5PT INSIDE ITS SLOT, SHARED BUBBLE
    /// HIDDEN OR NOT.** Measured on iOS 27 (iPhone 18 Pro): the item's glass
    /// slot was 176pt wide and the custom view 166pt at x 5, so the capsule
    /// stood 5pt further from the bar's leading margin and from the bubble
    /// beside it than those bubbles stand from each other. The capsule is
    /// drawn out over that inset; nothing on the way up clips it (filmed).
    /// The overhang is outside the item's bounds, so it takes no touches —
    /// 5pt of rounded glass with no tile in it at rest.
    static let slotInset: CGFloat = 5

    /// What the bar holds: the strip, overhanging it by `slotInset` on each
    /// side.
    private let host = UIView()
    private let strip = EmoteStripView()

    var view: UIView { host }
    var onInsertText: ((String) -> Void)?

    init() {
        strip.onSelect = { [weak self] emote in self?.onInsertText?(emote.insertionText) }
        host.translatesAutoresizingMaskIntoConstraints = false
        host.clipsToBounds = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(strip)
        // Hugs nothing, and wants everything — at the lowest priorities, so
        // the bar's own layout (the bubbles, their gaps, its margins) wins and
        // this takes the rest.
        host.setContentHuggingPriority(.init(1), for: .horizontal)
        host.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let fill = host.widthAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .init(2)
        // 999, never required: the bar's first pass pins its item wrapper to
        // the raw intrinsic size with autoresizing constraints.
        let height = host.heightAnchor.constraint(equalToConstant: Self.bubbleHeight)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            fill, height,
            strip.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: -Self.slotInset),
            strip.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: Self.slotInset),
            strip.topAnchor.constraint(equalTo: host.topAnchor),
            strip.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }
}
