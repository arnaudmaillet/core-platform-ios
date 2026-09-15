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
    /// handle is dragged — the moment of the file to put on the canvas. Stores
    /// nothing.
    var onScrub: ((Double) -> Void)?

    /// Whether a finger is on the track at all. The screen pauses playback while
    /// it is: a clip that keeps running fights every seek the scroll asks for,
    /// and the picture ends up somewhere neither the player nor the author chose.
    var onScrubbing: ((Bool) -> Void)?

    /// The author asked the clip to start or stop. The screen owns the player, so
    /// it answers by calling `showPaused(_:)` back.
    var onPlayPause: (() -> Void)?

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
    private let dimBefore = UIView()
    private let dimAfter = UIView()
    private let topBar = UIView()
    private let bottomBar = UIView()
    private let keptLabel = UILabel()
    private let startGrab = UIView()
    private let endGrab = UIView()
    private let startGrip = UIView()
    private let endGrip = UIView()
    private let needle = UIView()
    private let needleCap = UIView()

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

        for dim in [dimBefore, dimAfter] {
            dim.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
            dim.isUserInteractionEnabled = false
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
        content.addSubview(dimBefore)
        content.addSubview(dimAfter)
        content.addSubview(topBar)
        content.addSubview(bottomBar)
        content.addSubview(startGrab)
        content.addSubview(endGrab)
        startGrab.addSubview(startGrip)
        endGrab.addSubview(endGrip)
        scroller.addSubview(content)
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
        guard grip == nil else { return }
        self.duration = duration
        self.timeline = timeline
        setNeedsLayout()
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

    /// One square image view per visible tile, keyed by tile index.
    private var tiles: [Int: UIImageView] = [:]
    /// Retired views, kept to be filled in again rather than rebuilt.
    private var spareTiles: [UIImageView] = []
    /// The pictures that have arrived, keyed by tile index. Bounded by
    /// `Metrics.mostDecoded`.
    private var decoded: [Int: UIImage] = [:]
    /// Tiles already asked for, so a scroll does not ask twice.
    private var requesting: Set<Int> = []
    /// ⚠️ **CHARTER F14: THE STRIP NEVER SHOWS EMPTY BOXES.** Until a tile's own
    /// frame arrives it shows the nearest one already decoded, so a strip being
    /// scrolled into reads as a blurred film rather than as a row of holes.
    /// `PryntTrimmerView` does the same thing with its first decoded frame, and
    /// it is the cheapest possible improvement to how the strip feels.
    private var anyFrame: UIImage?

    /// Throws away every picture and asks again — for a clip that changed under
    /// the track.
    func forgetFrames() {
        decoded.removeAll()
        requesting.removeAll()
        anyFrame = nil
        for (_, view) in tiles { view.image = nil }
        setNeedsLayout()
    }

    /// Adds, retires and fills the squares of film that are on screen.
    private func refreshTiles() {
        let count = MediaTimelining.tileCount(
            acrossContentWidth: MediaTimelining.contentWidth(ofSourceSeconds: duration, pointsPerSecond: pointsPerSecond)
        )
        let window = MediaTimelining.visibleTiles(
            contentOffset: scroller.contentOffset.x, trackWidth: bounds.width, count: count
        )

        for (index, view) in tiles where !window.contains(index) {
            view.removeFromSuperview()
            tiles[index] = nil
            if spareTiles.count < 8 { spareTiles.append(view) }
        }

        for index in window {
            let view = tiles[index] ?? takeTile()
            tiles[index] = view
            view.frame = CGRect(
                x: CGFloat(index) * MediaTimelining.tileWidth, y: 0,
                width: MediaTimelining.tileWidth, height: Metrics.strip
            )
            view.image = decoded[index] ?? anyFrame
            // ⚠️ **THE FILM'S ENDS ARE ROUNDED ON THE END TILES, NOT ON THE
            // FILM.** Rounding the strip itself would ask Core Animation for a
            // mask as wide as the clip is long — 43200px at four minutes, far
            // past the 16384 Metal hard-asserts at, which is charter T6. Only two
            // tiles in the whole strip have a corner to draw, and they are 54pt
            // wide. The radius matches the selection's so the two agree wherever
            // they meet.
            let corners = Self.roundedCorners(ofTile: index, count: count)
            view.layer.maskedCorners = corners
            view.layer.cornerRadius = corners.isEmpty ? 0 : Metrics.corner
            view.layer.cornerCurve = .continuous
        }

        askForMissingTiles(in: window)
    }

    /// Which corners a tile rounds: the leading pair on the first, the trailing
    /// pair on the last, none in between.
    static func roundedCorners(ofTile index: Int, count: Int) -> CACornerMask {
        var corners: CACornerMask = []
        if index == 0 { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
        if index == count - 1 { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
        return corners
    }

    private func takeTile() -> UIImageView {
        let view = spareTiles.popLast() ?? {
            let made = UIImageView()
            made.contentMode = .scaleAspectFill
            made.clipsToBounds = true
            made.isUserInteractionEnabled = false
            return made
        }()
        film.addSubview(view)
        return view
    }

    private func askForMissingTiles(in window: Range<Int>) {
        guard let framesProvider, duration > 0, !isZooming else { return }
        let wanted = window.filter { decoded[$0] == nil && !requesting.contains($0) }
        guard !wanted.isEmpty else { return }
        requesting.formUnion(wanted)

        let spacing = MediaTimelining.tileSpacingSeconds(pointsPerSecond: pointsPerSecond)
        let seconds = wanted.map { MediaTimelining.sourceSeconds(ofTile: $0, pointsPerSecond: pointsPerSecond) }
        Task { [weak self] in
            guard let self else { return }
            let arrived = await framesProvider(seconds, Metrics.strip, spacing)
            for (index, second) in zip(wanted, seconds) {
                requesting.remove(index)
                guard let picture = arrived[second] else { continue }
                decoded[index] = picture
                if anyFrame == nil { anyFrame = picture }
                tiles[index]?.image = picture
            }
            forgetTheFurthestPictures(from: window)
        }
    }

    /// ⚠️ **CHARTER T3: THE PICTURES ALIVE AT ONCE ARE BOUNDED.** Without this
    /// the cache is a record of everywhere the author has ever scrolled, which on
    /// a long clip is the eager strip this whole design exists to avoid — just
    /// arrived at slowly. The ones furthest from where they are looking go first.
    private func forgetTheFurthestPictures(from window: Range<Int>) {
        guard decoded.count > Metrics.mostDecoded else { return }
        let middle = (window.lowerBound + window.upperBound) / 2
        let doomed = decoded.keys
            .sorted { abs($0 - middle) > abs($1 - middle) }
            .prefix(decoded.count - Metrics.mostDecoded)
        for index in doomed { decoded[index] = nil }
    }

    /// Brings `seconds` of the file under the needle without announcing it — the
    /// track following a clip that is playing.
    ///
    /// ⚠️ **REFUSED WHENEVER A FINGER IS INVOLVED.** A track that snapped back to
    /// the player's position while the author was pushing it would be unusable,
    /// and the deceleration after a flick is just as much the author's gesture as
    /// the drag that started it.
    func follow(sourceSeconds seconds: Double) {
        guard grip == nil, !scroller.isDragging, !scroller.isDecelerating, bounds.width > 0,
              !isEasing
        else { return }
        let target = MediaTimelining.contentOffset(
            forSourceSeconds: seconds, trackWidth: bounds.width, pointsPerSecond: pointsPerSecond
        )
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

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = MediaTimelining.centringInset(forTrackWidth: bounds.width)
        if abs(scroller.contentInset.left - inset) > 0.5 {
            scroller.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        }

        let width = MediaTimelining.contentWidth(ofSourceSeconds: duration, pointsPerSecond: pointsPerSecond)
        content.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        scroller.contentSize = content.bounds.size

        // One rail below the ruler's gap, so the frame's top edge has room.
        let stripY = Metrics.ruler + Metrics.gap + Metrics.bar
        rulerHost.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Metrics.ruler)
        ruler.frame = CGRect(
            x: -scroller.contentOffset.x, y: 0, width: width, height: Metrics.ruler
        )
        let step = MediaTimelining.rulerStep(pointsPerSecond: pointsPerSecond, acrossSourceSeconds: duration)
        ruler.mark(
            MediaTimelining.rulerSeconds(upToSourceSeconds: duration, step: step),
            step: step, pointsPerSecond: pointsPerSecond
        )

        film.frame = CGRect(x: 0, y: stripY, width: width, height: Metrics.strip)
        refreshTiles()

        let pieces = MediaTimelining.resolved(timeline, withinSource: duration)
        let startX = MediaTimelining.x(atSourceSeconds: pieces.first?.start ?? 0, pointsPerSecond: pointsPerSecond)
        let endX = MediaTimelining.x(atSourceSeconds: pieces.last?.end ?? duration, pointsPerSecond: pointsPerSecond)

        dimBefore.frame = CGRect(x: 0, y: stripY, width: startX, height: Metrics.strip)
        dimAfter.frame = CGRect(
            x: endX, y: stripY, width: max(width - endX, 0), height: Metrics.strip
        )
        // ⚠️ **THE RAILS STOP AT THE GRIPS, AND THE GRIPS STAND PROUD OF THE
        // FILM BY ONE RAIL AT EACH END.** Drawn the obvious way — rails spanning
        // the whole selection, caps laid on top — the straight rail runs past the
        // cap's ROUNDED corner and shows as a hair of white sticking out beyond
        // the curve at all four corners. Reported from the device as the borders
        // overshooting at the ends. Closing the frame instead of overlapping it
        // means: the caps own the corners, the rails own the span between them,
        // and the outside of the whole thing is one rounded rectangle.
        let frameTop = stripY - Metrics.bar
        let frameHeight = Metrics.strip + Metrics.bar * 2
        // ⚠️ **TUCKED UNDER THE CAPS, NOT BUTTED AGAINST THEM.** Two white
        // rectangles meeting exactly leave a hairline wherever rounding lands
        // them half a pixel apart. The caps are drawn after the rails and are
        // opaque, so an overlap is invisible and a gap cannot happen. What must
        // still never happen is the rail reaching past a cap's OUTER edge, which
        // is the overshoot this frame was rebuilt to remove.
        // ⚠️ **THE CAPS STAND OUTSIDE THE CUT, NOT ON TOP OF IT.** Laid over the
        // film they ate twelve points of picture at each end — and those are the
        // twelve the author is aiming with, the frames right at the edge of the
        // decision being made. The kept film runs `startX` to `endX` and is
        // visible end to end; the frame is drawn AROUND it.
        let frameFrom = startX - Metrics.grab
        let frameTo = endX + Metrics.grab
        let railFrom = frameFrom + Metrics.corner
        let railTo = max(frameTo - Metrics.corner, railFrom)
        topBar.frame = CGRect(
            x: railFrom, y: frameTop, width: railTo - railFrom, height: Metrics.bar
        )
        bottomBar.frame = CGRect(
            x: railFrom, y: frameTop + frameHeight - Metrics.bar,
            width: railTo - railFrom, height: Metrics.bar
        )
        // ⚠️ **WHERE YOU ARE AND HOW LONG IT WILL RUN — CHARTER F10.** The pair
        // CapCut and 快影 put at the left of their control row, and the single
        // number Instagram centres. It said only the second of the two, which is
        // the one you can already see by looking at the selection; the position
        // under the needle is the one you cannot.
        keptLabel.text = MediaTimelining.stamp(secondsUnderNeedle)
            + " / "
            + MediaTimelining.stamp(
                MediaTimelining.playedSeconds(of: timeline, withinSource: duration)
            )
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

        startGrab.frame = CGRect(
            x: frameFrom, y: frameTop, width: Metrics.grab, height: frameHeight
        )
        endGrab.frame = CGRect(
            x: endX, y: frameTop, width: Metrics.grab, height: frameHeight
        )
        for (grab, line) in [(startGrab, startGrip), (endGrab, endGrip)] {
            line.frame = CGRect(
                x: (grab.bounds.width - Metrics.grip.width) / 2,
                y: (grab.bounds.height - Metrics.grip.height) / 2,
                width: Metrics.grip.width, height: Metrics.grip.height
            )
        }

        needle.frame = CGRect(
            x: (bounds.width - Metrics.needle) / 2, y: 0,
            width: Metrics.needle, height: bounds.height
        )
        needleCap.frame = CGRect(
            x: (bounds.width - Metrics.needleCap) / 2, y: 0,
            width: Metrics.needleCap, height: Metrics.needleCap
        )

        accessibilityValue = Self.spoken(pieces)

        // Opened on the start of what is kept, once: the moment the author cares
        // about, rather than a clip that begins half a screen before its own
        // first frame.
        if !hasOpened, duration > 0, bounds.width > 0 {
            hasOpened = true
            isFollowingPlayback = true
            scroller.contentOffset.x = MediaTimelining.contentOffset(
                forSourceSeconds: pieces.first?.start ?? 0, trackWidth: bounds.width,
                pointsPerSecond: pointsPerSecond
            )
            isFollowingPlayback = false
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
        let next = MediaTimelining.moved(
            timeline, edge: .end, bySourceSeconds: delta, withinSource: duration
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
        ruler.frame.origin.x = -scroller.contentOffset.x
        guard !isFollowingPlayback, hasOpened else { return }
        onScrub?(secondsUnderNeedle)
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
        scroller.layer.removeAllAnimations()
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
    private func refreshReadout() {
        keptLabel.text = MediaTimelining.stamp(secondsUnderNeedle)
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

    private var secondsUnderNeedle: Double {
        MediaTimelining.sourceSeconds(
            atContentOffset: scroller.contentOffset.x,
            trackWidth: bounds.width,
            pointsPerSecond: pointsPerSecond,
            withinSource: duration
        )
    }

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
        guard recogniser === contentPan else { return true }
        return takesAHandle(at: recogniser.location(in: content).x)
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
    private func handleCentres() -> (start: CGFloat, end: CGFloat)? {
        let pieces = MediaTimelining.resolved(timeline, withinSource: duration)
        guard let first = pieces.first, let last = pieces.last else { return nil }
        let cutFrom = MediaTimelining.x(
            atSourceSeconds: first.start, pointsPerSecond: pointsPerSecond
        )
        let cutTo = MediaTimelining.x(
            atSourceSeconds: last.end, pointsPerSecond: pointsPerSecond
        )
        return (cutFrom - Metrics.grab / 2, cutTo + Metrics.grab / 2)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            zoomAnchorSeconds = secondsUnderNeedle
            isZooming = true
            // ⚠️ **THE PICTURES ARE DROPPED ONCE, AT THE START.** A tile's index
            // means a different moment at every scale, so what is cached is
            // wrong the instant the scale moves. Dropping them per sample would
            // re-request sixty times a second; dropping them once and asking
            // again on release costs one refill, and in between every tile shows
            // the nearest frame it has, which is charter F14 doing its job.
            decoded.removeAll()
            requesting.removeAll()
            onScrubbing?(true)
        case .changed:
            let next = MediaTimelining.zoomed(pointsPerSecond, by: gesture.scale)
            gesture.scale = 1
            guard abs(next - pointsPerSecond) > 0.01 else { return }
            pointsPerSecond = next
            setNeedsLayout()
            layoutIfNeeded()
            keepTheNeedleOnTheAnchor()
        case .ended, .cancelled, .failed:
            isZooming = false
            onScrubbing?(false)
            setNeedsLayout()
        default:
            break
        }
    }

    /// Holds the moment the pinch began on under the needle, so the film grows
    /// around what the author is looking at rather than around its own start.
    private func keepTheNeedleOnTheAnchor() {
        isFollowingPlayback = true
        scroller.contentOffset.x = MediaTimelining.contentOffset(
            forSourceSeconds: zoomAnchorSeconds, trackWidth: bounds.width,
            pointsPerSecond: pointsPerSecond
        )
        isFollowingPlayback = false
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            takeHold(at: pan.location(in: content).x)
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

    private func track(byPoints points: CGFloat) {
        guard let grip else { return }
        timeline = MediaTimelining.moved(
            timeline, edge: grip,
            // The SIGNED converter. `sourceSeconds(atX:)` floors at zero and
            // would turn every leftward sample into no movement at all.
            bySourceSeconds: MediaTimelining.sourceSeconds(ofPoints: points, pointsPerSecond: pointsPerSecond),
            withinSource: duration
        )
        setNeedsLayout()
        // The canvas shows the frame the handle is standing on, which is how a
        // trim is aimed. Continuous, and stores nothing.
        let pieces = MediaTimelining.resolved(timeline, withinSource: duration)
        switch grip {
        case .start: onScrub?(pieces.first?.start ?? 0)
        case .end: onScrub?(pieces.last?.end ?? duration)
        }
    }

    private func finishDrag() {
        let hadGrip = grip != nil
        grip = nil
        guard hadGrip else { return }
        onScrubbing?(false)
        onChange?(timeline)
    }

    #if DEBUG
    /// Internal for tests: the track's own state, and re-entry through the very
    /// routines a finger uses rather than around them.
    var debugTimeline: MediaTimeline { timeline }
    var debugFrameCount: Int { tiles.count }
    /// Internal for tests: how many pictures are decoded and alive (charter T3).
    var debugDecodedCount: Int { decoded.count }
    /// Internal for tests: which tiles have a view on screen right now.
    var debugTileIndices: [Int] { tiles.keys.sorted() }
    /// Internal for tests: whether every tile on screen is showing something
    /// (charter F14).
    var debugEveryTileHasAPicture: Bool { tiles.values.allSatisfy { $0.image != nil } }
    var debugSelectionFrame: CGRect { CGRect(
        x: startGrab.frame.minX, y: startGrab.frame.minY,
        width: max(endGrab.frame.maxX - startGrab.frame.minX, 0), height: startGrab.frame.height
    ) }
    var debugIsDimmedBefore: Bool { dimBefore.frame.width > 0.5 }
    var debugIsDimmedAfter: Bool { dimAfter.frame.width > 0.5 }
    var debugContentWidth: CGFloat { scroller.contentSize.width }
    var debugCentringInset: CGFloat { scroller.contentInset.left }
    var debugContentOffset: CGFloat { scroller.contentOffset.x }
    /// Internal for tests: whether the film is in the middle of an eased move.
    var debugIsEasing: Bool { isEasing }
    /// ⚠️ **Internal for tests: whether an animation is ACTUALLY ON THE LAYER.**
    /// `contentOffset` is the model value and `UIView.animate` sets it at once —
    /// reading it back says where the film is GOING, never whether it is easing
    /// there. `uiview-animate-from-value-trap` records the same lesson about
    /// `alpha`. The layer's own animation keys are the only honest answer.
    var debugScrollIsAnimating: Bool {
        scroller.layer.animationKeys()?.isEmpty == false
    }
    var debugSecondsUnderNeedle: Double { secondsUnderNeedle }
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
    /// Internal for tests: where the KEPT film begins and ends, in content
    /// points — what the caps must stand outside of.
    var debugKeptRangeX: ClosedRange<CGFloat> {
        let pieces = MediaTimelining.resolved(timeline, withinSource: duration)
        let from = MediaTimelining.x(
            atSourceSeconds: pieces.first?.start ?? 0, pointsPerSecond: pointsPerSecond
        )
        let to = MediaTimelining.x(
            atSourceSeconds: pieces.last?.end ?? duration, pointsPerSecond: pointsPerSecond
        )
        return from...max(to, from)
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
        zoomAnchorSeconds = secondsUnderNeedle
        pointsPerSecond = MediaTimelining.zoomed(pointsPerSecond, by: scale)
        setNeedsLayout()
        layoutIfNeeded()
        keepTheNeedleOnTheAnchor()
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
    #endif
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
    private var pointsPerSecond = MediaTimelining.pointsPerSecond

    private enum Metrics {
        static let tick = CGSize(width: 1, height: 3)
        static let dot: CGFloat = 2
        static let gap: CGFloat = 2
    }

    /// ⚠️ **A DOT BETWEEN TWO LABELS — CHARTER F9.** Measured on CapCut and 快影:
    /// a label every two seconds with one dot at the one-second midpoint;
    /// Instagram labels every four with a dot at two. Without it a ruler is a row
    /// of numbers and the eye has nothing to judge a half-step against.
    func mark(_ seconds: [Double], step: Double, pointsPerSecond: CGFloat) {
        self.step = step
        self.pointsPerSecond = pointsPerSecond
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
            let x = MediaTimelining.x(atSourceSeconds: at, pointsPerSecond: pointsPerSecond)
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
            let midpoint = MediaTimelining.x(
                atSourceSeconds: at + step / 2, pointsPerSecond: pointsPerSecond
            )
            piece.dot.frame = CGRect(
                x: midpoint - Metrics.dot / 2,
                y: bounds.height - (Metrics.tick.height + Metrics.dot) / 2 - Metrics.dot / 2,
                width: Metrics.dot, height: Metrics.dot
            )
        }
    }

    #if DEBUG
    var debugMarks: [String] { pieces.compactMap(\.label.text) }
    var debugDotCount: Int { pieces.count }
    #endif
}
