import DesignSystem
import MediaPlayback
import UIKit

// The track's own views (#2388): the film's squares, a piece's film, the
// edge-scroll proxy, a shot and the ruler. Out of `MediaTimelineTrackView.swift`,
// which only lays them out.

/// One square of the film sheet.
///
/// ⚠️ **TWO VIEWS, SO THAT A HANDLE CROPS THE FRAME RATHER THAN SQUEEZING IT.**
/// A square at a piece's edge is only partly shown, and the picture inside it has
/// to stay where it was — that is what makes a handle READ as a window sliding
/// over a fixed sheet of film. Laid straight into the shortened rectangle, the
/// same frame would compress as the handle moved, which is the unfolding the
/// author asked to be rid of.
@MainActor
final class FilmSquare: UIView {
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
final class PieceFilmView: UIView {
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
final class EdgeScrollProxy: NSObject {
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
final class ShotView: UIView {
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
        picture.backgroundColor = Surface.mediaGround
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
final class RulerView: UIView {
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

    enum Metrics {
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
