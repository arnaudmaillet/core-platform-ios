import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// The hero flight: what hides while a twin is in the air, and the furniture's return
extension PostGridListRowCell {
    /// Hides ONLY the preview while its twin is in the air.
    ///
    /// A row is a card of which the media is one part, and the flight carries
    /// that part (`mediaHeroRect`) — so that part is exactly what must
    /// disappear. Hiding the whole cell instead, which is what a tile needs,
    /// took the caption, the author line and the metrics with it: they were
    /// missing for the length of the flight and snapped back at its last
    /// frame, because nothing in the air was standing in for them.
    ///
    /// The invariant, in one line: CONCEAL EXACTLY WHAT THE FLIGHT
    /// REPRODUCES. A tile is its media, so the tile hides whole; a row is not,
    /// so it does not. A text row never flies at all — it pushes natively.
    ///
    /// Alpha, not `isHidden`, and that is load-bearing: `mediaHeroRect`
    /// reports nil for a hidden preview, so hiding it would make the row
    /// unable to answer where its own media is — which is the rect the
    /// DISMISSAL flies home to.
    ///
    /// The metadata pills go with it, and they get there for free: they are
    /// subviews OF the preview, so the one alpha carries them. That is why they
    /// were built inside it rather than over it in the card — a chip left
    /// floating on an empty rounded box for the length of a flight is the same
    /// defect as a caption that vanishes, on a smaller scale, and the way not
    /// to have it is to have no second channel to keep in step.
    public func setHeroMediaConcealed(_ concealed: Bool) {
        // A COLLECTION conceals one PAGE, not the preview.
        //
        // The rule is the same one this method's note states — conceal exactly
        // what the flight reproduces — read one level further in: a flight from
        // a collection carries the current page, so the box, the neighbour's
        // peek and the chips all stay. Hiding the box took the peek and the
        // chips with it and brought the whole strip back in one frame at the
        // landing, which is the pop this rule exists to prevent, rebuilt inside
        // the preview it was written for.
        // ⚠️ REMEMBERED, because a flight outlives a configure.
        //
        // A row can be re-dequeued and reconfigured while its twin is in the
        // air, and `prepareForReuse` resets the furniture to visible. The
        // concealment was applied to the instance that flew, so the fresh one
        // came back with its play badge lit in the MIDDLE of a dismissal —
        // on single-media rows only, because a collection's badge is hidden
        // outright by `post.isCollection` and so has nothing to reveal.
        // ⚠️ Only a flight ENDING earns the settle. `prepareForReuse` comes
        // through here too, and animating there would flutter the chips of
        // every row a scroll recycles — a cost paid continuously for an effect
        // that belongs to one moment.
        let wasConcealed = isHeroMediaConcealed
        isHeroMediaConcealed = concealed
        // ⚠️ THE FURNITURE GOES IN BOTH SHAPES, and that is the unification.
        //
        // A single attachment hid its chips for free — they are subviews of the
        // preview, and the preview went to alpha 0. A collection conceals only
        // the PAGE, so its counters, date and indicator stayed lit through the
        // whole flight while the single-media version's vanished. Same gesture,
        // two behaviours, which is exactly the doubt raised about whether this
        // was ever really unified. It was not.
        //
        // What the flight carries is the media. What it does not carry is the
        // furniture — so the furniture goes, in both.
        for view in furnitureViews { view.alpha = concealed ? 0 : 1 }
        if let carousel, !carousel.isHidden {
            carousel.setCurrentPageConcealed(concealed)
        } else {
            mediaView.alpha = concealed ? 0 : 1
        }
        if wasConcealed, !concealed { animateFurnitureIn() }
    }

    /// Everything the preview wears that the flight does not reproduce.
    private var furnitureViews: [UIView] {
        // Nothing, since the counters and the page indicator moved to the
        // closing line under the preview: the flight carries the media and
        // the card around it stays, line included.
        []
    }


    /// Brings the chips, the date and the badge back with a settle rather than
    /// a switch.
    ///
    /// ⚠️ The MEDIA is deliberately not animated. The flight has just handed the
    /// picture over; fading THAT in would show the hand-off instead of hiding
    /// it. What pops is the furniture — counters, date, badge — which the flight
    /// never carried and which therefore arrives from nothing on the landing
    /// frame.
    private func animateFurnitureIn() {
        // ⚠️ NOT ALL AT ONCE, AND NOT AS ONE PIECE.
        //
        // Four chips arriving on the same frame with the same curve read as a
        // single sheet being switched on — the eye sees one event, not four
        // objects. A few hundredths of a second between them is enough for it
        // to read as things settling into a row.
        //
        // And each capsule's CONTENTS lag its shape by a couple of points. A
        // label transformed with its capsule is one object sliding; a label that
        // arrives a moment after the shape it sits in makes the shape read as a
        // container the text drops into. It is a small dishonesty about physics
        // and it is what makes the row feel alive rather than assembled.
        // ⚠️ FADE AND SCALE, NO TRANSLATION.
        //
        // A chip that slides in comes FROM somewhere, and there is nowhere for
        // it to have come from — it was always at that spot, merely invisible.
        // Growing into place says the true thing: this was here, and it is
        // arriving. The spring is deliberately shallow; a pronounced bounce on
        // four small capsules reads as a toy.
        for (index, view) in furnitureViews.enumerated() where !view.isHidden {
            let contents = (view as? PostMetaPillView)?.contentRow
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
            contents?.alpha = 0
            contents?.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            let step = 0.04 * Double(index)
            UIView.animate(
                withDuration: 0.36, delay: step,
                usingSpringWithDamping: 0.78, initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                view.alpha = 1
                view.transform = .identity
            }
            // The contents run the same curve a beat later, so the capsule
            // reads as a container the text grows into rather than as one solid
            // thing changing size.
            UIView.animate(
                withDuration: 0.36, delay: step + 0.06,
                usingSpringWithDamping: 0.78, initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                contents?.alpha = 1
                contents?.transform = .identity
            }
        }
    }

    /// Hides whatever THIS row's flight is carrying, for as long as it is in
    /// the air — and the routing lives here because only the row knows.
    ///
    /// A media row flies its preview and keeps the rest: caption, counters and
    /// author stay put, because none of them left. A TEXT row has no preview,
    /// and what a reveal carries away is the card itself — so the card is what
    /// goes.
    ///
    /// Without this a dragged window and the row it came from show the same
    /// post twice, side by side, which is not a hero picking a card up; it is a
    /// copy being made. The grid keeps the row's SLOT either way, so nothing
    /// reflows underneath while the viewer is holding it.
    /// ⚠️ CONCEALING CHOOSES A CHANNEL; RESTORING PUTS BACK BOTH.
    ///
    /// The routing reads `mediaView.isHidden` — which post this row is bound to
    /// RIGHT NOW — and a flight outlives that answer. Conceal a text row (the
    /// whole card goes to alpha 0), let the row be reconfigured with a post
    /// that HAS media, and the restore took the other branch: it cleared a
    /// media concealment that was never set and left the card at alpha 0. An
    /// invisible card that still holds its slot is a hole in the feed, one card
    /// tall, and it survives every later pass because nothing else looks at
    /// that channel.
    ///
    /// Asymmetric on purpose: hiding the wrong thing shows the post twice mid
    /// flight, so the conceal has to be exact. Putting back something that was
    /// never taken costs nothing.
    /// What the transition is carrying away from this row, which is the only
    /// thing that decides what has to be hidden underneath it.
    ///
    /// ⚠️ NOT THE ROW'S OWN KIND, which is what this used to infer it from. A
    /// hero flight lifts the MEDIA out of a media row, so the media is what
    /// goes and the card's words stay. A reveal's window carries the WHOLE
    /// CARD, whatever the row happens to contain — so a close that starts on a
    /// text post and lands on a media row hid only that row's picture and left
    /// its author line, caption and metrics on screen under a window that was
    /// drawing them too. Filmed.
    public enum HeroCarry {
        /// The flight took the picture; the card around it stays.
        case media
        /// The window took the whole card.
        case card
    }

    public func setHeroConcealed(_ concealed: Bool, carrying carry: HeroCarry = .media) {
        guard concealed else {
            card.alpha = 1
            setHeroMediaConcealed(false)
            return
        }
        // A row with no media has nothing smaller to hide than itself, so both
        // carries agree there — which is why inferring from the kind looked
        // right for as long as only text rows opened windows.
        if carry == .card || mediaView.isHidden {
            card.alpha = 0
        } else {
            setHeroMediaConcealed(true)
        }
    }


    /// The card's own rounding and fill, so a flight impersonating this row
    /// is its twin rather than an approximation of it. Restating either as a
    /// literal in the flight card is how the two drift.
    /// The platform's own radius for a grouped content card.
    ///
    /// There is no named constant to read: iOS 26's `UICornerRadius` offers
    /// only `.fixed(_)` and `.containerConcentric(minimum:)`, and a card at the
    /// root of a scroll view has no rounded container to be concentric with. So
    /// the default is taken from what UIKit DRAWS — an `.insetGrouped` list
    /// section, which is the system's own version of this shape.
    ///
    /// Measured off one, on two independent sections, by fitting the corner
    /// profile `dx = R - sqrt(2·R·dy - dy²)`: **24.8pt (rms 0.28)** and
    /// **25.3pt (rms 0.16)**. The pipeline is calibrated against known radii and
    /// runs a couple of percent low, which puts the true value at 25–26.
    ///
    /// ❌ Two bespoke values were tried against the system context menu first
    /// and both are recorded here so they are not re-derived: **32**, the
    /// menu's own radius, which makes the two curves identical and therefore
    /// makes the band between them swell through the turn (20.0pt on the
    /// straights, 22.8pt at 45°); and **48**, the menu's radius plus the 16pt
    /// margin it sits at, which does hold the band flat (15.5–16.3pt at every
    /// angle) and is simply too round for a card. Matching a transient overlay
    /// was the wrong target — the card is on screen all the time, and it should
    /// look like the platform.
    public static let cardCornerRadius: CGFloat = Surface.cardCornerRadius

    /// How far every child of a card is held off its edges: the caption, the
    /// author band, the closing metric line, and the media preview, which is
    /// the point — text and image share one pair of vertical lines rather than
    /// each having its own.
    ///
    /// ## It is not only a margin
    ///
    /// It is the card's ONE free number, and it sets four things at once:
    ///
    /// * the reading padding of a card,
    /// * where the preview's edges fall (on the caption's),
    /// * **the preview's radius** — it chose 14 (`cardCornerRadius -
    ///   contentInset`) while the rows were cards; the radius is its own
    ///   constant now (`mediaCornerRadius`, #2290),
    /// * the reading padding of the post's own PAGE — `captionInset` is shared
    ///   with `PostCaptionRowView` structurally, because a reveal has to land
    ///   the window's caption on the card's.
    ///
    /// The third is the one that is easy to miss and the reason this value
    /// cannot be argued to. A card at 26 with a 16pt padding gives a 10pt
    /// preview: correct by the concentric rule and a 2.6× drop in roundness
    /// between the container and the thing inside it, which reads as a hard
    /// rectangle in a soft card.
    ///
    /// **12**, chosen off three builds side by side:
    ///
    /// ```
    ///   padding   preview   drop     page prose
    ///   16        10        2.6x     16   the loosest, and the widest gap
    ///   12        14        1.9x     12   ← here
    ///   10        16        1.6x     10
    ///    8        18        1.4x      8   ❌ measured cramped, page worse
    /// ```
    ///
    /// ❌ 8 is recorded rather than merely rejected: geometrically it is the
    /// most homogeneous of the four, and it is still wrong. It was tried whole —
    /// one number governing every curve in the card (26 → 18 → 10, a constant
    /// band at all three levels, chips landing within half a point of their own
    /// capsule) — and the arithmetic being perfect did not save it. The card
    /// reads cramped, and because the page shares this number, a full column of
    /// prose ended up 8pt from the screen's edge.
    public static let contentInset: CGFloat = 12

    /// The gap between two chips of the preview's bottom row. Smaller than the
    /// inset that holds the row off the preview's edges: chips in one row belong
    /// together more closely than the row belongs to the frame.
    public static let chipGap: CGFloat = 6

    /// The closing line's glyphs, named once so a test can ask the runtime
    /// whether each one exists.
    ///
    /// ⚠️ A NAME THAT DOES NOT RESOLVE IS AN EMPTY BUTTON, NOT AN ERROR — see
    /// `IconActionBarTests.everyGlyphThisBarIsGivenResolves`. Comments and
    /// repost are the app-wide `PostActionSymbol`s, so the card and the post
    /// screen's toolbar cannot drift apart.
    public enum ActionSymbol {
        public static let comments = PostActionSymbol.comments
        public static let like = AppSymbol.like.rawValue
        public static let repost = PostActionSymbol.repost
        public static let save = SaveStar.outlineGlyph
        public static let saved = SaveStar.glyph
    }

    /// How far the preview's own furniture — the metadata pills, the play badge
    /// — is held off its edges. `contentInset` again, and that is the point.
    ///
    /// ## Why furniture may be a capsule, and the preview may not
    ///
    /// The concentric rule — a child's radius is its parent's less the inset
    /// between them — is about CORNERS. It exists because two curves turning
    /// together at a corner have a band between them, and unless the radii
    /// differ by exactly the inset that band swells through the turn. Along a
    /// STRAIGHT edge there is no such constraint: the band is the inset, at
    /// every point, whatever shape the child is.
    ///
    /// So the question for a chip resting on the preview is not what radius the
    /// arithmetic gives it (a rectangle, at any padding worth using) but whether
    /// it is anywhere near the preview's corners at all. Held off both edges by
    /// the preview's own radius or more, it is not: a rounded rect's corner arc
    /// occupies a box of exactly its radius. The chip rests on flat edge, has no
    /// competing curve to hold a band with, and is free to be the capsule a chip
    /// should be.
    ///
    /// ❌ 8 was the first value, and it is what put the chips INSIDE the corner
    /// boxes — where a capsule's ~10.5 sat within half a point of the preview's
    /// own radius, which is the equal-radii case: measured, an 8pt band on the
    /// straights opening to 11.5 at 45°. Concentric would have fixed it at
    /// radius 2 and cost the chips their shape. Moving them off the corner costs
    /// nothing and dissolves the question.
    ///
    /// The clearance is therefore a FLOOR, not a preference: whatever the
    /// row's padding is, furniture on the preview has to start outside the
    /// preview's corner arcs — round the preview more and its corners reach
    /// further in.
    ///
    /// `CardShapeSystemTests` asserts it, because it is what the capsule is
    /// standing on.
    public static var mediaFurnitureInset: CGFloat {
        max(contentInset, mediaCornerRadius)
    }

    /// How far the media preview is held off the card's edge — named because
    /// the preview's own radius is derived from it, and the two must move
    /// together or the curves stop being parallel.
    public static var mediaInset: CGFloat { contentInset }
    /// The card's tone — `Surface.card`, so a card is lighter than the page
    /// it lies on and raised by that alone (see `Surface`).
    public static let cardFillColor: UIColor = Surface.card
    /// The caption's inset, which is the preview's, which is the card's — see
    /// `contentInset`. Public because the post's own page reproduces this exact
    /// register so a reveal's window lands its caption on the card's own.
    public static var captionInset: CGFloat { contentInset }
    public static var captionTopInset: CGFloat { contentInset }
    /// The closing metric line's placement, shared with the flight card that
    /// stands in for a text row.
    public static let metaBottomInset: CGFloat = 14
    /// NOT an inset — the gap between two counters inside the line, which is a
    /// question about reading a row of numbers rather than about where the card
    /// ends. It does not follow `contentInset`.
    public static let metaSpacing: CGFloat = 14
    /// The closing line's column: where its first ink starts and its last
    /// ink ends, from the card's edges — one plain action's padding INSIDE
    /// the caption's (`captionInset` + `PostCardPillView.plainInsets`, 20).
    ///
    /// ⚠️ NOT THE CAPTION'S COLUMN, on purpose (2026-09-30, evening). #329
    /// hung the ends so the ink sat exactly on the caption's inset, 12pt
    /// from the card's edge — typographically tidy, and the row read as
    /// pressed against the card's sides ("add a bit of horizontal space on
    /// the container of the action buttons"). Two ways to buy the air were
    /// weighed:
    ///
    /// * **wider gaps between the groups** — there is no gap to widen: the
    ///   spacer already takes all the slack between save/repost and
    ///   comments/likes, so it is the ENDS that are tight;
    /// * **an inset line** — here. Inset by exactly one action's padding,
    ///   the outer actions' BOXES (the press wash's capsule) now stand on the
    ///   caption's column rather than 8pt past it, 4pt from the card's edge:
    ///   at rest the ink breathes, and a press lights a capsule that stays
    ///   inside the text's margin instead of spilling towards the corner.
    ///
    /// **20**, chosen off three builds side by side (16 / 18 / 20). 16 still
    /// read as the ends pressed out to the card; at 20 the line is plainly
    /// its own inset row, and its last count ends where the band's "..."
    /// glyph ends above it — the card's trailing ink on one column, top and
    /// bottom.
    ///
    /// The whole line moves as one container — the date and the page
    /// indicator lead it on this column too — so the line reads as a unit
    /// under the caption, not as a row whose ends disagree.
    ///
    /// ⚠️ A CARD'S COLUMN ONLY (#2289). A list's row has no side to press
    /// against: its line stands on the caption's column instead, as does its
    /// "..." — see `closingLineInset(for:)`.
    public static var actionLineInset: CGFloat {
        captionInset + PostCardPillView.plainInsets.leading
    }
}
