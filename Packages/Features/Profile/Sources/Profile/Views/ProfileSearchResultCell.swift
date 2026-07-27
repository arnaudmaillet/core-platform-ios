import DesignSystem
import MediaCore
import UIKit

/// One row in the share sheet's search results: avatar, display name, handle.
///
/// Built on `UICollectionViewListCell`'s own content configuration rather than
/// a hand-laid-out cell — the two-line-with-leading-image shape is exactly
/// what the system's list content gives, including its Dynamic Type behaviour
/// and its separator inset, and hand-rolling it would only be a slower way to
/// arrive at the same row.
final class ProfileSearchResultCell: UICollectionViewListCell {
    static let avatarSize = CGSize(width: 40, height: 40)

    private var avatarTask: Task<Void, Never>?
    private var target: ProfileShareTarget?

    func configure(with target: ProfileShareTarget, imagePipeline: ImagePipeline?) {
        self.target = target
        avatarTask?.cancel()

        // Cleared, so the sheet's glass runs behind the list. A list cell's
        // default background is opaque and painted a flat white block over the
        // material — the rows read as a different surface bolted into the
        // sheet rather than as content on it.
        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = .clear
        backgroundConfiguration = background

        apply(target: target, avatar: nil)
        guard let url = target.avatarURL, let imagePipeline else { return }
        avatarTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url) else { return }
            // The id check, not just cancellation: a recycled cell can be
            // reconfigured for someone else before its task is cancelled, and
            // the wrong face on the right name is worse than no face.
            guard let self, !Task.isCancelled, self.target == target else { return }
            self.apply(target: target, avatar: image)
        }
    }

    private func apply(target: ProfileShareTarget, avatar: UIImage?) {
        var content = defaultContentConfiguration()
        content.text = target.displayName
        // The handle without its `@`: the sigil is decoration here, and the
        // row already reads as a person.
        content.secondaryText = target.handle
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = avatar ?? Self.placeholder
        content.imageProperties.maximumSize = Self.avatarSize
        content.imageProperties.reservedLayoutSize = Self.avatarSize
        content.imageProperties.cornerRadius = Self.avatarSize.width / 2
        contentConfiguration = content
    }

    /// A neutral disc, so a row without an avatar keeps the same silhouette as
    /// one with it and the list doesn't jitter as images arrive.
    private static let placeholder: UIImage = {
        let size = avatarSize
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.tertiarySystemFill.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }()

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarTask?.cancel()
        avatarTask = nil
        target = nil
    }
}
