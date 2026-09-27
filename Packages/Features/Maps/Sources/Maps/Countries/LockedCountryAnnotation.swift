import DesignSystem
import MapKit
import UIKit

/// A country the account has not unlocked, standing at the country's centre
/// with its rank among the world's countries.
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
///   ⬤─────────────╮
///  (🔒) 🇪🇸  #4    │
///   ⬤─────────────╯
/// ```
///
/// The flag and the rank on the map's own material, and the lock in a small
/// dark bubble riding the capsule's LEFT edge: what the country is, then what
/// a tap offers. The likes live in the offer's sheet, not here — on a map of
/// two hundred badges they were a column of numbers nobody compared.
///
/// ⚠️ **BELOW THE POSTS, AND IT GIVES WAY — THE BUSIEST FIRST.**
/// `displayPriority` is under `.defaultLow` and follows the RANK (at one flat
/// priority MapKit kept Monaco and hid Germany), so a post's marker always
/// wins its place and among badges the busiest country does.
///
/// ⚠️ **THE VIEW IS BIGGER THAN THE BADGE.** MapKit collides annotation
/// FRAMES, so the view carries a transparent margin (`collisionMargin`) around
/// the capsule: two badges now need that much room between them, which is
/// what thins a continent from a wall of badges to a scatter. Only the
/// capsule and its bubble take touches (`point(inside:)`).
final class LockedCountryAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "LockedCountryAnnotationView"
    /// The empty room around the badge that another badge may not enter.
    static let collisionMargin = CGSize(width: 34, height: 26)
    private static let bubbleDiameter: CGFloat = 22

    /// A tap on the badge — the host offers the country.
    var onSelect: (() -> Void)?

    /// The capsule's shadow, its material, and the lock bubble.
    private let body = UIView()
    private let capsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let bubble = UIView()
    private let flagLabel = UILabel()
    private let rankLabel = UILabel()
    private let lockView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let row = UIStackView()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .defaultLow
        collisionMode = .rectangle
        canShowCallout = false

        body.layer.shadowColor = UIColor.black.cgColor
        body.layer.shadowOpacity = 0.18
        body.layer.shadowRadius = 6
        body.layer.shadowOffset = CGSize(width: 0, height: 2)
        capsule.clipsToBounds = true
        capsule.layer.cornerCurve = .circular

        bubble.backgroundColor = UIColor(white: 0.1, alpha: 0.92)
        bubble.layer.cornerRadius = Self.bubbleDiameter / 2
        bubble.layer.borderWidth = 1.5
        bubble.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        lockView.tintColor = .white
        lockView.preferredSymbolConfiguration = .init(pointSize: 9, weight: .bold)
        lockView.contentMode = .center
        bubble.addSubview(lockView)

        flagLabel.font = .systemFont(ofSize: 17)
        rankLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        rankLabel.textColor = .label
        row.addArrangedSubview(flagLabel)
        row.addArrangedSubview(rankLabel)
        row.spacing = 5
        row.alignment = .center
        capsule.contentView.addSubview(row)
        body.addSubview(capsule)
        body.addSubview(bubble)
        addSubview(body)
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

    /// Only the badge itself: the collision margin around it is empty map.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        body.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    private func configure() {
        guard let country = annotation as? LockedCountryAnnotation else { return }
        flagLabel.text = country.flag
        rankLabel.text = "#\(country.standing.rank)"
        displayPriority = MKFeatureDisplayPriority(rawValue: Float(max(10, 249 - country.standing.rank)))
        accessibilityLabel = "Locked country, rank \(country.standing.rank)"
        accessibilityHint = "Shows how to unlock it"

        // The capsule: the row, with room on the left for the bubble's half.
        let content = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let height = max(ceil(content.height) + 6, 26)
        let leading = Self.bubbleDiameter / 2 + 5
        let capsuleSize = CGSize(width: leading + ceil(content.width) + 10, height: height)
        // The bubble's centre sits ON the capsule's left edge.
        let bodySize = CGSize(width: capsuleSize.width + Self.bubbleDiameter / 2, height: height)
        let margin = Self.collisionMargin
        frame.size = CGSize(width: bodySize.width + 2 * margin.width, height: bodySize.height + 2 * margin.height)
        body.frame = CGRect(origin: CGPoint(x: margin.width, y: margin.height), size: bodySize)
        capsule.frame = CGRect(x: Self.bubbleDiameter / 2, y: 0, width: capsuleSize.width, height: height)
        capsule.layer.cornerRadius = height / 2
        row.frame = CGRect(x: leading, y: (height - ceil(content.height)) / 2,
                           width: ceil(content.width), height: ceil(content.height))
        bubble.frame = CGRect(x: 0, y: (height - Self.bubbleDiameter) / 2,
                              width: Self.bubbleDiameter, height: Self.bubbleDiameter)
        lockView.frame = bubble.bounds
        body.layer.shadowPath = UIBezierPath(roundedRect: capsule.frame, cornerRadius: height / 2).cgPath
        // Centred on the country's label point, the capsule rather than the
        // bubble: shift left by half the bubble's overhang.
        centerOffset = CGPoint(x: -Self.bubbleDiameter / 4, y: 0)
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
