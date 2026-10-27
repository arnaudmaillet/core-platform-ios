import UIKit

/// An avatar's skeleton (#1750): one shimmering bone cut to the avatar's
/// `shape` — a disc, or the rounded tile — shown while a face that exists is
/// still on its way (`AvatarView`'s skeleton rung). The bone is the shared
/// `SkeletonBoneView`, so it sweeps in phase with every other bone on screen
/// and rests still when decoration does.
public final class AvatarSkeletonView: UIView {
    private let bone = SkeletonBoneView(rounding: .fixed(0))

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
