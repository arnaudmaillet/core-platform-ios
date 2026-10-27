import DesignSystem
import UIKit

/// THE MEDIA SLOT (#1505): one remote picture on the loading ladder, with its
/// skeleton — the media's contract, which every view showing a picture wears
/// rather than writing its own (the owner, 2026-10-27: "an avatar HAS a
/// media; so has a banner").
///
/// ```
///   in memory      → drawn in the configure pass, no bone
///   not in memory  → nothing for `skeletonDelay`, then the bone (held at
///                    least `skeletonMinimum`), then the picture's arrival
///   failed / none  → no bone; the host's floor (initials, a flat grey)
/// ```
///
/// The slot owns the state — the ladder, the load, the bone registered as
/// the skeleton rung, the current item's token — and never the picture's
/// view: the host draws what arrives (`load`'s `arrive`), so each keeps only
/// its decoration on top:
/// - `AvatarView`: the initials floor, the stand-in, the animated still, the
///   frame;
/// - `HeroBannerView`: the focal cut, the baked blur, the ramp, the video;
/// - `CoverSlot`: a hero source's cover, whose view the ladder never
///   touches, and the parked frame;
/// - `ImageContentView`: a plain picture.
///
/// Two rules every host shares:
/// - **A bone already up stays up** across a new item (a recycled cell, a
///   redaction handing over to the load): no second delay, no flash.
/// - **A picture that may exist and is not known yet** (`awaitPicture`): the
///   bone holds its place, and the next `begin` answers it on the same item.
@MainActor
public final class MediaSlot {
    /// The ladder the picture arrives on.
    public let ladder: LoadingLadder
    /// The skeleton rung's view: a `SkeletonBoneView`, or a shaped wrapper of
    /// one (`AvatarSkeletonView`). The host lays it out under the picture.
    public let bone: UIView
    private let load: ImageLoadSlot
    /// The current item's token.
    public private(set) var token: LoadingLadder.Token
    /// Waiting for a picture's URL (`awaitPicture`).
    public private(set) var isAwaiting = false

    /// - Parameters:
    ///   - size: the bucket the picture is decoded at — required (#894).
    ///   - bone: the skeleton the host lays out under its picture.
    public init(
        size: ImageBucket, bone: UIView,
        policy: LoadingLadder.Policy = .standard, clock: LoadingLadder.Clock = .system
    ) {
        load = ImageLoadSlot(size: size)
        self.bone = bone
        bone.isUserInteractionEnabled = false
        ladder = LoadingLadder(policy: policy, clock: clock)
        ladder.setView(bone, for: .skeleton)
        token = ladder.currentToken
    }

    /// The bucket the next picture is decoded at — a host following Dynamic
    /// Type restates it.
    public var size: ImageBucket {
        get { load.size }
        set { load.size = newValue }
    }

    /// The URL loading or loaded; nil after a cancel.
    public var url: URL? { load.url }

    /// Whether a load is in flight.
    public var isLoading: Bool { load.isLoading }

    /// Whether the bone is on screen now.
    public var showsBone: Bool { !bone.isHidden && bone.alpha > 0 }

    /// A new item: a cut, the load in flight dropped — unless the slot was
    /// awaiting a picture, whose item this answers (its bone kept, its delay
    /// not started again). A bone already up stays up.
    @discardableResult
    public func begin(_ item: AnyHashable?) -> LoadingLadder.Token {
        if isAwaiting {
            isAwaiting = false
            return token
        }
        let boneShowing = item != nil && showsBone
        load.cancel()
        token = ladder.begin(item: item)
        if boneShowing { ladder.show(.skeleton, token: token, warm: true) }
        return token
    }

    /// A picture that may exist and whose URL is not known yet (a second
    /// service, posts on their way): the bone holds its place. A reconfigure
    /// while waiting keeps the same item.
    public func awaitPicture() {
        guard !isAwaiting else { return }
        begin(UUID())
        isAwaiting = true
    }

    /// Loads `url` for the current item: `arrive` gets the picture and how it
    /// comes in (`.none` for a warm hit, drawn in this pass), `failed` a
    /// missing or broken one — after the ladder has failed, so no bone
    /// follows. A late answer for an older item lands nowhere.
    public func load(
        _ url: URL?, using pipeline: ImagePipeline?,
        arrive: @escaping @MainActor (UIImage, LoadingLadder.Transition) -> Void,
        failed: (@MainActor () -> Void)? = nil
    ) {
        let token = token
        load.load(url, using: pipeline) { [weak self] image, transition in
            guard let self, ladder.isCurrent(token) else { return }
            arrive(image, transition)
        } failed: { [weak self] in
            guard let self, ladder.isCurrent(token) else { return }
            ladder.fail(token: token)
            failed?()
        }
    }

    /// Drops the load in flight (and any wait); its answer lands nowhere.
    public func cancel() {
        isAwaiting = false
        load.cancel()
    }
}
