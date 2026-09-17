import MediaPlayback
import UIKit

/// The mark on a cut: a small white disc with a `+`, or with the symbol of the
/// transition the cut already carries.
///
/// ```
///   ▓▓▓▓▓▓▓▓▓( + )▓▓▓▓▓▓▓▓▓
/// ```
///
/// ⚠️ **A FINGER WIDE, A DISC SMALL.** The disc is 22pt so it sits on the cut
/// without hiding the film either side of it; the button around it is 44pt —
/// the platform's minimum target — so a thumb can find it. The track narrows
/// the target where cuts crowd (`MediaTimelining.seamMarks`).
///
/// ⚠️ **THE SHADOW HAS AN EXPLICIT PATH.** Without one Core Animation renders
/// the disc offscreen to find its outline, once per mark, per frame of a scroll.
@MainActor
final class SeamButton: UIButton {
    private enum Metrics {
        static let disc: CGFloat = 22
        static let hit: CGFloat = 44
        static let glyph: CGFloat = 11
    }

    nonisolated static var hitSize: CGFloat { Metrics.hit }
    nonisolated static var discSize: CGFloat { Metrics.disc }

    /// Which cut this stands on: the one after piece `seam`.
    var seam = 0

    private let disc = UIView()
    private let glyph = UIImageView()
    private(set) var showing: VideoTransitionKind?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Metrics.hit, height: Metrics.hit))
        backgroundColor = .clear

        disc.isUserInteractionEnabled = false
        disc.backgroundColor = .white
        disc.frame = CGRect(x: 0, y: 0, width: Metrics.disc, height: Metrics.disc)
        disc.layer.cornerRadius = Metrics.disc / 2
        disc.layer.shadowColor = UIColor.black.cgColor
        disc.layer.shadowOpacity = 0.3
        disc.layer.shadowRadius = 2
        disc.layer.shadowOffset = .zero
        disc.layer.shadowPath = UIBezierPath(ovalIn: disc.bounds).cgPath
        addSubview(disc)

        glyph.isUserInteractionEnabled = false
        glyph.tintColor = .black
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: Metrics.glyph, weight: .bold
        )
        disc.addSubview(glyph)
        glyph.frame = disc.bounds
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        disc.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// States what the cut carries: nothing yet, or a kind.
    func show(_ kind: VideoTransitionKind?) {
        showing = kind
        glyph.image = UIImage(systemName: MediaTransitionCatalog.markGlyph(for: kind))
        accessibilityLabel = kind.map { "Transition: \($0.spokenLabel)" } ?? "Add a transition"
    }

    #if DEBUG
    /// Internal for tests: the symbol drawn on the disc — read off the IMAGE,
    /// not off `showing`, which would say what was asked for rather than what
    /// is on screen.
    var debugGlyph: String? { MediaTransitionCatalog.debugSymbol(drawnIn: glyph.image) }
    #endif
}
