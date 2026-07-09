import MapKit
import UIKit

/// The bubble shown when MapKit collapses overlapping / co-located pins. It
/// reports how many of the *returned* pins sit here — honest given the server's
/// Top-K thinning — and, in Step B, its tap opens a vertical snap feed seeded
/// with exactly those posts' ids (already held client-side, no extra round-trip).
final class MapClusterAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "MapClusterAnnotationView"

    private static let side: CGFloat = 44
    private let countLabel = UILabel()

    override var annotation: (any MKAnnotation)? {
        didSet { refreshCount() }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        centerOffset = .zero
        buildLayout()
        refreshCount()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        backgroundColor = .clear
        let circle = UIView(frame: bounds)
        circle.backgroundColor = .tintColor
        circle.layer.cornerRadius = Self.side / 2
        circle.layer.borderWidth = 2
        circle.layer.borderColor = UIColor.systemBackground.cgColor
        circle.isUserInteractionEnabled = false
        addSubview(circle)

        countLabel.frame = bounds
        countLabel.textAlignment = .center
        countLabel.textColor = .white
        countLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withSemibold()
        addSubview(countLabel)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    private func refreshCount() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let count = cluster.memberAnnotations.count
        countLabel.text = count > 99 ? "99+" : String(count)
    }
}

private extension UIFont {
    func withSemibold() -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
