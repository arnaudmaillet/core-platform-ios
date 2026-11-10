import DesignSystem
import UIKit

/// One member's face in a group's picture (#2233): their name — for their
/// initials and for VoiceOver — and their picture.
///
/// `awaitsPicture`: the picture's URL is still being looked up (a second
/// service behind the member's id). The face then holds the avatar's
/// skeleton, never the initials (`AvatarView.awaitPicture`, #1750).
public nonisolated struct GroupAvatarFace: Equatable, Hashable, Sendable {
    public let name: String
    public let avatarURL: URL?
    public let awaitsPicture: Bool

    public init(name: String, avatarURL: URL?, awaitsPicture: Bool = false) {
        self.name = name
        self.avatarURL = avatarURL
        self.awaitsPicture = awaitsPicture
    }

    /// The initials a face without a picture shows: the app's one rule.
    public var monogram: String { MonogramAvatarView.monogram(name: name, handle: "") }

    /// The first word of the name, as VoiceOver says the group.
    var firstName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }
}

/// What a group's picture is made of (#2233): its own photo, its members'
/// faces, its name — the ONE value every surface that draws a group hands
/// `GroupAvatarView`: the inbox and invitation rows, the thread's pill, the
/// info screen's header, the name step at creation.
///
/// The faces are the OTHER members, the viewer excluded (as Messages and
/// WhatsApp draw a group), in a STABLE order the data plane decides — the
/// owner first, then by join date — never by last message, or the picture
/// would change with every message.
public nonisolated struct GroupAvatarContent: Equatable, Sendable {
    /// The group's name: its initials when nothing else is known, and what
    /// VoiceOver says of a group with a photo.
    public let name: String
    public let photoURL: URL?
    /// The other members' faces, at most `GroupAvatarLayout.maximumFaces`.
    public let faces: [GroupAvatarFace]
    /// Everyone in the group, the viewer included; 0 when not known (the
    /// faces then count for it).
    public let memberCount: Int

    public init(name: String, photoURL: URL? = nil, faces: [GroupAvatarFace] = [], memberCount: Int = 0) {
        self.name = name
        self.photoURL = photoURL
        self.faces = Array(faces.prefix(GroupAvatarLayout.maximumFaces))
        self.memberCount = memberCount
    }

    /// What the picture draws, in order (#2233):
    /// 1. the group's photo, when it has one;
    /// 2. otherwise its members' faces, stacked — the fourth place a "+N"
    ///    past four other members;
    /// 3. otherwise its initials (no face known yet).
    public enum Drawing: Equatable, Sendable {
        case photo(URL)
        /// `more`: the members not drawn — zero for none.
        case stack([GroupAvatarFace], more: Int)
        case initials(String)
    }

    public var drawing: Drawing {
        if let photoURL { return .photo(photoURL) }
        guard !faces.isEmpty else { return .initials(monogram) }
        let maximum = GroupAvatarLayout.maximumFaces
        guard otherMemberCount > maximum else { return .stack(faces, more: 0) }
        // ⚠️ "+N" COUNTS EVERY MEMBER NOT DRAWN, THE VIEWER INCLUDED (the
        // issue's own example: a group of 40 shows three faces and "+37").
        // The faces and the figure add up to the group's size, which is what
        // a large group should read as at a glance.
        let shown = Array(faces.prefix(maximum - 1))
        return .stack(shown, more: max(0, groupSize - shown.count))
    }

    /// The group's initials, by the app's one rule.
    public var monogram: String { MonogramAvatarView.monogram(name: name, handle: "") }

    /// The other members, as counted: the member count less the viewer, or
    /// the faces when the count is not known.
    var otherMemberCount: Int { max(memberCount - 1, faces.count) }

    /// Everyone, the viewer included.
    var groupSize: Int { max(memberCount, faces.count + 1) }

    /// What VoiceOver says (#2233): one element, "Group: Sofía, Tom and 2
    /// others" — the faces are never elements of their own. A group drawn
    /// from its photo or its initials says its name.
    public var spokenLabel: String {
        let names = faces.map(\.firstName).filter { !$0.isEmpty }
        guard photoURL == nil, !names.isEmpty else { return "Group: \(name)" }
        let total = max(otherMemberCount, names.count)
        let listed: String
        switch (names.count, total) {
        case (1, 1): listed = names[0]
        case (2, 2): listed = "\(names[0]) and \(names[1])"
        case (3, 3): listed = "\(names[0]), \(names[1]) and \(names[2])"
        case (1, _):
            let others = total - 1
            listed = "\(names[0]) and \(others) \(others == 1 ? "other" : "others")"
        default:
            let others = total - 2
            listed = "\(names[0]), \(names[1]) and \(others) \(others == 1 ? "other" : "others")"
        }
        return "Group: \(listed)"
    }
}

/// Where each face of a group's stack sits (#2233), and the cut between
/// them.
///
/// ⚠️ PLACED BY HAND, NOT A GRID: one main face larger, the others smaller,
/// slightly offset — each count's set written out as fractions of the disc
/// (centre x, centre y, radius, of a side of 100). The issue's starting
/// point, to be tuned on a device. The first face is at the back, the last
/// in front; right-to-left mirrors the set.
public nonisolated enum GroupAvatarLayout {
    /// The most faces a stack draws; past four other members the fourth
    /// place is the "+N".
    public static let maximumFaces = 4

    /// ⚠️ THE GAP BETWEEN FACES, IN POINTS, AT EVERY SIZE (#2233): about
    /// 2 pt at the row's 48 pt. A fraction of the disc would vanish on the
    /// pill's 36 pt and gape on the info screen's 96 pt.
    public static let gap: CGFloat = 2

    /// (centre x, centre y, radius) per face, of a side of 100.
    static func unitDiscs(count: Int) -> [(x: CGFloat, y: CGFloat, r: CGFloat)] {
        switch count {
        case ...0: []
        case 1: [(50, 50, 50)]
        case 2: [(36, 36, 30), (70, 68, 24)]
        case 3: [(38, 40, 28), (74, 30, 20), (62, 74, 20)]
        default: [(34, 36, 24), (70, 30, 20), (32, 72, 18), (67, 67, 22)]
        }
    }

    /// Each face's frame in a disc of `side`, back to front, in half points
    /// so no face lands between pixels.
    public static func frames(count: Int, side: CGFloat, rightToLeft: Bool) -> [CGRect] {
        unitDiscs(count: min(count, maximumFaces)).map { disc in
            let centreX = (rightToLeft ? 100 - disc.x : disc.x) / 100 * side
            let centreY = disc.y / 100 * side
            let diameter = halfPoint(2 * disc.r / 100 * side)
            return CGRect(
                x: halfPoint(centreX - diameter / 2), y: halfPoint(centreY - diameter / 2),
                width: diameter, height: diameter
            )
        }
    }

    /// ⚠️ A REAL CUT, NOT A RING (#2233): face `index`'s mask, in its own
    /// space — its disc less every face in front of it, each grown by `gap`.
    /// Whatever lies behind shows through the gap (glass, a tinted or
    /// selected row, a photo); a ring of the background colour showed as a
    /// ring on anything but the plain background. A UNION of the front
    /// discs is taken out, never an even-odd fill: two front faces that
    /// overlap each other would put their shared lens back.
    public static func maskPath(index: Int, frames: [CGRect], gap: CGFloat = gap) -> CGPath {
        guard frames.indices.contains(index) else { return CGMutablePath() }
        let own = frames[index]
        var path = CGPath(ellipseIn: CGRect(origin: .zero, size: own.size), transform: nil)
        for front in frames.dropFirst(index + 1) {
            let cut = front.offsetBy(dx: -own.minX, dy: -own.minY).insetBy(dx: -gap, dy: -gap)
            path = path.subtracting(CGPath(ellipseIn: cut, transform: nil))
        }
        return path
    }

    private static func halfPoint(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
}

/// A group's picture (#2233): its photo, its members' faces stacked and cut
/// apart — up to four, "+N" beyond — or its initials. The ONE component
/// every surface draws a group with, beside the person avatar it is built
/// from; Chat and Feed (the thread's pill) both reach it here.
///
/// Every face is the app's avatar (`AvatarView`): it loads, holds its
/// skeleton and dissolves in like every face, on the avatar's fixed light
/// ground with its initials as a layer bitmap (#2051) — nothing here draws
/// an avatar's parts by hand. The "+N" is an avatar too, initials alone on
/// the quiet ground (`MonogramAvatarView.plateColor`): never given a picture,
/// its plate never turns the final initials' grey.
///
/// It sizes itself from its bounds (a square; the stack centres in a
/// rectangle) and is one accessibility element, "Group: Sofía, Tom and 2
/// others" — a host that speaks for it (a row, the pill) turns that off.
@MainActor
public final class GroupAvatarView: UIView {
    /// The side it asks for, when its host lets it size itself.
    public let diameter: CGFloat
    private let size: ImageBucket
    /// The photo, or the initials: one disc, the whole side.
    private let single: AvatarView
    /// The stack's faces, kept across changes: a member added moves the
    /// faces already drawn without reloading them (no flash, #2233).
    private var faceViews: [AvatarView] = []
    /// What each face view was last given, so a change elsewhere in the
    /// stack leaves it alone (an awaited picture keeps its skeleton's clock).
    private var appliedFaces: [GroupAvatarFace?] = []
    /// The "+N", in the fourth place; made the first time a group needs it.
    private var moreView: AvatarView?
    /// The cut on each stacked view, by identity.
    private var masks: [ObjectIdentifier: CAShapeLayer] = [:]

    /// What is drawn now.
    public private(set) var content: GroupAvatarContent?
    private var drawing: GroupAvatarContent.Drawing?

    /// - Parameters:
    ///   - diameter: the side it asks for (`intrinsicContentSize`).
    ///   - size: the bucket every face and the photo are decoded at.
    public init(diameter: CGFloat = MonogramAvatarView.rowDiameter, size: ImageBucket = .avatar) {
        self.diameter = diameter
        self.size = size
        single = AvatarView(diameter: diameter, size: size)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .image
        single.isHidden = true
        addSubview(single)
        registerForTraitChanges([UITraitLayoutDirection.self]) { (view: GroupAvatarView, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

    /// Draws `content` — nil for nothing (a recycled row). The same content
    /// again changes nothing; a change of faces keeps the faces already
    /// drawn. A change of what is drawn (faces to the photo) cross-fades on
    /// screen, never cutting from one to the other.
    public func setContent(_ content: GroupAvatarContent?, pipeline: ImagePipeline?) {
        guard content != self.content else { return }
        self.content = content
        let next = content?.drawing
        let fades = window != nil && drawing != nil && next != nil && Self.kind(of: next) != Self.kind(of: drawing)
        drawing = next
        accessibilityLabel = content?.spokenLabel
        let draw: () -> Void = { self.apply(next, monogram: content?.monogram ?? "", pipeline: pipeline) }
        if fades {
            UIView.transition(with: self, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: draw)
        } else {
            draw()
        }
    }

    private enum Kind { case photo, stack, initials }

    private static func kind(of drawing: GroupAvatarContent.Drawing?) -> Kind? {
        switch drawing {
        case .photo?: .photo
        case .stack?: .stack
        case .initials?: .initials
        case nil: nil
        }
    }

    private func apply(_ drawing: GroupAvatarContent.Drawing?, monogram: String, pipeline: ImagePipeline?) {
        switch drawing {
        case .photo(let url)?:
            showSingle(monogram: monogram, url: url, pipeline: pipeline)
            showStack([], more: 0, pipeline: nil)
        case .initials(let initials)?:
            showSingle(monogram: initials, url: nil, pipeline: nil)
            showStack([], more: 0, pipeline: nil)
        case .stack(let faces, let more)?:
            hideSingle()
            showStack(faces, more: more, pipeline: pipeline)
        case nil:
            hideSingle()
            showStack([], more: 0, pipeline: nil)
        }
        setNeedsLayout()
    }

    private func showSingle(monogram: String, url: URL?, pipeline: ImagePipeline?) {
        single.isHidden = false
        single.setMonogram(monogram)
        single.setPicture(url, pipeline: pipeline)
    }

    private func hideSingle() {
        single.isHidden = true
        single.setPicture(nil, pipeline: nil)
    }

    private func showStack(_ faces: [GroupAvatarFace], more: Int, pipeline: ImagePipeline?) {
        let limit: Int = more > 0 ? GroupAvatarLayout.maximumFaces - 1 : GroupAvatarLayout.maximumFaces
        let shown: [GroupAvatarFace] = Array(faces.prefix(limit))
        while faceViews.count < shown.count {
            faceViews.append(makeFaceView())
            appliedFaces.append(nil)
        }
        for (index, view) in faceViews.enumerated() {
            guard index < shown.count else {
                view.isHidden = true
                if appliedFaces[index] != nil {
                    view.setPicture(nil, pipeline: nil)
                    appliedFaces[index] = nil
                }
                continue
            }
            let face = shown[index]
            view.isHidden = false
            guard appliedFaces[index] != face else { continue }
            appliedFaces[index] = face
            view.setMonogram(face.monogram)
            if face.awaitsPicture {
                view.awaitPicture()
            } else {
                view.setPicture(face.avatarURL, pipeline: pipeline)
            }
        }
        if more > 0 {
            let view = moreView ?? makeFaceView()
            moreView = view
            view.isHidden = false
            view.setMonogram("+\(more)")
        } else {
            moreView?.isHidden = true
        }
    }

    /// A face of the stack: the app's avatar, cut by the faces in front of
    /// it through a mask of its own.
    private func makeFaceView() -> AvatarView {
        let view = AvatarView(diameter: diameter, size: size)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        let mask = CAShapeLayer()
        masks[ObjectIdentifier(view)] = mask
        view.layer.mask = mask
        addSubview(view)
        return view
    }

    /// The stacked views on show, back to front: the faces, then the "+N".
    private var stackedViews: [AvatarView] {
        var views = faceViews.filter { !$0.isHidden }
        if let moreView, !moreView.isHidden { views.append(moreView) }
        return views
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let origin = CGPoint(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
        single.setDiameter(side)
        single.frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let views = stackedViews
        let frames = GroupAvatarLayout.frames(
            count: views.count, side: side, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, view) in views.enumerated() where index < frames.count {
            let frame = frames[index]
            view.setDiameter(frame.width)
            view.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
            if let mask = masks[ObjectIdentifier(view)] {
                mask.frame = CGRect(origin: .zero, size: frame.size)
                mask.path = GroupAvatarLayout.maskPath(index: index, frames: frames)
            }
        }
        CATransaction.commit()
    }

    // MARK: - Tests

    /// How many members' faces are drawn (the "+N" apart). Tests.
    public var drawnFaceCount: Int { faceViews.filter { !$0.isHidden }.count }

    /// The "+N" drawn, nil for none. Tests.
    public var drawnMore: Int? {
        if case .stack(_, let more)? = drawing, more > 0 { return more }
        return nil
    }

    /// Whether one disc is drawn — the photo or the initials. Tests.
    public var drawsSingleDisc: Bool { !single.isHidden }

    /// The stacked views' frames, back to front, in the view's space. Tests.
    public var stackFrames: [CGRect] {
        layoutIfNeeded()
        return stackedViews.map(\.frame)
    }

    /// Whether the stacked view at `index` (back to front) lets `point`, in
    /// the group view's space, show through its cut. Tests.
    public func stackShows(at point: CGPoint, index: Int) -> Bool {
        layoutIfNeeded()
        let views = stackedViews
        guard views.indices.contains(index) else { return false }
        let view = views[index]
        guard let path = masks[ObjectIdentifier(view)]?.path else { return true }
        return path.contains(CGPoint(x: point.x - view.frame.minX, y: point.y - view.frame.minY))
    }

    /// Whether anything but the faces themselves is drawn round them — a
    /// ring, a border: never (#2233, a cut). Tests.
    public var drawsRings: Bool {
        (faceViews + [single]).contains { $0.layer.borderWidth > 0 }
    }
}
