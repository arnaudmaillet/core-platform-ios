import DesignSystem
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
        /// ⚠️ **THIN, AND THE THINNESS IS THE POINT.** A 2pt rail around a 54pt
        /// strip reads as a border drawn on a thing; 1.5 reads as the edge of the
        /// thing itself, which is what CapCut and Instagram both draw.
        static let bar: CGFloat = 1.5
        /// One radius for the selection AND for the film's own ends, so the two
        /// agree wherever they meet.
        static let corner: CGFloat = 8
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
        /// The seam a split leaves behind. Twice a rail, so a cut reads as a
        /// deliberate division of the film and not as one of its edges.
        static let cut: CGFloat = 3
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
    private let needle = UIView()
    private let needleCap = UIView()
    /// ⚠️ **THE FILM'S OWN FOOTPRINT WHILE IT HAS NO PICTURES — NOT A PLATE.**
    /// The band forbids a surface behind its tenant, and this does not break that
    /// rule: it is drawn in the rectangle the film is about to occupy, clipped to
    /// what is on screen, and it goes the moment there is anything at all to
    /// show. Without it the track opens as a white selection drawn around
    /// nothing, which is exactly how it was reported — "the timeline does not
    /// appear when it loads".
    private let skeleton = SkeletonBoneView(rounding: .fixed(Metrics.corner))
    /// One seam per interior boundary, so a split is something the author can
    /// SEE. A cut that changes only the export is a cut nobody can aim.
    private var cutMarks: [UIView] = []
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

        // ⚠️ THE ORDER OF THESE BLOCKS IS THE Z-ORDER. Film first, then what dims
        // it, then the selection's ink, then its handles.
        // ⚠️ **NO CORNER RADIUS AND NO CLIPPING ON THE FILM — CHARTER T6.** This
        // view is as wide as the clip is long: four minutes at sixty points a
        // second is 14400pt, which at 3x is 43200px, and a rounded, clipping
        // layer at that width asks Core Animation for a mask far past the 16384px
        // Metal hard-asserts at. The rounded ends the eye actually reads come
        // from the two grab bars, which are 13pt wide and carry the radius
        // themselves.
        film.isUserInteractionEnabled = false

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
            handle.layer.cornerRadius = Metrics.corner
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

        needle.backgroundColor = .tintColor
        needle.layer.cornerRadius = Metrics.needle / 2
        needleCap.backgroundColor = .tintColor
        needleCap.layer.cornerRadius = Metrics.needleCap / 2
        for part in [needle, needleCap] { part.isUserInteractionEnabled = false }

        content.addSubview(film)
        content.addSubview(topBar)
        content.addSubview(bottomBar)
        content.addSubview(startGrab)
        content.addSubview(endGrab)
        startGrab.addSubview(startGrip)
        endGrab.addSubview(endGrip)
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
        accessibilityLabel = "Trim, adjusts the end"

        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        takeOrPutDown(atContentX: gesture.location(in: content).x)
    }

    private func takeOrPutDown(atContentX x: CGFloat) {
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
        // frames. Swallowing a tap there meant the author could not take the
        // section on the other side of the cut by pointing at it: the tap did
        // nothing, they dragged the handle they could see, and the piece they
        // had held all along moved. Which is exactly "on ne raisonne pas par
        // clip". The band still protects a finger that misses a handle PAST the
        // film, which is what it was for.
        let under = MediaTimelining.piece(atPoints: x, in: placed)
        if let held = selected, let chosen = placed.first(where: { $0.index == held }),
           x >= chosen.from - Metrics.grab, x <= chosen.to + Metrics.grab,
           under == nil || under == held {
            return
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
        squares = MediaTimelining.squares(
            in: timeline, withinSource: duration,
            visible: (seen - MediaTimelining.filmMargin)...(
                seen + bounds.width + MediaTimelining.filmMargin
            ),
            pointsPerSecond: pointsPerSecond
        )
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

        let filmWidth = MediaTimelining.contentWidth(
            of: timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        for square in squares {
            let view = tiles[square.place] ?? takeTile()
            tiles[square.place] = view
            view.frame = CGRect(
                x: square.from, y: 0, width: square.width, height: Metrics.strip
            )
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
            // ⚠️ **THE FILM'S ENDS ARE ROUNDED ON THE END SQUARES, NOT ON THE
            // FILM.** Rounding the strip itself would ask Core Animation for a
            // mask as wide as the clip is long — 43200px at four minutes, far
            // past the 16384 Metal hard-asserts at, which is charter T6. Only two
            // squares in the whole strip have a corner to draw, and they are at
            // most 54pt wide.
            let corners = Self.roundedCorners(of: square, filmWidth: filmWidth)
            view.layer.maskedCorners = corners
            view.layer.cornerRadius = corners.isEmpty ? 0 : Metrics.corner
        }

        askForMissingTiles()
    }

    /// Which corners a square rounds: the leading pair on whichever square is
    /// drawn at the very start of the film, the trailing pair on whichever is
    /// drawn at its end, none in between — the seams inside the strip are drawn,
    /// not rounded.
    static func roundedCorners(
        of square: MediaTimelining.Square, filmWidth: CGFloat
    ) -> CACornerMask {
        var corners: CACornerMask = []
        if square.from <= 0.5 {
            corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner])
        }
        if square.from + square.width >= filmWidth - 0.5 {
            corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
        }
        return corners
    }

    private func takeTile() -> FilmSquare {
        let view = spareTiles.popLast() ?? FilmSquare(frame: .zero)
        film.addSubview(view)
        return view
    }

    private func askForMissingTiles() {
        guard let framesProvider, duration > 0, !isZooming else { return }
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
    func follow(playedSeconds seconds: Double) {
        guard grip == nil, reordering == nil, !scroller.isDragging, !scroller.isDecelerating,
              bounds.width > 0, !isEasing, seconds.isFinite
        else { return }
        let target = offset(forPlayedSeconds: seconds)
        guard MediaTimelining.easesFollow(byPoints: target - scroller.contentOffset.x) else {
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
        // cut. See `MediaTimelining.stepWithoutEasing` for where the line is.
        //
        // ⚠️ **AND THE FLAG IS HELD FOR THE WHOLE ANIMATION, NOT AROUND AN
        // ASSIGNMENT.** An animated content offset calls `scrollViewDidScroll`
        // on every frame of the ease, long after a flag set around the assignment
        // would have been cleared — and each of those callbacks would be read as
        // the author scrubbing, and seek the player to where the animation had
        // got to. The clip would chase its own animation.
        isEasing = true
        isFollowingPlayback = true
        UIView.animate(
            withDuration: 0.22, delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) { [self] in
            scroller.contentOffset.x = target
        } completion: { [weak self] _ in
            self?.isFollowingPlayback = false
            self?.isEasing = false
        }
    }

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

        film.frame = CGRect(x: 0, y: stripY, width: width, height: Metrics.strip)
        refreshTiles()

        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
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
        layOutTheSelection(placed, frameTop: frameTop, frameHeight: frameHeight)
        layOutTheCuts(placed, frameTop: frameTop, frameHeight: frameHeight, stripY: stripY)
        layOutTheSkeleton(filmWidth: width, stripY: stripY)

        needle.frame = CGRect(
            x: (bounds.width - Metrics.needle) / 2, y: 0,
            width: Metrics.needle, height: bounds.height
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
            let film = MediaTimelining.squares(
                in: timeline, withinSource: duration,
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
        _ placed: [MediaTimelining.Placement], frameTop: CGFloat, frameHeight: CGFloat
    ) {
        guard let index = selected, let chosen = placed.first(where: { $0.index == index }) else {
            for part in [topBar, bottomBar, startGrab, endGrab] { part.isHidden = true }
            return
        }
        for part in [topBar, bottomBar, startGrab, endGrab] { part.isHidden = false }
        // ⚠️ **THE CAPS STAND OUTSIDE THE PIECE, NOT ON TOP OF IT.** Laid over the
        // film they eat twelve points of picture at each end — and those are the
        // twelve the author is aiming with, the frames right at the edge of the
        // decision being made.
        // ⚠️ **AND THE RAILS STOP SHORT OF BOTH CAPS.** Drawn the obvious way —
        // rails spanning the whole selection, caps laid on top — the straight
        // rail runs past the cap's ROUNDED corner and shows as a hair of white
        // sticking out beyond the curve at all four corners. Reported from the
        // device as the borders overshooting at the ends.
        let frameFrom = chosen.from - Metrics.grab
        let frameTo = chosen.to + Metrics.grab
        let railFrom = frameFrom + Metrics.corner
        let railTo = max(frameTo - Metrics.corner, railFrom)
        topBar.frame = CGRect(
            x: railFrom, y: frameTop, width: railTo - railFrom, height: Metrics.bar
        )
        bottomBar.frame = CGRect(
            x: railFrom, y: frameTop + frameHeight - Metrics.bar,
            width: railTo - railFrom, height: Metrics.bar
        )
        startGrab.frame = CGRect(
            x: frameFrom, y: frameTop, width: Metrics.grab, height: frameHeight
        )
        endGrab.frame = CGRect(
            x: chosen.to, y: frameTop, width: Metrics.grab, height: frameHeight
        )
        for (grab, line) in [(startGrab, startGrip), (endGrab, endGrip)] {
            line.frame = CGRect(
                x: (grab.bounds.width - Metrics.grip.width) / 2,
                y: (grab.bounds.height - Metrics.grip.height) / 2,
                width: Metrics.grip.width, height: Metrics.grip.height
            )
        }
    }

    private static func spoken(_ pieces: [MediaSegment]) -> String {
        let seconds = Int(pieces.reduce(0) { $0 + $1.playedSeconds }.rounded())
        return seconds == 1 ? "1 second kept" : "\(seconds) seconds kept"
    }

    // MARK: - Spoken adjustment

    /// One second per swipe: the floor `MediaTimelining` enforces, so a viewer
    /// cannot step into a state the handles refuse.
    private static let spokenStep: Double = 1

    override func accessibilityIncrement() { adjustEnd(bySourceSeconds: Self.spokenStep) }

    override func accessibilityDecrement() { adjustEnd(bySourceSeconds: -Self.spokenStep) }

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
        let stripY = Metrics.ruler + Metrics.gap + Metrics.bar
        layOutTheSkeleton(
            filmWidth: MediaTimelining.contentWidth(
                of: timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
            ),
            stripY: stripY
        )
        // The stamps are clamped into the viewport, so they move with it.
        if !rateStamps.isEmpty {
            layOutTheRateStamps(
                MediaTimelining.placements(
                    timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
                ),
                stripY: stripY
            )
        }
        guard !isFollowingPlayback, hasOpened, let moment = momentUnderNeedle else { return }
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

    /// The seams a split left behind, and the stamp a piece carries when it is
    /// not playing as shot.
    ///
    /// ⚠️ **A SPLIT THAT CANNOT BE SEEN IS A SPLIT NOBODY CAN AIM.** Cutting a
    /// clip in two keeps both halves, so without these the author taps the
    /// scissors, the export changes, and the track looks exactly as it did. The
    /// same is true of a rate: the readout's total shortens, which says SOMETHING
    /// happened but not to which piece.
    ///
    /// ⚠️ **INTERIOR BOUNDARIES ONLY.** A seam is where two pieces MEET on the
    /// track; the outer ends of the whole result are not seams, and drawing one
    /// there would put a white bar under the first and last frame.
    private func layOutTheCuts(
        _ placed: [MediaTimelining.Placement], frameTop: CGFloat, frameHeight: CGFloat,
        stripY: CGFloat
    ) {
        let seams = placed.dropLast().map(\.to)
        while cutMarks.count > seams.count { cutMarks.removeLast().removeFromSuperview() }
        while cutMarks.count < seams.count {
            let mark = UIView()
            mark.backgroundColor = .white
            mark.isUserInteractionEnabled = false
            content.insertSubview(mark, aboveSubview: film)
            cutMarks.append(mark)
        }
        for (mark, x) in zip(cutMarks, seams) {
            mark.frame = CGRect(
                x: x - Metrics.cut / 2, y: frameTop, width: Metrics.cut, height: frameHeight
            )
        }

        layOutTheRateStamps(placed, stripY: stripY)
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
    private func layOutTheRateStamps(_ placed: [MediaTimelining.Placement], stripY: CGFloat) {
        let stamped = placed.filter { abs($0.piece.speed - 1) > 0.001 }
        while rateStamps.count > stamped.count { rateStamps.removeLast().removeFromSuperview() }
        while rateStamps.count < stamped.count {
            let stamp = UILabel()
            stamp.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            stamp.textColor = .white
            stamp.isUserInteractionEnabled = false
            stamp.layer.shadowColor = UIColor.black.cgColor
            stamp.layer.shadowOpacity = 0.4
            stamp.layer.shadowRadius = 2
            stamp.layer.shadowOffset = .zero
            content.addSubview(stamp)
            rateStamps.append(stamp)
        }
        for (stamp, at) in zip(rateStamps, stamped) {
            stamp.text = MediaTimelining.rateLabel(at.piece.speed)
            stamp.sizeToFit()
            let from = at.from
            let to = at.to
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
        guard recogniser !== pinch else { return duration > 0 }
        guard recogniser !== lift else { return wouldLift(atContentX: lift.location(in: content).x) }
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
        return placed.count > 1 && pieceAimedAt(x, in: placed) != nil
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
        if let held = selected, let chosen = placed.first(where: { $0.index == held }),
           x >= chosen.from - Metrics.grab, x <= chosen.to + Metrics.grab {
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
        guard let index = selected else { return nil }
        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        guard let chosen = placed.first(where: { $0.index == index }) else { return nil }
        return (chosen.from - Metrics.grab / 2, chosen.to + Metrics.grab / 2)
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
        case .began: lift(atContentX: press.location(in: content).x)
        case .changed: carry(toTrackX: press.location(in: self).x)
        case .ended, .cancelled, .failed: drop()
        default: break
        }
    }

    // ⚠️ **THE THREE ROUTINES THE PRESS USES, NAMED — SO THE TESTS GO THROUGH
    // THEM RATHER THAN ALONGSIDE.** A long press's state cannot be set from a
    // test, and `debugPinch` records what re-entering by a copy of the logic
    // costs: it skipped `beginZoom` entirely and the test written to prove that a
    // zoom retires its frames passed on a path that does not.
    private func lift(atContentX x: CGFloat) {
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
            underTrackX: x - scroller.contentOffset.x,
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
    var debugFilm: [(piece: Int, from: CGFloat, width: CGFloat, picture: UIImage?)] {
        squares.map { ($0.piece, $0.from, $0.width, tiles[$0.place]?.picture.image) }
    }
    /// Internal for tests: where each square's PICTURE is laid inside it. ⚠️ THE
    /// DRAWN EVIDENCE OF THE CROP — a square the window cuts in half must hold a
    /// full-width picture hanging out of itself, not a squeezed one.
    var debugFilmCrop: [(width: CGFloat, picture: CGRect)] {
        squares.compactMap { square in
            tiles[square.place].map { (square.width, $0.picture.frame) }
        }
    }
    /// Internal for tests: how many pictures are decoded and alive (charter T3).
    var debugDecodedCount: Int { decoded.count }
    /// Internal for tests: where the squares of film are, so a test can ask
    /// whether the last one stops at the end of the result.
    var debugTileFrames: [CGRect] { tiles.values.map(\.frame) }
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

    /// Internal for tests: where the seams a split left are, in content points.
    var debugCutMarks: [CGFloat] { cutMarks.map(\.frame.midX).sorted() }
    /// Internal for tests: what the pieces that are not as shot are stamped with.
    var debugRateStamps: [String] { rateStamps.compactMap { $0.isHidden ? nil : $0.text } }
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
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lays the picture at its OWN size and offset, which is what the crop is.
    func show(at offset: CGFloat, width: CGFloat) {
        picture.frame = CGRect(x: offset, y: 0, width: width, height: bounds.height)
    }
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
