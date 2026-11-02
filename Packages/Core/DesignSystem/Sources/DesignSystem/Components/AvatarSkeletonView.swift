import UIKit

/// An avatar's skeleton (#1750): one shimmering bone cut to the avatar's
/// `shape` — a disc, or the rounded tile — shown while a face that exists is
/// still on its way (`AvatarView`'s skeleton rung). The bone is the shared
/// `SkeletonBoneView`, so it sweeps in phase with every other bone on screen
/// and rests still when decoration does.
public final class AvatarSkeletonView: UIView {
    /// ⚠️ THE AVATAR'S GROUND, NOT THE SKELETON'S (#2051): the bone wears
    /// `Surface.avatarGround`, the plate's own fixed light grey, so two greys
    /// never meet under a loading face (#1771's rule, kept for avatars).
    private let bone = SkeletonBoneView(rounding: .fixed(0), fill: Surface.avatarGround)

    /// The bone's ground as drawn now. Tests.
    public var drawnGround: CGColor? { bone.drawnGround }

    /// The outline, the avatar's own.
    public var shape: AvatarShape = .circle {
        didSet {
            guard shape != oldValue else { return }
            setNeedsLayout()
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // Its sweep too: the light appearance's band, on any chrome, so a
        // dark trait never lays the dark band over the light ground.
        bone.overrideUserInterfaceStyle = .light
        bone.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bone)
        NSLayoutConstraint.activate([
            bone.leadingAnchor.constraint(equalTo: leadingAnchor),
            bone.trailingAnchor.constraint(equalTo: trailingAnchor),
            bone.topAnchor.constraint(equalTo: topAnchor),
            bone.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        AvatarShapeMask.apply(shape, to: self)
    }

    /// Hidden with its bone, so the bone's sweep stops too (a hidden bone
    /// runs none — `SkeletonBoneView.isHidden`).
    public override var isHidden: Bool {
        didSet { bone.isHidden = isHidden }
    }

    #if DEBUG
    /// Whether the bone's band is sweeping now — for tests.
    public var debugIsSweeping: Bool { bone.isSweeping }
    #endif
}
