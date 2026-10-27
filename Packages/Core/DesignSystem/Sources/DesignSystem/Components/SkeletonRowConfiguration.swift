import UIKit

/// The one list-row skeleton (#1769): the row it stands for, redacted. A list
/// cell wears it while its section loads —
/// `cell.contentConfiguration = SkeletonRowConfiguration(redacting: …)` — in
/// place of a "Loading…" line or a row of hand-placed bones.
///
/// It is handed the SAME list content configuration the real row will wear —
/// a sample title, a sample subtitle, the symbol — renders it with clear ink,
/// and lays a shimmering bone over each of its parts through
/// `UIListContentView`'s layout guides. So the skeleton's heights, insets and
/// Dynamic Type sizing are the real row's by construction, not by copied
/// constants: when the content cross-fades in (`crossfadeSkeleton(swapping:)`),
/// nothing moves. The sample strings only decide how wide each bone is.
///
/// Settings (title, title + subtitle, title + value with `valueCell()`),
/// Account, Edit Profile and the wallet's history all draw their loading rows
/// through it.
public struct SkeletonRowConfiguration: UIContentConfiguration {
    public var content: UIListContentConfiguration
    /// A bone at the row's trailing edge where an accessory will stand — an
    /// amount, a count — this wide; nil for none.
    public var trailingBoneWidth: CGFloat?

    /// A row shaped like `content`: a title (and a subtitle, an image) whose
    /// sample text sets each bone's width. The image bone takes the image's
    /// corner radius (`imageProperties.cornerRadius`), a symbol's otherwise.
    public init(redacting content: UIListContentConfiguration, trailingBoneWidth: CGFloat? = nil) {
        self.content = content
        self.trailingBoneWidth = trailingBoneWidth
    }

    /// A plain one-line row of `sample`'s width.
    public init(sample: String, secondary: String? = nil) {
        var content = UIListContentConfiguration.cell()
        content.text = sample
        content.secondaryText = secondary
        self.init(redacting: content)
    }

    public func makeContentView() -> any UIView & UIContentView {
        SkeletonRowContentView(configuration: self)
    }

    public func updated(for state: any UIConfigurationState) -> SkeletonRowConfiguration { self }
}

private final class SkeletonRowContentView: UIView, UIContentView {
    private let listView = UIListContentView(configuration: .cell())
    private var imageBone = SkeletonBoneView(rounding: .fixed(SkeletonRowContentView.symbolCorner))
    private var imageCorner = SkeletonRowContentView.symbolCorner
    private let textBone = SkeletonBoneView(rounding: .capsule)
    private let secondaryBone = SkeletonBoneView(rounding: .capsule)
    private let trailingBone = SkeletonBoneView(rounding: .capsule)
    private var boneConstraints: [NSLayoutConstraint] = []

    /// A symbol's bone: a rounded square, not a disc.
    private static let symbolCorner: CGFloat = 6

    var configuration: any UIContentConfiguration {
        didSet { apply() }
    }

    init(configuration: SkeletonRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        listView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listView)
        for bone in [imageBone, textBone, secondaryBone, trailingBone] {
            bone.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bone)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Loading"
        accessibilityTraits = .updatesFrequently
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func apply() {
        guard let configuration = configuration as? SkeletonRowConfiguration else { return }
        let content = configuration.content
        var ink = content
        ink.textProperties.color = .clear
        ink.secondaryTextProperties.color = .clear
        ink.imageProperties.tintColor = .clear
        listView.configuration = ink

        // The bone's rounding is fixed at its making: a thumbnail's corner
        // (a stake row) is a new bone.
        let corner = content.imageProperties.cornerRadius > 0 ? content.imageProperties.cornerRadius : Self.symbolCorner
        if imageCorner != corner {
            imageCorner = corner
            imageBone.removeFromSuperview()
            imageBone = SkeletonBoneView(rounding: .fixed(corner))
            imageBone.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageBone)
        }

        NSLayoutConstraint.deactivate(boneConstraints)
        boneConstraints = [
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
        ]
        if let width = configuration.trailingBoneWidth {
            trailingBone.isHidden = false
            boneConstraints += [
                trailingBone.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -content.directionalLayoutMargins.trailing
                ),
                trailingBone.centerYAnchor.constraint(equalTo: centerYAnchor),
                trailingBone.widthAnchor.constraint(equalToConstant: width),
                trailingBone.heightAnchor.constraint(equalToConstant: 12),
                listView.trailingAnchor.constraint(equalTo: trailingBone.leadingAnchor, constant: -Spacing.sm),
            ]
        } else {
            trailingBone.isHidden = true
            boneConstraints.append(listView.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        place(imageBone, over: content.image == nil ? nil : listView.imageLayoutGuide, filling: true)
        place(textBone, over: content.text == nil ? nil : listView.textLayoutGuide, filling: false)
        place(secondaryBone, over: content.secondaryText == nil ? nil : listView.secondaryTextLayoutGuide, filling: false)
        NSLayoutConstraint.activate(boneConstraints)
    }

    /// A text bone spans its line's width at most of its height (a line box
    /// carries leading the glyphs don't fill); the image bone fills its slot.
    private func place(_ bone: SkeletonBoneView, over guide: UILayoutGuide?, filling: Bool) {
        guard let guide else {
            bone.isHidden = true
            return
        }
        bone.isHidden = false
        boneConstraints += [
            bone.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            bone.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            bone.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            bone.heightAnchor.constraint(equalTo: guide.heightAnchor, multiplier: filling ? 1 : 0.6)
        ]
    }
}
