import DesignSystem
import UIKit

/// What a post tab shows when nothing is vending post surfaces.
///
/// ⚠️ THIS IS NOT A PLACEHOLDER FOR UNFINISHED WORK — it is the honest floor
/// for a COMPOSITION that did not wire `SearchPostSurfaceProviding`. The seam
/// is optional by design: Search must build, run and be testable without Feed
/// present, exactly as it does today with `ExploreProviding` unset. A crash or
/// a blank page there would make the package's independence a lie that only
/// shows up at runtime.
///
/// In the app, the root wires the provider and this is never seen.
@MainActor
final class SearchPendingSurfaceViewController: UIViewController, SearchPostSurface {
    var viewController: UIViewController { self }

    /// Ignored. There is nothing here that could show a post — see the type's
    /// note. Conforming anyway is what lets the screen hold ONE kind of thing
    /// rather than branching on whether a provider was wired.
    func show(_ state: SearchPostSurfaceState) {}

    /// Nothing here plays.
    func setPlaybackActive(_ active: Bool) {}

    enum Kind {
        case posts
        case media

        var title: String {
            switch self {
            case .posts: "Posts aren't available here"
            case .media: "Media isn't available here"
            }
        }

        var symbol: String {
            switch self {
            case .posts: "rectangle.stack"
            case .media: "square.grid.2x2"
            }
        }
    }

    private let kind: Kind
    private let statusView = EmptyStateView()

    init(kind: Kind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.configure(
            symbolName: kind.symbol,
            title: kind.title,
            subtitle: "Try the Users tab for people matching this search."
        )
        view.addSubview(statusView)
        NSLayoutConstraint.activate([
            statusView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            statusView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }
}
