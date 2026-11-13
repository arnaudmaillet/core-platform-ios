import DesignSystem
import MediaPlayback
import UIKit

/// The clip as a strip of film you push past a fixed needle.
///
/// ```
///        0:00      0:02      0:04      0:06          ← ruler, scrolls with the film
///                        ┃
///   ░░░░░░░░┃▓▓▓▓▓▓▓▓▓▓▓▓┃▓▓▓▓▓▓▓▓▓▓▓┃░░░░░░░░
///   ░ dim  ░┃  the frames kept        ┃░  dim  ░     ← the strip, one cell per sample
///   ░░░░░░░░┃▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 0:04 ▐┃░░░░░░░░
///           ↑            ↑            ↑
///        start grab   the needle    end grab
/// ```
///
/// ⚠️ **THE FILM MOVES AND THE NEEDLE DOES NOT.** Every other arrangement was
/// available — a playhead that travels along a static strip is the older, more
/// obvious one — and this is the arrangement the whole industry converged on
/// because it makes the aiming gesture *scrolling*, which needs no target. It is
/// also what forces `MediaTimelining.centringInset`: a strip that begins at the
/// left edge can never bring its first frame under a centred needle.
///
/// ⚠️ **NO GROUND, NO MATERIAL, NO PLATE** — the band's rule, stated by every
/// tenant it has. The canvas runs full-bleed underneath and a plate here would
/// cut the picture in two. What dims is the part of the CLIP being discarded,
/// which is ink on the strip rather than a surface behind it.
///
/// ⚠️ **IT ANNOUNCES ON RELEASE, NOT DURING THE DRAG.** `MediaCropSurfaceView`
/// does the same and for the same reason: a value sampled mid-gesture is not a
/// decision, and storing one would put an entry in `edits` for every frame of a
/// drag the author has not finished. `onScrub` is the separate, continuous
/// channel — it moves the picture, it does not store anything.
@MainActor
final class MediaTimelineTrackView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    enum Metrics {
        /// The timecodes. Short, because it is a chart axis.
        static let ruler: CGFloat = 13
        static let gap: CGFloat = 5
        /// The film.
        static let strip: CGFloat = 54
        /// The grab bars. The REACH is a finger's 44 and much larger; this is
        /// only what the eye needs to find them.
        static let grab: CGFloat = 12
        /// The line inside a grab bar that says it is a handle.
        static let grip = CGSize(width: 2, height: 16)
        /// ⚠️ **THE `+` A CAP CARRIES ON A CUT, AND THE CAP STAYS 12PT.** Bold at
        /// 7pt the four symbols measure 8.0 (plus), 8.33 (moon), 9.0 (zoom) and
        /// 9.33 (sun) points wide on the iOS 26.5 simulator — at least 1.33pt of
        /// white either side, which survives pixel rounding at 1x. At 8pt the
        /// sun is 10.67; at 9pt, 11.67. Widening the cap instead would move its
        /// clean 6pt corner, its shadow and every rail measured on 12, and hide
        /// more of the neighbour's film.
        static let capGlyph: CGFloat = 7
        /// ⚠️ **THIN, AND THE THINNESS IS THE POINT.** A 2pt rail around a 54pt
        /// strip reads as a border drawn on a thing; 1.5 reads as the edge of the
        /// thing itself, which is what CapCut and Instagram both draw.
        static let bar: CGFloat = 1.5
        /// The corner every piece's film is rounded to at its own two ends —
        /// preferred, then clamped per piece by `MediaTimelining.endRadius`.
        /// ⚠️ **THE FRAME'S INNER CORNERS ARE THIS CORNER**: the plates behind the
        /// held film show through exactly where it is rounded away, so the two
        /// can never disagree.
        static let filmCorner: CGFloat = 8
        /// ⚠️ **THE CAPS' OUTER CORNERS, AND 8 WAS A SPIKE.** Core Animation does
        /// not clamp a radius: on a 12pt cap rounded on one side only, anything
        /// past half its width draws a partial row instead of a curve (measured on
        /// the simulator), and exactly half draws clean. IMG.LY's editor ships the
        /// same pair — 6 outside, 8 inside.
        static let capCorner: CGFloat = grab / 2
        /// Where a rail starts inside a cap: past the cap's outer curve, still
        /// under the cap, so a rail never shows as a hair beside the curve.
        static let railInset: CGFloat = 8
        /// How far the inner-corner plates reach under the cap beside them, so
        /// their own edge is never the one on screen.
        static let filletTuck: CGFloat = 2
        /// The caps' shadow, and how far it is kept off their inner side.
        static let capShadowBlur: CGFloat = 2
        /// ⚠️ **A CUT IS DAYLIGHT BETWEEN TWO ROUNDED PIECES, NOT A WHITE BAR.**
        /// Asked for in those words — *"plutôt séparer les segments avec un léger
        /// espace et arrondir les bords"*. The daylight is CARVED OUT OF THE FILM
        /// (`MediaTimelining.spans`), centred on the cut, and the clock keeps none
        /// of it. Two points, so each half is a whole pixel at 1x, 2x and 3x and
        /// the needle, which is as wide, still hides the cut it stands on.
        ///
        /// ⚠️ **AND A SPLIT HAS TO BE SEEN.** Cutting a clip keeps both halves, so
        /// a split that drew nothing would change the export and leave the track
        /// looking exactly as it did — a cut nobody can aim. The daylight and the
        /// two rounded ends are what say it happened.
        static let seamGap: CGFloat = 2
        /// How close two `+` marks may stand before the one between is left out
        /// — a disc and a little air.
        static let seamSpacing: CGFloat = 26
        /// The film, collapsed, while a cut's transition is being chosen.
        static let line: CGFloat = 4
        /// The track above the transitions row: the ruler, and the line inside
        /// its two rails' worth of room.
        static let compactHeight: CGFloat = ruler + gap + bar + line + bar
        /// The stretch the preview loops, drawn over the line.
        static let rehearsal: CGFloat = 7
        /// The transition itself, standing proud of the stretch.
        static let window: CGFloat = 12
        /// A cut with nothing on it still shows where it is.
        static let windowMinimum: CGFloat = 3
        /// ⚠️ **ROUNDED, AND ASKED FOR**: *"la zone de l'animation (rectangle
        /// blanc) doit avoir les corners un peu plus arrondis"*. Clamped to half
        /// the mark's width, so the bare cut's 3pt tick is a pill, not a spike.
        static let windowCorner: CGFloat = 4
        /// Room kept between the looped stretch and the track's end, with the
        /// needle at the stretch's start.
        static let rehearsalMargin: CGFloat = 16
        /// How much film either side of a transition the preview loops: at
        /// least this, at most the longer one.
        static let shortestLead: Double = 0.5
        static let longestLead: Double = 2
        /// The play/pause button at the head of the ruler row.
        static let control: CGFloat = 22
        /// How far past an overlay the ruler takes to come back — the crop tools'
        /// chip strip fades over the same distance for the same reason.
        static let fade: CGFloat = 26
        /// The pill at the trailing end of the ruler carrying how long the
        /// result will run.
        static let readout = CGSize(width: 78, height: 15)
        static let needle: CGFloat = 2
        static let needleCap: CGFloat = 7
        /// The stamp a piece carries when it is not playing as shot.
        static let stampInset: CGFloat = 3
        /// Daylight between two chips of the shot list, so a row of them reads as
        /// several pieces rather than one strip.
        static let shotGap: CGFloat = 10
        /// ⚠️ **THE DAYLIGHT THAT SURVIVES THE LIFT.** The chip in hand grows, and
        /// a ratio grows a wide chip by more than the gap beside it: at 1.06 a
        /// 180pt chip gained eleven points and swallowed four points of daylight
        /// whole — reported as the pieces touching while being re-ordered. The
        /// lift is capped so this much always remains on either side.
        static let shotDaylight: CGFloat = 6
        /// Room at both ends of the shot list for the first and last timecodes,
        /// which are CENTRED on the list's outer edges.
        static let shotInset: CGFloat = 16
        /// How close two seams' timecodes may come before the one between is
        /// left out — a "0:00" at this size is about twenty points wide.
        static let shotMarkSpacing: CGFloat = 30
        /// How much the chip in the author's hand grows. ⚠️ **CAPPED, AND THE
        /// CAP IS MEASURED** — `SelectedMediaTrayView` records the same number
        /// arrived at the same way: past this the lifted thing reaches its
        /// neighbours and the row clips what it is trying to show off.
        static let inHand: CGFloat = 1.06
        /// How small a chip starts when the list appears, and how small it goes
        /// when the list is put away — enough to read as coming from its centre,
        /// not so much that it reads as a zoom.
        static let arriving: CGFloat = 0.9
        /// ⚠️ **THE NARROWEST SLOT OF THE SHOT LIST: ONE SQUARE OF FILM AND ITS
        /// DAYLIGHT.** Shared out evenly, a dozen pieces left chips twenty points
        /// wide; past this the list grows wider than the track and scrolls.
        static let shotMinimum: CGFloat = strip + shotGap
        /// How far in from either end of the track a carried chip starts the list
        /// scrolling by itself — a finger's width, so a thumb resting against
        /// the bezel is well inside it.
        static let edgeZone: CGFloat = 56
        /// How fast the list scrolls with the chip pressed against an end: nine
        /// slots a second, quick enough to cross a long list and slow enough
        /// that each crossing can still be felt.
        static let edgeSpeed: CGFloat = 600
        /// ⚠️ **HOW MANY DECODED PICTURES MAY BE ALIVE AT ONCE — CHARTER T3.**
        /// A 54pt tile on a 3x screen is 298x167px, which is 198 KB; six hundred
        /// of them, an eager ten-minute strip, is 116 MB for a band 74pt tall.
        /// The window on screen is about sixteen, so this is three screenfuls of
        /// slack either side of wherever the author is.
        static let mostDecoded = 48
    }

    /// ⚠️ `nonisolated` SO A TENANT'S OWN `Metrics` CAN ADD IT UP — the same
    /// reason `StraightenDialView.height` is, and it cost a build once.
    /// ⚠️ **THE FRAME IS PART OF THE HEIGHT, AND FORGETTING IT CLIPPED THE
    /// BOTTOM RAIL AWAY.** The selection stands one rail proud of the film at the
    /// top and one at the bottom, so the track is two rails taller than the strip
    /// it holds. Stated as a sum rather than a number because a band tenant
    /// declares its own height and nothing else knows what is in it — measured on
    /// the device as a selection with three sides.
    nonisolated static var height: CGFloat {
        Metrics.ruler + Metrics.gap + Metrics.bar + Metrics.strip + Metrics.bar
    }

    /// The side to ask the library for, which is the film's height and not the
    /// track's — the track is taller than its pictures by a ruler.
    nonisolated static var frameHeight: CGFloat { Metrics.strip }

    /// How tall the track DRAWS while the film is collapsed into a line — its
    /// own height does not change (charter F28); the room below is the
    /// transitions row's.
    nonisolated static var compactHeight: CGFloat { Metrics.compactHeight }

    /// Fired when the author lets go of a handle.
    var onChange: ((MediaTimeline) -> Void)?

    /// Fired continuously while the film moves under the needle, or while a
    /// handle is dragged — the moment to put on the canvas, and the piece it
    /// belongs to. Stores nothing.
    var onScrub: ((MediaTimelining.Moment) -> Void)?

    /// Whether a finger is on the track at all. The screen pauses playback while
    /// it is: a clip that keeps running fights every seek the scroll asks for,
    /// and the picture ends up somewhere neither the player nor the author chose.
    var onScrubbing: ((Bool) -> Void)?

    /// The author asked the clip to start or stop. The screen owns the player, so
    /// it answers by calling `showPaused(_:)` back.
    var onPlayPause: (() -> Void)?

    /// The author took hold of a piece, or put one down (`nil`).
    ///
    /// ⚠️ **A SELECTION IS NOT AN EDIT, WHICH IS WHY IT HAS ITS OWN CHANNEL.**
    /// `onChange` stores a timeline; this stores nothing at all. What it changes
    /// is what the toolbar's actions are pointed at.
    var onSelect: ((Int?) -> Void)?

    /// The author tapped the `+` on a cut — the one after piece `n`.
    ///
    /// ⚠️ **NO LISTENER, NO MARKS.** A `+` that nobody answers is a control
    /// that does nothing, so the track draws them only once the screen is
    /// listening.
    var onSeam: ((Int) -> Void)? {
        didSet { setNeedsLayout() }
    }

    let scroller = ChipScrollView()
    let content = UIView()
    /// ⚠️ **THE RULER LIVES OUTSIDE THE SCROLLER, AND IT USED TO LIVE INSIDE.**
    /// A `UIScrollView`'s `bounds.origin` IS its content offset, so a mask framed
    /// in its bounds travels with the content — `MediaCropToolsView` records
    /// exactly this, seen on screen as a chip guillotined mid-letter. The ruler
    /// has to fade where it passes behind the play button and behind the readout,
    /// so it hangs in a host that does not scroll and is moved by hand instead.
    let rulerHost = UIView()
    let ruler = RulerView()
    /// ▶︎ / ❚❚, the owner's (#2276): a configured button, so the app's play ⇄
    /// pause swap (`PlayPauseGlyph`) can replace its symbol instead of a cut.
    let playButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.preferredSymbolConfigurationForImage = MediaTimelineTrackView.playGlyphConfiguration
        return UIButton(configuration: configuration)
    }()
    /// The play button's glyph: 13 pt semibold, as it always drew.
    static let playGlyphConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    let film = UIView()
    let topBar = UIView()
    let bottomBar = UIView()
    let keptLabel = UILabel()
    let startGrab = UIView()
    let endGrab = UIView()
    let startGrip = UIView()
    let endGrip = UIView()
    /// The `+` — or the transition's symbol — a cap standing on a cut carries in
    /// place of its grip.
    let startGlyph = UIImageView()
    let endGlyph = UIImageView()
    /// The symbol each glyph is drawing, so a layout that changes nothing looks
    /// nothing up (T8).
    private var startGlyphName: String?
    private var endGlyphName: String?
    #if DEBUG
    var capGlyphImageAssignments = 0
    #endif
    let needle = UIView()
    private let needleCap = UIView()
    /// ⚠️ **THE FILM'S OWN FOOTPRINT WHILE IT HAS NO PICTURES — NOT A PLATE.**
    /// The band forbids a surface behind its tenant, and this does not break that
    /// rule: it is drawn in the rectangle the film is about to occupy, clipped to
    /// what is on screen, and it goes the moment there is anything at all to
    /// show. Without it the track opens as a white selection drawn around
    /// nothing, which is exactly how it was reported — "the timeline does not
    /// appear when it loads".
    let skeleton = SkeletonBoneView(rounding: .fixed(Metrics.filmCorner))
    /// The four plates behind the held piece's film that round the frame's
    /// inner corners — top leading, top trailing, bottom leading, bottom
    /// trailing. See `MediaTimelining.fillets`.
    let innerCorners: [UIView] = (0..<4).map { _ in UIView() }
    /// ⚠️ **WHILE A PIECE IS CARRIED THE TRACK BECOMES A SHOT LIST.** Reported as
    /// the carry working "partially": it did work — the order changed and the
    /// export followed — and nothing on screen said a piece had been picked up,
    /// so there was no way to tell a carry from a press that had gone nowhere.
    /// And the place a carried piece has to reach is usually off screen, on a
    /// track that cannot scroll while a finger is carrying something.
    ///
    /// Both are answered by the arrangement every editor keeps for exactly this
    /// (`MediaTimelining.shots`): one chip per piece, all the same width, the
    /// whole composition on screen at once, the one in hand lifted and the rest
    /// stood back. Asked for in those words — *"peut etre aussi reduire au grab
    /// tout les segments a des largeurs egales pour pouvoir plus facilement
    /// inserer sans avoir a parcourir toute la timeline"*.
    var shots: [ShotView] = []
    /// ⚠️ **THE SHOT LIST HAS A SCROLLER OF ITS OWN, AND IT IS NOT THE TRACK'S.**
    /// With a floor under every chip the list can run past the track's width —
    /// asked for as *"une scrollview horizontale … on peut reprendre la même que
    /// celle de la timeline"* — so it is a `ChipScrollView`, the band's shared
    /// horizontal scroller. The track's own is out of the question: its content
    /// is the film, its offset is the needle, and it is put away with the rest
    /// of the track for the length of the carry. Hidden at rest, so it never
    /// stands between a finger and the film.
    let shotList = ChipScrollView()
    /// Where the carrying finger is, in the track's own coordinates — asked again
    /// whenever the list moves under it.
    var carryX: CGFloat?
    let edgeScroll = EdgeScrollProxy()
    /// When the list last scrolled by itself.
    var edgeScrollBeat: CFTimeInterval = 0
    /// Everything the track draws that is NOT the ruler: what is put away while
    /// the shot list is up.
    ///
    /// ⚠️ **PUT AWAY, NOT STOOD BACK — AND STANDING IT BACK WAS REPORTED.** A
    /// semi-transparent scrim left the film, the frame, the seams and the needle
    /// showing through the chips: *"on aperçoit la timeline par derrière (il y a
    /// un fouillis car tout est en semi transparent)"*. While a piece is carried
    /// the only things on the band are the chips and the ruler that counts them.
    var partsOfTheTrack: [UIView] {
        [scroller, skeleton, needle, needleCap, playButton, keptLabel]
    }
    /// A shot list that is on its way back down to the track. The chips are laid
    /// on the pieces they belong to and taken away when the animation lands, and
    /// without this the layout would remove them mid-flight.
    var isPuttingDown = false
    /// ⚠️ **SELECTION FEEDBACK, NOT IMPACT.** Apple's rule: selection feedback
    /// "communicates movement through a series of discrete values", which is what
    /// a piece crossing another is; an impact is for a collision. One tick when
    /// the piece lifts and one per crossing — never on every beat of the drag,
    /// which the HIG calls decorative noise.
    /// One stamp per piece that is not playing as shot.
    var rateStamps: [UILabel] = []
    /// What each stamp last said, so a scroll re-sets nothing.
    var rateStampWords: [String] = []

    /// The symbol a filtered piece's stamp carries.
    static let filterStampGlyph = "camera.filters"

    static func filterStamp(rate: String?) -> NSAttributedString {
        let symbol = UIImage(
            systemName: filterStampGlyph,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        )?.withTintColor(.white, renderingMode: .alwaysOriginal)
        let stamp = NSMutableAttributedString(attachment: NSTextAttachment(image: symbol ?? UIImage()))
        if let rate {
            stamp.append(NSAttributedString(string: " " + rate))
        }
        return stamp
    }
    /// Every `+` the track would draw, worked out on the last layout.
    var seamMarks: [MediaTimelining.SeamMark] = []
    /// The `+` buttons on screen, keyed by their cut.
    var seamButtons: [Int: SeamButton] = [:]
    var spareSeamButtons: [SeamButton] = []
    /// Every cut VoiceOver can reach, as last spoken.
    var spokenSeams: [MediaTimelining.SpokenSeam] = []
    /// Where the finger the tap recogniser — or the press — is following
    /// LANDED, in content points.
    var tapLanding: CGFloat?
    var liftLanding: CGFloat?

    /// Whether the film is collapsed into a line, for choosing a transition.
    var isCompact = false
    /// Bumped by every collapse and every return, so an animation that lands
    /// after a newer one began tidies nothing away.
    var compactTurns = 0
    /// The line: one piece of it per piece of film near the screen.
    var lineSegments: [UIView] = []
    /// The stretch the preview loops, and the transition inside it.
    let rehearsalBar = UIView()
    let windowMark = UIView()
    var rehearsalRange: ClosedRange<Double>?
    var rehearsalWindow: ClosedRange<Double>?

    /// Clear under the play button, solid across the middle, clear again under
    /// the readout: what a timecode passes through on its way behind either.
    let rulerFade: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor.clear.cgColor, UIColor.clear.cgColor,
            UIColor.black.cgColor, UIColor.black.cgColor,
            UIColor.clear.cgColor, UIColor.clear.cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        return gradient
    }()

    /// How wide one second of film is drawn, which a pinch varies — charter F15.
    ///
    /// ⚠️ **AN INSTANCE VALUE, NOT THE TYPE'S CONSTANT.** Every function in
    /// `MediaTimelining` already takes it as a parameter precisely so that a zoom
    /// could exist; the type's value is only the starting point.
    var pointsPerSecond = MediaTimelining.pointsPerSecond
    /// The moment under the needle when a pinch began, so the film zooms around
    /// what the author is looking at rather than around its own beginning.
    var zoomAnchorSeconds: Double = 0
    var isZooming = false
    /// What the play button is currently drawing, so a beat that changes nothing
    /// costs a comparison rather than an image lookup.
    var showingPaused: Bool?

    var duration: Double = 0
    var timeline: MediaTimeline = .whole

    /// Which piece is being carried to a new place, if any.
    var reordering: Int?
    /// Where the piece in hand was lifted from: a drop elsewhere plays
    /// `drop`, a return to it nothing (#1887).
    var liftedFrom: Int?

    /// Extra room at the head of the track, for the length of a head trim.
    ///
    /// ⚠️ **WITHOUT IT THE FIRST PIECE'S START CANNOT FOLLOW A FINGER, AND THAT
    /// WAS REPORTED.** A piece begins where the one before it ends, so dragging
    /// its start shortens it from the INSIDE: the cap stays put and the other end
    /// moves. The track pays for the gesture by scrolling under the finger — and
    /// a scroll view will not go past its own leading inset, which for the FIRST
    /// piece it is already sitting on. The inset grows by exactly what the head
    /// has given up, for exactly as long as the drag lasts.
    var leadingSlack: CGFloat = 0

    /// Which piece the author has taken hold of, if any.
    ///
    /// ⚠️ **NIL AT REST, AND THE WHOLE TRACK USED TO BE SELECTED INSTEAD.** A
    /// clip opened already bracketed by a white frame, which says "this is what
    /// you are editing" before the author has said anything — and with more than
    /// one piece it says it about the wrong one. Selecting is now an act: tap a
    /// piece to take it, tap away to put it down. The handles belong to whatever
    /// is held, which is what makes every piece resizable rather than only the
    /// two outer edges.
    var selected: Int?
    /// Which end of the selection the finger has hold of, if any.
    var grip: MediaTimelining.Edge?
    /// Where the pince's compensation wants the film, unrounded (#2198).
    ///
    /// ⚠️ **A SCROLL VIEW ROUNDS ITS OFFSET TO THE PIXEL.** On a 2× screen
    /// 10.158 reads back as 10.0. Adding each sample's shift to the ROUNDED
    /// offset dropped up to a quarter of a point per sample, and the drops
    /// add up: the cap that should stand still slid ~1 pt over a 60 pt trim
    /// on an iPhone SE, and further over a long drag. The shifts are added
    /// here instead, and the scroller is given the sum.
    var exactDragOffset: CGFloat?
    /// ⚠️ **SET ONLY AROUND A PROGRAMMATIC SCROLL.** `setContentOffset` calls
    /// `scrollViewDidScroll` synchronously, so following the player would emit a
    /// scrub, which the screen turns into a seek, which moves the player, which
    /// moves the track. The loop is not theoretical; the flag is what stops it.
    var isFollowingPlayback = false
    var hasOpened = false

    /// ⚠️ **ON THE SCROLLER, FOR THE REASON `contentPan` IS.** `ChipScrollView`
    /// gives its own pan first refusal over any recogniser living OUTSIDE it, so
    /// a pinch on the track view would have to wait for a scroll that never fails
    /// — and never begin. A recogniser on the scroller itself is not an outsider:
    /// the rule asks `owner.isDescendant(of: self)`, and a view is its own
    /// descendant.
    lazy var pinch: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        gesture.delegate = self
        return gesture
    }()

    /// ⚠️ **A TAP, NOT A TOUCH-DOWN — AND IT MUST NOT TAKE THE TOUCH.** The
    /// scroller under it has to go on scrolling from the same finger, and a
    /// recogniser that cancelled touches would make the film feel stuck for the
    /// length of every tap. `cancelsTouchesInView = false` is the same rule the
    /// selector's touch probe is built on.
    lazy var selectTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        // A delegate only for the landing probe (`shouldReceive`); the
        // `shouldBegin` override lets it begin, as it always did.
        tap.delegate = self
        return tap
    }()

    /// ⚠️ **ONE RECOGNISER FOR THE WHOLE CARRY, AND A PAN WOULD BE A SECOND PARTY
    /// TO THE FIGHT.** A long press is CONTINUOUS: Apple's own description is
    /// that it "transitions to the Change state whenever a finger moves", so it
    /// reports the finger for the length of the drag by itself. Requiring the
    /// scroller's pan to fail this one instead would delay EVERY scroll by the
    /// press duration, which is the trade `ChipScrollView` refuses everywhere
    /// else in this app.
    ///
    /// ⚠️ **AND `allowableMovement` IS A PRE-RECOGNITION GATE, WHICH THIS READ AS
    /// A TRAVEL ALLOWANCE.** It stopped mattering the instant the press began;
    /// what it actually decided was whether a finger that had ALREADY MOVED could
    /// still lift a piece. Set to infinity it said yes — so a slow scroll held
    /// for a third of a second lifted the piece it had started on and took the
    /// film hostage mid-drag. Movement before the press is a scroll and must stay
    /// one, which is the platform's own default and the first pitfall every
    /// drag-to-reorder guide names.
    lazy var lift: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(carried))
        press.minimumPressDuration = 0.35
        press.delegate = self
        return press
    }()

    lazy var contentPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        pan.delegate = self
        return pan
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        // ⚠️ THE BAND HAS NO BACKGROUND, SO NEITHER DOES THIS — the filter row
        // carries the same note. A scroller with a ground of its own would put
        // back the plate the band exists to avoid.
        scroller.backgroundColor = .clear
        // The band sits above a toolbar and below a canvas; letting the system
        // add safe-area padding here would shift the needle off the centre it is
        // nailed to.
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.decelerationRate = .fast
        scroller.delegate = self

        // ⚠️ THE Z-ORDER, BOTTOM UP: the inner-corner plates, the film (one
        // rounded window per piece, its squares inside), the rate stamps, the
        // rails, the caps and their grips.
        // ⚠️ **NO CORNER RADIUS AND NO CLIPPING ON THE FILM — CHARTER T6.** This
        // view is as wide as the clip is long: four minutes at sixty points a
        // second is 14400pt, which at 3x is 43200px, and a rounded, clipping
        // layer at that width asks Core Animation for a mask far past the 16384px
        // Metal hard-asserts at. The rounded ends are drawn by each piece's
        // WINDOW, which is only as wide as the squares laid out in it — the
        // visible band and its margin, whatever the clip's length.
        film.isUserInteractionEnabled = false
        // ⚠️ **PLAIN WHITE, NO RADIUS, NO SHADOW — THE FILM IN FRONT DOES THE
        // SHAPING.**
        for plate in innerCorners {
            plate.backgroundColor = .white
            plate.isUserInteractionEnabled = false
            plate.isHidden = true
        }

        // ⚠️ **WHITE, NOT `.label` — AND IT IS NOT A DARK-MODE OVERSIGHT.** The
        // selection is drawn ON the film, which is a photograph and not a
        // background: `.label` turns the caps black over a bright clip and lets
        // them vanish into a dark one. Every reference picks one fixed colour for
        // that reason — CapCut white, Instagram yellow, TikTok red — and lifts it
        // with a shadow rather than a plate. The band's no-plate rule still
        // holds; this is ink with a shadow, which is exactly what
        // `MediaPickerGridCell`'s duration stamp already does.
        for ink in [topBar, bottomBar, startGrab, endGrab] {
            ink.backgroundColor = .white
            ink.isUserInteractionEnabled = false
        }
        for handle in [startGrab, endGrab] {
            handle.layer.cornerRadius = Metrics.capCorner
            handle.layer.cornerCurve = .continuous
        }
        startGrab.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        endGrab.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]

        // The grip is the inverse of the cap it sits in, so it reads on white.
        for line in [startGrip, endGrip] {
            line.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            line.layer.cornerRadius = Metrics.grip.width / 2
            line.isUserInteractionEnabled = false
        }
        // The `+` on a cap is the disc's ink: one meaning, one colour.
        for glyph in [startGlyph, endGlyph] {
            glyph.tintColor = .black
            glyph.contentMode = .center
            glyph.isUserInteractionEnabled = false
            glyph.isHidden = true
        }

        // ⚠️ **MONOSPACED DIGITS, OR THE NUMBER JITTERS AS IT COUNTS.** A
        // proportional "1" is narrower than a "0", so a right-aligned readout
        // ticking through 0:11 → 0:10 shifts sideways while the author drags.
        // Fixed size (#482), like the stamps below: drawn over the film strip
        // and sized with it.
        keptLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        keptLabel.textColor = .white
        keptLabel.textAlignment = .right
        keptLabel.isUserInteractionEnabled = false

        playButton.tintColor = .white
        playButton.accessibilityLabel = "Play"
        playButton.addAction(
            UIAction { [weak self] _ in self?.onPlayPause?() }, for: .touchUpInside
        )
        showPaused(true)

        // ⚠️ **INK WITH A SHADOW, NEVER A PLATE.** The readout was a black pill,
        // which is the one thing the band forbids — a surface between the author
        // and their picture. What replaces the pill is not nothing: the ruler
        // FADES OUT where it would pass behind this text and behind the play
        // button, so neither ever has to compete with a timecode for the same
        // pixels.
        // ⚠️ **NO SHADOW ON THE RAILS, AND THEIR SHADOW WAS THE SEAM.** A 2pt
        // shadow around a 1.5pt bar is mostly shadow: it softens the bar's ends
        // into something that reads as rounded, and where the rail meets a cap it
        // lays a dark line across the junction — the two pieces stop looking like
        // one frame. The caps are thirteen points wide and carry the lift for the
        // whole selection; the rails ride on it.
        for lifted in [startGrab, endGrab, keptLabel, playButton] {
            lifted.layer.shadowColor = UIColor.black.cgColor
            lifted.layer.shadowOpacity = 0.3
            lifted.layer.shadowRadius = 2
            lifted.layer.shadowOffset = .zero
        }
        // The caps' blur is the one their shadow path is cut back by.
        for cap in [startGrab, endGrab] { cap.layer.shadowRadius = Metrics.capShadowBlur }

        needle.backgroundColor = .tintColor
        needle.layer.cornerRadius = Metrics.needle / 2
        needleCap.backgroundColor = .tintColor
        needleCap.layer.cornerRadius = Metrics.needleCap / 2
        for part in [needle, needleCap] { part.isUserInteractionEnabled = false }

        content.addSubview(film)
        for plate in innerCorners { content.insertSubview(plate, belowSubview: film) }
        // ⚠️ **INK, LIKE THE SELECTION** — white on the photograph, never a plate.
        for mark in [rehearsalBar, windowMark] {
            mark.backgroundColor = .white
            mark.isUserInteractionEnabled = false
            mark.isHidden = true
            mark.layer.cornerCurve = .continuous
            content.addSubview(mark)
        }
        windowMark.layer.shadowColor = UIColor.black.cgColor
        windowMark.layer.shadowOpacity = 0.35
        windowMark.layer.shadowRadius = 2
        windowMark.layer.shadowOffset = .zero
        content.addSubview(topBar)
        content.addSubview(bottomBar)
        content.addSubview(startGrab)
        content.addSubview(endGrab)
        startGrab.addSubview(startGrip)
        endGrab.addSubview(endGrip)
        startGrab.addSubview(startGlyph)
        endGrab.addSubview(endGlyph)
        scroller.addSubview(content)
        // ⚠️ BEHIND THE SCROLLER, NOT INSIDE IT. Inside, it would have to be as
        // wide as the clip is long — 43200px at four minutes, which is charter
        // T6's Metal limit — and a rounded, masked, gradient-swept layer is
        // exactly the kind that asserts there. Outside, it is never wider than
        // the track and the empty tiles are transparent, so it shows through.
        addSubview(skeleton)
        scroller.pin(to: self)

        rulerHost.isUserInteractionEnabled = false
        rulerHost.addSubview(ruler)
        rulerHost.layer.mask = rulerFade
        addSubview(rulerHost)
        addSubview(playButton)
        // The needle is NOT in the scroller. That is the arrangement.
        // ⚠️ **THE READOUT DOES NOT SCROLL, AND IT USED TO.** It was a strip of
        // ink along the bottom of the selection, which put the only number the
        // author is really choosing — how long the result runs — off the screen
        // the moment they scrolled, and off it for most of a long clip. Measured
        // on a ten-second clip in a 390pt track: the selection's trailing end is
        // 210pt past the right edge at rest, so the number was never once
        // visible. Fixed to the ruler's trailing end, it is always readable.
        addSubview(keptLabel)
        addSubview(needle)
        addSubview(needleCap)

        // ⚠️ **ABOVE EVERYTHING, AND HIDDEN UNTIL A PIECE IS LIFTED.** The track
        // under it is put away while it is up; at rest it would swallow every
        // touch meant for the film.
        shotList.showsHorizontalScrollIndicator = false
        shotList.showsVerticalScrollIndicator = false
        shotList.backgroundColor = .clear
        shotList.contentInsetAdjustmentBehavior = .never
        shotList.decelerationRate = .fast
        shotList.isHidden = true
        shotList.delegate = self
        addSubview(shotList)


        // ⚠️ **ON THE SCROLLER, NOT ON THE CONTENT — AND ON THE CONTENT THE CAPS
        // WERE UNREACHABLE.** `content` spans x = 0 to the clip's width, and the
        // caps are drawn OUTSIDE the cut: the leading one sits at `startX - 12`,
        // which for an untrimmed clip is **x = -12**. A view draws outside its
        // own bounds happily and does not receive touches there, so the pan
        // attached to `content` never saw a finger on the leading cap — and the
        // reach, measured from the cap's centre, extended inwards only. Reported
        // as the hit areas being "beside the grips rather than on them", which is
        // exactly what half a reach looks like.
        //
        // The scroller's bounds are the visible track, so everything drawn in it
        // is touchable. `location(in: content)` still converts correctly — the
        // recogniser's view and the space its position is read in are
        // independent.
        scroller.addGestureRecognizer(contentPan)
        scroller.addGestureRecognizer(pinch)
        scroller.addGestureRecognizer(selectTap)
        scroller.addGestureRecognizer(lift)
        // ⚠️ **ONE FINGER SCROLLS; TWO ZOOM.** Without this the scroll view's own
        // pan follows a two-finger gesture as happily as a one-finger one, and
        // the film slides away under a pinch that was only meant to change the
        // scale.
        scroller.panGestureRecognizer.maximumNumberOfTouches = 1
        // ⚠️ **THE HANDLE WINS, AND WITHOUT THIS BOTH WIN.** Two pans with no
        // stated relationship both recognise: the film would scroll while the
        // handle moved, at different rates, and the selection would slide away
        // from the finger. `contentPan` fails at touch-down for anything that is
        // not a handle (see `gestureRecognizerShouldBegin`), so this costs an
        // ordinary scroll nothing.
        //
        // ⚠️ AND IT MUST BE STATED THIS WAY ROUND, NOT THROUGH `ChipScrollView`'s
        // delegate rule. That rule gives the scroller first refusal over pans
        // living OUTSIDE it — the sheet's dismissal, the stack's back-swipe —
        // and returns false for its own descendants precisely so a relationship
        // like this one can be declared. Putting `contentPan` on the track view
        // instead of on the content would make it an outsider and produce a
        // cycle: each waiting for the other to fail.
        scroller.panGestureRecognizer.require(toFail: contentPan)

        // ⚠️ **A `CGColor` DOES NOT FOLLOW AN APPEARANCE CHANGE.** Everything
        // above is a `UIColor` on a view and re-resolves itself; nothing here is
        // a layer colour, which is why this view has no trait registration and
        // the strip it replaces needed one. Said out loud because the absence
        // otherwise looks like the omission it was there.

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        // ⚠️ **`.adjustable` IS A PROMISE.** The trait tells VoiceOver this can be
        // changed with a swipe, and the swipe calls
        // `accessibilityIncrement`/`Decrement`. Declaring it without implementing
        // them gives a viewer a control they can hear and cannot move.
        //
        // The end is what the pair adjusts: "how much of this clip do I keep" is
        // the question. The ruler's timecodes are deliberately not exposed — the
        // value below carries the only number a listener is after, and a scroll
        // position is not something to read out.
        accessibilityLabel = Self.trimLabel

        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        // Each half of the daylight is floored to the screen's pixels.
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let trimLabel = "Trim, adjusts the end"

    // MARK: - What it is showing

    /// ⚠️ **THE DURATION IS THE FILE'S, AND EVERYTHING IS LAID OUT AGAINST IT.**
    /// A track told one length while the file runs another places its handles
    /// over moments that do not exist.
    ///
    /// ⚠️ **REFUSED WHILE A FINGER IS DOWN, AND NOT REFUSING IT WAS A DEFECT.**
    /// The frames arrive asynchronously — a file read, then a dozen exact-time
    /// decodes — and the author can start dragging before they land. The
    /// predecessor took the value alongside the pictures and assigned it, so the
    /// landing silently reset the handle mid-drag. The pictures are decoration;
    /// the value being edited is not theirs to set.
    func configure(duration: Double, timeline: MediaTimeline) {
        // ⚠️ **NOR WHILE A PIECE IS BEING CARRIED** — the order on the track is
        // the value being edited for the length of that gesture, and the screen
        // is still holding the one it was given before the press.
        guard grip == nil, reordering == nil else { return }
        self.duration = duration
        self.timeline = timeline
        setNeedsLayout()
    }

    /// Which piece the author is holding, if any.
    var selectedPiece: Int? { selected }

    /// The arrangement the track is showing right now — which, the instant a
    /// gesture ends, is ahead of what the screen has been told.
    var arrangement: MediaTimeline { timeline }

    /// Whether a finger is holding one of the handles. ⚠️ While it is, what the
    /// canvas has to show is the EDGE — a moment of the file that the loaded
    /// arrangement may not contain at all.
    var isHoldingAnEdge: Bool { grip != nil }

    /// Puts a moment of the FILE back under the needle.
    ///
    /// ⚠️ **A RATE CHANGES THE SHAPE OF THE TRACK UNDER A STATIONARY NEEDLE.**
    /// The needle is nailed to the centre of the screen and the film moves past
    /// it, so a piece that halves in width drags every later frame leftwards —
    /// and the frame the author was looking at, and which the canvas is showing,
    /// slides away under them. Measured: with the needle on the fourth second of
    /// a ten-second clip, setting 2× left it standing on the eighth. The same
    /// rule the pinch already follows (`keepTheNeedleOnTheAnchor`), which anchors
    /// on the moment rather than on the offset.
    ///
    /// ⚠️ **THE PIECE IS PART OF THE ANCHOR.** Once pieces can be re-ordered, a
    /// moment of the file does not say where in the result it is — the same
    /// second can play twice, or third.
    func bringUnderTheNeedle(_ moment: MediaTimelining.Moment) {
        guard bounds.width > 0, duration > 0 else { return }
        isFollowingPlayback = true
        scroller.contentOffset.x = offset(
            forPlayedSeconds: MediaTimelining.playedSeconds(
                ofPiece: moment.piece, atSourceSeconds: moment.sourceSeconds,
                in: timeline, withinSource: duration
            )
        )
        isFollowingPlayback = false
    }

    /// The scroll that puts a moment of the RESULT under the needle.
    func offset(forPlayedSeconds seconds: Double) -> CGFloat {
        MediaTimelining.contentOffset(
            forPlayedSeconds: seconds, trackWidth: bounds.width,
            pointsPerSecond: pointsPerSecond
        )
    }

    /// Takes hold of a piece, or puts one down — the very routine a tap calls.
    ///
    /// ⚠️ **ANNOUNCED, BECAUSE THE TOOLBAR IS POINTED AT IT.** The rate chips
    /// show what the held piece plays at and set what it will play at; a
    /// selection the screen did not hear about would leave them speaking for
    /// whatever was held before.
    func select(_ index: Int?, notify: Bool = true) {
        let pieces = MediaTimelining.resolved(timeline, withinSource: duration)
        let next = index.flatMap { pieces.indices.contains($0) ? $0 : nil }
        guard next != selected else { return }
        selected = next
        setNeedsLayout()
        if notify { onSelect?(next) }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        recognisedTap(reportedAtContentX: gesture.location(in: content).x)
    }

    /// What a recognised tap does, from where it was REPORTED — which is not
    /// where it landed if the film moved meanwhile.
    func recognisedTap(reportedAtContentX reported: CGFloat) {
        let x = tapLanding ?? reported
        tapLanding = nil
        tap(atContentX: x)
    }

    /// ⚠️ **A TAP IS READ WHERE THE FINGER LANDED.** The film goes on moving under
    /// a resting finger while the clip plays — `follow(playedSeconds:)` stands
    /// down for a drag, not for a touch — so a tap that lasts a tenth of a
    /// second is reported up to thirty points from where it came down, which is
    /// the far side of a cap's `+`. `UploadNavigationController` reads touches
    /// the same way.
    ///
    /// ⚠️ **AND A PRESS TOO**: it is recognised a third of a second after it
    /// lands, by which time the film may have carried the neighbour under it.
    func gestureRecognizer(_ recogniser: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recogniser === selectTap { tapLanding = touch.location(in: content).x }
        if recogniser === lift { liftLanding = touch.location(in: content).x }
        return true
    }

    private func tap(atContentX x: CGFloat) {
        // Collapsed, the film is a line to read, not a row of pieces to take.
        guard !isCompact else { return }
        takeOrPutDown(atContentX: x)
    }

    func takeOrPutDown(atContentX x: CGFloat, answeringMarks: Bool = true) {
        // ⚠️ **A TAP ON A CAP THAT STANDS ON A CUT IS A TAP ON THAT CUT'S `+`** —
        // *"quand on appuie sur le + de la pince ça montre les transitions, mais si
        // on déplace la pince ça prend le comportement de la pince"*. A drag
        // never gets here: it is the handle pan's, which this recogniser loses
        // to the moment the finger travels. Asked first, before the rule that
        // keeps the held piece, and nothing may follow the call: the screen
        // collapses the track inside it.
        if answeringMarks,
           let mark = heldCapMarks().first(where: { $0.reach.contains(x) && edge(at: x) == $0.edge }) {
            onSeam?(mark.index)
            return
        }
        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        // ⚠️ **A TAP ON A CAP IS A TAP ON ITS PIECE.** The caps are drawn OUTSIDE
        // the piece they belong to, so a finger that lands on one is outside
        // every placement and would put the piece down — which reads as the
        // selection flickering off whenever somebody aims at a handle and misses
        // by a point.
        // ⚠️ **UNLESS IT LANDS ON ANOTHER PIECE'S FILM, WHICH AT A SEAM IS WHERE
        // THE CAP IS DRAWN.** A cap stands twelve points outside its own piece —
        // at an interior cut those twelve points are the neighbour's first
        // frames, under an opaque cap that now answers for its cut (above), so
        // the neighbour's VISIBLE film begins at the cap's outer edge. Swallowing a tap there meant the author could not take the
        // section on the other side of the cut by pointing at it: the tap did
        // nothing, they dragged the handle they could see, and the piece they
        // had held all along moved. Which is exactly "on ne raisonne pas par
        // clip". The band still protects a finger that misses a handle PAST the
        // film, which is what it was for.
        // ⚠️ **AND THE DAYLIGHT IS NOT A DEAD ZONE.** Which piece a finger is
        // on is asked of the CLOCK, where the pieces touch; a tap in the two
        // points carved between them takes the piece on that side of the cut.
        let under = MediaTimelining.piece(atPoints: x, in: placed)
        if let held = selected, let caps = heldCaps(), caps.claims(x),
           under == nil || under == held {
            return
        }
        // ⚠️ **A TAP ON A `+` BELONGS TO THE `+`.** The button answers it; the
        // piece on either side of the cut is not taken as well.
        if answeringMarks {
            guard shownSeam(atContentX: x) == nil else { return }
        }
        select(under)
    }

    /// Where the pictures come from. The screen sets this; the track decides
    /// WHICH pictures and WHEN.
    ///
    /// ⚠️ **THE TRACK ASKS, RATHER THAN BEING TOLD — AND THAT IS THE INVERSION
    /// CHARTER T2 NEEDED.** The screen used to fetch a whole strip and hand it
    /// over, which meant the decision "how much of this clip is worth decoding"
    /// lived somewhere with no idea where the film had been scrolled to.
    var framesProvider: (
        (_ sourceSeconds: [Double], _ height: CGFloat, _ spacing: Double) async -> [Double: UIImage]
    )?

    /// One view per visible square of film, keyed by its place on the SOURCE grid
    /// inside its piece — so a square keeps its frame for the whole of an edit
    /// and is only ever moved, revealed or hidden.
    var tiles: [MediaTimelining.Square.Place: FilmSquare] = [:]
    /// The squares the strip is drawing right now: what is asked for, what is
    /// evicted and what the poster fills in all read this.
    var squares: [MediaTimelining.Square] = []
    /// Retired views, kept to be filled in again rather than rebuilt.
    private var spareTiles: [FilmSquare] = []
    /// One rounded, clipping window per piece that has squares laid out, keyed
    /// by the piece — the same number a square's place carries, so a kept
    /// square never changes window, even after a carry renumbers the pieces.
    var windows: [Int: PieceFilmView] = [:]
    private var spareWindows: [PieceFilmView] = []
    /// What the last `refreshTiles` laid out: where each piece's TIME is, where
    /// its FILM is drawn, and the windows that show it. Read by the layout and
    /// the scroll so nothing is resolved twice a beat.
    var laidPlacements: [MediaTimelining.Placement] = []
    var drawnSpans: [MediaTimelining.Span] = []
    private var openWindows: [MediaTimelining.FilmWindow] = []
    /// The pictures that have arrived, keyed by THE SECOND OF FILM THEY SHOW.
    /// Bounded by `Metrics.mostDecoded`.
    ///
    /// ⚠️ **KEYED BY THE FILM, NOT BY THE PLACE ON THE TRACK — AND THE PLACE WAS
    /// THE DEFECT.** A tile index says where on the track a square sits; what
    /// stands there changes the moment anything is edited. Measured: on a
    /// ten-second clip cut at four, continuing the first piece to five seconds
    /// moved tile 6 from 5.85s of film to 4.85s and the strip asked for NOTHING,
    /// because every index already had a picture — so the film the drag had just
    /// revealed never appeared, and the reported symptom was that the clip did
    /// not continue at all. See `MediaTimelining.squares(in:withinSource:visible:)`.
    var decoded: [Double: UIImage] = [:]
    /// Seconds already asked for, so a scroll does not ask twice.
    private var requesting: Set<Double> = []
    /// ⚠️ **CHARTER F14: THE STRIP NEVER SHOWS EMPTY BOXES.** Until a tile's own
    /// frame arrives it shows the nearest one already decoded, so a strip being
    /// scrolled into reads as a blurred film rather than as a row of holes.
    /// `PryntTrimmerView` does the same thing with its first decoded frame, and
    /// it is the cheapest possible improvement to how the strip feels.
    var anyFrame: UIImage?

    /// The clip's own poster, handed over by the screen the moment the mode
    /// opens — the stand-in of last resort.
    ///
    /// ⚠️ **THIS IS WHAT MAKES THE TRACK APPEAR AT ONCE, AND NOTHING ELSE
    /// COULD.** Two asynchronous steps stand between opening the mode and the
    /// first picture: `PHImageManager` vending the file, then a batch of
    /// exact-time decodes. Neither can be made instant, and until both land the
    /// strip is a row of transparent boxes over the canvas — a selection drawn
    /// around nothing. The screen, meanwhile, is ALREADY HOLDING this clip's
    /// poster: it is the picture on the canvas behind the band. Handing that over
    /// costs one assignment and fills every visible tile in the same turn the
    /// mode opens.
    ///
    /// It is one frame repeated, which is the "wallpaper" `VideoFilmstripTests`
    /// exists to catch in a finished strip. Here it is charter F14 — the nearest
    /// picture we have — and every tile replaces it the moment its own arrives.
    var posterFrame: UIImage?

    /// Which film the tiles in flight were asked for. Bumped whenever the
    /// PICTURES stop meaning what they meant, which since they are keyed by the
    /// second of film they show is one thing only: a different clip.
    var framesGeneration = 0

    /// The picture to show wherever the film has none of its own yet.
    ///
    /// Restated on every clip, `nil` included: a poster left over from the
    /// previous page is a picture of the wrong film.
    func showPoster(_ image: UIImage?) {
        guard image !== posterFrame else { return }
        posterFrame = image
        for square in squares where decoded[square.seconds] == nil {
            tiles[square.place]?.picture.image = anyFrame ?? image
        }
        setNeedsLayout()
    }

    /// Throws away every picture and asks again — for a clip that changed under
    /// the track.
    ///
    /// ⚠️ **THE POSTER SURVIVES THIS, AND THE COMMENT IN `beginZoom` USED TO BE
    /// WRONG WITHOUT IT.** A pinch drops every frame because a tile's index means
    /// a different moment at every scale — and that note claims each tile keeps
    /// showing "the nearest frame it has" while the refill is in flight. It did
    /// not: this cleared `anyFrame` and blanked every tile, so the whole strip
    /// went empty for the length of the pinch. The poster is a fact about the
    /// CLIP rather than about the scale, so it stays and the film stays visible.
    func forgetFrames() {
        // ⚠️ **THE TOKEN IS WHAT ACTUALLY CANCELS A REQUEST, AND CLEARING THE
        // CACHES DOES NOT.** A batch is an unstructured `Task` that has already
        // captured its tile INDICES; emptying `decoded` and `requesting` leaves
        // it running, and when it lands it writes those indices back — into a
        // strip that is now showing a DIFFERENT CLIP, or the same clip at a
        // different zoom where an index means a different moment. The pictures
        // stay until the cache is evicted, which on a short clip is never.
        // Measured as a real sequence by the review: scroll clip A (a 16-tile
        // batch is ~170ms in flight), swipe to clip B, and B's strip shows A's
        // film.
        framesGeneration &+= 1
        decoded.removeAll()
        requesting.removeAll()
        anyFrame = nil
        for (_, view) in tiles { view.picture.image = posterFrame }
        squares.removeAll()
        setNeedsLayout()
    }

    /// Adds, retires and fills the squares of film that are on screen.
    ///
    /// ⚠️ **THE SHEET IS FIXED AND THE PIECE IS A WINDOW ON IT.** A square is
    /// identified by where it falls on the SOURCE, so an edit never changes what
    /// a square shows — only whether it is visible, how much of it is, and where
    /// its piece has got to. Opening a piece's end reveals the next squares of the
    /// sheet without moving one of them; closing it hides them again; rippling a
    /// piece along carries its squares with it.
    func refreshTiles() {
        let seen = scroller.contentOffset.x
        laidPlacements = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        drawnSpans = MediaTimelining.spans(
            of: laidPlacements, gap: Metrics.seamGap, holding: selected,
            corner: Metrics.filmCorner, height: Metrics.strip,
            scale: traitCollection.displayScale
        )
        squares = MediaTimelining.squares(
            along: drawnSpans, withinSource: duration,
            visible: (seen - MediaTimelining.filmMargin)...(
                seen + bounds.width + MediaTimelining.filmMargin
            ),
            pointsPerSecond: pointsPerSecond
        )
        openWindows = MediaTimelining.windows(of: squares, along: drawnSpans)
        let wanted = Set(squares.map(\.place))

        for (place, view) in tiles where !wanted.contains(place) {
            view.removeFromSuperview()
            tiles[place] = nil
            // ⚠️ **AND IT GIVES UP ITS PICTURE ON THE WAY OUT.** A spare is
            // handed to whichever square is next, and a square now keeps what it
            // is showing until a better picture arrives — so a view that kept its
            // old film would hand a square of somewhere else to a place that has
            // never shown anything.
            view.picture.image = nil
            if spareTiles.count < 8 { spareTiles.append(view) }
        }

        // ⚠️ **NOTHING ON THE FILM IS EVER ANIMATED HERE.** A scroll does not move
        // film in content coordinates — it only changes which squares exist — and
        // this runs inside every animation that moves the offset: the eased
        // follow at a loop, the carry's crossings, the drop. Animated, a window
        // slid towards its new hull while the squares born in it were placed
        // against where it was going, a window from the pool rounded its corners
        // up from nothing, and a spare square's picture slid in from wherever it
        // last was. The scroller's own movement is the only motion the film has.
        UIView.performWithoutAnimation {
            // ⚠️ **ONE WINDOW PER PIECE, ROUNDED AT THE ENDS IT ACTUALLY SHOWS.** The
            // window clips its squares, so a piece's corner is drawn whole however
            // many squares it runs across — a six-point sliver at the end of the
            // film no longer has to carry an eight-point curve on its own.
            let open = Set(openWindows.map(\.piece))
            for (piece, window) in windows where !open.contains(piece) {
                window.removeFromSuperview()
                windows[piece] = nil
                window.layer.cornerRadius = 0
                if spareWindows.count < 4 { spareWindows.append(window) }
            }
            for opening in openWindows {
                let frame = CGRect(
                    x: opening.from, y: 0, width: opening.width, height: Metrics.strip
                )
                let window: PieceFilmView
                if let known = windows[opening.piece] {
                    window = known
                } else {
                    window = spareWindows.popLast() ?? PieceFilmView(frame: .zero)
                    windows[opening.piece] = window
                    film.addSubview(window)
                }
                window.frame = frame
                window.layer.cornerRadius = opening.radius
                window.layer.maskedCorners = Self.corners(
                    leading: opening.roundsLeading, trailing: opening.roundsTrailing
                )
            }

            for square in squares {
                guard let window = windows[square.piece] else { continue }
                let frame = CGRect(
                    x: square.from - window.frame.minX, y: 0,
                    width: square.width, height: Metrics.strip
                )
                let view: FilmSquare
                if let known = tiles[square.place] {
                    view = known
                    if view.superview !== window { window.addSubview(view) }
                } else {
                    view = takeTile(into: window, at: frame)
                    tiles[square.place] = view
                }
                view.frame = frame
                // The picture keeps its own size and simply hangs out of the part the
                // window shows: that is the crop.
                view.show(at: square.filmFrom - square.from, width: square.filmWidth)
                // ⚠️ **A SQUARE KEEPS WHAT IT IS SHOWING UNTIL SOMETHING BETTER
                // ARRIVES.** Blanking a square back to the poster while its frame
                // decodes turns a scroll into a strobe. One that has never shown
                // anything takes whatever picture is at hand, which is what fills the
                // strip in the turn the mode opens.
                if let picture = decoded[square.seconds] {
                    view.picture.image = picture
                } else if view.picture.image == nil {
                    view.picture.image = anyFrame ?? posterFrame
                }
            }
        }

        askForMissingTiles()
    }

    /// The corners a window rounds: the leading pair where it shows its piece's
    /// drawn start, the trailing pair where it shows its end.
    ///
    /// ⚠️ **A TEST CANNOT SEE THIS IN PIXELS.** The CPU renderer a test can use
    /// rounds all four corners whatever `maskedCorners` says (measured), so the
    /// mask is asserted as a property and pixels are only read off windows that
    /// round all four.
    static func corners(leading: Bool, trailing: Bool) -> CACornerMask {
        var corners: CACornerMask = []
        if leading { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
        if trailing { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
        return corners
    }

    /// The caps' shadow: the cap less `blur` twice on its inner side, rounded on
    /// its outer side.
    ///
    /// ⚠️ **AN EXPLICIT PATH, AND IT KEEPS THE SHADOW OFF THE FILM.** Without one
    /// Core Animation derives the shadow from the layer's alpha in an offscreen
    /// pass, and casts it inwards too — over the inner-corner plates and the
    /// held piece's first frames. Built by hand with tangent arcs so no path
    /// helper's capsule rule decides the shape.
    static func capShadowPath(
        size: CGSize, outerIsLeading: Bool, radius: CGFloat, blur: CGFloat
    ) -> CGPath {
        let width = max(size.width - 2 * blur, 0)
        let rect = CGRect(
            x: outerIsLeading ? 0 : size.width - width, y: 0,
            width: width, height: size.height
        )
        let corner = max(0, min(radius, rect.width, rect.height / 2))
        let path = CGMutablePath()
        if outerIsLeading {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: corner
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: corner
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: corner
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: corner
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }

    /// A square's view, standing in its piece's window.
    ///
    /// ⚠️ **IN THE WINDOW, NOT IN THE FILM**, or the window's rounded corners
    /// clip nothing.
    private func takeTile(into window: PieceFilmView, at frame: CGRect) -> FilmSquare {
        let view = spareTiles.popLast() ?? FilmSquare(frame: .zero)
        view.frame = frame
        window.addSubview(view)
        return view
    }

    private func askForMissingTiles() {
        // ⚠️ **NOTHING IS DECODED FOR A FILM NOBODY CAN SEE.** Collapsed, the
        // film is invisible; the squares it lays out wait for the return.
        guard let framesProvider, duration > 0, !isZooming, !isCompact else { return }
        // ⚠️ **WHAT IS MISSING IS A SECOND OF FILM, NOT A SQUARE OF TRACK.** Two
        // squares can stand for the same moment — a piece may be shown twice
        // over, since a cut leaves both halves the whole source — so this is a
        // set.
        let wanted = Set(squares.map(\.seconds))
            .filter { decoded[$0] == nil && !requesting.contains($0) }
        guard !wanted.isEmpty else { return }
        requesting.formUnion(wanted)

        let spacing = MediaTimelining.tileSpacingSeconds(
            in: timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        let seconds = Array(wanted)
        let generation = framesGeneration
        Task { [weak self] in
            guard let self else { return }
            let arrived = await framesProvider(seconds, Metrics.strip, spacing)
            // The film this batch was asked for is gone — a new clip. Nothing
            // else invalidates a picture any more: a second of film is the same
            // second whatever the track has been edited into since.
            guard generation == framesGeneration else { return }
            // ⚠️ **THE FIRST PICTURE OF ANY KIND IS A LAYOUT EVENT.** The frame's
            // inner corners are plates BEHIND the film, and they wait for film
            // that is not transparent before they show.
            let hadNone = anyFrame == nil && posterFrame == nil
            for second in seconds {
                requesting.remove(second)
                guard let picture = arrived[second] else { continue }
                decoded[second] = picture
                if anyFrame == nil { anyFrame = picture }
            }
            // The squares standing for those seconds, wherever they are now.
            for square in squares {
                if let picture = decoded[square.seconds] {
                    tiles[square.place]?.picture.image = picture
                }
            }
            forgetTheFurthestPictures()
            if hadNone && anyFrame != nil { setNeedsLayout() }
        }
    }

    /// ⚠️ **CHARTER T3: THE PICTURES ALIVE AT ONCE ARE BOUNDED.** Without this
    /// the cache is a record of everywhere the author has ever scrolled, which on
    /// a long clip is the eager strip this whole design exists to avoid — just
    /// arrived at slowly. The ones furthest from where they are looking go first.
    private func forgetTheFurthestPictures() {
        guard decoded.count > Metrics.mostDecoded, !squares.isEmpty else { return }
        // The middle of what is on screen, in FILM — the pictures are keyed by
        // the film now, so the distance that decides what goes has to be too.
        let middle = squares[squares.count / 2].seconds
        let doomed = decoded.keys
            .sorted { abs($0 - middle) > abs($1 - middle) }
            .prefix(decoded.count - Metrics.mostDecoded)
        for second in doomed { decoded[second] = nil }
    }

    /// Brings `seconds` of the file under the needle without announcing it — the
    /// track following a clip that is playing.
    ///
    /// ⚠️ **REFUSED WHENEVER A FINGER IS INVOLVED.** A track that snapped back to
    /// the player's position while the author was pushing it would be unusable,
    /// and the deceleration after a flick is just as much the author's gesture as
    /// the drag that started it.
    func follow(_ moment: MediaTimelining.Moment) {
        follow(
            playedSeconds: MediaTimelining.playedSeconds(
                ofPiece: moment.piece, atSourceSeconds: moment.sourceSeconds,
                in: timeline, withinSource: duration
            )
        )
    }

    /// Brings a moment of the RESULT under the needle — what the preview reports
    /// now that it plays the arrangement, whose seconds are the track's own.
    ///
    /// ⚠️ **NO CONVERSION, AND THAT IS CHARTER T8.** Sixty times a second, a
    /// played second is already where the film goes; turning it into a piece
    /// and back would resolve the timeline, which allocates, on every beat.
    ///
    /// `rate` is how many played seconds the clip covers per second of real
    /// time — zero while it is stopped — which is what an eased move needs to
    /// land where the clip WILL be rather than where it was.
    func follow(playedSeconds seconds: Double, advancing rate: Double = 0) {
        guard grip == nil, reordering == nil, !scroller.isDragging, !scroller.isDecelerating,
              bounds.width > 0, !isEasing, seconds.isFinite
        else { return }
        let target = offset(forPlayedSeconds: seconds)
        let current = scroller.contentOffset.x
        guard MediaTimelining.easesFollow(byPoints: target - current) else {
            isFollowingPlayback = true
            scroller.contentOffset.x = target
            isFollowingPlayback = false
            return
        }
        // ⚠️ **A JUMP IS EASED; A STEP IS NOT.** Playing a clip moves the film one
        // point a beat and easing that would put a quarter-second animation on
        // top of motion that is already smooth — the film would swim. What is
        // brusque is a DISCONTINUITY: letting go of a handle after the player has
        // been seeked elsewhere, or the playhead turning back at the end of the
        // cut. See `MediaTimelining.stepWithoutEasing` for where the line is,
        // and `followEase` for why the ease aims ahead of a running clip.
        let duration = MediaTimelining.followEaseSeconds
        let ahead = rate.isFinite && rate > 0
            ? offset(forPlayedSeconds: seconds + rate * duration) - target : 0
        let ease = MediaTimelining.followEase(from: current, to: target, lead: ahead)
        if Self.probesFollow {
            print(String(format: "[timeline] ease travel=%.1fpt lead=%.1fpt", ease.landing - current, ahead))
        }
        // ⚠️ **AND THE FLAG IS HELD FOR THE WHOLE ANIMATION, NOT AROUND AN
        // ASSIGNMENT.** An animated content offset calls `scrollViewDidScroll`
        // on every frame of the ease, long after a flag set around the assignment
        // would have been cleared — and each of those callbacks would be read as
        // the author scrubbing, and seek the player to where the animation had
        // got to. The clip would chase its own animation.
        isEasing = true
        isFollowingPlayback = true
        let animator = UIViewPropertyAnimator(
            duration: duration,
            timingParameters: UICubicTimingParameters(
                controlPoint1: MediaTimelining.FollowEase.firstControlPoint,
                controlPoint2: ease.controlPoint
            )
        )
        animator.isUserInteractionEnabled = true
        animator.addAnimations { [scroller] in
            scroller.contentOffset.x = ease.landing
        }
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, let animator, followAnimator === animator else { return }
            followAnimator = nil
            isFollowingPlayback = false
            isEasing = false
        }
        followAnimator = animator
        animator.startAnimation()
    }

    /// Puts a moment of the RESULT under the needle at once — the track
    /// appearing over a clip that is already running.
    ///
    /// ⚠️ **NOT EASED, BECAUSE THERE IS NOTHING ON SCREEN TO MOVE FROM.** The
    /// film was wherever the last visit left it; sliding it from there to the
    /// player is a journey the author never took.
    /// Returns whether the film was placed.
    @discardableResult
    func place(atPlayedSeconds seconds: Double) -> Bool {
        guard grip == nil, reordering == nil, !scroller.isDragging, !scroller.isDecelerating,
              bounds.width > 0, seconds.isFinite
        else { return false }
        stopEasing()
        // ⚠️ **LAID OUT FIRST, OR THE OPENING UNDOES IT.** The first layout
        // with a width puts the film on the start of the result, once; placed
        // before that pass, the film went back to zero on it and the next beat
        // eased 300pt across the gap — measured under `-timeline-probe`.
        layoutIfNeeded()
        isFollowingPlayback = true
        scroller.contentOffset.x = offset(forPlayedSeconds: seconds)
        isFollowingPlayback = false
        return true
    }

    /// The ease a follow started, while it runs.
    var followAnimator: UIViewPropertyAnimator?

    /// ⚠️ **RESOLVED ONCE** — `MediaEditorViewController.probesFollow` says why.
    private static let probesFollow = ProcessInfo.processInfo.arguments.contains("-timeline-probe")

    /// Whether the film is in the middle of an eased move. A beat that lands
    /// during one is ignored: the ease is already going where the player is, and
    /// interrupting it every frame is how an animation becomes a stutter.
    var isEasing = false

    // MARK: - Layout

    /// The top of the film row: one rail below the ruler's gap, so the
    /// selection's top edge has room. ⚠️ A PROPERTY, BECAUSE THE SHOT LIST IS
    /// RAISED FROM A GESTURE AND NOT FROM `layoutSubviews` — a second copy of
    /// this sum is how two rows end up a rail apart.
    var stripY: CGFloat { Metrics.ruler + Metrics.gap + Metrics.bar }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = MediaTimelining.centringInset(forTrackWidth: bounds.width)
        // ⚠️ THE SLACK IS PART OF THE INSET, AND THE LAYOUT IS WHERE IT IS
        // APPLIED — setting it anywhere else would be undone on the next pass,
        // which is how the first version of this silently did nothing.
        let leading = inset + leadingSlack
        if abs(scroller.contentInset.left - leading) > 0.5
            || abs(scroller.contentInset.right - inset) > 0.5 {
            scroller.contentInset = UIEdgeInsets(top: 0, left: leading, bottom: 0, right: inset)
        }

        // ⚠️ **THE CONTENT IS THE RESULT, NOT THE FILE.** Its width is what the
        // post will RUN for, so a piece at 2× takes half the room its film does.
        // Everything below is placed from `placements`, which is the one function
        // that knows where a piece sits.
        let width = MediaTimelining.contentWidth(
            of: timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        content.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        scroller.contentSize = content.bounds.size

        rulerHost.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Metrics.ruler)
        layOutTheRuler(width: width)

        // ⚠️ **BOUNDS AND CENTRE, NEVER THE FRAME.** The film collapses into the
        // line by a transform, and a frame assigned under a transform is read
        // through it — the film would come back somewhere nobody asked for.
        film.bounds = CGRect(x: 0, y: 0, width: width, height: Metrics.strip)
        film.center = CGPoint(x: width / 2, y: stripY + Metrics.strip / 2)
        // ⚠️ **BEFORE THE SELECTION, ALWAYS.** The frame's inner corners are
        // plates behind the film and assume the film in front of them is laid.
        refreshTiles()
        // ⚠️ **ONE ANSWER FOR THE CAPS, PASSED DOWN** — never stored and read
        // back, or a split's `+` would wait a layout.
        let capped = heldCapMarks()

        let placed = laidPlacements
        let frameTop = stripY - Metrics.bar
        let frameHeight = Metrics.strip + Metrics.bar * 2

        refreshReadout()
        keptLabel.frame = CGRect(
            x: bounds.width - Metrics.readout.width - Spacing.sm, y: 0,
            width: Metrics.readout.width, height: Metrics.ruler
        )
        // Nothing to say about a clip with no length yet.
        keptLabel.isHidden = duration <= 0

        playButton.frame = CGRect(
            x: Spacing.sm, y: (Metrics.ruler - Metrics.control) / 2,
            width: Metrics.control, height: Metrics.control
        )
        layOutTheRulerFade()

        layOutTheCarry(placed, stripY: stripY)
        layOutTheSelection(drawnSpans, frameTop: frameTop, frameHeight: frameHeight, capped: capped)
        layOutTheRateStamps(drawnSpans, stripY: stripY)
        layOutTheSeams(reckoning: true)
        if isCompact { layOutTheLine() }
        layOutTheSkeleton(filmWidth: width, stripY: stripY)

        needle.frame = CGRect(
            x: (bounds.width - Metrics.needle) / 2, y: 0,
            width: Metrics.needle, height: needleHeight
        )
        needleCap.frame = CGRect(
            x: (bounds.width - Metrics.needleCap) / 2, y: 0,
            width: Metrics.needleCap, height: Metrics.needleCap
        )

        accessibilityValue = Self.spoken(MediaTimelining.resolved(timeline, withinSource: duration))

        // Opened on the start of the result, once.
        if !hasOpened, duration > 0, bounds.width > 0 {
            hasOpened = true
            isFollowingPlayback = true
            scroller.contentOffset.x = offset(forPlayedSeconds: 0)
            isFollowingPlayback = false
        }
    }

    /// The ruler: the result's seconds along the scrolled track at rest, and the
    /// shot list's seams while a piece is carried.
    ///
    /// ⚠️ **WHILE A PIECE IS CARRIED THE RULER COUNTS THE LIST, AND IT IS READ
    /// AGAIN AT EVERY CROSSING.** The chips are all one width whatever they run
    /// for, so evenly spaced seconds would lie about every one of them; the marks
    /// are the seams, labelled with where each piece begins in the order AS IT
    /// STANDS. This runs in `layoutSubviews`, which is exactly what a crossing
    /// asks for — so a carried piece relabels the ruler the instant it changes
    /// places, as asked: *"attention lorsqu'on réorganise, il faut bien mettre à
    /// jour cette barre de temps"*.
    private func layOutTheRuler(width: CGFloat) {
        guard reordering != nil else {
            rulerHost.layer.mask = rulerFade
            ruler.frame = CGRect(
                x: -scroller.contentOffset.x, y: 0, width: width, height: Metrics.ruler
            )
            // The ruler counts the result, and the track is drawn on it: one
            // axis, so a mark goes where its own arithmetic puts it.
            let played = MediaTimelining.playedSeconds(of: timeline, withinSource: duration)
            let step = MediaTimelining.rulerStep(
                pointsPerSecond: pointsPerSecond, acrossPlayedSeconds: played
            )
            ruler.mark(
                MediaTimelining.rulerSeconds(upToPlayedSeconds: played, step: step),
                step: step,
                at: { [pointsPerSecond] at in
                    MediaTimelining.x(atPlayedSeconds: at, pointsPerSecond: pointsPerSecond)
                }
            )
            return
        }
        // ⚠️ **NO FADE WHILE THE LIST IS UP.** The fade exists to let the ruler
        // pass behind the play button and the readout, which are put away with
        // the rest of the track — kept, it would hide the first and last seams.
        rulerHost.layer.mask = nil
        // ⚠️ **AS WIDE AS THE LIST AND MOVED WITH IT**, the way the track's ruler
        // is moved with the film — see `listScrolled`.
        let list = standing
        ruler.frame = CGRect(
            x: -shotList.contentOffset.x, y: 0, width: listWidth(of: list), height: Metrics.ruler
        )
        let marks = MediaTimelining.shotMarks(list, minimumSpacing: Metrics.shotMarkSpacing)
        var places: [Double: CGFloat] = [:]
        for mark in marks { places[mark.seconds] = mark.x }
        ruler.mark(marks.map(\.seconds), step: 0, showsDots: false) { places[$0] ?? 0 }
    }

    /// Lays the shot list out over the track — or, once the finger has gone, lays
    /// it back down on the pieces it came from.
    ///
    /// ⚠️ **THE CHIPS ARE PLACED HERE AND NOWHERE ELSE, SO THE ANIMATIONS ARE
    /// FREE.** Every move the list makes — rising off the track, re-flowing as a
    /// piece is crossed, settling back — is the same two lines at the call site:
    /// ask for a layout, then run `layoutIfNeeded` inside an animation. A routine
    /// that placed them itself would need a third copy of the arithmetic for
    /// every one of those moments.
    private func layOutTheCarry(_ placed: [MediaTimelining.Placement], stripY: CGFloat) {
        guard reordering != nil else {
            // A list on its way out fades where it stands; the animation that is
            // fading it owns it until it lands.
            if !isPuttingDown { putTheShotsAway() }
            return
        }
        let list = standing
        sizeTheList(list)
        let frames = asAShotList(list, stripY: stripY)
        for (index, shot) in shots.enumerated() where frames.indices.contains(index) {
            // ⚠️ A TRANSFORM AND A FRAME CANNOT BOTH BE SET: a frame is READ
            // through the transform, so assigning one while scaled moves the chip
            // somewhere nobody asked for. Identity, place it, then lift it.
            shot.transform = .identity
            shot.frame = frames[index]
            let inHand = index == reordering
            shot.isInHand = inHand
            shot.transform = inHand ? Self.lift(forWidth: frames[index].width) : .identity
            // ⚠️ **THE ONE IN HAND IS THE BRIGHT ONE, AND NONE IS SEE-THROUGH.**
            // Standing the others back by alpha let the track and the footage
            // behind the band show through them; a shade inside each chip says
            // the same thing and shows nothing.
            shot.isShaded = reordering != nil && !inHand
        }
    }

    /// The shot list itself: equal widths, the whole composition across the
    /// track, with room at both ends for the first and last timecodes.
    ///
    /// ⚠️ **ONE PLACE, SHARED BY THE CHIPS, THE RULER AND THE FINGER.** Where a
    /// chip is drawn, where its seam is labelled and which chip a finger is over
    /// are three readings of the same arrangement; three copies of it would drift
    /// by an inset and the finger would drop a piece one chip away from the one it
    /// was over.
    ///
    /// ⚠️ **IN THE LIST'S OWN COORDINATES, WHICH SCROLL.** A finger reports where
    /// it is on the TRACK; `shotList.contentOffset` is what turns one into the
    /// other, and the carry adds it before asking which chip the finger is over.
    var standing: [MediaTimelining.Placement] {
        MediaTimelining.shots(
            timeline, withinSource: duration,
            across: max(bounds.width - Metrics.shotInset * 2, 0),
            startingAt: Metrics.shotInset, atLeast: Metrics.shotMinimum
        )
    }

    /// How far the shot list runs, room at both ends included — never less than
    /// the track, so a list that fits does not scroll.
    func listWidth(of list: [MediaTimelining.Placement]) -> CGFloat {
        max((list.last?.to ?? 0) + Metrics.shotInset, bounds.width)
    }

    /// Frames the list's scroller over the track, as long as the list runs.
    private func sizeTheList(_ list: [MediaTimelining.Placement]) {
        shotList.frame = bounds
        let size = CGSize(width: listWidth(of: list), height: bounds.height)
        if shotList.contentSize != size { shotList.contentSize = size }
    }

    /// Where the chips stand while the list is up: a hair of daylight between
    /// them.
    private func asAShotList(_ list: [MediaTimelining.Placement], stripY: CGFloat) -> [CGRect] {
        list.map {
            CGRect(
                x: $0.from + Metrics.shotGap / 2, y: stripY,
                width: max($0.width - Metrics.shotGap, 1), height: Metrics.strip
            )
        }
    }

    /// How the chip in hand is lifted: the full rise in height, and in width no
    /// more than the daylight beside it can spare.
    static func lift(forWidth width: CGFloat) -> CGAffineTransform {
        guard width > 0 else { return .identity }
        let spare = max((Metrics.shotGap - Metrics.shotDaylight) * 2, 0)
        return CGAffineTransform(
            scaleX: min(Metrics.inHand, 1 + spare / width), y: Metrics.inHand
        )
    }

    /// Puts the track away while the list is up, or brings it back — inside
    /// whatever animation the caller is running.
    func standTheTrackAside(_ aside: Bool) {
        for part in partsOfTheTrack { part.alpha = aside ? 0 : 1 }
    }

    /// Raises one chip per piece, IN ITS PLACE IN THE LIST, laid out and waiting
    /// to be faded and scaled in.
    ///
    /// ⚠️ **LAID OUT BEFORE THE ANIMATION, OR ITS PICTURE GROWS OUT OF A CORNER.**
    /// A chip made and framed in the same turn as the animation that shows it has
    /// never been laid out: its picture's frame is still `.zero`, and the first
    /// layout happens INSIDE the animation — so the picture animated from the
    /// top-left corner to the bottom-right. Reported in exactly those words:
    /// *"le contenu des segments compressés apparaît depuis le haut gauche vers le
    /// bas droit, ce n'est pas naturel"*.
    ///
    /// ⚠️ **AND IT NO LONGER TRAVELS FROM THE TRACK.** The chips used to start on
    /// their pieces and stretch into equal widths; with the track put away there
    /// is nothing left to say where they came from, and a picture being pulled
    /// wider and narrower at once read as a distortion rather than a lift. They
    /// appear where they will stand — a fade and a small scale from their centres,
    /// asked for by name: *"un scale depuis le centre et/ou un fade"*.
    ///
    /// ⚠️ **THE PICTURES ARE ONES THE STRIP HAS ALREADY DECODED.** A shot list
    /// that asked the library for a frame per piece would put a file read inside
    /// a gesture, and the chips would be empty for the first of it. The tile at
    /// the piece's own beginning is the frame the author is already looking at.
    func raiseTheShots(_ placed: [MediaTimelining.Placement], stripY: CGFloat) {
        putTheShotsAway()
        let list = standing
        sizeTheList(list)
        shotList.contentOffset = .zero
        shotList.isHidden = false
        for (at, frame) in zip(placed, asAShotList(list, stripY: stripY)) {
            // The piece's own first square, wherever it is — a shot list shows
            // every piece, including the ones off screen.
            // ⚠️ **FROM THE STRIP AS IT IS DRAWN.** Asked of the uncarved sheet,
            // the first square of a piece can be one the daylight hid — never
            // decoded for this piece, and decoded for the one BEFORE it, whose
            // film it then showed.
            let spans = drawnSpans.isEmpty
                ? MediaTimelining.spans(of: placed) : drawnSpans
            let film = MediaTimelining.squares(
                along: spans, withinSource: duration,
                visible: at.from...(at.from + MediaTimelining.tileWidth),
                pointsPerSecond: pointsPerSecond
            ).first { $0.piece == at.index }?.seconds
            let shot = ShotView(
                picture: film.flatMap { decoded[$0] } ?? anyFrame ?? posterFrame
            )
            shot.frame = frame
            shotList.addSubview(shot)
            shot.layoutIfNeeded()
            shot.alpha = 0
            shot.transform = CGAffineTransform(scaleX: Metrics.arriving, y: Metrics.arriving)
            shots.append(shot)
        }
    }

    func putTheShotsAway() {
        stopTheListScrolling()
        guard !shots.isEmpty else { return }
        for shot in shots { shot.removeFromSuperview() }
        shots.removeAll()
        shotList.isHidden = true
        shotList.contentOffset = .zero
        standTheTrackAside(false)
    }

    /// The white frame around the piece the author has chosen — and nothing at
    /// all until they choose one.
    ///
    /// ⚠️ **NOTHING IS SELECTED AT REST, AND THE WHOLE TRACK USED TO BE.** The
    /// frame was drawn around the outer bounds of the timeline whatever the
    /// author had touched, so a clip arrived already bracketed and every piece
    /// past the first was inside somebody else's selection. Asked for in those
    /// words: the selection happens when you tap the track or one of its
    /// segments. It is also what makes per-piece handles possible at all — two
    /// caps can only belong to one piece.
    private func layOutTheSelection(
        _ drawn: [MediaTimelining.Span], frameTop: CGFloat, frameHeight: CGFloat,
        capped: [MediaTimelining.CapMark]
    ) {
        guard let index = selected, let held = drawn.first(where: { $0.index == index }) else {
            for part in [topBar, bottomBar, startGrab, endGrab] { part.isHidden = true }
            for plate in innerCorners { plate.isHidden = true }
            laidOutHeld = nil
            return
        }
        // ⚠️ **A FRAME THAT APPEARS, OR JUMPS TO ANOTHER PIECE, IS PLACED AT ONCE.**
        // A lift selects inside the carry's spring: animated, the caps and rails
        // grew out of the content's origin (or slid across from the last piece)
        // while the plates they hide stood already in place, and the plates'
        // tucked edges showed for the length of it. The frame of a piece that
        // stays held still moves with whatever animation is running — a drop,
        // a crossing.
        let jumps = laidOutHeld != index || startGrab.isHidden
        laidOutHeld = index
        for part in [topBar, bottomBar, startGrab, endGrab] { part.isHidden = false }
        if jumps {
            UIView.performWithoutAnimation {
                placeTheFrame(around: held, frameTop: frameTop, frameHeight: frameHeight, capped: capped)
            }
        } else {
            placeTheFrame(around: held, frameTop: frameTop, frameHeight: frameHeight, capped: capped)
        }
    }

    /// Which piece the frame was last laid out around.
    private var laidOutHeld: Int?

    private func placeTheFrame(
        around held: MediaTimelining.Span, frameTop: CGFloat, frameHeight: CGFloat,
        capped: [MediaTimelining.CapMark]
    ) {
        // ⚠️ **THE CAPS STAND OUTSIDE THE PIECE, NOT ON TOP OF IT.** Laid over the
        // film they eat twelve points of picture at each end — and those are the
        // twelve the author is aiming with, the frames right at the edge of the
        // decision being made. The held piece is never carved, so its drawn film
        // IS its cut, and the caps stand on it.
        // ⚠️ **AND THE RAILS STOP SHORT OF BOTH CAPS' OUTER CURVES.** Drawn the
        // obvious way — rails spanning the whole selection, caps laid on top — the
        // straight rail runs past the cap's ROUNDED corner and shows as a hair of
        // white sticking out beyond the curve at all four corners. Reported from
        // the device as the borders overshooting at the ends.
        let caps = MediaTimelining.caps(around: held, grab: Metrics.grab)
        let inset = max(Metrics.railInset, Metrics.capCorner)
        let railFrom = caps.start.lowerBound + inset
        let railTo = max(caps.end.upperBound - inset, railFrom)
        topBar.frame = CGRect(
            x: railFrom, y: frameTop, width: railTo - railFrom, height: Metrics.bar
        )
        bottomBar.frame = CGRect(
            x: railFrom, y: frameTop + frameHeight - Metrics.bar,
            width: railTo - railFrom, height: Metrics.bar
        )
        startGrab.frame = CGRect(
            x: caps.start.lowerBound, y: frameTop, width: Metrics.grab, height: frameHeight
        )
        endGrab.frame = CGRect(
            x: caps.end.lowerBound, y: frameTop, width: Metrics.grab, height: frameHeight
        )
        for (grab, outerIsLeading) in [(startGrab, true), (endGrab, false)] {
            let size = grab.bounds.size
            if grab.layer.shadowPath?.boundingBoxOfPath.height != size.height {
                grab.layer.shadowPath = Self.capShadowPath(
                    size: size, outerIsLeading: outerIsLeading,
                    radius: Metrics.capCorner, blur: Metrics.capShadowBlur
                )
            }
        }
        for (grab, line) in [(startGrab, startGrip), (endGrab, endGrip)] {
            line.frame = CGRect(
                x: (grab.bounds.width - Metrics.grip.width) / 2,
                y: (grab.bounds.height - Metrics.grip.height) / 2,
                width: Metrics.grip.width, height: Metrics.grip.height
            )
        }
        // ⚠️ **A CAP ON A CUT CARRIES THE CUT'S `+` IN PLACE OF ITS GRIP** (F7,
        // F27) — *"mettre le plus dans les pinces de sélection à la place du trait
        // vertical"*: right after a split the new cut is under the held half's
        // closing cap, and its `+` has to be there at once.
        let scale = max(traitCollection.displayScale, 1)
        for (grab, line, glyph, edge) in [
            (startGrab, startGrip, startGlyph, MediaTimelining.Edge.start),
            (endGrab, endGrip, endGlyph, MediaTimelining.Edge.end)
        ] {
            let mark = capped.first { $0.edge == edge }
            line.isHidden = mark != nil
            glyph.isHidden = mark == nil
            guard let mark else { continue }
            // ⚠️ **PLACED, NEVER ANIMATED** — a drop lays the track out inside its
            // fade, and a glyph set there would grow from nothing.
            UIView.performWithoutAnimation {
                let name = MediaTransitionCatalog.markGlyph(for: mark.kind)
                if name != (edge == .start ? startGlyphName : endGlyphName) {
                    glyph.image = UIImage(
                        systemName: name,
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.capGlyph, weight: .bold)
                    )
                    if edge == .start { startGlyphName = name } else { endGlyphName = name }
                    #if DEBUG
                    capGlyphImageAssignments += 1
                    #endif
                }
                // Centred on the cap, its origin on the pixel grid in CONTENT
                // points: a cap stands at fractional places under a rate or a
                // zoom, and a symbol half a pixel off draws soft.
                let size = glyph.image?.size ?? .zero
                let x = ((grab.frame.midX - size.width / 2) * scale).rounded() / scale
                let y = ((grab.frame.midY - size.height / 2) * scale).rounded() / scale
                glyph.frame = CGRect(
                    x: x - grab.frame.minX, y: y - grab.frame.minY,
                    width: size.width, height: size.height
                )
            }
        }

        // ⚠️ **THE INNER CORNERS ARE THE FILM'S OWN.** Asked for as *"le cadre
        // intérieur des pinces… ait aussi des bordures intérieures arrondies, ce
        // qui matcherait avec les coins arrondis des segments"*. White plates
        // BEHIND the held film show exactly where its window is rounded away, so
        // the frame's inner curve is the piece's curve by construction, at any
        // clamped radius.
        // ⚠️ **HIDDEN UNTIL THERE IS FILM IN FRONT OF THEM.** A square with no
        // picture of any kind is transparent, and a plate behind it would show as
        // a white block inside the frame.
        let plates = MediaTimelining.fillets(
            around: held, top: stripY, bottom: stripY + Metrics.strip,
            rail: Metrics.bar, tuck: Metrics.filletTuck
        )
        let showsPlates = plates.count == innerCorners.count
            && (anyFrame != nil || posterFrame != nil)
        for (offset, plate) in innerCorners.enumerated() {
            guard showsPlates else {
                plate.isHidden = true
                continue
            }
            if plate.isHidden {
                // ⚠️ Framed before it is seen: the carry and the drop lay the
                // track out inside their animations.
                UIView.performWithoutAnimation { plate.frame = plates[offset] }
                plate.isHidden = false
            } else {
                plate.frame = plates[offset]
            }
        }
    }

    /// The held piece's caps, from the very arithmetic that draws them.
    ///
    /// ⚠️ **ONE SOURCE FOR THE DRAWING, THE REACH AND THE TAP BAND.** A cap that
    /// moved in one of three copies was a handle whose reach sat beside it.
    func heldCaps() -> MediaTimelining.Caps? {
        guard let index = selected else { return nil }
        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        let drawn = MediaTimelining.spans(
            of: placed, gap: Metrics.seamGap, holding: index,
            corner: Metrics.filmCorner, height: Metrics.strip,
            scale: traitCollection.displayScale
        )
        guard let held = drawn.first(where: { $0.index == index }) else { return nil }
        return MediaTimelining.caps(around: held, grab: Metrics.grab)
    }

    /// The `+` marks the held piece's caps carry.
    ///
    /// ⚠️ **ONE SOURCE FOR THE DRAWING, THE TAP AND THE SPOKEN LIST**, like
    /// `heldCaps()`. None while nobody listens, while a piece is carried, or
    /// while the film is a line.
    func heldCapMarks() -> [MediaTimelining.CapMark] {
        guard onSeam != nil, reordering == nil, !isCompact, duration > 0,
              let held = selected, let caps = heldCaps()
        else { return [] }
        return MediaTimelining.capMarks(
            MediaTimelining.placements(timeline, withinSource: duration, pointsPerSecond: pointsPerSecond),
            holding: held, caps: caps, reach: SeamButton.hitSize
        )
    }

    private static func spoken(_ pieces: [MediaSegment]) -> String {
        // The result's length: its pieces less every transition's overlap.
        let seconds = Int((MediaTimelining.laid(pieces).last?.ends ?? 0).rounded())
        return seconds == 1 ? "1 second kept" : "\(seconds) seconds kept"
    }

    // MARK: - Spoken adjustment

    /// One second per swipe: the floor `MediaTimelining` enforces, so a viewer
    /// cannot step into a state the handles refuse.
    private static let spokenStep: Double = 1

    /// ⚠️ **ACTIVATING THE TRACK TAKES THE PIECE UNDER THE NEEDLE, AND NEVER
    /// OPENS A CUT.** Left to the default, VoiceOver taps the track's centre —
    /// the needle — and right after a split that is the held half's `+`. The
    /// cuts are the custom actions.
    ///
    /// ⚠️ **COLLAPSED, IT IS CONSUMED AND DOES NOTHING.** Handed back, the
    /// default tap lands on the track's centre — where the transitions row
    /// stands — and would choose a card nobody asked for.
    override func accessibilityActivate() -> Bool {
        guard !isCompact else { return true }
        guard duration > 0 else { return false }
        takeOrPutDown(
            atContentX: scroller.contentOffset.x + MediaTimelining.centringInset(forTrackWidth: bounds.width),
            answeringMarks: false
        )
        return true
    }

    override func accessibilityIncrement() {
        guard !isCompact else { return }
        adjustEnd(bySourceSeconds: Self.spokenStep)
    }

    override func accessibilityDecrement() {
        guard !isCompact else { return }
        adjustEnd(bySourceSeconds: -Self.spokenStep)
    }

    /// ⚠️ **THROUGH `MediaTimelining.moved`, LIKE EVERY OTHER ROUTE.** A second
    /// implementation of the clamping would be a second set of edge cases, and
    /// the arithmetic is pure precisely so every caller can share it.
    private func adjustEnd(bySourceSeconds delta: Double) {
        // ⚠️ **THE PIECE THAT IS HELD, NOT THE LAST ONE.** The overload without an
        // index resolves to the final piece, so with the first half of a cut
        // clip framed on screen a VoiceOver swipe silently lengthened the OTHER
        // half — a control and the clip it edits that are not the same thing.
        let pieces = MediaTimelining.resolved(timeline, withinSource: duration)
        guard let index = selected ?? pieces.indices.last else { return }
        let next = MediaTimelining.moved(
            timeline, piece: index, edge: .end, bySourceSeconds: delta, withinSource: duration
        )
        guard next != timeline else { return }
        timeline = next
        setNeedsLayout()
        // Announced immediately: unlike a finger, a VoiceOver swipe IS the whole
        // gesture, so there is no release to wait for.
        onChange?(timeline)
    }
}
