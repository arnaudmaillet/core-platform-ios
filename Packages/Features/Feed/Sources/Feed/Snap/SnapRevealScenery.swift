import MediaCore
import PostGrid
import UIKit

/// What the text reveal's scenery asks of the arriving screen (#2514): its
/// view, which the scenery covers whole — the comment stream and the composer
/// are not the page cell's.
@MainActor
protocol SnapRevealSceneryHost: UIViewController {}

/// The text reveal's scenery on the arriving feed (#2514): the veil that
/// covers what a COLLAPSED card has no room for, and the source row's author
/// band borrowed for the flight — both on the screen's own view, both driven
/// by the flight's progress, both gone when the flight is.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: the reveal's installer and its animation
/// block call it in their turn, where they called the screen before.
@MainActor
final class SnapRevealScenery {
    private unowned let host: any SnapRevealSceneryHost

    init(host: any SnapRevealSceneryHost) {
        self.host = host
    }

    /// Transition-scoped: covers what a COLLAPSED card has no room for, for
    /// the length of a reveal. See `installRevealVeil`.
    private var revealVeil: RevealVeilView?
    /// The source row's author band, borrowed for a flight — see
    /// `installRevealAuthorBand`.
    private var revealAuthorBand: PostAuthorBandView?

    /// **THE TEXT REVEAL**. Covers everything below `cut` for the
    /// length of a reveal, so a page opened from a COLLAPSED card shows no
    /// more of itself than the card did — see `RevealVeilView`.
    ///
    /// Hosted on this screen's own view rather than on the page cell, because
    /// it has to cover the comment stream and the composer as well, and those
    /// are not the cell's. `nil` takes it away.
    func installRevealVeil(below cut: CGFloat?, tint: UIColor?) {
        revealVeil?.removeFromSuperview()
        revealVeil = nil
        guard let cut, let tint, cut < host.view.bounds.height else { return }
        let veil = RevealVeilView(tint: tint)
        // Hung a band ABOVE the cut, so the gradient reaches solid exactly AT
        // it. Starting the ramp at the cut is what let the page's next line
        // ride the whole flight as a grey ghost — see `RevealVeilView`.
        let top = max(0, cut - RevealVeilView.fadeBand)
        veil.frame = CGRect(
            x: 0, y: top, width: host.view.bounds.width, height: host.view.bounds.height - top
        )
        veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(veil)
        revealVeil = veil
    }

    /// Driven inside the flight's animation block, so the page unfolds as the
    /// window opens and folds back as it closes — and scrubs with the finger
    /// on a dismissal.
    func setRevealVeilOpacity(_ alpha: CGFloat) {
        revealVeil?.alpha = alpha
    }

    /// **THE TEXT REVEAL**. Puts the SOURCE row's author band into
    /// this page for the length of a flight, at `top` in this view's own
    /// coordinates — or takes it away with `nil`.
    ///
    /// ## Why the page borrows a header it does not have
    ///
    /// A card names its author above its caption; a page names it in the nav
    /// pill instead, and has nothing in that strip at all. So the window a
    /// viewer holds showed a blank band where the card shows a header, and the
    /// card's own header had to fade in at the landing to cover the difference.
    ///
    /// A fade is the wrong tool twice over here. It is a fade of something
    /// against NOTHING, which works — but it is also a fade at exactly the
    /// moment this transition promises to be invisible, and the strip is the
    /// one part of the window that never matched.
    ///
    /// With the band drawn INTO the page, the window shows what the card shows
    /// from frame 0, and the swap at the landing is the identity rather than a
    /// dissolve. It is scenery: no touches, no follow action, gone the moment
    /// the flight is.
    ///
    /// Hosted on this screen's own view rather than on the page cell, for the
    /// same reason the veil is — and positioned rather than laid out, so the
    /// page's resting layout never learns it exists.
    func installRevealAuthorBand(
        in rect: CGRect?, model: PostAuthorBandView.Model?, pipeline: ImagePipeline?
    ) {
        revealAuthorBand?.removeFromSuperview()
        revealAuthorBand = nil
        guard let rect, let model else { return }
        let band = PostAuthorBandView()
        band.isUserInteractionEnabled = false
        band.configure(with: model, imagePipeline: pipeline)
        // Scenery, but scenery that has to match: the card this lands on wears
        // a "...", and a control that pops in at the landing is the one frame
        // the reveal exists to make invisible.
        band.showMenuControlAsScenery()
        band.alpha = 0
        band.translatesAutoresizingMaskIntoConstraints = true
        // The rect comes from the CAPTION ROW, already inset from the page's
        // edge, and the band takes the caption's own inset inside it — which is
        // exactly what the card does. Measuring from this view instead was the
        // first version, and it put the band 16pt wider on each side than the
        // card's: the page's caption is inset TWICE, once by the stream's
        // section and once by the row, and only the second of those is the
        // card's own.
        band.frame = rect
        band.autoresizingMask = [.flexibleWidth]
        // ABOVE the veil: the veil covers what the page has too much of, and
        // this is the one thing it has too little of.
        host.view.addSubview(band)
        revealAuthorBand = band
    }

    /// The prop's opacity, driven on the flight's progress — full when the
    /// window is the card, gone when the page is itself.
    func setRevealAuthorBandOpacity(_ alpha: CGFloat) {
        revealAuthorBand?.alpha = alpha
    }
}
