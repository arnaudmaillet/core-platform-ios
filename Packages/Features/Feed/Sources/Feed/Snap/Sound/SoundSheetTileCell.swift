import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// One video made with the sound: its poster, and a mark on the one the
/// viewer came from.
final class SoundSheetTileCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let currentBadge = UILabel()
    private var loading: Task<Void, Never>?
    private var postID: PostID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .tertiarySystemFill
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        currentBadge.text = "Watching"
        currentBadge.font = .preferredFont(forTextStyle: .caption2).withWeight(.semibold)
        currentBadge.textColor = .white
        currentBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        currentBadge.textAlignment = .center
        currentBadge.layer.cornerRadius = 9
        currentBadge.clipsToBounds = true
        currentBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(currentBadge)
        NSLayoutConstraint.activate([
            currentBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.xs + 2),
            currentBadge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.xs + 2),
            currentBadge.heightAnchor.constraint(equalToConstant: 18),
            currentBadge.widthAnchor.constraint(
                equalToConstant: currentBadge.intrinsicContentSize.width + Spacing.md
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        imageView.image = nil
    }

    func configure(_ tile: SoundSheetViewController.Tile, pipeline: ImagePipeline) {
        postID = tile.postID
        currentBadge.isHidden = !tile.isCurrent
        accessibilityLabel = tile.isCurrent ? "This video" : "Video"
        isAccessibilityElement = true
        accessibilityTraits = .button
        loading?.cancel()
        guard let url = tile.thumbnailURL else { return }
        let id = tile.postID
        loading = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.postID == id else { return }
            self.imageView.image = image
        }
    }
}
