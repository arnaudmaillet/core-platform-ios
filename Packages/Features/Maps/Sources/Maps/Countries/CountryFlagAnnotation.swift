import DesignSystem
import MapKit
import UIKit

/// A country with nothing on the map: no marker of its posts stands for it,
/// because it has none (or none loaded at this zoom), so the country itself
/// does — its round flag at its label point.
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


/// The empty country's disc — the country's ROUND flag itself:
///
/// ```
///    ╭───╮          ╭───╮
///   │ 🇯🇵 │        │▓▓▓▓▓│
///    ╰───╯          ╰───🔒   locked: the flag darkened, the lock in the badge corner
/// ```
///
/// The disc IS the flag (`FlagPalette`'s round flag, edge to edge), under a
/// hairline that keeps a white flag (Japan) from melting into light tiles and
/// a dark one into dark tiles — the flag-gradient border a post marker wears
/// would only repeat the flag around itself. Locked, the flag darkens and the
/// lock takes the corner a post marker gives its flag — the flag is already
/// the face. A code without a round flag (none in the atlas) shows its emoji
/// on the map's ground instead.
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
    /// country reads as lighter than a country with something to show. The
    /// flags are rendered for exactly this size (`Scripts/import-circle-flags.py`).
    static let side: CGFloat = 40
    /// How dark a locked country's flag goes.
    static let lockedVeilAlpha: CGFloat = 0.45
    private static let hairlineWidth: CGFloat = 0.75

    /// A tap on the disc — the host offers a locked country, or goes to an
    /// open one.
    var onSelect: (() -> Void)?

    /// The shadow and the disc's furniture.
    private let body = UIView()
    private let disc = UIView()
    private let veil = UIView()
    private let flagView = UIImageView()
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
        disc.layer.cornerRadius = Self.side / 2
        disc.layer.cornerCurve = .circular
        // The hairline: a layer's border composites ABOVE its sublayers, so it
        // rims the flag and the veil alike.
        disc.layer.borderWidth = Self.hairlineWidth
        disc.clipsToBounds = true
        flagView.contentMode = .scaleAspectFit
        disc.addSubview(flagView)
        veil.frame = local
        veil.backgroundColor = UIColor.black.withAlphaComponent(Self.lockedVeilAlpha)
        disc.addSubview(veil)
        badge.center = MapMarkerBadgeView.center(in: local.size, cornerRadius: Self.side / 2)
        body.addSubview(disc)
        body.addSubview(badge)
        addSubview(body)
        applyHairline()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyHairline()
        }
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

    private func applyHairline() {
        disc.layer.borderColor = MapFlagBorderView.hairlineColor.resolvedColor(with: traitCollection).cgColor
    }

    private func configure() {
        guard let country = annotation as? CountryFlagAnnotation else { return }
        let flag = FlagPalette.entry(for: country.code)
        flagView.image = flag.image
        // The round flag fills the disc; an emoji sits on the map's ground,
        // inside it.
        let local = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        flagView.frame = flag.isRound ? local : local.insetBy(dx: 9, dy: 9)
        disc.backgroundColor = flag.isRound ? .clear : .systemBackground
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
    var debugFlagImage: UIImage? { flagView.image }
    /// The flag's frame in the disc, and the disc's own.
    var debugFlagFrame: CGRect { flagView.frame }
    var debugDiscBounds: CGRect { disc.bounds }
    var debugVeilAlpha: CGFloat { veil.isHidden ? 0 : veil.backgroundColor?.cgColor.alpha ?? 0 }
    #endif

    @objc private func tapped() {
        HapticImpact(style: .light).impactOccurred()
        onSelect?()
    }
}
