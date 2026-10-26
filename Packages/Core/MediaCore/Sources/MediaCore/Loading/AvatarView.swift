import DesignSystem
import UIKit

/// THE app's avatar (#943, step 2 of #1085): a person's picture on the
/// loading ladder, their initials when there is none — one view where
/// nineteen drew their own.
///
/// ```
///   skeleton:    a bone in the avatar's shape (AvatarSkeletonView)
///   placeholder: the initials (MonogramAvatarView) — a PERMANENT floor
///   preview:     a smaller decode of the face standing in
///   content:     the picture (AvatarImageView), dissolved in
///   overlay:     the avatar frame (`frameID`, #943) — a ring on the rim
/// ```
///
/// The avatar rendering contract (#1505, the owner's option A; #1750):
/// - **An account WITH a picture shows its picture**: in the configure pass
///   when the pipeline holds it; else nothing for `skeletonDelay`, then the
///   skeleton (held at least `skeletonMinimum`), then the picture dissolved
///   in. Never the initials first: a stand-in that then changes reads as two
///   avatars (the owner's recording, 2026-10-21: AM, KT, LK, SR, then faces).
/// - **The initials are for an account with NO picture, or whose picture
///   failed.** They are a permanent floor: the picture would be drawn over
///   them, and once it has landed they draw nothing
///   (`MonogramAvatarView.isCovered`), or a reshaped plate would show around
///   it as a rim.
/// No row waits on a face: the skeleton holds the face's place.
///
/// The ladder's rules come with it: a warm picture in the configure pass, a
/// late one dissolved in, a recycled view never showing the previous person,
/// the size bucket required (#1086: an avatar is not a 1200 px decode).
@MainActor
public final class AvatarView: UIView {
    /// The initials: the floor.
    public let monogram: MonogramAvatarView
    /// The bone shown while a face that exists is on its way.
    public let skeleton = AvatarSkeletonView()
    /// The picture, addressable (the ladder's hook 1).
    public let picture = AvatarImageView()
    /// A smaller decode of the same face standing in while the sharp one
    /// decodes (`standInSize`): the preview rung.
    public let standIn = AvatarImageView()
    /// The ladder the avatar runs on.
    public let ladder: LoadingLadder
    /// The frame the profile wears (#943), over the face's rim.
    public let frameView = AvatarFrameView()
    private let load: ImageLoadSlot
    private var token: LoadingLadder.Token?

    /// - Parameters:
    ///   - diameter: the disc's side; `setDiameter` changes it later.
    ///   - size: the bucket the picture is decoded at — required; `.avatar`
    ///     for a row, larger for a header.
    public init(
        diameter: CGFloat = MonogramAvatarView.rowDiameter, size: ImageBucket,
        policy: LoadingLadder.Policy = .standard, clock: LoadingLadder.Clock = .system
    ) {
        monogram = MonogramAvatarView(diameter: diameter)
        ladder = LoadingLadder(policy: policy, clock: clock)
        load = ImageLoadSlot(size: size)
        super.init(frame: .zero)
        monogram.translatesAutoresizingMaskIntoConstraints = false
        addSubview(monogram)
        monogram.pin(to: self)
        for view in [skeleton, standIn, picture] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
            view.pin(to: monogram)
        }
        // The frame rides on top of the face (last in the disc), in its
        // bounds: it changes no size.
        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameView.pin(to: monogram)
        ladder.setView(skeleton, for: .skeleton)
        ladder.setView(monogram, for: .placeholder, drivesAlpha: false, permanent: true)
        ladder.setView(standIn, for: .preview)
        ladder.setView(picture, for: .content)
        ladder.onSettled = { [weak self] in
            guard let self else { return }
            // Covered once the picture has landed — after its dissolve, so
            // the initials stay opaque behind it while it fades (the fade law).
            monogram.isCovered = (ladder.rung == .content && picture.image != nil)
                || (ladder.rung == .preview && standIn.image != nil)
        }
        token = ladder.begin(item: nil)
        ladder.show(.placeholder, token: token!, warm: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The outline, for the initials and the picture alike.
    public var shape: AvatarShape {
        get { monogram.shape }
        set {
            monogram.shape = newValue
            skeleton.shape = newValue
            picture.shape = newValue
            frameView.shape = newValue
        }
    }

    /// The profile's `avatar_frame_id` (#943): the frame drawn over the
    /// face. Nil, empty or an id this build has no art for: none.
    public var frameID: String? {
        get { frameView.frameStyle?.rawValue }
        set { frameView.frameStyle = AvatarFrame(id: newValue) }
    }

    /// Resizes the disc, initials included.
    public func setDiameter(_ diameter: CGFloat) {
        monogram.setDiameter(diameter)
    }

    /// The bucket the picture is decoded at, for a disc that follows Dynamic
    /// Type: the next picture is decoded at it.
    public var pictureSize: ImageBucket {
        get { load.size }
        set { load.size = newValue }
    }

    /// A smaller bucket whose decode, when the pipeline already holds it,
    /// stands in for the face while `pictureSize` decodes — soft for a beat,
    /// never the initials (the profile header: the row that opened it drew
    /// the face at `.avatar`). Nil: none.
    public var standInSize: ImageBucket?

    /// Told when a picture that had to be fetched has landed or failed — not
    /// for a warm one, drawn in the configure pass.
    public var onSettledAfterLoad: (() -> Void)?

    /// The initials shown under (or instead of) the picture.
    public func setMonogram(_ text: String) {
        monogram.setMonogram(text)
    }

    /// Shows `url`'s picture: at once when the pipeline has it, else the
    /// skeleton, then the picture dissolved in when it lands; the initials
    /// when `url` is nil or the picture fails. The same URL again is a
    /// reconfigure and changes nothing; another (or nil) is a new person.
    public func setPicture(_ url: URL?, pipeline: ImagePipeline?) {
        // The answer to `awaitPicture`: the same item, its skeleton kept.
        let answersAwait = isAwaitingPicture
        isAwaitingPicture = false
        if !answersAwait {
            if let url, url == load.url, load.isLoading || ladder.rung == .content { return }
            if url == nil, load.url == nil, ladder.rung == .placeholder, picture.image == nil { return }
        }
        let token = answersAwait ? (self.token ?? ladder.begin(item: url)) : ladder.begin(item: url)
        self.token = token
        picture.image = nil
        standIn.image = nil
        monogram.isCovered = false
        // No picture: the initials, now. A picture: nothing yet — the
        // ladder brings the skeleton in if it is late.
        if url == nil { ladder.show(.placeholder, token: token, warm: true) }
        // After the new item has begun: a sheet already resolved hands its
        // still over now, as the picture (`adoptStill`). At the rung the
        // picture is decoded at: the profile header's 512 px picture takes
        // the 256 px sheet (#1444).
        animation.rung = AnimatedAvatars.Rung(bucket: load.size)
        animation.setAvatar(url)
        var warm = false
        load.load(url, using: pipeline) { [weak self] image, transition in
            guard let self, ladder.isCurrent(token) else { return }
            warm = transition == .none
            // An animated avatar's picture is its still, never the photo
            // under it (#1424).
            picture.image = animation.still ?? image
            ladder.show(.content, token: token, warm: warm)
            if !warm { onSettledAfterLoad?() }
        } failed: { [weak self] in
            guard let self, ladder.isCurrent(token) else { return }
            // The picture is not coming: the initials, without animation.
            ladder.show(.placeholder, token: token, warm: true)
            ladder.fail(token: token)
            if url != nil { onSettledAfterLoad?() }
        }
        // Missed at its size: a smaller decode already at hand stands in.
        // Never for a sheet avatar (#1444): its one picture is its sheet's
        // last frame, shown once the sheet is decoded — no stand-in to hand
        // over from.
        if !warm, load.isLoading, animation.still == nil, let url, !AnimatedAvatars.isSheet(url), let standInSize,
           let face = pipeline?.cachedImage(for: url, size: standInSize) {
            standIn.image = face
            ladder.show(.preview, token: token, warm: true)
            monogram.isCovered = true
        }
    }

    /// A person whose picture's URL is still being looked up (a second
    /// service — `profile.v1` behind a `chat.v1` row): they may well have a
    /// face, so the skeleton holds its place, never the initials (#1750).
    /// `setPicture` answers it on the same item — the URL loads under the
    /// bone already there, nil shows the initials.
    public func awaitPicture() {
        load.cancel()
        token = ladder.begin(item: UUID())
        picture.image = nil
        standIn.image = nil
        monogram.isCovered = false
        animation.setAvatar(nil)
        isAwaitingPicture = true
    }

    private var isAwaitingPicture = false

    /// Back to the initials alone — a recycled row's first step (the next
    /// configure, in the same pass, starts the new person).
    public func reset() {
        load.cancel()
        setPicture(nil, pipeline: nil)
    }

    /// An animated avatar's player over the picture (#1358): the sheet's
    /// last frame at rest, played once by the rule (`AnimatedAvatarPlayer`).
    /// A still avatar shows nothing of it.
    public private(set) lazy var animation: AnimatedAvatarPlayer = {
        let player = AnimatedAvatarPlayer.attach(to: picture)
        player.onStill = { [weak self] still in self?.adoptStill(still) }
        return player
    }()

    /// ⚠️ AN ANIMATED AVATAR'S PICTURE IS ITS STILL (#1424): its sheet's last
    /// frame, drawn as THE picture the moment it is known — at once for a
    /// sheet already resolved, before the photo, at any size, playing or not.
    /// Laid over a different photo, every hand-over between the two was a cut
    /// (the owner's recording, 2026-10-19: three pictures around one play).
    private func adoptStill(_ still: UIImage) {
        guard let token, ladder.isCurrent(token) else { return }
        picture.image = still
        ladder.show(.content, token: token, warm: true)
        monogram.isCovered = true
    }

    /// When this avatar plays: when the rounds pick it (the default), on its
    /// first display on a screen where it is large and alone, or when its
    /// person changes.
    public var animationTrigger: AnimatedAvatarPlayer.Trigger {
        get { animation.trigger }
        set { animation.trigger = newValue }
    }

    /// The picture on show, nil while the initials are — an animated
    /// avatar's still (its last frame), which is its picture.
    public var shownPicture: UIImage? {
        switch ladder.rung {
        case .content: return animation.still ?? picture.image
        case .preview: return standIn.image
        default: return nil
        }
    }

    /// Whether the avatar has stopped changing: a picture landed, or none is
    /// coming — for a push that waits on its faces.
    /// A stand-in counts: the face is drawn, the sharper one only refines it.
    public var isSettled: Bool {
        ladder.isSettled || ladder.rung == .preview || (load.url == nil && !load.isLoading)
    }

    #if DEBUG
    public var debugIsLoading: Bool { load.isLoading }
    #endif
}
