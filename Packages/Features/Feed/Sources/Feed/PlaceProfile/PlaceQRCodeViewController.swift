import DesignSystem
import UIKit

/// A place's QR code, opened from the bubble in its page's tray: the place's
/// name, its share link drawn as a scannable code (`QRCodeImage`, the
/// profile's own generator), the link in words, and a Share button handing
/// the link to the system's sheet.
///
/// The profile's bubble opens a richer card (`ProfileShareViewController`,
/// with its avatar punched into the code and share targets); a place has no
/// picture of its own to punch in, so this is the code alone.
final class PlaceQRCodeViewController: UIViewController {
    private let name: String
    private let url: URL
    /// The code's side, in points.
    static let codeSide: CGFloat = 220

    let codeView = UIImageView()

    init(name: String, url: URL) {
        self.name = name
        self.url = url
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Surface.page

        let title = UILabel()
        title.text = name
        title.font = .scaledFont(forTextStyle: .title3, weight: .semibold)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center

        // On white, whatever the appearance: a code scans dark on light.
        let card = UIView()
        card.backgroundColor = .white
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        codeView.image = QRCodeImage.makeImage(
            for: url, side: Self.codeSide, scale: traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        )
        codeView.accessibilityLabel = "QR code for \(name)"
        codeView.isAccessibilityElement = true
        codeView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(codeView)

        let link = UILabel()
        link.text = url.absoluteString
        link.font = .appFont(forTextStyle: .footnote)
        link.adjustsFontForContentSizeCategory = true
        link.textColor = .secondaryLabel
        link.textAlignment = .center

        var share = HeroTray.capsule(prominent: true)
        share.title = "Share"
        share.image = UIImage(systemName: "square.and.arrow.up")
        share.imagePadding = Spacing.xs
        let shareButton = UIButton(configuration: share, primaryAction: UIAction { [weak self] action in
            self?.share(from: action.sender as? UIView)
        })

        let stack = UIStackView(arrangedSubviews: [title, card, link, shareButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let inset: CGFloat = Spacing.lg
        NSLayoutConstraint.activate([
            codeView.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            codeView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            codeView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            codeView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            codeView.widthAnchor.constraint(equalToConstant: Self.codeSide),
            codeView.heightAnchor.constraint(equalToConstant: Self.codeSide),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.xl),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Spacing.lg),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Spacing.lg),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shareButton.heightAnchor.constraint(equalToConstant: HeroTray.bubbleSize),
        ])
    }

    private func share(from source: UIView?) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = source ?? view
        present(activity, animated: true)
    }
}
