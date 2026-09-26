import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// One video made with the sound: its poster, and a mark on the one the
/// viewer came from.
final class SoundSheetTileCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let currentBadge = UILabel()
    private let captionLabel = UILabel()
    private var loading: Task<Void, Never>?
    private var postID: PostID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        // A text post has no picture: its words are its tile.
        captionLabel.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 5
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(captionLabel)
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.sm),
            captionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.sm),
            captionLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

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
        captionLabel.text = tile.thumbnailURL == nil ? tile.caption : nil
        guard let url = tile.thumbnailURL else { return }
        let id = tile.postID
        loading = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.postID == id else { return }
            self.imageView.image = image
        }
    }
}
