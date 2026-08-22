import UIKit

/// The ink for the date laid directly on a media preview: WHITE, always, on a
/// black halo.
///
/// ## ⚠️ It used to sample the picture, and that is worth knowing before anyone
/// suggests it again
///
/// The date lost its capsule because a capsule claims its contents can be
/// pressed, and of the things on that row it is the one that never will be.
/// Without a capsule it has no floor, so the first answer was to take its side
/// from the ground: render the picture through the view's aspect-fill geometry,
/// average the luminance under the word, go black on a light ground and white
/// on a dark one. It worked, and it was measured working — white on deep water,
/// white on dark wood at 0.27, black on light stone.
///
/// It was dropped for three reasons, in order of weight:
///
/// 1. **It cannot answer for a video.** What the viewer sees is a decoded frame
///    the card never held; the poster is what would be sampled, so the answer
///    was right at rest and wrong the moment playback started.
/// 2. **It cannot answer for a carousel.** The date's corner spans the current
///    page, the gap and the neighbour's peek — three grounds averaged into one
///    number, changing as the pages move.
/// 3. **The exceptions outgrew the rule.** Two of the three grounds a card can
///    have were already fixed constants; sampling survived only for the still
///    photograph, which is the case that needed it least.
///
/// A fixed ink is stable, and stability is what a halo can rescue. A sampled
/// one is occasionally perfect and occasionally confidently wrong, and nothing
/// rescues that.
enum MediaDateInk {
    static let colour: UIColor = .white

    /// ⚠️ The halo is the COUNTER-TONE, not decoration.
    ///
    /// A black shadow under black text is a slightly bolder black word — on the
    /// ground that already could not carry it. What holds a bare word on an
    /// arbitrary photograph is an edge of the opposite side, which is why this
    /// is tied to `colour` and must move with it.
    static let halo: UIColor = .black

    /// ⚠️ Sized for the WORST ground, not for a good one.
    ///
    /// 0.5 at 2.5pt is what a shadow wants to be when the ground is already
    /// nearly right, and on the case it exists for — a light preview under a
    /// white word — it did nothing. At 0.85 the halo is a legible edge against a
    /// ground of the ink's own side and still reads as soft where the ground is
    /// the opposite one. That asymmetry is the point: it is loud only when it is
    /// the only thing holding the word up.
    static let haloOpacity: Float = 0.85
    static let haloRadius: CGFloat = 3
}
