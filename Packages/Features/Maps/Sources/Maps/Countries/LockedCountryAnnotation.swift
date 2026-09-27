import DesignSystem
import MapKit
import UIKit

/// A country the account has not unlocked, standing at the country's centre
/// with what it would open: its rank among the world's countries and the
/// likes on its posts.
final class LockedCountryAnnotation: NSObject, MKAnnotation {
    let code: String
    let flag: String
    let standing: CountryStanding
    let coordinate: CLLocationCoordinate2D

    init(country: CountryAtlas.Country, standing: CountryStanding) {
        code = country.code
        flag = country.flag
        self.standing = standing
        coordinate = country.label
    }
}

/// The locked country's badge:
///
/// ```
///  ╭──────────────────────────╮
///  │ 🇪🇸  #4 · ♥ 12.4K   🔒   │
///  ╰──────────────────────────╯
/// ```
///
/// A compact capsule on the map's own material, the flag first so the
/// country reads before the numbers; the heart is red, the app's colour for
/// likes; the lock says what a tap will offer.
///
/// ⚠️ **BELOW THE POSTS, AND IT GIVES WAY — THE BUSIEST FIRST.**
/// `displayPriority` is under `.defaultLow` and the collision rectangle is the
/// capsule, so at a continent's zoom MapKit hides the badges that would
/// overlap instead of stacking them, and a post's marker always wins its
/// place. Among badges the priority follows the RANK: at one flat priority
/// MapKit kept Monaco and Vatican City and hid Germany, Spain and Italy.
final class LockedCountryAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "LockedCountryAnnotationView"

    /// A tap on the badge — the host offers the country.
    var onSelect: (() -> Void)?

    private let capsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let flagLabel = UILabel()
    private let rankLabel = UILabel()
    private let likesLabel = UILabel()
    private let lockView = UIImageView(image: UIImage(systemName: "lock.fill"))

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .defaultLow
        collisionMode = .rectangle
        canShowCallout = false

        capsule.clipsToBounds = true
        capsule.layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        flagLabel.font = .systemFont(ofSize: 17)
        rankLabel.font = .systemFont(ofSize: 13, weight: .bold)
        rankLabel.textColor = .label
        likesLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        likesLabel.textColor = .secondaryLabel
        lockView.tintColor = .secondaryLabel
        lockView.preferredSymbolConfiguration = .init(pointSize: 10, weight: .bold)

        let row = UIStackView(arrangedSubviews: [flagLabel, rankLabel, likesLabel, lockView])
        row.spacing = 5
        row.alignment = .center
        row.setCustomSpacing(8, after: likesLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(row)
        addSubview(capsule)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor, constant: -9),
            row.topAnchor.constraint(equalTo: capsule.contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor, constant: -4),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var annotation: (any MKAnnotation)? {
        didSet { configure() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onSelect = nil
    }

    private func configure() {
        guard let country = annotation as? LockedCountryAnnotation else { return }
        flagLabel.text = country.flag
        rankLabel.text = "#\(country.standing.rank)"
        displayPriority = MKFeatureDisplayPriority(rawValue: Float(max(10, 249 - country.standing.rank)))
        let likes = NSMutableAttributedString(
            attachment: NSTextAttachment(image: UIImage(systemName: "heart.fill")!
                .applyingSymbolConfiguration(.init(pointSize: 10, weight: .bold))!
                .withTintColor(.systemRed, renderingMode: .alwaysOriginal))
        )
        likes.append(NSAttributedString(string: " " + Self.compact(country.standing.likes)))
        likesLabel.attributedText = likes
        accessibilityLabel = "Locked country, rank \(country.standing.rank), "
            + "\(country.standing.likes) likes"
        accessibilityHint = "Shows how to unlock it"
        let size = capsule.contentView.subviews.first?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            ?? CGSize(width: 110, height: 22)
        let bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 17, height: ceil(size.height) + 8)
        frame.size = bounds.size
        capsule.frame = bounds
        capsule.layer.cornerRadius = bounds.height / 2
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
        centerOffset = .zero
    }

    /// "12.4K", "3.1M", "860".
    static func compact(_ value: Int64) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: String(format: "%.0fK", Double(value) / 1_000)
        case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
        default: "\(value)"
        }
    }

    @objc private func tapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSelect?()
    }
}
