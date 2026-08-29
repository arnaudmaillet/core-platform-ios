import DesignSystem
import UIKit

/// The single geometry authority for the comments engagement — the pure
/// in-cell layout mutation between the page's two states:
///
///   NORMAL:  full-bleed media under the overlay chrome.
///   ENGAGED: [‹]  …  [⇅ sort] [author pill]       — screen chrome
///            ( ) [ caption bubble  10 weeks ]     ┐ the comment LIST:
///            ( ) Kenji Tanaka · 20m               │ the caption is row #0
///            ( ) Lena Klein · 5m                  ┘ and scrolls with it
///            [ compose bar          🎙 ]          — clear, no frost band
///            [ a black wash, ~50%    ]            — the readability layer
///            [ the post's media, full-bleed ]     — never moves, never stops
///
/// THE MEDIA DOES NOT DOCK. It stays exactly where it was — full-bleed,
/// identity transform, still playing — and becomes the BACKGROUND of the
/// engaged screen — at identity, square-cornered, untouched. A plain black
/// wash pushes it back in depth so the stream reading over it stays legible
/// WITHOUT blurring the photo away. (The 88pt tile that
/// preceded this is gone, and with it the crop masks, the media's own glass
/// card, and the whole bug class that came from the engagement owning the
/// media's transform — every path that reset it had to branch on the
/// engagement, and three separate defects came from one that didn't.)
///
/// (Author identity deliberately does NOT appear in the card: the nav
/// pill — screen chrome — already carries it, and fading the pill means
/// fighting its glass platter. One identity, zero duplication.)
///
/// ONE surface, one motion profile: every element of the mutation lives in
/// the cell's own hierarchy and animates in a single spring block (the
/// sheet, the custom presentation controller, and the reveal animators that
/// preceded this design are gone — each split the screen into two motion
/// systems, and each read as exactly that).
///
/// The background is the wash, plus two blur bands — a dense adaptive
/// material, gradient-masked so each dissolves into the stream instead of
/// ending on an edge. They do one narrow job: keeping the nav chrome and the
/// composer legible where rows glide past them.
///
/// What is left here is small on purpose: with the caption scrolling as a
/// list row, the only geometry the cell still needs is where the stream
/// starts, and that is a pure function of the frozen top inset (the feed's
/// pushed-threshold doctrine).
enum SnapCommentsLayout {
    /// The gap between the screen chrome and the first row of the stream.
    ///
    /// It was two constants summing to 20pt, and both were named for a "strip"
    /// — the floating caption card that used to sit in this band. That card is
    /// gone; the caption scrolls as the list's first row and brings the gallery
    /// card's own `captionTopInset` with it. So 20pt here was a third helping
    /// of top padding on one edge, under the 16pt the row already has.
    ///
    /// ⚠️ AND THEN THE ROW'S OWN INSET WENT TOO, so this carries it now.
    ///
    /// 4pt was right while the caption was the gallery card's content, which
    /// brought a 16pt `captionTopInset` of its own. The caption is a comment
    /// row now (see `CaptionBubbleCell`), and comment rows sit flush — nothing
    /// below this number holds the first row off the blur band any more, so the
    /// caption arrived tight against the chrome. Reported as wanting air above
    /// it, which is exactly what was subtracted.
    static let streamTopBreath: CGFloat = Spacing.lg

    // MARK: The caption bubble's interior
    //
    // The caption is no longer a floating card the cell reserves space for —
    // it is the comment list's FIRST ROW, a message bubble that scrolls with
    // everything else (see `CaptionBubbleCell`). What survives here is the
    // bubble's own styling, shared with the list cell so its interior and
    // the stream's other geometry agree.
    //
    // Everything that existed to RESERVE a fixed region for a floating card
    // is gone with the card: the caption line cap, the measured caption
    // height, the band slack, and `cardHeight`. A self-sizing list cell
    // measures its own text — that is the entire job those did, done by
    // Auto Layout instead of by hand.

    /// The bubble's inner content margins.
    ///
    /// `lg`, the message-bubble measure: a chat bubble's text sits well clear
    /// of its rounded edge, and at the old `md` the caption crowded a corner
    /// radius that has since grown.
    static let cardContentInset: CGFloat = Spacing.lg
    /// The interior separation between the caption and the timestamp beneath
    /// it — a comfortable breath, not a cramped hairline.
    static let captionActionsGap: CGFloat = Spacing.sm

    /// The engaged-state spring, shared by every leg of the one animation —
    /// and symmetric: the return runs the same envelope. ONE rhythm: the
    /// media's recede, the backdrop's wash, the chrome fades, the stream's
    /// fade-and-expand, and the composer's slide all breathe in this single
    /// block.
    static let engageDuration: TimeInterval = 0.45
    static let disengageDuration: TimeInterval = 0.45
    /// The composer's entrance micro-translation: it slides up into place
    /// as it fades, arriving into its stacked seat above the native bar.
    static let composerEntranceOffset: CGFloat = 15
    /// The stream's entrance scale: the whole comments layer EXPANDS into
    /// place as it fades in, rather than simply appearing there. This
    /// carries the engagement's motion now that neither the media nor a
    /// floating card morphs — without a replacement the change reads as a
    /// panel sliding over the post (the exact failure this feature
    /// diagnosed once already, by frame capture, when a coordinator block
    /// ran its legs un-animated).
    ///
    /// It moved from the caption card to the CONTAINER when the caption
    /// became a scrolling row: the motion belongs to the surface that
    /// appears, and that is now the list itself. Deliberately small —
    /// the one piece of motion the engagement still owns.
    static let streamEntranceScale: CGFloat = 0.94

    /// The skeleton density estimate: a DELIBERATE low-ball of the real
    /// skeleton row's height (~48pt with list insets), because the count
    /// is viewport ÷ estimate — the smaller the estimate, the MORE rows,
    /// and over-provisioning is free (the list clips the excess) while
    /// under-provisioning strands blank space above the input bar.
    static let skeletonRowEstimate: CGFloat = 44
    /// How many shimmer rows the first-load snapshot injects: enough to
    /// cover the whole viewport on ANY form factor — SE, Pro Max, iPad —
    /// with zero hardcoded gaps. The fallback covers the pre-layout call
    /// (bounds not yet set): generous enough for every iPhone.
    static func skeletonPlaceholderCount(viewportHeight: CGFloat) -> Int {
        guard viewportHeight > 0 else { return 24 }
        return Int(ceil(viewportHeight / skeletonRowEstimate))
    }

    /// The empty page's row height in the comments-only stream. The shared
    /// `EmptyStateView` centres its block in whatever bounds it is given and
    /// has no vertical intrinsic size of its own, so a self-sizing list row
    /// has to be told one.
    ///
    /// It is decided ONCE, at configuration time, and never revisited: the
    /// caller passes the room already left over by the caption row and the
    /// section insets, and `CommentsEmptyPageCell` returns exactly this for
    /// the life of the configuration. A height that resolves differently on
    /// a later pass is not a refinement — it is a block that jumps when the
    /// presentation finishes.
    ///
    /// `availableHeight` is the room the stream will have WHEN SETTLED, not
    /// the room it has mid-transition (see
    /// `PostDetailViewController.availableStreamHeight`), minus everything
    /// above the empty page.
    static let emptyPageMinimumHeight: CGFloat = 260
    static func emptyPageHeight(availableHeight: CGFloat) -> CGFloat {
        max(emptyPageMinimumHeight, availableHeight)
    }

    /// Where the engaged stream's content begins — the comments region's
    /// upper boundary, and the scroll view's top inset.
    ///
    /// It is now just the NAV ZONE plus a breath. There is no card to
    /// reserve a region for: the caption scrolls as the list's first row,
    /// so everything below the screen chrome belongs to the stream. (This
    /// used to be `topInset + padding + cardHeight + padding`, and the card
    /// height was a measured function of the caption — a whole apparatus
    /// whose only purpose was holding a fixed rectangle open.)
    static func commentsTopInset(topInset: CGFloat) -> CGFloat {
        topInset + streamTopBreath
    }

    /// The caption bubble's corner radius: the app's MESSAGE-BUBBLE radius,
    /// taken from `MessageCell` rather than picked — the caption is a bubble
    /// in a list of messages, so it is the same bubble the chat transcript
    /// draws. Applied via `cornerConfiguration` (see `SnapGlassCardView`),
    /// which is what gives it the continuous curve — a layer radius would
    /// clip the material instead of shaping it.
    static let stripCardCornerRadius: CGFloat = 18

    /// The comments region's height: everything below the screen chrome,
    /// down to the cell's bottom edge.
    static func commentsRegionHeight(containerHeight: CGFloat, topInset: CGFloat) -> CGFloat {
        max(0, containerHeight - commentsTopInset(topInset: topInset))
    }

    // MARK: The background treatment
    //
    // The media stays full-bleed behind the whole engaged screen, so the
    // stream reads over live content. ONE constant makes that legible: a
    // plain black wash. No blur, by decision — see `backdropDimOpacity`.

    /// How far the media is dimmed behind the engaged stream, and the whole
    /// readability treatment: a solid black overlay at this opacity, over
    /// undisturbed pixels. Nothing else — no blur, no material, no gradient.
    ///
    /// TWO ROUNDS OF MATERIAL WERE TRIED AND BOTH LOST THE PHOTO, which is
    /// why the treatment is now this plain. `systemThinMaterialDark` + 0.45
    /// sampled a FLAT (36,44,64) at two heights 700pt apart on a page whose
    /// media runs a yellow-green gradient from (164,164,91) to (101,100,56)
    /// — a blue-dominant constant, which that content cannot produce: it had
    /// rebuilt the black curtain this layout exists to remove.
    /// `systemUltraThinMaterialDark` + 0.28 restored the hue but still
    /// smeared the image past recognition. A dark material does not merely
    /// blur; it desaturates and tints toward its own grey, and over a
    /// full-screen photo that reads as fog.
    ///
    /// A wash has none of that: it scales luminance and leaves hue, detail,
    /// and motion intact, so the post stays the post. It is also the
    /// cheapest thing that can work — a single opaque-blend pass over a
    /// surface that may be a playing `AVPlayerLayer`, where a full-screen
    /// blur is a per-frame render-server cost. (Per-row glass was considered
    /// and declined for the same reason, plus the reply indent / thread
    /// seams / rail exclusion all fight a per-row capsule.)
    ///
    /// At 0.5 a mid-tone photo lands near luminance 78 — comfortably past
    /// 4.5:1 against white body text — while a near-white region lands near
    /// 128, about 3.9:1, which is the honest floor of this approach. Raising
    /// it buys contrast on bright media and costs visibility of the post,
    /// which is the trade this constant exists to express.
    static let backdropDimOpacity: CGFloat = 0.5

    // MARK: The chrome's frost bands
    //
    // Two dissolving bands frame the stream: one under the nav chrome, one
    // behind the composer. They exist for a narrow job — keeping the BARS
    // legible where rows glide past them — and they very nearly earned
    // themselves deleted by overreaching at full strength, where they read
    // as heavy overlays on a background whose whole point is the photo.

    /// The bands' material: the system's standard separator blur, which
    /// adapts to light and dark on its own. Density was tried and rejected
    /// anyway: what keeps the composer legible is `footerFrostLead` — the
    /// runway its ramp finishes over — not a thicker material.
    static let frostStyle: UIBlurEffect.Style = .regular

    /// The frost veil's opacity at the band's SOLID end, on pages where the
    /// blur alone cannot be seen.
    ///
    /// High at the SOLID end on purpose — that end sits against the screen's
    /// edge, under the bars. The ramp is what makes it subtle: the gradient
    /// takes this to nothing by the band's inner edge, so a comment
    /// scrolling up recedes gradually rather than meeting a lid. Left short
    /// of 1 so the blur still contributes at the edge.
    static let frostVeilOpacity: CGFloat = 0.85

    /// The veil's opacity for a given page format — zero over media, where
    /// the blur has a photo to refract and a veil would only mute it.
    static func frostVeilOpacity(hasMedia: Bool) -> CGFloat {
        hasMedia ? 0 : frostVeilOpacity
    }

    /// The HEADER band's ramp: opaque at the screen's top edge, fully clear
    /// at the container's bottom — one gradient across the whole container,
    /// two stops so there is no knee partway down.
    static var headerFrostMaskColors: [UIColor] { [.black, .clear] }
    static var headerFrostMaskLocations: [NSNumber] { [0, 1] }

    /// The FOOTER band's ramp — THE HEADER'S, MIRRORED. Clear at the band's
    /// top, full material at the screen's bottom edge, one gradient across
    /// the whole band with no knee in it.
    ///
    /// ⚠️ It used to hold: clear → full by the composer's top edge → SOLID
    /// from there down, on the rule that the composer must sit on the solid
    /// part of its own band. That rule was right about legibility and wrong
    /// about proportion — the hold made two thirds of the band a flat slab,
    /// which over a text page (where a veil stands in for a blur that has
    /// nothing to refract) reads as a lid rather than a fade. Reported as far
    /// too pronounced, and against the header band, which does exactly this
    /// and was not.
    ///
    /// The composer now sits where the nav bar sits in the header's ramp:
    /// past the middle, on strong material, but not on a plateau.
    static var footerFrostMaskColors: [UIColor] { [.clear, .black] }
    static var footerFrostMaskLocations: [NSNumber] { [0, 1] }

    /// How far ABOVE the composer the footer band starts.
    ///
    /// It was the RUNWAY the ramp had to finish over, back when the ramp
    /// finished early and held. With a single gradient it is simply how much
    /// of the page the fade is spread across — and spreading it further is
    /// what makes it gentle, so the number stays.
    static let footerFrostLead: CGFloat = 96

    // MARK: The interactive pull-down dismissal
    //
    // Dragging down at the top of the comment list collapses back to media,
    // and does it UNDER THE FINGER: the layer fades, shrinks, and un-dims in
    // step with the drag, then commits or springs back on release. The
    // earlier version fired a fixed animation once a threshold was crossed,
    // which meant the gesture had no relationship to what was on screen
    // until it was already over.
    //
    // The list's OVERSHOOT past its top is the progress — the same number
    // UIKit is already rubber-banding, so the content and the fade cannot
    // drift apart. Arming is unconditional by construction: overshoot exists
    // only at the top, so a drag anywhere else drives nothing, and no rule
    // about where the drag began is needed to say so.
    //
    // The CANCEL is free for the same reason. A pull that falls short
    // springs home under UIKit's own animation, and the scroll callbacks
    // walk the transition back to rest with it — there is no separate
    // spring to write, and none to keep in sync with the bounce.

    /// The OVERSHOOT that maps to a complete dismissal — how far past its
    /// top the list is pulled, not how far the finger moved. UIKit's rubber
    /// band damps the finger to roughly half, so this reads as about twice
    /// its number in the hand; 90 of overshoot is a deliberate,
    /// comfortable pull.
    static let pullDismissDistance: CGFloat = 90
    /// The progress at which releasing COMMITS rather than springs back —
    /// about a third of the way, so a decisive pull finishes and a hesitant
    /// one returns.
    static let pullDismissCommitProgress: CGFloat = 0.35
    /// A flick commits from any progress: past this downward velocity
    /// (points/ms) the gesture reads as a throw.
    static let pullDismissCommitVelocity: CGFloat = 1.2

    /// The transition's progress for a finger displacement: 0 fully engaged,
    /// 1 fully dismissed. Clamped, so an upward drag reads as 0 rather than
    /// running the transition backwards past its own resting state.
    static func pullDismissProgress(translation: CGFloat) -> CGFloat {
        min(1, max(0, translation / pullDismissDistance))
    }

    /// Whether a released drag should finish the dismissal or spring back.
    /// `velocity` is the release velocity in points/ms, positive downward.
    static func shouldCompletePullDismiss(progress: CGFloat, velocity: CGFloat) -> Bool {
        progress >= pullDismissCommitProgress || velocity >= pullDismissCommitVelocity
    }
}

/// The engaged screen's READABILITY LAYER: the one surface between the
/// post's full-bleed media and the comment stream reading over it.
///
/// It is a black view whose alpha animates, and deliberately nothing more.
/// No blur, no material, no gradient — two rounds of dark material were
/// tried and both cost the photo (the archaeology is on
/// `SnapCommentsLayout.backdropDimOpacity`). A wash scales luminance and
/// leaves hue, detail, and motion untouched, so the post stays legible AS
/// the post; a dark material desaturates and tints toward its own grey,
/// which over a full-screen image reads as fog.
///
/// Being plain also makes it the cheapest possible answer. It covers the
/// whole cell over a surface that may be a playing `AVPlayerLayer`, where a
/// full-screen blur is a per-frame render-server cost; an opaque-blend pass
/// is nearly free. It needs no window guard for the same reason — there is
/// no `UIBlurEffect` here to contact the render server, so unlike every
/// other effect surface in this feature it behaves identically on a
/// headless CI host and on a device.
///
/// Alpha is the animatable channel (and the only one it has), so the whole
/// treatment rides the engagement's single spring block for free.
///
/// HIT-INERT: the media behind it keeps whatever hit-testing it had, and
/// the stream in front keeps every touch. This layer owns none.
/// THE PAGE'S THEME, and the only place it is decided.
///
/// A snap page is one visual object made of surfaces that live in three
/// different view trees — the cell (its frost band and the hosted comment
/// panel), the navigation bar, and the toolbar. Nothing inherits across
/// those boundaries, so before this existed each tree answered "am I light
/// or dark?" on its own and they disagreed: in light mode a media page drew
/// white-on-light nav platters above a dark caption bubble and a dark
/// composer.
///
/// Two rules, and they follow from what is BEHIND the chrome:
///
///   • MEDIA — pinned dark. The chrome floats over an arbitrary photo or
///     video, so its contrast can only come from the material it is made
///     of; the device's appearance has no opinion worth taking here.
///   • TEXT — inherited. The page's own ground follows the system (see
///     `SnapFeedCell.configure`), so the chrome over it must too, or light
///     mode puts white glass and white text on a white page.
enum SnapChromeTheme {
    static func style(hasMedia: Bool) -> UIUserInterfaceStyle {
        hasMedia ? .dark : .unspecified
    }

    /// The same rule for something INSIDE a screen that may itself be pinned.
    ///
    /// ⚠️ `.unspecified` MEANS "ASK MY PARENT", and a page's parent is a screen
    /// that pins itself dark while a photograph is settled. So a text page
    /// scrolling in under a media page inherited DARK, then turned light at the
    /// settle when the screen's own pin was released — a whole page changing
    /// theme under the viewer, visible on any recording of the scroll.
    ///
    /// A text page follows the DEVICE, which is what it looks like it should
    /// do, and saying so explicitly is the only way to mean it from inside a
    /// subtree someone else has pinned.
    static func style(hasMedia: Bool, device: UIUserInterfaceStyle) -> UIUserInterfaceStyle {
        hasMedia ? .dark : device
    }
}

final class SnapMediaBackdropView: UIView {
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .black
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Raises (or clears) the wash. Call inside the engagement's animation
    /// block — alpha interpolates.
    func setActive(_ active: Bool) {
        setDim(active ? SnapCommentsLayout.backdropDimOpacity : 0)
    }

    /// The wash at an arbitrary opacity — the interactive dismissal ramps it
    /// down under the finger rather than switching it.
    func setDim(_ opacity: CGFloat) {
        alpha = min(max(0, opacity), SnapCommentsLayout.backdropDimOpacity)
    }

    /// The wash's current opacity — the choreography's test seam.
    var dimOpacity: CGFloat { alpha }
}


/// A blur band that DISSOLVES along its length instead of ending on a hard
/// geometric edge: a `UIVisualEffectView` alpha-masked by a vertical
/// `CAGradientLayer`.
///
/// This masked-effect-view pair IS the native way to build a blur gradient —
/// UIKit has no gradient-blur type, blur strength is not a settable
/// property, and alpha on an effect view is unsupported. So the material is
/// the system's own (`.regular`, set by the callers, which adapts to light
/// and dark) and the gradient decides only WHERE it lands.
///
/// Two mechanics, both load-bearing: the mask must be a VIEW assigned to
/// `mask` (UIKit propagates it through the effect's internal backdrop
/// layers; masking `layer` directly breaks effect rendering), and its frame
/// is re-bound to the bounds every layout pass — the footer band resizes
/// when the keyboard lifts the composer, and a stale mask frame shears the
/// ramp.
final class ProgressiveFrostView: UIVisualEffectView {
    private let fadeMask: GradientView
    /// A veil of the PAGE's own colour, under the same ramp as the blur.
    ///
    /// Blur is a refraction, so it can only show you what it has to work
    /// with: over a photo it is obvious, and over a text page's flat ground
    /// it is arithmetically almost a no-op. Measured on a white page, the
    /// band rendered #F9F9F9–#FCFCFC against #FFFFFF — a difference you can
    /// measure and cannot see, which is why the bands read as "missing"
    /// there. The veil is what gives the ramp something to say on a flat
    /// ground: content sliding under it recedes toward the page colour
    /// instead of staying perfectly crisp until it hits the bar.
    ///
    /// It lives in `contentView` (the supported place to put content over an
    /// effect) and is therefore masked by the SAME gradient — one ramp
    /// governs both layers, so they can never disagree about where the band
    /// ends.
    private let veil = UIView()
    /// When set, the ramp occupies exactly this many points from the band's
    /// TOP edge and the rest holds full material — resolved against the
    /// live height every layout pass, so a band that grows (the footer's
    /// does, when the keyboard lifts the composer) keeps the fade the same
    /// physical length instead of stretching it. A fixed fraction cannot do
    /// that, and a stale one shears the ramp.
    private let topRampLength: CGFloat?

    /// `maskColors`/`maskLocations` describe the mask's OPACITY ramp
    /// top→bottom: opaque = full material, clear = none.
    init(maskColors: [UIColor], maskLocations: [NSNumber], topRampLength: CGFloat? = nil) {
        fadeMask = GradientView(colors: maskColors, locations: maskLocations)
        self.topRampLength = topRampLength
        super.init(effect: nil)
        isUserInteractionEnabled = false
        mask = fadeMask
        // `secondarySystemBackground` — the system's "one step recessed from
        // the page" surface — and NOT `systemBackground`.
        //
        // The page's own colour was the first attempt and it is invisible by
        // construction: a white veil over a white page changes nothing
        // (measured — the band still read #F9F9F9 against #FFFFFF). It would
        // still mute content passing under, but the band itself would have
        // no presence, which is half the job. One step recessed gives both:
        // content recedes toward it, and the strip reads as a distinct
        // surface even with nothing behind it. Semantic, so it resolves for
        // whichever theme the page is wearing (`SnapChromeTheme`).
        veil.backgroundColor = .secondarySystemBackground
        veil.alpha = 0
        veil.isUserInteractionEnabled = false
        veil.pin(to: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Raises (or clears) the veil. Media pages leave it at zero — a blur
    /// over a photo is already doing the work, and a veil there would only
    /// mute the media the layout exists to show.
    func setVeilOpacity(_ opacity: CGFloat) {
        veil.alpha = min(max(0, opacity), 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fadeMask.frame = bounds
        guard let topRampLength, bounds.height > 0 else { return }
        // Clamped under 1 so a band shorter than its own ramp still fades
        // rather than inverting into a hard edge.
        let stop = min(0.95, max(0, topRampLength / bounds.height))
        fadeMask.setLocations([0, NSNumber(value: Double(stop)), 1])
    }
}
