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
    private enum Metrics {
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

    private let scroller = ChipScrollView()
    private let content = UIView()
    /// ⚠️ **THE RULER LIVES OUTSIDE THE SCROLLER, AND IT USED TO LIVE INSIDE.**
    /// A `UIScrollView`'s `bounds.origin` IS its content offset, so a mask framed
    /// in its bounds travels with the content — `MediaCropToolsView` records
    /// exactly this, seen on screen as a chip guillotined mid-letter. The ruler
    /// has to fade where it passes behind the play button and behind the readout,
    /// so it hangs in a host that does not scroll and is moved by hand instead.
    private let rulerHost = UIView()
    private let ruler = RulerView()
    private let playButton = UIButton(type: .system)
    private let film = UIView()
    private let topBar = UIView()
    private let bottomBar = UIView()
    private let keptLabel = UILabel()
    private let startGrab = UIView()
    private let endGrab = UIView()
    private let startGrip = UIView()
    private let endGrip = UIView()
    /// The `+` — or the transition's symbol — a cap standing on a cut carries in
    /// place of its grip.
    private let startGlyph = UIImageView()
    private let endGlyph = UIImageView()
    /// The symbol each glyph is drawing, so a layout that changes nothing looks
    /// nothing up (T8).
    private var startGlyphName: String?
    private var endGlyphName: String?
    #if DEBUG
    private var capGlyphImageAssignments = 0
    #endif
    private let needle = UIView()
    private let needleCap = UIView()
    /// ⚠️ **THE FILM'S OWN FOOTPRINT WHILE IT HAS NO PICTURES — NOT A PLATE.**
    /// The band forbids a surface behind its tenant, and this does not break that
    /// rule: it is drawn in the rectangle the film is about to occupy, clipped to
    /// what is on screen, and it goes the moment there is anything at all to
    /// show. Without it the track opens as a white selection drawn around
    /// nothing, which is exactly how it was reported — "the timeline does not
    /// appear when it loads".
    private let skeleton = SkeletonBoneView(rounding: .fixed(Metrics.filmCorner))
    /// The four plates behind the held piece's film that round the frame's
    /// inner corners — top leading, top trailing, bottom leading, bottom
    /// trailing. See `MediaTimelining.fillets`.
    private let innerCorners: [UIView] = (0..<4).map { _ in UIView() }
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
    private var shots: [ShotView] = []
    /// ⚠️ **THE SHOT LIST HAS A SCROLLER OF ITS OWN, AND IT IS NOT THE TRACK'S.**
    /// With a floor under every chip the list can run past the track's width —
    /// asked for as *"une scrollview horizontale … on peut reprendre la même que
    /// celle de la timeline"* — so it is a `ChipScrollView`, the band's shared
    /// horizontal scroller. The track's own is out of the question: its content
    /// is the film, its offset is the needle, and it is put away with the rest
    /// of the track for the length of the carry. Hidden at rest, so it never
    /// stands between a finger and the film.
    private let shotList = ChipScrollView()
    /// Where the carrying finger is, in the track's own coordinates — asked again
    /// whenever the list moves under it.
    private var carryX: CGFloat?
    private let edgeScroll = EdgeScrollProxy()
    /// When the list last scrolled by itself.
    private var edgeScrollBeat: CFTimeInterval = 0
    /// Everything the track draws that is NOT the ruler: what is put away while
    /// the shot list is up.
    ///
    /// ⚠️ **PUT AWAY, NOT STOOD BACK — AND STANDING IT BACK WAS REPORTED.** A
    /// semi-transparent scrim left the film, the frame, the seams and the needle
    /// showing through the chips: *"on aperçoit la timeline par derrière (il y a
    /// un fouillis car tout est en semi transparent)"*. While a piece is carried
    /// the only things on the band are the chips and the ruler that counts them.
    private var partsOfTheTrack: [UIView] {
        [scroller, skeleton, needle, needleCap, playButton, keptLabel]
    }
    /// A shot list that is on its way back down to the track. The chips are laid
    /// on the pieces they belong to and taken away when the animation lands, and
    /// without this the layout would remove them mid-flight.
    private var isPuttingDown = false
    /// ⚠️ **SELECTION FEEDBACK, NOT IMPACT.** Apple's rule: selection feedback
    /// "communicates movement through a series of discrete values", which is what
    /// a piece crossing another is; an impact is for a collision. One tick when
    /// the piece lifts and one per crossing — never on every beat of the drag,
    /// which the HIG calls decorative noise.
    private let carryTicks = UISelectionFeedbackGenerator()
    /// One stamp per piece that is not playing as shot.
    private var rateStamps: [UILabel] = []
    /// What each stamp last said, so a scroll re-sets nothing.
    private var rateStampWords: [String] = []

    /// The symbol a filtered piece's stamp carries.
    static let filterStampGlyph = "camera.filters"

    private static func filterStamp(rate: String?) -> NSAttributedString {
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
    private var seamMarks: [MediaTimelining.SeamMark] = []
    /// The `+` buttons on screen, keyed by their cut.
    private var seamButtons: [Int: SeamButton] = [:]
    private var spareSeamButtons: [SeamButton] = []
    /// Every cut VoiceOver can reach, as last spoken.
    private var spokenSeams: [MediaTimelining.SpokenSeam] = []
    /// Where the finger the tap recogniser — or the press — is following
    /// LANDED, in content points.
    private var tapLanding: CGFloat?
    private var liftLanding: CGFloat?

    /// Whether the film is collapsed into a line, for choosing a transition.
    private(set) var isCompact = false
    /// Bumped by every collapse and every return, so an animation that lands
    /// after a newer one began tidies nothing away.
    private var compactTurns = 0
    /// The line: one piece of it per piece of film near the screen.
    private var lineSegments: [UIView] = []
    /// The stretch the preview loops, and the transition inside it.
    private let rehearsalBar = UIView()
    private let windowMark = UIView()
    private var rehearsalRange: ClosedRange<Double>?
    private var rehearsalWindow: ClosedRange<Double>?

    /// Clear under the play button, solid across the middle, clear again under
    /// the readout: what a timecode passes through on its way behind either.
    private let rulerFade: CAGradientLayer = {
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
    private var pointsPerSecond = MediaTimelining.pointsPerSecond
    /// The moment under the needle when a pinch began, so the film zooms around
    /// what the author is looking at rather than around its own beginning.
    private var zoomAnchorSeconds: Double = 0
    private var isZooming = false
    /// What the play button is currently drawing, so a beat that changes nothing
    /// costs a comparison rather than an image lookup.
    private var showingPaused: Bool?

    private var duration: Double = 0
    private var timeline: MediaTimeline = .whole

    /// Which piece is being carried to a new place, if any.
    private var reordering: Int?

    /// Extra room at the head of the track, for the length of a head trim.
    ///
    /// ⚠️ **WITHOUT IT THE FIRST PIECE'S START CANNOT FOLLOW A FINGER, AND THAT
    /// WAS REPORTED.** A piece begins where the one before it ends, so dragging
    /// its start shortens it from the INSIDE: the cap stays put and the other end
    /// moves. The track pays for the gesture by scrolling under the finger — and
    /// a scroll view will not go past its own leading inset, which for the FIRST
    /// piece it is already sitting on. The inset grows by exactly what the head
    /// has given up, for exactly as long as the drag lasts.
    private var leadingSlack: CGFloat = 0

    /// Which piece the author has taken hold of, if any.
    ///
    /// ⚠️ **NIL AT REST, AND THE WHOLE TRACK USED TO BE SELECTED INSTEAD.** A
    /// clip opened already bracketed by a white frame, which says "this is what
    /// you are editing" before the author has said anything — and with more than
    /// one piece it says it about the wrong one. Selecting is now an act: tap a
    /// piece to take it, tap away to put it down. The handles belong to whatever
    /// is held, which is what makes every piece resizable rather than only the
    /// two outer edges.
    private var selected: Int?
    /// Which end of the selection the finger has hold of, if any.
    private var grip: MediaTimelining.Edge?
    /// ⚠️ **SET ONLY AROUND A PROGRAMMATIC SCROLL.** `setContentOffset` calls
    /// `scrollViewDidScroll` synchronously, so following the player would emit a
    /// scrub, which the screen turns into a seek, which moves the player, which
    /// moves the track. The loop is not theoretical; the flag is what stops it.
    private var isFollowingPlayback = false
    private var hasOpened = false

    /// ⚠️ **ON THE SCROLLER, FOR THE REASON `contentPan` IS.** `ChipScrollView`
    /// gives its own pan first refusal over any recogniser living OUTSIDE it, so
    /// a pinch on the track view would have to wait for a scroll that never fails
    /// — and never begin. A recogniser on the scroller itself is not an outsider:
    /// the rule asks `owner.isDescendant(of: self)`, and a view is its own
    /// descendant.
    private lazy var pinch: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        gesture.delegate = self
        return gesture
    }()

    /// ⚠️ **A TAP, NOT A TOUCH-DOWN — AND IT MUST NOT TAKE THE TOUCH.** The
    /// scroller under it has to go on scrolling from the same finger, and a
    /// recogniser that cancelled touches would make the film feel stuck for the
    /// length of every tap. `cancelsTouchesInView = false` is the same rule the
    /// selector's touch probe is built on.
    private lazy var selectTap: UITapGestureRecognizer = {
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
    private lazy var lift: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(carried))
        press.minimumPressDuration = 0.35
        press.delegate = self
        return press
    }()

    private lazy var contentPan: UIPanGestureRecognizer = {
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

    private static let trimLabel = "Trim, adjusts the end"

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
    private func offset(forPlayedSeconds seconds: Double) -> CGFloat {
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
    private func recognisedTap(reportedAtContentX reported: CGFloat) {
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

    private func takeOrPutDown(atContentX x: CGFloat, answeringMarks: Bool = true) {
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
    private var tiles: [MediaTimelining.Square.Place: FilmSquare] = [:]
    /// The squares the strip is drawing right now: what is asked for, what is
    /// evicted and what the poster fills in all read this.
    private var squares: [MediaTimelining.Square] = []
    /// Retired views, kept to be filled in again rather than rebuilt.
    private var spareTiles: [FilmSquare] = []
    /// One rounded, clipping window per piece that has squares laid out, keyed
    /// by the piece — the same number a square's place carries, so a kept
    /// square never changes window, even after a carry renumbers the pieces.
    private var windows: [Int: PieceFilmView] = [:]
    private var spareWindows: [PieceFilmView] = []
    /// What the last `refreshTiles` laid out: where each piece's TIME is, where
    /// its FILM is drawn, and the windows that show it. Read by the layout and
    /// the scroll so nothing is resolved twice a beat.
    private var laidPlacements: [MediaTimelining.Placement] = []
    private var drawnSpans: [MediaTimelining.Span] = []
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
    private var decoded: [Double: UIImage] = [:]
    /// Seconds already asked for, so a scroll does not ask twice.
    private var requesting: Set<Double> = []
    /// ⚠️ **CHARTER F14: THE STRIP NEVER SHOWS EMPTY BOXES.** Until a tile's own
    /// frame arrives it shows the nearest one already decoded, so a strip being
    /// scrolled into reads as a blurred film rather than as a row of holes.
    /// `PryntTrimmerView` does the same thing with its first decoded frame, and
    /// it is the cheapest possible improvement to how the strip feels.
    private var anyFrame: UIImage?

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
    private var posterFrame: UIImage?

    /// Which film the tiles in flight were asked for. Bumped whenever the
    /// PICTURES stop meaning what they meant, which since they are keyed by the
    /// second of film they show is one thing only: a different clip.
    private var framesGeneration = 0

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
    private func refreshTiles() {
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
    private var followAnimator: UIViewPropertyAnimator?

    /// ⚠️ **RESOLVED ONCE** — `MediaEditorViewController.probesFollow` says why.
    private static let probesFollow = ProcessInfo.processInfo.arguments.contains("-timeline-probe")

    /// Whether the film is in the middle of an eased move. A beat that lands
    /// during one is ignored: the ease is already going where the player is, and
    /// interrupting it every frame is how an animation becomes a stutter.
    private var isEasing = false

    // MARK: - Layout

    /// The top of the film row: one rail below the ruler's gap, so the
    /// selection's top edge has room. ⚠️ A PROPERTY, BECAUSE THE SHOT LIST IS
    /// RAISED FROM A GESTURE AND NOT FROM `layoutSubviews` — a second copy of
    /// this sum is how two rows end up a rail apart.
    private var stripY: CGFloat { Metrics.ruler + Metrics.gap + Metrics.bar }

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
    private var standing: [MediaTimelining.Placement] {
        MediaTimelining.shots(
            timeline, withinSource: duration,
            across: max(bounds.width - Metrics.shotInset * 2, 0),
            startingAt: Metrics.shotInset, atLeast: Metrics.shotMinimum
        )
    }

    /// How far the shot list runs, room at both ends included — never less than
    /// the track, so a list that fits does not scroll.
    private func listWidth(of list: [MediaTimelining.Placement]) -> CGFloat {
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
    private func standTheTrackAside(_ aside: Bool) {
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
    private func raiseTheShots(_ placed: [MediaTimelining.Placement], stripY: CGFloat) {
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

    private func putTheShotsAway() {
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
    private func heldCaps() -> MediaTimelining.Caps? {
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
    private func heldCapMarks() -> [MediaTimelining.CapMark] {
        guard onSeam != nil, reordering == nil, !isCompact, duration > 0,
              let held = selected, let caps = heldCaps()
        else { return [] }
        return MediaTimelining.capMarks(
            MediaTimelining.placements(timeline, withinSource: duration, pointsPerSecond: pointsPerSecond),
            holding: held, caps: caps, reach: SeamButton.hitSize
        )
    }

    private static func spoken(_ pieces: [MediaSegment]) -> String {
        let seconds = Int(pieces.reduce(0) { $0 + $1.playedSeconds }.rounded())
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

    // MARK: - Scrolling is seeking

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // ⚠️ **TWO SCROLLERS, ONE DELEGATE.** The shot list's movements are not
        // the film's, and must not be read as a scrub.
        guard scrollView === scroller else { return listScrolled() }
        // ⚠️ EVERY SCROLL, INCLUDING THE FOLLOWER'S. The window of film worth
        // decoding moves with the offset whoever moved it — a clip playing past
        // the end of what has been decoded needs new tiles just as much as a
        // finger does.
        refreshTiles()
        refreshReadout()
        // ⚠️ **THE RULER IS MOVED BY HAND, BECAUSE IT NO LONGER SCROLLS.** It
        // hangs in a host outside the scroll view so that a gradient mask can be
        // framed in coordinates that stand still — see `rulerHost`. The price is
        // this one line, and it is cheaper than the mask sliding off the viewport
        // on the first drag, which is what happened when it was inside.
        // While a piece is carried the ruler counts the list, which does not
        // scroll.
        if reordering == nil { ruler.frame.origin.x = -scroller.contentOffset.x }
        layOutTheSkeleton(
            filmWidth: MediaTimelining.contentWidth(
                of: timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
            ),
            stripY: stripY
        )
        // The stamps are clamped into the viewport, so they move with it.
        if !rateStamps.isEmpty {
            layOutTheRateStamps(drawnSpans, stripY: stripY)
        }
        if !seamMarks.isEmpty {
            layOutTheSeams(reckoning: false)
        }
        if isCompact { layOutTheLine() }
        // ⚠️ **COLLAPSED, THE FILM IS NEVER SCRUBBED.** Only the follower moves
        // it — the preview is looping a stretch the author did not aim.
        guard !isFollowingPlayback, !isCompact, hasOpened, let moment = momentUnderNeedle else { return }
        onScrub?(moment)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // ⚠️ **A FINGER OUTRANKS AN EASE.** `allowUserInteraction` lets a drag
        // start mid-animation, but the animation would go on driving the offset
        // underneath it — the film would fight the finger. Ending it here leaves
        // the offset wherever the ease had got to, which is where the film
        // visibly is.
        stopEasing()
        onScrubbing?(true)
    }

    private func stopEasing() {
        guard isEasing else { return }
        // ⚠️ **THE MODEL VALUE IS ALREADY AT THE TARGET, SO REMOVING THE
        // ANIMATION SNAPS THERE.** `UIView.animate { contentOffset = target }`
        // sets the model at once and animates only the presentation;
        // `removeAllAnimations` drops the presentation and the film jumps the
        // rest of the way — the opposite of leaving it where it visibly is, which
        // is what this used to claim. Reading the presentation layer first and
        // assigning THAT is what makes the finger pick the film up where it sees
        // it. `uiview-animate-from-value-trap` is the same lesson about `alpha`.
        let visible = scroller.layer.presentation()?.bounds.origin.x
        if let animator = followAnimator {
            followAnimator = nil
            animator.stopAnimation(true)
        }
        scroller.layer.removeAllAnimations()
        if let visible { scroller.contentOffset.x = visible }
        isEasing = false
        isFollowingPlayback = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // ⚠️ THE FLICK IS STILL THE AUTHOR'S GESTURE. Saying the scrub ended here
        // would let playback resume while the film was still sliding, and every
        // remaining deceleration sample would seek away from it.
        guard !decelerate else { return }
        onScrubbing?(false)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        onScrubbing?(false)
    }

    /// The left half of the readout changes on every scroll; the right half only
    /// when a handle moves. Both are cheap, and one label is one assignment.
    /// ⚠️ **BOTH HALVES IN PLAYED SECONDS — CHARTER F10, AND THE SOURCE CLOCK
    /// WAS ON THE LEFT FOR ONE BUILD.** "Where the playhead is" and "how long the
    /// result will run" are one question asked twice, and the answer has to be in
    /// the units a viewer will experience. With a rate on the piece the two
    /// clocks part company: measured on the device, a seven-second clip at 2×
    /// read "0:04 / 0:04" with the needle half way along it.
    private func refreshReadout() {
        keptLabel.text = MediaTimelining.stamp(playedSecondsUnderNeedle)
            + " / "
            + MediaTimelining.stamp(
                MediaTimelining.playedSeconds(of: timeline, withinSource: duration)
            )
    }

    /// Clear under the play button, solid across the middle, clear again under
    /// the readout.
    ///
    /// ⚠️ **THE STOPS ARE COMPUTED, NOT GUESSED — AND THE RESTING PLACE IS PAST
    /// THE RAMP.** `MediaCropToolsView` states the same rule for its row of
    /// shapes: a label that comes to rest inside the ramp sits permanently half
    /// dissolved, which reads as a rendering fault rather than as a fade.
    ///
    /// ⚠️ **AND THE FRAME IS SET WITH ACTIONS OFF.** A layer that is not a view's
    /// backing layer animates its own `frame` implicitly over a quarter second,
    /// so the mask would lag a rotation of the device behind what it masks.
    private func layOutTheRulerFade() {
        let width = rulerHost.bounds.width
        guard width > 0 else { return }
        let afterPlay = playButton.frame.maxX
        let solidFrom = afterPlay + Metrics.fade
        let clearFrom = keptLabel.frame.minX
        let solidUntil = max(clearFrom - Metrics.fade, solidFrom)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rulerFade.frame = rulerHost.bounds
        rulerFade.locations = [
            0,
            NSNumber(value: Double(afterPlay / width)),
            NSNumber(value: Double(solidFrom / width)),
            NSNumber(value: Double(solidUntil / width)),
            NSNumber(value: Double(clearFrom / width)),
            1
        ]
        CATransaction.commit()
    }

    /// The rate a piece carries, kept where it can be read.
    ///
    /// ⚠️ **CLAMPED INTO THE VIEWPORT, NOT PINNED TO THE PIECE'S START.** A stamp
    /// nailed to the leading edge of its piece is off screen for every piece
    /// longer than a screenful — measured on the device: a seven-second clip at
    /// the resting scale is 420pt of film against a 390pt track, and the stamp
    /// for the only piece there is had already scrolled away by the time the
    /// author chose the rate. It slides along the piece instead, the way the
    /// fixed readout does, and stops at both of its ends so it never speaks for a
    /// piece it is not over.
    ///
    /// ⚠️ **ON ITS OWN FILM AND UNDER THE FRAME.** Clamped to where the piece's
    /// film is DRAWN, so it never sits in the daylight; past the held piece's
    /// closing cap when that piece is the one before; and inserted under the
    /// selection's ink, which is always the thing on top.
    private func layOutTheRateStamps(_ drawn: [MediaTimelining.Span], stripY: CGFloat) {
        // ⚠️ **A FILTERED PIECE IS STAMPED TOO** — the filter's symbol before its
        // rate, if it has one: nothing else on the film says it wears a look.
        let stamped = drawn.filter {
            abs($0.placement.piece.speed - 1) > 0.001 || $0.placement.piece.filter != nil
        }
        while rateStamps.count > stamped.count {
            rateStamps.removeLast().removeFromSuperview()
            rateStampWords.removeLast()
        }
        while rateStamps.count < stamped.count {
            let stamp = UILabel()
            stamp.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            stamp.textColor = .white
            stamp.isUserInteractionEnabled = false
            stamp.layer.shadowColor = UIColor.black.cgColor
            stamp.layer.shadowOpacity = 0.4
            stamp.layer.shadowRadius = 2
            stamp.layer.shadowOffset = .zero
            content.insertSubview(stamp, belowSubview: topBar)
            rateStamps.append(stamp)
            rateStampWords.append("")
        }
        let caps = heldCaps()
        for (index, (stamp, span)) in zip(rateStamps, stamped).enumerated() {
            let piece = span.placement.piece
            let rate = abs(piece.speed - 1) > 0.001 ? MediaTimelining.rateLabel(piece.speed) : nil
            // ⚠️ SET ONLY WHEN THE WORDS CHANGE (charter T8): this runs on every
            // scroll, and an attributed string is an allocation.
            let words = (piece.filter == nil ? "" : "filter|") + (rate ?? "")
            if rateStampWords[index] != words {
                rateStampWords[index] = words
                if piece.filter != nil {
                    stamp.attributedText = Self.filterStamp(rate: rate)
                } else {
                    stamp.attributedText = nil
                    stamp.text = rate
                }
                stamp.sizeToFit()
            }
            var from = span.from
            var to = span.to
            if let caps, selected == span.index - 1 {
                from = max(from, caps.end.upperBound)
            }
            if let caps, selected == span.index + 1 {
                to = min(to, caps.start.lowerBound)
            }
            // Pinned to the piece's leading edge and never wider than the piece:
            // a stamp that overran its own segment would sit on its neighbour and
            // say the wrong thing about it.
            let width = min(stamp.bounds.width, max(to - from - Metrics.stampInset * 2, 0))
            let leading = from + Metrics.stampInset
            let trailing = max(to - width - Metrics.stampInset, leading)
            let visible = scroller.contentOffset.x + Metrics.stampInset
            stamp.frame = CGRect(
                x: min(max(visible, leading), trailing),
                y: stripY + Metrics.strip - stamp.bounds.height - Metrics.stampInset,
                width: width, height: stamp.bounds.height
            )
            stamp.isHidden = width < 8
        }
    }

    /// The `+` on every cut in view.
    ///
    /// ⚠️ **WORKED OUT ON A LAYOUT, ONLY PLACED ON A SCROLL — CHARTER T8.** Which
    /// cuts carry a mark depends on the arrangement, the scale and the held
    /// piece, and none of them changes while the film merely moves; a scroll
    /// only decides which of those marks are near enough the screen to exist,
    /// and a beat that changes nothing allocates nothing.
    ///
    /// ⚠️ **NONE WHILE A PIECE IS CARRIED.** The track is put away for the
    /// length of a carry, and a cut there is about to move anyway.
    private func layOutTheSeams(reckoning: Bool) {
        if reckoning {
            let wanted: [MediaTimelining.SeamMark]
            if onSeam == nil || reordering != nil || duration <= 0 {
                wanted = []
            } else {
                let caps = heldCaps()
                wanted = MediaTimelining.seamMarks(
                    laidPlacements, minimumSpacing: Metrics.seamSpacing,
                    hiding: caps.map { $0.start.lowerBound...$0.end.upperBound },
                    disc: SeamButton.discSize, widest: SeamButton.hitSize
                )
            }
            seamMarks = wanted
            // ⚠️ **EVERY CUT IS SPOKEN, DRAWN OR NOT** — a disc thinned away or
            // hidden beside a held cap is still a cut a VoiceOver user must
            // reach. Spoken again only when a cut or what it carries changes,
            // not on every sample of a trim.
            let spoken: [MediaTimelining.SpokenSeam] = onSeam == nil || reordering != nil || duration <= 0
                ? []
                : laidPlacements.dropLast().map { .init(index: $0.index, kind: $0.piece.transitionOut) }
            if spoken != spokenSeams {
                spokenSeams = spoken
                speakTheSeams()
            }
        }
        let offset = scroller.contentOffset.x
        let low = offset - MediaTimelining.filmMargin
        let high = offset + bounds.width + MediaTimelining.filmMargin
        for (index, button) in seamButtons {
            let kept = seamMarks.contains { $0.index == index && $0.x >= low && $0.x <= high }
            guard !kept else { continue }
            button.removeFromSuperview()
            seamButtons[index] = nil
            if spareSeamButtons.count < 4 { spareSeamButtons.append(button) }
        }
        let scale = max(traitCollection.displayScale, 1)
        for mark in seamMarks where mark.x >= low && mark.x <= high {
            let known = seamButtons[mark.index]
            guard known == nil || reckoning else { continue }
            let fresh = known == nil
            let button = known ?? takeASeamButton()
            seamButtons[mark.index] = button
            // ⚠️ **PLACED, NEVER ANIMATED.** A layout can run inside the drop's
            // fade, and a button from the pool would slide in from wherever it
            // last stood.
            UIView.performWithoutAnimation {
                button.seam = mark.index
                button.bounds.size = CGSize(width: mark.hitWidth, height: SeamButton.hitSize)
                button.center = CGPoint(
                    x: (mark.x * scale).rounded() / scale,
                    y: ((stripY + Metrics.strip / 2) * scale).rounded() / scale
                )
                if fresh || button.showing != mark.kind { button.show(mark.kind) }
                if fresh {
                    button.alpha = isCompact ? 0 : 1
                    button.transform = isCompact ? Self.seamAway : .identity
                }
                button.isUserInteractionEnabled = !isCompact
                button.layoutIfNeeded()
            }
        }
    }

    private func takeASeamButton() -> SeamButton {
        let button = spareSeamButtons.popLast() ?? {
            let made = SeamButton()
            made.addAction(
                UIAction { [weak self, weak made] _ in
                    guard let self, let made else { return }
                    onSeam?(made.seam)
                },
                for: .primaryActionTriggered
            )
            return made
        }()
        content.insertSubview(button, belowSubview: topBar)
        return button
    }

    /// Where a `+` goes as the film collapses under it: smaller, and up into
    /// the line with the film.
    private static let seamAway = CGAffineTransform(
        translationX: 0, y: -(Metrics.strip - Metrics.line) / 2
    ).scaledBy(x: 0.6, y: 0.6)

    /// The `+` a touch at `x` belongs to, if one is on screen there.
    private func shownSeam(atContentX x: CGFloat) -> Int? {
        guard !isCompact else { return nil }
        return seamButtons.first { abs($0.value.center.x - x) <= $0.value.bounds.width / 2 }?.key
    }

    /// ⚠️ **THE TRACK IS ONE ACCESSIBILITY ELEMENT, SO ITS BUTTONS ARE NOT.** A
    /// VoiceOver user reaches each cut through the track's own actions — every
    /// cut, in view or not.
    private func speakTheSeams() {
        accessibilityCustomActions = spokenSeams.map { mark in
            UIAccessibilityCustomAction(
                name: "Transition after clip \(mark.index + 1): \(mark.kind?.spokenLabel ?? "none")"
            ) { [weak self] _ in
                guard let self, let onSeam else { return false }
                onSeam(mark.index)
                return true
            }
        }
    }

    // MARK: - Collapsed, for choosing a transition

    /// How tall the needle stands: the whole track, or down to the line.
    private var needleHeight: CGFloat { isCompact ? Metrics.compactHeight : bounds.height }

    /// The film scaled into the line, its top edge where the film's was.
    private static var collapse: CGAffineTransform {
        let scale = Metrics.line / Metrics.strip
        return CGAffineTransform(translationX: 0, y: -(Metrics.strip - Metrics.line) / 2)
            .scaledBy(x: 1, y: scale)
    }

    /// How much film either side of a transition the preview loops.
    ///
    /// ⚠️ **AS MUCH AS STAYS ON SCREEN.** The needle is nailed to the centre and
    /// walks the stretch as it plays, so from its start the whole stretch has
    /// to fit in the half of the track to the needle's right — at the resting
    /// scale that is about a second and a quarter either side, *"quelques
    /// secondes avant jusqu'à quelques secondes après"*. Never less than half a
    /// second, however far the author has zoomed in; never more than two.
    var rehearsalLead: Double {
        guard bounds.width > 0, pointsPerSecond > 0 else { return Metrics.shortestLead }
        let reach = Double((bounds.width / 2 - Metrics.rehearsalMargin) / pointsPerSecond)
        let lead = (reach - VideoTransitionKind.standardSeconds) / 2
        return min(max(lead, Metrics.shortestLead), Metrics.longestLead)
    }

    /// Collapses the film upwards into a line under the ruler — or opens it
    /// again — leaving the track its height: the room below the line is the
    /// transitions row's (charter F28).
    ///
    /// ⚠️ **REFUSED WHILE A HANDLE OR A PIECE IS HELD**, and the answer says so.
    /// A collapse under a finger would take the thing it is moving away.
    ///
    /// ⚠️ **STAGED, THEN ANIMATED IN ONE SPRING — AND WITHOUT
    /// `.beginFromCurrentState`.** The line and the bars are laid out at alpha
    /// zero first; with that option the fade would read its from-value off a
    /// presentation layer that has never drawn them, and run from one to one
    /// (`uiview-animate-from-value-trap`).
    @discardableResult
    func setCompact(
        _ compact: Bool, bringingUnderTheNeedle seconds: Double? = nil, animated: Bool
    ) -> Bool {
        guard compact != isCompact else { return true }
        if compact {
            guard grip == nil, reordering == nil else { return false }
            select(nil, notify: true)
        }
        stopEasing()
        compactTurns += 1
        let turn = compactTurns
        isCompact = compact
        scroller.isScrollEnabled = !compact
        accessibilityTraits = compact ? [] : .adjustable
        accessibilityLabel = compact ? "Transition timeline" : Self.trimLabel
        for button in seamButtons.values { button.isUserInteractionEnabled = !compact }
        if compact {
            for mark in [rehearsalBar, windowMark] {
                mark.alpha = 0
                mark.isHidden = false
            }
            setNeedsLayout()
            layoutIfNeeded()
        }
        let target = seconds.map { offset(forPlayedSeconds: $0) }
        if target != nil {
            isEasing = true
            isFollowingPlayback = true
        }
        let changes = { [self] in
            film.transform = compact ? Self.collapse : .identity
            film.alpha = compact ? 0 : 1
            for stamp in rateStamps { stamp.alpha = compact ? 0 : 1 }
            for button in seamButtons.values {
                button.alpha = compact ? 0 : 1
                button.transform = compact ? Self.seamAway : .identity
            }
            for segment in lineSegments { segment.alpha = compact ? 1 : 0 }
            rehearsalBar.alpha = compact ? 1 : 0
            windowMark.alpha = compact ? 1 : 0
            needle.frame.size.height = needleHeight
            skeleton.alpha = compact ? 0 : 1
            if let target { scroller.contentOffset.x = target }
        }
        let landed = { [weak self] in
            guard let self, turn == compactTurns else { return }
            if target != nil {
                isEasing = false
                isFollowingPlayback = false
            }
            guard !isCompact else { return }
            for segment in lineSegments { segment.removeFromSuperview() }
            lineSegments.removeAll()
            rehearsalBar.isHidden = true
            windowMark.isHidden = true
            rehearsalRange = nil
            rehearsalWindow = nil
            // The film asked for nothing while it was a line.
            refreshTiles()
        }
        guard animated, window != nil else {
            changes()
            landed()
            return true
        }
        UIView.animate(
            withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
            options: [.allowUserInteraction], animations: changes
        ) { _ in landed() }
        return true
    }

    /// Lights the stretch the preview loops, and the transition inside it — in
    /// PLAYED seconds, the axis the line is drawn on.
    func showRehearsal(
        _ range: ClosedRange<Double>?, window: ClosedRange<Double>?, animated: Bool
    ) {
        rehearsalRange = range
        rehearsalWindow = window
        guard isCompact else { return }
        guard animated, self.window != nil else { return layOutTheLine() }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) { [self] in
            layOutTheLine()
        }
    }

    /// The line, the lit stretch and the transition's mark.
    ///
    /// ⚠️ **CLIPPED TO THE SCREEN AND ITS MARGIN — CHARTER T6.** A piece of
    /// line as long as a four-minute piece is 43200px at 3x; a rounded layer
    /// that wide is what Metal asserts on.
    private func layOutTheLine() {
        let offset = scroller.contentOffset.x
        let low = offset - MediaTimelining.filmMargin
        let high = offset + bounds.width + MediaTimelining.filmMargin
        var used = 0
        for span in drawnSpans where span.to > low && span.from < high {
            let from = max(span.from, low)
            let to = min(span.to, high)
            let segment: UIView
            if used < lineSegments.count {
                segment = lineSegments[used]
            } else {
                segment = UIView()
                segment.backgroundColor = UIColor.white.withAlphaComponent(0.35)
                segment.isUserInteractionEnabled = false
                segment.layer.cornerCurve = .continuous
                // ⚠️ **AS VISIBLE AS THE BAR ABOVE IT.** Staged for the collapse,
                // that is nothing yet; once collapsed, a piece of line scrolled
                // into view simply shows.
                segment.alpha = rehearsalBar.alpha
                content.insertSubview(segment, belowSubview: rehearsalBar)
                lineSegments.append(segment)
            }
            let width = max(to - from, 0)
            UIView.performWithoutAnimation {
                segment.frame = CGRect(x: from, y: stripY, width: width, height: Metrics.line)
                segment.layer.cornerRadius = min(Metrics.line / 2, width / 2)
                segment.layer.maskedCorners = Self.corners(
                    leading: from == span.from, trailing: to == span.to
                )
            }
            used += 1
        }
        while lineSegments.count > used { lineSegments.removeLast().removeFromSuperview() }

        let middle = stripY + Metrics.line / 2
        if let range = rehearsalRange {
            let from = max(MediaTimelining.x(atPlayedSeconds: range.lowerBound, pointsPerSecond: pointsPerSecond), low)
            let to = min(MediaTimelining.x(atPlayedSeconds: range.upperBound, pointsPerSecond: pointsPerSecond), high)
            let width = max(to - from, 0)
            rehearsalBar.frame = CGRect(
                x: from, y: middle - Metrics.rehearsal / 2, width: width, height: Metrics.rehearsal
            )
            rehearsalBar.layer.cornerRadius = min(Metrics.rehearsal / 2, width / 2)
        }
        rehearsalBar.isHidden = rehearsalRange == nil
        if let window = rehearsalWindow {
            let from = MediaTimelining.x(atPlayedSeconds: window.lowerBound, pointsPerSecond: pointsPerSecond)
            let to = MediaTimelining.x(atPlayedSeconds: window.upperBound, pointsPerSecond: pointsPerSecond)
            let width = max(to - from, Metrics.windowMinimum)
            let centre = min(max((from + to) / 2, low), high)
            windowMark.frame = CGRect(
                x: centre - width / 2, y: middle - Metrics.window / 2,
                width: width, height: Metrics.window
            )
            windowMark.layer.cornerRadius = min(Metrics.windowCorner, width / 2)
        }
        windowMark.isHidden = rehearsalWindow == nil
    }

    /// The bone under the part of the film that is on screen.
    ///
    /// ⚠️ **THE FILM'S RECTANGLE, NOT THE TRACK'S.** At rest the content carries
    /// half a track of lead-in (charter F2), so the clip starts under the needle
    /// and the leading half of the viewport holds no film at all. A bone spanning
    /// the whole width would promise pictures where there will never be any.
    private func layOutTheSkeleton(filmWidth: CGFloat, stripY: CGFloat) {
        let offset = scroller.contentOffset.x
        let from = max(0, -offset)
        let to = min(bounds.width, filmWidth - offset)
        skeleton.frame = CGRect(x: from, y: stripY, width: max(to - from, 0), height: Metrics.strip)
        // Gone the moment there is anything at all to draw — a poster counts,
        // which is the whole point of handing one over.
        skeleton.isHidden = duration <= 0 || to <= from
            || anyFrame != nil || posterFrame != nil
    }

    /// States the play button's glyph without announcing it — the screen owns the
    /// player and tells the track which way round it is.
    func showPaused(_ paused: Bool) {
        guard paused != showingPaused else { return }
        showingPaused = paused
        playButton.setImage(
            UIImage(
                systemName: paused ? "play.fill" : "pause.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            ),
            for: .normal
        )
        playButton.accessibilityLabel = paused ? "Play" : "Pause"
    }

    /// Where the needle is in the RESULT — the axis the track is drawn on.
    var playedSecondsUnderNeedle: Double {
        MediaTimelining.playedSeconds(
            atContentOffset: scroller.contentOffset.x,
            trackWidth: bounds.width,
            pointsPerSecond: pointsPerSecond,
            of: timeline, withinSource: duration
        )
    }

    /// Which piece is under the needle and where in the FILE it has got to —
    /// what a split cuts at, what a rate is applied to, and what the preview is
    /// asked to show.
    var momentUnderNeedle: MediaTimelining.Moment? {
        MediaTimelining.moment(
            atPlayedSeconds: playedSecondsUnderNeedle, in: timeline, withinSource: duration
        )
    }

    /// The moment of the FILE under the needle, for callers that only need that.
    var sourceSecondsUnderNeedle: Double { momentUnderNeedle?.sourceSeconds ?? 0 }

    // MARK: - Dragging a handle

    /// ⚠️ **THE PAN EXISTS ONLY FOR THE HANDLES, AND SAYS SO AT TOUCH-DOWN.**
    /// Refusing here rather than in `.began` is what keeps an ordinary scroll
    /// free: `scroller.panGestureRecognizer` waits for this one to fail, and a
    /// recogniser that never begins fails at once.
    /// ⚠️ **AN `override`, AND `ChipScrollView`'S NEIGHBOURING RULE IS NOT — THE
    /// TWO LOOK ALIKE AND ARE NOT.** `UIView` declares
    /// `gestureRecognizerShouldBegin(_:)` itself, so this one takes the keyword;
    /// `gestureRecognizer(_:shouldBeRequiredToFailBy:)` is delegate-only and
    /// refuses it. The compiler says so plainly in both directions, which is the
    /// only reason this is cheap to get wrong rather than expensive.
    override func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        // ⚠️ **COLLAPSED, THE TRACK TAKES NO GESTURE AT ALL.** There is no film
        // to zoom, no piece to lift and no handle to drag — the line is a
        // reading of where the loop is.
        if isCompact, recogniser === pinch || recogniser === lift || recogniser === contentPan {
            return false
        }
        guard recogniser !== pinch else { return duration > 0 }
        guard recogniser !== lift else {
            return wouldLift(atContentX: liftLanding ?? lift.location(in: content).x)
        }
        guard recogniser === contentPan else { return true }
        return takesAHandle(at: touchDownX(of: contentPan))
    }

    /// Where the finger LANDED, not where it has got to.
    ///
    /// ⚠️ **A RECOGNISER IS NOT ASKED THE INSTANT THE FINGER TOUCHES DOWN.** It
    /// is asked when it first tries to leave `.possible`, which is after its own
    /// slop — and if several touch samples arrive in one turn of the run loop,
    /// that can be tens of points later. Measured in the simulator with an
    /// injected drag: the finger landed on a cap at content x = 5 and
    /// `shouldBegin` was asked at x = 53, which is outside the 44pt reach, so the
    /// handle refused a drag that started exactly on it and the film scrolled
    /// instead. A fast flick off a cap does the same thing to a real finger.
    ///
    /// The translation is the distance travelled since touch-down, so the
    /// difference is where it began.
    private func touchDownX(of pan: UIPanGestureRecognizer) -> CGFloat {
        Self.touchDown(
            location: pan.location(in: content).x, travelled: pan.translation(in: content).x
        )
    }

    /// Whether a press here has anything to carry.
    ///
    /// ⚠️ **A PRESS THAT CANNOT CARRY ANYTHING MUST NOT TAKE THE TOUCH.** A long
    /// press that recognises prevents the scroller's pan from ever beginning for
    /// that finger — so on a clip that has not been cut, where there is nothing
    /// to re-order, a third of a second of stillness froze the film for the rest
    /// of the gesture and the author had to lift and start again. This is the
    /// Bool `beginInteractiveMovementForItem(at:)` hands back, and the reason
    /// every account of that API says to gate the whole carry on it.
    private func wouldLift(atContentX x: CGFloat) -> Bool {
        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        // ⚠️ **A PRESS ON A `+` LIFTS NOTHING — A DISC'S OR A CAP'S.** A
        // recognised long press takes the finger for the whole gesture, and the
        // `+` would never hear its tap: *"quand on appuie sur le + de la pince ça
        // montre les transitions"*, however long the press. Within a cap's
        // target a press is a tap, and a press that travels is the handle's.
        return placed.count > 1 && shownSeam(atContentX: x) == nil
            && !heldCapMarks().contains { $0.reach.contains(x) }
            && pieceAimedAt(x, in: placed) != nil
    }

    /// Which piece a gesture at `x` is aimed at.
    ///
    /// ⚠️ **THE CAPS BELONG TO THE PIECE THAT IS HELD, AND THEY ARE DRAWN ON THE
    /// NEIGHBOUR'S FILM.** A cap stands twelve points outside its own piece, so
    /// at an interior cut a finger on the held piece's closing cap is, by
    /// position alone, inside the NEXT piece — and a press there lifted that next
    /// piece into a carry, taking the selection with it. A control belongs to the
    /// thing it controls: inside the held piece's caps the answer is the held
    /// piece, and everywhere else it is whichever piece the film belongs to.
    private func pieceAimedAt(_ x: CGFloat, in placed: [MediaTimelining.Placement]) -> Int? {
        if let held = selected, let caps = heldCaps(), caps.claims(x) {
            return held
        }
        return MediaTimelining.piece(atPoints: x, in: placed)
    }

    /// ⚠️ **NAMED AND STATIC SO A TEST CAN ASK THE ARITHMETIC** — what it cannot
    /// ask is that the delegate uses it, because a recogniser's location cannot
    /// be set from a test. That half was found in the simulator and is checked
    /// there.
    static func touchDown(location: CGFloat, travelled: CGFloat) -> CGFloat {
        location - travelled
    }

    /// ⚠️ **NAMED, SO A TEST CAN ASK THE DECISION RATHER THAN A COPY OF IT.** A
    /// recogniser's location cannot be set from a test, so the delegate method
    /// above is unreachable there; a test asserting `edge(at:) != nil` instead
    /// would be asserting its own restatement of this line, and the gate could be
    /// deleted with the test still green. One expression, two doors.
    private func takesAHandle(at x: CGFloat) -> Bool { edge(at: x) != nil }

    private func edge(at x: CGFloat) -> MediaTimelining.Edge? {
        guard let centres = handleCentres() else { return nil }
        return MediaTimelining.edge(at: x, startX: centres.start, endX: centres.end)
    }

    /// Where the two caps are DRAWN, in content points — which is not where the
    /// cut is.
    ///
    /// ⚠️ **THE REACH FOLLOWS THE CONTROL, AND FOR ONE BUILD IT DID NOT.** The
    /// caps moved outside the kept film so the first and last frames stopped
    /// being covered; the hit test kept measuring from the CUT, so the finger's
    /// forty-four points sat half a cap away from the thing the eye aims at —
    /// generous enough that the handles still worked, and harder to hit on one
    /// side than the other.
    ///
    /// ⚠️ **AND THE LEADING CAP WAS BEING PLACED AT THE DEFAULT SCALE.** This
    /// read `x(atSourceSeconds: first.start)` with no `pointsPerSecond` while the
    /// trailing one passed the instance's — so the two handles agreed only until
    /// the first pinch, after which the start handle's hit area sat somewhere the
    /// start handle was not. Found by the compiler, when both were finally made
    /// to come from one place.
    /// How wide one piece is drawn right now.
    private func width(ofPiece index: Int) -> CGFloat {
        MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        ).first { $0.index == index }?.width ?? 0
    }

    /// ⚠️ **AND THERE ARE NONE UNTIL A PIECE IS HELD.** With nothing selected the
    /// track has no handles at all, so every touch on it is a scroll — which is
    /// what makes "tap to select" possible in the first place: a tap that had to
    /// fight a handle for its own touch would select the wrong thing half the
    /// time.
    private func handleCentres() -> (start: CGFloat, end: CGFloat)? {
        heldCaps()?.centres
    }

    /// Carries a piece to another place in the composition.
    ///
    /// ⚠️ **THE LIST RE-FLOWS AS THE PIECES ARE CROSSED; THE CHIP IN HAND IS THE
    /// ONE THAT RISES.** Nothing is dragged across the film itself — the strip is
    /// one row of tiles laid across the whole track, and a carried copy of it
    /// would double the decoding for the length of a gesture. What the author
    /// holds is a chip of the shot list, standing over a track that has stood
    /// back; the others make room around it as it passes, which is how a home
    /// screen re-arranges icons.
    @objc private func carried(_ press: UILongPressGestureRecognizer) {
        // ⚠️ **TWO SPACES, AND ONE OF THEM IS NOT THE FILM'S.** The press LANDS on
        // the track, so which piece it took is a question about content
        // coordinates; from the instant it is carrying something the thing under
        // the finger is the SHOT LIST, which is laid in the view's own bounds and
        // does not scroll. Reading the whole gesture in one space would put the
        // drop wherever the film happened to be scrolled to.
        switch press.state {
        case .began:
            lift(
                atContentX: liftLanding ?? press.location(in: content).x,
                underTrackX: press.location(in: self).x
            )
        case .changed: carry(toTrackX: press.location(in: self).x)
        case .ended, .cancelled, .failed:
            liftLanding = nil
            drop()
        default: break
        }
    }

    // ⚠️ **THE THREE ROUTINES THE PRESS USES, NAMED — SO THE TESTS GO THROUGH
    // THEM RATHER THAN ALONGSIDE.** A long press's state cannot be set from a
    // test, and `debugPinch` records what re-entering by a copy of the logic
    // costs: it skipped `beginZoom` entirely and the test written to prove that a
    // zoom retires its frames passed on a path that does not.
    private func lift(atContentX x: CGFloat, underTrackX finger: CGFloat? = nil) {
        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        guard wouldLift(atContentX: x), let index = pieceAimedAt(x, in: placed)
        else { return }
        isPuttingDown = false
        carryX = nil
        reordering = index
        select(index)
        stopTheFilmMovingUnderTheFinger()
        raiseTheShots(placed, stripY: stripY)
        let list = standing
        shotList.contentOffset.x = MediaTimelining.shotListOffset(
            centring: list.first { $0.index == index },
            underTrackX: finger ?? x - scroller.contentOffset.x,
            listWidth: listWidth(of: list), trackWidth: bounds.width
        )
        // Warm first, so the crossings that follow tick without the engine
        // waking up under them. ⚠️ A SIMULATOR FEELS NOTHING — this pair is
        // convention, checked by reading, not by a test or a screenshot.
        carryTicks.prepare()
        carryTicks.selectionChanged()
        onScrubbing?(true)
        // ⚠️ **THE TRACK FADES OUT AS THE LIST FADES AND GROWS IN, EACH CHIP FROM
        // ITS OWN CENTRE.**
        //
        // ⚠️ **A SPRING, AND NO `.beginFromCurrentState` — THE CHIPS WERE STAGED IN
        // THIS SAME TURN.** That option reads the starting value from the
        // PRESENTATION layer, which a view added a moment ago does not have yet;
        // the repository has measured it animating end to end, invisibly, in
        // exactly this situation. A spring animation is immune, and without the
        // option the start is the value the chip was just given.
        setNeedsLayout()
        UIView.animate(
            withDuration: 0.34, delay: 0,
            usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) { [self] in
            layoutIfNeeded()
            for shot in shots { shot.alpha = 1 }
            standTheTrackAside(true)
        }
    }

    /// ⚠️ **APPLE'S OWN RECIPE, AND IT IS NOT `isScrollEnabled`.** WWDC 2014's
    /// "Advanced Scrollviews and Touch Handling Techniques" answers exactly this
    /// question — picking something up inside a scroll view — with: *"at the
    /// moment when I'm grabbing the dot, I just need to disable and then
    /// re-enable the ScrollView's pan gesture"*. Disabling makes the pan "stop
    /// looking at any touches it was currently considering, and reset itself", so
    /// the finger that is now carrying a piece is dropped by the scroller even if
    /// it had already begun to move the film; turning it straight back on leaves
    /// that touch dropped while new ones still work. `isScrollEnabled = false` is
    /// the blunt version — documented as refusing touches altogether and silent
    /// about the ones already in flight — and it is kept only for what comes
    /// AFTER: while the shot list is up the whole composition is on screen, so
    /// there is nothing left to scroll to.
    private func stopTheFilmMovingUnderTheFinger() {
        scroller.panGestureRecognizer.isEnabled = false
        scroller.panGestureRecognizer.isEnabled = true
        scroller.isScrollEnabled = false
    }

    private func carry(toTrackX x: CGFloat) {
        guard reordering != nil else { return }
        carryX = x
        keepTheListScrolling()
        moveTheCarry(toTrackX: x)
    }

    /// Puts the piece in hand in the slot the finger is over now.
    private func moveTheCarry(toTrackX x: CGFloat) {
        guard let from = reordering else { return }
        // ⚠️ **THE FINGER IS ON THE TRACK, AND THE LIST MAY HAVE SCROLLED UNDER
        // IT.** Read without the offset, a finger resting at the edge while the
        // list slides would keep asking for the same slot, and the piece would
        // stay behind while the list it is meant to travel along moved on.
        let to = MediaTimelining.dropIndex(
            forPoints: x + shotList.contentOffset.x, in: standing, moving: from
        )
        guard to != from else { return }
        timeline = MediaTimelining.reordered(
            timeline, move: from, to: to, withinSource: duration
        )
        // ⚠️ **THE CHIP TRAVELS WITH ITS PIECE.** The list is one chip per piece
        // in play order, so the same move is made in both or a chip showing one
        // piece's film ends up standing for another's.
        // ⚠️ **AND THE INDEX IS CHECKED, THOUGH A LIFT ALWAYS RAISES THE LIST.**
        // `remove(at:)` past the end is a crash, and a crash in the middle of a
        // gesture is the one failure the author cannot recover from — found by
        // breaking the lift on purpose, which took the whole suite down with it
        // and hid what the break was supposed to prove.
        if shots.indices.contains(from) {
            let carried = shots.remove(at: from)
            shots.insert(carried, at: min(to, shots.count))
            shotList.bringSubviewToFront(carried)
        }
        reordering = to
        // The frame stays around the piece being carried; the screen hears about
        // the new order once, on release, through `onChange`.
        selected = to
        carryTicks.selectionChanged()
        // ⚠️ **THE RE-FLOW IS THE FEEDBACK, SO IT HAS TO BE SEEN HAPPENING.** An
        // instant swap reads as the list glitching rather than as two pieces
        // changing places. A fifth of a second is enough to follow and too short
        // to be in the way of the next crossing.
        setNeedsLayout()
        UIView.animate(
            withDuration: 0.18, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.layoutIfNeeded()
        }
    }

    private func drop() {
        guard reordering != nil else { return }
        reordering = nil
        carryX = nil
        stopTheListScrolling()
        // ⚠️ **THE LIST FADES OUT WHERE IT STANDS WHILE THE TRACK FADES BACK IN —
        // THE SAME GESTURE AS ITS ARRIVAL, BACKWARDS.** Until the fade lands,
        // `isPuttingDown` is what stops the layout removing the chips mid-flight.
        isPuttingDown = true
        scroller.isScrollEnabled = true
        setNeedsLayout()
        UIView.animate(
            withDuration: 0.22, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) { [self] in
            layoutIfNeeded()
            for shot in shots {
                shot.alpha = 0
                shot.transform = CGAffineTransform(
                    scaleX: Metrics.arriving, y: Metrics.arriving
                )
            }
            standTheTrackAside(false)
        } completion: { [weak self] _ in
            guard let self, reordering == nil else { return }
            isPuttingDown = false
            putTheShotsAway()
        }
        // ⚠️ **THE NEEDLE KEEPS ITS PLACE, AND THE PREVIEW IS TOLD WHAT IS UNDER
        // IT NOW.** The screen knows which piece is playing by its INDEX, and a
        // carry has just renumbered them: left alone, "piece 0 at two seconds"
        // named a different piece after the drop, and the follow scrolled the
        // whole track to wherever that one happened to sit — measured on the
        // device as the needle leaping from 0:02 to 0:00 the instant the finger
        // came up. A new order does not change how long the result runs, so the
        // track has not moved; the moment under the needle, in the new order, is
        // what the player has to be sent to.
        // ⚠️ **AND A PIECE PUT DOWN AT THE END LOSES ITS TRANSITION** — there is
        // no cut after the film. Cleared here, once, rather than at every
        // crossing: a carry that comes back where it started must be the
        // timeline that was lifted.
        timeline = MediaTimelining.settled(timeline)
        setNeedsLayout()
        if let moment = momentUnderNeedle { onScrub?(moment) }
        onScrubbing?(false)
        onChange?(timeline)
    }

    /// The shot list moved — by itself at an edge, or under a second finger.
    ///
    /// ⚠️ **IT MOVED UNDER A FINGER THAT DID NOT**, so what that finger is over
    /// has changed: the carry is asked again, and the ruler that counts the list
    /// goes with it.
    private func listScrolled() {
        guard reordering != nil else { return }
        ruler.frame.origin.x = -shotList.contentOffset.x
        if let carryX { moveTheCarry(toTrackX: carryX) }
    }

    /// How fast the list should be scrolling by itself right now — zero when the
    /// finger is away from both ends, or when there is no further to go.
    private var edgeScrollSpeed: CGFloat {
        guard reordering != nil, let carryX else { return 0 }
        let speed = MediaTimelining.edgeScrollSpeed(
            atTrackX: carryX, trackWidth: bounds.width,
            zone: Metrics.edgeZone, fastest: Metrics.edgeSpeed
        )
        let furthest = max(shotList.contentSize.width - shotList.bounds.width, 0)
        if speed < 0, shotList.contentOffset.x <= 0 { return 0 }
        if speed > 0, shotList.contentOffset.x >= furthest { return 0 }
        return speed
    }

    /// Starts the list scrolling by itself when the finger is at an end, and
    /// stops it when it is not.
    ///
    /// ⚠️ **A DISPLAY LINK, BECAUSE A FINGER HELD STILL SENDS NOTHING.** The long
    /// press reports movement; a thumb pressed against the bezel does not move,
    /// and the list must go on sliding under it all the same.
    private func keepTheListScrolling() {
        guard edgeScrollSpeed != 0 else { return stopTheListScrolling() }
        guard edgeScroll.link == nil else { return }
        let link = CADisplayLink(target: edgeScroll, selector: #selector(EdgeScrollProxy.tick(_:)))
        edgeScroll.owner = self
        edgeScroll.link = link
        edgeScrollBeat = 0
        link.add(to: .main, forMode: .common)
    }

    private func stopTheListScrolling() {
        edgeScroll.link?.invalidate()
        edgeScroll.link = nil
    }

    fileprivate func edgeScrollTicked(_ link: CADisplayLink) {
        let elapsed = edgeScrollBeat == 0 ? link.duration : link.timestamp - edgeScrollBeat
        edgeScrollBeat = link.timestamp
        // A beat that arrives late must not throw the list a screen.
        scrollTheList(forSeconds: min(max(elapsed, 0), 1.0 / 20))
    }

    /// One step of the list scrolling by itself. The move is heard back through
    /// `listScrolled`, which is what carries the piece along.
    private func scrollTheList(forSeconds elapsed: Double) {
        let speed = edgeScrollSpeed
        guard speed != 0 else { return stopTheListScrolling() }
        let furthest = max(shotList.contentSize.width - shotList.bounds.width, 0)
        shotList.contentOffset.x = min(
            max(shotList.contentOffset.x + speed * CGFloat(elapsed), 0), furthest
        )
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopTheListScrolling() }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginZoom()
        case .changed:
            let next = MediaTimelining.zoomed(pointsPerSecond, by: gesture.scale)
            gesture.scale = 1
            zoom(to: next)
        case .ended, .cancelled, .failed:
            endZoom()
        default:
            break
        }
    }

    // ⚠️ **THE THREE ROUTINES A PINCH USES, NAMED — SO THE DEBUG HOOK GOES
    // THROUGH THEM RATHER THAN ALONGSIDE.** `debugPinch` was a shortcut that set
    // the scale and moved the film, and skipped `beginZoom` entirely: it never
    // retired the frames in flight, so the test written to prove that a zoom
    // retires them passed on a path that does not. The crop surface states the
    // same rule — a test re-entering by a copy of the logic is a test of the copy.
    private func beginZoom() {
        zoomAnchorSeconds = playedSecondsUnderNeedle
        isZooming = true
            // ⚠️ **THE PICTURES ARE DROPPED ONCE, AT THE START.** A tile's index
            // means a different moment at every scale, so what is cached is
            // wrong the instant the scale moves. Dropping them per sample would
            // re-request sixty times a second; dropping them once and asking
            // again on release costs one refill, and in between every tile shows
            // the nearest frame it has, which is charter F14 doing its job.
            // Through `forgetFrames`, so the generation is bumped: a tile index
            // means a different moment at every scale, and a batch in flight has
            // already captured its indices.
        forgetFrames()
        onScrubbing?(true)
    }

    private func zoom(to scale: CGFloat) {
        guard abs(scale - pointsPerSecond) > 0.01 else { return }
        pointsPerSecond = scale
        setNeedsLayout()
        layoutIfNeeded()
        keepTheNeedleOnTheAnchor()
    }

    private func endZoom() {
        isZooming = false
        onScrubbing?(false)
        setNeedsLayout()
    }

    /// Holds the moment the pinch began on under the needle, so the film grows
    /// around what the author is looking at rather than around its own start.
    private func keepTheNeedleOnTheAnchor() {
        isFollowingPlayback = true
        scroller.contentOffset.x = offset(forPlayedSeconds: zoomAnchorSeconds)
        isFollowingPlayback = false
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            // ⚠️ THE SAME QUESTION THE DELEGATE ANSWERED, ASKED THE SAME WAY —
            // see `touchDownX`. Reading the current location here would take a
            // different handle from the one the gesture was allowed to begin for.
            takeHold(at: touchDownX(of: pan))
        case .changed:
            // ⚠️ **ZEROED EVERY SAMPLE, SO THE ARITHMETIC IS INCREMENTAL.** It is
            // what lets a handle dragged past the end of the clip come straight
            // back rather than first undoing its overshoot — the crop surface and
            // the straighten dial both do this.
            let moved = pan.translation(in: content).x
            pan.setTranslation(.zero, in: content)
            track(byPoints: moved)
        case .ended, .cancelled, .failed:
            finishDrag()
        default:
            break
        }
    }

    // ⚠️ **THE THREE ROUTINES A FINGER USES, NAMED — SO THE DEBUG HOOKS CAN GO
    // THROUGH THEM RATHER THAN ALONGSIDE.** The crop surface states the rule: a
    // test re-entering by a copy of the logic is a test of the copy.
    private func takeHold(at x: CGFloat) {
        stopEasing()
        grip = edge(at: x)
        guard grip != nil else { return }
        onScrubbing?(true)
    }

    /// ⚠️ **THE DRAG IS WORTH DIFFERENT AMOUNTS OF FILM IN DIFFERENT PIECES.**
    /// The track is drawn in played seconds, so a piece at 2× is half as wide as
    /// the film it covers and one point of finger is worth two frames rather than
    /// one. Converting a drag straight to source seconds — which is what the
    /// single-clock version did — moves a fast piece's edge twice as far as the
    /// finger went.
    private func track(byPoints points: CGFloat) {
        guard let grip, let index = selected else { return }
        let pieces = MediaTimelining.resolved(timeline, withinSource: duration)
        guard pieces.indices.contains(index) else { return }
        let wide = width(ofPiece: index)
        timeline = MediaTimelining.moved(
            timeline, piece: index, edge: grip,
            // The SIGNED converter. `playedSeconds(atX:)` floors at zero and
            // would turn every leftward sample into no movement at all.
            bySourceSeconds: MediaTimelining.sourceSeconds(
                ofPoints: points, atSpeed: pieces[index].speed, pointsPerSecond: pointsPerSecond
            ),
            withinSource: duration
        )
        // ⚠️ **THE LEFT PINCE IS THE MIRROR OF THE RIGHT ONE, AND THE TRACK IS
        // WHAT MOVES TO MAKE IT SO.** Asked for in those words: *"si on tire la
        // pince gauche vers la gauche… dévoiler la partie avant et pousser la
        // section précédente — en gros ce qu'on a fait pour la pince de droite, il
        // faut faire la même chose pour la pince de gauche."* The right pince
        // holds everything BEFORE it still and pushes what follows; the left one
        // must hold everything AFTER it still and push what precedes.
        //
        // A piece begins where the pieces before it end, and that number does not
        // change when its own start is dragged — so in the composition's own
        // coordinates a head that opens pushes ITSELF and everything after it to
        // the right, which is the opposite of what the eye is promised. Scrolling
        // the track by exactly what the piece gained cancels that: the piece's
        // closing edge, its film and every section after it stand perfectly
        // still, the sections BEFORE it slide aside, and the cap follows the
        // finger. Measured on the device by pixel correlation, both directions.
        //
        // ⚠️ **AND THE LEADING INSET IS WHAT LETS THE FIRST PIECE DO IT.** A
        // scroll view will not go past its own leading inset, and for the first
        // piece it is already sitting on it; the inset grows for the length of
        // the gesture and settles back on release.
        if grip == .start {
            let lost = wide - width(ofPiece: index)
            if abs(lost) > 0.01 {
                leadingSlack = max(leadingSlack + lost, 0)
                // Suppressed, because this is not the author scrubbing: the drag
                // reports the edge's own moment below, and a second announcement
                // carrying the needle's would seek the preview away from it.
                isFollowingPlayback = true
                scroller.contentInset.left =
                    MediaTimelining.centringInset(forTrackWidth: bounds.width) + leadingSlack
                scroller.contentOffset.x -= lost
                isFollowingPlayback = false
            }
        }
        setNeedsLayout()
        // The canvas shows the frame the handle is standing on, which is how a
        // trim is aimed. Continuous, and stores nothing.
        let moved = MediaTimelining.resolved(timeline, withinSource: duration)
        guard moved.indices.contains(index) else { return }
        switch grip {
        case .start:
            onScrub?(MediaTimelining.Moment(piece: index, sourceSeconds: moved[index].start))
        case .end:
            onScrub?(MediaTimelining.Moment(piece: index, sourceSeconds: moved[index].end))
        }
    }

    private func finishDrag() {
        let hadGrip = grip != nil
        grip = nil
        // The slack was the gesture's; the track settles back onto the composition.
        if leadingSlack != 0 {
            leadingSlack = 0
            setNeedsLayout()
        }
        guard hadGrip else { return }
        // ⚠️ **THE PREVIEW COMES BACK TO THE NEEDLE; THE TRACK DOES NOT GO TO THE
        // PREVIEW.** While a handle is held the canvas shows the frame the EDGE is
        // standing on — that is how a trim is aimed — so at the end of the gesture
        // the player is parked on that frame. Left there, the next beat of
        // playback had the track FOLLOW it: the whole film slid under the needle
        // the moment the finger came up, which reads as every section moving at
        // once and is the thing the author has asked three times to be rid of.
        // Sending the needle's own moment back puts the canvas where the playhead
        // is and leaves the film exactly where the eye left it.
        if let moment = momentUnderNeedle { onScrub?(moment) }
        onScrubbing?(false)
        onChange?(timeline)
    }

    #if DEBUG
    /// Internal for tests: the track's own state, and re-entry through the very
    /// routines a finger uses rather than around them.
    var debugTimeline: MediaTimeline { timeline }
    var debugFrameCount: Int { tiles.count }
    /// Internal for tests: the picture each square of film is SHOWING, keyed by
    /// its place on the track.
    ///
    /// ⚠️ **THE PICTURE ITSELF, NOT THE SECOND IT OUGHT TO BE.** Asking the track
    /// which second a tile stands for and comparing it with the same function's
    /// answer proves nothing; the only question that cannot be laundered is which
    /// image is on screen. The suite pairs this with a provider that hands back a
    /// different object per second.
    /// Every square of film on screen: where it is DRAWN and what it is SHOWING.
    /// A test pairs this with a provider that hands back a different object per
    /// second, which is how it can ask whether a piece's film travelled with it.
    ///
    /// ⚠️ **DRAWN**: where a square has a view, `from`/`width` are that view's
    /// rectangle in film coordinates (which are content x), read through the
    /// window it stands in.
    var debugFilm: [(piece: Int, from: CGFloat, width: CGFloat, picture: UIImage?)] {
        squares.map { square in
            guard let view = tiles[square.place] else {
                return (square.piece, square.from, square.width, nil)
            }
            let drawn = view.convert(view.bounds, to: film)
            return (square.piece, drawn.minX, drawn.width, view.picture.image)
        }
    }
    /// Internal for tests: where each square's PICTURE is laid inside it. ⚠️ THE
    /// DRAWN EVIDENCE OF THE CROP — a square the window cuts in half must hold a
    /// full-width picture hanging out of itself, not a squeezed one.
    var debugFilmCrop: [(width: CGFloat, picture: CGRect)] {
        squares.compactMap { square in
            tiles[square.place].map { ($0.bounds.width, $0.picture.frame) }
        }
    }
    /// Internal for tests: every piece's window, read off its layer — frames in
    /// film coordinates, in play order.
    var debugFilmWindows: [(
        piece: Int, frame: CGRect, radius: CGFloat, corners: CACornerMask,
        clips: Bool, curve: CALayerCornerCurve
    )] {
        windows.sorted { $0.key < $1.key }.map { piece, window in
            (
                piece, window.frame, window.layer.cornerRadius, window.layer.maskedCorners,
                window.clipsToBounds, window.layer.cornerCurve
            )
        }
    }
    /// Internal for tests: every square's view — where it is drawn in film
    /// coordinates, which window it stands in, and whether it carries a radius
    /// of its own (it must not).
    var debugTiles: [(
        place: MediaTimelining.Square.Place, frame: CGRect, windowPiece: Int?, cornerRadius: CGFloat
    )] {
        tiles.map { place, view in
            let window = windows.first { $0.value === view.superview }?.key
            return (place, view.convert(view.bounds, to: film), window, view.layer.cornerRadius)
        }
        .sorted { $0.frame.minX < $1.frame.minX }
    }
    /// Internal for tests: for each square on screen, where the sheet puts its
    /// picture and where the picture is actually drawn — both in film
    /// coordinates. Carving daylight must move neither.
    var debugPictureOnTheSheet: [(sheet: CGFloat, drawn: CGFloat)] {
        squares.compactMap { square in
            tiles[square.place].map { view in
                (square.filmFrom, view.convert(view.picture.frame, to: film).minX)
            }
        }
    }
    /// Internal for tests: the four inner-corner plates, in content coordinates.
    var debugFillets: [(
        frame: CGRect, isShowing: Bool, isBehindTheFilm: Bool, isWhite: Bool,
        hasCorners: Bool, hasShadow: Bool
    )] {
        let filmAt = content.subviews.firstIndex(of: film) ?? -1
        return innerCorners.map { plate in
            (
                plate.frame, !plate.isHidden,
                (content.subviews.firstIndex(of: plate) ?? .max) < filmAt,
                plate.backgroundColor == .white,
                plate.layer.cornerRadius > 0, plate.layer.shadowOpacity > 0
            )
        }
    }
    /// Internal for tests: whether ANY part of the selection's ink is showing.
    var debugSelectionInkShowing: Bool {
        ([topBar, bottomBar, startGrab, endGrab] + innerCorners).contains { !$0.isHidden }
    }
    /// Internal for tests: the caps' own shapes — their outer radius and which
    /// corners it rounds, and the shadow's extent in the cap's coordinates.
    var debugCapShapes: [(
        width: CGFloat, height: CGFloat, radius: CGFloat, corners: CACornerMask,
        shadowRadius: CGFloat, shadowPath: CGPath?
    )] {
        [startGrab, endGrab].map { cap in
            (
                cap.bounds.width, cap.bounds.height, cap.layer.cornerRadius, cap.layer.maskedCorners,
                cap.layer.shadowRadius, cap.layer.shadowPath
            )
        }
    }
    /// Internal for tests: the reach's source, to compare with the drawn caps.
    var debugHeldCaps: (start: ClosedRange<CGFloat>, end: ClosedRange<CGFloat>)? {
        heldCaps().map { ($0.start, $0.end) }
    }
    /// ⚠️ **Internal for tests: CHARTER T6, WALKED.** Every layer in the track
    /// wider or taller than the Metal limit at `scale` that is decorated in a
    /// way that needs a texture that size — rounded, masked, clipping
    /// sublayers, rasterised, shadowed, or holding contents.
    func debugLayersPastTheMetalLimit(scale: CGFloat) -> [String] {
        var found: [String] = []
        func walk(_ layer: CALayer) {
            let longest = max(layer.bounds.width, layer.bounds.height) * scale
            if longest > 16384 {
                let decorated = layer.cornerRadius > 0 || layer.mask != nil
                    || (layer.masksToBounds && !(layer.sublayers ?? []).isEmpty)
                    || layer.shouldRasterize || layer.shadowOpacity > 0
                    || layer.contents != nil
                    || ((layer as? CAShapeLayer)?.path.map {
                        max($0.boundingBoxOfPath.width, $0.boundingBoxOfPath.height) * scale > 16384
                    } ?? false)
                if decorated {
                    let owner = layer.delegate.map { String(describing: type(of: $0)) } ?? "CALayer"
                    found.append("\(owner) \(Int(layer.bounds.width))x\(Int(layer.bounds.height))")
                }
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(layer)
        return found
    }
    static var debugSeamGap: CGFloat { Metrics.seamGap }
    static var debugFilmCorner: CGFloat { Metrics.filmCorner }
    static var debugCapCorner: CGFloat { Metrics.capCorner }
    static var debugCapShadowBlur: CGFloat { Metrics.capShadowBlur }
    static var debugFilletTuck: CGFloat { Metrics.filletTuck }
    static var debugBar: CGFloat { Metrics.bar }
    static var debugStampInset: CGFloat { Metrics.stampInset }
    static var debugStrip: CGFloat { Metrics.strip }
    /// Internal for tests: where the film row starts, in the track's coordinates.
    var debugStripY: CGFloat { stripY }
    /// Internal for tests: the rate stamps THEMSELVES, to ask where they stand in
    /// the z-order.
    var debugStampIsUnderTheFrame: Bool {
        guard let rail = content.subviews.firstIndex(of: topBar) else { return false }
        return rateStamps.allSatisfy { (content.subviews.firstIndex(of: $0) ?? .max) < rail }
    }
    /// Internal for tests: how many pictures are decoded and alive (charter T3).
    var debugDecodedCount: Int { decoded.count }
    /// Internal for tests: where the squares of film are DRAWN, in film
    /// coordinates, so a test can ask whether the last one stops at the end of
    /// the result.
    var debugTileFrames: [CGRect] { tiles.values.map { $0.convert($0.bounds, to: film) } }
    /// Internal for tests: which squares of film have a view on screen right
    /// now, in the order they are drawn.
    var debugTileIndices: [MediaTimelining.Square.Place] {
        squares.map(\.place).filter { tiles[$0] != nil }
    }
    /// Internal for tests: whether every tile on screen is showing something
    /// (charter F14).
    var debugEveryTileHasAPicture: Bool { tiles.values.allSatisfy { $0.picture.image != nil } }
    /// ⚠️ **THERE IS NOTHING LEFT TO DIM, AND THAT IS THE AXIS CHANGE.** The
    /// discarded head and tail used to be drawn greyed out beside the kept film,
    /// because the track was a picture of the FILE. It is a picture of the RESULT
    /// now: what is thrown away is simply not on it, and the way back is to drag
    /// a piece's edge out again. `debugPieceFrames` is what replaces this —
    /// where the kept pieces are, which is all there is.
    var debugContentWidth: CGFloat { scroller.contentSize.width }
    var debugCentringInset: CGFloat { scroller.contentInset.left }
    var debugContentOffset: CGFloat { scroller.contentOffset.x }
    /// Internal for tests: whether the track is holding a way of asking for
    /// pictures at all. Between two clips it must not be — the closure belongs to
    /// one file.
    var debugHasFramesProvider: Bool { framesProvider != nil }
    /// Internal for tests: whether the film is in the middle of an eased move.
    var debugIsEasing: Bool { isEasing }
    var debugFramesGeneration: Int { framesGeneration }
    /// ⚠️ **Internal for tests: whether an animation is ACTUALLY ON THE LAYER.**
    /// `contentOffset` is the model value and `UIView.animate` sets it at once —
    /// reading it back says where the film is GOING, never whether it is easing
    /// there. `uiview-animate-from-value-trap` records the same lesson about
    /// `alpha`. The layer's own animation keys are the only honest answer.
    var debugScrollIsAnimating: Bool {
        scroller.layer.animationKeys()?.isEmpty == false
    }
    var debugSecondsUnderNeedle: Double { sourceSecondsUnderNeedle }
    var debugKeptText: String? { keptLabel.isHidden ? nil : keptLabel.text }
    /// ⚠️ THE READOUT IS FIXED, NOT ON THE FILM — so it is inside the track's own
    /// bounds whatever the scroll offset is.
    var debugKeptIsOnScreen: Bool { bounds.contains(keptLabel.frame) && !keptLabel.isHidden }
    /// Internal for tests: whether the play button is showing the pause glyph.
    var debugShowsPause: Bool { playButton.accessibilityLabel == "Pause" }
    /// Internal for tests: the pieces of the selection's frame, in content
    /// coordinates, so a test can ask whether it actually closes.
    var debugTopRail: CGRect { topBar.frame }
    var debugBottomRail: CGRect { bottomBar.frame }
    var debugStartGrip: CGRect { startGrab.frame }
    var debugEndGrip: CGRect { endGrab.frame }
    var debugFilmFrame: CGRect { film.frame }
    /// Internal for tests: where the SELECTED piece is drawn, in content points
    /// — what its caps must stand outside of.
    var debugSelectedRangeX: ClosedRange<CGFloat>? {
        guard let index = selected else { return nil }
        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        guard let chosen = placed.first(where: { $0.index == index }) else { return nil }
        return chosen.from...max(chosen.to, chosen.from)
    }
    /// Internal for tests: taps the film where a finger would, through the very
    /// routine the recogniser calls — a tap's location cannot be set.
    func debugTap(atContentX x: CGFloat) { takeOrPutDown(atContentX: x) }
    /// Internal for tests: carries a piece the way a long press and a drag do.
    func debugLift(atContentX x: CGFloat) { lift(atContentX: x) }
    func debugCarry(toTrackX x: CGFloat) { carry(toTrackX: x) }
    func debugDrop() { drop() }
    /// Internal for tests: whether a piece is being carried right now.
    var debugCarrying: Int? { reordering }
    /// Internal for tests: whether the film can still be pushed past the needle.
    var debugScrollIsEnabled: Bool { scroller.isScrollEnabled }
    /// Internal for tests: where the shot list's chips are LAID, in the track's
    /// own coordinates and in play order — the whole of what a carry shows.
    ///
    /// ⚠️ **THE PLACEMENT, NOT `frame` — A FRAME IS READ THROUGH THE TRANSFORM.**
    /// The chip in hand is scaled, so its `frame` is 6% wider than the place it
    /// was given and hangs a few points off the leading edge. Asked that way, "are
    /// the chips the same width" is a question about the lift as much as about
    /// the layout, and it answered no. The lift has its own hook below.
    ///
    /// ⚠️ **CONVERTED OUT OF THE LIST, WHICH SCROLLS** — a finger reports track
    /// coordinates, and a test aiming at a chip must be told where it is on the
    /// track.
    var debugShotFrames: [CGRect] { shots.map { shotList.convert($0.placement, to: self) } }
    /// Internal for tests: which chip is lifted, and how far back the others
    /// stand. ⚠️ ASKED OF THE CHIPS THEMSELVES, not of `reordering` — the state
    /// says a piece is held, and only the drawing says the author can SEE it.
    var debugShotInHand: Int? { shots.firstIndex { $0.isInHand } }
    /// Internal for tests: how opaque each chip is — ⚠️ ALL OF THEM, ALWAYS, since
    /// a see-through chip is what the author reported — and which ones are
    /// shaded behind the one in hand.
    var debugShotOpacity: [CGFloat] { shots.map(\.alpha) }
    var debugShotShaded: [Bool] { shots.map(\.debugIsShaded) }
    /// Internal for tests: where each chip is DRAWN, lift included — which is
    /// what the daylight between two of them has to be measured on.
    var debugShotDrawnFrames: [CGRect] { shots.map { shotList.convert($0.frame, to: self) } }
    /// Internal for tests: how far the shot list has scrolled, how far it runs,
    /// and whether a finger could scroll it.
    var debugShotListOffset: CGFloat { shotList.contentOffset.x }
    var debugShotListWidth: CGFloat { shotList.contentSize.width }
    var debugShotListScrolls: Bool {
        !shotList.isHidden && shotList.isScrollEnabled
            && shotList.contentSize.width > shotList.bounds.width + 0.5
    }
    /// Internal for tests: whether the list is scrolling by itself.
    var debugListIsScrollingByItself: Bool { edgeScroll.link != nil }
    /// Internal for tests: one step of the list scrolling by itself, through the
    /// routine the display link calls — a link's clock cannot be set.
    func debugScrollTheList(forSeconds elapsed: Double) { scrollTheList(forSeconds: elapsed) }
    /// Internal for tests: a second finger scrolling the list.
    func debugScrollTheList(toOffset x: CGFloat) { shotList.contentOffset.x = x }
    static var debugShotMinimum: CGFloat { Metrics.shotMinimum }
    static var debugEdgeZone: CGFloat { Metrics.edgeZone }
    /// Internal for tests: what is animating on each chip and inside it.
    var debugShotAnimations: [[String]] { shots.map(\.debugAnimations) }
    var debugShotPictureAnimations: [[String]] { shots.map(\.debugPictureAnimations) }
    var debugShotPictureFrames: [CGRect] { shots.map(\.debugPictureFrame) }
    /// Internal for tests: the picture each chip shows.
    var debugShotPictures: [UIImage?] { shots.map(\.debugPicture) }
    /// Internal for tests: what is animating on the film — every window and
    /// every square — and on the frame.
    var debugFilmAnimations: [String] {
        (Array(windows.values) as [UIView] + Array(tiles.values) as [UIView])
            .flatMap { $0.layer.animationKeys() ?? [] }
    }
    var debugFrameAnimations: [String] {
        ([topBar, bottomBar, startGrab, endGrab, startGlyph, endGlyph] + innerCorners)
            .flatMap { $0.layer.animationKeys() ?? [] }
    }
    /// Internal for tests: where the ruler's marks are DRAWN, in the track's own
    /// coordinates, and what they say.
    var debugRulerMarkCentres: [CGFloat] {
        ruler.debugMarkCentres.map { $0 + ruler.frame.minX }
    }
    /// Internal for tests: the chips THEMSELVES, in play order.
    ///
    /// ⚠️ **IDENTITY, BECAUSE AN INDEX ANSWERS ITS OWN QUESTION.** "Which index is
    /// in hand" is decided by the same number the assertion reads, so a chip that
    /// stayed behind while its piece moved still answers it correctly — and is
    /// showing the wrong piece's film. Proved by deliberate break: leaving the
    /// chips where they were turned nothing red until this hook existed.
    var debugShotIdentities: [ObjectIdentifier] { shots.map(ObjectIdentifier.init) }
    /// Internal for tests: whether a press here would carry anything — the very
    /// predicate the delegate answers with, so the scroll is not taken hostage by
    /// a press that has nothing to lift.
    func debugWouldLift(atContentX x: CGFloat) -> Bool { wouldLift(atContentX: x) }
    /// Internal for tests: every `+` on screen, in content points, in order.
    var debugSeamMarks: [(index: Int, centre: CGPoint, hit: CGRect, glyph: String?)] {
        seamButtons.sorted { $0.key < $1.key }.map { index, button in
            (index, button.center, button.frame, button.debugGlyph)
        }
    }
    /// Internal for tests: whether any `+` can be seen at all.
    var debugSeamMarksShowing: Bool { !seamButtons.isEmpty && scroller.alpha > 0 && !scroller.isHidden }
    /// Internal for tests: taps a `+` exactly as a finger would.
    func debugTapSeam(_ index: Int) { seamButtons[index]?.sendActions(for: .primaryActionTriggered) }
    static var debugSeamHitSize: CGFloat { SeamButton.hitSize }
    /// Internal for tests: where each `+` is DRAWN, transform included.
    var debugSeamMarkFrames: [CGRect] { seamButtons.sorted { $0.key < $1.key }.map(\.value.frame) }
    /// Internal for tests: what each cap shows, start then end — "hidden",
    /// "grip", or the symbol DRAWN in place of the grip.
    var debugCapMarks: [String] {
        [(startGrab, startGrip, startGlyph), (endGrab, endGrip, endGlyph)].map { grab, line, glyph in
            if grab.isHidden { return "hidden" }
            switch (line.isHidden, glyph.isHidden) {
            case (false, true): return "grip"
            case (true, false): return MediaTransitionCatalog.debugSymbol(drawnIn: glyph.image) ?? "unknown"
            case (false, false): return "both"
            case (true, true): return "none"
            }
        }
    }
    /// Internal for tests: each cap's glyph box in content points, and the
    /// image's own size; nil where the glyph is hidden.
    var debugCapGlyphs: [(frame: CGRect, image: CGSize)?] {
        [startGlyph, endGlyph].map { glyph in
            glyph.isHidden ? nil : (glyph.convert(glyph.bounds, to: content), glyph.image?.size ?? .zero)
        }
    }
    var debugCapGlyphImageAssignments: Int { capGlyphImageAssignments }
    var debugCapGlyphAnimations: [String] {
        [startGlyph, endGlyph].flatMap { $0.layer.animationKeys() ?? [] }
    }
    var debugGrip: MediaTimelining.Edge? { grip }
    /// Internal for tests: whether any `+` would answer a finger.
    var debugSeamTakesTouches: Bool { seamButtons.values.contains { $0.isUserInteractionEnabled } }
    /// Internal for tests: the collapsed film's line, in content points.
    var debugLineFrames: [CGRect] { lineSegments.map(\.frame) }
    /// Internal for tests: the lit stretch and the transition's mark, in
    /// content points, or nil where nothing is drawn.
    var debugRehearsalFrame: CGRect? { rehearsalBar.isHidden ? nil : rehearsalBar.frame }
    var debugWindowFrame: CGRect? { windowMark.isHidden ? nil : windowMark.frame }
    var debugWindowCorner: CGFloat { windowMark.layer.cornerRadius }
    var debugNeedleFrame: CGRect { needle.frame }
    /// Internal for tests: what is animating on the film VIEW itself — the
    /// collapse — as opposed to the pieces inside it.
    var debugFilmOwnAnimations: [String] { film.layer.animationKeys() ?? [] }
    var debugFilmAlpha: CGFloat { film.alpha }
    /// Internal for tests: what the line and the bars are animating.
    var debugLineAnimations: [String] {
        (lineSegments + [rehearsalBar, windowMark]).flatMap { $0.layer.animationKeys() ?? [] }
    }
    /// Internal for tests: whether a gesture of each kind would be allowed to
    /// begin — asked of the very delegate method a finger reaches.
    var debugGesturesThatWouldBegin: [String] {
        let asked: [(name: String, recogniser: UIGestureRecognizer)] = [
            ("pinch", pinch), ("lift", lift), ("handle", contentPan)
        ]
        return asked.filter { gestureRecognizerShouldBegin($0.recogniser) }.map(\.name)
    }
    /// Internal for tests: what a tap on the scroller would do, through the
    /// recogniser's own action.
    func debugTapped(atContentX x: CGFloat) { recognisedTap(reportedAtContentX: x) }
    /// Internal for tests: a recognised tap that LANDED at one place and was
    /// reported at another — the film moved under a resting finger.
    func debugTapped(landedAt landed: CGFloat, reportedAt reported: CGFloat) {
        tapLanding = landed
        recognisedTap(reportedAtContentX: reported)
    }
    /// Internal for tests: a press that landed at one place and is recognised
    /// at another, asked of the very routine the recogniser asks.
    func debugWouldLift(landedAt landed: CGFloat) -> Bool {
        liftLanding = landed
        defer { liftLanding = nil }
        return gestureRecognizerShouldBegin(lift)
    }
    /// Internal for tests: the tap that answers a cap's `+` and the handle pan
    /// share a view, and nothing lets them recognise together — so a drag is
    /// never also a tap.
    var debugTapYieldsToTheHandle: Bool {
        let delegate = self as UIGestureRecognizerDelegate
        return selectTap.view === contentPan.view && selectTap.delegate === self
            && !(delegate.gestureRecognizer?(selectTap, shouldRecognizeSimultaneouslyWith: contentPan) ?? false)
            && !(delegate.gestureRecognizer?(contentPan, shouldRecognizeSimultaneouslyWith: selectTap) ?? false)
    }
    /// Internal for tests: whether the track is put away — every part of it, not
    /// just one, since any part left showing is part of the mess that was
    /// reported.
    /// Internal for tests: whether the ruler is faded at its ends — which it must
    /// be at rest, where it passes behind the play button and the readout, and
    /// must NOT be while a piece is carried, where the fade would hide the first
    /// and last seams.
    var debugRulerIsFaded: Bool { rulerHost.layer.mask != nil }
    /// Internal for tests: the room kept at both ends of the shot list.
    static var debugShotInset: CGFloat { Metrics.shotInset }
    var debugTrackIsPutAway: Bool { partsOfTheTrack.allSatisfy { $0.alpha < 0.01 } }
    var debugTrackIsShowing: Bool { partsOfTheTrack.allSatisfy { $0.alpha > 0.99 } }
    /// ⚠️ **Internal for tests: whether the frame is DRAWN, which is not the same
    /// question as whether a piece is held.** A test that asked only `selected`
    /// could not see a layout that framed something anyway — proved by deliberate
    /// break: drawing the frame around piece 0 whatever was held left every
    /// selection test green.
    var debugSelectionIsDrawn: Bool {
        !topBar.isHidden && !bottomBar.isHidden && !startGrab.isHidden && !endGrab.isHidden
            && (innerCorners.allSatisfy { !$0.isHidden } || (anyFrame == nil && posterFrame == nil))
    }
    /// Internal for tests: which piece is held, and where every piece is drawn.
    var debugSelectedPiece: Int? { selected }
    var debugPieceFrames: [ClosedRange<CGFloat>] {
        MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        ).map { $0.from...max($0.to, $0.from) }
    }
    /// Internal for tests: presses play/pause the way a finger would.
    func debugTapPlayPause() { onPlayPause?() }
    var debugRulerMarks: [String] { ruler.debugMarks }
    /// Internal for tests: how many midpoint dots the ruler is drawing (F9).
    var debugRulerDotCount: Int { ruler.debugDotCount }
    var debugNeedleIsCentred: Bool { abs(needle.frame.midX - bounds.midX) < 0.5 }
    /// Internal for tests: how wide a second of film is drawn right now.
    var debugPointsPerSecond: CGFloat { pointsPerSecond }
    /// Internal for tests: pinches the way two fingers would, through the very
    /// routine the recogniser calls.
    func debugPinch(by scale: CGFloat) {
        beginZoom()
        zoom(to: MediaTimelining.zoomed(pointsPerSecond, by: scale))
        endZoom()
    }
    var debugHasGrip: Bool { grip != nil }

    /// Whether a touch at `x` in CONTENT coordinates would take a handle rather
    /// than scroll the film — the very predicate the delegate asks.
    func debugWouldTakeAHandle(at x: CGFloat) -> Bool { takesAHandle(at: x) }


    /// Internal for tests: where the caps are drawn, which is what the reach must
    /// be measured from.
    var debugHandleCentres: (start: CGFloat, end: CGFloat)? { handleCentres() }

    /// Internal for tests: whether the view the handle pan is attached to can
    /// actually be touched at this point of the film. A perfect predicate on a
    /// view the finger cannot reach is still a dead handle.
    func debugPanReceivesTouches(atContentX x: CGFloat) -> Bool {
        guard let host = contentPan.view else { return false }
        let point = content.convert(CGPoint(x: x, y: Metrics.strip / 2), to: host)
        return host.bounds.contains(point)
    }

    /// ⚠️ **THE WIRING THE PREDICATE ABOVE CANNOT SEE.** A perfect answer from a
    /// recogniser nobody asks is still a track that cannot be scrolled: the pan
    /// must be delegated here, and it must live INSIDE the scroller — on the
    /// track view it would be an outsider to `ChipScrollView`'s arbitration rule,
    /// and the two "you go first" requirements would form a cycle.
    var debugHandlePanIsDelegatedHere: Bool { contentPan.delegate === self }
    var debugHandlePanLivesInsideTheScroller: Bool {
        contentPan.view.map { $0.isDescendant(of: scroller) } ?? false
    }

    func debugTakeHold(at x: CGFloat) { takeHold(at: x) }

    func debugDrag(byPoints points: CGFloat) {
        track(byPoints: points)
        layoutIfNeeded()
    }

    func debugRelease() { finishDrag() }

    /// Scrolls the film the way a finger would.
    ///
    /// ⚠️ **ASSIGNMENT ALONE — CALLING THE DELEGATE TOO FIRES IT TWICE.** A
    /// `contentOffset` assignment invokes `scrollViewDidScroll` synchronously, so
    /// the explicit call this used to make produced a SECOND scrub for the same
    /// movement, at a distance of zero. Everything downstream that reads a
    /// distance — the seek's tolerance, chiefly — then saw a still finger after
    /// every move, and the adaptive-tolerance test failed for a reason that was
    /// entirely the harness's. Found by that test, which is what it is for.
    func debugScroll(toContentOffset x: CGFloat) {
        scroller.contentOffset.x = x
    }

    /// Internal for tests: the daylight between two pieces' drawn film, in
    /// content points — read off the WINDOWS, for each pair of neighbours that
    /// both have one and both round the ends that face each other. A negative
    /// width is an overlap, never daylight.
    var debugSeamGaps: [(from: CGFloat, to: CGFloat)] {
        let open = debugFilmWindows
        return zip(open, open.dropFirst()).compactMap { left, right in
            guard right.piece == left.piece + 1,
                  left.corners.contains(.layerMaxXMinYCorner),
                  right.corners.contains(.layerMinXMinYCorner)
            else { return nil }
            return (left.frame.maxX, right.frame.minX)
        }
    }
    /// Internal for tests: what the pieces that are not as shot are stamped with.
    var debugRateStamps: [String] {
        rateStamps.compactMap { stamp in
            guard !stamp.isHidden else { return nil }
            // The rate alone — a filter's symbol is read by `debugFilterStamps`.
            return stamp.attributedText.map {
                $0.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
            } ?? stamp.text
        }.filter { !$0.isEmpty }
    }
    /// Internal for tests: how many visible stamps DRAW the filter symbol —
    /// read off the attachment's image, not off the piece.
    var debugFilterStamps: Int {
        rateStamps.filter { stamp in
            guard !stamp.isHidden, let text = stamp.attributedText, text.length > 0 else { return false }
            let attachment = text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
            return attachment?.image?.description.contains("system: \(Self.filterStampGlyph))") == true
        }.count
    }
    /// Internal for tests: where those stamps are, in content points — which is
    /// the half that says whether anyone can read them.
    var debugRateStampFrames: [CGRect] { rateStamps.filter { !$0.isHidden }.map(\.frame) }
    /// Internal for tests: the part of the film the track is showing.
    var debugVisibleContent: ClosedRange<CGFloat> {
        scroller.contentOffset.x...(scroller.contentOffset.x + bounds.width)
    }
    /// Internal for tests: whether the film's placeholder is standing in for it.
    var debugSkeletonIsShowing: Bool { !skeleton.isHidden }
    /// Internal for tests: where that placeholder is, which must be the FILM's
    /// rectangle and not the track's — at rest the leading half of the viewport
    /// holds no film at all.
    var debugSkeletonFrame: CGRect { skeleton.frame }
    /// Internal for tests: the picture of last resort, by identity — so a test
    /// can tell one clip's poster from another's.
    var debugPoster: UIImage? { posterFrame }
    #endif
}

/// One square of the film sheet.
///
/// ⚠️ **TWO VIEWS, SO THAT A HANDLE CROPS THE FRAME RATHER THAN SQUEEZING IT.**
/// A square at a piece's edge is only partly shown, and the picture inside it has
/// to stay where it was — that is what makes a handle READ as a window sliding
/// over a fixed sheet of film. Laid straight into the shortened rectangle, the
/// same frame would compress as the handle moved, which is the unfolding the
/// author asked to be rid of.
@MainActor
private final class FilmSquare: UIView {
    let picture = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        addSubview(picture)
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lays the picture at its OWN size and offset, which is what the crop is.
    func show(at offset: CGFloat, width: CGFloat) {
        picture.frame = CGRect(x: offset, y: 0, width: width, height: bounds.height)
    }
}

/// The part of one piece's film that is laid out: a rounded window its squares
/// stand in.
///
/// ⚠️ **ROUNDED HERE AND NOWHERE ELSE.** The squares carry no radius, so a
/// piece's corner is one curve however many squares it crosses. Bounded by the
/// squares inside it, never by the piece — charter T6.
@MainActor
private final class PieceFilmView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = nil
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// ⚠️ **A WEAK HOP, BECAUSE A DISPLAY LINK KEEPS ITS TARGET ALIVE** — the
/// editor's follower is built the same way for the same reason.
@MainActor
private final class EdgeScrollProxy: NSObject {
    weak var owner: MediaTimelineTrackView?
    weak var link: CADisplayLink?

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { return link.invalidate() }
        owner.edgeScrollTicked(link)
    }
}

/// One piece of the composition, drawn as a chip while the author is carrying
/// another one.
///
/// ⚠️ **TWO VIEWS, BECAUSE A SHADOW AND A MASK CANNOT SHARE ONE LAYER.** The
/// picture has to be clipped to the chip's rounded corners and the chip in hand
/// has to cast a shadow, and `masksToBounds` clips the shadow away with
/// everything else. The container carries the shadow and the border; the picture
/// inside it carries the mask.
@MainActor
private final class ShotView: UIView {
    private let picture = UIImageView()
    /// ⚠️ **A SHADE, NOT A TRANSPARENCY.** The chips that are not in hand used to
    /// stand back by ALPHA, which let the track and the footage behind the band
    /// show through them — reported as *"un fouillis car tout est en semi
    /// transparent"*. Darkening them with an opaque overlay says the same thing
    /// and shows nothing behind.
    private let shade = UIView()

    /// Whether this chip stands back behind the one in hand.
    var isShaded = false {
        didSet { shade.alpha = isShaded ? 1 : 0 }
    }

    /// Whether this is the piece in the author's hand. Elevation is the one cue
    /// every platform uses for "you are holding this" — Material states it
    /// outright, Apple's drag-and-drop guidance has the content "rise and adhere
    /// to the user's finger" — so the chip in hand gains a shadow and a rail and
    /// the rest lose theirs.
    var isInHand = false {
        didSet {
            guard isInHand != oldValue else { return }
            layer.shadowOpacity = isInHand ? 0.45 : 0
            layer.borderWidth = isInHand ? 1.5 : 0
        }
    }

    init(picture image: UIImage?) {
        super.init(frame: .zero)
        picture.image = image
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 6
        picture.layer.cornerCurve = .continuous
        // Opaque: an empty chip must not show the footage behind the band either.
        picture.backgroundColor = .systemGray5
        addSubview(picture)
        shade.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        shade.alpha = 0
        shade.isUserInteractionEnabled = false
        shade.layer.cornerRadius = 6
        shade.layer.cornerCurve = .continuous
        shade.clipsToBounds = true
        addSubview(shade)
        // ⚠️ **WHITE, FOR THE REASON THE CAPS ARE WHITE** — the rail is drawn on a
        // photograph, and `.label` disappears into half of them.
        layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowOpacity = 0
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where the chip was LAID, which is not `frame` once it is lifted: a frame
    /// is read through the transform.
    var placement: CGRect {
        CGRect(
            x: center.x - bounds.width / 2, y: center.y - bounds.height / 2,
            width: bounds.width, height: bounds.height
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = bounds
        shade.frame = bounds
    }

    var debugIsShaded: Bool { shade.alpha > 0.01 }
    var debugPicture: UIImage? { picture.image }
    /// What is animating on the chip, and on the picture INSIDE it.
    var debugAnimations: [String] { layer.animationKeys() ?? [] }
    var debugPictureAnimations: [String] { picture.layer.animationKeys() ?? [] }
    var debugPictureFrame: CGRect { picture.frame }
}

/// The timecodes above the film.
///
/// ⚠️ **A FIXED TYPE SIZE, WHICH IS NOT THIS APP'S HABIT.** Every other label in
/// this flow carries `adjustsFontForContentSizeCategory`. A chart axis cannot:
/// the marks are placed by TIME, so at the larger accessibility sizes the
/// timecodes would overlap each other rather than reflow, and a ruler whose
/// labels collide is less readable than one that stayed small. The number a
/// listener actually wants is the track's `accessibilityValue`, which is spoken
/// and has no size.
@MainActor
private final class RulerView: UIView {
    /// ⚠️ **ONE ARRAY, NOT THREE IN LOCKSTEP.** The label, its tick and its
    /// midpoint dot were three parallel arrays indexed together, which is the
    /// shape this repository already calls out under "one predicate, two owners":
    /// nothing enforced that they stayed the same length, and `layoutSubviews`
    /// read all three by index. Proved while checking the dot rule could fail —
    /// deleting the dot's creation did not turn a test red, it **crashed** with
    /// "Index out of range". One struct, one array, and the divergence cannot be
    /// written.
    private struct Mark {
        let label: UILabel
        let tick: UIView
        let dot: UIView
    }

    private var pieces: [Mark] = []
    private var marks: [Double] = []
    private var step: Double = 0
    private var showsDots = true
    private var place: (Double) -> CGFloat = { CGFloat($0) * MediaTimelining.pointsPerSecond }

    private enum Metrics {
        static let tick = CGSize(width: 1, height: 3)
        static let dot: CGFloat = 2
        static let gap: CGFloat = 2
    }

    /// ⚠️ **A DOT BETWEEN TWO LABELS — CHARTER F9.** Measured on CapCut and 快影:
    /// a label every two seconds with one dot at the one-second midpoint;
    /// Instagram labels every four with a dot at two. Without it a ruler is a row
    /// of numbers and the eye has nothing to judge a half-step against.
    /// ⚠️ **THE MARKS ARE PLACED BY A CLOSURE, BECAUSE THE RULER'S CLOCK AND THE
    /// TRACK'S AXIS ARE NO LONGER THE SAME THING.** A mark is a round number of
    /// PLAYED seconds; where it goes is wherever the film that plays at that
    /// moment is drawn, which only the timeline can say. The ruler used to
    /// multiply by the scale itself, which was right for exactly as long as one
    /// second of film was one second of result.
    ///
    /// ⚠️ **AND THE DOTS ARE OPTIONAL, BECAUSE A MIDPOINT NEEDS AN EVEN STEP.**
    /// The shot list's marks are its seams, which are as far apart as the pieces
    /// are long; a dot "half way" between two of them would sit over the middle
    /// of a chip and mean nothing.
    func mark(
        _ seconds: [Double], step: Double, showsDots: Bool = true,
        at place: @escaping (Double) -> CGFloat
    ) {
        self.step = step
        self.place = place
        self.showsDots = showsDots
        // ⚠️ THE MARKS MAY BE THE SAME WHILE THEIR PLACES HAVE MOVED — a rate
        // change leaves the result the same length at a different shape. The
        // early return only skips rebuilding the VIEWS; a layout is always asked
        // for.
        guard seconds != marks else { return setNeedsLayout() }
        marks = seconds
        while pieces.count > seconds.count {
            let spent = pieces.removeLast()
            spent.label.removeFromSuperview()
            spent.tick.removeFromSuperview()
            spent.dot.removeFromSuperview()
        }
        while pieces.count < seconds.count {
            let label = UILabel()
            label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            // ⚠️ **WHITE, LIKE THE SELECTION AND FOR THE SAME REASON.** The ruler
            // is drawn over the canvas, which is the author's own footage — a
            // `.label` timecode is black over a bright clip and gone over a dark
            // one. One fixed colour with a shadow is what every reference does,
            // and what `MediaPickerGridCell`'s duration stamp already does here.
            label.textColor = UIColor.white.withAlphaComponent(0.85)
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.35
            label.layer.shadowRadius = 2
            label.layer.shadowOffset = .zero
            label.textAlignment = .center
            addSubview(label)

            let tick = UIView()
            tick.backgroundColor = UIColor.white.withAlphaComponent(0.55)
            tick.layer.cornerRadius = Metrics.tick.width / 2
            addSubview(tick)

            let dot = UIView()
            dot.backgroundColor = UIColor.white.withAlphaComponent(0.45)
            dot.layer.cornerRadius = Metrics.dot / 2
            addSubview(dot)

            pieces.append(Mark(label: label, tick: tick, dot: dot))
        }
        for (piece, at) in zip(pieces, seconds) { piece.label.text = MediaTimelining.stamp(at) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (piece, at) in zip(pieces, marks) {
            let x = place(at)
            piece.label.sizeToFit()
            piece.label.frame = CGRect(
                x: x - piece.label.frame.width / 2, y: 0,
                width: piece.label.frame.width,
                height: bounds.height - Metrics.tick.height - Metrics.gap
            )
            piece.tick.frame = CGRect(
                x: x - Metrics.tick.width / 2, y: bounds.height - Metrics.tick.height,
                width: Metrics.tick.width, height: Metrics.tick.height
            )
            guard showsDots else {
                piece.dot.frame = .zero
                piece.dot.isHidden = true
                continue
            }
            piece.dot.isHidden = false
            let midpoint = place(at + step / 2)
            piece.dot.frame = CGRect(
                x: midpoint - Metrics.dot / 2,
                y: bounds.height - (Metrics.tick.height + Metrics.dot) / 2 - Metrics.dot / 2,
                width: Metrics.dot, height: Metrics.dot
            )
        }
    }

    #if DEBUG
    var debugMarks: [String] { pieces.compactMap(\.label.text) }
    /// ⚠️ **DOTS THAT ARE ACTUALLY DRAWN SOMEWHERE, NOT DOTS THAT EXIST.** This
    /// was `pieces.count`, and `debugMarks` is also derived from `pieces` — so
    /// the test comparing them read `pieces.count == pieces.count` and stayed
    /// green with the dot's positioning deleted, or with `addSubview(dot)`
    /// deleted. A dot at the origin with no size is not a mark on a ruler.
    var debugDotCount: Int {
        pieces.filter { $0.dot.frame.width > 0 && $0.dot.superview != nil && !$0.dot.isHidden }.count
    }
    /// Where each mark is DRAWN, in the ruler's own coordinates.
    var debugMarkCentres: [CGFloat] { pieces.map(\.label.frame.midX) }
    #endif
}
