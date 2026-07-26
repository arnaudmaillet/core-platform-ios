import LinkPresentation
import UIKit

/// Rasterizes a `ProfileQRCardView` into an image other apps can receive.
///
/// The shared image and the on-screen card are the SAME view, rendered — not
/// two drawing routines that have to be kept in step. When the card's layout
/// changes, what people receive changes with it, for free.
enum ProfileShareCard {
    /// Renders `card` at `width`, sizing the height to its content.
    ///
    /// `layer.render(in:)` rather than `drawHierarchy(in:afterScreenUpdates:)`:
    /// the latter needs the view on screen to capture correctly, and this runs
    /// on a detached copy. That trade is only safe because the card is
    /// deliberately made of plain opaque views — a `UIVisualEffectView` would
    /// come out blank, which is one more reason the card isn't glass.
    @MainActor
    static func render(_ card: ProfileQRCardView, width: CGFloat, scale: CGFloat) -> UIImage {
        card.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let fitted = card.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        card.frame = CGRect(origin: .zero, size: fitted)
        // Twice on purpose: the first pass resolves the QR image view's width,
        // which is what `ProfileQRCardView` generates the code against — the
        // second pass draws with that code in place. One pass renders a card
        // with an empty centre.
        card.layoutIfNeeded()
        card.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: fitted, format: format).image { context in
            card.layer.render(in: context.cgContext)
        }
    }
}

/// Supplies the profile link to `UIActivityViewController`, plus the metadata
/// that makes the system sheet's header show *whose* profile is being shared
/// rather than a bare URL.
///
/// Without `activityViewControllerLinkMetadata` the share sheet falls back to
/// fetching the link's own preview — which, for a link this app cannot yet
/// serve (see the universal-link gap), means no header at all.
final class ProfileShareItemSource: NSObject, UIActivityItemSource {
    private let card: ProfileViewModel.ShareCard
    private let icon: UIImage?

    init(card: ProfileViewModel.ShareCard, icon: UIImage?) {
        self.card = card
        self.icon = icon
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        card.url
    }

    func activityViewController(
        _ controller: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        card.url
    }

    func activityViewController(
        _ controller: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        // Mail's subject line.
        "\(card.displayName) (\(card.handle))"
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = card.url
        metadata.url = card.url
        metadata.title = "\(card.displayName) · \(card.handle)"
        if let icon {
            metadata.iconProvider = NSItemProvider(object: icon)
        }
        return metadata
    }
}
