import DesignSystem
import UIKit

/// THE app's avatar (#943, step 2 of #1085): a person's initials, then their
/// picture, on the loading ladder — one view where nineteen drew their own.
///
/// ```
///   placeholder: the initials (MonogramAvatarView) — a PERMANENT floor
///   content:     the picture (AvatarImageView), dissolved in over it
///   (overlay:    the avatar frame, later — #943 step 2)
/// ```
///
/// The avatar rendering contract, unchanged: **the initials are the rendered
/// state, the picture an enhancement that may never arrive.** No row waits on
/// a face. The picture is drawn OVER the initials, never swapped for them, so
/// there is no empty disc at any point; once it has landed the initials draw
/// nothing (`MonogramAvatarView.isCovered`), or a reshaped plate would show
/// around it as a rim.
///
/// The ladder's rules come with it: a warm picture in the configure pass, a
/// late one dissolved in, a recycled view never showing the previous person,
/// the size bucket required (#1086: an avatar is not a 1200 px decode).
@MainActor
public final class AvatarView: UIView {
    /// The initials: the floor.
    public let monogram: MonogramAvatarView
    /// The picture, addressable (the ladder's hook 1).
    public let picture = AvatarImageView()
    /// The ladder the avatar runs on.
    public let ladder: LoadingLadder
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
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.isUserInteractionEnabled = false
        addSubview(picture)
        picture.pin(to: monogram)
        ladder.setView(monogram, for: .placeholder, drivesAlpha: false, permanent: true)
        ladder.setView(picture, for: .content)
        ladder.onSettled = { [weak self] in
            guard let self else { return }
            // Covered once the picture has landed — after its dissolve, so
            // the initials stay opaque behind it while it fades (the fade law).
            monogram.isCovered = ladder.rung == .content && picture.image != nil
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
            picture.shape = newValue
        }
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

    /// The initials shown under (or instead of) the picture.
    public func setMonogram(_ text: String) {
        monogram.setMonogram(text)
    }

    /// Shows `url`'s picture over the initials: at once when the pipeline
    /// has it, else dissolved in when it lands. The same URL again is a
    /// reconfigure and changes nothing; another (or nil) is a new person and
    /// cuts back to the initials first.
    public func setPicture(_ url: URL?, pipeline: ImagePipeline?) {
        if let url, url == load.url, load.isLoading || ladder.rung == .content { return }
        if url == nil, load.url == nil, ladder.rung == .placeholder, picture.image == nil { return }
        let token = ladder.begin(item: url)
        self.token = token
        picture.image = nil
        monogram.isCovered = false
        ladder.show(.placeholder, token: token, warm: true)
        load.load(url, using: pipeline) { [weak self] image, transition in
            guard let self, ladder.isCurrent(token) else { return }
            picture.image = image
            ladder.show(.content, token: token, warm: transition == .none)
        } failed: { [weak self] in
            guard let self, ladder.isCurrent(token) else { return }
            ladder.fail(token: token)
        }
    }

    /// Back to the initials alone — a recycled row's first step.
    public func reset() {
        load.cancel()
        setPicture(nil, pipeline: nil)
    }

    /// The picture on show, nil while the initials are.
    public var shownPicture: UIImage? { ladder.rung == .content ? picture.image : nil }

    /// Whether the avatar has stopped changing: a picture landed, or none is
    /// coming — for a push that waits on its faces.
    public var isSettled: Bool { ladder.isSettled || (load.url == nil && !load.isLoading) }

    #if DEBUG
    public var debugIsLoading: Bool { load.isLoading }
    #endif
}
