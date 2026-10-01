import DesignSystem
import MapKit
import UIKit

/// A country with nothing on the map: no marker of its posts stands for it,
/// because it has none (or none loaded at this zoom), so the country itself
/// does — its flag in a disc at its label point.
///
/// Every country can therefore be found on the map: a country with posts by
/// the marker of its busiest post (`MapClusterAnnotationView`, locked or not),
/// a country without by this.
final class CountryFlagAnnotation: NSObject, MKAnnotation {
    let code: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    /// Not unlocked by the account: darkened, a lock in its corner, and a tap
    /// offers it.
    let isLocked: Bool
    /// The country's place among the world's (1 = the busiest) — what decides
    /// which of two colliding discs MapKit keeps.
    let rank: Int

    init(country: CountryAtlas.Country, isLocked: Bool, rank: Int) {
        code = country.code
        name = country.name
        coordinate = country.label
        self.isLocked = isLocked
        self.rank = rank
    }
}

/// The empty country's disc:
///
/// ```
///    ╭───╮          ╭───╮
///   │ 🇯🇵 │        │▓🇯🇵▓│
///    ╰───╯          ╰───🔒   locked: darkened, the lock in the badge corner
/// ```
///
/// The flag on the map's own ground, inside the flag-gradient border every
/// country marker wears (`MapFlagBorderView`). Locked, the ground darkens and
/// the lock takes the corner a post marker gives its flag — the flag is
/// already the face.
///
/// ⚠️ **BELOW EVERY POST MARKER, AND IT GIVES WAY — THE BUSIEST FIRST.**
/// `displayPriority` is under `.defaultLow` and follows the RANK (at one flat
/// priority MapKit kept Monaco and hid Germany), so a post's marker always
/// wins its place — open (`.required`) or locked (`MapMarkerDress
/// .lockedPriority`) — and among discs the busiest country does.
///
/// ⚠️ **THE VIEW IS BIGGER THAN THE DISC.** MapKit collides annotation
/// FRAMES, so the view carries a transparent margin (`collisionMargin`) around
/// it: two discs need that much room between them, which is what thins a
/// continent from a wall of flags to a scatter. Only the disc takes touches
/// (`point(inside:)`).
final class CountryFlagAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "CountryFlagAnnotationView"
    /// The empty room around the disc that another disc may not enter.
    static let collisionMargin = CGSize(width: 14, height: 12)
    /// The disc's diameter: a little under a text marker's, so an empty
    /// country reads as lighter than a country with something to show.
    static let side: CGFloat = 40

    /// A tap on the disc — the host offers a locked country, or goes to an
    /// open one.
    var onSelect: (() -> Void)?

    /// The shadow and the disc's furniture.
    private let body = UIView()
    private let disc = UIView()
    private let veil = UIView()
    private let flagView = UIImageView()
    private let border = MapFlagBorderView()
    private let badge = MapMarkerBadgeView()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .defaultLow
        collisionMode = .rectangle
        canShowCallout = false
        let margin = Self.collisionMargin
        frame = CGRect(x: 0, y: 0, width: Self.side + 2 * margin.width, height: Self.side + 2 * margin.height)
        centerOffset = .zero
        body.frame = CGRect(x: margin.width, y: margin.height, width: Self.side, height: Self.side)
        let local = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        // The pin's own lift — same shadow as a marker — on an explicit path.
        PinCardView.applyPinShadow(to: body.layer)
        body.layer.shadowPath = UIBezierPath(ovalIn: local).cgPath
        disc.frame = local
        disc.backgroundColor = .systemBackground
        disc.layer.cornerRadius = Self.side / 2
        disc.layer.cornerCurve = .circular
        disc.clipsToBounds = true
        flagView.contentMode = .scaleAspectFit
        flagView.frame = local.insetBy(dx: 9, dy: 9)
        disc.addSubview(flagView)
        veil.frame = local
        veil.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        disc.addSubview(veil)
        border.frame = local
        border.setShape(radius: Self.side / 2, curve: .circular)
        let center = MapMarkerBadgeView.center(in: local.size, cornerRadius: Self.side / 2)
        badge.center = center
        body.addSubview(disc)
        body.addSubview(border)
        body.addSubview(badge)
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
        alpha = 1
        transform = .identity
    }

    /// Only the disc (and its badge): the collision margin around it is
    /// empty map.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        body.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    private func configure() {
        guard let country = annotation as? CountryFlagAnnotation else { return }
        flagView.image = FlagPalette.image(for: country.code)
        border.setFlag(country.code)
        veil.isHidden = !country.isLocked
        badge.setBadge(country.isLocked ? .lock : nil)
        displayPriority = Self.priority(forRank: country.rank)
        accessibilityLabel = country.isLocked ? "\(country.name), locked" : country.name
        accessibilityHint = country.isLocked ? "Shows how to unlock it" : "Shows the country"
    }

    /// Under `.defaultLow` (250) and falling with the rank, so post markers
    /// always win and the busiest country wins among discs.
    static func priority(forRank rank: Int) -> MKFeatureDisplayPriority {
        MKFeatureDisplayPriority(rawValue: Float(max(10, 249 - rank)))
    }

    #if DEBUG
    var debugIsDarkened: Bool { !veil.isHidden }
    var debugBadge: MapMarkerDress.Badge? { badge.badge }
    var debugBorderFlag: String? { border.flagCode }
    var debugFlagImage: UIImage? { flagView.image }
    #endif

    @objc private func tapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSelect?()
    }
}
